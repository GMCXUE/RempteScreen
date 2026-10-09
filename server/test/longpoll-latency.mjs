// 长轮询的延迟与效率验证。
//
// 对比对象：原来的客户端每 1.5 秒轮询一次（最坏情况要等 1.5 秒才看到变化），
// 设备侧更是每 15 秒才拉一次心跳（最坏 15 秒才弹窗）。
// 长轮询应该做到「变化发生 → 客户端收到」在百毫秒级。
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.TEST_PORT ?? 8796);
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
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { raw: text };
  }
  return { status: response.status, body: parsed };
}

console.log('=== 长轮询 · 延迟与效率验证 ===');

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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

try {
  const account = (
    await api('POST', '/v1/auth/register', {
      body: { email: 'lp@example.com', password: 'lp-secret-1', name: '长轮询测试' },
    })
  ).body;
  const device = (
    await api('POST', '/v1/devices/register', {
      token: account.token,
      body: { platform: 'macos', deviceName: '长轮询测试机' },
    })
  ).body;
  const { deviceId, sessionToken } = device;

  // ---- 1. 设备侧长轮询：请求创建后多久拿到 ----
  let deviceDeliveredAt = 0;
  const deviceWaitStart = Date.now();
  const devicePoll = api('POST', `/v1/devices/${deviceId}/notifications`, {
    body: { sessionToken, waitSec: 25 },
  }).then((response) => {
    deviceDeliveredAt = Date.now() - deviceWaitStart;
    return response;
  });

  // 等设备端确实挂上（避免请求先于等待者创建）
  await sleep(300);
  const created = (
    await api('POST', '/v1/connect-requests', {
      body: { deviceId, viewerName: '长轮询观看端' },
    })
  ).body;

  const deviceResponse = await devicePoll;
  const delivered = (deviceResponse.body.pendingRequests ?? []).some(
    (item) => item.requestId === created.requestId,
  );
  check('设备侧长轮询：新请求立刻送达', delivered, `用时 ${deviceDeliveredAt}ms`);
  check('设备侧送达耗时 < 1 秒（原来最坏 15 秒）', deviceDeliveredAt < 1000, `${deviceDeliveredAt}ms`);

  // ---- 2. 观看侧长轮询：对方决策后多久拿到结果 ----
  const viewerWaitStart = Date.now();
  const viewerPoll = api('GET', `/v1/connect-requests/${created.requestId}?wait=25`).then(
    (response) => ({ response, elapsed: Date.now() - viewerWaitStart }),
  );

  await sleep(300);
  await api('POST', `/v1/connect-requests/${created.requestId}/decision`, {
    body: { sessionToken, approve: true },
  });

  const { response: viewerResponse, elapsed: viewerElapsed } = await viewerPoll;
  check(
    '观看侧长轮询：同意后立刻拿到房间与令牌',
    viewerResponse.body.status === 'approved' && Boolean(viewerResponse.body.token),
    `用时 ${viewerElapsed}ms`,
  );
  check('观看侧送达耗时 < 1 秒（原来最坏 1.5 秒且空转）', viewerElapsed < 1000, `${viewerElapsed}ms`);

  // ---- 3. 长轮询兼作心跳：等待期间设备保持在线 ----
  const status = await api('GET', `/v1/devices/${deviceId}/status?sessionToken=${sessionToken}`);
  check('长轮询期间设备仍被判在线', status.body.online === true, `online=${status.body.online}`);

  // ---- 3.5 已知道的请求不应让长轮询立刻返回（否则会变成客户端空转） ----
  const second = (
    await api('POST', '/v1/connect-requests', {
      body: { deviceId, viewerName: '空转检测' },
    })
  ).body;
  const spinStart = Date.now();
  const spun = await api('POST', `/v1/devices/${deviceId}/notifications`, {
    body: { sessionToken, waitSec: 2, seen: [second.requestId] },
  });
  const spinElapsed = Date.now() - spinStart;
  check(
    '已知的请求不会让长轮询立刻返回（防空转）',
    spinElapsed > 1500 && (spun.body.pendingRequests ?? []).length === 1,
    `${spinElapsed}ms`,
  );
  await api('DELETE', `/v1/connect-requests/${second.requestId}`);

  // ---- 4. 超时行为：无变化时应按时返回空结果（不能把连接挂死） ----
  const idleStart = Date.now();
  const idle = await api('POST', `/v1/devices/${deviceId}/notifications`, {
    body: { sessionToken, waitSec: 1 },
  });
  const idleElapsed = Date.now() - idleStart;
  check(
    '无变化时按 waitSec 超时返回空列表',
    idle.status === 200 && (idle.body.pendingRequests ?? []).length === 0 && idleElapsed < 2500,
    `${idleElapsed}ms`,
  );
} finally {
  child.kill('SIGTERM');
  await new Promise((resolve) => setTimeout(resolve, 400));
  child.kill('SIGKILL');
}

console.log('');
const failed = results.filter((item) => !item.passed);
console.log(`=== 结果：${results.length - failed.length} / ${results.length} 通过 ===`);
for (const item of failed) console.log(`  未通过：${item.label}`);
process.exit(failed.length ? 1 : 0);
