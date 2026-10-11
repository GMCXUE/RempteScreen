//! 会话内语音/视频通话轨。麦克风与摄像头分别发布为 Microphone/Camera，
//! 与屏幕及系统声音轨完全分离。

use livekit::options::{TrackPublishOptions, VideoCodec, VideoEncoding};
use livekit::prelude::*;
#[cfg(target_os = "macos")]
use livekit::webrtc::prelude::{NV12Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation};
#[cfg(target_os = "macos")]
use livekit::webrtc::video_frame::native::VideoFrameBufferExt;
#[cfg(target_os = "macos")]
use livekit::webrtc::video_source::native::NativeVideoSource;
#[cfg(target_os = "macos")]
use std::io::{BufRead, Read};
#[cfg(target_os = "macos")]
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct CallMedia {
    busy: bool,
    closed: bool,
    microphone: Option<MicrophoneCapture>,
    camera: Option<CameraCapture>,
}

impl CallMedia {
    pub fn close(&mut self) {
        self.closed = true;
        self.microphone.take();
        self.camera.take();
    }

    pub fn microphone_enabled(&self) -> bool {
        self.microphone.is_some()
    }

    pub fn camera_enabled(&self) -> bool {
        self.camera.is_some()
    }

    pub fn camera_preview(&self) -> Option<Vec<u8>> {
        self.camera.as_ref().and_then(|camera| camera.preview.frames.lock().unwrap().clone())
    }
}

struct Operation(Arc<Mutex<CallMedia>>);
impl Operation {
    fn begin(media: &Arc<Mutex<CallMedia>>) -> Result<Self, String> {
        let mut state = media.lock().unwrap();
        if state.closed { return Err("通话会话已经关闭".into()); }
        if state.busy { return Err("通话操作处理中，请稍后重试".into()); }
        state.busy = true;
        Ok(Self(media.clone()))
    }
}
impl Drop for Operation {
    fn drop(&mut self) { self.0.lock().unwrap().busy = false; }
}

struct MicrophoneCapture {
    _audio: crate::microphone::Microphone,
    publication: LocalTrackPublication,
}

pub async fn set_microphone(
    local: &LocalParticipant,
    media: &Arc<Mutex<CallMedia>>,
    enabled: bool,
) -> Result<(), String> {
    let _operation = Operation::begin(media)?;
    if enabled {
        if media.lock().unwrap().microphone.is_some() {
            return Ok(());
        }
        let audio = tokio::task::spawn_blocking(crate::microphone::Microphone::start)
            .await.map_err(|error| format!("打开麦克风失败：{error}"))??;
        if media.lock().unwrap().closed {return Err("通话会话已经关闭".into());}
        let track = LocalAudioTrack::create_audio_track("voice-microphone", audio.source());
        let publication = local
            .publish_track(
                LocalTrack::Audio(track),
                TrackPublishOptions {
                    source: TrackSource::Microphone,
                    ..Default::default()
                },
            )
            .await
            .map_err(|error| format!("发布麦克风失败：{error}"))?;
        let capture = MicrophoneCapture { _audio: audio, publication };
        let sid = capture.publication.sid();
        let closed = {
            let mut state = media.lock().unwrap();
            if state.closed { true } else { state.microphone = Some(capture); false }
        };
        if closed {
            let _ = local.unpublish_track(&sid).await;
            return Err("通话会话已经关闭".into());
        }
    } else {
        let capture = media.lock().unwrap().microphone.take();
        if let Some(capture) = capture {
            let _ = local.unpublish_track(&capture.publication.sid()).await;
        }
    }
    Ok(())
}

pub async fn set_camera(
    local: &LocalParticipant,
    media: &Arc<Mutex<CallMedia>>,
    enabled: bool,
) -> Result<(), String> {
    let _operation = Operation::begin(media)?;
    if enabled {
        if media.lock().unwrap().camera.is_some() {
            return Ok(());
        }
        let capture = CameraCapture::start(local,media.clone()).await?;
        let sid = capture.publication.sid();
        #[cfg(target_os = "windows")]
        let capture_stopped = capture._native.stop_flag();
        let closed = {
            let mut state = media.lock().unwrap();
            if state.closed { true } else { state.camera = Some(capture); false }
        };
        if closed {
            let _ = local.unpublish_track(&sid).await;
            return Err("通话会话已经关闭".into());
        }
        #[cfg(target_os = "windows")]
        {
            let media = Arc::downgrade(media);
            let local = local.clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(200)).await;
                    let Some(media) = media.upgrade() else { break; };
                    if capture_stopped.load(std::sync::atomic::Ordering::Relaxed) {
                        let removed = {
                            let mut state = media.lock().unwrap();
                            if state.camera.as_ref().is_some_and(|capture| capture.publication.sid() == sid) {
                                state.camera.take(); true
                            } else { false }
                        };
                        if removed { let _ = local.unpublish_track(&sid).await; }
                        break;
                    }
                }
            });
        }
    } else {
        let capture = media.lock().unwrap().camera.take();
        if let Some(capture) = capture {
            let sid = capture.publication.sid();
            drop(capture);
            let _ = local.unpublish_track(&sid).await;
        }
    }
    Ok(())
}

struct CameraCapture {
    #[cfg(target_os = "macos")]
    child: Child,
    #[cfg(target_os = "macos")]
    reader: Option<std::thread::JoinHandle<()>>,
    #[cfg(target_os = "windows")]
    _native: crate::windows_camera::Capture,
    publication: LocalTrackPublication,
    preview: CameraPreview,
}

struct CameraPreview {
    frames: crate::viewer::FrameStore,
    stop: Arc<std::sync::atomic::AtomicBool>,
}
impl CameraPreview {
    fn start(track: &LocalVideoTrack) -> Self {
        let frames=Arc::new(Mutex::new(None));
        let stop=Arc::new(std::sync::atomic::AtomicBool::new(false));
        crate::viewer::spawn_camera_preview(track.rtc_track(),frames.clone(),stop.clone());
        Self { frames,stop }
    }
}
impl Drop for CameraPreview {
    fn drop(&mut self) {
        self.stop.store(true,std::sync::atomic::Ordering::Relaxed);
        *self.frames.lock().unwrap()=None;
    }
}

#[cfg(test)]
mod camera_preview_tests {
    use super::*;
    use livekit::webrtc::prelude::{I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation};
    use livekit::webrtc::video_source::native::NativeVideoSource;

    #[cfg(target_os = "macos")]
    #[test]
    fn mac_nv12_camera_preview_uses_capture_path() {
        tauri::async_runtime::block_on(async {
            let source=NativeVideoSource::new(VideoResolution{width:16,height:16},false);
            let track=LocalVideoTrack::create_video_track("nv12-preview-test",RtcVideoSource::Native(source.clone()));
            let preview=CameraPreview::start(&track);
            let frames=preview.frames.clone();
            let mut bytes=vec![128;16*16*3/2];bytes[..16*16].fill(90);
            let mut captured=false;
            for _ in 0..30 {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                capture_nv12(&source,16,16,&bytes).unwrap();
                if let Some(jpeg)=frames.lock().unwrap().as_ref() {
                    let image=image::load_from_memory(jpeg).unwrap().to_rgb8();
                    assert_eq!(image.dimensions(),(16,16));
                    let pixel=image.get_pixel(8,8).0;
                    if (60..120).contains(&pixel[0]) {
                        assert!(pixel.iter().all(|value|value.abs_diff(pixel[0])<5));
                        captured=true;break;
                    }
                }
            }
            assert!(captured,"NV12 capture must safely produce its own preview pixels");
            assert!(capture_nv12(&source,16,16,&bytes[..bytes.len()-1]).is_err());
            drop(preview);
            capture_nv12(&source,16,16,&bytes).unwrap();
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            assert!(frames.lock().unwrap().is_none());
        });
    }

    #[test]
    fn local_preview_uses_existing_track_and_clears_on_close() {
        tauri::async_runtime::block_on(async {
            let source=NativeVideoSource::new(VideoResolution{width:16,height:16},false);
            let track=LocalVideoTrack::create_video_track("preview-test",RtcVideoSource::Native(source.clone()));
            let preview=CameraPreview::start(&track);
            let frames=preview.frames.clone();
            for _ in 0..30 {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                let mut buffer=I420Buffer::new(16,16);
                let (y,u,v)=buffer.data_mut();y.fill(90);u.fill(128);v.fill(128);
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0,buffer));
                if frames.lock().unwrap().is_some(){break;}
            }
            let jpeg=frames.lock().unwrap().clone().expect("Local track must produce preview frames without a second capture");
            let image=image::load_from_memory(&jpeg).unwrap();
            assert_eq!((image.width(),image.height()),(16,16));
            drop(preview);
            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            assert!(frames.lock().unwrap().is_none(),"Late frames cannot restore a closed preview");
        });
    }
    #[test]
    fn cancelled_camera_decoder_cannot_restore_a_muted_frame() {
        tauri::async_runtime::block_on(async {
            let source=NativeVideoSource::new(VideoResolution{width:16,height:16},false);
            let track=LocalVideoTrack::create_video_track("mute-preview-test",RtcVideoSource::Native(source.clone()));
            let frames=Arc::new(Mutex::new(None));
            let stop=Arc::new(std::sync::atomic::AtomicBool::new(false));
            let cancelled=crate::viewer::spawn_camera_preview(track.rtc_track(),frames.clone(),stop);
            let frame=|| {
                let mut buffer=I420Buffer::new(16,16);
                let (y,u,v)=buffer.data_mut();y.fill(90);u.fill(128);v.fill(128);
                VideoFrame::new(VideoRotation::VideoRotation0,buffer)
            };
            for _ in 0..30 {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                source.capture_frame(&frame());
                if frames.lock().unwrap().is_some(){break;}
            }
            assert!(frames.lock().unwrap().is_some());
            cancelled.store(true,std::sync::atomic::Ordering::Relaxed);
            *frames.lock().unwrap()=None;
            source.capture_frame(&frame());
            tokio::time::sleep(std::time::Duration::from_millis(150)).await;
            assert!(frames.lock().unwrap().is_none());
        });
    }
}

#[cfg(target_os = "macos")]
impl CameraCapture {
    async fn start(local: &LocalParticipant, media:Arc<Mutex<CallMedia>>) -> Result<Self, String> {
        let helper = crate::find_camera_capture_helper()
            .ok_or("应用缺少摄像头采集器，请重新构建并安装完整应用")?;
        let capture_media=media.clone();
        let (mut child, mut stdout, width, height, first) =
            tokio::task::spawn_blocking(move || -> Result<_, String> {
                crate::capture_permissions::request(true)?;
                if capture_media.lock().unwrap().closed {return Err("通话会话已经关闭".into());}
                let mut child = Command::new(helper)
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped())
                    .spawn()
                    .map_err(|error| format!("启动摄像头采集器失败：{error}"))?;
                let mut stdout = child.stdout.take().ok_or("摄像头采集器没有输出")?;
                let stderr_reader = child.stderr.take().map(|stderr| {
                    std::thread::spawn(move || {
                        let mut last = String::new();
                        for line in std::io::BufReader::new(stderr)
                            .lines()
                            .map_while(Result::ok)
                        {
                            crate::publisher::log_to_file(&format!("[camera-capture] {line}"));
                            last = line;
                        }
                        last
                    })
                });
                let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
                std::thread::spawn(move || {
                    let frame = read_nv12_frame(&mut stdout);
                    let _ = ready_tx.send(frame.map(|(w, h, data)| (stdout, w, h, data)));
                });
                match ready_rx.recv_timeout(std::time::Duration::from_secs(60)) {
                    Ok(Ok((stdout, width, height, first))) => Ok((child, stdout, width, height, first)),
                    outcome => {
                        let error = outcome.ok().and_then(Result::err).unwrap_or(
                            "摄像头启动超时，请检查系统摄像头权限".into());
                        let _ = child.kill();
                        let _ = child.wait();
                        if let Some(reader) = stderr_reader {
                            if let Ok(message) = reader.join() {
                                if !message.is_empty() && !message.starts_with("camera-capture:") {
                                    return Err(format!("{error}；{message}"));
                                }
                            }
                        }
                        crate::publisher::log_to_file(&format!("[camera-capture] {error}"));
                        Err(error)
                    }
                }
            })
            .await
            .map_err(|error| format!("等待摄像头启动失败：{error}"))??;

        if media.lock().unwrap().closed {let _=child.kill();let _=child.wait();return Err("通话会话已经关闭".into());}
        let source = NativeVideoSource::new(VideoResolution { width, height }, false);
        let track = LocalVideoTrack::create_video_track(
            "call-camera",
            RtcVideoSource::Native(source.clone()),
        );
        let publication = match local
            .publish_track(
                LocalTrack::Video(track.clone()),
                TrackPublishOptions {
                    source: TrackSource::Camera,
                    video_codec: VideoCodec::H264,
                    simulcast: false,
                    video_encoding: Some(VideoEncoding {
                        max_bitrate: 900_000,
                        max_framerate: 24.0,
                    }),
                    ..Default::default()
                },
            )
            .await
        {
            Ok(publication) => publication,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("发布摄像头失败：{error}"));
            }
        };
        crate::publisher::log_to_file(&format!("[camera-publish] 已发布摄像头 {}，{}×{}", publication.sid(), width, height));
        if let Err(error) = capture_nv12(&source, width, height, &first) {
            let _ = child.kill();
            let _ = child.wait();
            let _ = local.unpublish_track(&publication.sid()).await;
            return Err(error);
        }

        let reader = match std::thread::Builder::new()
            .name("camera-capture".into())
            .spawn(move || {
                while let Ok((frame_width, frame_height, bytes)) = read_nv12_frame(&mut stdout) {
                    if frame_width != width || frame_height != height {
                        continue;
                    }
                    if capture_nv12(&source, width, height, &bytes).is_err() {
                        break;
                    }
                }
            }) {
            Ok(reader) => reader,
            Err(error) => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = local.unpublish_track(&publication.sid()).await;
                return Err(format!("启动摄像头读取线程失败：{error}"));
            }
        };

        Ok(Self {
            child,
            reader: Some(reader),
            publication,
            preview: CameraPreview::start(&track),
        })
    }
}

#[cfg(not(any(target_os = "macos", target_os = "windows")))]
impl CameraCapture {
    async fn start(_local: &LocalParticipant, _media:Arc<Mutex<CallMedia>>) -> Result<Self, String> {
        Err("当前桌面平台尚未接入摄像头采集器".into())
    }
}

#[cfg(target_os = "windows")]
impl CameraCapture {
    async fn start(local: &LocalParticipant, media: Arc<Mutex<CallMedia>>) -> Result<Self, String> {
        let capture = crate::windows_camera::Capture::start().await?;
        if media.lock().unwrap().closed { return Err("通话会话已经关闭".into()); }
        let track = LocalVideoTrack::create_video_track("call-camera", capture.source());
        let publication = local.publish_track(LocalTrack::Video(track.clone()), TrackPublishOptions {
            source: TrackSource::Camera,
            video_codec: VideoCodec::H264,
            simulcast: false,
            video_encoding: Some(VideoEncoding { max_bitrate: 900_000, max_framerate: 24.0 }),
            ..Default::default()
        }).await.map_err(|error| format!("发布摄像头失败：{error}"))?;
        Ok(Self { _native: capture, publication, preview: CameraPreview::start(&track) })
    }
}

#[cfg(target_os = "macos")]
fn read_nv12_frame(stdout: &mut impl Read) -> Result<(u32, u32, Vec<u8>), String> {
    let mut header = [0u8; 12];
    stdout
        .read_exact(&mut header)
        .map_err(|error| format!("读取摄像头帧头失败：{error}"))?;
    let width = u32::from_le_bytes(header[0..4].try_into().unwrap());
    let height = u32::from_le_bytes(header[4..8].try_into().unwrap());
    let length = u32::from_le_bytes(header[8..12].try_into().unwrap()) as usize;
    // NV12 的 UV 行数先取整，再乘行宽；不能把行宽乘进取整表达式。
    let expected = (width as usize).checked_mul(height as usize)
        .and_then(|y| (width as usize).checked_mul((height as usize + 1) / 2)
            .and_then(|uv| y.checked_add(uv)));
    if width == 0 || height == 0 || width % 2 != 0
        || Some(length) != expected || length > 16 * 1024 * 1024 {
        return Err("摄像头输出了无效帧".into());
    }
    let mut bytes = vec![0u8; length];
    stdout
        .read_exact(&mut bytes)
        .map_err(|error| format!("读取摄像头帧失败：{error}"))?;
    Ok((width, height, bytes))
}

#[cfg(all(test, target_os = "macos"))]
mod camera_frame_tests {
    use super::read_nv12_frame;
    use std::io::Cursor;

    fn packet(width: u32, height: u32, length: u32) -> Vec<u8> {
        [width.to_le_bytes(), height.to_le_bytes(), length.to_le_bytes()].concat()
    }

    #[test]
    fn reads_helper_vga_frame_and_leaves_next_frame_intact() {
        let length = 640 * 480 + 640 * 240;
        let mut bytes = packet(640, 480, length);
        bytes.resize(12 + length as usize, 37);
        bytes.extend(packet(2, 2, 6));
        bytes.extend([9; 6]);
        let mut stream = Cursor::new(bytes);
        let (width, height, frame) = read_nv12_frame(&mut stream).unwrap();
        assert_eq!((width, height, frame.len()), (640, 480, length as usize));
        assert!(frame.iter().all(|byte| *byte == 37));
        assert_eq!(read_nv12_frame(&mut stream).unwrap(), (2, 2, vec![9; 6]));
    }

    #[test]
    fn rejects_incorrect_length_and_truncated_payload() {
        assert!(read_nv12_frame(&mut Cursor::new(packet(640, 480, 461120))).is_err());
        assert!(read_nv12_frame(&mut Cursor::new(packet(640, 480, 460800))).is_err());
        assert!(read_nv12_frame(&mut Cursor::new(packet(0, 480, 0))).is_err());
        assert!(read_nv12_frame(&mut Cursor::new(packet(3, 2, 9))).is_err());
    }
}

#[cfg(target_os = "macos")]
fn capture_nv12(
    source: &NativeVideoSource,
    width: u32,
    height: u32,
    bytes: &[u8],
) -> Result<(), String> {
    if width == 0 || height == 0 {
        return Err("摄像头帧不完整".into());
    }
    let mut buffer = NV12Buffer::new(width, height);
    let (y, uv) = buffer.data_mut();
    let y_length = y.len();
    if bytes.len() != y_length + uv.len() {
        return Err("摄像头帧不完整".into());
    }
    y.copy_from_slice(&bytes[..y_length]);
    uv.copy_from_slice(&bytes[y_length..]);
    // The SDK's native preview sink rejects this NV12 buffer variant at its FFI boundary.
    // Normalize the shared capture track before sending it to preview and publication.
    let buffer = buffer.to_i420();
    // false means normal frame-rate/resolution adaptation, not a capture failure.
    source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
    Ok(())
}

#[cfg(target_os = "macos")]
impl Drop for CameraCapture {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}
