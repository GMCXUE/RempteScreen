// 独立观看窗口逻辑：拉帧绘制 + 控制条（声音 / 显示模式 / 全屏 / 沉浸 / 断开）
const { invoke } = window.__TAURI__.core;
const $ = (id) => document.getElementById(id);

const canvas = $("screen");
const context = canvas.getContext("2d");

let frameLoop = null;
let pending = false;
let frameGeneration = 0;
let abortFrame = null;
let fitMode = "contain"; // contain | stretch | pixel
let audioOn = true;
let callError = "";
let remoteCameraOn = false;
let cameraPending = false;
let lastCameraFetch = 0;

// ---------- 画面 ----------

function startFrames() {
  if (frameLoop) return;
  const generation = ++frameGeneration;
  const tick = () => {
    if (!frameLoop || generation !== frameGeneration) return;
    if (!pending) {
      pending = true;
      const image = new Image();
      const finish = () => {
        clearTimeout(deadline);
        image.onload = image.onerror = null;
        if (generation === frameGeneration) { pending = false; abortFrame = null; }
      };
      const deadline = setTimeout(() => {
        finish();
        image.src = "";
        if (generation === frameGeneration) {
          $("status").textContent = "画面加载超时，正在重试…";
          $("status").classList.remove("hidden");
        }
      }, 3000);
      abortFrame = () => { finish(); image.src = ""; };
      image.onload = () => {
        if (generation !== frameGeneration) { finish(); return; }
        if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
          canvas.width = image.naturalWidth;
          canvas.height = image.naturalHeight;
        }
        context.drawImage(image, 0, 0);
        $("status").classList.add("hidden");
        finish();
      };
      image.onerror = finish;
      image.src = `${window.__TAURI__.core.convertFileSrc('latest', 'frame')}?t=${performance.now()}`;
    }
    frameLoop = requestAnimationFrame(tick);
  };
  frameLoop = requestAnimationFrame(tick);
}

function stopFrames() {
  if (abortFrame) abortFrame();
  ++frameGeneration;
  pending = false;
  if (frameLoop) cancelAnimationFrame(frameLoop);
  frameLoop = null;
  context.clearRect(0, 0, canvas.width, canvas.height);
}

function cameraTick() {
  const view = $("camera-view");
  const now = performance.now();
  if (remoteCameraOn && !cameraPending && now - lastCameraFetch >= 16) {
    lastCameraFetch = now;
    cameraPending = true;
    const next = new Image();
    const finish = () => { clearTimeout(deadline); next.onload = next.onerror = null; cameraPending = false; };
    const deadline = setTimeout(() => { finish(); next.src = ''; }, 3000);
    next.onload = () => {
      if (!remoteCameraOn) { finish(); return; }
      view.src = next.src;
      view.classList.remove("hidden");
      finish();
    };
    next.onerror = () => {
      view.classList.add("hidden");
      finish();
    };
    next.src = `${window.__TAURI__.core.convertFileSrc('latest', 'camera')}?t=${performance.now()}`;
  } else if (!remoteCameraOn) {
    view.classList.add("hidden");
  }
  requestAnimationFrame(cameraTick);
}
cameraTick();

// ---------- 状态轮询 ----------

async function refresh() {
  let state;
  try {
    state = await invoke("get_watch_state");
  } catch {
    return;
  }

  const live = state.watching && state.frames > 0 && !state.error;
  controls.setAvailable(live);
  document.body.classList.toggle("waiting", !live);
  $("viewing-status").textContent = state.error ? "连接异常" : live ? "正在观看" : "等待画面";

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
  $("meta").textContent = callError || ($("mic-btn").disabled
    ? "正在处理通话设备，请留意系统权限提示…" : state.width
    ? `${state.width}×${state.height} · ${state.fps} fps`
    : "连接中…");

  // 没有音频轨时把声音按钮置灰
  const audioButton = $("audio-btn");
  audioButton.classList.toggle("muted", !state.has_audio);
  audioButton.title = state.has_audio ? "声音开关" : "对方未发送声音";

  try {
    const call = await invoke("call_state", { scope: "watch" });
    remoteCameraOn = call.remote_camera;
    $("call-speaker-btn").classList.toggle("on", call.speaker);
    $("call-speaker-btn").textContent = call.speaker ? "通话声音" : "通话静音";
    $("mic-btn").classList.toggle("on", call.microphone);
    $("mic-btn").textContent = call.microphone ? "麦克风" : "麦克风关";
    $("camera-btn").classList.toggle("on", call.camera);
    $("camera-btn").textContent = call.camera ? "摄像头" : "摄像头关";
  } catch {}
}

// ---------- 控制条 ----------

const controls = new ViewerControls({
  root: document.body, stage: $("stage"), toolbar: $("controls"),
});
$("stage").addEventListener("click", () => controls.toggle());
$("show-controls").addEventListener("click", () => controls.show());
$("controls").addEventListener("pointerdown", () => controls.schedule());
$("controls").addEventListener("focusin", () => controls.show());
document.addEventListener("mousemove", (event) => {
  if (!event.target.closest(".compact-controls")) controls.interact();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Tab") controls.show();
  if (event.key === "Escape") {
    if (!$("close-modal").classList.contains("hidden")) $("close-cancel").click();
    else if (fullscreen) $("full-btn").click();
    else controls.show();
  }
});

async function toggleCall(kind) {
  if ($("mic-btn").disabled || $("camera-btn").disabled) return;
  callError = "";
  controls.setBusy(true);
  $("mic-btn").disabled = $("camera-btn").disabled = true;
  $("meta").textContent = "正在处理通话设备，请留意系统权限提示…";
  try {
    const state = await invoke("call_state", { scope: "watch" });
    const command = kind === "microphone" ? "call_set_microphone" : "call_set_camera";
    await invoke(command, { scope: "watch", enabled: !state[kind] });
  } catch (error) {
    callError = String(error);
  } finally {
    $("mic-btn").disabled = $("camera-btn").disabled = false;
    controls.setBusy(false);
    await refresh();
  }
}

$("mic-btn").addEventListener("click", async () => {
  try { await toggleCall("microphone"); } catch (error) { $("meta").textContent = String(error); }
});
$("camera-btn").addEventListener("click", async () => {
  try { await toggleCall("camera"); } catch (error) { $("meta").textContent = String(error); }
});

// 音量滑块：实时设置播放音量（0-100）
let lastVolume = Number($("volume").value) || 100;

async function applyVolume(value) {
  try {
    await invoke("set_volume", { volume: value });
    const muted = value === 0;
    $("audio-btn").classList.toggle("on", !muted);
    $("audio-btn").classList.toggle("muted", muted);
    $("audio-label").textContent = muted ? "投屏静音" : "投屏声音";
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
async function toggleFullscreen() {
  if ($("full-btn").disabled) return;
  const next = !fullscreen;
  $("full-btn").disabled = $("compact-full-btn").disabled = true;
  try {
    await invoke("set_viewer_fullscreen", { fullscreen: next });
    fullscreen = next;
    for (const id of ["full-btn", "compact-full-btn"]) {
      $(id).classList.toggle("on", fullscreen);
      $(id).title = fullscreen ? "退出全屏" : "全屏";
      $(id).setAttribute("aria-label", $(id).title);
    }
    controls.show();
  } catch (error) {
    callError = "无法切换全屏，请重试";
    $("meta").textContent = callError;
    controls.show();
  } finally {
    $("full-btn").disabled = $("compact-full-btn").disabled = false;
  }
}
$("full-btn").addEventListener("click", toggleFullscreen);
$("compact-full-btn").addEventListener("click", toggleFullscreen);
$("hide-btn").addEventListener("click", () => controls.hide());

$("stop-btn").addEventListener("click", () => {
  controls.setBusy(true);
  $("close-device").textContent = $("device").textContent;
  $("close-modal").classList.remove("hidden");
});

// ---------- 点窗口关闭按钮（×）时的二次确认 ----------

const { event } = window.__TAURI__;

invoke("ui_log", { message: "观看窗口已就绪" }).catch(() => {});

event.listen("viewer:close-requested", () => {
  invoke("ui_log", { message: "弹出关闭确认框" }).catch(() => {});
  // 正在观看时，关闭窗口等于断开连接 —— 先确认
  const name = $("device").textContent || "远程设备";
  $("close-device").textContent = name;
  controls.setBusy(true);
  $("close-modal").classList.remove("hidden");
  // 标题带上状态：窗口被别的程序挡住时也能一眼看出是在等确认
  document.title = "确认关闭 — RemoteScreen 观看";
});

$("close-cancel").addEventListener("click", () => {
  $("close-modal").classList.add("hidden");
  controls.setBusy(false);
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
canvas.addEventListener("dblclick", () => { controls.show(); $("full-btn").click(); });

refresh();
setInterval(refresh, 1000);

$("call-speaker-btn").addEventListener("click", async () => {
  try {
    const state = await invoke("call_state", { scope: "watch" });
    await invoke("call_set_speaker", { enabled: !state.speaker });
    await refresh();
  } catch (error) {
    callError = `通话操作失败：${error}`;
    $("meta").textContent = callError;
    controls.show();
  }
});
