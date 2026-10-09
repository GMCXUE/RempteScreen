// 用户账号与会话。
//
// 登录名用邮箱；邮箱统一转小写存储，避免 Alice@x.com 与 alice@x.com 被当成两个账号。

import { getPool, query } from './db.mjs';
import { config } from './config.mjs';
import { createPasswordRecord, verifyPassword, randomToken, sha256, newId } from './security.mjs';

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const normalizeEmail = (email) => String(email ?? '').trim().toLowerCase();

/** 非空用户永远查不到时，用一个固定盐跑一次哈希，避免通过响应耗时探测邮箱是否已注册。 */
const DECOY_SALT = '00'.repeat(16);
const DECOY_HASH = '00'.repeat(32);

export async function findUserByEmail(email) {
  const rows = await query('SELECT * FROM users WHERE email = $1', [normalizeEmail(email)]);
  return rows[0] ?? null;
}

export async function findUserById(id) {
  const rows = await query('SELECT * FROM users WHERE id = $1', [id]);
  return rows[0] ?? null;
}

export function validateRegistration({ email, password, name }) {
  if (!EMAIL_PATTERN.test(String(email ?? '').trim())) {
    return { error: 'invalid_email', message: '请填写有效的邮箱地址' };
  }
  if (String(password ?? '').length < 8) {
    return { error: 'weak_password', message: '密码至少 8 位' };
  }
  if (String(name ?? '').trim().length === 0) {
    return { error: 'invalid_name', message: '请填写昵称' };
  }
  if (String(name).trim().length > config.auth.nameMaxLength) {
    return { error: 'invalid_name', message: `昵称不能超过 ${config.auth.nameMaxLength} 个字符` };
  }
  return {};
}

export async function createUser({ email, password, name }) {
  const normalized = normalizeEmail(email);
  if (await findUserByEmail(normalized)) {
    return { error: 'email_taken' };
  }

  const { salt, hash } = await createPasswordRecord(password);
  const id = newId('user');

  await getPool().query(
    `INSERT INTO users (id, email, name, password_salt, password_hash, created_at)
     VALUES ($1, $2, $3, $4, $5, $6)`,
    [id, normalized, String(name).trim(), salt, hash, Date.now()],
  );

  return { user: await findUserById(id) };
}

export async function authenticate({ email, password }) {
  const user = await findUserByEmail(email);

  if (!user) {
    await verifyPassword(password, DECOY_SALT, DECOY_HASH);
    return { error: 'invalid_credentials' };
  }

  const ok = await verifyPassword(password, user.password_salt, user.password_hash);
  return ok ? { user } : { error: 'invalid_credentials' };
}

export async function createSession(userId) {
  const token = randomToken(32);
  const now = Date.now();
  const expiresAt = now + config.auth.sessionTtlSec * 1000;

  await getPool().query(
    'INSERT INTO sessions (token_hash, user_id, created_at, expires_at) VALUES ($1, $2, $3, $4)',
    [sha256(token), userId, now, expiresAt],
  );

  return { token, expiresAt };
}

/** 校验会话令牌，返回对应的用户；过期或无效一律返回 null。 */
export async function resolveSession(token) {
  if (!token) return null;

  const rows = await query('SELECT * FROM sessions WHERE token_hash = $1', [sha256(token)]);
  const row = rows[0];
  if (!row) return null;

  if (row.expires_at <= Date.now()) {
    await getPool().query('DELETE FROM sessions WHERE token_hash = $1', [row.token_hash]);
    return null;
  }

  const user = await findUserById(row.user_id);
  return user ? { user, expiresAt: row.expires_at } : null;
}

export async function revokeSession(token) {
  if (!token) return false;
  const result = await getPool().query('DELETE FROM sessions WHERE token_hash = $1', [sha256(token)]);
  return (result.rowCount ?? 0) > 0;
}

/** 对外的用户表示，绝不包含密码字段。 */
export function toPublicUser(user) {
  return { id: user.id, email: user.email, name: user.name, createdAt: user.created_at };
}
