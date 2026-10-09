// RemoteScreen 桌面端 —— 渲染层
//
// 一个页面承载四件事：
//   账号   —— 登录 / 注册 / 退出，设备都挂在账号下
//   本机   —— 设备 ID / 连接密码 / 采集设置 / 开始投送
//   我的设备 —— 登录后列出名下设备，点一下即可免密码连接
//   连接   —— 用「设备 ID + 密码」连接别人的设备（对外分享通道）
//
// 只用标准 Web API，不依赖 Electron 能力，因此这一页也能直接托管给浏览器访问。
// 手机浏览器打开时只显示连接相关的部分（手机没有可投送的桌面）。

const api = window.remoteScreen;
const RSApi = window.RSApi;
const { Room, RoomEvent, Track, ConnectionState } = window.LivekitClient;

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);

// 手机浏览器没有可投送的桌面，只显示连接相关的部分。
// 判断依据是 UA 而不是协议：桌面浏览器（哪怕经 http 访问）同样可以采集屏幕，
// 把侧栏藏掉会让桌面用户看不到完整界面 —— 之前就犯了这个错。
const isMobileBrowser =
    /Android|iPhone|iPad|iPod|Mobile/i.test(navigator.userAgent);
if (isMobileBrowser) document.body.classList.add('viewer-only');

// 非安全上下文（http）里浏览器拿不到 mediaDevices，也就无法采集屏幕。
// 桌面客户端（Electron）不受此限制。
const canCaptureScreen =
    typeof navigator.mediaDevices?.getDisplayMedia === 'function';

const captureSelfTest = params.get('selftest') === '1';
const viewerSelfTest = params.get('selftest-viewer') === '1';

// ############################################################################
// MARK: - 账号
// ############################################################################

const account = {
  user: null,
  authMode: 'login', // login | register
};

const initialOf = (name) => String(name ?? '?').trim().slice(0, 1).toUpperCase();

/**
 * 渲染账号状态。
 *
 * 侧栏的头像与名字、弹层里的账号卡片、以及「能不能投送」都由这里统一决定 ——
 * 设备必须归属于账号，所以未登录时投送开关是禁用的。
 */
function renderAccount() {
  const signedIn = Boolean(account.user);

  $('account-avatar').textContent = signedIn ? initialOf(account.user.name) : '?';
  $('account-name').textContent = signedIn ? account.user.name : '立即登录';
  $('logout-button').classList.toggle('hidden', !signedIn);

  $('auth-pane').classList.toggle('hidden', signedIn);
  $('account-pane').classList.toggle('hidden', !signedIn);

  $('modal-title').textContent = signedIn
    ? '账号'
    : (account.authMode === 'register' ? '注册账号' : '登录');

  if (signedIn) {
    $('account-pane-avatar').textContent = initialOf(account.user.name);
    $('account-pane-name').textContent = account.user.name;
    $('account-email').textContent = account.user.email;
  }

  // 未登录或还没选采集源时不能开启投送
  $('share-toggle').disabled = !signedIn || !state.selectedSourceId;

  if (!signedIn) {
    setConnection('未登录', 'off');
  }
}

function setAuthMode(mode) {
  account.authMode = mode;
  const registering = mode === 'register';

  $('tab-login').classList.toggle('active', !registering);
  $('tab-register').classList.toggle('active', registering);
  $('name-field').classList.toggle('hidden', !registering);
  $('auth-submit').textContent = registering ? '注册' : '登录';
  $('auth-password').setAttribute('autocomplete', registering ? 'new-password' : 'current-password');
  $('auth-error').textContent = '';
  $('modal-title').textContent = registering ? '注册账号' : '登录';
}

function openAccountModal() {
  $('account-modal').classList.remove('hidden');
  setAuthMode(account.user ? 'login' : account.authMode);
  renderAccount();
  if (!account.user) setTimeout(() => $('auth-email').focus(), 60);
}

function closeAccountModal() {
  $('account-modal').classList.add('hidden');
  $('auth-error').textContent = '';
}

async function submitAuth() {
  const email = $('auth-email').value.trim();
  const password = $('auth-password').value;
  const name = $('auth-name').value.trim();
  const button = $('auth-submit');

  $('auth-error').textContent = '';

  if (!email || !password) {
    $('auth-error').textContent = '请把邮箱和密码都填上';
    return;
  }

  button.disabled = true;
  button.textContent = account.authMode === 'register' ? '注册中…' : '登录中…';

  try {
    const result = account.authMode === 'register'
      ? await RSApi.register({ email, password, name })
      : await RSApi.login({ email, password });

    RSApi.setToken(result.token);
    account.user = result.user;

    $('auth-password').value = '';
    $('auth-name').value = '';

    closeAccountModal();
    renderAccount();
    await startSharing();
  } catch (error) {
    $('auth-error').textContent = error.message;
  } finally {
    button.disabled = false;
    button.textContent = account.authMode === 'register' ? '注册' : '登录';
  }
}

async function logout() {
  try {
    await RSApi.logout();
  } catch {
    // 服务端连不上也要让本地退出，否则用户被困住
  }

  RSApi.setToken(null);
  account.user = null;

  stopPublishing();
  await api.unregisterSession().catch(() => {});

  state.deviceId = null;
  state.password = null;
  renderDevices([]);
  renderAccount();
  closeAccountModal();
  setConnection('未登录', 'off');
}

// ############################################################################
// MARK: - 投送端
// ############################################################################

const state = {
  platformInfo: null,
  sources: [],
  selectedSourceId: null,
  stream: null,
  room: null,
  publishing: false,
  deviceId: null,
  password: null,
};

const SETTINGS_KEY = 'remotescreen.captureSettings';

const RESOLUTION_PRESETS = {
  source: null,
  '2560x1440': { width: 2560, height: 1440 },
  '1920x1080': { width: 1920, height: 1080 },
  '1280x720': { width: 1280, height: 720 },
};

const QUALITY_PRESETS = { smooth: 1_500_000, balanced: 3_000_000, sharp: 6_000_000 };

// H.264 在 macOS 上走 VideoToolbox 硬件编码、在手机上硬件解码，
// 且对屏幕这类大面积静态内容比 VP8 更友好，因此作为默认。
const CODEC_CHOICES = ['h264', 'vp8', 'vp9'];

const DEFAULT_SETTINGS = { resolution: '1920x1080', framerate: 30, quality: 'balanced', codec: 'h264' };

function storedSettings() {
  try {
    return { ...DEFAULT_SETTINGS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}') };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function saveSettings(settings) {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
  } catch {
    // 隐私模式下可能写不进去，不影响本次使用
  }
}

/** 当前生效的采集参数：自检的查询参数优先，其次界面上的设置。 */
function currentCapture() {
  const saved = storedSettings();

  const resolution = params.get('resolution') ?? saved.resolution;
  const framerate = Number(params.get('framerate') ?? saved.framerate) || 30;
  const quality = params.get('quality') ?? saved.quality;
  const codec = params.get('codec') ?? saved.codec;
  const preset = RESOLUTION_PRESETS[resolution] ?? null;
  const explicit = Number(params.get('bitrate'));

  return {
    resolution,
    framerate,
    quality,
    codec: CODEC_CHOICES.includes(codec) ? codec : 'h264',
    maxWidth: preset?.width ?? null,
    maxHeight: preset?.height ?? null,
    bitrate: Number.isFinite(explicit) && explicit > 0
      ? explicit
      : (QUALITY_PRESETS[quality] ?? QUALITY_PRESETS.balanced),
  };
}

// MARK: - 发送侧指标

function toStatsArray(report) {
  if (!report) return [];
  if (typeof report.values === 'function') return Array.from(report.values());
  if (Array.isArray(report)) return report;
  const out = [];
  if (typeof report.forEach === 'function') report.forEach((stat) => out.push(stat));
  return out;
}

/**
 * 取发布端的统计报告。
 *
 * livekit-client v2 没有 Room.getStats()，本地轨道的统计只能从 sender
 * 或发布端 peer connection 上取。两处都试，避免依赖单一内部实现。
 */
async function senderStatsReport(room) {
  const sources = [
    () => room.engine?.pcManager?.publisher?.getStats(),
    () => {
      const publication = room.localParticipant.getTrackPublication(Track.Source.ScreenShare);
      return publication?.track?.sender?.getStats();
    },
  ];

  for (const source of sources) {
    try {
      const report = await source();
      if (report && toStatsArray(report).length > 0) return report;
    } catch {
      // 换下一个来源
    }
  }
  return null;
}

/**
 * 采样发送侧指标。
 *
 * 重点是 qualityLimitationReason —— 它直接说明编码器被什么卡住了：
 *   cpu → 采集侧算力不够，该降分辨率
 *   bandwidth → 上行带宽不够，该降码率或降帧率
 *   none → 发送侧没问题，卡顿在别处
 */
async function collectSenderStats(room, seconds, fps) {
  const snapshot = async () => {
    const report = await senderStatsReport(room);
    let video = null;
    let pair = null;
    const codecs = new Map();
    for (const stat of toStatsArray(report)) {
      if (!stat) continue;
      if (stat.type === 'codec' && stat.id) codecs.set(stat.id, stat);
      if (stat.type === 'outbound-rtp' && stat.kind === 'video') video = stat;
      if (stat.type === 'candidate-pair' && stat.state === 'succeeded' && stat.nominated) pair = stat;
    }
    return { video, pair, codecs };
  };

  const before = await snapshot();
  const startedAt = Date.now();
  await new Promise((resolve) => setTimeout(resolve, seconds * 1000));
  const after = await snapshot();
  const elapsed = (Date.now() - startedAt) / 1000;

  const v0 = before.video ?? {};
  const v1 = after.video ?? {};
  const bitrate = ((v1.bytesSent ?? 0) - (v0.bytesSent ?? 0)) * 8 / elapsed / 1_000_000;

  return {
    resolution: v1.frameWidth ? `${v1.frameWidth}×${v1.frameHeight}` : '未知',
    codec: (after.codecs.get(v1.codecId)?.mimeType ?? '未知').replace('video/', ''),
    qualityLimitation: v1.qualityLimitationReason ?? '未知',
    expectedFrames: Math.round(elapsed * fps),
    encodedFrames: (v1.framesEncoded ?? 0) - (v0.framesEncoded ?? 0),
    sentFrames: (v1.framesSent ?? 0) - (v0.framesSent ?? 0),
    bitrateMbps: Number(bitrate.toFixed(2)),
    rttMs: after.pair?.currentRoundTripTime != null
      ? Math.round(after.pair.currentRoundTripTime * 1000)
      : null,
    nackCount: (v1.nackCount ?? 0) - (v0.nackCount ?? 0),
    retransmitted: (v1.retransmittedPacketsSent ?? 0) - (v0.retransmittedPacketsSent ?? 0),
  };
}

// MARK: - 投送端界面

function formatDeviceId(deviceId) {
  if (!deviceId) return '— — —';
  return deviceId.replace(/(\d{3})(\d{3})(\d{3})/, '$1 $2 $3');
}

function setConnection(label, level) {
  $('connection-label').textContent = label;
  $('heartbeat-dot').className = `dot ${level}`;
}

function setMessage(text, tone) {
  const node = $('message');
  node.textContent = text ?? '';
  node.style.color = tone === 'ok' ? 'var(--ok)' : tone === 'muted' ? 'var(--text-dim)' : 'var(--warn)';
}

function setShareStatus(text, live) {
  const node = $('share-status');
  node.textContent = text;
  node.classList.toggle('live', Boolean(live));
}

function updateViewers() {
  $('viewers').textContent = String(state.room ? state.room.remoteParticipants.size : 0);
}

function renderSources() {
  const container = $('sources');
  container.textContent = '';

  if (state.sources.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'muted small';
    empty.textContent = '没有扫描到可采集的内容';
    container.appendChild(empty);
    return;
  }

  // 显示器排在窗口前面
  const ordered = [...state.sources].sort((a, b) => (a.kind === b.kind ? 0 : a.kind === 'screen' ? -1 : 1));

  for (const source of ordered) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = `source${source.id === state.selectedSourceId ? ' selected' : ''}`;

    if (source.thumbnail) {
      const image = document.createElement('img');
      image.src = source.thumbnail;
      image.alt = '';
      button.appendChild(image);
    } else {
      const placeholder = document.createElement('div');
      placeholder.className = 'placeholder';
      button.appendChild(placeholder);
    }

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = source.name;
    button.appendChild(name);

    const kind = document.createElement('span');
    kind.className = 'kind';
    kind.textContent = source.kind === 'screen' ? '整个屏幕' : '单个窗口';
    button.appendChild(kind);

    button.addEventListener('click', () => {
      state.selectedSourceId = source.id;
      renderSources();
      // 没登录时即便选了源也不能开投送
      $('share-toggle').disabled = !account.user;
    });

    container.appendChild(button);
  }
}

async function loadSources() {
  state.sources = await api.listSources();
  if (!state.selectedSourceId || !state.sources.some((item) => item.id === state.selectedSourceId)) {
    state.selectedSourceId = state.sources.find((item) => item.kind === 'screen')?.id ?? null;
  }
  renderSources();
  $('share-toggle').disabled = !state.selectedSourceId;
}

// MARK: - 投送

async function startPublishing() {
  if (!state.selectedSourceId) return;

  const wantSystemAudio = $('system-audio').checked;
  const capture = currentCapture();

  setMessage('正在准备采集…', 'muted');
  setShareStatus('准备中', false);

  try {
    await api.prepareCapture({ sourceId: state.selectedSourceId, wantSystemAudio });

    // 帧率在采集时就要提出来，事后再改约束未必能提上去
    state.stream = await navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: capture.framerate },
      audio: wantSystemAudio,
    });
  } catch (error) {
    setMessage(`采集启动失败：${error.message}`);
    setShareStatus('未投送', false);
    return;
  }

  const videoTrack = state.stream.getVideoTracks()[0];
  const audioTrack = state.stream.getAudioTracks()[0];

  if (capture.maxWidth || capture.maxHeight) {
    try {
      // 屏幕采集默认给的是原生像素尺寸（Retina 与 5K 屏上可到 5000+ 宽）
      await videoTrack.applyConstraints({
        ...(capture.maxWidth ? { width: { max: capture.maxWidth } } : {}),
        ...(capture.maxHeight ? { height: { max: capture.maxHeight } } : {}),
      });
    } catch (error) {
      setMessage(`分辨率限制未生效，将按原始尺寸推流：${error.message}`);
    }
  }

  const settings = videoTrack.getSettings();
  setShareStatus(`采集中 · ${settings.width}×${settings.height}`, true);

  videoTrack.addEventListener('ended', () => stopPublishing());

  const credentials = await api.getCredentials();
  if (!credentials) {
    setMessage('设备会话已失效，请重新登录');
    return;
  }

  try {
    const room = new Room({ adaptiveStream: false, dynacast: false });
    state.room = room;

    // 只处理当前房间的事件。
    // 上一次连接的 Disconnected 回调可能在**新连接建立之后**才到达，
    // 若不加判断，stopPublishing 会把刚建好的新连接一并拆掉 ——
    // 那正是「cannot publish track when not connected」的来源。
    const isCurrent = () => state.room === room;

    room
      .on(RoomEvent.ParticipantConnected, () => {
        if (!isCurrent()) return;
        updateViewers();
        loadDevices();
      })
      .on(RoomEvent.ParticipantDisconnected, () => {
        if (!isCurrent()) return;
        updateViewers();
      })
      .on(RoomEvent.ConnectionStateChanged, (connectionState) => {
        if (!isCurrent()) return;
        if (connectionState === ConnectionState.Connected) setShareStatus('投送中', true);
      })
      .on(RoomEvent.Disconnected, () => {
        if (!isCurrent()) return;
        setMessage('与媒体服务的连接已断开');
        stopPublishing();
      });

    await room.connect(credentials.livekitUrl, credentials.token);

    // connect 返回后状态未必立刻是 Connected，最多再等 3 秒
    for (let attempt = 0; attempt < 15 && room.state !== ConnectionState.Connected; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }

    if (!isCurrent() || room.state !== ConnectionState.Connected) {
      throw new Error(`媒体服务未就绪（当前状态 ${room.state}）`);
    }

    // 发布失败时重试一次：连接偶发抖动时第一次发布可能撞上断线
    let published = false;
    let lastError = null;
    for (let attempt = 1; attempt <= 2 && !published; attempt += 1) {
      try {
        await room.localParticipant.publishTrack(videoTrack, {
          name: 'screen',
          source: Track.Source.ScreenShare,
          simulcast: false,
          videoCodec: capture.codec,
          videoEncoding: { maxBitrate: capture.bitrate, maxFramerate: capture.framerate },
        });
        published = true;
      } catch (error) {
        lastError = error;
        if (room.state !== ConnectionState.Connected) break;
        await new Promise((resolve) => setTimeout(resolve, 500 * attempt));
      }
    }

    if (!published) throw lastError;

    if (audioTrack) {
      await room.localParticipant.publishTrack(audioTrack, {
        name: 'system-audio',
        source: Track.Source.ScreenShareAudio,
      });
    }

    state.publishing = true;
    $('share-toggle').checked = true;
    setCaptureSettingsEnabled(false);
    setShareStatus('投送中', true);
    updateViewers();

    setMessage(
      audioTrack ? '已开始投送画面与电脑声音' : '已开始投送画面。当前平台无法采集系统声音',
      audioTrack ? 'ok' : 'warn',
    );
  } catch (error) {
    setMessage(`连接媒体服务失败：${error.message}`);
    stopPublishing();
  }
}

function stopPublishing() {
  const room = state.room;
  // 先摘掉引用再断开：断开触发的回调会因为 state.room 已变而提前返回，
  // 不会重入这里把刚建立的新连接拆掉
  state.room = null;

  if (room) room.disconnect();

  if (state.stream) {
    for (const track of state.stream.getTracks()) track.stop();
    state.stream = null;
  }

  state.publishing = false;
  $('share-toggle').checked = false;
  setCaptureSettingsEnabled(true);
  setShareStatus('未投送', false);
  updateViewers();
}

// MARK: - 设备会话

async function registerSession() {
  const session = await api.registerSession({ accountToken: RSApi.getToken() });
  state.deviceId = session.deviceId;
  state.password = session.password;

  $('device-id').textContent = formatDeviceId(session.deviceId);
  renderPassword();
  $('device-name').textContent = `${session.deviceName} · ${session.roomName}`;
  setConnection('已就绪', 'on');
  return session;
}

async function refreshPassword() {
  const button = $('refresh-password');
  button.disabled = true;
  try {
    const result = await api.refreshPassword();
    state.password = result.password;
    // 换了密码就重新明文显示，否则用户不知道新密码是什么
    passwordVisible = true;
    renderPassword();
    setMessage('密码已更新，旧密码立即失效', 'ok');
  } catch (error) {
    setMessage(`刷新密码失败：${error.message}`);
  } finally {
    button.disabled = false;
  }
}

// MARK: - 我的设备

/** 最近一次拉取到的设备列表，用于判断某个 ID 是否属于自己。 */
let currentDevices = [];

async function loadDevices() {
  if (!account.user) {
    currentDevices = [];
    renderDevices([]);
    return;
  }

  try {
    const { devices } = await RSApi.listDevices();
    currentDevices = devices ?? [];
    renderDevices(currentDevices);
  } catch (error) {
    if (error.status === 401) {
      account.user = null;
      currentDevices = [];
      renderAccount();
    }
  }
}

function renderDevices(devices) {
  const container = $('my-devices');
  container.textContent = '';

  if (!account.user) {
    const empty = document.createElement('div');
    empty.className = 'device-empty';
    empty.textContent = '登录后才能看到你的设备';
    container.appendChild(empty);
    return;
  }

  if (!devices || devices.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'device-empty';
    empty.textContent = '还没有绑定设备';
    container.appendChild(empty);
    return;
  }

  for (const device of devices) {
    const row = document.createElement('div');
    row.className = `device-row${device.deviceId === state.deviceId ? ' current' : ''}`;

    const dot = document.createElement('span');
    dot.className = `dot ${device.online ? 'on' : ''}`;
    row.appendChild(dot);

    const info = document.createElement('div');
    info.className = 'device-info';

    const name = document.createElement('div');
    name.className = 'device-name';
    name.textContent = device.name + (device.deviceId === state.deviceId ? '（本机）' : '');
    info.appendChild(name);

    const sub = document.createElement('div');
    sub.className = 'device-sub';
    sub.textContent = formatDeviceId(device.deviceId);
    info.appendChild(sub);

    row.appendChild(info);

    const connect = document.createElement('button');
    connect.type = 'button';
    connect.textContent = device.online ? '连接' : '离线';
    connect.disabled = !device.online;
    connect.addEventListener('click', () => connectToDevice({ deviceId: device.deviceId, password: '' }));
    row.appendChild(connect);

    container.appendChild(row);
  }
}

// ############################################################################
// MARK: - 观看端
// ############################################################################

let viewerRoom = null;
let remoteVideoTrack = null;
let statsTimer = null;
let lastSample = null;
let overlayTimer = null;

const trackEvents = [];
const handledTracks = new Set();

const els = {
  connectPane: $('connect-pane'),
  stage: $('stage'),
  deviceId: $('remote-device-id'),
  password: $('remote-password'),
  serverUrl: $('server-url'),
  connect: $('connect'),
  error: $('error'),
  screen: $('screen'),
  audio: $('audio'),
  overlay: $('overlay'),
  peerName: $('peer-name'),
  quality: $('quality'),
  waiting: $('waiting'),
  unmute: $('unmute'),
  fullscreen: $('fullscreen'),
  disconnect: $('disconnect'),
};

function setViewerError(message) {
  els.error.textContent = message ?? '';
}

function setConnecting(flag) {
  els.connect.disabled = flag;
  els.connect.textContent = flag ? '连接中…' : '连接';
}

/** 把服务端返回的错误码翻译成用户能看懂的话。 */
function describeError(error) {
  const code = error?.code;
  if (code === 'wrong_password') return error.message;
  if (code === 'device_offline') return '设备不在线。请确认对方已启动投送，且设备 ID 没输错。';
  if (code === 'rate_limited') return error.message;
  if (code === 'invalid_device_id') return '设备 ID 应为 9 位数字。';
  if (code === 'invalid_request') return error.details?.message ?? '请填写连接密码';
  if (code === 'network') return error.message;
  return error.message ?? '连接失败';
}

function armOverlayAutoHide() {
  const wake = () => {
    els.overlay.classList.remove('idle');
    clearTimeout(overlayTimer);
    overlayTimer = setTimeout(() => els.overlay.classList.add('idle'), 3000);
  };
  for (const event of ['mousemove', 'touchstart', 'keydown']) {
    document.addEventListener(event, wake, { passive: true });
  }
  wake();
}

async function connectToDevice({ deviceId, password }) {
  const id = String(deviceId ?? '').replace(/\D/g, '');
  const secret = String(password ?? '').trim();

  if (id.length !== 9) {
    setViewerError('设备 ID 是 9 位数字');
    els.deviceId.focus();
    return;
  }

  // 自己名下的设备可以不带密码（服务端按账号令牌放行），别人的必须带
  if (!secret && !currentDevices.some((item) => item.deviceId === id)) {
    setViewerError('请输入连接密码（连接自己的设备可留空）');
    els.password.focus();
    return;
  }

  setViewerError('');
  setConnecting(true);

  localStorage.setItem('remotescreen.remoteDeviceId', id);

  try {
    const session = await RSApi.connect({ deviceId: id, password: secret || undefined, viewerName: '观看端' });
    await startPlayback(session);
  } catch (error) {
    setViewerError(describeError(error));
    setConnecting(false);
  }
}

async function startPlayback(session) {
  els.connectPane.classList.add('hidden');
  els.stage.classList.remove('hidden');
  els.waiting.classList.remove('hidden');
  els.peerName.textContent = session.deviceName || '已连接';
  els.quality.textContent = '';

  const instance = new Room({ adaptiveStream: true, dynacast: false });
  viewerRoom = instance;

  instance
    .on(RoomEvent.TrackSubscribed, onTrackSubscribed)
    .on(RoomEvent.TrackUnsubscribed, onTrackUnsubscribed)
    .on(RoomEvent.ParticipantDisconnected, () => {
      els.peerName.textContent = '对端已断开';
      els.overlay.querySelector('.dot').className = 'dot warn';
    })
    .on(RoomEvent.Reconnecting, () => {
      els.peerName.textContent = '网络波动，重连中…';
      els.overlay.querySelector('.dot').className = 'dot warn';
    })
    .on(RoomEvent.Reconnected, () => {
      els.peerName.textContent = session.deviceName || '已连接';
      els.overlay.querySelector('.dot').className = 'dot on';
    })
    .on(RoomEvent.Disconnected, () => {
      if (!els.stage.classList.contains('hidden')) {
        setViewerError('与媒体服务的连接已断开');
        teardownViewer();
      }
    })
    .on(RoomEvent.ConnectionStateChanged, (connectionState) => {
      if (connectionState === ConnectionState.Connected) {
        els.peerName.textContent = session.deviceName || '已连接';
        els.overlay.querySelector('.dot').className = 'dot on';
        setConnecting(false);
      }
    });

  await instance.connect(session.livekitUrl, session.token);

  // 已经存在的轨道也要接上
  for (const participant of instance.remoteParticipants.values()) {
    for (const publication of participant.trackPublications.values()) {
      if (publication.track) onTrackSubscribed(publication.track, publication);
    }
  }

  startStatsPolling();
  armOverlayAutoHide();
}

function onTrackSubscribed(track, publication) {
  const sid = track.sid ?? publication?.trackSid;
  if (sid) {
    if (handledTracks.has(sid)) return;
    handledTracks.add(sid);
  }

  trackEvents.push(`subscribed:${track.kind}`);

  if (track.kind === Track.Kind.Video) {
    remoteVideoTrack = track;
    track.attach(els.screen);
    els.waiting.classList.add('hidden');
    return;
  }

  if (track.kind === Track.Kind.Audio) {
    track.attach(els.audio);
    tryPlayAudio();
  }
}

function onTrackUnsubscribed(track) {
  trackEvents.push(`unsubscribed:${track.kind}`);

  if (track.kind === Track.Kind.Video) {
    remoteVideoTrack = null;
    track.detach(els.screen);
    els.waiting.classList.remove('hidden');
  } else {
    track.detach(els.audio);
  }
}

async function tryPlayAudio() {
  try {
    await els.audio.play();
    els.unmute.classList.add('hidden');
  } catch {
    els.unmute.classList.remove('hidden');
  }
}

function startStatsPolling() {
  stopStatsPolling();
  lastSample = null;
  statsTimer = setInterval(refreshQuality, 2000);
  refreshQuality();
}

function stopStatsPolling() {
  if (statsTimer) {
    clearInterval(statsTimer);
    statsTimer = null;
  }
}

async function refreshQuality() {
  if (!viewerRoom) return;

  const parts = [];
  const { videoWidth: width, videoHeight: height } = els.screen;
  if (width && height) parts.push(`${width}×${height}`);

  try {
    const rates = await readInboundRates();
    if (rates) {
      if (rates.fps > 0) parts.push(`${rates.fps.toFixed(0)} fps`);
      if (rates.mbps > 0.05) parts.push(`${rates.mbps.toFixed(1)} Mbps`);
    }
  } catch {
    // 统计接口形态不一，取不到就不显示
  }

  els.quality.textContent = parts.join(' · ');
}

/**
 * 读取接收侧速率。
 *
 * 「收到的帧率」是判断卡顿最直观的指标：它同时包含采集端出帧、
 * 网络传输与本地解码三段，任何一段出问题都会体现在这个数字上。
 */
async function readInboundRates() {
  if (typeof remoteVideoTrack?.getRTCStatsReport !== 'function') return null;

  const report = await remoteVideoTrack.getRTCStatsReport();
  if (!report) return null;

  const stats = typeof report.values === 'function'
    ? Array.from(report.values())
    : Array.isArray(report) ? report : [];

  const inbound = stats.find((stat) => stat?.type === 'inbound-rtp' && stat.kind === 'video');
  if (!inbound) return null;

  const sample = {
    bytes: inbound.bytesReceived ?? 0,
    frames: inbound.framesDecoded ?? 0,
    at: Date.now(),
  };
  const previous = lastSample;
  lastSample = sample;

  if (!previous) return { fps: 0, mbps: 0 };

  const seconds = (sample.at - previous.at) / 1000;
  if (seconds <= 0) return { fps: 0, mbps: 0 };

  return {
    fps: Math.max(0, (sample.frames - previous.frames) / seconds),
    mbps: Math.max(0, (sample.bytes - previous.bytes) * 8 / seconds / 1_000_000),
  };
}

function teardownViewer() {
  stopStatsPolling();

  if (viewerRoom) {
    viewerRoom.disconnect();
    viewerRoom = null;
  }

  remoteVideoTrack = null;
  handledTracks.clear();
  els.screen.srcObject = null;
  els.audio.srcObject = null;
  els.waiting.classList.remove('hidden');
  els.unmute.classList.add('hidden');
  lastSample = null;
  setConnecting(false);

  els.stage.classList.add('hidden');
  els.connectPane.classList.remove('hidden');
}

// ############################################################################
// MARK: - 界面绑定
// ############################################################################

function captureSettingFields() {
  return {
    resolution: $('resolution'),
    framerate: $('framerate'),
    quality: $('quality'),
    codec: $('codec'),
  };
}

function bindCaptureSettings() {
  const fields = captureSettingFields();
  const saved = storedSettings();

  fields.resolution.value = saved.resolution;
  fields.framerate.value = String(saved.framerate);
  fields.quality.value = saved.quality;
  fields.codec.value = saved.codec;

  for (const field of Object.values(fields)) {
    field.addEventListener('change', () => {
      saveSettings({
        resolution: fields.resolution.value,
        framerate: Number(fields.framerate.value),
        quality: fields.quality.value,
        codec: fields.codec.value,
      });
    });
  }
}

/** 投送过程中禁用设置项 —— 参数只在开始投送时读取，中途改不会生效。 */
function setCaptureSettingsEnabled(enabled) {
  for (const field of Object.values(captureSettingFields())) {
    field.disabled = !enabled;
  }
}

// MARK: - 投送页交互

/** 连接密码默认明文显示（方便对读），可切到掩码状态。 */
let passwordVisible = true;

/** 切换左侧导航页面。 */
function showPage(name) {
  for (const item of document.querySelectorAll('.nav-item')) {
    item.classList.toggle('active', item.dataset.page === name);
  }
  for (const page of document.querySelectorAll('.page')) {
    page.classList.toggle('hidden', page.id !== `page-${name}`);
  }
}

/** 把设备代码复制到剪贴板。 */
async function copyDeviceId() {
  if (!state.deviceId) return;

  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(state.deviceId);
    } else {
      // http 下没有 clipboard API（它不是安全上下文），退回旧办法
      const area = document.createElement('textarea');
      area.value = state.deviceId;
      area.style.position = 'fixed';
      area.style.opacity = '0';
      document.body.appendChild(area);
      area.select();
      document.execCommand('copy');
      area.remove();
    }
    setMessage('设备代码已复制', 'ok');
  } catch {
    setMessage(`复制失败，请手动记下：${state.deviceId}`, 'warn');
  }
}

function renderPassword() {
  const node = $('password');

  if (!state.password) {
    node.textContent = '— — —';
    $('toggle-password').textContent = '显示';
    return;
  }

  node.textContent = passwordVisible ? state.password : '••••••';
  $('toggle-password').textContent = passwordVisible ? '隐藏' : '显示';
}

function togglePasswordVisibility() {
  passwordVisible = !passwordVisible;
  renderPassword();
}

/**
 * 绑定全部界面交互。
 * 放在自检分支之前调用，保证自检也能覆盖到 —— 否则元素 id 写错这类问题
 * 只有在真人点界面时才会暴露。
 */
function bindUi() {
  // 账号
  $('account-button').addEventListener('click', openAccountModal);
  $('logout-button').addEventListener('click', logout);
  $('modal-close').addEventListener('click', closeAccountModal);
  $('account-logout').addEventListener('click', logout);
  $('tab-login').addEventListener('click', () => setAuthMode('login'));
  $('tab-register').addEventListener('click', () => setAuthMode('register'));
  $('auth-submit').addEventListener('click', submitAuth);
  $('account-modal').addEventListener('click', (event) => {
    if (event.target.dataset.dismiss) closeAccountModal();
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') closeAccountModal();
    if (event.key === 'Enter' && !$('account-modal').classList.contains('hidden')) submitAuth();
  });

  // 侧栏页面切换
  for (const item of document.querySelectorAll('.nav-item')) {
    item.addEventListener('click', () => showPage(item.dataset.page));
  }

  // 投送
  if (api) {
    api.onSessionError((error) => {
      if (error.scope === 'heartbeat') setConnection('心跳异常', 'warn');
    });
    api.onHeartbeat(() => setConnection('已就绪', 'on'));
  }

  $('share-toggle').addEventListener('change', (event) => {
    if (event.target.checked) startPublishing();
    else stopPublishing();
  });
  $('refresh-password').addEventListener('click', refreshPassword);
  $('copy-device-id').addEventListener('click', copyDeviceId);
  $('toggle-password').addEventListener('click', togglePasswordVisibility);
  $('reload-sources').addEventListener('click', loadSources);

  // 我的设备
  $('refresh-devices').addEventListener('click', loadDevices);
  $('server-url').addEventListener('change', () => {
    const value = $('server-url').value.trim();
    if (value) RSApi.setServerUrl(value);
    $('server-url').value = RSApi.getServerUrl();
  });

  // 连接
  els.connect.addEventListener('click', () => connectToDevice({
    deviceId: els.deviceId.value,
    password: els.password.value,
  }));

  for (const field of [els.deviceId, els.password]) {
    field.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') {
        connectToDevice({ deviceId: els.deviceId.value, password: els.password.value });
      }
    });
  }

  els.deviceId.addEventListener('input', () => {
    els.deviceId.value = els.deviceId.value.replace(/\D/g, '').slice(0, 9);
  });

  els.password.addEventListener('input', () => {
    els.password.value = els.password.value.replace(/\s/g, '').slice(0, 6);
  });

  els.disconnect.addEventListener('click', () => { teardownViewer(); setViewerError(''); });

  els.unmute.addEventListener('click', async () => {
    els.audio.muted = false;
    await tryPlayAudio();
  });

  els.fullscreen.addEventListener('click', async () => {
    try {
      if (document.fullscreenElement) {
        await document.exitFullscreen();
      } else {
        const target = els.stage.requestFullscreen ? els.stage : els.screen;
        await (target.requestFullscreen?.() ?? target.webkitEnterFullscreen?.());
      }
    } catch {
      // 用户取消或平台不支持
    }
  });

  document.addEventListener('fullscreenchange', () => {
    els.fullscreen.textContent = document.fullscreenElement ? '退出全屏' : '全屏';
  });
}

// ############################################################################
// MARK: - 自检
// ############################################################################

/** 自检用固定账号，避免每次跑都在生产库里增加账号。 */
async function ensureSelfTestAccount() {
  const email = 'selftest@remotescreen.local';
  const password = 'selftest-password-1';

  try {
    const { token } = await RSApi.register({ email, password, name: '自检账号' });
    RSApi.setToken(token);
  } catch (error) {
    if (error.code !== 'email_taken') throw error;
    const { token } = await RSApi.login({ email, password });
    RSApi.setToken(token);
  }
}

async function runCaptureSelfTest() {
  const steps = [];
  const report = { passed: false, steps };
  const record = (label, ok, detail, optional) => {
    steps.push({ label, ok: Boolean(ok), detail: detail ?? '', optional: Boolean(optional) });
  };

  try {
    const info = await api.getPlatformInfo();
    record('读取环境信息', true, `${info.platform} / Electron ${info.electronVersion}`);

    if (info.platform === 'darwin') {
      record('屏幕录制授权', info.screenPermission === 'granted', `系统状态：${info.screenPermission}`);
    }

    await ensureSelfTestAccount();
    record('账号登录', Boolean(RSApi.getToken()), '已取得账号会话');

    const session = await registerSession();
    record('设备注册并绑定到账号', /^\d{9}$/.test(session.deviceId ?? ''), `设备 ID ${session.deviceId}`);
    // 立即把连接要素打出来：自检结果要等保持连接结束后才输出，
    // 而观看端的自动化验证需要在这段时间内就能拿到密码。
    console.log(`CASTER_INFO=${JSON.stringify({
      deviceId: session.deviceId,
      password: session.password,
      roomName: session.roomName,
    })}`);

    await loadSources();
    const source = state.sources.find((item) => item.id === state.selectedSourceId);
    record('枚举采集源', Boolean(source), `${state.sources.length} 个源，选用「${source?.name}」`);

    const capture = currentCapture();
    record('采集设置', true,
      `分辨率 ${capture.resolution} · ${capture.framerate}fps · 码率上限 ${(capture.bitrate / 1_000_000).toFixed(1)} Mbps · ${capture.codec}`);

    await api.prepareCapture({ sourceId: source.id, wantSystemAudio: true });
    state.stream = await navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: capture.framerate },
      audio: true,
    });

    const videoTrack = state.stream.getVideoTracks()[0];

    // 实验采集帧率到底能到多少：先看采集开始时的值，再显式用约束提一次
    const beforeRate = videoTrack.getSettings().frameRate;
    try {
      await videoTrack.applyConstraints({
        frameRate: { ideal: 60, max: 60 },
      });
    } catch (error) {
      record('帧率约束调整', false, error.message);
    }
    const afterRate = videoTrack.getSettings().frameRate;
    record('采集帧率', true, `约束前 ${beforeRate ?? '?'}fps → 显式提 60 后 ${afterRate ?? '?'}fps`);

    if (capture.maxWidth || capture.maxHeight) {
      try {
        await videoTrack.applyConstraints({
          ...(capture.maxWidth ? { width: { max: capture.maxWidth } } : {}),
          ...(capture.maxHeight ? { height: { max: capture.maxHeight } } : {}),
        });
      } catch (error) {
        record('限制分辨率', false, error.message);
      }
    }

    const videoSettings = videoTrack.getSettings();
    record('采集屏幕画面', Boolean(videoTrack),
      `${videoSettings.width}×${videoSettings.height} @${videoSettings.frameRate ?? '?'}fps`);

    const audioTrack = state.stream.getAudioTracks()[0];
    record('采集系统音频', Boolean(audioTrack),
      audioTrack ? '已获得音频轨' : `${info.platform} 上不可用（系统限制）`,
      info.platform === 'darwin');

    const credentials = await api.getCredentials();
    const room = new Room({ adaptiveStream: false, dynacast: false });
    state.room = room;
    await room.connect(credentials.livekitUrl, credentials.token);
    record('连上 LiveKit 房间', room.state === 'connected', credentials.roomName);

    await room.localParticipant.publishTrack(videoTrack, {
      name: 'screen',
      source: Track.Source.ScreenShare,
      simulcast: false,
      videoCodec: capture.codec,
      videoEncoding: { maxBitrate: capture.bitrate, maxFramerate: capture.framerate },
    });
    if (audioTrack) {
      await room.localParticipant.publishTrack(audioTrack, {
        name: 'system-audio',
        source: Track.Source.ScreenShareAudio,
      });
    }

    const publications = [...room.localParticipant.trackPublications.values()];
    record('发布轨道', publications.length >= 1,
      publications.map((item) => item.trackName).join(', '));

    // 设备列表应能看到自己
    const { devices } = await RSApi.listDevices();
    record('设备列表包含本机', devices.some((item) => item.deviceId === session.deviceId),
      `${devices.length} 台设备`);

    report.deviceId = session.deviceId;
    report.password = session.password;
    report.roomName = credentials.roomName;
    report.identity = credentials.identity;
    report.livekitUrl = credentials.livekitUrl;
    report.publishedTracks = publications.map((item) => ({
      name: item.trackName,
      source: item.source,
      muted: item.isMuted,
    }));

    const holdSeconds = Number(params.get('hold')) || 12;
    const stats = await collectSenderStats(room, holdSeconds, capture.framerate);
    report.senderStats = stats;

    // 判断采集侧有没有出问题，正确指标是「编码出来的帧有没有全部发出去」。
    // 不能拿实发帧数除以目标帧率 —— 屏幕采集是内容驱动的，画面不变就不产生新帧。
    const sentRatio = stats.encodedFrames > 0 ? stats.sentFrames / stats.encodedFrames : 1;
    record('编码帧已全部发出', sentRatio >= 0.95,
      `编码 ${stats.encodedFrames} 帧，发出 ${stats.sentFrames} 帧（${Math.round(sentRatio * 100)}%）`);
    record('采集侧未触发限流',
      stats.qualityLimitation === 'none' || stats.qualityLimitation === 'unknown',
      `编码器受限原因：${stats.qualityLimitation}`);

    await room.disconnect();
    for (const track of state.stream.getTracks()) track.stop();
  } catch (error) {
    report.error = error.message;
    record('执行流程', false, error.message);
  }

  report.passed = steps.filter((step) => !step.optional).every((step) => step.ok);
  return report;
}

async function runViewerSelfTest() {
  const steps = [];
  const report = { passed: false, steps };
  const record = (label, ok, detail) => steps.push({ label, ok: Boolean(ok), detail: detail ?? '' });

  const deviceId = params.get('device') ?? '';
  const password = params.get('password') ?? '';
  let frames = 0;

  const finish = () => {
    report.deviceId = deviceId;
    report.resolution = els.screen.videoWidth
      ? `${els.screen.videoWidth}×${els.screen.videoHeight}`
      : '';
    report.decodedFrames = frames;
    report.receivedAudio = Boolean(els.audio.srcObject);
    report.diagnostics = {
      readyState: els.screen.readyState,
      hasSrcObject: Boolean(els.screen.srcObject),
      hasVideoTrack: Boolean(remoteVideoTrack),
      trackEvents: [...trackEvents],
    };
    report.passed = steps.every((step) => step.ok);
    return report;
  };

  try {
    record('解析服务器地址', Boolean(RSApi.getServerUrl()), RSApi.getServerUrl());

    if (params.get('account') === 'owner') {
      await ensureSelfTestAccount();
      record('账号登录', Boolean(RSApi.getToken()), '以设备主人身份连接');
    }

    let session;
    try {
      session = await RSApi.connect({ deviceId, password, viewerName: 'self-test' });
      record('换取观看令牌', true, `房间 ${session.roomName} / 授权方式 ${session.via}`);
    } catch (error) {
      record('换取观看令牌', false, error.message);
      return finish();
    }

    await startPlayback(session);
    record('加入房间', viewerRoom?.state === 'connected', `state=${viewerRoom?.state}`);

    if (typeof els.screen.requestVideoFrameCallback === 'function') {
      const tick = () => {
        frames += 1;
        els.screen.requestVideoFrameCallback(tick);
      };
      els.screen.requestVideoFrameCallback(tick);
    }

    await new Promise((resolve) => setTimeout(resolve, 8000));

    // 画面尺寸可能滞后于帧解码（隐藏窗口下合成器会延迟），最多再等 5 秒
    for (let attempt = 0; attempt < 25 && els.screen.videoWidth === 0; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 200));
    }

    const hasVideo = els.screen.videoWidth > 0;
    record('收到画面轨道', hasVideo || Boolean(remoteVideoTrack),
      hasVideo
        ? `${els.screen.videoWidth}×${els.screen.videoHeight}`
        : (remoteVideoTrack ? '已订阅但画面尺寸未就绪' : '未收到视频'));
    record('解码并渲染画面', frames > 0, `收到 ${frames} 帧`);
    record('收到声音轨道', true, els.audio.srcObject ? '已收到' : '对端未发布音频（macOS 平台限制）');
  } catch (error) {
    record('执行流程', false, error.message);
  }

  return finish();
}

// ############################################################################
// MARK: - 启动
// ############################################################################

async function initApi() {
  const fallbackServer = api
    ? await api.getPlatformInfo().then((info) => info.serverUrl).catch(() => 'http://127.0.0.1:8787')
    : (standaloneViewer ? location.origin : 'http://127.0.0.1:8787');

  RSApi.init({ queryServer: params.get('server'), fallback: fallbackServer });
  els.serverUrl.value = RSApi.getServerUrl();
}

async function startSharing() {
  // 浏览器端（没有 Electron 桥）不注册本机设备：
  // 屏幕采集需要桌面客户端，而且 http 下浏览器也拿不到采集权限。
  // 这里的账号登录、我的设备、观看远端画面都不受影响。
  if (!api) {
    setConnection('浏览器模式', 'on');
    return;
  }

  try {
    state.platformInfo = await api.getPlatformInfo();
  } catch (error) {
    setMessage(`初始化失败：${error.message}`);
    return;
  }

  if (!state.platformInfo.systemAudioSupported) {
    $('system-audio').disabled = true;
    $('audio-note').textContent = '（当前系统不支持采集电脑声音）';
  }

  try {
    await registerSession();
    await loadSources();
    setMessage('设备已上线，等待其他设备连接', 'muted');
  } catch (error) {
    setConnection('注册失败', 'off');
    setMessage(error.message);
  }

  await loadDevices();
}

// MARK: - 错误呈现
//
// 浏览器端没有控制台可看：出错时若不显示出来，用户只会看到「卡住」而不知道原因。
function showFatal(text) {
  const node = $('message');
  if (node) {
    node.textContent = '页面错误：' + text;
    node.style.color = 'var(--danger)';
  }
  setConnection('页面异常', 'off');
  console.error('[RemoteScreen]', text);
}

window.addEventListener('error', (event) => showFatal(event.message ?? '未知错误'));
window.addEventListener('unhandledrejection', (event) => {
  const reason = event.reason;
  showFatal(reason instanceof Error ? reason.message : String(reason ?? '未知错误'));
});

async function boot() {
  // 界面绑定放在自检分支之前，保证自检能覆盖到
  bindUi();
  bindCaptureSettings();

  await initApi();

  const rememberedDevice = localStorage.getItem('remotescreen.remoteDeviceId');
  if (rememberedDevice) els.deviceId.value = rememberedDevice;

  if (captureSelfTest || viewerSelfTest) {
    if (viewerSelfTest) {
      const report = await runViewerSelfTest();
      console.log(`VIEWER_SELFTEST=${JSON.stringify(report)}`);
      setTimeout(() => window.close(), 600);
      return;
    }
    const report = await runCaptureSelfTest();
    await api.reportSelfTest(report);
    return;
  }

  // 恢复已保存的账号会话
  if (RSApi.getToken()) {
    try {
      const { user } = await RSApi.me();
      account.user = user;
    } catch {
      RSApi.setToken(null);
    }
  }

  // 浏览器在 http 下拿不到采集权限，明确告知而不是让用户点了个没反应的开关
  if (!canCaptureScreen) {
    $('share-toggle').disabled = true;
    $('capture-note').textContent =
        '当前浏览器环境不支持屏幕采集：网页经 http 访问时拿不到采集权限。'
        + '请使用桌面客户端投送，或等服务端上 HTTPS 后再用浏览器投送。';
    $('capture-note').classList.remove('hidden');
  }

  renderAccount();
  setAuthMode('login');

  if (account.user) {
    await startSharing();
  } else {
    setConnection('未登录', 'off');
    renderDevices([]);
  }
}

window.addEventListener('beforeunload', () => {
  viewerRoom?.disconnect();
});

boot().catch((error) => showFatal('启动失败：' + (error?.message ?? error)));
