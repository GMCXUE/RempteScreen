//! NativeAudioStream → buffered CPAL output. PCM and device frames stay aligned;
//! volume is applied once and silence uses the output sample format's midpoint.

use crate::audio_buffer::{self, BufferedPlayout, PacketError, StereoFrame};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use livekit::prelude::RemoteAudioTrack;

use rtrb::{Consumer, RingBuffer};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio_stream::StreamExt;

pub type Volume = Arc<AtomicU8>;

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

pub fn start(track: &RemoteAudioTrack, volume: Volume) -> Result<PlayoutHandle, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let rtc_track = track.rtc_track();
    let sid = track.sid().to_string();
    let stop_thread = stop.clone();
    // CPAL streams are not Send on every platform; create/use/drop on this thread.
    let thread = std::thread::Builder::new()
        .name("audio-playout".into())
        .spawn(move || {
            let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
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
                let channels = config.channels() as usize;
                if sample_rate == 0 || channels == 0 {
                    crate::publisher::log_to_file("音频播放：输出配置无效");
                    return;
                }
                // WebRTC remixes mono/stereo. Windows endpoints may be surround;
                // request at most stereo, then map it to physical front L/R.
                let decoded_channels = channels.min(2);
                crate::publisher::log_to_file(&format!(
                    "音频输出: {} @ {}Hz x {channels} ({:?}), 解码声道={decoded_channels}, 预缓冲=30ms",
                    device.name().unwrap_or_default(), sample_rate, config.sample_format()
                ));
                let (mut producer, consumer) = RingBuffer::<StereoFrame>::new(sample_rate as usize / 5);
                let mut audio_stream = crate::media_route::AudioStream::new(
                    &sid, rtc_track, sample_rate as i32, decoded_channels as i32
                );
                let underruns = Arc::new(AtomicU64::new(0));
                let stream_config: cpal::StreamConfig = config.clone().into();
                macro_rules! output_stream {
                    ($sample:ty) => {
                        build_output::<$sample>(&device, &stream_config, consumer,
                            volume, underruns.clone())
                    };
                }
                let stream = match config.sample_format() {
                    cpal::SampleFormat::F32 => output_stream!(f32),
                    cpal::SampleFormat::F64 => output_stream!(f64),
                    cpal::SampleFormat::I8 => output_stream!(i8),
                    cpal::SampleFormat::I16 => output_stream!(i16),
                    cpal::SampleFormat::I32 => output_stream!(i32),
                    cpal::SampleFormat::I64 => output_stream!(i64),
                    cpal::SampleFormat::U8 => output_stream!(u8),
                    cpal::SampleFormat::U16 => output_stream!(u16),
                    cpal::SampleFormat::U32 => output_stream!(u32),
                    cpal::SampleFormat::U64 => output_stream!(u64),
                    other => {
                        crate::publisher::log_to_file(&format!("不支持的输出采样格式: {other:?}"));
                        return;
                    }
                };
                let stream = match stream {
                    Ok(stream) => stream,
                    Err(error) => {
                        crate::publisher::log_to_file(&format!("音频播放：创建输出流失败: {error}"));
                        return;
                    }
                };
                if let Err(error) = stream.play() {
                    crate::publisher::log_to_file(&format!("音频播放：启动播放失败: {error}"));
                    return;
                }

                let mut overflows = 0u64;
                let mut invalid_frames = 0u64;
                let mut near_full_scale = 0u64;
                let mut received_samples = 0u64;
                let mut last_report = Instant::now();
                let mut stop_tick = tokio::time::interval(Duration::from_millis(100));
                stop_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    // Continuous frames must not starve the stop check.
                    if stop_thread.load(Ordering::Relaxed) { break; }
                    tokio::select! {
                        frame = audio_stream.next() => {
                            let Some(frame) = frame else { break };
                            if frame.sample_rate != sample_rate || frame.num_channels as usize != decoded_channels
                                || frame.data.len() != frame.samples_per_channel as usize * decoded_channels {
                                invalid_frames += 1;
                            } else {
                                received_samples += frame.data.len() as u64;
                                near_full_scale += frame.data.iter().filter(|s| s.unsigned_abs() >= 32700).count() as u64;
                                match audio_buffer::push_packet(&mut producer, &frame.data, decoded_channels) {
                                    Ok(()) => {},
                                    Err(PacketError::Full) => overflows += 1,
                                    Err(PacketError::InvalidChannels) => invalid_frames += 1,
                                }
                            }
                        }
                        _ = stop_tick.tick() => {}
                    }
                    if last_report.elapsed() >= Duration::from_secs(10) {
                        log_stats(&underruns, overflows, invalid_frames, near_full_scale, received_samples);
                        last_report = Instant::now();
                    }
                }
                log_stats(&underruns, overflows, invalid_frames, near_full_scale, received_samples);
            });
        })
        .map_err(|e| format!("启动音频播放线程失败: {e}"))?;
    Ok(PlayoutHandle {
        stop,
        thread: Some(thread),
    })
}

fn build_output<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device,
    config: &cpal::StreamConfig,
    consumer: Consumer<StereoFrame>,
    volume: Volume,
    underruns: Arc<AtomicU64>,
) -> Result<cpal::Stream, cpal::BuildStreamError> {
    let channels = config.channels as usize;
    let mut playout = BufferedPlayout::new(consumer, config.sample_rate.0);
    device.build_output_stream(
        config,
        move |data: &mut [T], _| {
            let volume = volume.load(Ordering::Relaxed);
            write_output(data, channels, &mut playout, volume);
            underruns.store(playout.underruns, Ordering::Relaxed);
        },
        |error| crate::publisher::log_to_file(&format!("音频输出流错误: {error}")),
        None,
    )
}

fn write_output<T: cpal::SizedSample + cpal::FromSample<f32>>(
    data: &mut [T],
    channels: usize,
    playout: &mut BufferedPlayout,
    volume: u8,
) {
    let mut frames = data.chunks_exact_mut(channels);
    for output_frame in &mut frames {
        let frame = playout.next_frame(volume);
        for (channel, out) in output_frame.iter_mut().enumerate() {
            *out = T::from_sample(audio_buffer::output_channel(frame, channel, channels));
        }
    }
    // CPAL promises whole frames; initialize any unexpected trailing data too.
    frames.into_remainder().fill(T::from_sample(0.0));
}

fn log_stats(
    underruns: &AtomicU64,
    overflows: u64,
    invalid: u64,
    near_full_scale: u64,
    samples: u64,
) {
    crate::publisher::log_to_file(&format!(
        "音频播放统计: 欠载={}, 整帧溢出={overflows}, 格式异常={invalid}, 近满幅采样={near_full_scale}/{samples}",
        underruns.load(Ordering::Relaxed)
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsigned_output_silence_uses_midpoint_including_trailing_sample() {
        let (_producer, consumer) = RingBuffer::new(200);
        let mut playout = BufferedPlayout::new(consumer, 1000);
        let mut output = [0u16; 17];
        write_output(&mut output, 8, &mut playout, 100);
        assert_eq!(output, [32768u16; 17]);
    }

    #[test]
    fn physical_surround_and_integer_conversion_do_not_duplicate_or_amplify() {
        let (mut producer, consumer) = RingBuffer::new(200);
        let input: Vec<i16> = (0..100).flat_map(|_| [16384, -8192]).collect();
        audio_buffer::push_packet(&mut producer, &input, 2).unwrap();
        let mut playout = BufferedPlayout::new(consumer, 1000);
        let mut warmup = [0f32; 8 * 10];
        write_output(&mut warmup, 8, &mut playout, 100);
        let mut output = [0i32; 8 * 10];
        write_output(&mut output, 8, &mut playout, 100);
        for frame in output.chunks_exact(8) {
            assert_eq!(frame, &[1073741824, -536870912, 0, 0, 0, 0, 0, 0]);
        }
    }
}
