use base64::Engine;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    io::Read,
    path::PathBuf,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use tauri::Manager;
const VIDEO_MAX: u64 = 50 * 1024 * 1024;
#[derive(Clone)]
struct Draft {
    token: String,
    path: PathBuf,
}
#[derive(Default)]
pub struct MediaDraftState(Mutex<HashMap<String, Draft>>);
pub(crate) fn token(app: &tauri::AppHandle) -> Result<String, String> {
    app.state::<super::AppState>()
        .creds
        .lock()
        .unwrap()
        .account_token
        .clone()
        .ok_or("请先登录".into())
}
pub fn clear(app: &tauri::AppHandle) {
    app.state::<MediaDraftState>().0.lock().unwrap().clear();
}
#[tauri::command]
pub fn release_chat_media(app: tauri::AppHandle, draft_id: String) {
    app.state::<MediaDraftState>()
        .0
        .lock()
        .unwrap()
        .remove(&draft_id);
}
#[tauri::command]
pub async fn pick_chat_media(app: tauri::AppHandle, limit: usize) -> Result<Vec<Value>, String> {
    if !(1..=9).contains(&limit) {
        return Err("最多添加 9 项图片或视频".into());
    }
    let owner = token(&app)?;
    let Some(files) = rfd::AsyncFileDialog::new()
        .add_filter(
            "图片与视频",
            &["png", "jpg", "jpeg", "webp", "mp4", "mov", "m4v"],
        )
        .pick_files()
        .await
    else {
        return Ok(vec![]);
    };
    if files.len() > limit {
        return Err("最多添加 9 项图片或视频".into());
    }
    let expected_owner = owner.clone();
    let prepared=tauri::async_runtime::spawn_blocking(move||->Result<Vec<(Value,Option<(String,Draft)>)>,String>{
  let mut values=Vec::new();
  for file in files{
   let path=file.path().to_path_buf();let size=std::fs::metadata(&path).map_err(|_|"无法读取图片或视频")?.len();
   let mut header=[0u8;16];let n=std::fs::File::open(&path).and_then(|mut f|f.read(&mut header)).map_err(|_|"无法读取图片或视频")?;
   if n>=8&&&header[4..8]==b"ftyp"{
    if size>VIDEO_MAX{return Err("视频过大，请选择 50 MB 以内的视频".into());}
    let id=format!("video_{}_{}",SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos(),values.len());
    values.push((json!({"kind":"video","video":{"draftId":id,"bytes":size,"name":path.file_name().unwrap_or_default().to_string_lossy()}}),Some((id,Draft{token:owner.clone(),path}))));
   }else{
    if size>8*1024*1024{return Err("图片过大，请选择 8 MB 以内的图片".into());}
    let bytes=std::fs::read(&path).map_err(|_|"无法读取图片")?;
    let mime=if bytes.starts_with(&[0xff,0xd8,0xff]){"jpeg"}else if bytes.starts_with(b"\x89PNG\r\n\x1a\n"){"png"}else if bytes.len()>=12&&&bytes[..4]==b"RIFF"&&&bytes[8..12]==b"WEBP"{"webp"}else{return Err("请选择 JPG、PNG、WebP 图片或 MP4、MOV 视频".into());};
    values.push((json!({"kind":"image","image":format!("data:image/{mime};base64,{}",base64::engine::general_purpose::STANDARD.encode(bytes))}),None));
   }
  }Ok(values)
 }).await.map_err(|e|e.to_string())??;
    let current = token(&app)?;
    if current != expected_owner {
        return Err("账号已变化，请重新选择图片或视频".into());
    }
    let state = app.state::<MediaDraftState>();
    let mut drafts = state.0.lock().unwrap();
    if drafts.len() + prepared.iter().filter(|(_, d)| d.is_some()).count() > 64 {
        return Err("发送队列较满，请等当前视频发送完成后再试".into());
    }
    let mut values = Vec::new();
    for (value, draft) in prepared {
        if let Some((id, d)) = draft {
            drafts.insert(id, d);
        }
        values.push(value);
    }
    Ok(values)
}
#[tauri::command]
pub async fn send_chat_video(
    app: tauri::AppHandle,
    draft_id: String,
    peer_id: String,
    client_id: String,
    send_session: String,
) -> Result<Value, String> {
    use sha2::Digest;
    let owner = token(&app)?;
    if format!("{:x}", sha2::Sha256::digest(owner.as_bytes())) != send_session {
        return Err("账号已变化，请重新发送".into());
    }
    let draft = app
        .state::<MediaDraftState>()
        .0
        .lock()
        .unwrap()
        .get(&draft_id)
        .cloned()
        .ok_or("视频文件已失效，请重新选择")?;
    if draft.token != owner {
        return Err("账号已变化，请重新发送".into());
    }
    if !(8..=80).contains(&client_id.len())
        || !client_id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    {
        return Err("消息标识不正确".into());
    }
    tauri::async_runtime::spawn_blocking(move || {
        let file = std::fs::File::open(draft.path).map_err(|_| "视频文件已失效，请重新选择")?;
        let size = file.metadata().map_err(|_| "无法读取视频")?.len();
        if size > VIDEO_MAX {
            return Err("视频过大，请选择 50 MB 以内的视频".to_owned());
        }
        let result = ureq::put(&format!(
            "{}/v1/social/videos/{}",
            super::api::SERVER_URL,
            client_id
        ))
        .query("peerId", &peer_id)
        .timeout(std::time::Duration::from_secs(240))
        .set("Authorization", &format!("Bearer {owner}"))
        .set("Content-Type", "application/octet-stream")
        .set("Content-Length", &size.to_string())
        .send(file);
        match result {
            Ok(r) => {let value:Value=r.into_json().map_err(|_| "视频发送响应格式不正确".to_owned())?;
                super::chat_store::record(&owner,&peer_id,&value["message"])?;Ok(value)},
            Err(ureq::Error::Status(_, r)) => {
                let data: Value = r.into_json().unwrap_or_default();
                Err(data["error"]["message"]
                    .as_str()
                    .unwrap_or("视频发送失败，请重试")
                    .into())
            }
            Err(_) => Err("连不上服务器，请检查网络或服务器地址".into()),
        }
    })
    .await
    .map_err(|e| e.to_string())?
}
