use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::StreamExt;
use hmac::{Hmac, Mac};
use livekit::options::TrackPublishOptions;
use livekit::webrtc::prelude::{
    I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation,
};
use livekit::webrtc::{
    audio_frame::AudioFrame,
    audio_source::{native::NativeAudioSource, AudioSourceOptions, RtcAudioSource},
    stats::RtcStats,
};
use livekit::webrtc::{
    video_source::native::NativeVideoSource, video_stream::native::NativeVideoStream,
};
use sha2::Sha256;
use std::sync::atomic::AtomicU64;
use std::{
    borrow::Cow,
    sync::atomic::AtomicU8,
    time::{SystemTime, UNIX_EPOCH},
};

async fn bytes(track: &RemoteAudioTrack) -> u64 {
    track
        .get_stats()
        .await
        .unwrap()
        .into_iter()
        .filter_map(|s| match s {
            RtcStats::InboundRtp(r) => Some(r.inbound.bytes_received),
            _ => None,
        })
        .sum()
}
async fn window(
    mic: &RemoteAudioTrack,
    screen: &RemoteAudioTrack,
    frames: &AtomicU64,
) -> (u64, u64) {
    // LiveKit drains jitter buffers with one second of Opus silence when muted.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let before = (bytes(mic).await, bytes(screen).await);
    let first_frame = frames.load(Ordering::Relaxed);
    let started = std::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(2)).await;
    let fps =
        (frames.load(Ordering::Relaxed) - first_frame) as f64 / started.elapsed().as_secs_f64();
    println!("unmodified video received fps: {fps:.1}");
    assert!(fps >= 27.0);
    (bytes(mic).await - before.0, bytes(screen).await - before.1)
}
#[test]
#[ignore = "requires an isolated local LiveKit dev server"]
fn muted_audio_stops_server_forwarding_and_resumes_same_track() {
    tauri::async_runtime::block_on(async {
        let url = std::env::var("RS_AUDIO_RECEPTION_TEST_URL").unwrap();
        assert!(url.starts_with("ws://127.0.0.1:"));
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
        let room_name = format!("audio-reception-{}", now.as_nanos());
        let token =
            |identity: &str| {
                let header = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
                let payload = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&serde_json::json!({
                "iss":"devkey","sub":identity,"nbf":now.as_secs()-5,"exp":now.as_secs()+180,
                "video":{"roomJoin":true,"room":room_name,"canPublish":true,"canSubscribe":true}
            })).unwrap());
                let unsigned = format!("{header}.{payload}");
                let mut mac = Hmac::<Sha256>::new_from_slice(b"secret").unwrap();
                mac.update(unsigned.as_bytes());
                format!(
                    "{unsigned}.{}",
                    URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
                )
            };
        let (receiver, mut events) =
            Room::connect(&url, &token("receiver"), crate::call::call_room_options())
                .await
                .unwrap();
        let (sender, _) = Room::connect(&url, &token("sender"), crate::call::call_room_options())
            .await
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        // Start muted before publication, to cover tracks arriving after a toggle.
        let mic_volume = Arc::new(AtomicU8::new(0));
        let screen_volume = Arc::new(AtomicU8::new(100));
        let _reception = start(
            &receiver,
            stop.clone(),
            Some(mic_volume.clone()),
            Some(screen_volume.clone()),
            Some("sender".into()),
        );
        let mut captures = Vec::new();
        let mut sids = Vec::new();
        for (source_kind, hz) in [
            (TrackSource::Microphone, 440.0),
            (TrackSource::ScreenshareAudio, 880.0),
        ] {
            let source = NativeAudioSource::new(
                AudioSourceOptions {
                    echo_cancellation: false,
                    noise_suppression: false,
                    auto_gain_control: false,
                },
                48000,
                1,
                50,
            );
            let track = LocalAudioTrack::create_audio_track(
                "continuous-tone",
                RtcAudioSource::Native(source.clone()),
            );
            let publication = sender
                .local_participant()
                .publish_track(
                    LocalTrack::Audio(track),
                    TrackPublishOptions {
                        source: source_kind,
                        ..Default::default()
                    },
                )
                .await
                .unwrap();
            sids.push(publication.sid());
            captures.push(tokio::spawn(async move {
                let mut clock = tokio::time::interval(Duration::from_millis(10));
                clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                let mut index = 0usize;
                loop {
                    clock.tick().await;
                    let data = (0..480)
                        .map(|i| {
                            (8000.0
                                * ((index + i) as f64 / 48000.0 * hz * std::f64::consts::TAU).sin())
                                as i16
                        })
                        .collect();
                    source
                        .capture_frame(&AudioFrame {
                            data: Cow::Owned(data),
                            sample_rate: 48000,
                            num_channels: 1,
                            samples_per_channel: 480,
                        })
                        .await
                        .unwrap();
                    index += 480;
                }
            }));
        }
        let video_source = NativeVideoSource::new(
            VideoResolution {
                width: 640,
                height: 360,
            },
            false,
        );
        let video_track = LocalVideoTrack::create_video_track(
            "unchanged-camera",
            RtcVideoSource::Native(video_source.clone()),
        );
        sender
            .local_participant()
            .publish_track(
                LocalTrack::Video(video_track),
                crate::call::camera_publish_options(640, 360),
            )
            .await
            .unwrap();
        captures.push(tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_nanos(1_000_000_000 / 30));
            let mut index = 0u8;
            loop {
                tick.tick().await;
                let mut buffer = I420Buffer::new(640, 360);
                let (y, u, v) = buffer.data_mut();
                y.fill(80 + index % 60);
                u.fill(128);
                v.fill(128);
                video_source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
                index = index.wrapping_add(1);
            }
        }));
        let frames = Arc::new(AtomicU64::new(0));
        let mut video_decoder = None;
        let mut tracks = std::collections::HashMap::new();
        tokio::time::timeout(Duration::from_secs(20), async {
            while tracks.len() < 2 || video_decoder.is_none() {
                match events.recv().await.unwrap() {
                    RoomEvent::TrackSubscribed {
                        track: RemoteTrack::Audio(track),
                        publication,
                        ..
                    } => {
                        tracks.insert(publication.sid(), track);
                    }
                    RoomEvent::TrackSubscribed {
                        track: RemoteTrack::Video(track),
                        ..
                    } => {
                        let count = frames.clone();
                        video_decoder = Some(tokio::spawn(async move {
                            let mut stream = NativeVideoStream::new(track.rtc_track());
                            while let Some(frame) = stream.next().await {
                                assert_eq!(
                                    (frame.buffer.width(), frame.buffer.height()),
                                    (640, 360)
                                );
                                count.fetch_add(1, Ordering::Relaxed);
                            }
                        }));
                    }
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
        let mic = &tracks[&sids[0]];
        let screen = &tracks[&sids[1]];
        let initial = window(mic, screen, &frames).await;
        println!("late muted mic / active screen bytes: {initial:?}");
        assert_eq!(initial.0, 0);
        assert!(initial.1 > 1000);
        mic_volume.store(100, Ordering::Relaxed);
        let both = window(mic, screen, &frames).await;
        println!("both enabled bytes: {both:?}");
        assert!(both.0 > 1000 && both.1 > 1000);
        screen_volume.store(0, Ordering::Relaxed);
        let screen_muted = window(mic, screen, &frames).await;
        println!("active mic / muted screen bytes: {screen_muted:?}");
        assert!(screen_muted.0 > 1000);
        assert_eq!(screen_muted.1, 0);
        screen_volume.store(100, Ordering::Relaxed);
        // Multiple rapid changes must converge to the latest desired state.
        for _ in 0..5 {
            mic_volume.store(0, Ordering::Relaxed);
            tokio::time::sleep(Duration::from_millis(50)).await;
            mic_volume.store(100, Ordering::Relaxed);
        }
        let resumed = window(mic, screen, &frames).await;
        println!("resumed original tracks bytes: {resumed:?}");
        assert!(resumed.0 > 1000 && resumed.1 > 1000);
        assert_eq!(
            receiver.connection_state(),
            livekit::ConnectionState::Connected
        );
        while let Ok(event) = events.try_recv() {
            assert!(!matches!(
                event,
                RoomEvent::Reconnecting
                    | RoomEvent::Disconnected { .. }
                    | RoomEvent::TrackUnsubscribed { .. }
            ));
        }
        assert_eq!(sender.local_participant().track_publications().len(), 3);
        screen_volume.store(0, Ordering::Relaxed);
        tokio::time::sleep(Duration::from_secs(2)).await;
        receiver
            .simulate_scenario(livekit::SimulateScenario::SignalReconnect)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if matches!(events.recv().await.unwrap(), RoomEvent::Reconnected) {
                    break;
                }
            }
        })
        .await
        .unwrap();
        let after_resume = window(mic, screen, &frames).await;
        println!("after signal resume mic / muted screen: {after_resume:?}");
        assert!(after_resume.0 > 1000);
        assert_eq!(after_resume.1, 0);
        if let Some(decoder) = video_decoder {
            decoder.abort();
        }
        for capture in captures {
            capture.abort();
        }
        stop.store(true, Ordering::Relaxed);
        sender.close().await.unwrap();
        receiver.close().await.unwrap();
    });
}
