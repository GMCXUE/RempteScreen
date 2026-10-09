// 连接请求（ToDesk 式「请求观看」）：观看方发起，设备主人同意后才签发令牌。
//
// 生命周期：pending → approved / denied / expired（默认 60 秒）。
// 只放内存：这类请求都是秒级的，服务重启丢失无所谓。

import { randomBytes } from 'node:crypto';

const requests = new Map();

/** 请求有效期（秒）。 */
const TTL_SEC = 60;

const now = () => Date.now();

export function createRequest({ deviceId, viewerName, viewerAddress }) {
  prune();
  const request = {
    id: randomBytes(16).toString('hex'),
    deviceId,
    viewerName: viewerName || '未知设备',
    viewerAddress: viewerAddress || '',
    status: 'pending',
    createdAt: now(),
    expiresAt: now() + TTL_SEC * 1000,
    grant: null,
  };
  requests.set(request.id, request);
  return request;
}

export function getRequest(id) {
  prune();
  const request = requests.get(id);
  if (!request) return null;
  return request;
}

/** 该设备当前待处理的请求（给心跳响应带上，客户端据此弹窗）。 */
export function listPendingForDevice(deviceId) {
  prune();
  return [...requests.values()]
    .filter((request) => request.deviceId === deviceId && request.status === 'pending')
    .map((request) => ({
      requestId: request.id,
      viewerName: request.viewerName,
      viewerAddress: request.viewerAddress,
      createdAt: request.createdAt,
      expiresInSec: Math.max(0, Math.round((request.expiresAt - now()) / 1000)),
    }));
}

export function decideRequest(id, approve) {
  prune();
  const request = requests.get(id);
  if (!request) return { error: 'not_found' };
  if (request.status !== 'pending') return { request };
  request.status = approve ? 'approved' : 'denied';
  request.decidedAt = now();
  return { request };
}

/** 设备同意后把签发好的连接要素挂到请求上，观看方轮询时取走。 */
export function attachGrant(id, grant) {
  const request = requests.get(id);
  if (request) request.grant = grant;
}

export function prune() {
  const current = now();
  for (const [id, request] of requests) {
    if (request.status === 'pending' && request.expiresAt <= current) {
      request.status = 'expired';
    }
    // 已决或过期的请求保留一段时间供观看方查询结果，之后清理
    const settledAt = request.decidedAt ?? request.expiresAt;
    if (request.status !== 'pending' && current - settledAt > 5 * 60 * 1000) {
      requests.delete(id);
    }
  }
}

/** 后台清理定时器。 */
export function startSweeper() {
  return setInterval(prune, 15 * 1000).unref();
}

export const ttlSec = TTL_SEC;
