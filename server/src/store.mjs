// 设备目录：持久化到 PostgreSQL，每台设备归属于一个用户。
//
// 与上一版的重要差别：设备不再随心跳超时被删除，只是状态变为离线。
// 有了账号体系后，「我的设备」需要长期存在，不能因为关机就从列表里消失。

import { randomInt } from 'node:crypto';
import { getPool, query } from './db.mjs';
import { config } from './config.mjs';
import { createPasswordRecord, verifyPassword, randomToken, sha256 } from './security.mjs';

// MARK: - 基础

export function isOnline(record, now = Date.now()) {
  return now - record.last_heartbeat_at <= config.heartbeat.timeoutSec * 1000;
}

export async function findDevice(deviceId) {
  const rows = await query('SELECT * FROM devices WHERE device_id = $1', [deviceId]);
  return rows[0] ?? null;
}

/** 分配一个未被占用的 9 位设备 ID，首位非零，便于口头转述。 */
async function allocateDeviceId() {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const candidate = String(randomInt(1, 10)) + String(randomInt(0, 100_000_000)).padStart(8, '0');
    const rows = await query('SELECT 1 FROM devices WHERE device_id = $1', [candidate]);
    if (rows.length === 0) return candidate;
  }
  throw new Error('设备 ID 池已耗尽');
}

/** 生成连接密码。字符集已剔除易混淆字符，配合限流可抵挡暴力尝试。 */
export function generatePassword() {
  const { alphabet, length } = config.password;
  let out = '';
  for (let index = 0; index < length; index += 1) {
    out += alphabet[randomInt(0, alphabet.length)];
  }
  return out;
}

// MARK: - 设备生命周期

/**
 * 注册或重新注册一台设备，并绑定到指定用户。
 *
 * - 带匹配的设备凭据且归属同一用户 → 沿用原设备 ID（设备重启场景）
 * - ID 已被**其他用户**占用 → 重新分配，不允许跨账号抢占
 * - 无论哪条路径都会生成新的连接密码与设备凭据 —— 凭据不跨会话复用
 */
export async function registerDevice({ deviceId, sessionToken, platform, deviceName, userId }) {
  const now = Date.now();

  const existing = deviceId ? await findDevice(deviceId) : null;

  let assignedId = null;
  let reused = false;

  if (existing) {
    const sameOwner = existing.user_id === userId;
    const sameToken = sessionToken && existing.session_token_hash === sha256(sessionToken);
    if (sameOwner && (sameToken || !isOnline(existing, now))) {
      assignedId = deviceId;
      reused = true;
    }
  } else if (deviceId && /^\d{9}$/.test(deviceId)) {
    // 库里没有这台设备但 ID 合法，说明是首次在新机器上登录
    assignedId = deviceId;
    reused = true;
  }

  if (!assignedId) assignedId = await allocateDeviceId();

  // 复用已有设备时**保留原密码**（自定义密码重启后不能丢）；
  // 只有新设备才生成一个随机密码。
  // 注意 password_plain 也要在：迁移前的老设备没有明文密码，
  // 这时重新生成一个（之后就会一直保持），否则界面上会显示成空密码。
  const keepPassword = reused && existing && existing.password_hash && existing.password_plain;
  const password = keepPassword ? existing.password_plain : generatePassword();
  const { salt, hash } = keepPassword
    ? { salt: existing.password_salt, hash: existing.password_hash }
    : await createPasswordRecord(password);
  const token = randomToken(32);

  await getPool().query(
    `
    INSERT INTO devices (
      device_id, user_id, name, platform,
      password_salt, password_hash, password_plain, session_token_hash,
      registered_at, last_heartbeat_at
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    ON CONFLICT(device_id) DO UPDATE SET
      user_id            = excluded.user_id,
      -- 名字归用户所有：设备已存在时保留库里的名字（改名只能走 PATCH），
      -- 否则客户端每次重启注册都会把用户改的名字冲回默认值。
      -- 仅当库里的名字为空时才采用本次注册上报的名字。
      name               = COALESCE(NULLIF(devices.name, ''), excluded.name),
      platform           = excluded.platform,
      password_salt      = excluded.password_salt,
      password_hash      = excluded.password_hash,
      password_plain     = excluded.password_plain,
      session_token_hash = excluded.session_token_hash,
      last_heartbeat_at  = excluded.last_heartbeat_at
    `,
    [
      assignedId,
      userId,
      deviceName || '未命名设备',
      platform || 'unknown',
      salt,
      hash,
      password,
      sha256(token),
      now,
      now,
    ],
  );

  return { deviceId: assignedId, password, sessionToken: token, reused, record: await findDevice(assignedId) };
}

/** 设备用自己持有的凭据证明身份（心跳、刷新密码、下线都走这里）。 */
async function requireOwnership(deviceId, sessionToken) {
  const record = await findDevice(deviceId);
  if (!record) return { error: 'device_unknown' };
  if (!sessionToken || record.session_token_hash !== sha256(sessionToken)) {
    return { error: 'unauthorized' };
  }
  return { record };
}

export async function heartbeat(deviceId, sessionToken) {
  const result = await requireOwnership(deviceId, sessionToken);
  if (result.error) return result;

  await getPool()
    .query('UPDATE devices SET last_heartbeat_at = $1 WHERE device_id = $2', [Date.now(), deviceId]);

  return { record: result.record, online: true };
}

export async function unregister(deviceId, sessionToken) {
  const result = await requireOwnership(deviceId, sessionToken);
  if (result.error) return result;

  await getPool().query('DELETE FROM devices WHERE device_id = $1', [deviceId]);
  return { removed: true };
}

/**
 * 账号侧解绑设备：设备离线（甚至已卸载）时，设备自己无法解绑，
 * 需要账号主人能把它从名下移除。
 */
export async function detachDevice(deviceId, userId) {
  const record = await findDevice(deviceId);
  if (!record) return { error: 'not_found' };
  if (record.user_id !== userId) return { error: 'not_found' }; // 不暴露他人设备是否存在

  await getPool().query('DELETE FROM devices WHERE device_id = $1', [deviceId]);
  return { removed: true, record };
}

/**
 * 设置连接密码，旧密码立即失效。
 *
 * customPassword 为空时随机生成一个（「刷新」）；给出时采用用户自定义的
 * （「自定义」）—— 两者都是设备自己的权利，账号主人改不了别台设备的密码。
 */
export async function refreshPassword(deviceId, sessionToken, customPassword) {
  const result = await requireOwnership(deviceId, sessionToken);
  if (result.error) return result;

  const password = customPassword && customPassword.length > 0 ? customPassword : generatePassword();
  const { salt, hash } = await createPasswordRecord(password);

  await getPool().query(
    'UPDATE devices SET password_salt = $1, password_hash = $2, password_plain = $3 WHERE device_id = $4',
    [salt, hash, password, deviceId],
  );

  return { password, record: await findDevice(deviceId) };
}

/** 重命名设备。只能改自己名下的。 */
export async function renameDevice(deviceId, userId, name) {
  const record = await findDevice(deviceId);
  if (!record || record.user_id !== userId) return { error: 'not_found' };

  const trimmed = String(name ?? '').trim();
  if (!trimmed || trimmed.length > 32) return { error: 'invalid_name' };

  await getPool().query('UPDATE devices SET name = $1 WHERE device_id = $2', [trimmed, deviceId]);
  return { record: await findDevice(deviceId) };
}

// MARK: - 查询

export async function findOnlineDevice(deviceId) {
  const record = await findDevice(deviceId);
  if (!record) return { error: 'device_offline' };
  if (!isOnline(record)) return { error: 'device_offline' };
  return { record };
}

export function verifyDevicePassword(record, password) {
  return verifyPassword(password, record.password_salt, record.password_hash);
}

/** 某个用户名下的全部设备，含在线状态。 */
export async function listDevices(userId) {
  const now = Date.now();
  const rows = await query(
    'SELECT * FROM devices WHERE user_id = $1 ORDER BY last_heartbeat_at DESC',
    [userId],
  );
  return rows.map((record) => ({
    deviceId: record.device_id,
    name: record.name,
    platform: record.platform,
    online: isOnline(record, now),
    lastSeenAt: record.last_heartbeat_at,
    registeredAt: record.registered_at,
  }));
}

export async function stats() {
  const count = async (sql, params = []) => {
    const rows = await query(sql, params);
    return Number(rows[0].n);
  };

  const total = await count('SELECT COUNT(*) AS n FROM devices');
  const users = await count('SELECT COUNT(*) AS n FROM users');

  const cutoff = Date.now() - config.heartbeat.timeoutSec * 1000;
  const online = await count('SELECT COUNT(*) AS n FROM devices WHERE last_heartbeat_at > $1', [cutoff]);

  return { users, devices: total, online };
}
