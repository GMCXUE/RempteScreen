// 设备目录服务的客户端封装。
//
// 刻意放在主进程而不是渲染进程：一是避开跨域，二是渲染进程只需要关心音视频，
// 不需要拿到任何凭据。

const config = {
  baseUrl: process.env.REMOTESCREEN_SERVER ?? 'http://127.0.0.1:8787',
};

async function request(method, urlPath, { body, token } = {}) {
  const headers = {};
  if (body) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;

  let response;
  try {
    response = await fetch(`${config.baseUrl}${urlPath}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    });
  } catch (cause) {
    const error = new Error(`连不上设备目录服务（${config.baseUrl}），请确认它已启动`);
    error.code = 'service_unreachable';
    error.cause = cause;
    throw error;
  }

  const text = await response.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = {};
  }

  if (!response.ok) {
    const error = new Error(parsed?.error?.message ?? `请求失败（HTTP ${response.status}）`);
    error.code = parsed?.error?.code ?? 'unknown';
    error.status = response.status;
    error.details = parsed?.error ?? {};
    throw error;
  }
  return parsed;
}

/**
 * 注册设备。需要账号令牌 —— 设备必须归属于某个用户。
 * 同时带上本地持久化的设备凭据，服务端就能认出这是同一台设备。
 */
async function registerDevice({ deviceId, sessionToken, platform, deviceName, accountToken }) {
  return request('POST', '/v1/devices/register', {
    token: accountToken,
    body: { deviceId, sessionToken, platform, deviceName },
  });
}

async function heartbeat(deviceId, sessionToken) {
  return request('POST', `/v1/devices/${deviceId}/heartbeat`, { sessionToken });
}

async function refreshPassword(deviceId, sessionToken) {
  return request('POST', `/v1/devices/${deviceId}/password`, { sessionToken });
}

async function unregister(deviceId, sessionToken) {
  return request('DELETE', `/v1/devices/${deviceId}`, { sessionToken });
}

module.exports = { registerDevice, heartbeat, refreshPassword, unregister, config };
