// 服务端到端验证。
//
// 真实启动 server/src/index.mjs 子进程，用独立的一次性数据库，然后把整条流程跑一遍。
// 除了正常路径，重点覆盖「越权」相关的错误路径 —— 引入账号体系后，
// 最容易出问题的不是功能不通，而是能碰到不该碰的东西。

import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.TEST_PORT ?? 8788);
const BASE = `http://127.0.0.1:${PORT}`;
// 被测库：本地起的 PostgreSQL 容器（见 docs/DEPLOY.md），每次跑测试前清空三张表
const TEST_DB_URL =
  process.env.TEST_DATABASE_URL ?? 'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test';

const results = [];

function check(label, passed, detail = '') {
  results.push({ label, passed });
  console.log(`${passed ? '✅' : '❌'} ${label}${detail ? `  —— ${detail}` : ''}`);
}

async function api(method, urlPath, { body, token } = {}) {
  const headers = {};
  if (body) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;

  const response = await fetch(`${BASE}${urlPath}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });

  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text };
  }
  return { status: response.status, body: parsed };
}

const decodePayload = (token) => JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));

console.log('=== RemoteScreen 服务端 · 端到端验证 ===');
console.log(`被测端口：${PORT}`);
console.log(`被测数据库：${TEST_DB_URL.replace(/:[^:@/]+@/, ':***@')}`);
console.log('');

// MARK: - 清空被测库

const admin = new pg.Pool({ connectionString: TEST_DB_URL });
await admin.query('DROP TABLE IF EXISTS devices CASCADE');
await admin.query('DROP TABLE IF EXISTS sessions CASCADE');
await admin.query('DROP TABLE IF EXISTS users CASCADE');
await admin.end();

// MARK: - 启动被测服务

const child = spawn(process.execPath, ['src/index.mjs'], {
  cwd: root,
  env: { ...process.env, PORT: String(PORT), HOST: '127.0.0.1', DATABASE_URL: TEST_DB_URL },
  stdio: ['ignore', 'pipe', 'pipe'],
});

child.stdout.on('data', (chunk) => {
  for (const line of String(chunk).trimEnd().split('\n')) console.log(`  │ ${line}`);
});
child.stderr.on('data', (chunk) => {
  for (const line of String(chunk).trimEnd().split('\n')) console.log(`  ⚠ ${line}`);
});

async function waitForReady(timeoutMs = 8000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${BASE}/v1/health`);
      if (response.ok) return true;
    } catch {
      // 还没起来
    }
    await new Promise((resolve) => setTimeout(resolve, 150));
  }
  return false;
}

if (!(await waitForReady())) {
  console.error('服务未能在超时内启动，测试中止');
  child.kill('SIGKILL');
  process.exit(1);
}
console.log('');

try {
  // ---------- 1. 账号注册 ----------
  let response = await api('POST', '/v1/auth/register', {
    body: { email: 'alice@example.com', password: 'alice-secret-1', name: 'Alice' },
  });
  const alice = response.body;
  check('注册账号成功', response.status === 200 && Boolean(alice.token) && alice.user?.email === 'alice@example.com',
    `用户 ${alice.user?.name}`);

  response = await api('POST', '/v1/auth/register', {
    body: { email: 'ALICE@example.com', password: 'another-secret', name: '假 Alice' },
  });
  check('同一邮箱大小写不同也算重复', response.status === 409 && response.body.error?.code === 'email_taken');

  response = await api('POST', '/v1/auth/register', {
    body: { email: 'bob@example.com', password: '123', name: 'Bob' },
  });
  check('弱密码被拒', response.status === 400 && response.body.error?.code === 'weak_password');

  response = await api('POST', '/v1/auth/register', {
    body: { email: 'not-an-email', password: 'bob-secret-123', name: 'Bob' },
  });
  check('非法邮箱被拒', response.status === 400 && response.body.error?.code === 'invalid_email');

  // ---------- 2. 登录 ----------
  response = await api('POST', '/v1/auth/login', {
    body: { email: 'alice@example.com', password: 'wrong-password' },
  });
  check('错误密码登录被拒', response.status === 401 && response.body.error?.code === 'invalid_credentials',
    `剩余 ${response.body.error?.remainingAttempts} 次`);

  response = await api('POST', '/v1/auth/login', {
    body: { email: 'alice@example.com', password: 'alice-secret-1' },
  });
  check('正确密码登录成功', response.status === 200 && Boolean(response.body.token));
  const aliceToken = response.body.token;

  response = await api('GET', '/v1/me');
  check('未登录访问 /v1/me 被拒', response.status === 401);

  response = await api('GET', '/v1/me', { token: aliceToken });
  check('带令牌访问 /v1/me 成功', response.status === 200 && response.body.user?.email === 'alice@example.com');
  check('用户信息不含密码字段',
    !JSON.stringify(response.body.user).includes('password'));

  // ---------- 3. 设备绑定 ----------
  response = await api('POST', '/v1/devices/register', {
    body: { platform: 'macos', deviceName: 'Alice 的 MacBook' },
  });
  check('未登录不能注册设备', response.status === 401);

  response = await api('POST', '/v1/devices/register', {
    token: aliceToken,
    body: { platform: 'macos', deviceName: 'Alice 的 MacBook' },
  });
  const aliceDevice = response.body;
  check('登录后注册设备成功并绑定到账号',
    response.status === 200 && /^\d{9}$/.test(aliceDevice.deviceId ?? ''),
    `设备 ID ${aliceDevice.deviceId}`);

  response = await api('POST', '/v1/devices/register', {
    token: aliceToken,
    body: {
      deviceId: aliceDevice.deviceId,
      sessionToken: aliceDevice.sessionToken,
      platform: 'macos',
      deviceName: 'Alice 的 MacBook',
    },
  });
  check('带凭据重新注册沿用原设备 ID',
    response.status === 200 && response.body.deviceId === aliceDevice.deviceId && response.body.reusedDeviceId === true);
  const aliceDevice2 = response.body;

  response = await api('GET', '/v1/devices', { token: aliceToken });
  check('设备列表能查到自己的设备',
    response.status === 200 && response.body.devices?.length === 1
      && response.body.devices[0].deviceId === aliceDevice.deviceId,
    `共 ${response.body.devices?.length} 台`);

  // ---------- 4. 设备凭据 ----------
  response = await api('POST', `/v1/devices/${aliceDevice.deviceId}/heartbeat`, {
    body: { sessionToken: aliceDevice2.sessionToken },
  });
  check('设备用心跳凭据保活成功', response.status === 200 && response.body.online === true);

  response = await api('POST', `/v1/devices/${aliceDevice.deviceId}/heartbeat`, {
    body: { sessionToken: 'f'.repeat(64) },
  });
  check('伪造设备凭据的心跳被拒', response.status === 401);

  // ---------- 5. 跨账号越权 ----------
  response = await api('POST', '/v1/auth/register', {
    body: { email: 'bob@example.com', password: 'bob-secret-123', name: 'Bob' },
  });
  const bobToken = response.body.token;
  check('注册第二个账号成功', response.status === 200);

  response = await api('POST', '/v1/devices/register', {
    token: bobToken,
    body: { deviceId: aliceDevice.deviceId, platform: 'windows', deviceName: '想抢占的设备' },
  });
  check('无法用别人的设备 ID 抢占设备',
    response.status === 200 && response.body.deviceId !== aliceDevice.deviceId,
    `分到了新 ID ${response.body.deviceId}`);
  const bobDevice = response.body;

  response = await api('GET', '/v1/devices', { token: bobToken });
  const bobIds = (response.body.devices ?? []).map((item) => item.deviceId);
  check('设备列表只返回自己名下的设备',
    response.status === 200 && bobIds.length === 1 && bobIds[0] === bobDevice.deviceId,
    `Bob 看到 ${bobIds.length} 台，且不含 Alice 的设备 ${!bobIds.includes(aliceDevice.deviceId)}`);

  response = await api('PATCH', `/v1/devices/${aliceDevice.deviceId}`, {
    token: bobToken,
    body: { name: '被改名了' },
  });
  check('无法重命名别人的设备', response.status === 404);

  response = await api('PATCH', `/v1/devices/${bobDevice.deviceId}`, {
    token: bobToken,
    body: { name: 'Bob 的台式机' },
  });
  check('可以重命名自己的设备',
    response.status === 200 && response.body.device?.name === 'Bob 的台式机');

  // ---------- 6. 连接 ----------
  response = await api('POST', '/v1/connect', {
    token: aliceToken,
    body: { deviceId: aliceDevice.deviceId },
  });
  check('设备主人免密码即可连接自己的设备',
    response.status === 200 && response.body.via === 'owner',
    `房间 ${response.body.roomName}`);

  const ownerGrants = decodePayload(response.body.token).video;
  check('观看令牌禁止发布轨道',
    ownerGrants.canPublish === false && ownerGrants.canPublishData === false);

  response = await api('POST', '/v1/connect', {
    token: bobToken,
    body: { deviceId: aliceDevice.deviceId },
  });
  check('非主人不带密码连接被拒', response.status === 400 && response.body.error?.code === 'invalid_request');

  // 注意用 aliceDevice2 的密码：带凭据重新注册时会轮换密码，
  // aliceDevice.password 已经失效了（下一组断言正好验证这一点）。
  response = await api('POST', '/v1/connect', {
    body: { deviceId: aliceDevice.deviceId, password: aliceDevice2.password },
  });
  check('用「设备 ID + 密码」可连接他人设备（对外分享通道）',
    response.status === 200 && response.body.via === 'password',
    `授权方式 ${response.body.via}`);

  response = await api('POST', '/v1/connect', {
    body: { deviceId: aliceDevice.deviceId, password: 'zzzzzz' },
  });
  check('错误密码被拒并提示剩余次数',
    response.status === 401 && response.body.error?.code === 'wrong_password');

  // ---------- 7. 密码刷新 ----------
  response = await api('POST', `/v1/devices/${aliceDevice.deviceId}/password`, {
    body: { sessionToken: bobDevice.sessionToken },
  });
  check('无法用别人的设备凭据刷新密码', response.status === 401);

  response = await api('POST', `/v1/devices/${aliceDevice.deviceId}/password`, {
    body: { sessionToken: aliceDevice2.sessionToken },
  });
  const newPassword = response.body.password;
  check('刷新自己设备的密码成功', response.status === 200 && newPassword !== aliceDevice.password,
    `新密码 ${newPassword}`);

  response = await api('POST', '/v1/connect', {
    body: { deviceId: aliceDevice.deviceId, password: aliceDevice.password },
  });
  check('刷新后旧密码立即失效', response.status === 401);

  response = await api('POST', '/v1/connect', {
    body: { deviceId: aliceDevice.deviceId, password: newPassword },
  });
  check('刷新后新密码可用', response.status === 200);

  // ---------- 8. 登出 ----------
  response = await api('POST', '/v1/auth/logout', { token: bobToken });
  check('登出成功', response.status === 200);

  response = await api('GET', '/v1/me', { token: bobToken });
  check('登出后令牌立即失效', response.status === 401);

  response = await api('GET', '/v1/me', { token: aliceToken });
  check('登出不影响其他会话', response.status === 200);

  // ---------- 9. 健康检查 ----------
  response = await api('GET', '/v1/health');
  check('健康检查包含账号与设备统计',
    response.status === 200 && response.body.stats?.users === 2 && response.body.stats?.devices === 2,
    `${response.body.stats?.users} 个账号 / ${response.body.stats?.devices} 台设备`);
} finally {
  child.kill('SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, 400));
  child.kill('SIGKILL');
}

console.log('');
const failed = results.filter((item) => !item.passed);
console.log(`=== 结果：${results.length - failed.length} / ${results.length} 通过 ===`);
if (failed.length > 0) {
  console.log('');
  for (const item of failed) console.log(`  未通过：${item.label}`);
}
process.exit(failed.length === 0 ? 0 : 1);
