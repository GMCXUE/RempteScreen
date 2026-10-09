// 前端逻辑：轮询状态 → 渲染视图；用户操作 → invoke 命令。
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

const SERVER_URL = "http://91.208.104.182";
let currentPage = "cast";

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

  const connected = state.registered && !state.last_error;
  $("server-dot").className = `dot ${connected ? "ok" : "bad"}`;
  $("server-text").textContent = connected ? "已连接服务器" : "连接异常";

  $("cast-error").textContent = state.last_error || "";

  $("set-server").textContent = SERVER_URL;
  $("set-quality").textContent = qualityLabel(state.share_height, state.share_fps);
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

async function refreshWatch() {
  let state;
  try {
    state = await invoke("get_watch_state");
  } catch {
    return;
  }
  const formCard = $("watch-form-card");
  const viewerCard = $("viewer-card");
  const active = state.watching || state.frames > 0;

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
    await invoke("start_watch", {
      deviceId: $("watch-id").value.trim(),
      password: $("watch-pw").value.trim(),
    });
    // 画面与控制条都在独立窗口里
    await invoke("open_viewer_window");
  } catch (error) {
    $("watch-error").textContent = String(error);
  } finally {
    $("watch-btn").disabled = false;
  }
  refreshWatch();
});

$("viewer-refocus").addEventListener("click", () => invoke("open_viewer_window"));

$("watch-stop").addEventListener("click", async () => {
  await invoke("stop_watch");
  await invoke("close_viewer_window");
  refreshWatch();
});

refresh();
refreshWatch();
setInterval(refresh, 2000);
setInterval(refreshWatch, 1500);
