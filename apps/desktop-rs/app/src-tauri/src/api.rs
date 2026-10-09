// 服务端 API 客户端与本地凭据持久化。
//
// 与 Flutter/桌面旧版调用同一套接口（server/README.md 的契约）：
// 账号登录 → 注册设备（带上次凭据，服务端认出同一台设备）→ 心跳保活。
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::path::PathBuf;

pub const SERVER_URL: &str = "http://91.208.104.182";

/// 本地持久化的凭据（账号令牌 + 设备凭据）。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Credentials {
    #[serde(default)]
    pub account_token: Option<String>,
    /// 登录账号的展示信息（登出时清空）
    #[serde(default)]
    pub account_name: Option<String>,
    #[serde(default)]
    pub account_email: Option<String>,
    #[serde(default)]
    pub device_id: Option<String>,
    #[serde(default)]
    pub device_session_token: Option<String>,
    /// 投屏画质：长边上限（720 / 1080 / 0=原始分辨率）
    #[serde(default = "default_share_height")]
    pub share_height: u32,
    /// 投屏帧率（15 / 30 / 60）
    #[serde(default = "default_share_fps")]
    pub share_fps: u32,
}

fn default_share_height() -> u32 { 1080 }
fn default_share_fps() -> u32 { 30 }

impl Default for Credentials {
    fn default() -> Self {
        Self {
            account_token: None,
            account_name: None,
            account_email: None,
            device_id: None,
            device_session_token: None,
            share_height: 1080,
            share_fps: 30,
        }
    }
}

fn creds_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".remotescreen-rs.json")
}

pub fn load_creds() -> Credentials {
    std::fs::read_to_string(creds_path())
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn save_creds(creds: &Credentials) {
    let _ = std::fs::write(creds_path(), serde_json::to_string_pretty(creds).unwrap());
}

/// 注册设备后由服务端下发的连接要素。
#[derive(Clone, Debug)]
pub struct Registration {
    pub device_id: String,
    pub password: String,
    pub session_token: String,
    pub livekit_url: String,
    pub publish_token: String,
}

fn post(path: &str, token: Option<&str>, body: &serde_json::Value) -> Result<serde_json::Value, String> {
    let mut request = ureq::post(&format!("{SERVER_URL}{path}"))
        .timeout(std::time::Duration::from_secs(15))
        .set("Content-Type", "application/json");
    if let Some(token) = token {
        request = request.set("Authorization", &format!("Bearer {token}"));
    }
    let response = request
        .send_string(&body.to_string())
        .map_err(|error| format!("{error}"))?;

    let text = response.into_string().map_err(|error| error.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if parsed.get("error").is_some() {
        let error = &parsed["error"];
        return Err(error["message"]
            .as_str()
            .unwrap_or("请求失败")
            .to_string());
    }
    Ok(parsed)
}

/// 带账号令牌的 GET 请求（目前只用于 /v1/me）。
fn get_json(path: &str, token: &str) -> Result<serde_json::Value, String> {
    let response = ureq::get(&format!("{SERVER_URL}{path}"))
        .timeout(std::time::Duration::from_secs(15))
        .set("Authorization", &format!("Bearer {token}"))
        .call()
        .map_err(|error| format!("{error}"))?;
    let text = response.into_string().map_err(|error| error.to_string())?;
    serde_json::from_str(&text).map_err(|error| error.to_string())
}

/// 补齐账号展示信息（本地凭据里缺失时用，同时验证令牌是否仍然有效）。
pub fn fetch_me(token: &str) -> Result<(String, String), String> {
    let result = get_json("/v1/me", token)?;
    let name = result["user"]["name"].as_str().unwrap_or("").to_string();
    let email = result["user"]["email"].as_str().unwrap_or("").to_string();
    Ok((name, email))
}

pub fn login(email: &str, password: &str) -> Result<(String, String), String> {
    let result = post(
        "/v1/auth/login",
        None,
        &json!({ "email": email, "password": password }),
    )?;
    let name = result["user"]["name"].as_str().unwrap_or("用户").to_string();
    let token = result["token"].as_str().unwrap_or("").to_string();
    Ok((name, token))
}

/// 注册设备：带持久化的设备凭据，服务端认出同一台设备就沿用原 ID。
pub fn register_device(creds: &Credentials) -> Result<Registration, String> {
    let token = creds
        .account_token
        .as_deref()
        .ok_or("尚未登录")?;
    let body = json!({
        "platform": "macos-rs",
        "deviceName": "RemoteScreen (Rust)",
        "deviceId": creds.device_id,
        "sessionToken": creds.device_session_token,
    });
    let result = post("/v1/devices/register", Some(token), &body)?;
    Ok(Registration {
        device_id: result["deviceId"].as_str().unwrap_or("").to_string(),
        password: result["password"].as_str().unwrap_or("").to_string(),
        session_token: result["sessionToken"].as_str().unwrap_or("").to_string(),
        livekit_url: result["livekitUrl"].as_str().unwrap_or("").to_string(),
        publish_token: result["token"].as_str().unwrap_or("").to_string(),
    })
}

/// 观看端连接票据（由服务端签发，权限为只能订阅）。
#[derive(Clone, Debug)]
pub struct ViewerTicket {
    pub livekit_url: String,
    pub token: String,
    pub device_name: String,
    pub device_id: String,
}

/// 连接他人设备：设备 ID + 密码（自己的设备带账号令牌可免密码）。
pub fn connect(
    device_id: &str,
    password: &str,
    account_token: Option<&str>,
    viewer_name: &str,
) -> Result<ViewerTicket, String> {
    let mut body = json!({ "deviceId": device_id, "viewerName": viewer_name });
    if !password.is_empty() {
        body["password"] = json!(password);
    }
    let result = post("/v1/connect", account_token, &body)?;
    Ok(ViewerTicket {
        livekit_url: result["livekitUrl"].as_str().unwrap_or("").to_string(),
        token: result["token"].as_str().unwrap_or("").to_string(),
        device_name: result["deviceName"].as_str().unwrap_or("设备").to_string(),
        device_id: result["deviceId"].as_str().unwrap_or("").to_string(),
    })
}

/// 刷新连接密码，旧密码立即失效。
pub fn refresh_password(device_id: &str, session_token: &str) -> Result<String, String> {
    let result = post(
        &format!("/v1/devices/{device_id}/password"),
        None,
        &json!({ "sessionToken": session_token }),
    )?;
    Ok(result["password"].as_str().unwrap_or("").to_string())
}

pub fn heartbeat(device_id: &str, session_token: &str) -> Result<(), String> {
    post(
        &format!("/v1/devices/{device_id}/heartbeat"),
        None,
        &json!({ "sessionToken": session_token }),
    )
    .map(|_| ())
}


// MARK: - 观看历史

/// 一条「看过某台设备」的记录。刻意不保存连接密码：自己的设备免密码，
/// 别人的设备下次仍需输入密码，避免明文口令落盘。
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct WatchHistoryEntry {
    pub device_id: String,
    pub device_name: String,
    /// 最近连接时间（Unix 秒）
    pub last_at: i64,
    /// 累计连接次数
    pub times: u32,
    /// 是否是自己名下的设备（免密码）
    pub own: bool,
}

fn history_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".remotescreen-rs.history.json")
}

pub fn load_history() -> Vec<WatchHistoryEntry> {
    std::fs::read_to_string(history_path())
        .ok()
        .and_then(|text| serde_json::from_str::<Vec<WatchHistoryEntry>>(&text).ok())
        .unwrap_or_default()
}

fn save_history(entries: &[WatchHistoryEntry]) {
    let _ = std::fs::write(history_path(), serde_json::to_string_pretty(entries).unwrap());
}

/// 记录一次观看：同一设备只保留一条，更新时间与次数后置顶。
pub fn record_watch(device_id: &str, device_name: &str, own: bool) {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|t| t.as_secs() as i64)
        .unwrap_or(0);

    let mut entries = load_history();
    let previous_times = entries
        .iter()
        .find(|entry| entry.device_id == device_id)
        .map(|entry| entry.times)
        .unwrap_or(0);
    entries.retain(|entry| entry.device_id != device_id);
    entries.insert(
        0,
        WatchHistoryEntry {
            device_id: device_id.to_string(),
            device_name: device_name.to_string(),
            last_at: now,
            times: previous_times + 1,
            own,
        },
    );
    entries.truncate(20);
    save_history(&entries);
}

pub fn clear_history() {
    save_history(&[]);
}

pub fn forget_device(device_id: &str) {
    let mut entries = load_history();
    entries.retain(|entry| entry.device_id != device_id);
    save_history(&entries);
}
