// LiveKit 访问令牌签发。
//
// 只依赖 Node 内置 crypto，不引入第三方包 —— 服务因此可以「拷贝即部署」，
// 线上不需要 npm install。
//
// 令牌是 HS256 签名的 JWT，权限写在 video 字段里，客户端无法自行提权。

import { createHmac, timingSafeEqual } from 'node:crypto';
import { config } from './config.mjs';

const base64url = (input) => Buffer.from(input).toString('base64url');

/**
 * 签发 LiveKit 访问令牌。
 *
 * @param {object} options
 * @param {string} options.identity     参与者标识，同一房间内必须唯一
 * @param {string} options.room         房间名
 * @param {boolean} options.canPublish  是否允许发布轨道（采集端 true，接收端 false）
 * @param {string} [options.name]       展示用名称
 * @param {number} [options.ttlSec]     有效期
 */
export function signLiveKitToken({ identity, room, canPublish, name, ttlSec }) {
  const now = Math.floor(Date.now() / 1000);

  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    exp: now + (ttlSec ?? config.livekit.tokenTtlSec),
    iss: config.livekit.apiKey,
    sub: identity,
    nbf: now - 10,
    video: {
      room,
      roomJoin: true,
      canPublish,
      canSubscribe: true,
      // 接收端连数据通道也不给，彻底断掉反向操作的可能
      canPublishData: canPublish,
    },
  };
  if (name) payload.name = name;

  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createHmac('sha256', config.livekit.apiSecret)
    .update(signingInput)
    .digest('base64url');

  return `${signingInput}.${signature}`;
}

/** 解析令牌载荷，仅供本地调试与测试使用，不做签名校验。 */
export function decodeTokenPayload(token) {
  const [, payload] = token.split('.');
  return JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
}

/** 定长字符串的常量时间比较，避免通过响应耗时逐位猜出密码。 */
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
