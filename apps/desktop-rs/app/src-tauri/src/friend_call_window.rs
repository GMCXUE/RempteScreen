//! The main webview owns signaling. This window only displays camera frames and
//! forwards controls, so opening/folding it cannot create a second call session.
use serde_json::Value;
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct CallWindowState(pub Mutex<Option<Value>>, Mutex<i8>);

#[tauri::command]
pub fn get_friend_call_window_state(state: tauri::State<CallWindowState>) -> Option<Value> {
    snapshot(&state)
}

fn snapshot(state: &CallWindowState) -> Option<Value> {
    let mut data = state.0.lock().unwrap().clone()?;
    let edge = *state.1.lock().unwrap();
    data["docked"] = (edge != 0).into();
    data["dockSide"] = edge.into();
    Some(data)
}

fn destroy_windows(app: &tauri::AppHandle) {
    for label in ["friend-call", "friend-call-mini"] {
        if let Some(window) = app.get_webview_window(label) {
            let _ = window.destroy();
        }
    }
}

fn create_mini(app: &tauri::AppHandle, voice: bool) -> Result<(), String> {
    let builder = tauri::WebviewWindowBuilder::new(
        app,
        "friend-call-mini",
        tauri::WebviewUrl::App("friend-call-mini.html".into()),
    )
    .title("通话 · RemoteScreen")
    .inner_size(180.0, if voice { 140.0 } else { 240.0 })
    .min_inner_size(28.0, 64.0)
    .decorations(false)
    .resizable(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .visible_on_all_workspaces(true)
    .visible(false);
    let builder = if let Some(monitor) = app.primary_monitor().ok().flatten() {
        let scale = monitor.scale_factor();
        builder.position(
            monitor.position().x as f64 / scale + monitor.size().width as f64 / scale - 196.0,
            monitor.position().y as f64 / scale + 96.0,
        )
    } else {
        builder
    };
    let window = builder
        .build()
        .map_err(|e| format!("打开通话悬浮窗失败：{e}"))?;
    let handle = app.clone();
    window.on_window_event(move |event| match event {
        tauri::WindowEvent::Moved(_) => {
            let _ = handle.emit_to("friend-call-mini", "friend-call-mini:moved", ());
        }
        tauri::WindowEvent::CloseRequested { api, .. } => {
            if handle
                .state::<CallWindowState>()
                .0
                .lock()
                .unwrap()
                .is_some()
            {
                api.prevent_close();
            }
        }
        _ => {}
    });
    Ok(())
}

#[tauri::command]
pub async fn set_friend_call_window_state(
    app: tauri::AppHandle,
    data: Option<Value>,
    visible: bool,
) -> Result<(), String> {
    let data = data.map(|mut call| {
        call["visible"] = visible.into();
        call
    });
    {
        let state = app.state::<CallWindowState>();
        let mut current = state.0.lock().unwrap();
        if current.as_ref().map(|v| &v["id"]) != data.as_ref().map(|v| &v["id"]) {
            *state.1.lock().unwrap() = 0;
        }
        *current = data.clone();
    }
    let task = tauri::async_runtime::spawn_blocking(move || {
        if data.is_none() {
            let ended = app.state::<CallWindowState>().0.lock().unwrap().is_none();
            if ended {
                destroy_windows(&app);
            }
            return Ok(());
        }
        let Some(current) = app.state::<CallWindowState>().0.lock().unwrap().clone() else {
            return Ok(());
        };
        let visible = current["visible"].as_bool().unwrap_or(false);
        if visible && app.get_webview_window("friend-call").is_none() {
            let (width, height) = app
                .primary_monitor()
                .ok()
                .flatten()
                .map(|monitor| {
                    let scale = monitor.scale_factor();
                    (
                        (monitor.size().width as f64 / scale - 64.0).clamp(520.0, 960.0),
                        (monitor.size().height as f64 / scale - 100.0).clamp(380.0, 720.0),
                    )
                })
                .unwrap_or((960.0, 720.0));
            let window = tauri::WebviewWindowBuilder::new(
                &app,
                "friend-call",
                tauri::WebviewUrl::App("friend-call.html".into()),
            )
            .title("视频通话 · RemoteScreen")
            .inner_size(width, height)
            .min_inner_size(520.0, 380.0)
            .center()
            .build()
            .map_err(|error| format!("打开通话窗口失败：{error}"))?;
            let handle = app.clone();
            window.on_window_event(move |event| {
                if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                    if handle
                        .state::<CallWindowState>()
                        .0
                        .lock()
                        .unwrap()
                        .is_some()
                    {
                        api.prevent_close();
                        if let Some(window) = handle.get_webview_window("friend-call") {
                            let _ = window.hide();
                        }
                        let _ = handle.emit_to(
                            "main",
                            "friend-call-window:action",
                            serde_json::json!({"action":"fold"}),
                        );
                    }
                }
            });
        }
        if !visible && app.get_webview_window("friend-call-mini").is_none() {
            create_mini(&app, current["kind"] == "voice")?;
        }
        // A slow platform window creation can outlive the call or a fold request.
        // Use the current snapshot before displaying it, never the old request.
        let latest = snapshot(&app.state::<CallWindowState>());
        let Some(latest) = latest else {
            destroy_windows(&app);
            return Ok(());
        };
        let visible = latest["visible"].as_bool().unwrap_or(false);
        if let Some(window) = app.get_webview_window("friend-call") {
            if visible && !window.is_visible().unwrap_or(false) {
                window
                    .show()
                    .map_err(|e| format!("显示通话窗口失败：{e}"))?;
                let _ = window.unminimize();
                let _ = window.set_focus();
            } else if !visible {
                let _ = window.hide();
            }
            let _ = window.emit("friend-call-window:state", latest.clone());
        }
        if let Some(window) = app.get_webview_window("friend-call-mini") {
            if visible {
                let _ = window.hide();
            } else {
                if !latest["docked"].as_bool().unwrap_or(false) {
                    let height = if latest["kind"] == "voice" { 140.0 } else { 240.0 };
                    let _ = window.set_size(tauri::LogicalSize::new(180.0, height));
                }
                window
                    .show()
                    .map_err(|e| format!("显示通话悬浮窗失败：{e}"))?;
            }
            let _ = window.emit("friend-call-window:state", latest);
        }
        Ok(())
    });
    tokio::time::timeout(std::time::Duration::from_secs(12), task)
        .await
        .map_err(|_| "打开通话窗口超时，请重试".to_string())?
        .map_err(|error| format!("更新通话窗口失败：{error}"))?
}

#[tauri::command]
pub fn close_friend_call_window(app: tauri::AppHandle, state: tauri::State<CallWindowState>) {
    *state.0.lock().unwrap() = None;
    *state.1.lock().unwrap() = 0;
    destroy_windows(&app);
}

#[tauri::command]
pub fn friend_call_window_action(
    app: tauri::AppHandle,
    call_id: String,
    action: String,
    state: tauri::State<CallWindowState>,
) -> Result<(), String> {
    if !matches!(
        action.as_str(),
        "microphone" | "camera" | "speaker" | "hangup" | "fold" | "restore"
    ) {
        return Err("不支持的通话操作".into());
    }
    if !state
        .0
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|call| call["id"] == call_id)
    {
        return Err("通话已结束".into());
    }
    if action == "restore" {
        if let Some(main) = app.get_webview_window("main") {
            let _ = main.show(); let _ = main.unminimize(); let _ = main.set_focus();
        }
    }
    app.emit_to(
        "main",
        "friend-call-window:action",
        serde_json::json!({"action":action,"callId":call_id}),
    )
    .map_err(|error| format!("通话操作失败：{error}"))
}

fn edge_for_position(x: i32, width: i32, monitor_x: i32, monitor_width: i32, threshold: i32) -> i8 {
    if x <= monitor_x + threshold {
        -1
    } else if x + width >= monitor_x + monitor_width - threshold {
        1
    } else {
        0
    }
}

#[tauri::command]
pub fn dock_friend_call_mini(
    app: tauri::AppHandle,
    call_id: String,
    restore: bool,
) -> Result<Value, String> {
    let state = app.state::<CallWindowState>();
    if !state
        .0
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|c| c["id"] == call_id && c["visible"] == false)
    {
        return Err("通话已结束或已返回通话".into());
    }
    let window = app
        .get_webview_window("friend-call-mini")
        .ok_or("通话悬浮窗已关闭")?;
    let monitor = window
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| app.primary_monitor().ok().flatten())
        .ok_or("无法获取屏幕位置")?;
    let scale = monitor.scale_factor();
    let position = window.outer_position().map_err(|e| e.to_string())?;
    let size = window.outer_size().map_err(|e| e.to_string())?;
    let old_edge = *state.1.lock().unwrap();
    let edge = if restore {
        old_edge
    } else {
        edge_for_position(
            position.x,
            size.width as i32,
            monitor.position().x,
            monitor.size().width as i32,
            (24.0 * scale) as i32,
        )
    };
    if edge != 0 {
        let (width, height) = if restore {
            let voice = state.0.lock().unwrap().as_ref().is_some_and(|c| c["kind"] == "voice");
            (180.0, if voice { 140.0 } else { 240.0 })
        } else {
            (28.0, 64.0)
        };
        let margin = if restore { (16.0 * scale) as i32 } else { 0 };
        let x = if edge < 0 {
            monitor.position().x + margin
        } else {
            monitor.position().x + monitor.size().width as i32 - (width * scale) as i32 - margin
        };
        let min_y = monitor.position().y + (32.0 * scale) as i32;
        let max_y = (monitor.position().y + monitor.size().height as i32
            - ((height + 16.0) * scale) as i32)
            .max(min_y);
        window
            .set_size(tauri::LogicalSize::new(width, height))
            .map_err(|e| e.to_string())?;
        window
            .set_position(tauri::PhysicalPosition::new(
                x,
                position.y.clamp(min_y, max_y),
            ))
            .map_err(|e| e.to_string())?;
        *state.1.lock().unwrap() = if restore { 0 } else { edge };
    }
    let current_edge = *state.1.lock().unwrap();
    let layout = serde_json::json!({"docked": current_edge != 0, "dockSide": current_edge});
    let _ = window.emit("friend-call-mini:layout", layout.clone());
    Ok(layout)
}

#[cfg(test)]
mod tests {
    use super::edge_for_position;
    #[test]
    fn dock_respects_both_edges_and_secondary_monitors() {
        assert_eq!(edge_for_position(0, 180, 0, 1440, 24), -1);
        assert_eq!(edge_for_position(1250, 180, 0, 1440, 24), 1);
        assert_eq!(edge_for_position(600, 180, 0, 1440, 24), 0);
        assert_eq!(edge_for_position(-1920, 180, -1920, 1920, 24), -1);
        assert_eq!(edge_for_position(-180, 180, -1920, 1920, 24), 1);
    }
}
