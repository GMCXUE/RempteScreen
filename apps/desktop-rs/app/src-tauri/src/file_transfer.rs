//! 文件传输：通过 LiveKit 可靠数据通道把观看端选择的文件发送到投送端。
//!
//! 协议：
//! - 控制消息（topic `rs-file-ctl`，JSON）：meta{id,name,size} / end{id} / cancel{id,reason}
//! - 数据块（topic `rs-file-bin`，二进制）：[u64 id LE][u32 seq LE][payload ≤12KiB]
//! - 接收方自动落盘到 ~/Downloads/RemoteScreen-Files/，进度经 Tauri `ft` 事件推给 UI。

use livekit::prelude::*;
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

pub const TOPIC_CTL: &str = "rs-file-ctl";
pub const TOPIC_BIN: &str = "rs-file-bin";
const CHUNK: usize = 12 * 1024;
const PROGRESS_EVERY: u64 = 256 * 1024;
const MAX_ACTIVE_RECEIVES: usize = 8;

#[derive(Serialize, Clone)]
pub struct FtProgress {
    pub direction: String,
    pub id: u64,
    pub name: String,
    pub received: u64,
    pub size: u64,
    pub done: bool,
    pub path: Option<String>,
    pub error: Option<String>,
}

struct RecvState {
    id: u64,
    name: String,
    size: u64,
    received: u64,
    next_seq: u32,
    file: std::fs::File,
    path: PathBuf,
    last_emit: u64,
    last_activity: std::time::Instant,
}

pub struct RecvMgr {
    /// 参与者身份也属于键的一部分，避免多个观看者同时发文件时 ID 冲突。
    files: HashMap<(String, u64), RecvState>,
    active_sends: HashMap<u64, String>,
    canceled_sends: HashMap<u64, String>,
    acknowledgments: HashMap<u64, HashSet<String>>,
    next_emit: AtomicU64,
}

impl RecvMgr {
    pub fn new() -> Self {
        Self {
            files: HashMap::new(),
            active_sends: HashMap::new(),
            canceled_sends: HashMap::new(),
            acknowledgments: HashMap::new(),
            next_emit: AtomicU64::new(0),
        }
    }

    pub fn list_progress(&self) -> Vec<FtProgress> {
        self.files
            .values()
            .map(|state| FtProgress {
                direction: "recv".into(),
                id: state.id,
                name: state.name.clone(),
                received: state.received,
                size: state.size,
                done: false,
                path: Some(state.path.display().to_string()),
                error: None,
            })
            .collect()
    }

    pub fn cancel_sends(&mut self) {
        for id in self.active_sends.keys() {
            self.canceled_sends.insert(*id, "已取消发送".into());
        }
    }

    fn start_send(&mut self, id: u64, destination: &str) {
        self.active_sends.insert(id, destination.to_string());
        self.acknowledgments.insert(id, HashSet::new());
        self.canceled_sends.remove(&id);
    }

    fn finish_send(&mut self, id: u64) {
        self.active_sends.remove(&id);
        self.acknowledgments.remove(&id);
        self.canceled_sends.remove(&id);
    }

    fn take_send_cancel(&mut self, id: u64) -> Option<String> {
        self.canceled_sends.remove(&id)
    }
}

impl Default for RecvMgr {
    fn default() -> Self {
        Self::new()
    }
}

fn save_dir() -> Result<PathBuf, String> {
    let mut dir = dirs::download_dir()
        .or_else(dirs::home_dir)
        .unwrap_or_else(|| PathBuf::from("."));
    dir.push("RemoteScreen-Files");
    std::fs::create_dir_all(&dir)
        .map_err(|error| format!("创建文件接收目录失败: {error}"))?;
    Ok(dir)
}

/// 同名文件不覆盖：追加 (1)、(2)…
fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let candidate = dir.join(name);
    if !candidate.exists() {
        return candidate;
    }
    let stem = Path::new(name)
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("file");
    let extension = Path::new(name)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| format!(".{value}"))
        .unwrap_or_default();
    for index in 1..1000u32 {
        let candidate = dir.join(format!("{stem} ({index}){extension}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem}-{}{extension}", std::process::id()))
}

fn finish_received_file(state: &mut RecvState) -> Result<(), String> {
    state.file.flush().and_then(|_| state.file.sync_all()).map_err(|e| e.to_string())?;
    let dir = state.path.parent().ok_or("接收目录无效")?;
    // A hard link makes the complete file visible atomically and never replaces an existing file.
    for _ in 0..1000 {
        let destination = unique_path(dir, &state.name);
        match std::fs::hard_link(&state.path, &destination) {
            Ok(()) => {
                let _ = std::fs::remove_file(&state.path);
                state.path = destination;
                return Ok(());
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.to_string()),
        }
    }
    Err("同名文件过多，请整理下载目录后重试".into())
}

pub fn expire_receives(mgr: &Mutex<RecvMgr>, app: Option<&tauri::AppHandle>) {
    let expired = {
        let mut manager = mgr.lock().unwrap();
        let keys: Vec<_> = manager.files.iter().filter(|(_, s)| s.last_activity.elapsed().as_secs() >= 60)
            .map(|(key, _)| key.clone()).collect();
        keys.into_iter().filter_map(|key| manager.files.remove(&key)).collect::<Vec<_>>()
    };
    for state in expired { receive_error(state, "接收超时，文件传输已中止".into(), app); }
}

fn emit(app: Option<&tauri::AppHandle>, progress: FtProgress) {
    if let Some(app) = app {
        use tauri::Emitter;
        let _ = app.emit("ft", &progress);
    }
}

fn log(message: &str) {
    crate::publisher::log_to_file(&format!("[文件传输] {message}"));
}

fn publish_control(
    local: &LocalParticipant,
    destination: &ParticipantIdentity,
    value: serde_json::Value,
) {
    let local = local.clone();
    let destination = destination.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = local
            .publish_data(DataPacket {
                payload: value.to_string().into_bytes(),
                topic: Some(TOPIC_CTL.to_string()),
                reliable: true,
                destination_identities: vec![destination],
            })
            .await
        {
            log(&format!("发送控制消息失败: {error}"));
        }
    });
}

fn send_cancel(
    local: &LocalParticipant,
    destination: &ParticipantIdentity,
    id: u64,
    reason: &str,
) {
    publish_control(
        local,
        destination,
        serde_json::json!({"t":"cancel","id":id,"reason":reason}),
    );
}

fn receive_error(state: RecvState, error: String, app: Option<&tauri::AppHandle>) {
    drop(state.file);
    let _ = std::fs::remove_file(&state.path);
    log(&format!("接收文件失败: {}: {error}", state.name));
    emit(
        app,
        FtProgress {
            direction: "recv".into(),
            id: state.id,
            name: state.name,
            received: state.received,
            size: state.size,
            done: true,
            path: None,
            error: Some(error),
        },
    );
}

/// 处理一条文件传输数据消息。返回 true 表示该消息属于文件传输协议。
pub fn handle_packet(
    local: &LocalParticipant,
    payload: &[u8],
    topic: Option<&str>,
    sender: Option<ParticipantIdentity>,
    mgr: &Mutex<RecvMgr>,
    app: Option<&tauri::AppHandle>,
) -> bool {
    let Some(topic) = topic else { return false };
    if topic != TOPIC_CTL && topic != TOPIC_BIN {
        return false;
    }
    let Some(sender) = sender else {
        log("忽略缺少发送方身份的文件消息");
        return true;
    };

    if topic == TOPIC_CTL {
        let Ok(text) = std::str::from_utf8(payload) else {
            return true;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
            return true;
        };
        let kind = value.get("t").and_then(|item| item.as_str()).unwrap_or("");
        let id = value.get("id").and_then(|item| item.as_u64()).unwrap_or(0);
        if id == 0 {
            return true;
        }
        let key = (sender.as_str().to_string(), id);

        match kind {
            "meta" => {
                let name = value
                    .get("name")
                    .and_then(|item| item.as_str())
                    .unwrap_or("file");
                let size = value.get("size").and_then(|item| item.as_u64()).unwrap_or(0);
                let safe_name = Path::new(name)
                    .file_name()
                    .and_then(|value| value.to_str())
                    .filter(|value| !value.is_empty())
                    .unwrap_or("file")
                    .to_string();

                {
                    let mut manager = mgr.lock().unwrap();
                    if manager.files.len() >= MAX_ACTIVE_RECEIVES
                        && !manager.files.contains_key(&key)
                    {
                        drop(manager);
                        send_cancel(local, &sender, id, "同时接收的文件过多");
                        return true;
                    }
                    if let Some(previous) = manager.files.remove(&key) {
                        drop(previous.file);
                        let _ = std::fs::remove_file(previous.path);
                    }
                }

                let path = match save_dir() {
                    Ok(dir) => unique_path(&dir, &format!(".incoming-{id}.partial")),
                    Err(error) => {
                        log(&error);
                        send_cancel(local, &sender, id, &error);
                        emit(
                            app,
                            FtProgress {
                                direction: "recv".into(),
                                id,
                                name: safe_name,
                                received: 0,
                                size,
                                done: true,
                                path: None,
                                error: Some(error),
                            },
                        );
                        return true;
                    }
                };

                match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                    Ok(file) => {
                        log(&format!(
                            "接收文件开始: {safe_name}（{size} 字节）→ {}",
                            path.display()
                        ));
                        mgr.lock().unwrap().files.insert(
                            key,
                            RecvState {
                                id,
                                name: safe_name.clone(),
                                size,
                                received: 0,
                                next_seq: 0,
                                file,
                                path,
                                last_emit: 0,
                                last_activity: std::time::Instant::now(),
                            },
                        );
                        publish_control(local, &sender, serde_json::json!({"t":"ready","id":id}));
                        emit(
                            app,
                            FtProgress {
                                direction: "recv".into(),
                                id,
                                name: safe_name,
                                received: 0,
                                size,
                                done: false,
                                path: None,
                                error: None,
                            },
                        );
                    }
                    Err(error) => {
                        let error = format!("创建接收文件失败: {error}");
                        log(&error);
                        send_cancel(local, &sender, id, &error);
                        emit(
                            app,
                            FtProgress {
                                direction: "recv".into(),
                                id,
                                name: safe_name,
                                received: 0,
                                size,
                                done: true,
                                path: None,
                                error: Some(error),
                            },
                        );
                    }
                }
            }
            "end" => {
                let state = mgr.lock().unwrap().files.remove(&key);
                if let Some(mut state) = state {
                    if state.received != state.size {
                        let error = format!(
                            "文件数据不完整：应收 {} 字节，实际收到 {} 字节",
                            state.size, state.received
                        );
                        send_cancel(local, &sender, id, &error);
                        receive_error(state, error, app);
                    } else if let Err(error) = finish_received_file(&mut state) {
                        let error = format!("写入文件失败: {error}");
                        send_cancel(local, &sender, id, &error);
                        receive_error(state, error, app);
                    } else {
                        publish_control(local, &sender, serde_json::json!({"t":"saved","id":id}));
                        log(&format!(
                            "接收文件完成: {}（{} 字节）→ {}",
                            state.name,
                            state.received,
                            state.path.display()
                        ));
                        emit(
                            app,
                            FtProgress {
                                direction: "recv".into(),
                                id,
                                name: state.name,
                                received: state.received,
                                size: state.size,
                                done: true,
                                path: Some(state.path.display().to_string()),
                                error: None,
                            },
                        );
                    }
                }
            }
            "ready" | "saved" => {
                let mut manager = mgr.lock().unwrap();
                if manager.active_sends.get(&id).map(String::as_str) == Some(sender.as_str()) {
                    manager.acknowledgments.entry(id).or_default().insert(kind.to_string());
                }
            }
            "cancel" => {
                let reason = value
                    .get("reason")
                    .and_then(|item| item.as_str())
                    .unwrap_or("对方取消了文件传输")
                    .to_string();
                let mut manager = mgr.lock().unwrap();
                if let Some(state) = manager.files.remove(&key) {
                    drop(manager);
                    receive_error(state, reason, app);
                } else if manager.active_sends.get(&id).map(String::as_str) == Some(sender.as_str()) {
                    manager.canceled_sends.insert(id, reason);
                }
            }
            _ => {}
        }
        return true;
    }

    if payload.len() < 12 {
        return true;
    }
    let id = u64::from_le_bytes(payload[0..8].try_into().unwrap());
    let sequence = u32::from_le_bytes(payload[8..12].try_into().unwrap());
    let key = (sender.as_str().to_string(), id);
    let data = &payload[12..];
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|time| time.as_millis() as u64)
        .unwrap_or(0);

    let mut manager = mgr.lock().unwrap();
    let next_emit = manager.next_emit.load(Ordering::Relaxed);
    let mut progress = None;
    let mut failure = None;
    if let Some(state) = manager.files.get_mut(&key) {
        state.last_activity = std::time::Instant::now();
        if sequence != state.next_seq {
            failure = Some(format!(
                "文件数据顺序错误：期望分块 {}，收到 {}",
                state.next_seq, sequence
            ));
        } else if state.received.saturating_add(data.len() as u64) > state.size {
            failure = Some("收到的文件数据超过声明大小".to_string());
        } else if let Err(error) = state.file.write_all(data) {
            failure = Some(format!("写入文件失败: {error}"));
        } else {
            state.next_seq = state.next_seq.wrapping_add(1);
            state.received += data.len() as u64;
            if state.received - state.last_emit >= PROGRESS_EVERY || now_ms >= next_emit {
                state.last_emit = state.received;
                progress = Some(FtProgress {
                    direction: "recv".into(),
                    id,
                    name: state.name.clone(),
                    received: state.received,
                    size: state.size,
                    done: false,
                    path: None,
                    error: None,
                });
            }
        }
    }

    if progress.is_some() {
        manager.next_emit.store(now_ms + 400, Ordering::Relaxed);
    }
    let failed_state = failure.as_ref().and_then(|_| manager.files.remove(&key));
    drop(manager);

    if let Some(error) = failure {
        send_cancel(local, &sender, id, &error);
        if let Some(state) = failed_state {
            receive_error(state, error, app);
        }
    } else if let Some(progress) = progress {
        emit(app, progress);
    }
    true
}

async fn publish_packet(
    local: &LocalParticipant,
    destination: &ParticipantIdentity,
    topic: &str,
    payload: Vec<u8>,
) -> Result<(), String> {
    tokio::time::timeout(std::time::Duration::from_secs(30), local
        .publish_data(DataPacket {
            payload,
            topic: Some(topic.to_string()),
            reliable: true,
            destination_identities: vec![destination.clone()],
        }))
        .await
        .map_err(|_| "发送文件数据超时".to_string())?
        .map_err(|error| format!("发送文件数据失败: {error}"))
}

async fn wait_for_ack(mgr: &Mutex<RecvMgr>, id: u64, kind: &str) -> Result<(), String> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    loop {
        {
            let mut manager = mgr.lock().unwrap();
            if let Some(reason) = manager.take_send_cancel(id) { return Err(reason); }
            if manager.acknowledgments.get(&id).is_some_and(|acks| acks.contains(kind)) {
                return Ok(());
            }
        }
        if std::time::Instant::now() >= deadline {
            return Err(if kind == "ready" {
                "对方未确认接收，请检查连接并确认双端已更新"
            } else {
                "未收到对方保存回执，请先检查对方下载目录再重试"
            }.into());
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

async fn send_file_inner(
    local: &LocalParticipant,
    destination: &ParticipantIdentity,
    path: &Path,
    id: u64,
    name: &str,
    size: u64,
    app: Option<&tauri::AppHandle>,
    mgr: &Mutex<RecvMgr>,
) -> Result<(), String> {
    publish_packet(
        local,
        destination,
        TOPIC_CTL,
        serde_json::json!({"t":"meta","id":id,"name":name,"size":size,"ack":1})
            .to_string()
            .into_bytes(),
    )
    .await?;

    emit(
        app,
        FtProgress {
            direction: "send".into(),
            id,
            name: name.to_string(),
            received: 0,
            size,
            done: false,
            path: None,
            error: None,
        },
    );

    wait_for_ack(mgr, id, "ready").await?;
    let mut file =
        std::fs::File::open(path).map_err(|error| format!("打开文件失败: {error}"))?;
    let mut buffer = vec![0u8; CHUNK];
    let mut sequence = 0u32;
    let mut sent = 0u64;
    let mut last_emit = 0u64;

    loop {
        if let Some(reason) = mgr.lock().unwrap().take_send_cancel(id) {
            return Err(reason);
        }
        let count = file
            .read(&mut buffer)
            .map_err(|error| format!("读取文件失败: {error}"))?;
        if count == 0 {
            break;
        }
        let mut packet = Vec::with_capacity(12 + count);
        packet.extend_from_slice(&id.to_le_bytes());
        packet.extend_from_slice(&sequence.to_le_bytes());
        packet.extend_from_slice(&buffer[..count]);
        publish_packet(local, destination, TOPIC_BIN, packet).await?;
        sequence = sequence
            .checked_add(1)
            .ok_or_else(|| "文件过大，分块编号已用尽".to_string())?;
        sent += count as u64;
        if sent - last_emit >= PROGRESS_EVERY {
            last_emit = sent;
            emit(
                app,
                FtProgress {
                    direction: "send".into(),
                    id,
                    name: name.to_string(),
                    received: sent,
                    size,
                    done: false,
                    path: None,
                    error: None,
                },
            );
        }
    }

    if let Some(reason) = mgr.lock().unwrap().take_send_cancel(id) {
        return Err(reason);
    }
    publish_packet(
        local,
        destination,
        TOPIC_CTL,
        serde_json::json!({"t":"end","id":id})
            .to_string()
            .into_bytes(),
    )
    .await?;

    wait_for_ack(mgr, id, "saved").await?;
    log(&format!("发送文件完成: {name}（{sent} 字节，{sequence} 块）"));
    emit(
        app,
        FtProgress {
            direction: "send".into(),
            id,
            name: name.to_string(),
            received: sent,
            size,
            done: true,
            path: None,
            error: None,
        },
    );
    Ok(())
}

/// 发送文件：meta → 数据块 → end。消息只定向发送给投送端，不广播给其他观看者。
pub async fn send_file(
    local: &LocalParticipant,
    destination: &ParticipantIdentity,
    path: PathBuf,
    app: Option<tauri::AppHandle>,
    mgr: Arc<Mutex<RecvMgr>>,
) -> Result<u64, String> {
    let id = new_file_id();
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .filter(|value| !value.is_empty())
        .unwrap_or("file")
        .to_string();
    let size = match std::fs::metadata(&path) {
        Ok(metadata) if metadata.is_file() => metadata.len(),
        Ok(_) => {
            let error = "只能发送普通文件".to_string();
            emit_send_error(app.as_ref(), id, name, 0, error.clone());
            return Err(error);
        }
        Err(error) => {
            let error = format!("读取文件信息失败: {error}");
            emit_send_error(app.as_ref(), id, name, 0, error.clone());
            return Err(error);
        }
    };

    mgr.lock().unwrap().start_send(id, destination.as_str());
    let result = send_file_inner(
        local,
        destination,
        &path,
        id,
        &name,
        size,
        app.as_ref(),
        &mgr,
    )
    .await;
    mgr.lock().unwrap().finish_send(id);

    match result {
        Ok(()) => Ok(size),
        Err(error) => {
            send_cancel(local, destination, id, &error);
            emit_send_error(app.as_ref(), id, name, size, error.clone());
            Err(error)
        }
    }
}

fn emit_send_error(
    app: Option<&tauri::AppHandle>,
    id: u64,
    name: String,
    size: u64,
    error: String,
) {
    log(&format!("发送文件失败: {name}: {error}"));
    emit(
        app,
        FtProgress {
            direction: "send".into(),
            id,
            name,
            received: 0,
            size,
            done: true,
            path: None,
            error: Some(error),
        },
    );
}

fn new_file_id() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(1);
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|time| time.as_millis() as u64)
        .unwrap_or(0);
    (stamp << 8) | (COUNTER.fetch_add(1, Ordering::Relaxed) & 0xFF)
}
