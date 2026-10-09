// 推流引擎：原生采集（ScreenCaptureKit）→ NV12→I420 → libwebrtc → LiveKit。
//
// 由尖刺 2 验证过的链路，包成可控启停的会话。
use base64::Engine;
use livekit::options::{DegradationPreference, TrackPublishOptions, VideoCodec, VideoEncoding};
use livekit::prelude::*;
use livekit::webrtc::prelude::{
    I420Buffer, RtcAudioSource, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation,
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
        if let Err(error) = run_session(&url, &token, stop_clone, height_tier, fps).await {
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
    let first = tokio::task::spawn_blocking(move || -> Result<FirstFrame, String> {
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

    // ---- 系统音频（macOS）：ScreenCaptureKit 采集 → 子进程输出 PCM → 发布音频轨 ----
    // 找采集器：优先应用包内（Contents/MacOS），开发态用 tools 目录
    // 启用平台音频时钟：纯手动推帧模式下 ADM 不会启动，推入的帧没人消费
    // （接收端只有静音）。创建实例后音频时钟开始运行，推入的帧才会被编码发送。
    // 实例需要保活到会话结束（drop 会关闭 ADM）。
    let platform_audio = match PlatformAudio::new() {
        Ok(audio) => {
            // 关键：RtcAudioSource::Native 的轨道不会自动启动 ADM 录音，
            // 而音频数据泵靠录音时钟驱动 —— 必须手动 start_recording。
            match audio.start_recording() {
                Ok(()) => log_to_file("PlatformAudio 已启用，录音时钟已启动"),
                Err(error) => log_to_file(&format!("start_recording 失败: {error}")),
            }
            Some(audio)
        }
        Err(error) => {
            log_to_file(&format!("PlatformAudio 启用失败: {error}"));
            None
        }
    };
    let sidecar = crate::find_audio_capture_helper();

    if let Some(sidecar_path) = sidecar {
        match std::process::Command::new(sidecar_path)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
        {
            Ok(mut child) => {
                let mut stdout = child.stdout.take().expect("采集器 stdout");
                // 采集器的 stderr 单独记录（启动错误都在这里）
                if let Some(stderr) = child.stderr.take() {
                    std::thread::spawn(move || {
                        use std::io::BufRead;
                        let reader = std::io::BufReader::new(stderr);
                        for line in reader.lines().flatten() {
                            log_to_file(&format!("[audio-capture] {line}"));
                        }
                    });
                }
                // 改用 SDK 主路径（RtcAudioSource::Device）：PlatformAudio 管理的
                // 录音设备。当前录制设备 = 系统默认麦克风（实验验证 Device 路径）；
                // 后续装 BlackHole 虚拟声卡后，用 set_recording_device 切到它
                // 即可采集真正的系统音频（无需推帧，SDK 已验证的路径）。
                let platform_audio = match PlatformAudio::new() {
                    Ok(audio) => audio,
                    Err(error) => {
                        let message = format!("PlatformAudio 启用失败: {error}");
                        println!("[publisher] {message}");
                        log_to_file(&message);
                        return Err(message);
                    }
                };
                if let Err(error) = platform_audio.start_recording() {
                    let message = format!("启动录音失败: {error}");
                    println!("[publisher] {message}");
                    log_to_file(&message);
                    return Err(message);
                }
                let audio_track = LocalAudioTrack::create_audio_track(
                    "system-audio",
                    platform_audio.rtc_source(),
                );
                if let Err(error) = room
                    .local_participant()
                    .publish_track(
                        LocalTrack::Audio(audio_track),
                        TrackPublishOptions {
                            source: TrackSource::Microphone,
                            ..Default::default()
                        },
                    )
                    .await
                {
                    let message = format!("发布音频轨失败: {error}");
                    println!("[publisher] {message}");
                    log_to_file(&message);
                    child.kill().ok();
                } else {
                    println!("[publisher] 系统音频轨已发布");
                    log_to_file("系统音频轨已发布");


                }
            }
            Err(error) => {
                let message = format!("启动音频采集器失败: {error}");
                println!("[publisher] {message}");
                log_to_file(&message);
            }
        }
    } else {
        let message = "未找到音频采集器（macos-audio-capture），本次投送无声音";
        println!("[publisher] {message}");
        log_to_file(message);
    }

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
