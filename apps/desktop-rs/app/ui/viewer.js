// 独立观看窗口逻辑：拉帧绘制 + 控制条（声音 / 显示模式 / 全屏 / 沉浸 / 断开）
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

const canvas = $("screen");
const context = canvas.getContext("2d");

let frameLoop = null;
let pending = false;
let fitMode = "contain"; // contain | stretch | pixel
let pinned = false;      // 沉浸模式里锁定控制条
let audioOn = true;

// ---------- 画面 ----------

function startFrames() {
  if (frameLoop) return;
  const tick = () => {
    if (!frameLoop) return;
    if (!pending) {
      pending = true;
      const image = new Image();
      image.onload = () => {
        if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
          canvas.width = image.naturalWidth;
          canvas.height = image.naturalHeight;
        }
        context.drawImage(image, 0, 0);
        $("status").classList.add("hidden");
        pending = false;
      };
      image.onerror = () => { pending = false; };
      image.src = `frame://localhost/latest?t=${performance.now()}`;
    }
    frameLoop = requestAnimationFrame(tick);
  };
  frameLoop = requestAnimationFrame(tick);
}

function stopFrames() {
  if (frameLoop) cancelAnimationFrame(frameLoop);
  frameLoop = null;
}

// ---------- 状态轮询 ----------

let lastFsState = false;

async function refresh() {
  let state;
  try {
    state = await invoke("get_watch_state");
  } catch {
    return;
  }

  if (state.error) {
    $("status").textContent = state.error;
    $("status").classList.remove("hidden");
    stopFrames();
    return;
  }

  if (!state.watching && state.frames === 0) {
    $("status").textContent = "对方已停止投送";
    $("status").classList.remove("hidden");
    stopFrames();
    return;
  }

  startFrames();
  $("device").textContent = state.device_name || "远程设备";
  $("meta").textContent = state.width
    ? `${state.width}×${state.height} · ${state.fps} fps`
    : "连接中…";

  // 没有音频轨时把声音按钮置灰
  const audioButton = $("audio-btn");
  audioButton.classList.toggle("muted", !state.has_audio);
  audioButton.title = state.has_audio ? "声音开关" : "对方未发送声音";
}

// ---------- 控制条 ----------

// 控制条显隐：默认显示，3 秒无操作自动隐藏；鼠标移到底部或沉浸模式下悬停浮现
let lastMove = Date.now();
let nearBottom = false;
let booted = false;

function updateControls() {
  const fresh = Date.now() - lastMove < 3000;
  const show = nearBottom || (!pinned && (fresh || !booted));
  document.body.classList.toggle("hover", show);
}

document.addEventListener("mousemove", (event) => {
  booted = true;
  lastMove = Date.now();
  nearBottom = event.clientY > window.innerHeight - 140;
  updateControls();
});
setInterval(updateControls, 400);
updateControls();

// 音量滑块：实时设置播放音量（0-100）
let lastVolume = Number($("volume").value) || 100;

async function applyVolume(value) {
  try {
    await invoke("set_volume", { volume: value });
    const muted = value === 0;
    $("audio-btn").classList.toggle("on", !muted);
    $("audio-btn").classList.toggle("muted", muted);
    $("audio-label").textContent = muted ? "静音" : "声音";
    audioOn = !muted;
  } catch {
    // 调用失败不改变状态
  }
}

$("audio-btn").addEventListener("click", async () => {
  // 静音开关：静音时记住之前的音量，取消静音时恢复
  if (audioOn) {
    lastVolume = Number($("volume").value) || 100;
    $("volume").value = 0;
    await applyVolume(0);
  } else {
    const restore = lastVolume > 0 ? lastVolume : 100;
    $("volume").value = restore;
    await applyVolume(restore);
  }
});

$("volume").addEventListener("input", async () => {
  const value = Number($("volume").value);
  await applyVolume(value);
});

$("fit-btn").addEventListener("click", () => {
  const modes = ["contain", "stretch", "pixel"];
  const labels = { contain: "适应窗口", stretch: "拉伸铺满", pixel: "原始像素" };
  fitMode = modes[(modes.indexOf(fitMode) + 1) % modes.length];
  canvas.classList.toggle("stretch", fitMode === "stretch");
  canvas.classList.toggle("pixel", fitMode === "pixel");
  $("fit-btn").textContent = labels[fitMode];
});

let fullscreen = false;
$("full-btn").addEventListener("click", async () => {
  fullscreen = !fullscreen;
  try {
    await invoke("set_viewer_fullscreen", { fullscreen });
  } catch (error) {
    console.error(error);
  }
  $("full-btn").classList.toggle("on", fullscreen);
});

$("hide-btn").addEventListener("click", () => {
  pinned = !pinned;
  document.body.classList.toggle("pinned", pinned);
  $("hide-btn").classList.toggle("on", pinned);
  $("hide-btn").textContent = pinned ? "沉浸中" : "沉浸";
  lastMove = 0;
  updateControls();
});

$("stop-btn").addEventListener("click", async () => {
  try {
    await invoke("stop_watch");
  } finally {
    stopFrames();
    await invoke("close_viewer_window");
  }
});

// ---------- 点窗口关闭按钮（×）时的二次确认 ----------

const { event } = window.__TAURI__;

invoke("ui_log", { message: "观看窗口已就绪" }).catch(() => {});

event.listen("viewer:close-requested", () => {
  invoke("ui_log", { message: "弹出关闭确认框" }).catch(() => {});
  // 正在观看时，关闭窗口等于断开连接 —— 先确认
  const name = $("device").textContent || "远程设备";
  $("close-device").textContent = name;
  $("close-modal").classList.remove("hidden");
  // 标题带上状态：窗口被别的程序挡住时也能一眼看出是在等确认
  document.title = "确认关闭 — RemoteScreen 观看";
});

$("close-cancel").addEventListener("click", () => {
  $("close-modal").classList.add("hidden");
  invoke("ui_log", { message: "用户取消了关闭" }).catch(() => {});
});

$("close-confirm").addEventListener("click", async () => {
  $("close-modal").classList.add("hidden");
  invoke("ui_log", { message: "用户确认断开并关闭" }).catch(() => {});
  try {
    await invoke("stop_watch");
  } catch {
    // 断开失败也要把窗口关掉，避免卡住
  }
  stopFrames();
  await invoke("close_viewer_window");
});

// 双击画面切换全屏
canvas.addEventListener("dblclick", () => $("full-btn").click());

refresh();
setInterval(refresh, 1000);
