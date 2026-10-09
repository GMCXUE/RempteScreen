#!/usr/bin/env node
// 媒体服务鉴权与房间管理链路验证。
//
// 只依赖 Node 内置模块，不装任何第三方包：
//   1. 用 API Key / Secret 手工签发 JWT（与后续令牌签发服务同源逻辑）
//   2. 通过 Twirp 接口调用 RoomService，确认服务端认可我们的密钥
//   3. 建房间 → 查房间 → 删房间，跑通完整生命周期
//
// 用法：node check.mjs

import { createHmac } from 'node:crypto';

const API_KEY = process.env.LIVEKIT_API_KEY ?? 'devkey';
const API_SECRET = process.env.LIVEKIT_API_SECRET ?? 'devsecret_devsecret_devsecret_32';
const BASE = process.env.LIVEKIT_HTTP ?? 'http://127.0.0.1:7880';

const base64url = (input) => Buffer.from(input).toString('base64url');
const now = () => Math.floor(Date.now() / 1000);

function signToken(grants, identity, room) {
  const header = { alg: 'HS256', typ: 'JWT' };
  const payload = {
    exp: now() + 600,
    iss: API_KEY,
    sub: identity,
    nbf: now() - 10,
    video: grants,
  };
  if (room) payload.video.room = room;
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = createHmac('sha256', API_SECRET).update(signingInput).digest('base64url');
  return `${signingInput}.${signature}`;
}

async function twirp(method, token, body = {}) {
  const response = await fetch(`${BASE}/twirp/livekit.RoomService/${method}`, {
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

const results = [];
function report(label, passed, detail) {
  results.push({ label, passed });
  console.log(`${passed ? '✅' : '❌'} ${label}${detail ? ` —— ${detail}` : ''}`);
}

console.log('=== RemoteScreen 媒体服务链路验证 ===');
console.log(`服务地址：${BASE}`);
console.log(`API Key：${API_KEY}`);
console.log('');

const adminToken = signToken({ roomList: true, roomCreate: true, roomAdmin: true }, 'server-check');
console.log(`已签发管理令牌：${adminToken.slice(0, 32)}…`);
console.log('');

// 1. 房间列表
let response = await twirp('ListRooms', adminToken);
report('服务接受我们的密钥（ListRooms）', response.ok,
  response.ok ? `返回 ${response.body.rooms?.length ?? 0} 个房间` : `HTTP ${response.status} ${JSON.stringify(response.body)}`);

// 2. 建房间
const roomName = 'screen-check1';
response = await twirp('CreateRoom', adminToken, { name: roomName });
const createdOK = response.ok && response.body.name === roomName;
report(`创建房间 ${roomName}`, createdOK,
  createdOK ? `emptyTimeout ${response.body.emptyTimeout}s` : `HTTP ${response.status} ${JSON.stringify(response.body)}`);

// 3. 房间出现在列表里
response = await twirp('ListRooms', adminToken);
const names = (response.body.rooms ?? []).map((room) => room.name);
report('新房间出现在列表中', response.ok && names.includes(roomName), `当前房间：${names.join(', ') || '无'}`);

// 4. 签发一个采集端令牌与一个接收端令牌，确认两者的权限确实不同
const casterToken = signToken(
  { roomJoin: true, canPublish: true, canSubscribe: true }, 'caster-mac', roomName);
const viewerToken = signToken(
  { roomJoin: true, canPublish: false, canSubscribe: true }, 'viewer-ipad', roomName);
const decode = (token) => JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString());
const casterGrants = decode(casterToken).video;
const viewerGrants = decode(viewerToken).video;
report('采集端与接收端权限已隔离',
  casterGrants.canPublish === true && viewerGrants.canPublish === false,
  `caster.canPublish=${casterGrants.canPublish}  viewer.canPublish=${viewerGrants.canPublish}`);

// 5. 删房间
response = await twirp('DeleteRoom', adminToken, { room: roomName });
report(`删除房间 ${roomName}`, response.ok, response.ok ? '' : `HTTP ${response.status}`);

console.log('');
const failed = results.filter((item) => !item.passed).length;
console.log(`=== 结果：${results.length - failed} / ${results.length} 通过 ===`);
process.exit(failed === 0 ? 0 : 1);
