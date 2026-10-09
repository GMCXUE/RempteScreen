// RemoteScreen Rust 桌面端 —— Tauri 2 应用入口。
//
// 架构：Rust 侧持有全部业务（服务端 API、心跳、原生采集推流），
// 前端只是个壳，通过 invoke 调命令、轮询状态渲染界面。
mod api;
mod publisher;
mod viewer;

use tauri::{Emitter, Manager};
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
    /// 正在等待对方同意的连接请求（界面据此显示「等待同意」）
    pending_request: Arc<Mutex<Option<PendingRequest>>>,
    /// 别人发给我们这台设备的观看请求（待同意）
    incoming_requests: Arc<Mutex<Vec<api::IncomingRequest>>>,
}

struct PendingRequest {
    request_id: String,
    device_name: String,
    expires_at: i64,
    stop: Arc<AtomicBool>,
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

fn spawn_heartbeat(app: &tauri::AppHandle, registration: api::Registration) {
    let state = app.state::<AppState>();
    // 停掉旧的心跳
    if let Some(old) = state.heartbeat_stop.lock().unwrap().take() {
        old.store(true, Ordering::Relaxed);
    }
    let stop = Arc::new(AtomicBool::new(false));
    *state.heartbeat_stop.lock().unwrap() = Some(stop.clone());
    *state.registration.lock().unwrap() = Some(registration.clone());

    // 启动时请求麦克风权限（弹窗归属应用）：webrtc 音频数据泵由麦克风设备驱动，
    // 没有授权时泵不转，音频帧发不出去。提前拿到授权，投送时就不会卡权限。
    {
        if let Some(helper) = find_audio_capture_helper() {
            std::thread::spawn(move || {
                if let Ok(output) = std::process::Command::new(helper)
                    .arg("--request-mic")
                    .stderr(std::process::Stdio::piped())
                    .output()
                {
                    let text = String::from_utf8_lossy(&output.stderr);
                    for line in text.lines() {
                        crate::publisher::log_to_file(&format!("[mic] {line}"));
                    }
                }
            });
        }
    }

    // 用 SSE 长连接取代轮询：服务端一有变化立刻推（实测 ~10ms），
    // 连接每 10 分钟由服务端轮换一次，这里循环重连即可。
    // 心跳也由服务端在流内处理（每 15 秒刷新在线状态），客户端不再需要定时上报。
    let handle = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let state = handle.state::<AppState>();
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }

            let result = api::stream_notifications(
                &registration.device_id,
                &registration.session_token,
                &stop,
                |event, data| {
                    match event {
                        "requests" => {
                            let incoming: Vec<api::IncomingRequest> =
                                serde_json::from_value(data["pendingRequests"].clone())
                                    .unwrap_or_default();
                            *state.incoming_requests.lock().unwrap() = incoming;
                        }
                        // 有观看者连入（同账号直连时服务端通知）：自动打开投送，
                        // 否则对方只会停在「等待画面」。
                        // 注意：屏幕采集必须在**主线程**上启动（ScreenCaptureKit 需要
                        // runloop），SSE 消费线程是后台线程，直接调会报权限错误。
                        "viewer-connected" => {
                            let publishing = state.session.lock().unwrap().is_some();
                            if !publishing {
                                let app_for_main = handle.clone();
                                let _ = handle.run_on_main_thread(move || {
                                    let main_state = app_for_main.state::<AppState>();
                                    match start_publish(main_state.clone()) {
                                        Ok(()) => viewer::log_to_file(
                                            "[viewer-connected] 观看者连入，已自动开启投送",
                                        ),
                                        Err(error) => viewer::log_to_file(&format!(
                                            "[viewer-connected] 自动开启投送失败: {error}"
                                        )),
                                    }
                                });
                            }
                        }
                        _ => {}
                    }
                },
            );

            if stop.load(Ordering::Relaxed) {
                break;
            }
            match result {
                Ok(()) => {
                    // 流正常结束（服务端 10 分钟轮换）→ 立即重连
                }
                Err(error) => {
                    eprintln!("[notifications] {error}");
                    // 网络抖动：退回一次普通心跳保活，稍后重连
                    let _ = api::heartbeat(&registration.device_id, &registration.session_token);
                    std::thread::sleep(std::time::Duration::from_secs(2));
                }
            }
        }
    });
}

/// 应用状态快照（每把锁都在独立作用域里取用完就释放，规则同 `watch_snapshot`）。
fn snapshot(state: &AppState) -> AppStateDto {
    let (logged_in, account_name, account_email, share_height, share_fps) = {
        let creds = state.creds.lock().unwrap();
        (
            creds.account_token.is_some(),
            creds.account_name.clone().unwrap_or_default(),
            creds.account_email.clone().unwrap_or_default(),
            creds.share_height,
            creds.share_fps,
        )
    };

    let (registered, device_id, password) = {
        let registration = state.registration.lock().unwrap();
        match registration.as_ref() {
            Some(registration) => (
                true,
                registration.device_id.clone(),
                registration.password.clone(),
            ),
            None => (false, String::new(), String::new()),
        }
    };

    let publishing = state.session.lock().unwrap().is_some();
    let last_error = state.last_error.lock().unwrap().clone().unwrap_or_default();

    AppStateDto {
        logged_in,
        registered,
        device_id,
        password,
        publishing,
        last_error,
        share_height,
        share_fps,
        account_name,
        account_email,
    }
}

#[tauri::command]
fn get_state(state: tauri::State<AppState>) -> AppStateDto {
    snapshot(&state)
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

// MARK: - 收到的观看请求（本机被别人请求观看）

#[tauri::command]
fn get_incoming_requests(state: tauri::State<AppState>) -> Vec<api::IncomingRequest> {
    state.incoming_requests.lock().unwrap().clone()
}

fn registration_device_id(state: &AppState) -> String {
    state
        .registration
        .lock()
        .unwrap()
        .as_ref()
        .map(|registration| registration.device_id.clone())
        .unwrap_or_default()
}

#[tauri::command]
fn decide_incoming_request(
    request_id: String,
    approve: bool,
    app: tauri::AppHandle,
    state: tauri::State<AppState>,
) -> Result<(), String> {
    let session_token = state
        .registration
        .lock()
        .unwrap()
        .as_ref()
        .map(|registration| registration.session_token.clone())
        .ok_or("设备尚未注册")?;
    if let Err(error) = api::decide_connect_request(&request_id, &session_token, approve) {
        // 决策失败多半是请求已失效（观看方取消 / 过期 / 重复处理）：
        // 本地这份列表已过期，立刻重新拉取，横幅随之消失。
        viewer::log_to_file(&format!("[decision] 处理失败，已刷新列表: {error}"));
        let fresh = api::heartbeat(&registration_device_id(&state), &session_token);
        if let Ok(incoming) = fresh {
            *state.incoming_requests.lock().unwrap() = incoming;
        }
        return Err(error);
    }

    // 同意观看后自动开启投送（等价于用户手动打开「允许远程观看本设备」），
    // 否则对方连上了却看不到画面。
    if approve {
        let publishing = state.session.lock().unwrap().is_some();
        if !publishing {
            if let Err(error) = start_publish(state.clone()) {
                viewer::log_to_file(&format!("[approve] 自动开启投送失败: {error}"));
            } else {
                viewer::log_to_file("[approve] 已同意观看请求并自动开启投送");
            }
        }
    }
    state
        .incoming_requests
        .lock()
        .unwrap()
        .retain(|request| request.request_id != request_id);
    Ok(())
}

// MARK: - 我的设备

/// 账号名下的设备列表（用于「我的设备」页）。
#[tauri::command]
fn list_devices(state: tauri::State<AppState>) -> Result<Vec<api::DeviceInfo>, String> {
    let token = state
        .creds
        .lock()
        .unwrap()
        .account_token
        .clone()
        .ok_or("请先登录")?;
    api::list_devices(&token)
}

#[tauri::command]
fn rename_device(device_id: String, name: String, state: tauri::State<AppState>) -> Result<(), String> {
    let token = state
        .creds
        .lock()
        .unwrap()
        .account_token
        .clone()
        .ok_or("请先登录")?;
    api::rename_device(&token, &device_id, &name)?;
    // 本机改名后同步到界面显示
    if let Some(registration) = state.registration.lock().unwrap().as_mut() {
        if registration.device_id == device_id {
            registration.device_name = name;
        }
    }
    Ok(())
}

/// 解绑设备。若解绑的是本机，则同时停掉投送与观看并清空本机凭据
///（下次启动会被当作新设备重新注册，拿到新的设备代码）。
#[tauri::command]
fn unbind_device(device_id: String, state: tauri::State<AppState>) -> Result<(), String> {
    let token = state
        .creds
        .lock()
        .unwrap()
        .account_token
        .clone()
        .ok_or("请先登录")?;
    api::unbind_device(&token, &device_id)?;

    let is_local = state
        .registration
        .lock()
        .unwrap()
        .as_ref()
        .map(|registration| registration.device_id == device_id)
        .unwrap_or(false);

    if is_local {
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
        let mut creds = state.creds.lock().unwrap();
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
fn register_device(app: tauri::AppHandle, state: tauri::State<AppState>) -> Result<(), String> {
    let creds = state.creds.lock().unwrap().clone();
    let registration = api::register_device(&creds)?;

    // 设备凭据轮换后必须覆盖写入
    {
        let mut creds = state.creds.lock().unwrap();
        creds.device_id = Some(registration.device_id.clone());
        creds.device_session_token = Some(registration.session_token.clone());
        api::save_creds(&creds);
    }

    spawn_heartbeat(&app, registration);
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

/// 自定义连接密码（设备本人的权利，旧密码立即失效）。
#[tauri::command]
fn set_device_password(password: String, state: tauri::State<AppState>) -> Result<String, String> {
    let (device_id, session_token) = {
        let registration = state.registration.lock().unwrap();
        let registration = registration.as_ref().ok_or("设备尚未注册")?;
        (registration.device_id.clone(), registration.session_token.clone())
    };
    let applied = api::set_password(&device_id, &session_token, Some(&password))?;
    {
        let mut registration = state.registration.lock().unwrap();
        if let Some(registration) = registration.as_mut() {
            registration.password = applied.clone();
        }
    }
    Ok(applied)
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
/// 开始观看。三种路径：
///   ① 自己名下的设备 → 免密码直连
///   ② 提供了连接密码 → 按密码直连（对外分享的老路径）
///   ③ 其他情况 → 向设备发起「观看请求」，对方在设备上同意后才建立连接
#[tauri::command]
fn start_watch(
    device_id: String,
    password: String,
    app: tauri::AppHandle,
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

    // 本机不能观看本机：屏幕就在眼前，自连只会白占一路上行
    let is_self = state
        .registration
        .lock()
        .unwrap()
        .as_ref()
        .map(|registration| registration.device_id == device_id)
        .unwrap_or(false);
    if is_self {
        return Err("不能观看本机屏幕，请在你这台设备之外的另一台设备上观看".into());
    }

    // 同账号设备免确认直连（账号即授权）；跨账号才需要设备端点头。
    // 无密码 + 非自有设备 → 发起观看请求，等对方同意。
    let mine = account_token
        .as_deref()
        .map(|token| api::device_is_mine(token, &device_id))
        .unwrap_or(false);
    if !mine && password.is_empty() {
        let outcome =
            api::create_connect_request(account_token.as_deref(), &device_id, "RemoteScreen 桌面端")?;
        return request_approval(&app, &state, outcome);
    }

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

/// 发起观看请求并后台轮询等待对方同意。同意后自动建立观看会话并打开观看窗口。
fn request_approval(
    app: &tauri::AppHandle,
    state: &tauri::State<AppState>,
    outcome: api::RequestOutcome,
) -> Result<String, String> {
    // 同一时间只保留一个待批准请求
    if let Some(previous) = state.pending_request.lock().unwrap().take() {
        previous.stop.store(true, Ordering::Relaxed);
    }

    let stop = Arc::new(AtomicBool::new(false));
    let expires_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|t| t.as_secs() as i64 + outcome.expires_in_sec as i64)
        .unwrap_or(0);
    let device_name = if outcome.device_name.is_empty() {
        outcome.request_id.clone()
    } else {
        outcome.device_name.clone()
    };

    *state.pending_request.lock().unwrap() = Some(PendingRequest {
        request_id: outcome.request_id.clone(),
        device_name: device_name.clone(),
        expires_at,
        stop: stop.clone(),
    });

    let handle = app.clone();
    let request_id = outcome.request_id.clone();
    tauri::async_runtime::spawn(async move {
        let state = handle.state::<AppState>();
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }

            // 长轮询：服务端挂住 20 秒，对方一决策就立刻返回
            match api::poll_connect_request_long(&request_id, 20) {
                Ok(api::PollOutcome::Pending) => continue,
                Ok(api::PollOutcome::Denied) => {
                    *state.watch_error.lock().unwrap() = Some("对方拒绝了这次观看请求".into());
                    break;
                }
                Ok(api::PollOutcome::Expired) => {
                    *state.watch_error.lock().unwrap() =
                        Some("观看请求已超时（对方未在 60 秒内确认）".into());
                    break;
                }
                Ok(api::PollOutcome::Approved(grant)) => {
                    // 记录历史（自有与否以账号归属为准）。
                    // 注意：先把令牌取出来再发网络请求 —— 绝不能持锁做 I/O，
                    // 否则界面轮询（get_state）会被同一个锁堵住，表现就是「应用卡死」。
                    let token = { state.creds.lock().unwrap().account_token.clone() };
                    let own = token
                        .as_deref()
                        .map(|token| {
                            api::device_is_mine(token, grant.room_name.trim_start_matches("device-"))
                        })
                        .unwrap_or(false);
                    api::record_watch(
                        grant.room_name.trim_start_matches("device-"),
                        &grant.device_name,
                        own,
                    );

                    match viewer::start_watch(
                        &grant.livekit_url,
                        &grant.token,
                        &grant.device_name,
                        state.watch_error.clone(),
                        state.frames.clone(),
                        state.watch_stats.clone(),
                        state.audio.clone(),
                    ) {
                        Ok(session) => {
                            *state.watch.lock().unwrap() = Some(session);
                            let _ = open_viewer_window(handle.clone());
                        }
                        Err(error) => {
                            *state.watch_error.lock().unwrap() = Some(error);
                        }
                    }
                    break;
                }
                Err(error) => {
                    *state.watch_error.lock().unwrap() = Some(format!("请求状态查询失败：{error}"));
                    break;
                }
            }
        }
        *state.pending_request.lock().unwrap() = None;
    });

    Ok(format!("已向「{device_name}」发送观看请求，等待对方同意…"))
}

/// 取消正在等待的观看请求。
#[tauri::command]
fn cancel_watch_request(state: tauri::State<AppState>) -> Result<(), String> {
    let taken = state.pending_request.lock().unwrap().take();
    if let Some(pending) = taken {
        pending.stop.store(true, Ordering::Relaxed);
        // 同步告诉服务端：对方那边会立刻不再显示这个请求（否则只能等 60 秒过期）
        let _ = api::cancel_connect_request(&pending.request_id);
    }
    Ok(())
}

#[tauri::command]
fn stop_watch(state: tauri::State<AppState>) -> Result<(), String> {
    if let Some(session) = state.watch.lock().unwrap().take() {
        session.stop();
    }
    *state.frames.lock().unwrap() = None;
    *state.audio.lock().unwrap() = None;
    // 立即复位统计与错误，界面据此收起「正在观看」卡片
    *state.watch_stats.lock().unwrap() = viewer::WatchStats::default();
    *state.watch_error.lock().unwrap() = None;
    Ok(())
}

/// 打开（或聚焦）独立的观看窗口 —— 画面与控制条都在这个窗口里。
#[tauri::command]
fn open_viewer_window(app: tauri::AppHandle) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("viewer") {
        let _ = window.set_focus();
        return Ok(());
    }
    let window =
        tauri::WebviewWindowBuilder::new(&app, "viewer", tauri::WebviewUrl::App("viewer.html".into()))
            .title("RemoteScreen 观看")
            .inner_size(1100.0, 760.0)
            .min_inner_size(520.0, 360.0)
            .build()
            .map_err(|error| format!("打开观看窗口失败: {error}"))?;

    // 点窗口关闭按钮（×）时：正在观看就先拦下来，让界面确认「关闭会断开连接」。
    let handle = app.clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            let watching = {
                let state = handle.state::<AppState>();
                let watching = state.watch.lock().unwrap().is_some();
                watching
            };
            if watching {
                api.prevent_close();
                let _ = handle.emit_to("viewer", "viewer:close-requested", ());
            }
        }
    });
    Ok(())
}

/// 界面侧写入诊断日志（观看窗口的交互状态记录在 ~/.remotescreen-rs.log，
/// 便于窗口被遮挡或远程排查时确认行为）。
#[tauri::command]
fn ui_log(message: String) {
    viewer::log_to_file(&format!("[ui] {message}"));
}

#[tauri::command]
fn close_viewer_window(app: tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("viewer") {
        // 用 destroy 而不是 close：close 会再次触发 CloseRequested，
        // 而那里为了「确认后断开」做了拦截，会互相递归。
        let _ = window.destroy();
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
    /// 等待对方同意的请求：空字符串表示没有
    pending_device: String,
    pending_seconds: i64,
}

/// 观看状态快照。
///
/// ⚠️ 每把锁都必须在**独立语句**（或显式作用域）里取用完就释放。
/// 曾经在同一个结构体字面量里对 `pending_request` 取了两次 ——
/// 结构体字面量的临时值会活到整条语句结束，而 Mutex 不可重入，
/// 于是每次轮询都死锁，界面直接卡死。
fn watch_snapshot(state: &AppState) -> WatchStateDto {
    let stats = state.watch_stats.lock().unwrap().clone();
    let error = state.watch_error.lock().unwrap().clone().unwrap_or_default();
    let has_audio = state.audio.lock().unwrap().is_some();

    let (pending_device, pending_seconds) = {
        let pending = state.pending_request.lock().unwrap();
        match pending.as_ref() {
            Some(pending) => {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|t| t.as_secs() as i64)
                    .unwrap_or(0);
                (pending.device_name.clone(), (pending.expires_at - now).max(0))
            }
            None => (String::new(), 0),
        }
    };

    WatchStateDto {
        watching: stats.active,
        width: stats.width,
        height: stats.height,
        fps: stats.fps,
        frames: stats.frames,
        device_name: stats.device_name,
        error,
        convert_ms: stats.convert_ms,
        encode_ms: stats.encode_ms,
        has_audio,
        pending_device,
        pending_seconds,
    }
}

#[tauri::command]
fn get_watch_state(state: tauri::State<AppState>) -> WatchStateDto {
    watch_snapshot(&state)
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
            audio.clone(),
        )
        .unwrap();

        // 接收端音频振幅测量：有 NativeAudioStream 拉到的帧才有数据，
        // 以此区分「轨订阅了但没数据」和「数据真的在流动」
        let mut audio_meter: Option<(i32, u32)> = None; // (峰值, 帧数)
        for second in 1..=seconds {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let snapshot = stats.lock().unwrap().clone();
            let jpeg_kb = frames.lock().unwrap().as_ref().map(|f| f.len() / 1024).unwrap_or(0);
            let audio_info = match audio.lock().unwrap().as_ref() {
                Some(track) => match audio_meter {
                    Some((peak, frames)) => {
                        if peak > 3000 {
                            format!("已收到✅ 有声音（峰值 {peak}，{frames} 帧）")
                        } else {
                            format!("已收到但静音（峰值 {peak}，{frames} 帧）")
                        }
                    }
                    None => "已订阅（测量中…）".to_string(),
                },
                None => "无".to_string(),
            };
            println!(
                "[{second:2}s] {}x{} {}fps 累计{}帧 jpeg={}KB 音频轨={audio_info} err={:?}",
                snapshot.width,
                snapshot.height,
                snapshot.fps,
                snapshot.frames,
                jpeg_kb,
                error_sink.lock().unwrap().clone()
            );

            // 音频轨出现后，挂一个 NativeAudioStream 测量接收到的振幅
            if audio_meter.is_none() {
                if let Some(track) = audio.lock().unwrap().as_ref() {
                    let mut stream =
                        livekit::webrtc::audio_stream::native::NativeAudioStream::new(
                            track.rtc_track(),
                            48_000,
                            1,
                        );
                    audio_meter = Some((0, 0));
                    tokio::spawn(async move {
                        use tokio_stream::StreamExt;
                        let mut stream = stream;
                        while let Some(frame) = stream.next().await {
                            let peak = frame
                                .data
                                .iter()
                                .map(|s| (*s as i32).abs())
                                .max()
                                .unwrap_or(0);
                            if let Some((ref mut max, ref mut frames)) = audio_meter {
                                if peak > *max {
                                    *max = peak;
                                }
                                *frames += 1;
                            }
                        }
                    });
                }
            }
        }
        session.stop();
    });
}

/// 定位音频采集器：优先应用包内（Contents/MacOS），开发态用 target/release 与 tools 目录
fn find_audio_capture_helper() -> Option<std::path::PathBuf> {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|p| p.to_path_buf()));
    [
        exe_dir.as_ref().map(|d| d.join("macos-audio-capture")),
        std::env::var("CARGO_MANIFEST_DIR").ok().map(|dir| {
            std::path::PathBuf::from(dir).join("../../tools/macos-audio-capture/macos-audio-capture")
        }),
    ]
    .into_iter()
    .flatten()
    .find(|path| path.exists())
}

/// 无界面自检：启动投送（屏幕 + 系统音频）N 秒后自动结束，验证音频轨发布。
/// 用法：remotescreen-desktop --publish-test <秒数>
fn run_publish_test(seconds: u64) {
    // 投送需要**发布令牌**（canPublish）；重新注册一次即可拿到（和启动时一样）
    let creds = api::load_creds();
    let registration = match api::register_device(&creds) {
        Ok(registration) => registration,
        Err(error) => {
            println!("注册失败: {error}");
            return;
        }
    };
    // 凭据轮换后覆盖写入
    let mut creds = creds;
    creds.device_id = Some(registration.device_id.clone());
    creds.device_session_token = Some(registration.session_token.clone());
    api::save_creds(&creds);

    println!(
        "开始投送（{seconds} 秒）→ 房间 device-{}",
        registration.device_id
    );

    let session = match publisher::start_publish(
        &registration.livekit_url,
        &registration.publish_token,
        Arc::new(Mutex::new(None)),
        1080,
        30,
    ) {
        Ok(session) => session,
        Err(error) => {
            println!("投送启动失败: {error}");
            return;
        }
    };

    std::thread::sleep(std::time::Duration::from_secs(seconds));
    session.stop();
    println!("投送已停止（音频轨是否发布看上方日志与 LiveKit）");
}

/// 无界面自检：验证状态快照不会死锁。
///
/// 这是回归防线 —— 「结构体字面量里重复加锁」这类死锁只在运行期暴露，
/// 编译器不会报错，所以用命令行自检真跑一遍。
fn run_state_check() {
    let state = AppState {
        creds: Mutex::new(api::load_creds()),
        registration: Mutex::new(None),
        heartbeat_stop: Mutex::new(None),
        session: Mutex::new(None),
        last_error: Arc::new(Mutex::new(None)),
        watch: Mutex::new(None),
        watch_error: Arc::new(Mutex::new(None)),
        frames: Arc::new(Mutex::new(None)),
        watch_stats: Arc::new(Mutex::new(viewer::WatchStats::default())),
        audio: Arc::new(Mutex::new(None)),
        pending_request: Arc::new(Mutex::new(Some(PendingRequest {
            request_id: "self-check".into(),
            device_name: "自检设备".into(),
            expires_at: 4_000_000_000,
            stop: Arc::new(AtomicBool::new(false)),
        }))),
        incoming_requests: Arc::new(Mutex::new(Vec::new())),
    };

    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for _ in 0..5 {
            let app = snapshot(&state);
            let watch = watch_snapshot(&state);
            let _ = tx.send((app.logged_in, watch.pending_device, watch.pending_seconds));
        }
    });

    match rx.recv_timeout(std::time::Duration::from_secs(3)) {
        Ok((logged_in, device, seconds)) => println!(
            "✅ 两个状态快照都正常返回（logged_in={logged_in} 等待中设备={device} 剩余{seconds}s）"
        ),
        Err(_) => {
            println!("❌ 状态快照超时 —— 存在死锁");
            std::process::exit(1);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() >= 2 && args[1] == "--state-check" {
        run_state_check();
        return;
    }
    if args.len() >= 3 && args[1] == "--publish-test" {
        let seconds: u64 = args[2].parse().unwrap_or(20);
        run_publish_test(seconds);
        return;
    }
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
            pending_request: Arc::new(Mutex::new(None)),
            incoming_requests: Arc::new(Mutex::new(Vec::new())),
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
                        spawn_heartbeat(&handle, registration);
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
            set_device_password,
            start_watch,
            cancel_watch_request,
            stop_watch,
            get_incoming_requests,
            decide_incoming_request,
            get_watch_state,
            open_viewer_window,
            close_viewer_window,
            ui_log,
            set_viewer_fullscreen,
            set_audio_enabled,
            has_audio,
            logout,
            list_devices,
            rename_device,
            unbind_device,
            get_history,
            clear_history,
            forget_device
        ])
        .run(tauri::generate_context!())
        .expect("tauri 应用启动失败");
}
