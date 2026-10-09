// 前端逻辑：轮询状态 → 渲染视图；用户操作 → invoke 命令。
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

const SERVER_URL = "http://91.208.104.182";
let currentPage = "cast";
/** 本机设备号（来自后端状态），用于在设备列表里标记「本机」 */
let ownDeviceId = "";

// ---------- 视图切换 ----------

function showLogin(show) {
  $("login-view").classList.toggle("hidden", !show);
  $("app").classList.toggle("hidden", show);
}

function switchPage(page) {
  currentPage = page;
  for (const button of document.querySelectorAll(".nav-item")) {
    button.classList.toggle("active", button.dataset.page === page);
  }
  for (const section of document.querySelectorAll(".page")) {
    section.classList.toggle("hidden", section.id !== `page-${page}`);
  }
}

for (const button of document.querySelectorAll(".nav-item")) {
  button.addEventListener("click", () => switchPage(button.dataset.page));
}

// ---------- 应用内弹窗 ----------
//
// Tauri 的 WebView（WKWebView）不支持 prompt / confirm / alert，
// 直接调用会静默返回 null（表现就是「点了没反应」），所以统一用自绘弹窗。
function askDialog({
  title,
  message = "",
  defaultValue = null,
  confirmText = "确定",
  cancelText = "取消",
  danger = false,
  hideCancel = false,
}) {
  return new Promise((resolve) => {
    const modal = $("modal");
    const input = $("modal-input");
    const confirm = $("modal-confirm");
    const cancel = $("modal-cancel");

    $("modal-title").textContent = title;
    $("modal-message").textContent = message;
    $("modal-message").classList.toggle("hidden", !message);

    if (defaultValue === null) {
      input.classList.add("hidden");
      input.value = "";
    } else {
      input.classList.remove("hidden");
      input.value = defaultValue;
    }

    confirm.textContent = confirmText;
    confirm.classList.toggle("danger", danger);
    cancel.textContent = cancelText;
    cancel.classList.toggle("hidden", hideCancel);

    modal.classList.remove("hidden");
    if (defaultValue !== null) {
      input.focus();
      input.select();
    }

    const finish = (result) => {
      modal.classList.add("hidden");
      confirm.removeEventListener("click", onConfirm);
      cancel.removeEventListener("click", onCancel);
      document.removeEventListener("keydown", onKey);
      modal.removeEventListener("click", onBackdrop);
      resolve(result);
    };

    const onConfirm = () => finish(defaultValue === null ? true : input.value.trim());
    const onCancel = () => finish(defaultValue === null ? false : null);
    const onKey = (event) => {
      if (event.key === "Enter" && defaultValue !== null) onConfirm();
      if (event.key === "Escape") onCancel();
    };
    const onBackdrop = (event) => {
      if (event.target === modal) onCancel();
    };

    confirm.addEventListener("click", onConfirm);
    cancel.addEventListener("click", onCancel);
    document.addEventListener("keydown", onKey);
    modal.addEventListener("click", onBackdrop);
  });
}

// ---------- 状态渲染 ----------

function formatDeviceId(id) {
  if (!id || id.length !== 9) return "— — —";
  return `${id.slice(0, 3)} ${id.slice(3, 6)} ${id.slice(6)}`;
}

function qualityLabel(height, fps) {
  const res = height === 0 ? "原始" : height <= 720 ? "流畅" : "高清";
  return `${res} · ${fps} 帧`;
}

async function refresh() {
  let state;
  try {
    state = await invoke("get_state");
  } catch (error) {
    $("server-text").textContent = "状态获取失败";
    $("server-dot").className = "dot bad";
    return;
  }

  showLogin(!state.logged_in);
  if (!state.logged_in) return;

  ownDeviceId = state.device_id || "";
  $("device-id").textContent = state.registered ? formatDeviceId(state.device_id) : "注册中…";
  $("device-password").textContent = state.registered ? state.password : "— — —";

  const toggle = $("publish-toggle");
  if (toggle.checked !== state.publishing) toggle.checked = state.publishing;
  toggle.disabled = !state.registered;
  $("publish-badge").classList.toggle("hidden", !state.publishing);
  $("publish-status").textContent = state.publishing
    ? "投送中 —— 其他设备正在观看这台屏幕"
    : "打开后，其他设备输入下面的设备代码与密码即可观看本机屏幕";
  $("publish-status").style.color = state.publishing ? "var(--green)" : "";

  for (const chip of document.querySelectorAll("#quality-res .chip")) {
    chip.classList.toggle("active", Number(chip.dataset.h) === state.share_height);
  }
  for (const chip of document.querySelectorAll("#quality-fps .chip")) {
    chip.classList.toggle("active", Number(chip.dataset.fps) === state.share_fps);
  }

  // 注册完成前属于「连接中」，只有真的报错才显示异常（此前启动瞬间会误报）
  if (state.last_error) {
    $("server-dot").className = "dot bad";
    $("server-text").textContent = "连接异常";
  } else if (state.registered) {
    $("server-dot").className = "dot ok";
    $("server-text").textContent = "已连接服务器";
  } else {
    $("server-dot").className = "dot";
    $("server-text").textContent = "正在连接…";
  }

  $("cast-error").textContent = state.last_error || "";

  $("set-server").textContent = SERVER_URL;
  $("set-quality").textContent = qualityLabel(state.share_height, state.share_fps);

  const name = state.account_name || "未登录";
  $("account-name").textContent = name;
  $("menu-name").textContent = name;
  $("menu-email").textContent = state.account_email || "—";
  $("account-avatar").textContent =
    name === "未登录" ? "—" : name.trim().slice(0, 1).toUpperCase();
  $("user-chip").classList.toggle("hidden", !state.logged_in);
}

// ---------- 交互 ----------

$("login-btn").addEventListener("click", async () => {
  $("login-error").textContent = "";
  $("login-btn").disabled = true;
  try {
    await invoke("login", {
      email: $("email").value.trim(),
      password: $("password").value,
    });
    await invoke("register_device");
  } catch (error) {
    $("login-error").textContent = String(error);
  } finally {
    $("login-btn").disabled = false;
  }
  refresh();
});

$("publish-toggle").addEventListener("change", async (event) => {
  const enabled = event.target.checked;
  try {
    await invoke(enabled ? "start_publish" : "stop_publish");
  } catch (error) {
    $("cast-error").textContent = String(error);
    event.target.checked = !enabled;
  }
  refresh();
});

for (const chip of document.querySelectorAll("#quality-res .chip, #quality-fps .chip")) {
  chip.addEventListener("click", async () => {
    const state = await invoke("get_state");
    const height = chip.dataset.h !== undefined ? Number(chip.dataset.h) : state.share_height;
    const fps = chip.dataset.fps !== undefined ? Number(chip.dataset.fps) : state.share_fps;
    try {
      await invoke("set_quality", { height, fps });
    } catch (error) {
      $("cast-error").textContent = `画质设置失败：${error}`;
    }
    refresh();
  });
}

$("copy-id").addEventListener("click", async () => {
  const state = await invoke("get_state");
  try {
    await navigator.clipboard.writeText(state.device_id);
    $("copy-id").textContent = "已复制";
    setTimeout(() => ($("copy-id").textContent = "复制"), 1500);
  } catch {
    $("cast-error").textContent = `设备代码：${state.device_id}`;
  }
});

$("refresh-pw").addEventListener("click", async () => {
  $("refresh-pw").disabled = true;
  try {
    await invoke("refresh_password");
  } catch (error) {
    $("cast-error").textContent = `刷新密码失败：${error}`;
  } finally {
    $("refresh-pw").disabled = false;
  }
  refresh();
});

// ---------- 观看 ----------

let lastWatching = false;

// ---------- 收到的观看请求（别人要看本机）----------

let incomingRequestId = "";

async function refreshIncoming() {
  let requests = [];
  try {
    requests = await invoke("get_incoming_requests");
  } catch {
    return;
  }
  const banner = $("incoming-request");
  if (!banner) return;
  if (!requests.length) {
    banner.classList.add("hidden");
    incomingRequestId = "";
    return;
  }
  const request = requests[0];
  incomingRequestId = request.requestId;
  $("incoming-viewer").textContent = request.viewerName || "未知设备";
  banner.classList.remove("hidden");
}

async function decideIncoming(approve) {
  if (!incomingRequestId) return;
  try {
    await invoke("decide_incoming_request", { requestId: incomingRequestId, approve });
  } catch (error) {
    $("cast-error").textContent = `处理请求失败：${error}`;
  }
  incomingRequestId = "";
  refreshIncoming();
}

$("incoming-approve").addEventListener("click", () => decideIncoming(true));
$("incoming-deny").addEventListener("click", () => decideIncoming(false));

async function refreshWatch() {
  let state;
  try {
    state = await invoke("get_watch_state");
  } catch {
    return;
  }
  const formCard = $("watch-form-card");
  const viewerCard = $("viewer-card");
  // 只以会话状态为准（累计帧数曾导致断开后卡片不消失）
  const active = state.watching;

  // 等待对方同意：显示倒计时横幅
  const pending = Boolean(state.pending_device);
  if (pending) {
    $("watch-pending").classList.remove("hidden");
    $("pending-name").textContent = state.pending_device;
    $("pending-countdown").textContent = state.pending_seconds > 0
      ? `（${state.pending_seconds} 秒内有效）`
      : "";
    $("watch-btn").disabled = true;
  } else {
    $("watch-pending").classList.add("hidden");
    $("watch-btn").disabled = false;
  }

  if (state.error) {
    formCard.classList.remove("hidden");
    viewerCard.classList.add("hidden");
    $("watch-error").textContent = state.error;
    lastWatching = false;
    return;
  }

  if (active) {
    formCard.classList.add("hidden");
    viewerCard.classList.remove("hidden");
    $("viewer-name").textContent = state.device_name || "远程设备";
    $("viewer-meta").textContent = state.width
      ? `独立窗口中显示 · ${state.width}×${state.height} · ${state.fps} fps`
      : "独立窗口中显示 · 连接中…";
  } else {
    formCard.classList.remove("hidden");
    viewerCard.classList.add("hidden");
  }
  lastWatching = active;
}

$("watch-btn").addEventListener("click", async () => {
  $("watch-error").textContent = "";
  $("watch-btn").disabled = true;
  try {
    const outcome = await invoke("start_watch", {
      deviceId: $("watch-id").value.trim(),
      password: $("watch-pw").value.trim(),
    });
    // 直连成功才立刻开窗；等待同意的路径由后端在批准后自动开窗
    if (!String(outcome).includes("等待对方同意")) {
      await invoke("open_viewer_window");
    } else {
      $("watch-error").textContent = "";
    }
  } catch (error) {
    $("watch-error").textContent = String(error);
  } finally {
    $("watch-btn").disabled = false;
  }
  refreshWatch();
});

$("pending-cancel").addEventListener("click", async () => {
  await invoke("cancel_watch_request");
  refreshWatch();
});

$("viewer-refocus").addEventListener("click", () => invoke("open_viewer_window"));

$("watch-stop").addEventListener("click", async () => {
  // 任何一步失败都要继续把界面刷回来（否则看起来像「点了没反应」）
  try {
    await invoke("stop_watch");
  } catch (error) {
    $("watch-error").textContent = `断开失败：${error}`;
  }
  try {
    await invoke("close_viewer_window");
  } catch {
    // 窗口可能已经关掉了，忽略
  }
  refreshWatch();
});

// ---------- 观看历史 ----------

function relativeTime(unixSeconds) {
  if (!unixSeconds) return "";
  const seconds = Math.floor(Date.now() / 1000 - unixSeconds);
  if (seconds < 60) return "刚刚";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} 分钟前`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)} 小时前`;
  if (seconds < 86400 * 30) return `${Math.floor(seconds / 86400)} 天前`;
  return new Date(unixSeconds * 1000).toLocaleDateString("zh-CN");
}

async function refreshHistory() {
  const list = $("history-list");
  let entries = [];
  try {
    entries = await invoke("get_history");
  } catch {
    return;
  }

  if (!entries.length) {
    list.innerHTML =
      '<p class="muted small">还没有观看记录 —— 连接过的设备会出现在这里，方便下次一键重连</p>';
    $("history-clear").classList.add("hidden");
    return;
  }

  $("history-clear").classList.remove("hidden");
  list.innerHTML = "";
  for (const entry of entries) {
    const item = document.createElement("div");
    item.className = "history-item";

    const main = document.createElement("div");
    main.className = "history-main";
    const nameRow = document.createElement("div");
    nameRow.className = "history-name";
    nameRow.textContent = entry.device_name || "未知设备";
    if (entry.own) {
      const pill = document.createElement("span");
      pill.className = "pill";
      pill.textContent = "我的设备";
      nameRow.appendChild(pill);
    }
    const codeRow = document.createElement("div");
    codeRow.className = "history-code";
    codeRow.textContent = `${formatDeviceId(entry.device_id)} · ${relativeTime(entry.last_at)}` +
      (entry.times > 1 ? ` · 连接过 ${entry.times} 次` : "");
    main.append(nameRow, codeRow);

    const actions = document.createElement("div");
    actions.className = "history-actions";

    const connectBtn = document.createElement("button");
    connectBtn.className = "ghost";
    connectBtn.textContent = entry.own ? "连接" : "连接";
    connectBtn.addEventListener("click", async (event) => {
      event.stopPropagation();
      $("watch-id").value = entry.device_id;
      // 自有设备直连，别人的设备走「请求对方同意」；填了密码则按密码直连
      const password = $("watch-pw").value.trim();
      try {
        const outcome = await invoke("start_watch", {
          deviceId: entry.deviceId,
          password,
        });
        if (!String(outcome).includes("等待对方同意")) {
          await invoke("open_viewer_window");
        }
      } catch (error) {
        $("watch-error").textContent = String(error);
      }
      refreshWatch();
    });

    const removeBtn = document.createElement("button");
    removeBtn.className = "ghost";
    removeBtn.textContent = "移除";
    removeBtn.addEventListener("click", async (event) => {
      event.stopPropagation();
      await invoke("forget_device", { deviceId: entry.device_id });
      refreshHistory();
    });

    actions.append(connectBtn, removeBtn);
    item.append(main, actions);
    // 点击整行等同于点「连接」
    item.addEventListener("click", () => connectBtn.click());
    list.appendChild(item);
  }
}

$("history-clear").addEventListener("click", async () => {
  await invoke("clear_history");
  refreshHistory();
});

// ---------- 我的设备 ----------

const PLATFORM_LABEL = {
  macos: "macOS",
  darwin: "macOS",
  "macos-rs": "macOS",
  windows: "Windows",
  android: "Android",
  ios: "iOS",
  linux: "Linux",
};

function platformLabel(platform) {
  if (!platform) return "未知平台";
  return PLATFORM_LABEL[platform] ?? platform;
}

async function refreshDevices() {
  const list = $("devices-list");
  if (!list) return;
  let devices = [];
  let error = "";
  try {
    devices = await invoke("list_devices");
  } catch (problem) {
    error = String(problem);
  }

  if (error) {
    list.innerHTML = `<p class="muted small">${error}</p>`;
    return;
  }
  if (!devices.length) {
    list.innerHTML = '<p class="muted small">账号下还没有设备 —— 本机会在登录后自动注册</p>';
    return;
  }

  list.innerHTML = "";
  for (const device of devices) {
    const item = document.createElement("div");
    item.className = "history-item";
    item.style.cursor = "default";

    const main = document.createElement("div");
    main.className = "history-main";
    const nameRow = document.createElement("div");
    nameRow.className = "history-name";
    nameRow.textContent = device.name || "未命名设备";

    const statePill = document.createElement("span");
    statePill.className = "pill";
    statePill.textContent = device.online ? "在线" : "离线";
    statePill.style.background = device.online ? "#e8f6ee" : "#f0f1f5";
    statePill.style.color = device.online ? "#17784a" : "#8b93a5";
    nameRow.appendChild(statePill);

    if (ownDeviceId && device.deviceId === ownDeviceId) {
      const ownPill = document.createElement("span");
      ownPill.className = "pill";
      ownPill.textContent = "本机";
      nameRow.appendChild(ownPill);
    }

    const metaRow = document.createElement("div");
    metaRow.className = "history-code";
    const lastSeen = device.online
      ? "在线中"
      : relativeTime(Math.floor((device.lastSeenAt ?? 0) / 1000)) || "从未上线";
    metaRow.textContent = `${formatDeviceId(device.deviceId)} · ${platformLabel(device.platform)} · ${lastSeen}`;
    main.append(nameRow, metaRow);

    const actions = document.createElement("div");
    actions.className = "history-actions";

    const watchBtn = document.createElement("button");
    watchBtn.className = "ghost";
    watchBtn.textContent = "观看";
    watchBtn.addEventListener("click", async () => {
      if (!device.online) {
        $("watch-error").textContent = "该设备当前离线，无法观看";
        switchPage("watch");
        return;
      }
      try {
        await invoke("start_watch", { deviceId: device.deviceId, password: "" });
        await invoke("open_viewer_window");
      } catch (problem) {
        $("watch-error").textContent = String(problem);
        switchPage("watch");
      }
      refreshWatch();
    });

    const renameBtn = document.createElement("button");
    renameBtn.className = "ghost";
    renameBtn.textContent = "重命名";
    renameBtn.addEventListener("click", async () => {
      const name = await askDialog({
        title: "重命名设备",
        message: "不超过 32 个字符",
        defaultValue: device.name || "",
        confirmText: "保存",
      });
      if (name === null || name === "") return;
      try {
        await invoke("rename_device", { deviceId: device.deviceId, name });
      } catch (problem) {
        await askDialog({ title: "重命名失败", message: String(problem), confirmText: "知道了", hideCancel: true });
        return;
      }
      refreshDevices();
    });

    actions.append(watchBtn, renameBtn);
    item.append(main, actions);
    list.appendChild(item);
  }
}

$("devices-refresh").addEventListener("click", refreshDevices);

// ---------- 右上角用户菜单 ----------

$("user-chip").addEventListener("click", (event) => {
  event.stopPropagation();
  $("user-menu").classList.toggle("hidden");
});
document.addEventListener("click", () => $("user-menu").classList.add("hidden"));

// ---------- 退出登录 ----------

$("logout-btn").addEventListener("click", async () => {
  $("user-menu").classList.add("hidden");
  const confirmed = await askDialog({
    title: "退出登录",
    message: "退出后本机将停止投送，需要重新登录才能继续。",
    confirmText: "退出登录",
    danger: true,
  });
  if (!confirmed) return;
  await invoke("logout");
  switchPage("cast");
  refresh();
  refreshHistory();
  refreshDevices();
});

refresh();
refreshWatch();
refreshHistory();
refreshIncoming();
setInterval(refresh, 2000);
setInterval(refreshWatch, 1500);
setInterval(refreshHistory, 5000);
refreshDevices();
setInterval(refreshDevices, 10000);
setInterval(refreshIncoming, 3000);
