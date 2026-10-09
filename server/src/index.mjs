// RemoteScreen 设备目录与令牌签发服务。
//
// 持久化：PostgreSQL 容器（docker-compose 里与本服务一起部署），
// 连接串经 DATABASE_URL 注入。数据迁移见 scripts/migrate-sqlite-to-pg.mjs。
//
// 接口一览：
//   账号   POST   /v1/auth/register          注册
//          POST   /v1/auth/login             登录
//          POST   /v1/auth/logout            登出
//          GET    /v1/me                     当前用户
//   设备   GET    /v1/devices                我名下的设备列表
//          POST   /v1/devices/register       注册设备（需登录，绑定到当前用户）
//          PATCH  /v1/devices/:id            重命名设备
//          POST   /v1/devices/:id/heartbeat  设备保活
//          DELETE /v1/devices/:id            设备解绑
//          POST   /v1/devices/:id/password   刷新连接密码
//          GET    /v1/devices/:id/status     查询在线状态
//   连接   POST   /v1/connect                换取观看令牌
//   健康   GET    /v1/health

import http from 'node:http';
import { config } from './config.mjs';
import { openDatabase, purgeExpiredSessions, closeDatabase } from './db.mjs';
import * as handlers from './handlers.mjs';
import { startSweeper } from './requests.mjs';

const routes = [
  ['POST', '/v1/auth/register', handlers.registerAccount],
  ['POST', '/v1/auth/login', handlers.login],
  ['POST', '/v1/auth/logout', handlers.logout],
  ['GET', '/v1/me', handlers.me],

  ['GET', '/v1/devices', handlers.listDevices],
  ['POST', '/v1/devices/register', handlers.registerDevice],
  ['PATCH', '/v1/devices/:deviceId', handlers.updateDevice],
  ['POST', '/v1/devices/:deviceId/heartbeat', handlers.heartbeat],
  ['POST', '/v1/devices/:deviceId/notifications', handlers.deviceNotifications],
  ['GET', '/v1/devices/:deviceId/notifications/stream', handlers.deviceNotificationsStream],
  ['DELETE', '/v1/devices/:deviceId', handlers.unregisterDevice],
  ['POST', '/v1/devices/:deviceId/password', handlers.refreshDevicePassword],
  ['GET', '/v1/devices/:deviceId/status', handlers.deviceStatus],

  ['POST', '/v1/connect', handlers.connect],
  ['POST', '/v1/connect-requests', handlers.createConnectRequest],
  ['GET', '/v1/connect-requests/:requestId', handlers.getConnectRequest],
  ['DELETE', '/v1/connect-requests/:requestId', handlers.cancelConnectRequest],
  ['POST', '/v1/connect-requests/:requestId/decision', handlers.decideConnectRequest],
  ['GET', '/v1/health', handlers.health],
];

const compiledRoutes = routes.map(([method, pattern, handler]) => ({
  method,
  segments: pattern.split('/').filter(Boolean),
  handler,
}));

function matchRoute(method, pathname) {
  const parts = pathname.split('/').filter(Boolean);
  for (const route of compiledRoutes) {
    if (route.method !== method || route.segments.length !== parts.length) continue;

    const params = {};
    let matched = true;
    for (let index = 0; index < route.segments.length; index += 1) {
      const segment = route.segments[index];
      if (segment.startsWith(':')) {
        params[segment.slice(1)] = decodeURIComponent(parts[index]);
      } else if (segment !== parts[index]) {
        matched = false;
        break;
      }
    }
    if (matched) return { handler: route.handler, params };
  }
  return null;
}

function readJsonBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let settled = false;

    request.on('data', (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > config.body.maxBytes) {
        settled = true;
        reject(Object.assign(new Error('请求体过大'), { statusCode: 413 }));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });

    request.on('end', () => {
      if (settled) return;
      settled = true;
      const raw = Buffer.concat(chunks).toString('utf8').trim();
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch {
        reject(Object.assign(new Error('请求体不是合法 JSON'), { statusCode: 400 }));
      }
    });

    request.on('error', (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function send(response, status, payload) {
  const data = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(data),
  });
  response.end(data);
}

const timestamp = () => new Date().toISOString().slice(11, 19);

function log(method, path, status, detail) {
  const suffix = detail ? `  ${detail}` : '';
  console.log(`${timestamp()}  ${method.padEnd(6)} ${path.padEnd(40)} ${status}${suffix}`);
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  const pathname = url.pathname;

  response.setHeader('Access-Control-Allow-Origin', '*');
  response.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  response.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
  response.setHeader('Cache-Control', 'no-store');

  if (request.method === 'OPTIONS') {
    response.writeHead(204).end();
    return;
  }

  const route = matchRoute(request.method, pathname);
  if (!route) {
    log(request.method, pathname, 404);
    send(response, 404, { error: { code: 'not_found', message: `无此接口：${request.method} ${pathname}` } });
    return;
  }

  try {
    const hasBody = request.method === 'POST' || request.method === 'PUT' || request.method === 'PATCH' || request.method === 'DELETE';
    const body = hasBody ? await readJsonBody(request) : {};
    const result = await route.handler({
      body,
      params: route.params,
      query: url.searchParams,
      request,
      response,
    });

    // SSE 类处理器已经接管了响应（长连接），分发器不再收尾
    if (result && result.__sse) return;

    if (pathname !== '/v1/health') {
      const detail = result.body?.deviceId ? `deviceId=${result.body.deviceId}` : '';
      log(request.method, pathname, result.status, detail);
    }
    send(response, result.status, result.body);
  } catch (error) {
    const status = error.statusCode ?? 500;
    log(request.method, pathname, status, error.message);
    send(response, status, {
      error: { code: status === 500 ? 'internal_error' : 'bad_request', message: error.message },
    });
  }
});

// 定期清理过期会话，避免会话表无限增长
startSweeper();
const sweeper = setInterval(async () => {
  try {
    const removed = await purgeExpiredSessions();
    if (removed > 0) console.log(`${timestamp()}  sweep  清理过期会话 ${removed} 条`);
  } catch (error) {
    console.warn(`${timestamp()}  sweep  清理失败：${error.message}`);
  }
}, 3600 * 1000);
sweeper.unref();

await openDatabase();

server.listen(config.port, config.host, async () => {
  const stats = (await handlers.health()).body.stats;
  console.log('RemoteScreen 设备目录服务已启动');
  console.log(`  监听地址    http://${config.host}:${config.port}`);
  console.log(`  数据库      PostgreSQL  ${config.database.url.replace(/:[^:@/]+@/, ':***@')}`);
  console.log(`  LiveKit     ${config.livekit.url}  (key=${config.livekit.apiKey})`);
  console.log(`  已有数据    ${stats.users} 个账号 / ${stats.devices} 台设备`);
  console.log(`  心跳        每 ${config.heartbeat.intervalSec}s 上报，超时 ${config.heartbeat.timeoutSec}s 判定离线`);
  console.log(`  会话有效期  ${Math.round(config.auth.sessionTtlSec / 86400)} 天`);
  console.log('');
});

function shutdown(signal) {
  console.log(`\n收到 ${signal}，正在关闭……`);
  clearInterval(sweeper);
  server.close(async () => {
    await closeDatabase();
    process.exit(0);
  });
  setTimeout(() => process.exit(0), 3000).unref();
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
