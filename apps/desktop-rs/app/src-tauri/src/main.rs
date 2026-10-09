// RemoteScreen Rust 桌面端 —— Tauri 2 应用入口。
//
// 架构：Rust 侧持有全部业务（服务端 API、心跳、原生采集推流），
// 前端只是个壳，通过 invoke 调命令、轮询状态渲染界面。
mod api;
mod publisher;
mod viewer;

use tauri::Manager;
use std::time::Duration;

use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct AppState {
    creds: Mutex<api::Credentials>,
    registration: Mutex<Option<api::Registration>>,
    heartbeat_stop: Mutex<Option<Arc<AtomicBool>>>,
    session: Mutex<Option<publisher::PublishSession>>,
    last_error: Arc<Mutex<Option<String>>>,
    watch: Mutex<Option<viewer::WatchSession>>,
    watch_error: Arc<Mutex<Option<String>>>,
    frames: viewer::FrameStore,
    watch_stats: Arc<Mutex<viewer::WatchStats>>,
    audio: viewer::AudioTrackStore,
}

#[derive(Serialize, Clone)]
struct AppStateDto {
    logged_in: bool,
    registered: bool,
    device_id: String,
    password: String,
    publishing: bool,
    last_error: String,
    share_height: u32,
    share_fps: u32,
    account_name: String,
    account_email: String,
}

fn spawn_heartbeat(state: &AppState, registration: api::Registration) {
    // 停掉旧的心跳
    if let Some(old) = state.heartbeat_stop.lock().unwrap().take() {
        old.store(true, Ordering::Relaxed);
    }
    let stop = Arc::new(AtomicBool::new(false));
    *state.heartbeat_stop.lock().unwrap() = Some(stop.clone());
    *state.registration.lock().unwrap() = Some(registration.clone());

    tauri::async_runtime::spawn(async move {
        let mut timer = tokio::time::interval(std::time::Duration::from_secs(15));
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            if let Err(error) = api::heartbeat(&registration.device_id, &registration.session_token) {
                eprintln!("[heartbeat] {error}");
            }
            timer.tick().await;
        }
    });
}

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> AppStateDto {
    let creds = state.creds.lock().unwrap();
    let registration = state.registration.lock().unwrap();
    let publishing = state.session.lock().unwrap().is_some();
    AppStateDto {
        logged_in: creds.account_token.is_some(),
        registered: registration.is_some(),
        device_id: registration.as_ref().map(|r| r.device_id.clone()).unwrap_or_default(),
        password: registration.as_ref().map(|r| r.password.clone()).unwrap_or_default(),
        publishing,
        last_error: state.last_error.lock().unwrap().clone().unwrap_or_default(),
        share_height: creds.share_height,
        share_fps: creds.share_fps,
        account_name: creds.account_name.clone().unwrap_or_default(),
        account_email: creds.account_email.clone().unwrap_or_default(),
    }
}

#[tauri::command]
fn login(email: String, password: String, state: tauri::State<AppState>) -> Result<String, String> {
    let (name, token) = api::login(&email, &password)?;
    {
        let mut creds = state.creds.lock().unwrap();
        creds.account_token = Some(token);
        creds.account_name = Some(name.clone());
        creds.account_email = Some(email);
        api::save_creds(&creds);
    }
    Ok(name)
}

/// 退出登录：停掉心跳、投送与观看，清空账号与设备凭据（画质设置保留）。
#[tauri::command]
fn logout(state: tauri::State<AppState>) -> Result<(), String> {
    if let Some(stop) = state.heartbeat_stop.lock().unwrap().take() {
        stop.store(true, Ordering::Relaxed);
    }
    if let Some(session) = state.session.lock().unwrap().take() {
        session.stop();
    }
    if let Some(session) = state.watch.lock().unwrap().take() {
        session.stop();
    }
    *state.registration.lock().unwrap() = None;
    *state.frames.lock().unwrap() = None;
    *state.last_error.lock().unwrap() = None;
    {
        let mut creds = state.creds.lock().unwrap();
        creds.account_token = None;
        creds.account_name = None;
        creds.account_email = None;
        creds.device_id = None;
        creds.device_session_token = None;
        api::save_creds(&creds);
    }
    Ok(())
}

// MARK: - 观看历史

#[tauri::command]
fn get_history() -> Vec<api::WatchHistoryEntry> {
    api::load_history()
}

#[tauri::command]
fn clear_history() {
    api::clear_history();
}

#[tauri::command]
fn forget_device(device_id: String) {
    api::forget_device(&device_id);
}

#[tauri::command]
fn register_device(state: tauri::State<AppState>) -> Result<(), String> {
    let creds = state.creds.lock().unwrap().clone();
    let registration = api::register_device(&creds)?;

    // 设备凭据轮换后必须覆盖写入
    {
        let mut creds = state.creds.lock().unwrap();
        creds.device_id = Some(registration.device_id.clone());
        creds.device_session_token = Some(registration.session_token.clone());
        api::save_creds(&creds);
    }

    spawn_heartbeat(&state, registration);
    Ok(())
}

#[tauri::command]
fn start_publish(state: tauri::State<AppState>) -> Result<(), String> {
    let registration = state
        .registration
        .lock()
        .unwrap()
        .clone()
        .ok_or("设备尚未注册")?;

    let mut session = state.session.lock().unwrap();
    if session.is_some() {
        return Ok(()); // 已在投送
    }
    let (share_height, share_fps) = {
        let creds = state.creds.lock().unwrap();
        (creds.share_height, creds.share_fps)
    };
    let new_session = match publisher::start_publish(
        &registration.livekit_url,
        &registration.publish_token,
        state.last_error.clone(),
        share_height,
        share_fps,
    ) {
        Ok(session) => session,
        Err(error) => return Err(error),
    };
    *state.last_error.lock().unwrap() = None;
    *session = Some(new_session);
    Ok(())
}

#[tauri::command]
fn stop_publish(state: tauri::State<AppState>) -> Result<(), String> {
    if let Some(session) = state.session.lock().unwrap().take() {
        session.stop();
    }
    Ok(())
}

/// 刷新连接密码（旧密码立即失效）。
#[tauri::command]
fn refresh_password(state: tauri::State<AppState>) -> Result<String, String> {
    let (device_id, session_token) = {
        let registration = state.registration.lock().unwrap();
        let registration = registration.as_ref().ok_or("设备尚未注册")?;
        (registration.device_id.clone(), registration.session_token.clone())
    };
    let password = api::refresh_password(&device_id, &session_token)?;
    {
        let mut registration = state.registration.lock().unwrap();
        if let Some(registration) = registration.as_mut() {
            registration.password = password.clone();
        }
    }
    Ok(password)
}

/// 保存画质设置；正在投送时自动以新画质重启会话。
#[tauri::command]
fn set_quality(height: u32, fps: u32, state: tauri::State<AppState>) -> Result<(), String> {
    {
        let mut creds = state.creds.lock().unwrap();
        creds.share_height = height;
        creds.share_fps = fps;
        api::save_creds(&creds);
    }
    let was_publishing = {
        let mut session = state.session.lock().unwrap();
        match session.take() {
            Some(session) => {
                session.stop();
                true
            }
            None => false,
        }
    };
    if was_publishing {
        start_publish(state)?;
    }
    Ok(())
}

/// 开始观看远端设备：先向服务端取观看票（自己的设备免密码），再订阅其屏幕轨道。
#[tauri::command]
fn start_watch(
    device_id: String,
    password: String,
    state: tauri::State<AppState>,
) -> Result<String, String> {
    {
        let mut watch = state.watch.lock().unwrap();
        if let Some(session) = watch.take() {
            session.stop();
        }
    }
    *state.watch_error.lock().unwrap() = None;
    *state.frames.lock().unwrap() = None;

    let account_token = state.creds.lock().unwrap().account_token.clone();
    let ticket = api::connect(&device_id, &password, account_token.as_deref(), "RemoteScreen 桌面端")?;
    // 连接成功才写入历史（点击重连时就能看到设备名）
    let own = state
        .creds
        .lock()
        .unwrap()
        .device_id
        .as_deref()
        .map(|own_id| own_id == ticket.device_id)
        .unwrap_or(false);
    api::record_watch(&ticket.device_id, &ticket.device_name, own);
    let session = viewer::start_watch(
        &ticket.livekit_url,
        &ticket.token,
        &ticket.device_name,
        state.watch_error.clone(),
        state.frames.clone(),
        state.watch_stats.clone(),
        state.audio.clone(),
    )?;
    *state.watch.lock().unwrap() = Some(session);
    Ok(ticket.device_name)
}

#[tauri::command]
fn stop_watch(state: tauri::State<AppState>) -> Result<(), String> {
    if let Some(session) = state.watch.lock().unwrap().take() {
        session.stop();
    }
    *state.frames.lock().unwrap() = None;
    Ok(())
}

/// 打开（或聚焦）独立的观看窗口 —— 画面与控制条都在这个窗口里。
#[tauri::command]
fn open_viewer_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("viewer") {
        let _ = window.set_focus();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(&app, "viewer", tauri::WebviewUrl::App("viewer.html".into()))
        .title("RemoteScreen 观看")
        .inner_size(1100.0, 760.0)
        .min_inner_size(520.0, 360.0)
        .build()
        .map_err(|error| format!("打开观看窗口失败: {error}"))?;
    Ok(())
}

#[tauri::command]
fn close_viewer_window(app: tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("viewer") {
        let _ = window.close();
    }
}

#[tauri::command]
fn set_viewer_fullscreen(app: tauri::AppHandle, fullscreen: bool) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("viewer") {
        window
            .set_fullscreen(fullscreen)
            .map_err(|error| format!("全屏切换失败: {error}"))?;
    }
    Ok(())
}

/// 远端音频开关：没有音频轨时返回 false，界面据此提示「对方未发送声音」。
#[tauri::command]
fn set_audio_enabled(enabled: bool, state: tauri::State<AppState>) -> Result<bool, String> {
    match state.audio.lock().unwrap().as_ref() {
        Some(track) => {
            if enabled {
                track.enable();
            } else {
                track.disable();
            }
            Ok(true)
        }
        None => Ok(false),
    }
}

#[tauri::command]
fn has_audio(state: tauri::State<AppState>) -> bool {
    state.audio.lock().unwrap().is_some()
}

#[derive(Serialize)]
struct WatchStateDto {
    watching: bool,
    width: u32,
    height: u32,
    fps: u32,
    frames: u64,
    device_name: String,
    error: String,
    convert_ms: f32,
    encode_ms: f32,
    has_audio: bool,
}

#[tauri::command]
fn get_watch_state(state: tauri::State<AppState>) -> WatchStateDto {
    let stats = state.watch_stats.lock().unwrap().clone();
    WatchStateDto {
        watching: stats.active,
        width: stats.width,
        height: stats.height,
        fps: stats.fps,
        frames: stats.frames,
        device_name: stats.device_name,
        error: state.watch_error.lock().unwrap().clone().unwrap_or_default(),
        convert_ms: stats.convert_ms,
        encode_ms: stats.encode_ms,
        has_audio: state.audio.lock().unwrap().is_some(),
    }
}

/// 无界面自检：连接设备、订阅画面并打印统计（用于命令行验证观看链路）。
/// 用法：remotescreen-desktop --watch-test <设备ID> [密码] [秒数]
fn run_watch_test(device_id: &str, password: &str, seconds: u64) {
    let creds = api::load_creds();
    let ticket = match api::connect(device_id, password, creds.account_token.as_deref(), "watch-test") {
        Ok(ticket) => ticket,
        Err(error) => {
            println!("取票失败: {error}");
            return;
        }
    };
    println!("已取票 → 设备 {} / 房间 {} 已建立", ticket.device_name, ticket.device_id);

    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    runtime.block_on(async {
        let stats = Arc::new(Mutex::new(viewer::WatchStats::default()));
        let frames: viewer::FrameStore = Arc::new(Mutex::new(None));
        let error_sink = Arc::new(Mutex::new(None));
        let audio: viewer::AudioTrackStore = Arc::new(Mutex::new(None));
        let session = viewer::start_watch(
            &ticket.livekit_url,
            &ticket.token,
            &ticket.device_name,
            error_sink.clone(),
            frames.clone(),
            stats.clone(),
            audio,
        )
        .unwrap();

        for second in 1..=seconds {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let snapshot = stats.lock().unwrap().clone();
            let jpeg_kb = frames.lock().unwrap().as_ref().map(|f| f.len() / 1024).unwrap_or(0);
            println!(
                "[{second:2}s] {}x{} {}fps 累计{}帧 jpeg={}KB 转换{:.1}ms 编码{:.1}ms err={:?}",
                snapshot.width,
                snapshot.height,
                snapshot.fps,
                snapshot.frames,
                jpeg_kb,
                snapshot.convert_ms,
                snapshot.encode_ms,
                error_sink.lock().unwrap().clone()
            );
        }
        session.stop();
    });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 3 && args[1] == "--watch-test" {
        run_watch_test(
            &args[2],
            args.get(3).map(|value| value.as_str()).unwrap_or(""),
            args.get(4).and_then(|value| value.parse().ok()).unwrap_or(20),
        );
        return;
    }

    let initial_creds = api::load_creds();
    let frames_for_protocol = Arc::new(Mutex::new(None::<Vec<u8>>));
    let frames = frames_for_protocol.clone();

    tauri::Builder::default()
        .manage(AppState {
            creds: Mutex::new(initial_creds.clone()),
            registration: Mutex::new(None),
            heartbeat_stop: Mutex::new(None),
            session: Mutex::new(None),
            last_error: Arc::new(Mutex::new(None)),
            watch: Mutex::new(None),
            watch_error: Arc::new(Mutex::new(None)),
            frames,
            watch_stats: Arc::new(Mutex::new(viewer::WatchStats::default())),
            audio: Arc::new(Mutex::new(None)),
        })
        .setup(move |app| {
            // 启动自检流程：先补齐账号信息（顺带校验令牌），再注册设备并恢复心跳。
            // 注意：所有凭据读写都走 state 里的那一份，避免旧快照把新写入覆盖掉。
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let state = handle.state::<AppState>();
                let token = state.creds.lock().unwrap().account_token.clone();
                let Some(token) = token else { return };

                if state.creds.lock().unwrap().account_name.is_none() {
                    match api::fetch_me(&token) {
                        Ok((name, email)) => {
                            let mut stored = state.creds.lock().unwrap();
                            stored.account_name = Some(name);
                            stored.account_email = Some(email);
                            api::save_creds(&stored);
                            println!("[startup] 账号信息已补全");
                        }
                        Err(error) => {
                            // 令牌失效：清登录态回到登录页
                            viewer::log_to_file(&format!("[startup] /v1/me 失败，清除登录态: {error}"));
                            let mut stored = state.creds.lock().unwrap();
                            stored.account_token = None;
                            stored.account_name = None;
                            stored.account_email = None;
                            stored.device_id = None;
                            stored.device_session_token = None;
                            api::save_creds(&stored);
                            return;
                        }
                    }
                }

                let creds = state.creds.lock().unwrap().clone();
                match api::register_device(&creds) {
                    Ok(registration) => {
                        let mut stored = state.creds.lock().unwrap();
                        stored.device_id = Some(registration.device_id.clone());
                        stored.device_session_token = Some(registration.session_token.clone());
                        api::save_creds(&stored);
                        drop(stored);
                        spawn_heartbeat(&state, registration);
                    }
                    Err(error) => {
                        let message = format!("设备注册失败：{error}");
                        viewer::log_to_file(&message);
                        *state.last_error.lock().unwrap() = Some(message);
                    }
                }
            });

            // 触发方式：环境变量 RS_AUTO_WATCH，或 ~/.remotescreen-autowatch 文件内容
            let auto_watch = std::env::var("RS_AUTO_WATCH").ok().or_else(|| {
                dirs::home_dir()
                    .and_then(|home| std::fs::read_to_string(home.join(".remotescreen-autowatch")).ok())
                    .map(|text| text.trim().to_string())
            });
            if let Some(device_id) = auto_watch.filter(|value| !value.is_empty()) {
                viewer::log_to_file(&format!("[autowatch] 启动，目标设备 {device_id}"));
                let handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(1500)).await;
                    let state = handle.state::<AppState>();
                    let account_token = state.creds.lock().unwrap().account_token.clone();
                    match api::connect(&device_id, "", account_token.as_deref(), "自检") {
                        Ok(ticket) => {
                            viewer::log_to_file(&format!("[autowatch] 取票成功 {}", ticket.device_id));
                            let own = state
                                .creds
                                .lock()
                                .unwrap()
                                .device_id
                                .as_deref()
                                .map(|own_id| own_id == ticket.device_id)
                                .unwrap_or(false);
                            api::record_watch(&ticket.device_id, &ticket.device_name, own);
                            if let Ok(session) = viewer::start_watch(
                                &ticket.livekit_url,
                                &ticket.token,
                                &ticket.device_name,
                                state.watch_error.clone(),
                                state.frames.clone(),
                                state.watch_stats.clone(),
                                state.audio.clone(),
                            ) {
                                viewer::log_to_file("[autowatch] 观看会话已启动");
                                *state.watch.lock().unwrap() = Some(session);
                                // 自检时一并打开独立观看窗口
                                let _ = open_viewer_window(handle.clone());
                            }
                        }
                        Err(error) => {
                            viewer::log_to_file(&format!("[autowatch] 取票失败 {error}"));
                            *state.watch_error.lock().unwrap() = Some(error);
                        }
                    }
                });
            }
            Ok(())
        })
        .register_asynchronous_uri_scheme_protocol("frame", move |_ctx, _request, responder| {
            // 前端 canvas 通过 frame://localhost/latest 拉取最新一帧 JPEG
            let body = frames_for_protocol.lock().unwrap().clone();
            let response = match body {
                Some(bytes) => tauri::http::Response::builder()
                    .header("Content-Type", "image/jpeg")
                    .header("Cache-Control", "no-store")
                    .body(bytes)
                    .unwrap(),
                None => tauri::http::Response::builder()
                    .status(204)
                    .body(Vec::new())
                    .unwrap(),
            };
            responder.respond(response);
        })
        .invoke_handler(tauri::generate_handler![
            get_state,
            login,
            register_device,
            start_publish,
            stop_publish,
            set_quality,
            refresh_password,
            start_watch,
            stop_watch,
            get_watch_state,
            open_viewer_window,
            close_viewer_window,
            set_viewer_fullscreen,
            set_audio_enabled,
            has_audio,
            logout,
            get_history,
            clear_history,
            forget_device
        ])
        .run(tauri::generate_context!())
        .expect("tauri 应用启动失败");
}
