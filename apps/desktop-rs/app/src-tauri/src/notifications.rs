//! Native account polling keeps system notifications independent of webview timers.
//! Current scope requires the app to remain running. Future push delivery must
//! reuse account validation and messaging-action routing (see notification-delivery.md).
use crate::api;
use crate::notification_policy::{can_ring, should_alert, show_call_panel, message_previews};
use std::{
    collections::{HashMap, HashSet},
    process::{Child, Command},
    sync::Mutex,
    time::Duration,
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::{Emitter, Manager};
use tauri_plugin_notification::{Action, ActionType, NotificationExt};
#[derive(Default)]
pub struct NotificationContext {
    pub peer: Mutex<Option<String>>,
    diagnostics: Mutex<serde_json::Value>,
    ring: Mutex<Option<(String, u64, String)>>,
    stopped: Mutex<HashSet<String>>,
    dismissed_calls: Mutex<HashSet<String>>,
}
#[cfg(target_os = "macos")]
static NATIVE_APP: std::sync::OnceLock<tauri::AppHandle> = std::sync::OnceLock::new();
#[cfg(target_os = "macos")]
extern "C" {
    fn rs_notifications_init(callback: extern "C" fn(*const std::ffi::c_char));
    fn rs_notifications_post(json: *const std::ffi::c_char);
    fn rs_notifications_status();
    fn rs_notifications_remove(id: *const std::ffi::c_char);
    fn rs_call_panel_update(json: *const std::ffi::c_char);
    fn rs_call_panel_dismiss(id: *const std::ffi::c_char);
    fn rs_call_panel_prepare_answer(id: *const std::ffi::c_char);
}
fn record(app: &tauri::AppHandle, key: &str, value: serde_json::Value) {
    let state = app.state::<NotificationContext>();
    let mut data = state.diagnostics.lock().unwrap();
    if !data.is_object() {
        *data = serde_json::json!({});
    }
    data[key] = value;
    if let Ok(dir) = app.path().app_data_dir() {
        let _ = std::fs::create_dir_all(&dir);
        if let Ok(bytes) = serde_json::to_vec(&*data) {
            let _ = std::fs::write(dir.join("notification-diagnostics.json"), bytes);
        }
    }
}
#[cfg(target_os = "macos")]
extern "C" fn native_event(value: *const std::ffi::c_char) {
    if value.is_null() {
        return;
    }
    let Some(app) = NATIVE_APP.get() else { return };
    let text = unsafe { std::ffi::CStr::from_ptr(value) }.to_string_lossy();
    let Ok(data) = serde_json::from_str::<serde_json::Value>(&text) else {
        return;
    };
    match data["type"].as_str() {
        Some("action") => {
            let state = app.state::<NotificationContext>();
            if matches!(
                data["action"].as_str(),
                Some("answer" | "reject" | "hangup")
            ) {
                if let Some(id) = data["extra"]["callId"].as_str() {
                    state.stopped.lock().unwrap().insert(id.into());
                    if matches!(data["action"].as_str(), Some("reject" | "hangup")) {
                        let mut dismissed = state.dismissed_calls.lock().unwrap();
                        dismissed.insert(id.into());
                        dismiss_call_panel(id);
                    }
                    let mut ring = state.ring.lock().unwrap();
                    if ring.as_ref().is_some_and(|r| r.0 == id) {
                        *ring = None;
                    }
                }
            }
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
            let _ = app.emit(
                "messaging-action",
                serde_json::json!({"action":data["action"],"extra":data["extra"]}),
            );
        }
        Some("permission") => record(app, "permission", data),
        Some("delivery") => record(app, "delivery", data),
        _ => record(app, "nativeError", data["error"].clone()),
    }
}
#[cfg(not(target_os="macos"))]
fn notification_number(id: &str) -> i32 {
    use std::hash::{Hash,Hasher};
    let mut h=std::collections::hash_map::DefaultHasher::new();id.hash(&mut h);(h.finish() & 0x7fffffff) as i32
}
fn remove_message(app: &tauri::AppHandle, peer: &str) {
    let id=format!("message-{peer}");
    #[cfg(target_os="macos")]
    if let Ok(value)=std::ffi::CString::new(id) { unsafe {rs_notifications_remove(value.as_ptr());} }
    #[cfg(not(target_os="macos"))]
    let _=app.notification().remove_active(vec![notification_number(&id)]);
}
fn post(app: &tauri::AppHandle, title: &str, body: &str, extra: serde_json::Value, sound: bool) {
    record(
        app,
        "lastAttempt",
        serde_json::json!({"time":now(),"kind":extra["kind"]}),
    );
    let id = if extra["kind"] == "call" {
        format!("call-{}", extra["callId"].as_str().unwrap_or_default())
    } else {
        format!("message-{}", extra["peerId"].as_str().unwrap_or("friends"))
    };
    #[cfg(target_os = "macos")]
    {
        let payload = serde_json::json!({"id":id,"title":title,"body":body,"extra":extra,"sound":sound,"thread":if extra["kind"]=="message"{id.clone()}else{String::new()},"category":if extra["kind"]=="call"{"friend-call"}else{""}});
        if let Ok(text) = std::ffi::CString::new(payload.to_string()) {
            unsafe {
                rs_notifications_post(text.as_ptr());
            }
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let mut b = app.notification().builder().id(notification_number(&id)).title(title).body(body);
        if sound {
            b = b.sound("default");
        }
        if let Some(map) = extra.as_object() {
            for (k, v) in map {
                b = b.extra(k, v.as_str().unwrap_or_default());
            }
        }
        if let Err(e) = b.show() {
            record(app, "nativeError", serde_json::json!(e.to_string()));
        }
    }
}
#[tauri::command]
pub fn notification_diagnostics(app: tauri::AppHandle) -> serde_json::Value {
    #[cfg(target_os = "macos")]
    unsafe {
        rs_notifications_status();
    }
    app.state::<NotificationContext>()
        .diagnostics
        .lock()
        .unwrap()
        .clone()
}
#[tauri::command]
pub async fn test_notification(
    app: tauri::AppHandle,
    account_id: String,
    kind: String,
) -> Result<(), String> {
    if !["message", "call"].contains(&kind.as_str()) {
        return Err("不支持的提醒测试".into());
    }
    let settings = notification_settings(app.clone(), account_id.clone(), None).await?;
    let id = format!("test-{}", now());
    post(
        &app,
        "RemoteScreen 提醒测试",
        if kind == "call" {
            "来电铃声测试，6 秒后自动停止"
        } else {
            "这是一条本机测试通知"
        },
        serde_json::json!({"accountId":account_id,"kind":"test","callId":id,"peerId":"self-test"}),
        settings.message_sound && kind == "message",
    );
    if kind == "call" && settings.call_sound {
        *app.state::<NotificationContext>().ring.lock().unwrap() =
            Some((id, now() + 6000, "self-test".into()));
    }
    Ok(())
}
#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct AlertSettings {
    message_sound: bool,
    message_preview: bool,
    call_sound: bool,
    muted_peers: HashSet<String>,
}
impl Default for AlertSettings {
    fn default() -> Self {
        Self {
            message_sound: true,
            message_preview: true,
            call_sound: true,
            muted_peers: HashSet::new(),
        }
    }
}
fn settings_path(app: &tauri::AppHandle, account: &str) -> Option<std::path::PathBuf> {
    // Internal account IDs are UUIDs; never accept a path from the webview.
    let key: String = account
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
        .collect();
    app.path()
        .app_data_dir()
        .ok()
        .map(|p| p.join(format!("alerts-{key}.json")))
}
fn read_settings(app: &tauri::AppHandle, account: &str) -> AlertSettings {
    settings_path(app, account)
        .and_then(|p| std::fs::read(p).ok())
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}
#[tauri::command]
pub async fn notification_settings(
    app: tauri::AppHandle,
    account_id: String,
    value: Option<AlertSettings>,
) -> Result<AlertSettings, String> {
    tauri::async_runtime::spawn_blocking(move || update_settings(app, account_id, value))
        .await
        .map_err(|e| e.to_string())?
}
fn update_settings(
    app: tauri::AppHandle,
    account_id: String,
    value: Option<AlertSettings>,
) -> Result<AlertSettings, String> {
    let token = api::load_creds().account_token.ok_or("请先登录")?;
    let data = api::social("state", &token, serde_json::json!({}))?;
    if api::load_creds().account_token.as_deref() != Some(&token) {
        return Err("账号已变化".into());
    }
    let user = data["me"]["id"].as_str().ok_or("缺少账号")?;
    if user != account_id {
        return Err("账号已变化".into());
    }
    if let Some(value) = value {
        let path = settings_path(&app, user).ok_or("无法保存提醒设置")?;
        std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(path, serde_json::to_vec(&value).unwrap()).map_err(|e| e.to_string())?;
        if !value.message_preview {
            if let Ok(path)=app.path().app_data_dir() {
                if let Ok(bytes)=std::fs::read(path.join("notification-seen.json")) {
                    if let Ok(seen)=serde_json::from_slice::<HashMap<String,u64>>(&bytes) {
                        for key in seen.keys(){if let Some((_,peer))=key.split_once(':'){remove_message(&app,peer);}}
                    }
                }
            }
        }
        let state = app.state::<NotificationContext>();
        let mut ring = state.ring.lock().unwrap();
        if !value.call_sound
            || ring
                .as_ref()
                .is_some_and(|r| value.muted_peers.contains(&r.2))
        {
            *ring = None;
        }
        return Ok(value);
    }
    Ok(read_settings(&app, user))
}
#[tauri::command]
pub fn stop_notification_ring(call_id: String, state: tauri::State<NotificationContext>) {
    state.stopped.lock().unwrap().insert(call_id.clone());
    let mut ring = state.ring.lock().unwrap();
    if ring.as_ref().is_some_and(|r| r.0 == call_id) {
        *ring = None;
    }
}
#[tauri::command]
pub fn prepare_call_notification_answer(call_id: String) {
    #[cfg(target_os = "macos")]
    if let Ok(id) = std::ffi::CString::new(call_id) {
        unsafe {
            rs_call_panel_prepare_answer(id.as_ptr());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = call_id;
}
#[tauri::command]
pub fn open_notification_settings() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        Command::new("/usr/bin/open")
            .arg("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            .spawn()
            .map_err(|e| format!("无法打开系统通知设置：{e}"))?;
        Ok(())
    }
    #[cfg(target_os = "windows")]
    {
        Command::new("explorer.exe").arg("ms-settings:notifications").spawn()
            .map_err(|error| format!("无法打开系统通知设置：{error}"))?;
        Ok(())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    Err("请手动打开系统的通知设置".into())
}
fn dismiss_call_panel(id: &str) {
    #[cfg(target_os = "macos")]
    if let Ok(id) = std::ffi::CString::new(id) {
        unsafe {
            rs_call_panel_dismiss(id.as_ptr());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = id;
}
fn update_call_panel(call: Option<serde_json::Value>) {
    #[cfg(target_os = "macos")]
    let call = call.map(|mut value| {
        use base64::Engine;
        if value["avatarPng"].is_string() { return value; }
        let bytes: &[u8] = match value["peerAvatarId"].as_str().unwrap_or("cat") {
            "dog" => include_bytes!("../../ui/avatars/dog.png"),
            "fox" => include_bytes!("../../ui/avatars/fox.png"),
            "rabbit" => include_bytes!("../../ui/avatars/rabbit.png"),
            "bear" => include_bytes!("../../ui/avatars/bear.png"),
            "panda" => include_bytes!("../../ui/avatars/panda.png"),
            "penguin" => include_bytes!("../../ui/avatars/penguin.png"),
            "owl" => include_bytes!("../../ui/avatars/owl.png"),
            _ => include_bytes!("../../ui/avatars/cat.png"),
        };
        value["avatarPng"] = serde_json::Value::String(base64::engine::general_purpose::STANDARD.encode(bytes));
        value
    });
    #[cfg(target_os = "macos")]
    if let Ok(json) = std::ffi::CString::new(call.unwrap_or(serde_json::Value::Null).to_string()) {
        unsafe {
            rs_call_panel_update(json.as_ptr());
        }
    }
    #[cfg(not(target_os = "macos"))]
    let _ = call;
}
#[tauri::command]
pub fn set_call_notification_context(
    owned_call_id: Option<String>,
    dismissed_call_id: Option<String>,
    state: tauri::State<NotificationContext>,
) {
    // The webview reports ownership only after acceptance succeeds. Keep a
    // tombstone so an in-flight native ringing snapshot cannot reopen it.
    if let Some(id) = dismissed_call_id.or(owned_call_id) {
        let mut dismissed = state.dismissed_calls.lock().unwrap();
        dismissed.insert(id.clone());
        dismiss_call_panel(&id);
        state.stopped.lock().unwrap().insert(id.clone());
        let mut ring = state.ring.lock().unwrap();
        if ring.as_ref().is_some_and(|r| r.0 == id) {
            *ring = None;
        }
    }
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
fn sound(name: &str) -> Option<Child> {
    #[cfg(target_os = "macos")]
    {
    Command::new("/usr/bin/afplay")
        .arg(format!("/System/Library/Sounds/{name}.aiff"))
        .spawn()
        .ok()
    }
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        let _ = name;
        Command::new("powershell.exe")
            .args(["-NoProfile", "-NonInteractive", "-Command",
                "[System.Media.SoundPlayer]::new(($env:WINDIR + '\\Media\\Windows Ring01.wav')).PlaySync()"])
            .creation_flags(0x08000000) // CREATE_NO_WINDOW; incoming calls must not flash a console.
            .spawn().ok()
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    { let _ = name; None }
}
fn start_ringer(app: tauri::AppHandle) {
    std::thread::spawn(move || {
        let mut playing: Option<Child> = None;
        let mut active = String::new();
        let mut last = 0;
        loop {
            std::thread::sleep(Duration::from_millis(100));
            let ring = app
                .state::<NotificationContext>()
                .ring
                .lock()
                .unwrap()
                .clone();
            let wanted = ring
                .filter(|r| r.1 > now())
                .map(|r| r.0)
                .unwrap_or_default();
            if wanted != active {
                if let Some(mut child) = playing.take() {
                    let _ = child.kill();
                    let _ = child.wait();
                }
                active = wanted;
                last = 0;
            }
            if playing
                .as_mut()
                .is_some_and(|p| p.try_wait().ok().flatten().is_some())
            {
                playing = None;
            }
            if !active.is_empty() && playing.is_none() && now() - last >= 2500 {
                playing = sound("Purr");
                last = now();
            }
        }
    });
}
#[tauri::command]
pub fn set_notification_context(peer_id: Option<String>, state: tauri::State<NotificationContext>) {
    *state.peer.lock().unwrap() = peer_id;
}
pub fn start(app: tauri::AppHandle) {
    #[cfg(target_os = "macos")]
    {
        let _ = NATIVE_APP.set(app.clone());
        unsafe {
            rs_notifications_init(native_event);
        }
    }
    start_ringer(app.clone());
    let notification_app = app.clone();
    let _ = app.notification().on_action(move |action| {
        let Some(notification) = action.notification() else {
            return;
        };
        let payload = serde_json::json!({"action":action.action_id(),"extra":notification.extra()});
        if matches!(payload["action"].as_str(), Some("answer" | "reject")) {
            if let Some(id) = payload["extra"]["callId"].as_str() {
                let state = notification_app.state::<NotificationContext>();
                state.stopped.lock().unwrap().insert(id.to_owned());
                let mut ring = state.ring.lock().unwrap();
                if ring.as_ref().is_some_and(|r| r.0 == id) {
                    *ring = None;
                }
            }
        }
        if let Some(window) = notification_app.get_webview_window("main") {
            let _ = window.unminimize();
            let _ = window.show();
            let _ = window.set_focus();
        }
        let _ = notification_app.emit("messaging-action", payload);
    });
    let _ = app
        .notification()
        .register_action_types(vec![ActionType::builder("friend-call")
            .actions(vec![
                Action::builder("answer", "接听").build(),
                Action::builder("reject", "拒绝").build(),
            ])
            .build()]);
    std::thread::spawn(move || {
        let client = format!(
            "notify-desktop-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()
        );
        let cache = app
            .path()
            .app_data_dir()
            .ok()
            .map(|p| p.join("notification-seen.json"));
        let mut seen: HashMap<String, u64> = cache
            .as_ref()
            .and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let viewed_cache=cache.as_ref().map(|p|p.with_file_name("notification-viewed.json"));
        let mut viewed:HashMap<String,u64>=viewed_cache.as_ref().and_then(|p|std::fs::read(p).ok())
            .and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or_default();
        let mut delivered_messages=HashSet::<String>::new();
        let mut account = String::new();
        let mut avatar_cache: HashMap<String,String> = HashMap::new();
        let mut requests = HashSet::new();
        let mut ringing = HashSet::new();
        loop {
            std::thread::sleep(Duration::from_secs(4));
            let Some(token) = api::load_creds().account_token else {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.set_badge_count(None);
                }
                update_call_panel(None);
                app.state::<NotificationContext>()
                    .dismissed_calls
                    .lock()
                    .unwrap()
                    .clear();
                for key in seen.keys(){if let Some((_,peer))=key.split_once(':'){remove_message(&app,peer);}}
                delivered_messages.clear();
                account.clear();
                avatar_cache.clear();
                requests.clear();
                ringing.clear();
                *app.state::<NotificationContext>().ring.lock().unwrap() = None;
                continue;
            };
            let data = match api::social("state", &token, serde_json::json!({})) {
                Ok(data) => {
                    record(&app, "lastPoll", serde_json::json!(now()));
                    record(&app, "pollError", serde_json::json!(""));
                    data
                }
                Err(error) => {
                    record(&app, "pollError", serde_json::json!(error));
                    continue;
                }
            };
            if api::load_creds().account_token.as_deref() != Some(&token) {
                continue;
            }
            let user = data["me"]["id"].as_str().unwrap_or_default();
            if user != account {
                update_call_panel(None);
                app.state::<NotificationContext>()
                    .dismissed_calls
                    .lock()
                    .unwrap()
                    .clear();
                for key in seen.keys(){if let Some((previous,peer))=key.split_once(':'){if previous!=user{remove_message(&app,peer);}}}
                delivered_messages.clear();
                account = user.to_owned();
                requests.clear();
                ringing.clear();
                *app.state::<NotificationContext>().ring.lock().unwrap() = None;
                app.state::<NotificationContext>()
                    .stopped
                    .lock()
                    .unwrap()
                    .clear();
            }
            let settings = read_settings(&app, user);
            let focused = app
                .get_webview_window("main")
                .and_then(|w| w.is_focused().ok())
                .unwrap_or(false);
            let visible = if focused {
                app.state::<NotificationContext>()
                    .peer
                    .lock()
                    .unwrap()
                    .clone()
            } else {
                None
            };
            let mut unread = 0i64;
            let mut dirty = false;
            if let Some(friends) = data["friends"].as_array() {
                let eligible:HashSet<&str>=friends.iter().filter(|f|f["blocked"]!=true).filter_map(|f|f["id"].as_str()).collect();
                let removed:Vec<_>=delivered_messages.iter().filter(|p|!eligible.contains(p.as_str())).cloned().collect();
                for peer in removed{remove_message(&app,&peer);delivered_messages.remove(&peer);}
                for f in friends {
                    let peer = f["id"].as_str().unwrap_or_default();
                    let seq = if let Some(rows)=f["incomingMessages"].as_array() {
                        rows.last().and_then(|r|r["seq"].as_str()).and_then(|s|s.parse::<u64>().ok()).unwrap_or(0)
                    } else if f["lastIncomingKind"]!="call" && f["lastIncomingKind"]!="recalled" {
                        f["lastIncomingSeq"].as_str().and_then(|s|s.parse::<u64>().ok()).unwrap_or(0)
                    } else {0};
                    let count = if f["blocked"].as_bool().unwrap_or(false) {
                        0
                    } else {
                        f["unread"].as_i64().unwrap_or(0)
                    };
                    unread += count;
                    let key = format!("{user}:{peer}");
                    let floor=*viewed.entry(key.clone()).or_insert_with(|| {
                        dirty=true;f["notificationReadSeq"].as_str().and_then(|v|v.parse().ok()).unwrap_or(0)
                    });
                    if visible.as_deref()==Some(peer) || f["blocked"]==true || settings.muted_peers.contains(peer) {
                        remove_message(&app,peer);delivered_messages.remove(peer);
                        if floor<seq{viewed.insert(key.clone(),seq);dirty=true;}
                    }
                    if !f["blocked"].as_bool().unwrap_or(false)
                        && !settings.muted_peers.contains(peer)
                        && should_alert(
                            *seen.get(&key).unwrap_or(&0),
                            seq,
                            count,
                            visible.as_deref() == Some(peer),
                            seen.contains_key(&key),
                        )
                    {
                        let name = f["remark"]
                            .as_str()
                            .filter(|s| !s.is_empty())
                            .or(f["name"].as_str())
                            .unwrap_or("好友");
                        let fallback=serde_json::json!([{"seq":seq.to_string(),"text":f["lastIncomingText"].as_str().unwrap_or("新消息"),"createdAt":now()}]);
                        let previews=message_previews(f.get("incomingMessages").unwrap_or(&fallback),floor);
                        if !previews.is_empty() {
                            let preview=read_settings(&app,user).message_preview;
                            let body=if preview {previews.iter().map(|r|r.text.as_str()).collect::<Vec<_>>().join("\n")} else {format!("收到 {} 条新消息",previews.len())};
                            let title=if preview{name}else{"RemoteScreen"};
                            if focused {
                                let _=app.emit("messaging-notice",serde_json::json!({"accountId":user,"peerId":peer,"text":format!("{title}：{}",if preview {previews.last().unwrap().text.as_str()}else{"收到新消息"})}));
                            }
                            post(&app,title,&body,serde_json::json!({"accountId":user,"peerId":peer,"kind":"message"}),settings.message_sound);
                            delivered_messages.insert(peer.into());
                        }
                    }
                    if !seen.contains_key(&key) || seen.get(&key).is_some_and(|old|*old<seq) {
                        dirty = true;
                        seen.insert(key, seq);
                    }
                }
            }
            if let Some(incoming) = data["requests"].as_array() {
                unread += incoming.len() as i64;
                for request in incoming {
                    let key = format!("{}:{}", request["id"], request["createdAt"]);
                    if requests.insert(key) {
                        post(
                            &app,
                            "新的好友申请",
                            &format!(
                                "{} 希望添加你为好友",
                                request["name"].as_str().unwrap_or("好友")
                            ),
                            serde_json::json!({"accountId":user,"kind":"friends"}),
                            settings.message_sound,
                        );
                    }
                }
            }
            if let Ok(calls) =
                api::social("call-state", &token, serde_json::json!({"clientId":client}))
            {
                if api::load_creds().account_token.as_deref() != Some(&token) {
                    continue;
                }
                let mut active = HashSet::new();
                let mut audible = None;
                let mut panel = None;
                let state = app.state::<NotificationContext>();
                let dismissed = state.dismissed_calls.lock().unwrap().clone();
                if let Some(calls) = calls["calls"].as_array() {
                    for c in calls {
                        let id = c["id"].as_str().unwrap_or_default();
                        if show_call_panel(
                            c["status"].as_str().unwrap_or_default(),
                            c["role"] == "callee",
                            dismissed.contains(id),
                        ) {
                            panel = Some(serde_json::json!({
                                "id":id,"accountId":user,"peerId":c["peerId"],"peerName":c["peerName"],"peerAvatarId":c["peerAvatarId"],"peerAvatarRevision":c["peerAvatarRevision"],
                                "kind":c["kind"],"status":c["status"],"role":c["role"],"acceptedAt":c["acceptedAt"],
                                "expiresAt":c["createdAt"].as_u64().unwrap_or(0).saturating_add(45000)
                            }));
                            if c["peerAvatarId"] == "custom" {
                                let key=format!("{user}:{}:{}",c["peerId"],c["peerAvatarRevision"]);
                                if !avatar_cache.contains_key(&key) {
                                    if let Ok(image)=api::social("avatar-image", &token,serde_json::json!({"peerId":c["peerId"],"revision":c["peerAvatarRevision"]})) {
                                        if let Some(png)=image["image"].as_str().and_then(|s|s.strip_prefix("data:image/png;base64,")) {
                                            if png.len()<410000 {if avatar_cache.len()>64 {avatar_cache.clear();}avatar_cache.insert(key.clone(),png.to_owned());}
                                        }
                                    }
                                }
                                if let Some(png)=avatar_cache.get(&key) {panel.as_mut().unwrap()["avatarPng"]=serde_json::Value::String(png.clone());}
                            }
                        }
                        if c["role"] != "callee" || c["status"] != "ringing" {
                            continue;
                        }
                        let id = c["id"].as_str().unwrap_or_default();
                        active.insert(id.to_owned());
                        let muted = settings
                            .muted_peers
                            .contains(c["peerId"].as_str().unwrap_or_default());
                        let stopped = app
                            .state::<NotificationContext>()
                            .stopped
                            .lock()
                            .unwrap()
                            .contains(id);
                        let expiry = c["createdAt"]
                            .as_u64()
                            .or_else(|| c["createdAt"].as_str().and_then(|v| v.parse().ok()))
                            .unwrap_or(0)
                            .saturating_add(45000);
                        if can_ring(settings.call_sound, muted, stopped, expiry, now()) {
                            audible = Some((
                                id.to_owned(),
                                expiry,
                                c["peerId"].as_str().unwrap_or_default().to_owned(),
                            ));
                        }
                        #[cfg(not(target_os = "macos"))]
                        if !ringing.contains(id) {
                            post(
                                &app,
                                c["peerName"].as_str().unwrap_or("好友"),
                                if c["kind"] == "video" {
                                    "视频来电"
                                } else {
                                    "语音来电"
                                },
                                serde_json::json!({"accountId":user,"kind":"call","peerId":c["peerId"],"callId":id}),
                                false,
                            );
                        }
                    }
                }
                {
                    // Queue updates and dismissals under the same lock, including
                    // after a potentially slow avatar fetch.
                    let dismissed = state.dismissed_calls.lock().unwrap();
                    if panel.as_ref().is_some_and(|c| {
                        dismissed.contains(c["id"].as_str().unwrap_or_default())
                    }) {
                        panel = None;
                    }
                    if api::load_creds().account_token.as_deref() != Some(&token) { continue; }
                    update_call_panel(panel);
                }
                if let Some(calls) = calls["calls"].as_array() {
                    state.dismissed_calls.lock().unwrap().retain(|id| {
                        calls
                            .iter()
                            .any(|c| c["id"] == *id && c["status"] != "ended")
                    });
                }
                {
                    let state = app.state::<NotificationContext>();
                    let mut ring = state.ring.lock().unwrap();
                    if !ring
                        .as_ref()
                        .is_some_and(|r| r.0.starts_with("test-") && r.1 > now())
                    {
                        // The user may answer/hang up while this request is in flight.
                        *ring = audible.filter(|r| !state.stopped.lock().unwrap().contains(&r.0));
                    }
                }
                #[cfg(target_os = "macos")]
                for id in ringing.difference(&active) {
                    if let Ok(id) = std::ffi::CString::new(format!("call-{id}")) {
                        unsafe {
                            rs_notifications_remove(id.as_ptr());
                        }
                    }
                }
                app.state::<NotificationContext>()
                    .stopped
                    .lock()
                    .unwrap()
                    .retain(|id| active.contains(id));
                unread += active.len() as i64;
                ringing = active;
            }
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.set_badge_count(if unread > 0 { Some(unread) } else { None });
            }
            if dirty {
                if let Some(path)=&viewed_cache {
                    if let Some(parent)=path.parent(){let _=std::fs::create_dir_all(parent);}
                    if let Ok(bytes)=serde_json::to_vec(&viewed){let tmp=path.with_extension("tmp");if std::fs::write(&tmp,bytes).is_ok(){let _=std::fs::rename(tmp,path);}}
                }
                if let Some(path) = &cache {
                    if let Some(parent) = path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    if let Ok(bytes) = serde_json::to_vec(&seen) {
                        let temp = path.with_extension("tmp");
                        if std::fs::write(&temp, bytes).is_ok() {
                            let _ = std::fs::rename(temp, path);
                        }
                    }
                }
            }
        }
    });
}
