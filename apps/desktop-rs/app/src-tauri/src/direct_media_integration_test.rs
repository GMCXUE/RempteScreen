use super::*;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use hmac::{Hmac, Mac};
use livekit::options::TrackPublishOptions;
use livekit::webrtc::{
    audio_frame::AudioFrame,
    audio_source::{native::NativeAudioSource, AudioSourceOptions, RtcAudioSource},
    prelude::{I420Buffer, RtcVideoSource, VideoFrame, VideoResolution, VideoRotation},
    video_source::native::NativeVideoSource,
};
use sha2::Sha256;
use std::{borrow::Cow, sync::atomic::AtomicU8};
fn token(room: &str, identity: &str) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let head = URL_SAFE_NO_PAD.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
    let body=URL_SAFE_NO_PAD.encode(serde_json::to_vec(&serde_json::json!({"iss":"devkey","sub":identity,"nbf":now-5,"exp":now+180,
        "video":{"roomJoin":true,"room":room,"canPublish":true,"canSubscribe":true,"canPublishData":true}})).unwrap());
    let unsigned = format!("{head}.{body}");
    let mut mac = Hmac::<Sha256>::new_from_slice(b"secret").unwrap();
    mac.update(unsigned.as_bytes());
    format!(
        "{unsigned}.{}",
        URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes())
    )
}
async fn bytes(track: &RemoteVideoTrack) -> u64 {
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
async fn received_sfu_bytes(room: &Room) -> u64 {
    let mut count = 0;
    for peer in room.remote_participants().values() {
        for p in peer.track_publications().values() {
            let stats = match p.track() {
                Some(RemoteTrack::Video(t)) => t.get_stats().await.unwrap(),
                Some(RemoteTrack::Audio(t)) => t.get_stats().await.unwrap(),
                _ => continue,
            };
            for stat in stats {
                if let RtcStats::InboundRtp(r) = stat {
                    count += r.inbound.bytes_received;
                }
            }
        }
    }
    count
}
#[test]
#[ignore = "requires isolated local LiveKit dev server"]
fn direct_media_removes_sfu_video_traffic_and_falls_back_without_room_disconnect() {
    tauri::async_runtime::block_on(async {
        let url = std::env::var("RS_DIRECT_MEDIA_TEST_URL").unwrap();
        assert!(url.starts_with("ws://127.0.0.1:"));
        let name = format!(
            "direct-media-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let (a, _) = Room::connect(
            &url,
            &token(&name, "a-sender"),
            crate::call::call_room_options(),
        )
        .await
        .unwrap();
        let (b, mut events) = Room::connect(
            &url,
            &token(&name, "z-receiver"),
            crate::call::call_room_options(),
        )
        .await
        .unwrap();
        let source = NativeVideoSource::new(
            VideoResolution {
                width: 1920,
                height: 1080,
            },
            false,
        );
        let camera =
            LocalVideoTrack::create_video_track("camera", RtcVideoSource::Native(source.clone()));
        let publication = a
            .local_participant()
            .publish_track(
                LocalTrack::Video(camera.clone()),
                crate::call::camera_publish_options(1920, 1080),
            )
            .await
            .unwrap();
        let sid = publication.sid().to_string();
        let stop = Arc::new(AtomicBool::new(false));
        let capture_stop = stop.clone();
        let capture = tokio::spawn(async move {
            let mut clock = tokio::time::interval(Duration::from_nanos(1_000_000_000 / 30));
            clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut n = 0u8;
            while !capture_stop.load(Ordering::Relaxed) {
                clock.tick().await;
                let mut buffer = I420Buffer::new(1920, 1080);
                let (y, u, v) = buffer.data_mut();
                y.fill(80 + n % 60);
                u.fill(128);
                v.fill(128);
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
                n = n.wrapping_add(1);
            }
        });
        let audio = NativeAudioSource::new(
            AudioSourceOptions {
                echo_cancellation: false,
                noise_suppression: false,
                auto_gain_control: false,
            },
            48000,
            1,
            50,
        );
        let mic =
            LocalAudioTrack::create_audio_track("tone", RtcAudioSource::Native(audio.clone()));
        a.local_participant()
            .publish_track(
                LocalTrack::Audio(mic),
                TrackPublishOptions {
                    source: TrackSource::Microphone,
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let tone = tokio::spawn(async move {
            let mut clock = tokio::time::interval(Duration::from_millis(10));
            let mut n = 0usize;
            loop {
                clock.tick().await;
                let data = (0..480)
                    .map(|i| {
                        (8000.0 * ((n + i) as f64 / 48000.0 * 440.0 * std::f64::consts::TAU).sin())
                            as i16
                    })
                    .collect();
                audio
                    .capture_frame(&AudioFrame {
                        data: Cow::Owned(data),
                        sample_rate: 48000,
                        num_channels: 1,
                        samples_per_channel: 480,
                    })
                    .await
                    .unwrap();
                n += 480;
            }
        });
        let remote = tokio::time::timeout(Duration::from_secs(15), async {
            loop {
                if let RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Video(t),
                    publication,
                    ..
                } = events.recv().await.unwrap()
                {
                    if publication.sid().as_str() == sid {
                        break t;
                    }
                }
            }
        })
        .await
        .unwrap();
        let mut frames = media_route::VideoStream::new(Some(&sid), remote.rtc_track());
        let decoded = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let counter = decoded.clone();
        let render = tokio::spawn(async move {
            while let Some(frame) = frames.next().await {
                counter.fetch_add(1, Ordering::Relaxed);
            }
        });
        let volume = Arc::new(AtomicU8::new(100));
        let _audio_a = crate::audio_reception::start(
            &a,
            stop.clone(),
            Some(volume.clone()),
            Some(volume.clone()),
            None,
        );
        let _audio_b = crate::audio_reception::start(
            &b,
            stop.clone(),
            Some(volume.clone()),
            Some(volume),
            None,
        );
        let mut route_a = Some(start(&a, stop.clone(), Some("z-receiver".into())));
        let route_b = start(&b, stop.clone(), Some("a-sender".into()));
        tokio::time::timeout(Duration::from_secs(30), async {
            while !media_route::sending_direct(&sid) || !media_route::receiving_direct(&sid) {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        })
        .await
        .expect("direct route never became active");
        tokio::time::sleep(Duration::from_secs(2)).await;
        let before = bytes(&remote).await;
        let first = decoded.load(Ordering::Relaxed);
        let t = Instant::now();
        tokio::time::sleep(Duration::from_secs(3)).await;
        let delta = bytes(&remote).await - before;
        let fps = (decoded.load(Ordering::Relaxed) - first) as f64 / t.elapsed().as_secs_f64();
        println!("direct render fps={fps:.1}; SFU received payload bytes={delta}");
        assert_eq!(delta, 0);
        assert!(fps >= 27.0);
        // Confirm upstream RTP is stopped too, not merely hidden locally.
        let outgoing = |stats: Vec<RtcStats>| {
            stats
                .into_iter()
                .filter_map(|s| match s {
                    RtcStats::OutboundRtp(r) => Some(r.sent.bytes_sent),
                    _ => None,
                })
                .sum::<u64>()
        };
        let up_before = outgoing(camera.get_stats().await.unwrap());
        tokio::time::sleep(Duration::from_secs(2)).await;
        let up_delta = outgoing(camera.get_stats().await.unwrap()) - up_before;
        println!("SFU upstream video bytes={up_delta}");
        assert_eq!(up_delta, 0);
        if std::env::var("RS_DIRECT_TEST_UNPUBLISH").as_deref() == Ok("1") {
            a.local_participant()
                .unpublish_track(&publication.sid())
                .await
                .expect("unpublishing paused original sender must be safe");
            tokio::time::timeout(Duration::from_secs(5), async {
                while media_route::sending_direct(&sid) || media_route::receiving_direct(&sid) {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            })
            .await
            .unwrap();
            tokio::time::sleep(Duration::from_secs(2)).await;
            assert_eq!(a.connection_state(), livekit::ConnectionState::Connected);
            assert_eq!(b.connection_state(), livekit::ConnectionState::Connected);
            assert_eq!(a.local_participant().track_publications().len(), 1);
            assert!(a
                .local_participant()
                .track_publications()
                .values()
                .all(|p| p.kind() == TrackKind::Audio));
            println!(
                "Paused camera unpublish kept both rooms and microphone publication connected"
            );
            stop.store(true, Ordering::Relaxed);
            drop(route_a);
            drop(route_b);
            capture.abort();
            tone.abort();
            render.abort();
            a.close().await.unwrap();
            b.close().await.unwrap();
            return;
        }
        let third = if std::env::var_os("RS_DIRECT_TEST_MULTI").is_some() {
            let (third, _) = Room::connect(
                &url,
                &token(&name, "extra-viewer"),
                crate::call::call_room_options(),
            )
            .await
            .unwrap();
            tokio::time::timeout(Duration::from_secs(5), async {
                while media_route::sending_direct(&sid) || media_route::receiving_direct(&sid) {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            })
            .await
            .unwrap();
            println!("second viewer restored the single SFU publication");
            Some(third)
        } else {
            None
        };
        if std::env::var_os("RS_DIRECT_TEST_RECONNECT").is_some() {
            b.simulate_scenario(livekit::SimulateScenario::SignalReconnect)
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
            assert!(media_route::sending_direct(&sid));
            assert!(media_route::receiving_direct(&sid));
            let received = bytes(&remote).await;
            tokio::time::sleep(Duration::from_secs(2)).await;
            assert_eq!(bytes(&remote).await, received);
            println!("Signal reconnect preserved active direct media and zero SFU payload");
        }
        // Change the four camera tiers while preserving the direct route/SID.
        for tier in [2, 1, 0, 3] {
            camera
                .set_single_video_encoding(
                    crate::call_quality::BITRATES[tier],
                    1080.0 / crate::call_quality::HEIGHTS[tier] as f64,
                    30.0,
                )
                .unwrap();
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
        if std::env::var_os("RS_DIRECT_TEST_CLOSE").is_some() {
            drop(route_a.take()); // Closes the actual PC; leaves both SDK rooms open.
        } else {
            media_route::request_fallback(&sid);
        }
        tokio::time::timeout(Duration::from_secs(5), async {
            while media_route::sending_direct(&sid) || media_route::receiving_direct(&sid) {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        })
        .await
        .unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
        let before = bytes(&remote).await;
        tokio::time::sleep(Duration::from_secs(2)).await;
        let resumed = bytes(&remote).await - before;
        println!("fallback SFU payload bytes={resumed}");
        assert!(resumed > 1000);
        assert_eq!(a.connection_state(), livekit::ConnectionState::Connected);
        assert_eq!(b.connection_state(), livekit::ConnectionState::Connected);
        while let Ok(e) = events.try_recv() {
            assert!(!matches!(
                e,
                RoomEvent::Disconnected { .. }
                    | RoomEvent::Reconnecting
                    | RoomEvent::TrackUnsubscribed { .. }
            ));
        }
        stop.store(true, Ordering::Relaxed);
        drop(route_a);
        drop(route_b);
        capture.abort();
        tone.abort();
        render.abort();
        if let Some(third) = third {
            third.close().await.unwrap();
        }
        a.close().await.unwrap();
        b.close().await.unwrap();
    });
}

#[test]
#[ignore = "requires local LiveKit and real Flutter web interop harness"]
fn native_flutter_direct_interop() {
    tauri::async_runtime::block_on(async {
        let url = std::env::var("RS_DIRECT_MEDIA_TEST_URL").unwrap();
        assert!(url.starts_with("ws://127.0.0.1:"));
        let name = format!(
            "flutter-interop-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        );
        let (room, _) = Room::connect(
            &url,
            &token(&name, "a-native"),
            crate::call::call_room_options(),
        )
        .await
        .unwrap();
        let source = NativeVideoSource::new(
            VideoResolution {
                width: 1920,
                height: 1080,
            },
            false,
        );
        let camera =
            LocalVideoTrack::create_video_track("camera", RtcVideoSource::Native(source.clone()));
        let publication = room
            .local_participant()
            .publish_track(
                LocalTrack::Video(camera.clone()),
                crate::call::camera_publish_options(1920, 1080),
            )
            .await
            .unwrap();
        let sid = publication.sid().to_string();
        let screen_source = NativeVideoSource::new(
            VideoResolution {
                width: 640,
                height: 360,
            },
            true,
        );
        let screen = LocalVideoTrack::create_video_track(
            "screen",
            RtcVideoSource::Native(screen_source.clone()),
        );
        room.local_participant()
            .publish_track(
                LocalTrack::Video(screen),
                TrackPublishOptions {
                    source: TrackSource::Screenshare,
                    video_codec: livekit::options::VideoCodec::VP8,
                    simulcast: false,
                    video_encoding: Some(livekit::options::VideoEncoding {
                        max_bitrate: 2_000_000,
                        max_framerate: 30.0,
                    }),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        let mut tones = Vec::new();
        for (name, kind, channels, hz) in [
            ("microphone", TrackSource::Microphone, 1, 440.0),
            ("system", TrackSource::ScreenshareAudio, 2, 880.0),
        ] {
            let audio = NativeAudioSource::new(
                AudioSourceOptions {
                    echo_cancellation: false,
                    noise_suppression: false,
                    auto_gain_control: false,
                },
                48000,
                channels,
                50,
            );
            let track =
                LocalAudioTrack::create_audio_track(name, RtcAudioSource::Native(audio.clone()));
            room.local_participant()
                .publish_track(
                    LocalTrack::Audio(track),
                    TrackPublishOptions {
                        source: kind,
                        ..Default::default()
                    },
                )
                .await
                .unwrap();
            tones.push(tokio::spawn(async move {
                let mut tick = tokio::time::interval(Duration::from_millis(10));
                let mut n = 0usize;
                loop {
                    tick.tick().await;
                    let data = (0..480)
                        .flat_map(|i| {
                            (0..channels).map(move |channel| {
                                (8000.0
                                    * ((n + i) as f64 / 48000.0
                                        * (hz + channel as f64 * 440.0)
                                        * std::f64::consts::TAU)
                                        .sin()) as i16
                            })
                        })
                        .collect();
                    audio
                        .capture_frame(&AudioFrame {
                            data: Cow::Owned(data),
                            sample_rate: 48000,
                            num_channels: channels as u32,
                            samples_per_channel: 480,
                        })
                        .await
                        .unwrap();
                    n += 480;
                }
            }));
        }
        let stop = Arc::new(AtomicBool::new(false));
        let capture_stop = stop.clone();
        let capture = tokio::spawn(async move {
            let mut tick = tokio::time::interval(Duration::from_nanos(1_000_000_000 / 30));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut n = 0u8;
            while !capture_stop.load(Ordering::Relaxed) {
                tick.tick().await;
                let mut buffer = I420Buffer::new(1920, 1080);
                let (y, u, v) = buffer.data_mut();
                y.fill(80 + n % 60);
                u.fill(128);
                v.fill(128);
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
                let mut screen = I420Buffer::new(640, 360);
                let (y, u, v) = screen.data_mut();
                y.fill(160 + n % 50);
                u.fill(100);
                v.fill(140);
                screen_source
                    .capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, screen));
                n = n.wrapping_add(1);
            }
        });
        let quality_mode = std::env::var("RS_DIRECT_TEST_QUALITY").as_deref() == Ok("1");
        let _quality = quality_mode
            .then(|| crate::call_quality::start(&room, stop.clone(), Some("z-flutter".into())));
        let reverse_mode = std::env::var("RS_DIRECT_TEST_REVERSE").as_deref() == Ok("1");
        let mut render_events = room.subscribe();
        let renderer = tokio::spawn(async move {
            let mut tasks = tokio::task::JoinSet::new();
            while let Some(event) = render_events.recv().await {
                if matches!(event, RoomEvent::Disconnected { .. }) {
                    break;
                }
                if let RoomEvent::TrackSubscribed {
                    track: RemoteTrack::Video(track),
                    publication,
                    ..
                } = event
                {
                    let sid = publication.sid().to_string();
                    tasks.spawn(async move {
                        let mut stream =
                            media_route::VideoStream::new(Some(&sid), track.rtc_track());
                        while stream.next().await.is_some() {}
                    });
                }
            }
            tasks.shutdown().await;
        });
        let volume = Arc::new(AtomicU8::new(100));
        let _reception = crate::audio_reception::start(
            &room,
            stop.clone(),
            Some(volume.clone()),
            Some(volume),
            Some("z-flutter".into()),
        );
        let route = start(&room, stop.clone(), Some("z-flutter".into()));
        std::fs::write(
            "/private/tmp/rs-interop-config.json",
            serde_json::to_vec(
                &serde_json::json!({"url":url,"token":token(&name,"z-flutter"),"peer":"a-native","quality":quality_mode,"reverse":reverse_mode}),
            )
            .unwrap(),
        )
        .unwrap();
        tokio::time::timeout(Duration::from_secs(90), async {
            while !media_route::sending_direct(&sid) {
                tokio::time::sleep(Duration::from_millis(200)).await;
            }
        })
        .await
        .expect("Flutter direct route never active");
        tokio::time::sleep(Duration::from_secs(if quality_mode { 45 } else { 12 })).await;
        let report: serde_json::Value =
            serde_json::from_slice(&std::fs::read("/private/tmp/rs-interop-result.json").unwrap())
                .unwrap();
        let camera_report = report["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["source"] == "camera")
            .unwrap();
        assert_eq!(report["state"], "connected");
        assert_eq!(camera_report["direct"], true);
        let stats = &camera_report["stats"][0];
        assert_eq!(
            stats["frameWidth"], 1920,
            "direct must retain the established SFU resolution"
        );
        assert_eq!(stats["frameHeight"], 1080);
        assert!(stats["framesPerSecond"].as_f64().unwrap() >= 27.0);
        assert_eq!(report["tracks"].as_array().unwrap().len(), 4);
        for t in report["tracks"].as_array().unwrap() {
            assert_eq!(
                t["direct"], true,
                "all four sources must use the same verified path"
            );
            assert!(t["stats"][0]["packetsReceived"].as_u64().unwrap() > 0);
            if t["source"] == "screenShareVideo" {
                assert_eq!(t["stats"][0]["frameWidth"], 640);
                assert_eq!(t["stats"][0]["frameHeight"], 360);
            }
        }
        if reverse_mode {
            let peer = room.remote_participants().into_values().next().unwrap();
            let remote = peer.track_publications();
            assert_eq!(remote.len(), 2);
            for p in remote.values() {
                assert!(media_route::receiving_direct(p.sid().as_str()));
            }
            let p = remote
                .values()
                .find(|p| p.source() == TrackSource::Camera)
                .unwrap();
            let Some(RemoteTrack::Video(track)) = p.track() else {
                panic!("Flutter camera missing");
            };
            let stats = media_route::receiver_stats(&track).await.unwrap();
            for s in stats {
                if let RtcStats::InboundRtp(r) = s {
                    if r.stream.kind == "video" {
                        assert_eq!(
                            (r.inbound.frame_width, r.inbound.frame_height),
                            (1920, 1080)
                        );
                        assert!(r.inbound.frames_per_second >= 27.0);
                        println!(
                            "Flutter to native camera {}x{}@{}",
                            r.inbound.frame_width,
                            r.inbound.frame_height,
                            r.inbound.frames_per_second
                        );
                    }
                }
            }
        }
        let native_received = received_sfu_bytes(&room).await;
        let previous_bytes = report["sfuBytes"].as_u64().unwrap();
        let mut sent_before = 0;
        for p in room.local_participant().track_publications().values() {
            if let Some(s) = p.track().as_ref().and_then(sender) {
                for stat in s.get_stats().await.unwrap() {
                    if let RtcStats::OutboundRtp(r) = stat {
                        sent_before += r.sent.bytes_sent;
                    }
                }
            }
        }
        let audio: serde_json::Value = serde_json::from_slice(
            &std::fs::read("/private/tmp/rs-interop-audio.json")
                .expect("browser must measure decoded tones"),
        )
        .unwrap();
        for t in report["tracks"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|t| t["source"] == "microphone" || t["source"] == "screenShareAudio")
        {
            let tone = audio
                .as_array()
                .unwrap()
                .iter()
                .find(|a| a["track"] == t["trackId"])
                .expect("audio source must retain its test tone");
            let expected = if t["source"] == "microphone" {
                [440.0, 440.0]
            } else {
                [880.0, 1320.0]
            };
            for (ch, hz) in expected.iter().enumerate() {
                assert!((tone["channels"][ch]["hz"].as_f64().unwrap() - hz).abs() < 10.0);
                assert!(tone["channels"][ch]["db"].as_f64().unwrap() > -70.0);
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
        let latest: serde_json::Value =
            serde_json::from_slice(&std::fs::read("/private/tmp/rs-interop-result.json").unwrap())
                .unwrap();
        assert_eq!(
            latest["sfuBytes"].as_u64().unwrap(),
            previous_bytes,
            "SFU media downstream must stop after direct activation"
        );
        assert_eq!(
            received_sfu_bytes(&room).await,
            native_received,
            "reverse SFU audio/video must also stop"
        );
        let mut sent_after = 0;
        for p in room.local_participant().track_publications().values() {
            if let Some(s) = p.track().as_ref().and_then(sender) {
                for stat in s.get_stats().await.unwrap() {
                    if let RtcStats::OutboundRtp(r) = stat {
                        sent_after += r.sent.bytes_sent;
                    }
                }
            }
        }
        assert_eq!(
            sent_after, sent_before,
            "SFU upstream must stop for all four sources"
        );
        println!("Flutter four-source active reception: {}", report["tracks"]);
        println!(
            "Four-source SFU media delta: upstream={} downstream={}",
            sent_after - sent_before,
            latest["sfuBytes"].as_u64().unwrap() - previous_bytes
        );
        if std::env::var("RS_DIRECT_TEST_UNPUBLISH").as_deref() == Ok("1") {
            room.local_participant()
                .unpublish_track(&publication.sid())
                .await
                .expect("unpublish paused SDK sender must be safe");
            tokio::time::sleep(Duration::from_secs(2)).await;
            assert!(!media_route::sending_direct(&sid));
            assert_eq!(room.connection_state(), livekit::ConnectionState::Connected);
            let report: serde_json::Value = serde_json::from_slice(
                &std::fs::read("/private/tmp/rs-interop-result.json").unwrap(),
            )
            .unwrap();
            assert_eq!(report["state"], "connected");
            assert!(report["tracks"]
                .as_array()
                .unwrap()
                .iter()
                .all(|t| t["source"] != "camera"));
            println!("Paused native camera unpublish preserved room and remaining sources");
        } else {
            media_route::request_fallback(&sid);
            tokio::time::timeout(Duration::from_secs(10), async {
                while media_route::sending_direct(&sid) {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            })
            .await
            .unwrap();
            tokio::time::sleep(Duration::from_secs(3)).await;
            let report: serde_json::Value = serde_json::from_slice(
                &std::fs::read("/private/tmp/rs-interop-result.json").unwrap(),
            )
            .unwrap();
            let camera_report = report["tracks"]
                .as_array()
                .unwrap()
                .iter()
                .find(|t| t["source"] == "camera")
                .unwrap();
            assert_eq!(report["state"], "connected");
            assert_eq!(camera_report["direct"], false);
            assert_eq!(
                camera_report["stats"][0]["frameWidth"], 1920,
                "fallback must not use stale bandwidth to downgrade camera"
            );
            assert_eq!(camera_report["stats"][0]["frameHeight"], 1080);
            assert!(
                camera_report["stats"][0]["framesPerSecond"]
                    .as_f64()
                    .unwrap()
                    >= 27.0
            );
            println!(
                "Flutter fallback camera reception: {}",
                camera_report["stats"]
            );
        }
        stop.store(true, Ordering::Relaxed);
        drop(route);
        capture.abort();
        renderer.abort();
        for tone in tones {
            tone.abort();
        }
        room.close().await.unwrap();
    });
}
