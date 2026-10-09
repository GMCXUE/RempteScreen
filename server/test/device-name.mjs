// 设备名的归属：用户改过的名字不能被后续注册冲掉。
//
// 背景：客户端每次启动都会注册一次设备并上报自己的默认名，
// 如果注册接口无条件写 name，用户重命名后一重启就被改回去了。
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.TEST_PORT ?? 8792);
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

console.log('=== 设备名归属 · 端到端验证 ===');

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
  const account = (
    await api('POST', '/v1/auth/register', {
      body: { email: 'name@example.com', password: 'name-secret-1', name: '命名测试' },
    })
  ).body;

  // 首次注册：使用上报的默认名
  const first = (
    await api('POST', '/v1/devices/register', {
      token: account.token,
      body: { platform: 'android', deviceName: '默认设备名' },
    })
  ).body;
  const { deviceId, sessionToken } = first;
  check('首次注册采用上报的设备名', first.deviceName === '默认设备名', first.deviceName);

  // 用户重命名
  const renamed = await api('PATCH', `/v1/devices/${deviceId}`, {
    token: account.token,
    body: { name: '我的手机' },
  });
  check('重命名成功', renamed.status === 200, `HTTP ${renamed.status}`);

  let list = ((await api('GET', '/v1/devices', { token: account.token })).body.devices ?? []);
  check('设备列表显示新名字', list[0]?.name === '我的手机', list[0]?.name);

  // 客户端重启：带着 sessionToken 与「默认名」再注册一次
  const again = (
    await api('POST', '/v1/devices/register', {
      token: account.token,
      body: { deviceId, sessionToken, platform: 'android', deviceName: '默认设备名' },
    })
  ).body;
  check('重复注册后名字保持不变（不被覆盖）', again.deviceName === '我的手机', again.deviceName);

  list = ((await api('GET', '/v1/devices', { token: account.token })).body.devices ?? []);
  check('设备列表里仍是用户改的名字', list[0]?.name === '我的手机', list[0]?.name);

  // 新设备仍然使用上报的名字
  const fresh = (
    await api('POST', '/v1/devices/register', {
      token: account.token,
      body: { platform: 'macos', deviceName: '新电脑' },
    })
  ).body;
  check('新设备仍采用上报的名字', fresh.deviceName === '新电脑', fresh.deviceName);
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
