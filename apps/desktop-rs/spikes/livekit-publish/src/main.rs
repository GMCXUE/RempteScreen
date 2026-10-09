// 尖刺 2：Rust 端原生采集 → LiveKit 推流。
//
// 链路：scap(ScreenCaptureKit, NV12) → 拆 UV 平面成 I420 → libwebrtc NativeVideoSource
//       → LocalVideoTrack → 连上现有 LiveKit 服务器发布。
//
// 环境变量：LK_URL / LK_KEY / LK_SECRET / LK_ROOM
// 运行 20 秒后自动退出，期间打印采集/发布状态。
use base64::Engine;
use hmac::{Hmac, Mac};
use livekit::webrtc::prelude::{I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation};
use livekit::webrtc::video_source::native::NativeVideoSource;
use livekit::options::{TrackPublishOptions, VideoCodec};
use livekit::prelude::*;
use livekit::track::LocalVideoTrack;
use livekit::{Room, RoomOptions};
use scap::capturer::{Capturer, Options};
use serde_json::json;
use sha2::Sha256;
use std::sync::Arc;
use std::time::{Duration, Instant};

fn b64url(data: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(data)
}

/// 用 HS256 手工签 LiveKit JWT（服务端同款 key/secret）。
fn mint_token(key: &str, secret: &str, identity: &str, room: &str) -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;

    let header = b64url(json!({"alg": "HS256", "typ": "JWT"}).to_string().as_bytes());
    let payload = b64url(
        json!({
            "iss": key,
            "sub": identity,
            "nbf": now - 10,
            "iat": now,
            "exp": now + 3600,
            "name": "rust-spike",
            "video": {
                "room": room,
                "roomJoin": true,
                "canPublish": true,
                "canPublishData": true
            }
        })
        .to_string()
        .as_bytes(),
    );
    let signing_input = format!("{header}.{payload}");
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(signing_input.as_bytes());
    let sig = b64url(&mac.finalize().into_bytes());
    format!("{signing_input}.{sig}")
}

/// NV12（Y 平面 + UV 交错平面）→ I420 三平面，逐行拷贝。
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

fn main() {
    let url = std::env::var("LK_URL").unwrap_or_else(|_| "ws://91.208.104.182".into());
    let key = std::env::var("LK_KEY").expect("LK_KEY");
    let secret = std::env::var("LK_SECRET").expect("LK_SECRET");
    let room_name = std::env::var("LK_ROOM").unwrap_or_else(|_| "spike-rust-publish".into());

    if !scap::has_permission() {
        println!("缺少屏幕录制权限，请在系统设置中允许后重跑");
        return;
    }

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .unwrap();
    runtime.block_on(async move {
        let token = mint_token(&key, &secret, "rust-spike-publisher", &room_name);
        println!("连接 {url}，房间 {room_name} ……");
        let (room, mut events) = Room::connect(&url, &token, RoomOptions::default())
            .await
            .expect("连接失败");
        println!("✅ 已连上 LiveKit");

        // 采集：默认输出 YUVFrame（NV12）
        let mut capturer = Capturer::build(Options { fps: 60, ..Default::default() })
            .expect("创建采集器失败");
        capturer.start_capture();

        // 用第一帧确定分辨率，再创建视频源与轨道
        let first = capturer.get_next_frame().expect("首帧获取失败");
        let (width, height, yuv) = match first {
            scap::frame::Frame::YUVFrame(f) => (f.width, f.height, f),
            other => panic!("意外的帧类型 {other:?}"),
        };
        println!("采集分辨率：{width}×{height}，开始推流（20 秒）……");

        let source = NativeVideoSource::new(
            VideoResolution { width: width as u32, height: height as u32 },
            true, // is_screencast：让编码器走屏幕内容优化
        );
        let track = LocalVideoTrack::create_video_track(
            "spike-screen",
            RtcVideoSource::Native(source.clone()),
        );
        room.local_participant()
            .publish_track(
                LocalTrack::Video(track),
                TrackPublishOptions {
                    video_codec: VideoCodec::H264,
                    simulcast: false,
                    ..Default::default()
                },
            )
            .await
            .expect("发布失败");
        println!("✅ 视频轨已发布");

        // 采集线程：NV12 → I420 → capture_frame
        let frame_counter = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter = frame_counter.clone();
        let capture_task = std::thread::spawn(move || {
            let mut seconds = 0u32;
            let mut frames_this_second = 0u32;
            let mut second_start = Instant::now();
            loop {
                if let Ok(frame) = capturer.get_next_frame() {
                    if let scap::frame::Frame::YUVFrame(ref yuv) = frame {
                        let mut buffer = I420Buffer::new(yuv.width as u32, yuv.height as u32);
                        fill_i420(&mut buffer, yuv);
                        let video_frame = VideoFrame::new(VideoRotation::VideoRotation0, buffer);
                        let _ = source.capture_frame(&video_frame);
                        frames_this_second += 1;
                        counter.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                }
                if second_start.elapsed() >= Duration::from_secs(1) {
                    seconds += 1;
                    println!("  采集第 {seconds:2} 秒：{frames_this_second:3} fps");
                    frames_this_second = 0;
                    second_start = Instant::now();
                    if seconds >= 20 {
                        break;
                    }
                }
            }
        });

        // 事件打印（连接/发布相关）
        let event_task = tokio::spawn(async move {
            let deadline = Instant::now() + Duration::from_secs(25);
            while Instant::now() < deadline {
                if let Ok(Some(event)) =
                    tokio::time::timeout(Duration::from_millis(500), events.recv()).await
                {
                    let name = match &event {
                        RoomEvent::TrackPublished { publication, .. } => {
                            format!("TrackPublished sid={} muted={}", publication.sid(), publication.is_muted())
                        }
                        
                        RoomEvent::Connected { .. } => "Connected".into(),
                        RoomEvent::Disconnected { reason, .. } => {
                            println!("  事件: Disconnected reason={reason:?}");
                            continue;
                        }
                        _ => continue,
                    };
                    println!("  事件: {name}");
                }
            }
        });

        capture_task.join().unwrap();
        event_task.abort();

        let total = frame_counter.load(std::sync::atomic::Ordering::Relaxed);
        println!("结束：20 秒共采集 {total} 帧（平均 {:.1} fps）", total as f64 / 20.0);
        let _ = room.close().await;
    });
}
