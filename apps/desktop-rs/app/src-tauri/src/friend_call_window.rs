//! The main webview owns signaling. This window only displays camera frames and
//! forwards controls, so opening/folding it cannot create a second call session.
use serde_json::Value;
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct CallWindowState(pub Mutex<Option<Value>>);

#[tauri::command]
pub fn get_friend_call_window_state(state: tauri::State<CallWindowState>) -> Option<Value> {
    state.0.lock().unwrap().clone()
}

#[tauri::command]
pub async fn set_friend_call_window_state(app: tauri::AppHandle, data: Option<Value>, visible: bool) -> Result<(), String> {
    let data=data.map(|mut call|{call["visible"]=visible.into();call});
    *app.state::<CallWindowState>().0.lock().unwrap()=data.clone();
    let task=tauri::async_runtime::spawn_blocking(move || {
        if data.is_none() {
            if let Some(window)=app.get_webview_window("friend-call") { let _=window.destroy(); }
            return Ok(());
        }
        let Some(current)=app.state::<CallWindowState>().0.lock().unwrap().clone() else { return Ok(()); };
        let visible=current["visible"].as_bool().unwrap_or(false);
        if visible && app.get_webview_window("friend-call").is_none() {
            let (width,height)=app.primary_monitor().ok().flatten().map(|monitor| {
                let scale=monitor.scale_factor();
                ((monitor.size().width as f64/scale-64.0).clamp(520.0,960.0),
                 (monitor.size().height as f64/scale-100.0).clamp(380.0,720.0))
            }).unwrap_or((960.0,720.0));
            let window=tauri::WebviewWindowBuilder::new(&app,"friend-call",tauri::WebviewUrl::App("friend-call.html".into()))
                .title("视频通话 · RemoteScreen").inner_size(width,height)
                .min_inner_size(520.0,380.0).center().build()
                .map_err(|error|format!("打开通话窗口失败：{error}"))?;
            let handle=app.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested{api,..}=event {
                    if handle.state::<CallWindowState>().0.lock().unwrap().is_some() {
                        api.prevent_close();
                        if let Some(window)=handle.get_webview_window("friend-call") { let _=window.hide(); }
                        let _=handle.emit_to("main","friend-call-window:action",serde_json::json!({"action":"fold"}));
                    }
                }
            });
        }
        // A slow platform window creation can outlive the call or a fold request.
        // Use the current snapshot before displaying it, never the old request.
        let latest=app.state::<CallWindowState>().0.lock().unwrap().clone();
        let Some(latest)=latest else {
            if let Some(window)=app.get_webview_window("friend-call") { let _=window.destroy(); }
            return Ok(());
        };
        let visible=latest["visible"].as_bool().unwrap_or(false);
        if let Some(window)=app.get_webview_window("friend-call") {
            if visible && !window.is_visible().unwrap_or(false) {
                window.show().map_err(|e|format!("显示通话窗口失败：{e}"))?;
                let _=window.unminimize();let _=window.set_focus();
            } else if !visible { let _=window.hide(); }
            let _=window.emit("friend-call-window:state",latest);
        }
        Ok(())
    });
    tokio::time::timeout(std::time::Duration::from_secs(12),task).await
        .map_err(|_|"打开通话窗口超时，请重试".to_string())?
        .map_err(|error|format!("更新通话窗口失败：{error}"))?
}

#[tauri::command]
pub fn close_friend_call_window(app: tauri::AppHandle, state: tauri::State<CallWindowState>) {
    *state.0.lock().unwrap()=None;
    if let Some(window)=app.get_webview_window("friend-call") { let _=window.destroy(); }
}

#[tauri::command]
pub fn friend_call_window_action(app: tauri::AppHandle, call_id: String, action: String, state: tauri::State<CallWindowState>) -> Result<(), String> {
    if !matches!(action.as_str(),"microphone"|"camera"|"speaker"|"hangup"|"fold") { return Err("不支持的通话操作".into()); }
    if !state.0.lock().unwrap().as_ref().is_some_and(|call|call["id"]==call_id) { return Err("通话已结束".into()); }
    app.emit_to("main","friend-call-window:action",serde_json::json!({"action":action,"callId":call_id}))
        .map_err(|error|format!("通话操作失败：{error}"))
}
