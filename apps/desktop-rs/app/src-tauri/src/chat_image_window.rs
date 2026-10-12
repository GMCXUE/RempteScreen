use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Clone, PartialEq)]
struct Context {
    token: String,
    peer: String,
    message: String,
}
#[derive(Default)]
pub struct ImageWindowState(Mutex<Option<Context>>);

fn context(app: &tauri::AppHandle) -> Result<Context, String> {
    let data = app
        .state::<ImageWindowState>()
        .0
        .lock()
        .unwrap()
        .clone()
        .ok_or("图片窗口已关闭")?;
    if app
        .state::<super::AppState>()
        .creds
        .lock()
        .unwrap()
        .account_token
        .as_deref()
        != Some(data.token.as_str())
    {
        return Err("账号已变化，请重新打开图片".into());
    }
    Ok(data)
}
pub fn close(app: &tauri::AppHandle) {
    app.state::<ImageWindowState>().0.lock().unwrap().take();
    if let Some(window) = app.get_webview_window("chat-image") {
        let _ = window.destroy();
    }
}
#[tauri::command]
pub fn close_chat_image(app: tauri::AppHandle, message_id: String) {
    let matches = app
        .state::<ImageWindowState>()
        .0
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|c| c.message == message_id);
    if matches {
        close(&app);
    }
}
#[tauri::command]
pub async fn open_chat_image(
    app: tauri::AppHandle,
    peer_id: String,
    message_id: String,
) -> Result<(), String> {
    let token = app
        .state::<super::AppState>()
        .creds
        .lock()
        .unwrap()
        .account_token
        .clone()
        .ok_or("请先登录")?;
    if peer_id.is_empty() || message_id.is_empty() {
        return Err("图片消息无效".into());
    }
    let data = Context {
        token,
        peer: peer_id,
        message: message_id,
    };
    *app.state::<ImageWindowState>().0.lock().unwrap() = Some(data);
    if let Some(window) = app.get_webview_window("chat-image") {
        window
            .emit("chat-image-context", json!({}))
            .map_err(|e| e.to_string())?;
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }
    tauri::WebviewWindowBuilder::new(
        &app,
        "chat-image",
        tauri::WebviewUrl::App("chat-image.html".into()),
    )
    .title("图片 · RemoteScreen")
    .theme(Some(tauri::Theme::Light))
    .inner_size(980.0, 760.0)
    .min_inner_size(520.0, 380.0)
    .center()
    .build()
    .map_err(|e| format!("打开图片失败：{e}"))?;
    Ok(())
}
async fn image(app: &tauri::AppHandle) -> Result<Value, String> {
    let data = context(app)?;
    let saved = data.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        super::api::social(
            "message-image",
            &saved.token,
            json!({"peerId":saved.peer,"messageId":saved.message}),
        )
    })
    .await
    .map_err(|e| e.to_string())??;
    if context(app)? != data {
        return Err("图片已切换，请重新查看".into());
    }
    Ok(result)
}
#[tauri::command]
pub async fn get_chat_image(app: tauri::AppHandle) -> Result<Value, String> {
    image(&app).await
}
#[tauri::command]
pub async fn copy_viewed_chat_image(app: tauri::AppHandle) -> Result<(), String> {
    let result = image(&app).await?;
    let source = result["image"]
        .as_str()
        .ok_or("无法复制图片，请重试")?
        .to_owned();
    super::copy_chat_image(app, source).await
}
