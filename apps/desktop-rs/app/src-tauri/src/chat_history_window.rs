use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct HistoryWindowState(Mutex<Option<(String, Value)>>);

fn context(app: &tauri::AppHandle) -> Result<(String, Value), String> {
    let data = app.state::<HistoryWindowState>().0.lock().unwrap().clone().ok_or("聊天记录窗口已关闭")?;
    if app.state::<super::AppState>().creds.lock().unwrap().account_token.as_deref() != Some(data.0.as_str()) {
        return Err("账号已变化，请重新打开聊天记录".into());
    }
    Ok(data)
}

pub fn close(app: &tauri::AppHandle) {
    app.state::<HistoryWindowState>().0.lock().unwrap().take();
    if let Some(window) = app.get_webview_window("chat-history") { let _ = window.destroy(); }
}

#[tauri::command]
pub fn close_chat_history(app: tauri::AppHandle) { close(&app); }

#[tauri::command]
pub async fn open_chat_history(app: tauri::AppHandle, peer_id: String) -> Result<(), String> {
    let token = app.state::<super::AppState>().creds.lock().unwrap().account_token.clone().ok_or("请先登录")?;
    let saved = token.clone();
    let social = tauri::async_runtime::spawn_blocking(move || super::api::social("state", &saved, json!({})))
        .await.map_err(|e| e.to_string())??;
    if app.state::<super::AppState>().creds.lock().unwrap().account_token.as_deref() != Some(token.as_str()) { return Err("账号已变化".into()); }
    let peer = social["friends"].as_array().and_then(|friends| friends.iter().find(|f| f["id"].as_str() == Some(&peer_id) && f["blocked"] != true)).ok_or("好友关系已变化")?.clone();
    let data = json!({"me":social["me"],"peer":peer});
    *app.state::<HistoryWindowState>().0.lock().unwrap() = Some((token, data.clone()));
    if let Some(window) = app.get_webview_window("chat-history") {
        let _ = window.emit("chat-history-context", &data);
        let _ = window.show(); let _ = window.set_focus(); return Ok(());
    }
    tauri::WebviewWindowBuilder::new(&app,"chat-history",tauri::WebviewUrl::App("chat-history.html".into()))
        .title("聊天记录 · RemoteScreen").inner_size(760.0,720.0).min_inner_size(560.0,420.0).center()
        .build().map_err(|e| format!("打开聊天记录失败：{e}"))?;
    Ok(())
}

#[tauri::command]
pub fn get_chat_history_context(app: tauri::AppHandle) -> Result<Value,String> { Ok(context(&app)?.1) }

#[tauri::command]
pub async fn chat_history_api(app: tauri::AppHandle, operation: String, mut body: Value) -> Result<Value,String> {
    if !["history","message-image","avatar-image"].contains(&operation.as_str()) { return Err("不支持的聊天记录操作".into()); }
    let (token,data) = context(&app)?;
    if !body.is_object() { return Err("请求格式不正确".into()); }
    if operation != "avatar-image" { body["peerId"] = data["peer"]["id"].clone(); }
    let saved = token.clone();
    let result = tauri::async_runtime::spawn_blocking(move || super::api::social(&operation,&saved,body)).await.map_err(|e|e.to_string())??;
    let latest = context(&app)?;
    if latest.0 != token || latest.1["peer"]["id"] != data["peer"]["id"] { return Err("会话已变化，请重新查找".into()); }
    Ok(result)
}

#[tauri::command]
pub fn locate_chat_message(app: tauri::AppHandle, message_id: String) -> Result<(),String> {
    let (_,data)=context(&app)?;
    app.emit_to("main","chat-history-locate",json!({"accountId":data["me"]["id"],"peerId":data["peer"]["id"],"messageId":message_id})).map_err(|e|e.to_string())?;
    if let Some(window)=app.get_webview_window("main") { let _=window.show();let _=window.set_focus(); }
    Ok(())
}
