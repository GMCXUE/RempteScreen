// 观看引擎：订阅远端屏幕轨道 → 解码 I420 → RGB → JPEG → 帧池。
//
// 前端通过自定义协议 frame://localhost/latest 每帧拉取最新 JPEG 绘制到 canvas。
// 这样避免把整帧原始像素（1080p RGBA 约 8MB）经 IPC 传给 WebView —— 那会直接压垮通道。
use futures_util::StreamExt;
use tauri::{Manager, Emitter};
#[cfg(target_os = "macos")]
use mozjpeg::{ColorSpace, Compress};
use livekit::prelude::*;
use livekit::webrtc::prelude::VideoBuffer;
use livekit::webrtc::video_stream::native::NativeVideoStream;
use livekit::Room;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// 观看状态（前端轮询显示）
#[derive(Clone, Default, Serialize)]
pub struct WatchStats {
    pub active: bool,
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub frames: u64,
    pub device_name: String,
    /// 解码（I420→RGB）与编码（→JPEG）各自的平均耗时，用于判断瓶颈
    pub convert_ms: f32,
    pub encode_ms: f32,
}

pub type FrameStore = Arc<Mutex<Option<Vec<u8>>>>;

/// 远端音频轨句柄（SDK 不暴露播放接口，这里只保留开关能力）
pub type AudioTrackStore = Arc<Mutex<Option<RemoteAudioTrack>>>;

pub struct WatchSession {
    stop: Arc<AtomicBool>,
    /// 本端 LocalParticipant：观看窗口发文件时用它走数据通道
    pub local: Arc<Mutex<Option<LocalParticipant>>>,
    /// 当前投送端身份：文件数据只发给它，避免同房间其他观看者收到文件。
    pub remote: Arc<Mutex<Option<ParticipantIdentity>>>,
    pub call: Arc<Mutex<crate::call::CallMedia>>,
}

impl WatchSession {
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Relaxed);
        self.call.lock().unwrap().close();
    }
}

fn peer_ended(app: Option<&tauri::AppHandle>, stop: &Arc<AtomicBool>, name: &str) {
    let Some(app) = app else { stop.store(true, Ordering::Relaxed); return; };
    let state = app.state::<crate::AppState>();
    let mut session = state.watch.lock().unwrap();
    if !session.as_ref().is_some_and(|current| Arc::ptr_eq(&current.stop, stop)) { return; }
    if let Some(current) = session.take() { current.stop(); }
    *state.frames.lock().unwrap() = None;
    *state.watch_camera_frames.lock().unwrap() = None;
    *state.audio.lock().unwrap() = None;
    *state.watch_stats.lock().unwrap() = WatchStats::default();
    state.watch_mode.lock().unwrap().clear();
    drop(session);
    if let Some(window) = app.get_webview_window("viewer") { let _ = window.destroy(); }
    let _ = app.emit("watch:peer-ended", format!("{name} 已停止投送"));
}

pub fn start_watch(
    livekit_url: &str,
    token: &str,
    device_name: &str,
    error_sink: Arc<Mutex<Option<String>>>,
    frames: FrameStore,
    stats: Arc<Mutex<WatchStats>>,
    audio: AudioTrackStore,
    volume: crate::audio_playout::Volume,
    voice_volume: crate::audio_playout::Volume,
    app: Option<tauri::AppHandle>,
    ft_recv: Arc<Mutex<crate::file_transfer::RecvMgr>>,
    camera_frames: FrameStore,
) -> Result<WatchSession, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let stop_clone = stop.clone();
    let url = livekit_url.to_string();
    let token = token.to_string();
    let device_name = device_name.to_string();
    let local_out: Arc<Mutex<Option<LocalParticipant>>> = Arc::new(Mutex::new(None));
    let local_for_session = local_out.clone();
    let remote_out: Arc<Mutex<Option<ParticipantIdentity>>> = Arc::new(Mutex::new(None));
    let remote_for_session = remote_out.clone();
    let call = Arc::new(Mutex::new(crate::call::CallMedia::default()));
    let call_for_session = call.clone();

    tauri::async_runtime::spawn(async move {
        if let Err(error) = run_watch(
            &url,
            &token,
            &device_name,
            stop_clone.clone(),
            &frames,
            &stats,
            &audio,
            volume,
            voice_volume,
            app,
            ft_recv,
            local_out,
            remote_out,
            camera_frames,
        )
        .await
        {
            eprintln!("[viewer] 会话异常结束: {error}");
            log_to_file(&format!("观看会话异常结束: {error}"));
            if !stop_clone.load(Ordering::Relaxed) {
                *error_sink.lock().unwrap() = Some(error);
            }
        }
        if !stop_clone.load(Ordering::Relaxed) { stats.lock().unwrap().active = false; }
        call.lock().unwrap().close();
    });

    Ok(WatchSession {
        stop,
        local: local_for_session,
        remote: remote_for_session,
        call: call_for_session,
    })
}

pub fn log_to_file(message: &str) {
    crate::publisher::log_to_file(message);
}

/// I420 → RGB（BT.601），按 stride 取样，`step` 为降采样步长。
///
/// 编码耗时与像素数成正比：Retina 全屏（3024×1964 ≈ 590 万像素）先抽到长边 1920
/// 再编码，帧率能翻倍、JPEG 也小一半，投屏清晰度不受影响。
fn i420_to_rgb(
    out: &mut Vec<u8>,
    width: usize,
    height: usize,
    step: usize,
    y: &[u8],
    stride_y: usize,
    u: &[u8],
    stride_u: usize,
    v: &[u8],
    stride_v: usize,
) -> (usize, usize) {
    let out_width = width.div_ceil(step);
    let out_height = height.div_ceil(step);
    out.resize(out_width * out_height * 3, 0);
    let chroma_width = width / 2;

    for out_row_index in 0..out_height {
        let row = out_row_index * step;
        let y_row = &y[row * stride_y..row * stride_y + width];
        let c_row = row / 2;
        let u_row = &u[c_row * stride_u..c_row * stride_u + chroma_width];
        let v_row = &v[c_row * stride_v..c_row * stride_v + chroma_width];
        let out_row = &mut out[out_row_index * out_width * 3..(out_row_index + 1) * out_width * 3];

        for out_col_index in 0..out_width {
            let col = out_col_index * step;
            let yv = y_row[col] as i32 - 16;
            let uv = u_row[col / 2] as i32 - 128;
            let vv = v_row[col / 2] as i32 - 128;
            let r = (298 * yv + 409 * vv + 128) >> 8;
            let g = (298 * yv - 100 * uv - 208 * vv + 128) >> 8;
            let b = (298 * yv + 516 * uv + 128) >> 8;
            let base = out_col_index * 3;
            out_row[base] = r.clamp(0, 255) as u8;
            out_row[base + 1] = g.clamp(0, 255) as u8;
            out_row[base + 2] = b.clamp(0, 255) as u8;
        }
    }
    (out_width, out_height)
}

async fn run_watch(
    url: &str,
    token: &str,
    device_name: &str,
    stop: Arc<AtomicBool>,
    frames: &FrameStore,
    stats: &Arc<Mutex<WatchStats>>,
    audio: &AudioTrackStore,
    volume: crate::audio_playout::Volume,
    voice_volume: crate::audio_playout::Volume,
    app: Option<tauri::AppHandle>,
    ft_recv: Arc<Mutex<crate::file_transfer::RecvMgr>>,
    local_out: Arc<Mutex<Option<LocalParticipant>>>,
    remote_out: Arc<Mutex<Option<ParticipantIdentity>>>,
    camera_frames: FrameStore,
) -> Result<(), String> {
    // 音频改由自管播放（audio_playout）：NativeAudioStream 拉帧 → cpal 输出，
    // 音量可控（ADM 扬声器无法调音量），输出走系统默认设备（系统音量也生效）。
    let (room, mut events) = Room::connect(url, token, crate::call::call_room_options())
        .await
        .map_err(|error| format!("连接失败: {error}"))?;
    let peer_identity = format!("caster-{}", room.name().trim_start_matches("device-"));
    let _quality = crate::call_quality::start(&room, stop.clone(), Some(peer_identity.clone()));
    let local = room.local_participant();
    *local_out.lock().unwrap() = Some(local.clone());

    // 等订阅到对方的视频轨：对方同意后可能还要过系统级的屏幕录制授权弹窗，
    // 所以给足 60 秒，避免"人都同意了，画面却被超时挡掉"。
    // 自管音频播放句柄：保活即播放，离开作用域即停止
    let mut playouts: Vec<crate::audio_playout::PlayoutHandle> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut video_track = None;
    while Instant::now() < deadline && !stop.load(Ordering::Relaxed) {
        match tokio::time::timeout(Duration::from_millis(500), events.recv()).await {
            Ok(Some(RoomEvent::TrackSubscribed {
                track,
                publication,
                participant,
            })) => {
                if stop.load(Ordering::Relaxed) || participant.identity().as_str() != peer_identity { continue; }
                *remote_out.lock().unwrap() = Some(participant.identity());
                match track {
                    RemoteTrack::Video(track) => {
                        if publication.source() == TrackSource::Camera {
                            spawn_camera_decoder(track, camera_frames.clone(), stop.clone());
                        } else if publication.source() == TrackSource::Screenshare
                            || (publication.source() == TrackSource::Unknown && publication.name() == "screen") {
                            video_track = Some(track);
                            break;
                        }
                    }
                    RemoteTrack::Audio(track) => {
                        // 对方推了音频：记下句柄并启动自管播放（音量由 UI 滑块控制）
                        match crate::audio_playout::start(&track, if publication.source() == TrackSource::Microphone { voice_volume.clone() } else { volume.clone() }) {
                            Ok(p) => playouts.push(p),
                            Err(error) => {
                                log_to_file(&format!("启动音频播放失败: {error}"))
                            }
                        }
                        *audio.lock().unwrap() = Some(track);
                    }
                    _ => {}
                }
            }
            Ok(Some(RoomEvent::DataReceived {
                payload,
                topic,
                participant,
                ..
            })) => {
                crate::file_transfer::handle_packet(
                    &local,
                    &payload,
                    topic.as_deref(),
                    participant.map(|value| value.identity()),
                    &ft_recv,
                    app.as_ref(),
                );
            }
            Ok(Some(RoomEvent::TrackMuted { publication, .. }))
                if publication.source() == TrackSource::Camera =>
            {
                *camera_frames.lock().unwrap() = None;
            }
            Ok(Some(RoomEvent::TrackUnsubscribed { publication, .. }))
                if publication.source() == TrackSource::Camera =>
            {
                *camera_frames.lock().unwrap() = None;
            }
            Ok(Some(RoomEvent::ParticipantDisconnected(participant)))
                if participant.identity().as_str() == peer_identity => {
                    peer_ended(app.as_ref(), &stop, device_name);
                    break;
                }
            Ok(Some(RoomEvent::Disconnected { .. })) | Ok(None) => {
                peer_ended(app.as_ref(), &stop, device_name);
                break;
            }
            Ok(Some(_)) => {},
            Err(_) => {} // 超时继续等
        }
    }

    if stop.load(Ordering::Relaxed) { let _ = room.close().await; return Ok(()); }
    let Some(track) = video_track else {
        let _ = room.close().await;
        return Err("对方还没有开启投送".into());
    };
    {
        let mut stats = stats.lock().unwrap();
        *stats = WatchStats::default();
        stats.active = true;
        stats.device_name = device_name.to_string();
    }

    // 视频订阅完成后，继续监听事件以接收可能后到的音频轨
    let audio_sink = audio.clone();
    let audio_stop = stop.clone();
    let ft_local = local.clone();
    let ft_events_app = app.clone();
    let camera_events_frames = camera_frames.clone();
    let camera_events_stop = stop.clone();
    let peer_app = app.clone();
    let peer_name = device_name.to_string();
    tokio::spawn(async move {
        let mut reconnect_deadline: Option<Instant> = None;
        while !audio_stop.load(Ordering::Relaxed) {
            if reconnect_deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                peer_ended(peer_app.as_ref(), &audio_stop, &peer_name);
                break;
            }
            match tokio::time::timeout(Duration::from_millis(500), events.recv()).await {
                Ok(Some(RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Audio(track),
                    participant,
                    publication,
                })) => {
                    if audio_stop.load(Ordering::Relaxed) || participant.identity().as_str() != peer_identity { continue; }
                    *remote_out.lock().unwrap() = Some(participant.identity());
                    match crate::audio_playout::start(&track, if publication.source() == TrackSource::Microphone { voice_volume.clone() } else { volume.clone() }) {
                        Ok(p) => playouts.push(p),
                        Err(error) => log_to_file(&format!("启动音频播放失败: {error}")),
                    }
                    *audio_sink.lock().unwrap() = Some(track);
                }
                Ok(Some(RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Video(track),
                    publication,
                    participant,
                })) if publication.source() == TrackSource::Camera => {
                    if audio_stop.load(Ordering::Relaxed) || participant.identity().as_str() != peer_identity { continue; }
                    *remote_out.lock().unwrap() = Some(participant.identity());
                    spawn_camera_decoder(
                        track,
                        camera_events_frames.clone(),
                        camera_events_stop.clone(),
                    );
                }
                Ok(Some(RoomEvent::DataReceived {
                    payload,
                    topic,
                    participant,
                    ..
                })) => {
                    crate::file_transfer::handle_packet(
                        &ft_local,
                        &payload,
                        topic.as_deref(),
                        participant.map(|value| value.identity()),
                        &ft_recv,
                        ft_events_app.as_ref(),
                    );
                }
                Ok(Some(RoomEvent::TrackMuted { publication, .. }))
                    if publication.source() == TrackSource::Camera =>
                {
                    *camera_events_frames.lock().unwrap() = None;
                }
                Ok(Some(RoomEvent::TrackUnsubscribed { publication, .. }))
                    if publication.source() == TrackSource::Camera =>
                {
                    *camera_events_frames.lock().unwrap() = None;
                }
                Ok(Some(RoomEvent::ParticipantDisconnected(participant)))
                    if participant.identity().as_str() == peer_identity => {
                        peer_ended(peer_app.as_ref(), &audio_stop, &peer_name); break;
                    }
                Ok(Some(RoomEvent::TrackUnpublished { publication, participant }))
                    if participant.identity().as_str() == peer_identity &&
                        (publication.source() == TrackSource::Screenshare ||
                         (publication.source() == TrackSource::Unknown && publication.name() == "screen")) => {
                        peer_ended(peer_app.as_ref(), &audio_stop, &peer_name); break;
                    }
                Ok(Some(RoomEvent::Disconnected { .. })) | Ok(None) => {
                    peer_ended(peer_app.as_ref(), &audio_stop, &peer_name); break;
                }
                Ok(Some(RoomEvent::Reconnecting)) => { reconnect_deadline.get_or_insert(Instant::now() + Duration::from_secs(30)); }
                Ok(Some(RoomEvent::Reconnected)) => { reconnect_deadline = None; }
                Ok(Some(_)) => {},
                Err(_) => {}
            }
        }
    });

    let mut stream = NativeVideoStream::new(track.rtc_track());
    let mut rgb: Vec<u8> = Vec::new();
    let mut jpeg: Vec<u8> = Vec::new();
    let mut window_start = Instant::now();
    let mut window_frames = 0u32;
    let mut last_fps = 0u32;
    let mut last_encode = Instant::now() - Duration::from_secs(1);

    loop {
        if stop.load(Ordering::Relaxed) {
            break;
        }

        let next = tokio::time::timeout(Duration::from_millis(300), stream.next()).await;
        if stop.load(Ordering::Relaxed) { break; }
        let frame = match next {
            Ok(Some(frame)) => frame,
            Ok(None) => { peer_ended(app.as_ref(), &stop, device_name); break; },  // 流结束（对方停止投送）
            Err(_) => continue, // 暂无帧
        };

        // 轻量限速：编解码是瓶颈，丢帧比堆积延迟好；上限交给实际编码耗时决定
        if last_encode.elapsed() < Duration::from_millis(12) {
            continue;
        }
        last_encode = Instant::now();

        let i420 = frame.buffer.to_i420();
        let width = i420.width() as usize;
        let height = i420.height() as usize;
        if width == 0 || height == 0 {
            continue;
        }

        let convert_start = Instant::now();
        // 长边超过 1920 时整数倍降采样，兼顾帧率与清晰度
        let long_side = width.max(height);
        let step = if long_side > 1920 { long_side.div_ceil(1920) } else { 1 };

        let (y, u, v) = i420.data();
        let (stride_y, stride_u, stride_v) = i420.strides();
        let (out_width, out_height) = i420_to_rgb(
            &mut rgb,
            width,
            height,
            step,
            y,
            stride_y as usize,
            u,
            stride_u as usize,
            v,
            stride_v as usize,
        );

        let encode_start = Instant::now();
        jpeg = encode_jpeg(&rgb, out_width, out_height);
        let encode_ms = encode_start.elapsed().as_secs_f32() * 1000.0;
        let convert_ms = convert_start.elapsed().as_secs_f32() * 1000.0 - encode_ms;
        *frames.lock().unwrap() = Some(jpeg.clone());

        window_frames += 1;
        if window_start.elapsed() >= Duration::from_secs(1) {
            last_fps = window_frames;
            window_frames = 0;
            window_start = Instant::now();
        }
        {
            let mut stats = stats.lock().unwrap();
            stats.width = out_width as u32;
            stats.height = out_height as u32;
            stats.fps = last_fps;
            stats.frames += 1;
            stats.convert_ms = convert_ms;
            stats.encode_ms = encode_ms;
        }
    }

    if !stop.load(Ordering::Relaxed) {
        *frames.lock().unwrap() = None;
        *camera_frames.lock().unwrap() = None;
        *audio.lock().unwrap() = None;
        *stats.lock().unwrap() = WatchStats::default();
    }
    stop.store(true, Ordering::Relaxed);
    let _ = room.close().await;
    println!("[viewer] 会话已结束");
    Ok(())
}

/// 把通话摄像头轨独立编码到小窗帧池，绝不覆盖屏幕共享主画面。
pub fn spawn_camera_decoder(track: RemoteVideoTrack, frames: FrameStore, stop: Arc<AtomicBool>) -> Arc<AtomicBool> {
    spawn_camera_preview(track.rtc_track(), frames, stop)
}

/// Local and remote camera previews share the same bounded frame decoder.
pub fn spawn_camera_preview(track: livekit::webrtc::video_track::RtcVideoTrack, frames: FrameStore, stop: Arc<AtomicBool>) -> Arc<AtomicBool> {
    let cancelled = Arc::new(AtomicBool::new(false));
    let cancel = cancelled.clone();
    tauri::async_runtime::spawn(async move {
        let mut stream = NativeVideoStream::new(track);
        let mut rgb = Vec::new();
        let mut window_start = Instant::now();
        let mut window_frames = 0u32;
        while !stop.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) {
            let next = tokio::time::timeout(Duration::from_millis(400), stream.next()).await;
            if stop.load(Ordering::Relaxed) || cancel.load(Ordering::Relaxed) { break; }
            let frame = match next {
                Ok(Some(frame)) => frame,
                Ok(None) => break,
                Err(_) => continue,
            };
            // The SDK stream keeps only the latest queued frame. A time gate
            // here aliases 30 fps to 15 fps and drops jittery 24 fps frames.
            // Encode on a blocking worker so two camera previews do not stall
            // media events, audio, or signaling on the async runtime.
            let encoded = tokio::task::spawn_blocking(move || {
                let i420 = frame.buffer.to_i420();
                let width = i420.width() as usize;
                let height = i420.height() as usize;
                if width == 0 || height == 0 {
                    return (rgb, None);
                }
                let (y, u, v) = i420.data();
                let (stride_y, stride_u, stride_v) = i420.strides();
                let (out_width, out_height) = i420_to_rgb(
                    &mut rgb,
                    width,
                    height,
                    1,
                    y,
                    stride_y as usize,
                    u,
                    stride_u as usize,
                    v,
                    stride_v as usize,
                );
                let jpeg = encode_jpeg_quality(&rgb, out_width, out_height, 85);
                (rgb, Some((jpeg, out_width, out_height)))
            }).await;
            let Ok((reused_rgb, encoded)) = encoded else { break; };
            rgb = reused_rgb;
            let Some((jpeg, width, height)) = encoded else { continue; };
            window_frames += 1;
            if window_start.elapsed() >= Duration::from_secs(10) {
                log_to_file(&format!("[camera-render] {width}×{height} fps={:.1}",
                    window_frames as f64 / window_start.elapsed().as_secs_f64()));
                window_frames = 0;
                window_start = Instant::now();
            }
            let mut latest = frames.lock().unwrap();
            if !stop.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) { *latest = Some(jpeg); }
        }
        if !stop.load(Ordering::Relaxed) && !cancel.load(Ordering::Relaxed) { *frames.lock().unwrap() = None; }
    });
    cancelled
}


/// 把 RGB 帧编码为 JPEG。
/// macOS 用 mozjpeg（libjpeg-turbo，快 2~3 倍，帧率关键）；
/// 其他平台（Windows 交叉编译）用纯 Rust 的 jpeg-encoder（无 C 依赖）。
fn encode_jpeg(rgb: &[u8], width: usize, height: usize) -> Vec<u8> {
    encode_jpeg_quality(rgb, width, height, 75)
}

#[cfg(target_os = "macos")]
fn encode_jpeg_quality(rgb: &[u8], width: usize, height: usize, quality: u8) -> Vec<u8> {
    let mut compress = Compress::new(ColorSpace::JCS_RGB);
    // mozjpeg 默认开 trellis 等慢速优化（实测编码 78ms/帧），
    // 切到 FASTEST 档位后降到几毫秒 —— 实时投屏优先帧率
    compress.set_fastest_defaults();
    compress.set_size(width, height);
    compress.set_quality(quality as f32);
    let mut started = compress
        .start_compress(Vec::new())
        .expect("JPEG 初始化失败");
    started.write_scanlines(rgb).expect("JPEG 编码失败");
    started.finish().expect("JPEG 收尾失败")
}

#[cfg(not(target_os = "macos"))]
fn encode_jpeg_quality(rgb: &[u8], width: usize, height: usize, quality: u8) -> Vec<u8> {
    use jpeg_encoder::{ColorType, Encoder};
    let mut jpeg = Vec::new();
    let encoder = Encoder::new(&mut jpeg, quality);
    encoder
        .encode(rgb, width as u16, height as u16, ColorType::Rgb)
        .expect("JPEG 编码失败");
    jpeg
}
