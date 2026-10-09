// 各接口的处理逻辑。路由注册见 index.mjs。
//
// 鉴权分两种，不要混淆：
//   用户会话（Bearer 令牌）—— 人用的，管理账号与设备
//   设备凭据（请求体里的 sessionToken）—— 设备自己用的，心跳与刷新密码

import { randomBytes } from 'node:crypto';
import { config } from './config.mjs';
import * as requests from './requests.mjs';
import * as store from './store.mjs';
import * as users from './users.mjs';
import { signLiveKitToken } from './token.mjs';
import { createRateLimiter } from './ratelimit.mjs';

const ok = (body) => ({ status: 200, body });

const fail = (status, code, message, extra = {}) => ({
  status,
  body: { error: { code, message, ...extra } },
});

const isDeviceId = (value) => /^\d{9}$/.test(String(value ?? ''));

const OFFLINE_MESSAGE = '设备不在线。请确认设备 ID 是否正确，且对方已启动投送。';

/** 连接尝试的限流，按设备 ID 计。 */
const connectLimiter = createRateLimiter({
  windowSec: config.rateLimit.windowSec,
  maxFailures: config.rateLimit.maxFailures,
  cooldownSec: config.rateLimit.cooldownSec,
});

/** 登录尝试的限流，按邮箱计。 */
const loginLimiter = createRateLimiter({
  windowSec: config.auth.loginWindowSec,
  maxFailures: config.auth.loginMaxFailures,
  cooldownSec: config.auth.loginCooldownSec,
});

/** 仅供测试使用：清空限流状态。 */
export function resetLimiters() {
  connectLimiter.resetAll();
  loginLimiter.resetAll();
}

function bearerToken(request) {
  const header = request?.headers?.authorization ?? '';
  const match = /^Bearer\s+(.+)$/i.exec(header);
  return match ? match[1].trim() : null;
}

/** 解析当前登录用户。 */
async function currentUser(request) {
  const resolved = await users.resolveSession(bearerToken(request));
  return resolved ? resolved.user : null;
}

// MARK: - 账号

/** POST /v1/auth/register */
export async function registerAccount({ body }) {
  const invalid = users.validateRegistration(body ?? {});
  if (invalid.error) return fail(400, invalid.error, invalid.message);

  const result = await users.createUser({
    email: body.email,
    password: body.password,
    name: body.name,
  });

  if (result.error === 'email_taken') {
    return fail(409, 'email_taken', '这个邮箱已经注册过了');
  }

  const session = await users.createSession(result.user.id);
  return ok({
    user: users.toPublicUser(result.user),
    token: session.token,
    expiresAt: session.expiresAt,
  });
}

/** POST /v1/auth/login */
export async function login({ body }) {
  const email = String(body?.email ?? '').trim();

  const limit = loginLimiter.check(email.toLowerCase());
  if (limit.blocked) {
    return fail(429, 'rate_limited', `尝试过于频繁，请 ${limit.retryAfterSec} 秒后重试`, {
      retryAfterSec: limit.retryAfterSec,
    });
  }

  const result = await users.authenticate({ email, password: body?.password });

  if (result.error) {
    const outcome = loginLimiter.recordFailure(email.toLowerCase());
    if (outcome.cooldown) {
      return fail(429, 'rate_limited', `密码错误次数过多，请 ${outcome.retryAfterSec} 秒后重试`, {
        retryAfterSec: outcome.retryAfterSec,
      });
    }
    return fail(401, 'invalid_credentials', '邮箱或密码不正确', {
      remainingAttempts: outcome.remainingAttempts,
    });
  }

  loginLimiter.recordSuccess(email.toLowerCase());
  const session = await users.createSession(result.user.id);

  return ok({
    user: users.toPublicUser(result.user),
    token: session.token,
    expiresAt: session.expiresAt,
  });
}

/** POST /v1/auth/logout */
export async function logout({ request }) {
  await users.revokeSession(bearerToken(request));
  return ok({ ok: true });
}

/** GET /v1/me */
export async function me({ request }) {
  const user = await currentUser(request);
  if (!user) return fail(401, 'unauthorized', '请先登录');
  return ok({ user: users.toPublicUser(user) });
}

// MARK: - 设备

/**
 * POST /v1/devices/register
 *
 * 需要登录：设备必须归属于某个账号。
 * 客户端应把返回的 deviceId 与 sessionToken 持久化到本地，下次启动带上来，
 * 服务端就能认出这是同一台设备，沿用原设备 ID。
 */
export async function registerDevice({ body, request }) {
  const user = await currentUser(request);
  if (!user) return fail(401, 'unauthorized', '请先登录');

  const { deviceId, sessionToken, platform, deviceName } = body ?? {};

  if (deviceId != null && !isDeviceId(deviceId)) {
    return fail(400, 'invalid_device_id', '设备 ID 必须是 9 位数字');
  }
  if (sessionToken != null && typeof sessionToken !== 'string') {
    return fail(400, 'invalid_request', 'sessionToken 必须是字符串');
  }

  const result = await store.registerDevice({
    deviceId: deviceId ? String(deviceId) : null,
    sessionToken,
    platform: typeof platform === 'string' ? platform : 'unknown',
    deviceName: typeof deviceName === 'string' && deviceName.trim() ? deviceName.trim() : '未命名设备',
    userId: user.id,
  });

  const identity = `caster-${result.deviceId}`;
  return ok({
    deviceId: result.deviceId,
    // 设备代码与请求中携带的不一致 → 说明这台机器换了账号（或凭据已失效），
    // 服务端为它分配了新代码；客户端据此提示用户。见 docs/architecture.md「多账号同一设备」。
    deviceIdChanged: Boolean(deviceId) && String(deviceId) !== result.deviceId,
    password: result.password,
    passwordLength: config.password.length,
    sessionToken: result.sessionToken,
    reusedDeviceId: result.reused,
    deviceName: result.record.name,
    platform: result.record.platform,
    roomName: `device-${result.deviceId}`,
    livekitUrl: config.livekit.url,
    token: signLiveKitToken({
      identity,
      room: `device-${result.deviceId}`,
      canPublish: true,
      name: result.record.name,
    }),
    identity,
    heartbeatIntervalSec: config.heartbeat.intervalSec,
  });
}

/** GET /v1/devices —— 当前用户名下的全部设备。 */
export async function listDevices({ request }) {
  const user = await currentUser(request);
  if (!user) return fail(401, 'unauthorized', '请先登录');
  return ok({ devices: await store.listDevices(user.id) });
}

/** PATCH /v1/devices/:deviceId —— 重命名自己名下的设备。 */
export async function updateDevice({ body, params, request }) {
  const user = await currentUser(request);
  if (!user) return fail(401, 'unauthorized', '请先登录');

  const result = await store.renameDevice(params.deviceId, user.id, body?.name);
  if (result.error === 'not_found') return fail(404, 'not_found', '设备不存在或不属于你');
  if (result.error === 'invalid_name') return fail(400, 'invalid_name', '设备名不能为空且不超过 32 个字符');

  return ok({ device: { deviceId: result.record.device_id, name: result.record.name } });
}

/** POST /v1/devices/:deviceId/heartbeat —— 设备用自己的凭据保活。 */
export async function heartbeat({ body, params }) {
  const result = await store.heartbeat(params.deviceId, body?.sessionToken);
  if (result.error === 'device_unknown') return fail(404, 'device_unknown', '设备不存在或已解绑');
  if (result.error === 'unauthorized') return fail(401, 'unauthorized', '设备凭据无效');
  // 顺带把待处理的「观看请求」带给设备，客户端据此弹窗征求同意
  return ok({
    online: true,
    heartbeatIntervalSec: config.heartbeat.intervalSec,
    pendingRequests: requests.listPendingForDevice(params.deviceId),
  });
}

// MARK: - 连接请求（观看方发起 → 设备主人同意）

/** 观看方发起：POST /v1/connect-requests { deviceId, viewerName } */
export async function createConnectRequest({ body, request }) {
  const deviceId = String(body?.deviceId ?? '').trim();
  if (!isDeviceId(deviceId)) {
    return fail(400, 'invalid_device_id', '设备 ID 必须是 9 位数字');
  }

  const limit = connectLimiter.check(deviceId);
  if (limit.blocked) {
    return fail(429, 'rate_limited', `尝试过于频繁，请 ${limit.retryAfterSec} 秒后重试`, {
      retryAfterSec: limit.retryAfterSec,
    });
  }

  const found = await store.findOnlineDevice(deviceId);
  if (found.error) return fail(404, 'device_offline', OFFLINE_MESSAGE);

  // 即便是自己名下的设备也一律走「请求确认」：被观看这件事必须由设备端点头。
  // 想免确认就用设备自己的连接密码（/v1/connect），那是设备主人主动分享的凭据。
  const user = await currentUser(request);
  const owned = Boolean(user && found.record.user_id === user.id);

  const entry = requests.createRequest({
    deviceId: found.record.device_id,
    viewerName: typeof body?.viewerName === 'string' ? body.viewerName.slice(0, 32) : '',
    viewerAddress: request?.socket?.remoteAddress ?? '',
  });
  connectLimiter.recordSuccess(deviceId);

  return ok({
    owned,
    requestId: entry.id,
    expiresInSec: requests.ttlSec,
    deviceName: found.record.name,
  });
}

/** 观看方轮询：GET /v1/connect-requests/:requestId */
export async function getConnectRequest({ params }) {
  const entry = requests.getRequest(params.requestId);
  if (!entry) return fail(404, 'not_found', '请求不存在或已失效');

  if (entry.status === 'approved') {
    if (!entry.grant) return ok({ status: 'pending' }); // 令牌还没挂上，继续等
    return ok({
      status: 'approved',
      deviceId: entry.deviceId,
      roomName: entry.grant.roomName,
      livekitUrl: entry.grant.livekitUrl,
      token: entry.grant.token,
      deviceName: entry.grant.deviceName,
    });
  }

  return ok({ status: entry.status });
}

/** 设备主人决策：POST /v1/connect-requests/:requestId/decision { sessionToken, approve } */
export async function decideConnectRequest({ body, params }) {
  const entry = requests.getRequest(params.requestId);
  if (!entry) return fail(404, 'not_found', '请求不存在或已失效');

  // 用设备凭据确认是这台设备本人在操作
  const verified = await store.heartbeat(entry.deviceId, body?.sessionToken);
  if (verified.error === 'device_unknown') return fail(404, 'device_unknown', '设备不存在或已解绑');
  if (verified.error === 'unauthorized') return fail(401, 'unauthorized', '设备凭据无效');

  if (entry.status !== 'pending') {
    return fail(409, 'already_decided', '该请求已被处理');
  }

  const approve = body?.approve === true;
  const decided = requests.decideRequest(entry.id, approve);
  if (decided.error === 'not_found') return fail(404, 'not_found', '请求不存在或已失效');
  if (!approve) return ok({ approved: false });

  const identity = `viewer-${randomBytes(4).toString('hex')}`;
  const roomName = `device-${entry.deviceId}`;
  const token = signLiveKitToken({
    identity,
    room: roomName,
    canPublish: false,
    name: entry.viewerName || '观看端',
  });
  const device = await store.findOnlineDevice(entry.deviceId);
  requests.attachGrant(entry.id, {
    token,
    roomName,
    livekitUrl: config.livekit.url,
    deviceName: device.record?.name ?? '',
  });

  return ok({ approved: true });
}

/**
 * DELETE /v1/devices/:deviceId
 *
 * 两条路径：
 *   设备自己解绑 —— 带设备 sessionToken
 *   账号主人解绑 —— 带账号令牌（用于清理离线/已卸载的旧设备，设备自己没法解绑）
 */
export async function unregisterDevice({ body, params, request }) {
  const user = await currentUser(request);

  if (user) {
    const owned = await store.detachDevice(params.deviceId, user.id);
    if (owned.removed) return ok({ removed: true, by: 'owner' });
    // 带了账号令牌却删不掉：要么不存在，要么不属于他 —— 一律 404，不泄漏设备是否存在
    return fail(404, 'device_unknown', '设备不存在或不属于你');
  }

  const result = await store.unregister(params.deviceId, body?.sessionToken);
  if (result.error === 'device_unknown') return fail(404, 'device_unknown', '设备不存在或已解绑');
  if (result.error === 'unauthorized') return fail(401, 'unauthorized', '设备凭据无效');
  return ok({ removed: true, by: 'device' });
}

/** POST /v1/devices/:deviceId/password —— 刷新连接密码，旧密码立即失效。 */
export async function refreshDevicePassword({ body, params }) {
  const result = await store.refreshPassword(params.deviceId, body?.sessionToken);
  if (result.error === 'device_unknown') return fail(404, 'device_unknown', '设备不存在或已解绑');
  if (result.error === 'unauthorized') return fail(401, 'unauthorized', '设备凭据无效');
  return ok({ password: result.password, passwordLength: config.password.length });
}

// MARK: - 连接

/**
 * POST /v1/connect
 *
 * 两条路径：
 *   自己的设备 —— 带用户令牌即可，不需要密码（登录后点一下就能连）
 *   别人的设备 —— 需要设备 ID + 连接密码（ToDesk 式的对外分享）
 *
 * 校验顺序刻意设计为「限流 → 在线 → 密码」，避免被拿来做离线爆破的算力放大器。
 */
export async function connect({ body, request }) {
  const deviceId = String(body?.deviceId ?? '').trim();
  const password = String(body?.password ?? '').trim();

  if (!isDeviceId(deviceId)) {
    return fail(400, 'invalid_device_id', '设备 ID 必须是 9 位数字');
  }

  const limit = connectLimiter.check(deviceId);
  if (limit.blocked) {
    return fail(429, 'rate_limited', `尝试过于频繁，请 ${limit.retryAfterSec} 秒后重试`, {
      retryAfterSec: limit.retryAfterSec,
    });
  }

  const found = await store.findOnlineDevice(deviceId);
  if (found.error) return fail(404, 'device_offline', OFFLINE_MESSAGE);

  const user = await currentUser(request);
  const isOwner = Boolean(user && found.record.user_id === user.id);

  if (!isOwner) {
    if (!password) {
      return fail(400, 'invalid_request', '请填写连接密码');
    }

    const valid = await store.verifyDevicePassword(found.record, password);
    if (!valid) {
      const outcome = connectLimiter.recordFailure(deviceId);
      if (outcome.cooldown) {
        return fail(429, 'rate_limited', `密码错误次数过多，请 ${outcome.retryAfterSec} 秒后重试`, {
          retryAfterSec: outcome.retryAfterSec,
        });
      }
      return fail(401, 'wrong_password', `连接密码不正确，还可尝试 ${outcome.remainingAttempts} 次`, {
        remainingAttempts: outcome.remainingAttempts,
      });
    }
  }

  connectLimiter.recordSuccess(deviceId);

  const identity = `viewer-${randomBytes(4).toString('hex')}`;
  const roomName = `device-${found.record.device_id}`;

  return ok({
    deviceId: found.record.device_id,
    deviceName: found.record.name,
    platform: found.record.platform,
    roomName,
    livekitUrl: config.livekit.url,
    token: signLiveKitToken({
      identity,
      room: roomName,
      canPublish: false,
      name: typeof body?.viewerName === 'string' ? body.viewerName : undefined,
    }),
    identity,
    // 告诉客户端这次是靠什么授权的，便于界面提示
    via: isOwner ? 'owner' : 'password',
  });
}

/** GET /v1/devices/:deviceId/status —— 只暴露在线与否，不泄漏设备名。 */
export async function deviceStatus({ params }) {
  if (!isDeviceId(params.deviceId)) {
    return fail(400, 'invalid_device_id', '设备 ID 必须是 9 位数字');
  }
  const found = await store.findOnlineDevice(params.deviceId);
  return ok({ deviceId: params.deviceId, online: !found.error });
}

// MARK: - 健康检查

export async function health() {
  return ok({ ok: true, service: 'remotescreen-server', version: '0.3.0', stats: await store.stats() });
}
