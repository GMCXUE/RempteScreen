//! 观看端音频自管播放：NativeAudioStream 拉取远端音频帧 → cpal 输出（带音量增益）。
//! 不用 SDK 的 ADM 扬声器（无法控制音量），改由我们自己消费帧：
//! 输出走标准 CoreAudio/WASAPI 默认输出设备 —— 系统音量和应用内音量都生效。
//!
//! 线程模型：cpal::Stream 不是 Send，整个播放（拉帧 + 输出）跑在专用 std 线程里，
//! 外部只持有轻量的可控句柄（stop + JoinHandle），可安全跨 async 边界传递。

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use livekit::prelude::RemoteAudioTrack;
use livekit::webrtc::audio_stream::native::NativeAudioStream;
use rtrb::RingBuffer;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio_stream::StreamExt;

/// 音量（0-100），由 UI 滑块设置，cpal 回调实时读取。
pub type Volume = Arc<AtomicU8>;

/// 可跨线程传递的播放句柄：drop 时停止播放。
pub struct PlayoutHandle {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl PlayoutHandle {
    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

impl Drop for PlayoutHandle {
    fn drop(&mut self) {
        self.stop();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// 挂到远端音频轨上开始播放。
pub fn start(track: &RemoteAudioTrack, volume: Volume) -> Result<PlayoutHandle, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let rtc_track = track.rtc_track();
    let stop_thread = stop.clone();

    let thread = std::thread::Builder::new()
        .name("audio-playout".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(_) => return,
            };
            rt.block_on(async move {
                let host = cpal::default_host();
                let Some(device) = host.default_output_device() else {
                    crate::publisher::log_to_file("音频播放：未找到输出设备");
                    return;
                };
                let Ok(config) = device.default_output_config() else {
                    crate::publisher::log_to_file("音频播放：读取输出配置失败");
                    return;
                };
                let sample_rate = config.sample_rate().0;
                let channels = config.channels() as u32;
                crate::publisher::log_to_file(&format!(
                    "音频输出: {} @ {}Hz x {channels} ({:?})",
                    device.name().unwrap_or_default(),
                    sample_rate,
                    config.sample_format()
                ));

                // 环形缓冲 200ms；SDK 按请求的速率/声道重采样，1:1 出队
                let (mut producer, mut consumer) =
                    RingBuffer::<i16>::new(sample_rate as usize / 5 * channels as usize);
                let mut audio_stream =
                    NativeAudioStream::new(rtc_track, sample_rate as i32, channels as i32);

                let stream = match config.sample_format() {
                    cpal::SampleFormat::F32 => device
                        .build_output_stream(
                            &config.into(),
                            move |data: &mut [f32], _| {
                                let gain = f32::from(volume.load(Ordering::Relaxed)) / 100.0;
                                for out in data.iter_mut() {
                                    let s = consumer.pop().unwrap_or(0);
                                    *out = f32::from(s) / 32768.0 * gain;
                                }
                            },
                            |err| {
                                crate::publisher::log_to_file(&format!("音频输出流错误: {err}"));
                            },
                            None,
                        )
                        .ok(),
                    cpal::SampleFormat::I16 => device
                        .build_output_stream(
                            &config.into(),
                            move |data: &mut [i16], _| {
                                let gain = f32::from(volume.load(Ordering::Relaxed)) / 100.0;
                                for out in data.iter_mut() {
                                    let s = consumer.pop().unwrap_or(0);
                                    *out = (f32::from(s) * gain) as i16;
                                }
                            },
                            |err| {
                                crate::publisher::log_to_file(&format!("音频输出流错误: {err}"));
                            },
                            None,
                        )
                        .ok(),
                    other => {
                        crate::publisher::log_to_file(&format!(
                            "不支持的输出采样格式: {other:?}"
                        ));
                        return;
                    }
                };
                let Some(stream) = stream else {
                    crate::publisher::log_to_file("音频播放：创建输出流失败");
                    return;
                };
                if stream.play().is_err() {
                    crate::publisher::log_to_file("音频播放：启动播放失败");
                    return;
                }

                // 拉帧 → 环形缓冲；停止信号到达即退出
                loop {
                    tokio::select! {
                        frame = audio_stream.next() => {
                            let Some(frame) = frame else { return };
                            for s in frame.data.iter() {
                                let mut spins = 0u32;
                                while producer.push(*s).is_err() {
                                    spins += 1;
                                    if spins > 20 || stop_thread.load(Ordering::Relaxed) {
                                        break;
                                    }
                                    tokio::time::sleep(Duration::from_millis(1)).await;
                                }
                            }
                        }
                        _ = tokio::time::sleep(Duration::from_millis(200)) => {
                            if stop_thread.load(Ordering::Relaxed) {
                                return;
                            }
                        }
                    }
                }
            });
        })
        .map_err(|e| format!("启动音频播放线程失败: {e}"))?;

    Ok(PlayoutHandle {
        stop,
        thread: Some(thread),
    })
}
