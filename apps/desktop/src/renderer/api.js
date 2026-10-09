// 与服务端通信的薄封装。
//
// 刻意不依赖 Electron：同一份代码在桌面应用与浏览器里都能跑。
// 服务器地址与账号令牌都放 localStorage —— 浏览器端别无选择，
// 桌面端也就不另做一套，少一条只在某个环境才复现的分支。

window.RSApi = (() => {
  const SERVER_KEY = 'remotescreen.serverUrl';
  const TOKEN_KEY = 'remotescreen.accountToken';

  const stripSlash = (value) => String(value ?? '').replace(/\/+$/, '');

  let serverUrl = null;

  /** 初始化服务器地址：查询参数优先，其次本地记住的，最后用传入的默认值。 */
  function init({ queryServer, fallback }) {
    if (queryServer) localStorage.setItem(SERVER_KEY, stripSlash(queryServer));
    serverUrl = stripSlash(localStorage.getItem(SERVER_KEY)) || stripSlash(fallback);
    return serverUrl;
  }

  function setServerUrl(value) {
    serverUrl = stripSlash(value);
    localStorage.setItem(SERVER_KEY, serverUrl);
    return serverUrl;
  }

  const getServerUrl = () => serverUrl;
  const getToken = () => localStorage.getItem(TOKEN_KEY);

  function setToken(token) {
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  async function request(method, path, { body, auth = true } = {}) {
    const headers = {};
    if (body) headers['Content-Type'] = 'application/json';

    const token = getToken();
    if (auth && token) headers.Authorization = `Bearer ${token}`;

    let response;
    try {
      response = await fetch(`${serverUrl}${path}`, {
        method,
        headers,
        body: body ? JSON.stringify(body) : undefined,
      });
    } catch {
      const error = new Error('连不上服务器，请检查网络与服务器设置');
      error.code = 'network';
      throw error;
    }

    const text = await response.text();
    let parsed = {};
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

      // 令牌失效就地清掉，避免界面一直拿着一个坏令牌重试
      if (response.status === 401 && auth && error.code === 'unauthorized') setToken(null);
      throw error;
    }
    return parsed;
  }

  return {
    init,
    setServerUrl,
    getServerUrl,
    getToken,
    setToken,

    register: (payload) => request('POST', '/v1/auth/register', { body: payload, auth: false }),
    login: (payload) => request('POST', '/v1/auth/login', { body: payload, auth: false }),
    logout: () => request('POST', '/v1/auth/logout'),
    me: () => request('GET', '/v1/me'),

    listDevices: () => request('GET', '/v1/devices'),
    renameDevice: (deviceId, name) => request('PATCH', `/v1/devices/${deviceId}`, { body: { name } }),

    connect: (payload) => request('POST', '/v1/connect', { body: payload }),
  };
})();
