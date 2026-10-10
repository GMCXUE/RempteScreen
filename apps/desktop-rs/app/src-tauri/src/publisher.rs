// 推流引擎：原生采集（ScreenCaptureKit）→ NV12→I420 → libwebrtc → LiveKit。
//
// 由尖刺 2 验证过的链路，包成可控启停的会话。
use livekit::options::{DegradationPreference, TrackPublishOptions, VideoCodec, VideoEncoding};
use livekit::prelude::*;
use livekit::webrtc::prelude::{
    I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation,
};
use livekit::webrtc::video_source::native::NativeVideoSource;
use livekit::{Room, RoomOptions};
use scap::capturer::{Capturer, Options};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

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
}

impl PublishSession {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
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
) -> Result<PublishSession, String> {
    // 屏幕录制权限预检。注意：应用必须至少发起一次采集请求，
    // 系统才会把它加进「屏幕录制」列表 —— 所以这里主动触发授权流程，
    // 否则用户在系统设置里永远找不到本应用。
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

    tauri::async_runtime::spawn(async move {
        if let Err(error) = run_session(&url, &token, stop_clone, height_tier, fps, error_sink.clone()).await {
            eprintln!("[publisher] 会话异常结束: {error}");
            log_to_file(&format!("会话异常结束: {error}"));
            *error_sink.lock().unwrap() = Some(error);
        }
    });

    Ok(PublishSession { stop })
}

/// NV12（Y 平面 + UV 交错平面）→ I420 三平面。
fn fill_i420(buffer: &mut I420Buffer, yuv: &scap::frame::YUVFrame) {
    let (y, u, v) = buffer.data_mut();
    let width = yuv.width as usize;
    let height = yuv.height as usize;
    let y_stride = yuv.luminance_stride as usize;
    let c_stride = yuv.chrominance_stride as usize;

    for row in 0..height {
        let src = &yuv.luminance_bytes[row * y_stride..row * y_stride + width];
        y[row * width..row * width + width].copy_from_slice(src);
    }

    let (cw, ch) = (width / 2, height / 2);
    for row in 0..ch {
        for col in 0..cw {
            let base = row * c_stride + col * 2;
            u[row * cw + col] = yuv.chrominance_bytes[base];
            v[row * cw + col] = yuv.chrominance_bytes[base + 1];
        }
    }
}

async fn run_session(
    url: &str,
    token: &str,
    stop: Arc<AtomicBool>,
    height_tier: u32,
    fps: u32,
    error_sink: Arc<Mutex<Option<String>>>,
) -> Result<(), String> {
    let (room, _events) = Room::connect(url, token, RoomOptions::default())
        .await
        .map_err(|error| format!("连接 LiveKit 失败: {error}"))?;

    // 采集器创建 + 首帧（阻塞，放独立线程）
    struct FirstFrame {
        capturer: Capturer,
        width: u32,
        height: u32,
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
            ..Default::default()
        })
        .map_err(|error| format!("创建采集器失败（检查屏幕录制权限）: {error}"))?;
        capturer.start_capture();
        let frame = capturer
            .get_next_frame()
            .map_err(|error| format!("首帧获取失败: {error}"))?;
        match frame {
            scap::frame::Frame::YUVFrame(f) => {
                Ok(FirstFrame { capturer, width: f.width as u32, height: f.height as u32 })
            }
            _ => Err("首帧不是预期的 NV12 格式".into()),
        }
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

    // Manual PCM sources have their own SDK clock; never substitute microphone audio.
    #[cfg(target_os = "macos")]
    let _system_audio = match crate::system_audio::SystemAudio::start(&room, error_sink).await {
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
        while !loop_stop.load(Ordering::Relaxed) {
            if let Ok(frame) = capturer.get_next_frame() {
                if let scap::frame::Frame::YUVFrame(ref yuv) = frame {
                    let mut buffer = I420Buffer::new(yuv.width as u32, yuv.height as u32);
                    fill_i420(&mut buffer, yuv);
                    let video_frame = VideoFrame::new(VideoRotation::VideoRotation0, buffer);
                    let _ = source.capture_frame(&video_frame);
                }
            }
        }
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
