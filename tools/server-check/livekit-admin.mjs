// LiveKit 管理接口的最小封装。
//
// 只依赖 Node 内置模块：手工签 HS256 令牌，直接调 Twirp 接口。
// check.mjs 与 inspect.mjs 共用这里的实现。

import { createHmac } from 'node:crypto';

export const config = {
  apiKey: process.env.LIVEKIT_API_KEY ?? 'devkey',
  apiSecret: process.env.LIVEKIT_API_SECRET ?? 'devsecret_devsecret_devsecret_32',
  baseUrl: process.env.LIVEKIT_HTTP ?? 'http://127.0.0.1:7880',
};

const base64url = (input) => Buffer.from(input).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);

/** 签发一枚带管理权限的令牌。 */
export function signAdminToken(grants = { roomList: true, roomCreate: true, roomAdmin: true }) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    exp: now() + 600,
    iss: config.apiKey,
    sub: 'server-check',
    nbf: now() - 10,
    video: grants,
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createHmac('sha256', config.apiSecret).update(signingInput).digest('base64url');
  return `${signingInput}.${signature}`;
}

/** 签发一枚房间内参与者令牌。 */
export function signParticipantToken({ identity, room, canPublish, canSubscribe = true }) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    exp: now() + 600,
    iss: config.apiKey,
    sub: identity,
    nbf: now() - 10,
    video: { room, roomJoin: true, canPublish, canSubscribe, canPublishData: canPublish },
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createHmac('sha256', config.apiSecret).update(signingInput).digest('base64url');
  return `${signingInput}.${signature}`;
}

export function decodePayload(token) {
  return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'));
}

/** 调用 RoomService 的 Twirp 接口。 */
export async function twirp(method, body = {}, token = signAdminToken()) {
  const response = await fetch(`${config.baseUrl}/twirp/livekit.RoomService/${method}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text };
  }
  return { ok: response.ok, status: response.status, body: parsed };
}
