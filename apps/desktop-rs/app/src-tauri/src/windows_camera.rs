//! Media Foundation camera capture stays off the UI thread.
use livekit::webrtc::{
    prelude::{I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation},
    video_source::native::NativeVideoSource,
};
use nokhwa::{
    pixel_format::RgbFormat,
    utils::{
        ApiBackend, CameraFormat, CameraIndex, FrameFormat, RequestedFormat, RequestedFormatType,
        Resolution,
    },
    Camera,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

pub struct Capture {
    stop: Arc<AtomicBool>,
    source: Option<NativeVideoSource>,
    pump: Option<tauri::async_runtime::JoinHandle<()>>,
}

impl Capture {
    pub async fn start() -> Result<Self, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let mut capture = Self {
            stop: stop.clone(),
            source: None,
            pump: None,
        };
        let (tx, mut rx) = tokio::sync::mpsc::channel(2);
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        std::thread::Builder::new().name("camera-media-foundation".into()).spawn(move || {
            struct StopOnExit(Arc<AtomicBool>);
            impl Drop for StopOnExit { fn drop(&mut self) { self.0.store(true, Ordering::Relaxed); } }
            let _exit = StopOnExit(stop.clone());
            let mut ready = Some(ready_tx);
            let result = (|| -> Result<(), String> {
                let request = RequestedFormat::new::<RgbFormat>(RequestedFormatType::Closest(
                    CameraFormat::new(Resolution::new(640, 480), FrameFormat::MJPEG, 24)));
                let mut camera = Camera::with_backend(CameraIndex::Index(0), request, ApiBackend::MediaFoundation)
                    .or_else(|_| Camera::with_backend(CameraIndex::Index(0),
                        RequestedFormat::new::<RgbFormat>(RequestedFormatType::AbsoluteHighestFrameRate), ApiBackend::MediaFoundation))
                    .map_err(|error| format!("打开摄像头失败：{error}。请检查摄像头是否被占用，以及系统设置中的摄像头访问权限"))?;
                camera.open_stream().map_err(|error| format!("启动摄像头失败：{error}"))?;
                while !stop.load(Ordering::Relaxed) && !tx.is_closed() {
                    let frame = camera.frame().map_err(|error| format!("读取摄像头失败：{error}"))?;
                    // Use the existing Rust JPEG decoder; avoid a second native libjpeg inside WebRTC.
                    let rgb = if frame.source_frame_format() == FrameFormat::MJPEG {
                        image::load_from_memory_with_format(frame.buffer(), image::ImageFormat::Jpeg)
                            .map_err(|error| format!("解码摄像头失败：{error}"))?.to_rgb8()
                    } else {
                        frame.decode_image::<RgbFormat>().map_err(|error| format!("解码摄像头失败：{error}"))?
                    };
                    let (width, height) = rgb.dimensions();
                    if width == 0 || height == 0 || width > 4096 || height > 4096 { return Err("摄像头图像尺寸无效".into()); }
                    if let Some(ready) = ready.take() { let _ = ready.send(Ok((width, height))); }
                    let _ = tx.try_send((width, height, rgb.into_raw()));
                }
                let _ = camera.stop_stream();
                Ok(())
            })();
            if let Err(error) = result {
                if let Some(ready) = ready.take() { let _ = ready.send(Err(error.clone())); }
                crate::publisher::log_to_file(&error);
            }
        }).map_err(|error| format!("启动摄像头采集失败：{error}"))?;
        let (width, height) = tokio::time::timeout(std::time::Duration::from_secs(15), ready_rx)
            .await
            .map_err(|_| "摄像头启动超时，请检查系统摄像头权限".to_string())?
            .map_err(|_| "摄像头采集线程已退出".to_string())??;
        let source = NativeVideoSource::new(VideoResolution { width, height }, false);
        capture.source = Some(source.clone());
        capture.pump = Some(tauri::async_runtime::spawn(async move {
            while let Some((width, height, rgb)) = rx.recv().await {
                let rgba: Vec<u8> = rgb
                    .chunks_exact(3)
                    .flat_map(|p| [p[0], p[1], p[2], 255])
                    .collect();
                let mut buffer = I420Buffer::new(width, height);
                let (sy, su, sv) = buffer.strides();
                let (y, u, v) = buffer.data_mut();
                livekit::webrtc::native::yuv_helper::abgr_to_i420(
                    &rgba,
                    width * 4,
                    y,
                    sy,
                    u,
                    su,
                    v,
                    sv,
                    width as i32,
                    height as i32,
                );
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
            }
        }));
        Ok(capture)
    }

    pub fn source(&self) -> RtcVideoSource {
        RtcVideoSource::Native(self.source.as_ref().unwrap().clone())
    }

    pub fn stop_flag(&self) -> Arc<AtomicBool> { self.stop.clone() }
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(pump) = self.pump.take() {
            pump.abort();
        }
    }
}
