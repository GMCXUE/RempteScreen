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

  // 连接密码：设备本人可自定义，账号主人改不了别台设备。
  // 注意：每次注册都会轮换 sessionToken，必须用**最新**的那个。
  const currentToken = again.sessionToken;
  const custom = await api('POST', `/v1/devices/${deviceId}/password`, {
    body: { sessionToken: currentToken, password: 'my-pass-8888' },
  });
  check('设备可自定义连接密码', custom.status === 200 && custom.body.password === 'my-pass-8888',
    custom.body.password);

  // 关键：客户端重启会重新注册 —— 自定义密码必须跟着设备保留下来
  const restart = await api('POST', '/v1/devices/register', {
    token: account.token,
    body: { deviceId, sessionToken: currentToken, platform: 'android', deviceName: '默认设备名' },
  });
  check('重启注册后自定义密码保持不变（密码跟随设备）',
    restart.body.password === 'my-pass-8888', restart.body.password);

  // 后续调用一律用**最新**的凭据（每次注册都会轮换 sessionToken）
  const liveToken = restart.body.sessionToken;

  const tooShort = await api('POST', `/v1/devices/${deviceId}/password`, {
    body: { sessionToken: liveToken, password: 'ab' },
  });
  check('过短的密码被拒绝', tooShort.status === 400 && tooShort.body.error?.code === 'invalid_password');

  const withSpace = await api('POST', `/v1/devices/${deviceId}/password`, {
    body: { sessionToken: liveToken, password: 'has space' },
  });
  check('含空格的密码被拒绝', withSpace.status === 400);

  const byOwner = await api('POST', `/v1/devices/${deviceId}/password`, {
    token: account.token,
    body: { password: 'owner-wants-this' },
  });
  check('账号主人不能改这台设备的密码（需设备凭据）', byOwner.status === 401, `HTTP ${byOwner.status}`);

  const stale = await api('POST', `/v1/devices/${deviceId}/password`, {
    body: { sessionToken: currentToken, password: 'stale-token-pass' },
  });
  check('旧 sessionToken 已失效（轮换后不可用）', stale.status === 401, `HTTP ${stale.status}`);

  const rotated = await api('POST', `/v1/devices/${deviceId}/password`, {
    body: { sessionToken: liveToken },
  });
  check('不带自定义值时随机刷新', rotated.status === 200 && rotated.body.password !== 'my-pass-8888',
    rotated.body.password);

  // 账号主人解绑（用于清理离线/已卸载的旧设备）
  const detached = await api('DELETE', `/v1/devices/${fresh.deviceId}`, { token: account.token });
  check('账号主人可解绑设备', detached.status === 200 && detached.body.removed === true, `by=${detached.body.by}`);

  list = ((await api('GET', '/v1/devices', { token: account.token })).body.devices ?? []);
  check('解绑后列表里不再有该设备', !list.some((item) => item.deviceId === fresh.deviceId));

  // 别人的设备不能被解绑
  const other = (
    await api('POST', '/v1/auth/register', {
      body: { email: 'other@example.com', password: 'other-secret-1', name: '别人' },
    })
  ).body;
  const foreign = await api('DELETE', `/v1/devices/${deviceId}`, { token: other.token });
  check('不能解绑别人的设备', foreign.status === 404, `HTTP ${foreign.status}`);

  // 无任何凭据时也不能解绑
  const anonymous = await api('DELETE', `/v1/devices/${deviceId}`);
  check('无凭据不能解绑', anonymous.status === 401, `HTTP ${anonymous.status}`);
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
