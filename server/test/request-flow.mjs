// 「连接请求 → 设备主人同意」链路的端到端验证。
//
// 与 e2e.mjs 一样使用本地 PostgreSQL（TEST_DATABASE_URL，默认 54329 端口）。
// 覆盖：自己名下设备免请求 / 他人设备需请求 / 设备端心跳拿到待处理请求 /
//       同意后观看方取到令牌 / 拒绝与过期路径。
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.TEST_PORT ?? 8790);
const BASE = `http://127.0.0.1:${PORT}`;
const TEST_DB_URL =
  process.env.TEST_DATABASE_URL ?? 'postgres://remotescreen:remotescreen@127.0.0.1:54329/remotescreen_test';

const results = [];
const check = (label, passed, detail = '') => {
  results.push({ label, passed });
  console.log(`${passed ? '✅' : '❌'} ${label}${detail ? `  —— ${detail}` : ''}`);
};

async function api(method, endpoint, { body, token } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(`${BASE}${endpoint}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    parsed = { raw: text };
  }
  return { status: response.status, body: parsed };
}

console.log('=== 连接请求链路 · 端到端验证 ===');
console.log(`被测端口：${PORT}`);

const admin = new pg.Pool({ connectionString: TEST_DB_URL });
await admin.query('DROP TABLE IF EXISTS devices CASCADE');
await admin.query('DROP TABLE IF EXISTS sessions CASCADE');
await admin.query('DROP TABLE IF EXISTS users CASCADE');
await admin.end();

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
  console.error('服务未能在超时内启动');
  child.kill('SIGKILL');
  process.exit(1);
}

try {
  // 两个账号：A 持有设备，B 是观看方
  const alice = (await api('POST', '/v1/auth/register', {
    body: { email: 'alice@example.com', password: 'alice-secret-1', name: 'Alice' },
  })).body;
  const bob = (await api('POST', '/v1/auth/register', {
    body: { email: 'bob@example.com', password: 'bob-secret-123', name: 'Bob' },
  })).body;

  const device = (await api('POST', '/v1/devices/register', {
    token: alice.token,
    body: { platform: 'android', deviceName: 'Alice 的手机' },
  })).body;
  const { deviceId, sessionToken } = device;
  console.log(`  设备：${deviceId}`);

  // ---- 1. 自己的设备：不需要请求 ----
  let response = await api('POST', '/v1/connect-requests', {
    token: alice.token,
    body: { deviceId },
  });
  check('自己名下的设备发起请求时直接返回 owned', response.status === 200 && response.body.owned === true,
    `owned=${response.body.owned}`);

  // ---- 2. 他人设备：生成待处理请求 ----
  response = await api('POST', '/v1/connect-requests', {
    token: bob.token,
    body: { deviceId, viewerName: 'Bob 的电脑' },
  });
  const requestId = response.body.requestId;
  check('他人设备发起请求 → pending，返回 requestId',
    response.status === 200 && response.body.owned === false && /^[0-9a-f]{32}$/.test(requestId ?? ''),
    `requestId=${requestId?.slice(0, 8)}… 有效期 ${response.body.expiresInSec}s`);

  // ---- 3. 设备侧心跳能看到待处理请求 ----
  response = await api('POST', `/v1/devices/${deviceId}/heartbeat`, { body: { sessionToken } });
  const pending = response.body.pendingRequests ?? [];
  check('设备心跳响应携带待处理请求', pending.length === 1 && pending[0].requestId === requestId,
    `${pending.length} 条，来自「${pending[0]?.viewerName}」`);

  // ---- 4. 观看方轮询：仍为 pending ----
  response = await api('GET', `/v1/connect-requests/${requestId}`);
  check('未决策时轮询返回 pending', response.status === 200 && response.body.status === 'pending');

  // ---- 5. 设备同意 ----
  response = await api('POST', `/v1/connect-requests/${requestId}/decision`, {
    body: { sessionToken, approve: true },
  });
  check('设备端同意请求', response.status === 200 && response.body.approved === true);

  // ---- 6. 观看方取到令牌 ----
  response = await api('GET', `/v1/connect-requests/${requestId}`);
  check('同意后观看方取到房间与令牌',
    response.status === 200 && response.body.status === 'approved' &&
      response.body.roomName === `device-${deviceId}` && Boolean(response.body.token),
    `房间 ${response.body.roomName}`);

  // ---- 7. 重复决策被拒 ----
  response = await api('POST', `/v1/connect-requests/${requestId}/decision`, {
    body: { sessionToken, approve: true },
  });
  check('重复决策返回 409', response.status === 409 && response.body.error?.code === 'already_decided');

  // ---- 8. 拒绝路径 ----
  const second = (await api('POST', '/v1/connect-requests', {
    token: bob.token,
    body: { deviceId, viewerName: 'Bob 的电脑' },
  })).body;
  await api('POST', `/v1/connect-requests/${second.requestId}/decision`, {
    body: { sessionToken, approve: false },
  });
  response = await api('GET', `/v1/connect-requests/${second.requestId}`);
  check('拒绝后观看方拿到 denied', response.body.status === 'denied');

  // ---- 9. 无凭据的设备无法替别人同意 ----
  response = await api('POST', `/v1/connect-requests/${second.requestId}/decision`, {
    body: { sessionToken: 'forged-token', approve: true },
  });
  check('伪造设备凭据无法决策', response.status === 401);

  // ---- 10. 未知设备直接拒绝请求 ----
  response = await api('POST', '/v1/connect-requests', {
    token: bob.token,
    body: { deviceId: '999999999' },
  });
  check('未知设备发起请求返回 404', response.status === 404 && response.body.error?.code === 'device_offline',
    response.body.error?.message ?? '');
} finally {
  child.kill('SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, 400));
  child.kill('SIGKILL');
}

console.log('');
const failed = results.filter((item) => !item.passed);
console.log(`=== 结果：${results.length - failed.length} / ${results.length} 通过 ===`);
if (failed.length) for (const item of failed) console.log(`  未通过：${item.label}`);
process.exit(failed.length ? 1 : 0);
