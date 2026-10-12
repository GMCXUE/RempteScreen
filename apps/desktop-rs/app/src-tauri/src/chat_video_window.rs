use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    io::{Read, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::Manager;
#[derive(Clone)]
struct Context {
    token: String,
    peer: String,
    message: String,
    cache: PathBuf,
    busy: Arc<AtomicBool>,
}
#[derive(Default)]
pub struct VideoWindowState(Mutex<Option<Context>>);
fn context(app: &tauri::AppHandle) -> Result<Context, String> {
    let c = app
        .state::<VideoWindowState>()
        .0
        .lock()
        .unwrap()
        .clone()
        .ok_or("视频窗口已关闭")?;
    if super::chat_media::token(app)? != c.token {
        return Err("账号已变化，请重新打开视频".into());
    }
    Ok(c)
}
pub fn close(app: &tauri::AppHandle) {
    if let Some(c) = app.state::<VideoWindowState>().0.lock().unwrap().take() {
        let _ = std::fs::remove_file(c.cache);
    }
    if let Some(w) = app.get_webview_window("chat-video") {
        let _ = w.destroy();
    }
}
#[tauri::command]
pub fn close_chat_video(app: tauri::AppHandle, message_id: String) {
    if app
        .state::<VideoWindowState>()
        .0
        .lock()
        .unwrap()
        .as_ref()
        .is_some_and(|c| c.message == message_id)
    {
        close(&app);
    }
}
#[tauri::command]
pub async fn open_chat_video(
    app: tauri::AppHandle,
    peer_id: String,
    message_id: String,
) -> Result<(), String> {
    let token = super::chat_media::token(&app)?;
    if peer_id.is_empty() || message_id.is_empty() {
        return Err("视频消息无效".into());
    }
    close(&app);
    let dir = app
        .path()
        .app_cache_dir()
        .map_err(|e| e.to_string())?
        .join("chat-videos");
    std::fs::create_dir_all(&dir).map_err(|_| "无法准备视频缓存")?;
    let cache = dir.join(format!(
        "{}.mp4",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    *app.state::<VideoWindowState>().0.lock().unwrap() = Some(Context {
        token,
        peer: peer_id,
        message: message_id,
        cache: cache.clone(),
        busy: Arc::new(AtomicBool::new(false)),
    });
    let saved = app.clone();
    let saved_cache = cache.clone();
    tauri::WebviewWindowBuilder::new(
        &app,
        "chat-video",
        tauri::WebviewUrl::App("chat-video.html".into()),
    )
    .title("视频 · RemoteScreen")
    .inner_size(960.0, 640.0)
    .min_inner_size(520.0, 380.0)
    .center()
    .build()
    .map_err(|e| e.to_string())?
    .on_window_event(move |event| {
        if matches!(event, tauri::WindowEvent::Destroyed) {
            let state = saved.state::<VideoWindowState>();
            let mut current = state.0.lock().unwrap();
            if current.as_ref().is_some_and(|c| c.cache == saved_cache) {
                current.take();
            }
            let _ = std::fs::remove_file(&saved_cache);
        }
    });
    Ok(())
}
#[tauri::command]
pub async fn get_chat_video(app: tauri::AppHandle) -> Result<Value, String> {
    let c = context(&app)?;
    if c.busy.swap(true, Ordering::AcqRel) {
        return Err("视频正在加载，请稍候".into());
    }
    let saved = c.clone();
    let result = tauri::async_runtime::spawn_blocking(move || -> Result<Value, String> {
        let reply = super::api::social(
            "message-video",
            &saved.token,
            json!({"peerId":saved.peer,"messageId":saved.message}),
        )?;
        let meta = reply["message"]["video"].clone();
        let size = meta["bytes"]
            .as_u64()
            .filter(|v| *v > 0 && *v <= 50 * 1024 * 1024)
            .ok_or("视频信息无效")?;
        let expected = meta["sha256"].as_str().ok_or("视频信息无效")?;
        let mut reader = match ureq::get(&format!(
            "{}/v1/social/videos/{}",
            super::api::SERVER_URL,
            saved.message
        ))
        .query("peerId", &saved.peer)
        .set("Authorization", &format!("Bearer {}", saved.token))
        .timeout(std::time::Duration::from_secs(90))
        .call()
        {
            Ok(r) => r.into_reader(),
            Err(ureq::Error::Status(_, r)) => {
                let v: Value = r.into_json().unwrap_or_default();
                return Err(v["error"]["message"]
                    .as_str()
                    .unwrap_or("视频下载失败，请重试")
                    .into());
            }
            Err(_) => return Err("视频下载失败，请重试".into()),
        };
        let part = saved.cache.with_extension("part");
        let mut output = std::fs::File::create(&part).map_err(|_| "无法保存视频缓存")?;
        let mut hash = Sha256::new();
        let mut total = 0u64;
        let mut buffer = [0u8; 64 * 1024];
        let download = (|| {
            loop {
                let n = reader
                    .read(&mut buffer)
                    .map_err(|_| "视频下载失败，请重试")?;
                if n == 0 {
                    break;
                }
                total += n as u64;
                if total > size {
                    return Err("视频下载校验失败，请重试");
                }
                hash.update(&buffer[..n]);
                output
                    .write_all(&buffer[..n])
                    .map_err(|_| "无法保存视频缓存")?;
            }
            if total != size || format!("{:x}", hash.finalize()) != expected {
                return Err("视频下载校验失败，请重试");
            }
            Ok(())
        })();
        drop(output);
        if let Err(e) = download {
            let _ = std::fs::remove_file(part);
            return Err(e.into());
        }
        std::fs::rename(part, &saved.cache).map_err(|_| "无法保存视频缓存")?;
        Ok(json!({"path":saved.cache.to_string_lossy(),"video":meta}))
    })
    .await
    .map_err(|e| e.to_string());
    c.busy.store(false, Ordering::Release);
    let result = result?;
    if context(&app).is_err() || context(&app)?.cache != c.cache {
        let _ = std::fs::remove_file(c.cache);
        return Err("视频窗口已关闭".into());
    }
    result
}
#[tauri::command]
pub async fn check_chat_video(app: tauri::AppHandle) -> Result<(), String> {
    let c = context(&app)?;
    let saved = c.clone();
    let result = tauri::async_runtime::spawn_blocking(move || {
        super::api::social(
            "message-video",
            &saved.token,
            json!({"peerId":saved.peer,"messageId":saved.message}),
        )
    })
    .await
    .map_err(|e| e.to_string())?;
    if let Err(error) = result {
        if ["已撤回", "消息不存在", "视频不存在", "请先登录", "好友关系"].iter().any(|value| error.contains(value)) {
            let _ = std::fs::remove_file(&c.cache);
        }
        return Err(error);
    }
    if context(&app)?.cache != c.cache {
        return Err("视频窗口已关闭".into());
    }
    Ok(())
}
