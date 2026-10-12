//! Independent microphone capture; never switches LiveKit's global ADM.
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::{
    native::NativeAudioSource, AudioSourceOptions, RtcAudioSource,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

pub struct Microphone {
    source: NativeAudioSource,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Microphone {
    pub fn source(&self) -> RtcAudioSource {
        RtcAudioSource::Native(self.source.clone())
    }

    pub fn start() -> Result<Self, String> {
        #[cfg(target_os = "macos")]
        crate::capture_permissions::request(false)?;
        let stop = Arc::new(AtomicBool::new(false));
        let signal = stop.clone();
        let (ready_tx, ready_rx) = std::sync::mpsc::sync_channel(1);
        let thread = std::thread::spawn(move || {
            let result = (|| -> Result<_, String> {
                let device = cpal::default_host()
                    .default_input_device()
                    .ok_or("没有可用麦克风")?;
                let config = device.default_input_config().map_err(|e| e.to_string())?;
                let rate = config.sample_rate().0;
                let channels = config.channels() as u32;
                let source = NativeAudioSource::new(
                    AudioSourceOptions {
                        echo_cancellation: false,
                        noise_suppression: false,
                        auto_gain_control: false,
                    },
                    rate,
                    channels,
                    50,
                );
                let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<i16>>(10);
                let mut pending = Vec::new();
                let frame_samples = (rate / 100 * channels) as usize;
                let mut deliver = move |samples: Vec<i16>| {
                    pending.extend(samples);
                    while pending.len() >= frame_samples {
                        let tail = pending.split_off(frame_samples);
                        let frame = std::mem::replace(&mut pending, tail);
                        let _ = tx.try_send(frame);
                    }
                };
                let on_error = |e| crate::publisher::log_to_file(&format!("麦克风采集失败：{e}"));
                let stream = match config.sample_format() {
                    cpal::SampleFormat::F32 => device.build_input_stream(
                        &config.into(),
                        move |data: &[f32], _| {
                            deliver(
                                data.iter()
                                    .map(|s| (s.clamp(-1.0, 1.0) * 32767.0) as i16)
                                    .collect(),
                            )
                        },
                        on_error,
                        None,
                    ),
                    cpal::SampleFormat::I16 => device.build_input_stream(
                        &config.into(),
                        move |data: &[i16], _| deliver(data.to_vec()),
                        on_error,
                        None,
                    ),
                    cpal::SampleFormat::U16 => device.build_input_stream(
                        &config.into(),
                        move |data: &[u16], _| {
                            deliver(data.iter().map(|s| (*s as i32 - 32768) as i16).collect())
                        },
                        on_error,
                        None,
                    ),
                    _ => return Err("不支持的麦克风采样格式".into()),
                }
                .map_err(|e| e.to_string())?;
                stream.play().map_err(|e| e.to_string())?;
                let rt = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .map_err(|e| e.to_string())?;
                let _ = ready_tx.send(Ok(source.clone()));
                rt.block_on(async {
                    while !signal.load(Ordering::Relaxed) {
                        tokio::select! {
                            samples = rx.recv() => {
                                let Some(data) = samples else { break };
                                let frame = AudioFrame { data: data.into(), sample_rate: rate,
                                    num_channels: channels, samples_per_channel: rate / 100 };
                                match tokio::time::timeout(Duration::from_millis(200), source.capture_frame(&frame)).await {
                                    Ok(Err(error)) => {
                                        crate::publisher::log_to_file(&format!("麦克风发送失败：{error}"));
                                        break;
                                    }
                                    _ => {}
                                }
                            }
                            _ = tokio::time::sleep(Duration::from_millis(100)) => {}
                        }
                    }
                });
                drop(stream);
                Ok(())
            })();
            if let Err(error) = result {
                let _ = ready_tx.send(Err(format!("打开麦克风失败：{error}")));
            }
        });
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(source)) => Ok(Self {
                source,
                stop,
                thread: Some(thread),
            }),
            outcome => {
                stop.store(true, Ordering::Relaxed);
                // A stalled device driver must not block the UI indefinitely.
                Err(outcome
                    .ok()
                    .and_then(Result::err)
                    .unwrap_or("麦克风启动超时".into()))
            }
        }
    }
}

impl Drop for Microphone {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
