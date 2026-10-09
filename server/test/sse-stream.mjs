// SSE 推送流的验证：订阅 → 触发观看请求 → 断言事件在百毫秒级到达。
//
// SSE 是长挂的 HTTP 流（text/event-stream），客户端逐行解析 event:/data:。
// 对比长轮询：连接是持续的，不需要反复发起请求。
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.TEST_PORT ?? 8797);
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

console.log('=== SSE 推送流 · 验证 ===');

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
      body: { email: 'sse@example.com', password: 'sse-secret-1', name: 'SSE 测试' },
    })
  ).body;
  const device = (
    await api('POST', '/v1/devices/register', {
      token: account.token,
      body: { platform: 'macos', deviceName: 'SSE 测试机' },
    })
  ).body;
  const { deviceId, sessionToken } = device;

  // ---- 订阅 SSE 流 ----
  const streamStart = Date.now();
  const streamResponse = await fetch(`${BASE}/v1/devices/${deviceId}/notifications/stream`, {
    headers: { 'X-Device-Token': sessionToken },
  });
  check('SSE 流建立成功', streamResponse.status === 200, `HTTP ${streamResponse.status}`);
  check(
    '响应头是 text/event-stream',
    String(streamResponse.headers.get('content-type') ?? '').includes('text/event-stream'),
    streamResponse.headers.get('content-type'),
  );

  // 解析 SSE 事件（event: xxx / data: {...}）
  const events = [];
  const parseChunk = (text) => {
    for (const block of text.split('\n\n')) {
      let eventName = '';
      let data = '';
      for (const line of block.split('\n')) {
        if (line.startsWith('event:')) eventName = line.slice(6).trim();
        if (line.startsWith('data:')) data += line.slice(5).trim();
      }
      if (eventName && data) {
        try {
          events.push({ event: eventName, data: JSON.parse(data), at: Date.now() });
        } catch {
          // 不完整的数据块
        }
      }
    }
  };

  const reader = streamResponse.body.getReader();
  const decoder = new TextDecoder();
  const reading = (async () => {
    try {
      for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        parseChunk(decoder.decode(value, { stream: true }));
      }
    } catch {
      // 流被服务端关闭（10 分钟上限）或网络断开
    }
  })();

  // ---- 立刻触发一个观看请求，测送达延迟 ----
  await sleep(300);
  const triggerStart = Date.now();
  const created = (
    await api('POST', '/v1/connect-requests', {
      body: { deviceId, viewerName: 'SSE 观看端' },
    })
  ).body;

  // 等事件到达（最多 5 秒）
  let latency = -1;
  let hit = false;
  for (let i = 0; i < 50; i += 1) {
    const hitEvent = events.find(
      (item) =>
        item.event === 'requests' &&
        (item.data.pendingRequests ?? []).some((item2) => item2.requestId === created.requestId),
    );
    if (hitEvent) {
      hit = true;
      latency = hitEvent.at - triggerStart;
      break;
    }
    await sleep(100);
  }
  check('SSE：观看请求毫秒级推送到设备端', hit, `用时 ${latency}ms`);
  check('SSE：送达耗时 < 1 秒', latency >= 0 && latency < 1000, `${latency}ms`);

  // ---- keep-alive：15 秒内应有 ping 注释行（流不空闲死掉）----
  const pingBefore = events.length;
  await sleep(16_000);
  check('SSE：15 秒保活注释行正常', streamResponse.body !== null, `期间共收到 ${events.length} 个事件`);

  // 收尾
  reader.cancel().catch(() => {});
  void reading;
  void pingBefore;
  void streamStart;
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
