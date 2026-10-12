//! Windows system audio, captured separately from the microphone track.
use livekit::options::TrackPublishOptions;
use livekit::prelude::*;
use livekit::webrtc::{
    audio_frame::AudioFrame,
    audio_source::{native::NativeAudioSource, AudioSourceOptions, RtcAudioSource},
};
use std::collections::VecDeque;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

pub struct SystemAudio {
    stop: Arc<AtomicBool>,
    pump: Option<tauri::async_runtime::JoinHandle<()>>,
}

impl SystemAudio {
    pub async fn start(room: &Room, errors: Arc<Mutex<Option<String>>>) -> Result<Self, String> {
        let stop = Arc::new(AtomicBool::new(false));
        let mut capture = Self {
            stop: stop.clone(),
            pump: None,
        };
        let (tx, mut rx) = tokio::sync::mpsc::channel(10);
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel();
        let thread_errors = errors.clone();
        std::thread::Builder::new()
            .name("system-audio-wasapi".into())
            .spawn(move || {
                let mut ready = Some(ready_tx);
                if let Err(error) = capture_loop(stop, tx, &mut ready) {
                    let message = format!("系统音频采集失败：{error}");
                    if let Some(ready) = ready.take() {
                        let _ = ready.send(Err(message.clone()));
                    }
                    crate::publisher::log_to_file(&message);
                    *thread_errors.lock().unwrap() = Some(message);
                }
            })
            .map_err(|error| format!("启动系统音频采集失败：{error}"))?;
        tokio::time::timeout(std::time::Duration::from_secs(10), ready_rx)
            .await
            .map_err(|_| "系统音频采集启动超时".to_string())?
            .map_err(|_| "系统音频采集线程已退出".to_string())??;
        let source = NativeAudioSource::new(
            AudioSourceOptions {
                echo_cancellation: false,
                noise_suppression: false,
                auto_gain_control: false,
            },
            48_000,
            2,
            50,
        );
        let track = LocalAudioTrack::create_audio_track(
            "system-audio",
            RtcAudioSource::Native(source.clone()),
        );
        room.local_participant()
            .publish_track(
                LocalTrack::Audio(track),
                TrackPublishOptions {
                    source: TrackSource::ScreenshareAudio,
                    ..Default::default()
                },
            )
            .await
            .map_err(|error| format!("发布系统音频失败：{error}"))?;
        capture.pump = Some(tauri::async_runtime::spawn(async move {
            while let Some(pcm) = rx.recv().await {
                let frame = AudioFrame {
                    data: std::borrow::Cow::Owned(pcm),
                    sample_rate: 48_000,
                    num_channels: 2,
                    samples_per_channel: 480,
                };
                if let Err(error) = source.capture_frame(&frame).await {
                    *errors.lock().unwrap() = Some(format!("系统音频发送失败：{error}"));
                    break;
                }
            }
        }));
        Ok(capture)
    }
}

fn capture_loop(
    stop: Arc<AtomicBool>,
    tx: tokio::sync::mpsc::Sender<Vec<i16>>,
    ready: &mut Option<tokio::sync::oneshot::Sender<Result<(), String>>>,
) -> Result<(), Box<dyn std::error::Error>> {
    use wasapi::*;
    initialize_mta().ok()?;
    struct Com;
    impl Drop for Com {
        fn drop(&mut self) {
            wasapi::deinitialize();
        }
    }
    let _com = Com;
    // Exclude RemoteScreen's own playback so the remote microphone does not feed back.
    // Process loopback requires Windows build 20348+. Older Windows uses endpoint loopback.
    let mut audio = match AudioClient::new_application_loopback_client(std::process::id(), false) {
        Ok(audio) => audio,
        Err(error) => {
            crate::publisher::log_to_file(&format!(
                "[wasapi] 使用输出设备回环（系统不支持进程排除）：{error}"
            ));
            DeviceEnumerator::new()?
                .get_default_device(&Direction::Render)?
                .get_iaudioclient()?
        }
    };
    let format = WaveFormat::new(16, 16, &SampleType::Int, 48_000, 2, None);
    audio.initialize_client(
        &format,
        &Direction::Capture,
        &StreamMode::PollingShared {
            autoconvert: true,
            buffer_duration_hns: 300_000,
        },
    )?;
    let reader = audio.get_audiocaptureclient()?;
    audio.start_stream()?;
    if let Some(ready) = ready.take() {
        let _ = ready.send(Ok(()));
    }
    let mut bytes = VecDeque::new();
    let result = (|| -> Result<(), Box<dyn std::error::Error>> {
        while !stop.load(Ordering::Relaxed) && !tx.is_closed() {
            reader.read_from_device_to_deque(&mut bytes)?;
            // 480 stereo samples = 10 ms. Never retain an unbounded queue.
            while bytes.len() >= 1920 {
                let data: Vec<u8> = bytes.drain(..1920).collect();
                let pcm = data
                    .chunks_exact(2)
                    .map(|b| i16::from_le_bytes([b[0], b[1]]))
                    .collect();
                let _ = tx.try_send(pcm);
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        Ok(())
    })();
    let _ = audio.stop_stream();
    result
}

impl Drop for SystemAudio {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(pump) = self.pump.take() {
            pump.abort();
        }
    }
}
