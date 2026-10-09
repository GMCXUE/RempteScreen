// 服务端 API 客户端与本地凭据持久化。
//
// 与 Flutter/桌面旧版调用同一套接口（server/README.md 的契约）：
// 账号登录 → 注册设备（带上次凭据，服务端认出同一台设备）→ 心跳保活。
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use serde_json::json;
use std::path::PathBuf;

pub const SERVER_URL: &str = "http://121.43.102.154";

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
    pub device_name: String,
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
    get_json_with_timeout(path, token, 15)
}

fn get_json_with_timeout(
    path: &str,
    token: &str,
    timeout_sec: u64,
) -> Result<serde_json::Value, String> {
    let mut request = ureq::get(&format!("{SERVER_URL}{path}"))
        .timeout(std::time::Duration::from_secs(timeout_sec));
    if !token.is_empty() {
        request = request.set("Authorization", &format!("Bearer {token}"));
    }
    let response = request.call().map_err(|error| format!("{error}"))?;
    let text = response.into_string().map_err(|error| error.to_string())?;
    serde_json::from_str(&text).map_err(|error| error.to_string())
}

fn patch_json(path: &str, token: &str, body: &serde_json::Value) -> Result<serde_json::Value, String> {
    let response = ureq::request("PATCH", &format!("{SERVER_URL}{path}"))
        .timeout(std::time::Duration::from_secs(15))
        .set("Authorization", &format!("Bearer {token}"))
        .set("Content-Type", "application/json")
        .send_string(&body.to_string())
        .map_err(|error| format!("{error}"))?;
    let text = response.into_string().map_err(|error| error.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if let Some(error) = parsed.get("error") {
        return Err(error["message"].as_str().unwrap_or("请求失败").to_string());
    }
    Ok(parsed)
}

/// PostgreSQL 的 BIGINT 经 node-postgres 返回的是字符串，这里两种形态都接受。
fn de_i64_from_any<'de, D>(deserializer: D) -> Result<i64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let value = serde_json::Value::deserialize(deserializer)?;
    Ok(match value {
        serde_json::Value::Number(number) => number.as_i64().unwrap_or(0),
        serde_json::Value::String(text) => text.parse().unwrap_or(0),
        _ => 0,
    })
}

/// 账号名下的一台设备。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DeviceInfo {
    #[serde(rename = "deviceId")]
    pub device_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub platform: String,
    #[serde(default)]
    pub online: bool,
    #[serde(rename = "lastSeenAt", default, deserialize_with = "de_i64_from_any")]
    pub last_seen_at: i64,
}

pub fn list_devices(token: &str) -> Result<Vec<DeviceInfo>, String> {
    let result = get_json("/v1/devices", token)?;
    Ok(serde_json::from_value(result["devices"].clone()).unwrap_or_default())
}

pub fn rename_device(token: &str, device_id: &str, name: &str) -> Result<(), String> {
    patch_json(
        &format!("/v1/devices/{device_id}"),
        token,
        &json!({ "name": name }),
    )
    .map(|_| ())
}

/// 账号侧解绑设备（设备离线/已卸载时也能清理）。
pub fn unbind_device(token: &str, device_id: &str) -> Result<(), String> {
    let url = format!("{SERVER_URL}/v1/devices/{device_id}");
    let response = ureq::delete(&url)
        .timeout(std::time::Duration::from_secs(15))
        .set("Authorization", &format!("Bearer {token}"))
        .call()
        .map_err(|error| format!("{error}"))?;
    let text = response.into_string().map_err(|error| error.to_string())?;
    let parsed: serde_json::Value = serde_json::from_str(&text).unwrap_or_default();
    if let Some(error) = parsed.get("error") {
        return Err(error["message"].as_str().unwrap_or("解绑失败").to_string());
    }
    Ok(())
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
        device_name: result["deviceName"]
            .as_str()
            .or_else(|| result["name"].as_str())
            .unwrap_or("RemoteScreen (Rust)")
            .to_string(),
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

/// 设置连接密码，旧密码立即失效。
///
/// `custom` 为 None 时由服务端随机生成（「刷新」）；给出时采用自定义密码，
/// 服务端会校验长度与字符（4–64 字符、不含空格）。
pub fn set_password(
    device_id: &str,
    session_token: &str,
    custom: Option<&str>,
) -> Result<String, String> {
    let body = match custom {
        Some(password) => json!({ "sessionToken": session_token, "password": password }),
        None => json!({ "sessionToken": session_token }),
    };
    let result = post(&format!("/v1/devices/{device_id}/password"), None, &body)?;
    Ok(result["password"].as_str().unwrap_or("").to_string())
}

/// 随机刷新连接密码（等价于 set_password(None)）。
pub fn refresh_password(device_id: &str, session_token: &str) -> Result<String, String> {
    set_password(device_id, session_token, None)
}

/// 设备侧的观看请求（服务端随心跳下发）。
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct IncomingRequest {
    #[serde(rename = "requestId")]
    pub request_id: String,
    #[serde(rename = "viewerName", default)]
    pub viewer_name: String,
    #[serde(rename = "expiresInSec", default)]
    pub expires_in_sec: u64,
}

/// 心跳：返回待用户处理的观看请求列表。
pub fn heartbeat(device_id: &str, session_token: &str) -> Result<Vec<IncomingRequest>, String> {
    let result = post(
        &format!("/v1/devices/{device_id}/heartbeat"),
        None,
        &json!({ "sessionToken": session_token }),
    )?;
    Ok(serde_json::from_value(result["pendingRequests"].clone()).unwrap_or_default())
}

/// 设备侧长轮询：把连接挂住等「新观看请求」。
///
/// 取代了原来每 15 秒一次的定时心跳 —— 长轮询期间服务端会持续刷新在线状态，
/// 一有请求立刻返回，延迟从「最坏 15 秒」降到百毫秒级。
/// 返回 None 表示等待超时（没有新请求）。
pub fn wait_notifications(
    device_id: &str,
    session_token: &str,
    wait_sec: u64,
    seen: &[String],
) -> Result<Vec<IncomingRequest>, String> {
    // seen：我们已经知道的请求 id。不带它的话服务端一见有请求就立刻返回，
    // 客户端拿到又马上再问 —— 会变成每秒好几次的空转。
    let result = post(
        &format!("/v1/devices/{device_id}/notifications"),
        None,
        &json!({ "sessionToken": session_token, "waitSec": wait_sec, "seen": seen }),
    )?;
    Ok(serde_json::from_value(result["pendingRequests"].clone()).unwrap_or_default())
}

/// 观看请求的长轮询：status 变化或超时才返回。
pub fn poll_connect_request_long(request_id: &str, wait_sec: u64) -> Result<PollOutcome, String> {
    poll_connect_request_inner(request_id, Some(wait_sec))
}

/// 取消自己发出的观看请求（对方那边会立刻不再显示这个请求）。
pub fn cancel_connect_request(request_id: &str) -> Result<(), String> {
    let url = format!("{SERVER_URL}/v1/connect-requests/{request_id}");
    let response = ureq::delete(&url)
        .timeout(std::time::Duration::from_secs(15))
        .call()
        .map_err(|error| format!("{error}"))?;
    let _ = response.into_string();
    Ok(())
}

/// SSE 流消费：订阅本机的「观看请求」通知流。
///
/// 服务端一有变化立刻推 `requests` 事件（实测 ~10ms）；每 15 秒有一个 keep-alive 注释行，
/// 因此读超时设 45 秒即可（不能设总超时，否则 10 分钟的长流会被掐断）。
/// 流正常结束（服务端 10 分钟上限）或断开时返回，由调用方决定重连。
pub fn stream_notifications(
    device_id: &str,
    session_token: &str,
    stop: &AtomicBool,
    mut on_event: impl FnMut(&str, serde_json::Value) + Send,
) -> Result<(), String> {
    use std::io::BufRead;

    let agent = ureq::AgentBuilder::new()
        .timeout_read(std::time::Duration::from_secs(45))
        .timeout_connect(std::time::Duration::from_secs(10))
        .build();
    let response = agent
        .get(&format!(
            "{SERVER_URL}/v1/devices/{device_id}/notifications/stream"
        ))
        .set("X-Device-Token", session_token)
        .set("Accept", "text/event-stream")
        .call()
        .map_err(|error| format!("建立通知流失败: {error}"))?;

    let reader = std::io::BufReader::new(response.into_reader());
    let mut event_name = String::new();
    let mut data_buffer = String::new();

    for line in reader.lines() {
        if stop.load(Ordering::Relaxed) {
            return Ok(()); // 调用方要求停止（退出登录/关窗）
        }
        let line = line.map_err(|error| format!("读取通知流失败: {error}"))?;

        if let Some(name) = line.strip_prefix("event:") {
            event_name = name.trim().to_string();
        } else if let Some(data) = line.strip_prefix("data:") {
            data_buffer = data.trim().to_string();
        } else if line.is_empty() && !data_buffer.is_empty() {
            // 空行 = 一条事件结束
            let parsed: serde_json::Value =
                serde_json::from_str(&data_buffer).unwrap_or_default();
            on_event(&event_name, parsed);
            event_name.clear();
            data_buffer.clear();
        }
    }
    Ok(())
}

/// 设备主人对观看请求做出决定（同意 / 拒绝）。
pub fn decide_connect_request(
    request_id: &str,
    session_token: &str,
    approve: bool,
) -> Result<(), String> {
    // 请求可能已被处理（观看方取消 / 过期 / 重复决策），服务端会回 409/404 ——
    // 把它的错误信息解析出来展示，而不是裸的 HTTP 状态码。
    let response = ureq::post(&format!(
        "{SERVER_URL}/v1/connect-requests/{request_id}/decision"
    ))
    .timeout(std::time::Duration::from_secs(15))
    .send_string(&json!({ "sessionToken": session_token, "approve": approve }).to_string());

    match response {
        Ok(_) => Ok(()),
        Err(ureq::Error::Status(code, resp)) => {
            let text = resp.into_string().unwrap_or_default();
            let message = serde_json::from_str::<serde_json::Value>(&text)
                .ok()
                .and_then(|parsed| parsed["error"]["message"].as_str().map(|m| m.to_string()))
                .unwrap_or_else(|| format!("请求已失效（HTTP {code}）"));
            Err(message)
        }
        Err(error) => Err(format!("{error}")),
    }
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


// MARK: - 连接请求（请求观看 → 设备主人同意）

/// 发起连接请求的结果。
pub struct RequestOutcome {
    /// 是否是自己名下的设备（免密码、无需请求）
    pub owned: bool,
    pub request_id: String,
    pub device_name: String,
    pub expires_in_sec: u64,
}

pub struct RequestGrant {
    pub livekit_url: String,
    pub token: String,
    pub room_name: String,
    pub device_name: String,
}

pub enum PollOutcome {
    Pending,
    Denied,
    Expired,
    Approved(RequestGrant),
}

/// 该设备是否属于我的账号（用自己的设备免密码，也不需要请求确认）。
pub fn device_is_mine(token: &str, device_id: &str) -> bool {
    list_devices(token)
        .map(|devices| devices.iter().any(|device| device.device_id == device_id))
        .unwrap_or(false)
}

pub fn create_connect_request(
    token: Option<&str>,
    device_id: &str,
    viewer_name: &str,
) -> Result<RequestOutcome, String> {
    let result = post(
        "/v1/connect-requests",
        token,
        &json!({ "deviceId": device_id, "viewerName": viewer_name }),
    )?;
    Ok(RequestOutcome {
        owned: result["owned"].as_bool().unwrap_or(false),
        request_id: result["requestId"].as_str().unwrap_or("").to_string(),
        device_name: result["deviceName"].as_str().unwrap_or("").to_string(),
        expires_in_sec: result["expiresInSec"].as_u64().unwrap_or(60),
    })
}

pub fn poll_connect_request(request_id: &str) -> Result<PollOutcome, String> {
    poll_connect_request_inner(request_id, None)
}

fn poll_connect_request_inner(request_id: &str, wait_sec: Option<u64>) -> Result<PollOutcome, String> {
    // 服务端等待期间会把连接挂住不返回，客户端因此不需要高频轮询
    let timeout = match wait_sec {
        Some(wait) => wait + 15,
        None => 15,
    };
    let result = get_json_with_timeout(
        &match wait_sec {
            Some(wait) => format!("/v1/connect-requests/{request_id}?wait={wait}"),
            None => format!("/v1/connect-requests/{request_id}"),
        },
        "",
        timeout,
    )?;
    Ok(match result["status"].as_str().unwrap_or("pending") {
        "approved" => PollOutcome::Approved(RequestGrant {
            livekit_url: result["livekitUrl"].as_str().unwrap_or("").to_string(),
            token: result["token"].as_str().unwrap_or("").to_string(),
            room_name: result["roomName"].as_str().unwrap_or("").to_string(),
            device_name: result["deviceName"].as_str().unwrap_or("").to_string(),
        }),
        "denied" => PollOutcome::Denied,
        "expired" => PollOutcome::Expired,
        _ => PollOutcome::Pending,
    })
}
