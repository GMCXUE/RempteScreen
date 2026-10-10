//! ScreenCaptureKit helper → 48 kHz mono PCM → LiveKit screen-share audio.
//! The helper and the PCM reader live exactly as long as the publishing session.
use livekit::options::TrackPublishOptions;
use livekit::prelude::*;
use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::{
    native::NativeAudioSource, AudioSourceOptions, RtcAudioSource,
};
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
        let mut session = Self {
            child,
            reader: None,
            pump: None,
        };
        std::thread::spawn(move || {
            for line in std::io::BufReader::new(stderr)
                .lines()
                .map_while(Result::ok)
            {
                crate::publisher::log_to_file(&format!("[audio-capture] {line}"));
            }
        });

        let source = NativeAudioSource::new(
            AudioSourceOptions {
                echo_cancellation: false,
                noise_suppression: false,
                auto_gain_control: false,
            },
            SAMPLE_RATE,
            CHANNELS,
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
            .map_err(|e| format!("发布系统音频失败：{e}"))?;

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
                    crate::publisher::log_to_file(&format!(
                        "[system-audio] 已发送 {count} 帧，最近 5 秒峰值 {peak}"
                    ));
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
    bytes
        .chunks_exact(2)
        .map(|s| i16::from_le_bytes([s[0], s[1]]))
        .collect()
}

fn audio_frame(pcm: Vec<i16>) -> AudioFrame<'static> {
    AudioFrame {
        data: pcm.into(),
        sample_rate: SAMPLE_RATE,
        num_channels: CHANNELS,
        samples_per_channel: SAMPLES_PER_FRAME as u32,
    }
}

impl Drop for SystemAudio {
    fn drop(&mut self) {
        if let Some(pump) = self.pump.take() {
            pump.abort();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
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
        assert_eq!(
            frame.data.len(),
            (frame.samples_per_channel * frame.num_channels) as usize
        );
        assert_eq!(frame.samples_per_channel * 100, frame.sample_rate);
        let runtime = tokio::runtime::Runtime::new().unwrap();
        runtime.block_on(async {
            let source =
                NativeAudioSource::new(AudioSourceOptions::default(), SAMPLE_RATE, CHANNELS, 0);
            source
                .capture_frame(&frame)
                .await
                .expect("SDK must accept the helper's channel count and frame size");
        });
    }

    /// Run against an isolated LiveKit --dev server. No screen or microphone access.
    /// RS_AUDIO_TEST_URL=ws://127.0.0.1:17880 cargo test audio_roundtrip -- --ignored --nocapture
    #[test]
    #[ignore = "requires a local LiveKit dev server"]
    fn audio_roundtrip() {
        use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
        use futures_util::StreamExt;
        use hmac::{Hmac, Mac};
        use livekit::webrtc::audio_stream::native::NativeAudioStream;
        use sha2::Sha256;
        use std::time::{Duration, SystemTime, UNIX_EPOCH};

        let url = std::env::var("RS_AUDIO_TEST_URL")
            .expect("set RS_AUDIO_TEST_URL to a local dev server");
        assert!(
            url.starts_with("ws://127.0.0.1:"),
            "test must not connect to production"
        );
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let room_name = format!("audio-regression-{}", now.as_nanos());
        let token = |identity: &str| {
            let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
            let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&serde_json::json!({
                "iss": "devkey", "sub": identity, "nbf": now.as_secs() - 5, "exp": now.as_secs() + 120,
                "video": { "roomJoin": true, "room": room_name, "canPublish": true, "canSubscribe": true }
            })).unwrap());
            let unsigned = format!("{header}.{payload}");
            let mut mac = Hmac::<Sha256>::new_from_slice(b"secret").unwrap();
            mac.update(unsigned.as_bytes());
            format!(
                "{unsigned}.{}",
                URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
            )
        };
        tokio::runtime::Runtime::new().unwrap().block_on(async {
            let (subscriber, mut events) =
                Room::connect(&url, &token("receiver"), Default::default())
                    .await
                    .unwrap();
            let (publisher, _) = Room::connect(&url, &token("sender"), Default::default())
                .await
                .unwrap();
            let source =
                NativeAudioSource::new(AudioSourceOptions::default(), SAMPLE_RATE, CHANNELS, 50);
            let track = LocalAudioTrack::create_audio_track(
                "system-audio",
                RtcAudioSource::Native(source.clone()),
            );
            publisher
                .local_participant()
                .publish_track(
                    LocalTrack::Audio(track),
                    TrackPublishOptions {
                        source: TrackSource::ScreenshareAudio,
                        ..Default::default()
                    },
                )
                .await
                .unwrap();
            let track = tokio::time::timeout(Duration::from_secs(15), async {
                loop {
                    if let Some(RoomEvent::TrackSubscribed {
                        track: RemoteTrack::Audio(track),
                        ..
                    }) = events.recv().await
                    {
                        break track;
                    }
                }
            })
            .await
            .expect("audio subscription timed out");
            let mut stream =
                NativeAudioStream::new(track.rtc_track(), SAMPLE_RATE as i32, CHANNELS as i32);
            let sending = tokio::spawn(async move {
                let mut tick = tokio::time::interval(Duration::from_millis(10));
                tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                for frame in 0..500 {
                    tick.tick().await;
                    let pcm = (0..SAMPLES_PER_FRAME)
                        .map(|i| {
                            let t = (frame * SAMPLES_PER_FRAME + i) as f64 / SAMPLE_RATE as f64;
                            (8000.0 * (t * 440.0 * std::f64::consts::TAU).sin()) as i16
                        })
                        .collect();
                    source.capture_frame(&audio_frame(pcm)).await.unwrap();
                }
            });
            let received = tokio::time::timeout(Duration::from_secs(10), async {
                let mut samples = Vec::new();
                let mut settling = 50;
                while let Some(frame) = stream.next().await {
                    if !frame.data.iter().any(|s| i32::from(*s).abs() > 500) {
                        continue;
                    }
                    if settling > 0 {
                        settling -= 1;
                        continue;
                    }
                    samples.extend_from_slice(&frame.data);
                    if samples.len() >= SAMPLE_RATE as usize / 2 {
                        break;
                    }
                }
                samples
            })
            .await;
            sending.abort();
            publisher.close().await.unwrap();
            subscriber.close().await.unwrap();
            let samples = received.expect("no non-silent PCM received");
            assert!(samples.len() >= SAMPLE_RATE as usize / 2);
            let crossings = samples.windows(2).filter(|w| w[0] <= 0 && w[1] > 0).count();
            let hz = crossings as f64 * SAMPLE_RATE as f64 / samples.len() as f64;
            println!(
                "Received {} PCM samples; measured tone {hz:.1} Hz",
                samples.len()
            );
            assert!(
                (hz - 440.0).abs() < 20.0,
                "received audio must match the transmitted tone"
            );
        });
    }
}
