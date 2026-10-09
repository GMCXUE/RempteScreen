// 密码哈希、令牌生成、常量时间比较。
// 用户密码与设备连接密码共用这里，避免两处实现漂移。

import { randomBytes, scrypt, timingSafeEqual, createHash } from 'node:crypto';
import { promisify } from 'node:util';

const scryptAsync = promisify(scrypt);

/** 用于校验高熵令牌（会话令牌、设备凭据），不需要慢哈希。 */
export const sha256 = (value) => createHash('sha256').update(value).digest('hex');

export const randomToken = (bytes = 32) => randomBytes(bytes).toString('hex');

export const newId = (prefix) => `${prefix}_${randomBytes(9).toString('hex')}`;

/**
 * 用户密码与设备连接密码都用 scrypt 派生，不存明文。
 * 迭代参数用 Node 默认值，单次约几十毫秒 —— 对登录接口可以接受，
 * 但因此必须配合限流，否则会变成 CPU 放大器。
 */
export async function hashPassword(password, saltHex) {
  const derived = await scryptAsync(password, Buffer.from(saltHex, 'hex'), 32);
  return derived.toString('hex');
}

export async function createPasswordRecord(password) {
  const salt = randomBytes(16).toString('hex');
  return { salt, hash: await hashPassword(password, salt) };
}

export async function verifyPassword(password, saltHex, expectedHash) {
  const candidate = await hashPassword(password ?? '', saltHex);
  return safeEqual(candidate, expectedHash);
}

/** 常量时间字符串比较，避免通过响应耗时逐位猜出密码。 */
export function safeEqual(a, b) {
  const left = Buffer.from(String(a ?? ''), 'utf8');
  const right = Buffer.from(String(b ?? ''), 'utf8');
  if (left.length !== right.length) {
    // 长度不同也要走一次比较，避免长度差异泄漏在耗时上
    timingSafeEqual(left, left);
    return false;
  }
  return timingSafeEqual(left, right);
}
