// RemoteScreen 桌面端 —— 主进程
//
// 一个窗口承载两种能力：左侧「本机」展示设备 ID 与采集设置，右侧「连接」用于观看其他设备。
// 不需要切换角色、不需要开第二个窗口。
//
// 主进程负责渲染层拿不到的部分：采集源枚举、屏幕捕获授权、凭据持久化、设备目录服务调用与心跳。

const { app, BrowserWindow, desktopCapturer, ipcMain, session, systemPreferences } = require('electron');
const path = require('node:path');
const os = require('node:os');

const deviceStore = require('./device-store');
const deviceClient = require('./device-client');

const argv = process.argv;
const hasFlag = (name) => argv.includes(`--${name}`);

/** 读取 --name=value 形式的启动参数。 */
function argValue(name, fallback = null) {
  const prefix = `--${name}=`;
  const found = argv.find((value) => value.startsWith(prefix));
  return found ? found.slice(prefix.length) : fallback;
}

const captureSelfTest = hasFlag('self-test');
const viewerSelfTest = hasFlag('self-test-viewer');
const isSelfTest = captureSelfTest || viewerSelfTest;
const isMac = process.platform === 'darwin';
const defaultServerUrl = process.env.REMOTESCREEN_SERVER ?? 'http://127.0.0.1:8787';

app.setName('RemoteScreen');

// 自检会真实登录并注册设备，从而在本地留下账号令牌与设备凭据。
// 给它一个独立的数据目录，否则自检跑完用户打开应用会发现自己"已经是登录状态"。
// 用固定路径而不是随机路径，是为了让多次自检复用同一台设备，不在库里堆设备。
if (isSelfTest) {
  app.setPath('userData', path.join(os.tmpdir(), 'remotescreen-selftest'));
}

/** 自检时保持推流的秒数，可用 --hold=45 覆盖。 */
function selfTestHoldSeconds() {
  const seconds = Number(argValue('hold'));
  return Number.isFinite(seconds) && seconds > 0 ? Math.min(seconds, 600) : 12;
}

/** 自检时透传给渲染层的参数。 */
function buildQuery() {
  if (viewerSelfTest) {
    return {
      'selftest-viewer': '1',
      server: argValue('server', defaultServerUrl),
      device: argValue('device', ''),
      password: argValue('password', ''),
    };
  }

  if (captureSelfTest) {
    const query = { selftest: '1', hold: String(selfTestHoldSeconds()) };
    for (const key of ['resolution', 'framerate', 'quality', 'codec', 'bitrate']) {
      const value = argValue(key);
      if (value) query[key] = value;
    }
    return query;
  }

  return { server: argValue('server', defaultServerUrl) };
}

let mainWindow = null;
let heartbeatTimer = null;
let currentSession = null;

// 渲染进程通过 IPC 预先告知「要采集哪个源、要不要系统声音」。
// setDisplayMediaRequestHandler 是同步回调，拿不到渲染进程的实时参数，只能这样传递。
const pendingCapture = { sourceId: null, wantSystemAudio: true };

// MARK: - 屏幕捕获授权

function screenPermissionStatus() {
  if (!isMac) return 'granted';
  try {
    return systemPreferences.getMediaAccessStatus('screen');
  } catch {
    return 'unknown';
  }
}

// MARK: - 采集源

async function listSources({ withThumbnails }) {
  const sources = await desktopCapturer.getSources({
    types: ['screen', 'window'],
    thumbnailSize: withThumbnails ? { width: 320, height: 200 } : { width: 0, height: 0 },
    fetchWindowIcons: false,
  });

  return sources.map((source) => ({
    id: source.id,
    name: source.name,
    // screen:<displayId>:<windowId>，window 源形如 window:<windowId>:<title>
    kind: source.id.startsWith('screen:') ? 'screen' : 'window',
    thumbnail: withThumbnails && !source.thumbnail.isEmpty() ? source.thumbnail.toDataURL() : null,
  }));
}

function installDisplayMediaHandler() {
  session.defaultSession.setDisplayMediaRequestHandler(
    async (request, callback) => {
      try {
        const sources = await desktopCapturer.getSources({
          types: ['screen', 'window'],
          thumbnailSize: { width: 0, height: 0 },
        });

        const source = sources.find((item) => item.id === pendingCapture.sourceId) ?? sources[0];
        if (!source) {
          callback({});
          return;
        }

        // audio: 'loopback' 目前只有 Windows 可用，macOS 传了会直接抛错，
        // 所以按平台决定要不要带音频，而不是无脑传。
        const wantsAudio = pendingCapture.wantSystemAudio && !isMac;
        callback(wantsAudio ? { video: source, audio: 'loopback' } : { video: source });
      } catch (error) {
        console.error('[capture] 选择采集源失败：', error);
        callback({});
      }
    },
    { useSystemPicker: false },
  );
}

// MARK: - 心跳

function stopHeartbeat() {
  if (heartbeatTimer) {
    clearInterval(heartbeatTimer);
    heartbeatTimer = null;
  }
}

function startHeartbeat(intervalSec) {
  stopHeartbeat();
  const period = Math.max(5, intervalSec || 15) * 1000;
  heartbeatTimer = setInterval(async () => {
    if (!currentSession) return;
    try {
      await deviceClient.heartbeat(currentSession.deviceId, currentSession.sessionToken);
      mainWindow?.webContents.send('session:heartbeat', { at: Date.now() });
    } catch (error) {
      mainWindow?.webContents.send('session:error', {
        scope: 'heartbeat',
        message: error.message,
        code: error.code,
      });
    }
  }, period);
}

// MARK: - 窗口

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1180,
    height: 820,
    minWidth: 480,
    minHeight: 560,
    show: !isSelfTest,
    title: 'RemoteScreen',
    backgroundColor: '#0b0d11',
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'index.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  mainWindow.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'), { query: buildQuery() });

  if (isSelfTest) {
    // Electron 44 起 console-message 改为事件对象，这里同时兼容新旧签名
    mainWindow.webContents.on('console-message', (event, _level, message) => {
      const text = event && typeof event === 'object' && event.message ? event.message : message;
      console.log(`[renderer] ${text}`);
    });
  }

  mainWindow.on('closed', () => { mainWindow = null; });
}

// MARK: - IPC

function registerIpc() {
  ipcMain.handle('platform:info', () => ({
    platform: process.platform,
    // 系统声音采集依赖 WASAPI loopback，目前仅 Windows 具备
    systemAudioSupported: !isMac,
    screenPermission: screenPermissionStatus(),
    electronVersion: process.versions.electron,
    serverUrl: deviceClient.config.baseUrl,
  }));

  ipcMain.handle('sources:list', () => listSources({ withThumbnails: true }));

  ipcMain.handle('capture:prepare', (_event, options) => {
    pendingCapture.sourceId = options?.sourceId ?? null;
    pendingCapture.wantSystemAudio = options?.wantSystemAudio !== false;
    return { ok: true, systemAudioWillBeRequested: pendingCapture.wantSystemAudio && !isMac };
  });

  ipcMain.handle('session:register', async (_event, payload) => {
    const accountToken = payload?.accountToken;
    if (!accountToken) {
      const error = new Error('请先登录');
      error.code = 'unauthorized';
      throw error;
    }

    const stored = deviceStore.load();
    const result = await deviceClient.registerDevice({
      deviceId: stored.deviceId,
      sessionToken: stored.sessionToken,
      platform: process.platform,
      deviceName: payload?.deviceName || os.hostname(),
      accountToken,
    });

    // 服务端每次都会轮换 sessionToken，必须覆盖写入
    deviceStore.save({ deviceId: result.deviceId, sessionToken: result.sessionToken });

    currentSession = {
      deviceId: result.deviceId,
      sessionToken: result.sessionToken,
      password: result.password,
      roomName: result.roomName,
      livekitUrl: result.livekitUrl,
      token: result.token,
      identity: result.identity,
    };

    startHeartbeat(result.heartbeatIntervalSec);

    return {
      deviceId: result.deviceId,
      password: result.password,
      reusedDeviceId: result.reusedDeviceId,
      deviceName: result.deviceName,
      roomName: result.roomName,
      identity: result.identity,
      heartbeatIntervalSec: result.heartbeatIntervalSec,
    };
  });

  ipcMain.handle('session:credentials', () => {
    if (!currentSession) return null;
    // 令牌只在这一个通道里交给渲染进程，用于连 LiveKit
    return {
      deviceId: currentSession.deviceId,
      password: currentSession.password,
      roomName: currentSession.roomName,
      livekitUrl: currentSession.livekitUrl,
      token: currentSession.token,
      identity: currentSession.identity,
    };
  });

  ipcMain.handle('session:refreshPassword', async () => {
    if (!currentSession) throw new Error('尚未注册设备');
    const result = await deviceClient.refreshPassword(currentSession.deviceId, currentSession.sessionToken);
    currentSession.password = result.password;
    return { password: result.password };
  });

  ipcMain.handle('session:unregister', async () => {
    if (!currentSession) return { ok: true };
    stopHeartbeat();
    try {
      await deviceClient.unregister(currentSession.deviceId, currentSession.sessionToken);
    } finally {
      currentSession = null;
      deviceStore.save({ deviceId: null, sessionToken: null });
    }
    return { ok: true };
  });

  // 投送端自检：渲染进程跑完流程后回报结果，主进程打印并退出
  ipcMain.handle('selftest:report', (_event, report) => {
    console.log(`SELFTEST_RESULT=${JSON.stringify(report)}`);
    stopHeartbeat();
    setTimeout(() => app.exit(report?.passed ? 0 : 1), 100);
    return { ok: true };
  });
}

// MARK: - 生命周期

app.whenReady().then(() => {
  installDisplayMediaHandler();
  registerIpc();
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  // 自检模式下窗口一关就退出，方便脚本化调用
  if (process.platform !== 'darwin' || isSelfTest) app.quit();
});

app.on('before-quit', () => {
  stopHeartbeat();
});
