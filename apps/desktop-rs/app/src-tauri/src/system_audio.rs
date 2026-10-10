//! ScreenCaptureKit helper → 48 kHz mono PCM → LiveKit screen-share audio.
//! The helper and the PCM reader live exactly as long as the publishing session.
use livekit::options::TrackPublishOptions;
use livekit::prelude::*;
use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::{native::NativeAudioSource, AudioSourceOptions, RtcAudioSource};
use std::io::{BufRead, Read};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};

const SAMPLE_RATE: u32 = 48_000;
const CHANNELS: u32 = 1;
const SAMPLES_PER_FRAME: usize = 480; // 10 ms, matching the Swift helper's mono output.

pub struct SystemAudio {
    child: Child,
    reader: Option<std::thread::JoinHandle<()>>,
    pump: Option<tauri::async_runtime::JoinHandle<()>>,
}

impl SystemAudio {
    pub async fn start(room: &Room, errors: Arc<Mutex<Option<String>>>) -> Result<Self, String> {
        let helper = crate::find_audio_capture_helper()
            .ok_or("应用缺少系统音频采集器，请重新构建并安装完整应用")?;
        let mut child = Command::new(helper)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("启动系统音频采集器失败：{e}"))?;
        let mut stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let mut session = Self { child, reader: None, pump: None };
        std::thread::spawn(move || {
            for line in std::io::BufReader::new(stderr).lines().map_while(Result::ok) {
                crate::publisher::log_to_file(&format!("[audio-capture] {line}"));
            }
        });

        let source = NativeAudioSource::new(
            AudioSourceOptions { echo_cancellation: false, noise_suppression: false, auto_gain_control: false },
            SAMPLE_RATE, CHANNELS, 50,
        );
        let track = LocalAudioTrack::create_audio_track("system-audio", RtcAudioSource::Native(source.clone()));
        room.local_participant().publish_track(LocalTrack::Audio(track), TrackPublishOptions {
            source: TrackSource::ScreenshareAudio,
            ..Default::default()
        }).await.map_err(|e| format!("发布系统音频失败：{e}"))?;

        // Bounded buffering: a stalled network must not accumulate seconds of audio delay.
        let (tx, mut rx) = tokio::sync::mpsc::channel(10);
        session.reader = Some(std::thread::spawn(move || {
            let mut bytes = [0u8; SAMPLES_PER_FRAME * 2];
            while stdout.read_exact(&mut bytes).is_ok() {
                let pcm = decode_pcm(&bytes);
                match tx.try_send(pcm) {
                    Ok(()) | Err(tokio::sync::mpsc::error::TrySendError::Full(_)) => {}
                    Err(tokio::sync::mpsc::error::TrySendError::Closed(_)) => break,
                }
            }
        }));
        session.pump = Some(tauri::async_runtime::spawn(async move {
            let mut count = 0u64;
            let mut peak = 0i32;
            while let Some(pcm) = rx.recv().await {
                peak = peak.max(pcm.iter().map(|&s| i32::from(s).abs()).max().unwrap_or(0));
                if let Err(e) = source.capture_frame(&audio_frame(pcm)).await {
                    *errors.lock().unwrap() = Some(format!("系统音频发送失败：{e}"));
                    return;
                }
                count += 1;
                if count % 500 == 0 {
                    crate::publisher::log_to_file(&format!("[system-audio] 已发送 {count} 帧，最近 5 秒峰值 {peak}"));
                    peak = 0;
                }
            }
            let message = "系统音频采集已中断，请检查屏幕录制权限后重新投送";
            crate::publisher::log_to_file(message);
            *errors.lock().unwrap() = Some(message.into());
        }));
        Ok(session)
    }
}

fn decode_pcm(bytes: &[u8; SAMPLES_PER_FRAME * 2]) -> Vec<i16> {
    bytes.chunks_exact(2).map(|s| i16::from_le_bytes([s[0], s[1]])).collect()
}

fn audio_frame(pcm: Vec<i16>) -> AudioFrame<'static> {
    AudioFrame { data: pcm.into(), sample_rate: SAMPLE_RATE, num_channels: CHANNELS, samples_per_channel: SAMPLES_PER_FRAME as u32 }
}

impl Drop for SystemAudio {
    fn drop(&mut self) {
        if let Some(pump) = self.pump.take() { pump.abort(); }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() { let _ = reader.join(); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_pcm_matches_livekit_frame_shape() {
        let mut bytes = [0u8; SAMPLES_PER_FRAME * 2];
        bytes[..4].copy_from_slice(&[0x00, 0x80, 0xff, 0x7f]);
        let frame = audio_frame(decode_pcm(&bytes));
        assert_eq!(&frame.data[..2], &[i16::MIN, i16::MAX]);
        assert_eq!(frame.data.len(), (frame.samples_per_channel * frame.num_channels) as usize);
        assert_eq!(frame.samples_per_channel * 100, frame.sample_rate);
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let source = NativeAudioSource::new(AudioSourceOptions::default(), SAMPLE_RATE, CHANNELS, 0);
            source.capture_frame(&frame).await.expect("SDK must accept the helper's channel count and frame size");
        });
    }
}
