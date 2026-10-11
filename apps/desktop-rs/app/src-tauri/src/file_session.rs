//! Data-only connections live independently of screen capture and viewing.
use livekit::prelude::*;
use livekit::{Room, RoomOptions};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, Default, Serialize)]
pub struct Status {
    pub watching: bool,
    pub device_name: String,
    pub error: String,
}
pub struct FileSession {
    stop: Arc<AtomicBool>,
    pub local: Arc<Mutex<Option<LocalParticipant>>>,
    pub remote: Arc<Mutex<Option<ParticipantIdentity>>>,
    pub status: Arc<Mutex<Status>>,
}
impl FileSession {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}
impl Drop for FileSession {
    fn drop(&mut self) {
        self.stop();
    }
}
pub fn start(
    url: String,
    token: String,
    device_name: String,
    destination: Option<String>,
    mgr: Arc<Mutex<crate::file_transfer::RecvMgr>>,
    app: tauri::AppHandle,
) -> FileSession {
    let stop = Arc::new(AtomicBool::new(false));
    let local = Arc::new(Mutex::new(None));
    let remote = Arc::new(Mutex::new(destination.map(ParticipantIdentity::from)));
    let status = Arc::new(Mutex::new(Status {
        device_name,
        ..Default::default()
    }));
    let result = FileSession {
        stop: stop.clone(),
        local: local.clone(),
        remote,
        status: status.clone(),
    };
    tauri::async_runtime::spawn(async move {
        while !stop.load(Ordering::Relaxed) {
            let mut options = RoomOptions::default();
            options.auto_subscribe = false;
            let connected = tokio::time::timeout(
                Duration::from_secs(30),
                Room::connect(&url, &token, options),
            )
            .await;
            match connected {
                Ok(Ok((room, mut events))) => {
                    if !stop.load(Ordering::Relaxed) {
                        *local.lock().unwrap() = Some(room.local_participant());
                        let mut current = status.lock().unwrap();
                        current.watching = true;
                        current.error.clear();
                    }
                    while !stop.load(Ordering::Relaxed) {
                        crate::file_transfer::expire_receives(&mgr, Some(&app));
                        match tokio::time::timeout(Duration::from_millis(200), events.recv()).await
                        {
                            Ok(Some(RoomEvent::DataReceived {
                                payload,
                                topic,
                                participant,
                                ..
                            })) => {
                                crate::file_transfer::handle_packet(
                                    &room.local_participant(),
                                    &payload,
                                    topic.as_deref(),
                                    participant.map(|p| p.identity()),
                                    &mgr,
                                    Some(&app),
                                );
                            }
                            Ok(Some(RoomEvent::Disconnected { .. })) | Ok(None) => break,
                            _ => {}
                        }
                    }
                    let _ = room.close().await;
                }
                Ok(Err(error)) => {
                    status.lock().unwrap().error = format!("文件连接失败，正在重连：{error}");
                }
                Err(_) => {
                    status.lock().unwrap().error = "文件连接超时，正在重连…".into();
                }
            }
            *local.lock().unwrap() = None;
            status.lock().unwrap().watching = false;
            if !stop.load(Ordering::Relaxed) {
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
        }
    });
    result
}
