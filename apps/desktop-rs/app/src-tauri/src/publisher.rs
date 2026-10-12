// 推流引擎：原生采集（ScreenCaptureKit）→ NV12→I420 → libwebrtc → LiveKit。
//
// 由尖刺 2 验证过的链路，包成可控启停的会话。
use livekit::options::{DegradationPreference, TrackPublishOptions, VideoCodec, VideoEncoding};
use livekit::prelude::*;
use livekit::webrtc::prelude::{
    I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation,
};
use livekit::webrtc::video_source::native::NativeVideoSource;
use livekit::Room;
use scap::capturer::Options;
#[cfg(not(target_os = "windows"))]
use scap::capturer::Capturer;
#[cfg(target_os = "windows")]
use crate::windows_screen::Capturer;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

static CALL_WINDOW_GENERATION: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// release 版没有控制台，错误同时落到文件便于排查
pub fn log_to_file(message: &str) {
    if let Some(home) = dirs::home_dir() {
        let path = home.join(".remotescreen-rs.log");
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|t| t.as_secs())
            .unwrap_or(0);
        // 追加而非覆盖：排障需要历史。超过 512KB 时截断一半，防止无限增长。
        use std::io::Write;
        let append = |message: &str| -> std::io::Result<()> {
            let mut file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
            file.write_all(format!("[{stamp}] {message}\n").as_bytes())
        };
        let size = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        if size > 512 * 1024 {
            let _ = std::fs::write(&path, ""); // 截断后重新追加
        }
        let _ = append(message);
    }
}

/// 一次投送会话：持有停止标志。
pub struct PublishSession {
    stop: Arc<AtomicBool>,
    pub local: Arc<Mutex<Option<LocalParticipant>>>,
    pub call: Arc<Mutex<crate::call::CallMedia>>,
}

impl PublishSession {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.call.lock().unwrap().close();
    }
}

/// 启动投送：连 LiveKit、采集本机屏幕、发布视频轨。
/// 全部在后台任务里跑；返回的句柄用于停止。
pub fn start_publish(
    livekit_url: &str,
    publish_token: &str,
    error_sink: Arc<Mutex<Option<String>>>,
    height_tier: u32,
    fps: u32,
    app: Option<tauri::AppHandle>,
    ft_recv: Arc<Mutex<crate::file_transfer::RecvMgr>>,
    camera_frames: crate::viewer::FrameStore,
    volume: crate::audio_playout::Volume,
) -> Result<PublishSession, String> {
    // 屏幕录制权限预检。注意：应用必须至少发起一次采集请求，
    // 系统才会把它加进「屏幕录制」列表 —— 所以这里主动触发授权流程，
    // 否则用户在系统设置里永远找不到本应用。
    #[cfg(target_os = "macos")]
    if !scap::has_permission() {
        // 触发系统授权登记，并直接打开「屏幕录制」设置页 ——
        // request_permission 只在系统首次询问时弹窗，之后必须手动去设置里开
        scap::request_permission();
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            .spawn();
        let message: String = "请在打开的「屏幕录制」设置页中勾选 RemoteScreen，然后重启应用".into();
        *error_sink.lock().unwrap() = Some(message.clone());
        return Err(message);
    }

    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = stop.clone();
    let url = livekit_url.to_string();
    let token = publish_token.to_string();
    let local = Arc::new(Mutex::new(None));
    let local_for_task = local.clone();
    let call = Arc::new(Mutex::new(crate::call::CallMedia::default()));

    let call_for_task = call.clone();
    let window_generation = CALL_WINDOW_GENERATION.fetch_add(1, Ordering::Relaxed) + 1;
    if let Some(handle) = app.clone() {
        let preview_frames = camera_frames.clone();
        let preview_stop = stop.clone();
        tauri::async_runtime::spawn(async move {
            let mut visible = false;
            while !preview_stop.load(Ordering::Relaxed)
                && CALL_WINDOW_GENERATION.load(Ordering::Relaxed) == window_generation {
                let has_frame = preview_frames.lock().unwrap().is_some();
                if has_frame != visible || !has_frame {
                    if has_frame {
                        if let Err(error) = crate::open_call_window(handle.clone()) {
                            log_to_file(&error);
                        }
                    } else {
                        crate::close_call_window(&handle);
                    }
                    visible = has_frame;
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
            if CALL_WINDOW_GENERATION.load(Ordering::Relaxed) == window_generation {
                crate::close_call_window(&handle);
            }
        });
    }
    let cleanup_frames = camera_frames.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = run_session(&url, &token, stop_clone.clone(), height_tier, fps, error_sink.clone(), app, ft_recv, camera_frames, volume, local_for_task).await {
            eprintln!("[publisher] 会话异常结束: {error}");
            log_to_file(&format!("会话异常结束: {error}"));
            if !stop_clone.load(Ordering::Relaxed) { *error_sink.lock().unwrap() = Some(error); }
        }
        call_for_task.lock().unwrap().close();
        if CALL_WINDOW_GENERATION.load(Ordering::Relaxed) == window_generation {
            *cleanup_frames.lock().unwrap() = None;
        }
        stop_clone.store(true, Ordering::Relaxed);
    });

    Ok(PublishSession { stop, local, call })
}

async fn run_session(
    url: &str,
    token: &str,
    stop: Arc<AtomicBool>,
    height_tier: u32,
    fps: u32,
    error_sink: Arc<Mutex<Option<String>>>,
    app: Option<tauri::AppHandle>,
    ft_recv: Arc<Mutex<crate::file_transfer::RecvMgr>>,
    camera_frames: crate::viewer::FrameStore,
    volume: crate::audio_playout::Volume,
    local_out: Arc<Mutex<Option<LocalParticipant>>>,
) -> Result<(), String> {
    let (room, mut events) = Room::connect(url, token, crate::call::call_room_options())
        .await
        .map_err(|error| format!("连接 LiveKit 失败: {error}"))?;

    let ft_local = room.local_participant();
    let _quality = crate::call_quality::start(&room, stop.clone(), None);
    *local_out.lock().unwrap() = Some(ft_local.clone());
    // 数据通道、远端麦克风与摄像头监听。
    let ft_recv = ft_recv.clone();
    let ft_app = app.clone();
    let call_stop = stop.clone();
    tokio::spawn(async move {
        let mut playouts = Vec::new();
        let mut camera_decoder: Option<(ParticipantIdentity, Arc<AtomicBool>)> = None;
        while let Some(event) = events.recv().await {
            match event {
                RoomEvent::DataReceived {
                    payload,
                    topic,
                    participant,
                    ..
                } => {
                    crate::file_transfer::handle_packet(
                        &ft_local,
                        &payload,
                        topic.as_deref(),
                        participant.map(|value| value.identity()),
                        &ft_recv,
                        ft_app.as_ref(),
                    );
                }
                RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Audio(track),
                    ..
                } => match crate::audio_playout::start(&track, volume.clone()) {
                    Ok(playout) => playouts.push(playout),
                    Err(error) => log_to_file(&format!("启动通话声音失败: {error}")),
                },
                RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Video(track),
                    publication,
                    participant,
                } if publication.source() == TrackSource::Camera => {
                    if let Some((_, cancel)) = camera_decoder.take() { cancel.store(true, Ordering::Relaxed); }
                    *camera_frames.lock().unwrap() = None;
                    let cancel = crate::viewer::spawn_camera_decoder(
                        track,
                        camera_frames.clone(),
                        call_stop.clone(),
                    );
                    camera_decoder = Some((participant.identity(), cancel));
                }
                RoomEvent::ParticipantDisconnected(participant) => {
                    if camera_decoder.as_ref().is_some_and(|(identity, _)| *identity == participant.identity()) {
                        if let Some((_, cancel)) = camera_decoder.take() { cancel.store(true, Ordering::Relaxed); }
                        *camera_frames.lock().unwrap() = None;
                    }
                }
                RoomEvent::TrackUnpublished { publication, participant }
                    if publication.source() == TrackSource::Camera => {
                    if camera_decoder.as_ref().is_some_and(|(identity, _)| *identity == participant.identity()) {
                        if let Some((_, cancel)) = camera_decoder.take() { cancel.store(true, Ordering::Relaxed); }
                        *camera_frames.lock().unwrap() = None;
                    }
                }
                RoomEvent::TrackMuted { publication, participant }
                    if publication.source() == TrackSource::Camera =>
                {
                    if camera_decoder.as_ref().is_some_and(|(identity, _)| *identity == participant.identity()) {
                        *camera_frames.lock().unwrap() = None;
                    }
                }
                RoomEvent::TrackUnsubscribed { publication, participant, .. }
                    if publication.source() == TrackSource::Camera =>
                {
                    if camera_decoder.as_ref().is_some_and(|(identity, _)| *identity == participant.identity()) {
                        if let Some((_, cancel)) = camera_decoder.take() { cancel.store(true, Ordering::Relaxed); }
                        *camera_frames.lock().unwrap() = None;
                    }
                }
                _ => {}
            }
        }
    });

    // 采集器创建 + 首帧（阻塞，放独立线程）
    struct FirstFrame {
        capturer: Capturer,
        width: u32,
        height: u32,
        buffer: I420Buffer,
    }
    let mut first = tokio::task::spawn_blocking(move || -> Result<FirstFrame, String> {
        let output_resolution = match height_tier {
            720 => scap::capturer::Resolution::_720p,
            1080 => scap::capturer::Resolution::_1080p,
            _ => scap::capturer::Resolution::Captured,
        };
        let mut capturer = Capturer::build(Options {
            fps,
            output_resolution,
            #[cfg(target_os = "windows")]
            output_type: scap::frame::FrameType::BGRAFrame,
            ..Default::default()
        })
        .map_err(|error| format!("创建采集器失败（检查屏幕录制权限）: {error}"))?;
        capturer.start_capture();
        #[cfg(not(target_os = "windows"))]
        let frame = capturer
            .get_next_frame()
            .map_err(|error| format!("首帧获取失败: {error}"))?;
        #[cfg(target_os = "windows")]
        let frame = capturer.next_frame(Duration::from_secs(15))?
            .ok_or("屏幕采集启动超时，请检查是否处于锁屏或远程桌面断开状态")?;
        let buffer = crate::screen_frame::scale_to_tier(crate::screen_frame::convert(&frame)?, height_tier);
        use livekit::webrtc::prelude::VideoBuffer;
        Ok(FirstFrame { capturer, width: buffer.width(), height: buffer.height(), buffer })
    })
    .await
    .map_err(|error| error.to_string())??;

    let width = first.width;
    let height = first.height;
    println!("[publisher] 采集分辨率 {width}×{height}");

    let source = NativeVideoSource::new(
        VideoResolution { width, height },
        true, // is_screencast：屏幕内容编码优化
    );
    let track = LocalVideoTrack::create_video_track("screen", RtcVideoSource::Native(source.clone()));
    let max_bitrate: u64 = if height_tier == 0 {
        match fps { 60 => 12_000_000, 30 => 8_000_000, _ => 5_000_000 }
    } else if height_tier <= 720 {
        match fps { 60 => 4_000_000, 30 => 2_500_000, _ => 1_500_000 }
    } else {
        match fps { 60 => 6_000_000, 30 => 3_800_000, _ => 2_500_000 }
    };
    room.local_participant()
        .publish_track(
            LocalTrack::Video(track),
            TrackPublishOptions {
                source: TrackSource::Screenshare,
                video_codec: VideoCodec::H264,
                simulcast: false,
                video_encoding: Some(VideoEncoding {
                    max_bitrate,
                    max_framerate: fps as f64,
                }),
                // 带宽吃紧时优先保帧率、降分辨率（投屏场景帧率更影响体验）
                degradation_preference: Some(DegradationPreference::MaintainFramerate),
                ..Default::default()
            },
        )
        .await
        .map_err(|error| format!("发布失败: {error}"))?;
    println!("[publisher] 视频轨已发布");
    source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, &first.buffer));

    // Manual PCM sources have their own SDK clock; never substitute microphone audio.
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    let _system_audio = match crate::system_audio::SystemAudio::start(&room, error_sink.clone()).await {
        Ok(audio) => audio,
        Err(error) => {
            first.capturer.stop_capture();
            let _ = room.close().await;
            return Err(error);
        }
    };

    // 采集循环（阻塞，独立线程），看到停止标志后退出
    let loop_stop = stop.clone();
    let capture_task = tokio::task::spawn_blocking(move || {
        let mut capturer = first.capturer;
        #[cfg(target_os = "windows")]
        let mut latest = first.buffer;
        while !loop_stop.load(Ordering::Relaxed) {
            #[cfg(not(target_os = "windows"))]
            let frame = capturer.get_next_frame().map(Some).map_err(|error| error.to_string());
            #[cfg(target_os = "windows")]
            let frame = capturer.next_frame(Duration::from_millis(300));
            if let Ok(Some(frame)) = frame {
                match crate::screen_frame::convert(&frame) {
                    Ok(buffer) => {
                        let buffer = crate::screen_frame::scale_to_tier(buffer, height_tier);
                        let video_frame = VideoFrame::new(VideoRotation::VideoRotation0, buffer);
                        let _ = source.capture_frame(&video_frame);
                        #[cfg(target_os = "windows")]
                        { latest = video_frame.buffer; }
                    }
                    Err(error) => { log_to_file(&error); *error_sink.lock().unwrap() = Some(error); break; }
                }
            } else if let Err(error) = frame {
                log_to_file(&error);
                *error_sink.lock().unwrap() = Some(format!("屏幕采集失败：{error}"));
                break;
            } else {
                #[cfg(target_os = "windows")]
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, &latest));
            }
        }
        capturer.stop_capture();
        loop_stop.store(true, Ordering::Relaxed);
    });

    // 等停止信号
    while !stop.load(Ordering::Relaxed) {
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let _ = capture_task.await;
    let _ = room.close().await;
    println!("[publisher] 会话已结束");
    Ok(())
}
