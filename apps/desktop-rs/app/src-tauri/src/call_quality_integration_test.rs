use super::*;
use futures_util::StreamExt;
use livekit::webrtc::prelude::{
    I420Buffer, RtcVideoSource, VideoBuffer, VideoFrame, VideoResolution, VideoRotation,
};
use livekit::webrtc::video_source::native::NativeVideoSource;
use livekit::webrtc::video_stream::native::NativeVideoStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[test]
#[ignore = "requires a local LiveKit server and synthetic test tokens"]
fn four_camera_tiers_preserve_track_and_connection() {
    tauri::async_runtime::block_on(async {
        let url = std::env::var("RS_QUALITY_TEST_URL").unwrap();
        let publisher_token =
            std::fs::read_to_string(std::env::var("RS_QUALITY_TEST_PUBLISHER_TOKEN_FILE").unwrap())
                .unwrap();
        let subscriber_token = std::fs::read_to_string(
            std::env::var("RS_QUALITY_TEST_SUBSCRIBER_TOKEN_FILE").unwrap(),
        )
        .unwrap();
        let (publisher, _publisher_events) =
            Room::connect(&url, publisher_token.trim(), call_room_options())
                .await
                .unwrap();
        let (subscriber, mut events) =
            Room::connect(&url, subscriber_token.trim(), call_room_options())
                .await
                .unwrap();
        let source = NativeVideoSource::new(
            VideoResolution {
                width: 1920,
                height: 1080,
            },
            false,
        );
        let track = LocalVideoTrack::create_video_track(
            "synthetic-call-camera",
            RtcVideoSource::Native(source.clone()),
        );
        let publication = publisher
            .local_participant()
            .publish_track(
                LocalTrack::Video(track.clone()),
                camera_publish_options(1920, 1080),
            )
            .await
            .unwrap();
        let sid = publication.sid();
        let stop = Arc::new(AtomicBool::new(false));
        let capture_stop = stop.clone();
        let capture = tokio::spawn(async move {
            let mut clock = tokio::time::interval(Duration::from_nanos(1_000_000_000 / 30));
            clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut index = 0u8;
            while !capture_stop.load(Ordering::Relaxed) {
                clock.tick().await;
                let mut buffer = I420Buffer::new(1920, 1080);
                let (y, u, v) = buffer.data_mut();
                y.fill(80 + index % 60);
                u.fill(128);
                v.fill(128);
                source.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
                index = index.wrapping_add(1);
            }
        });
        let remote = tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                match events.recv().await.unwrap() {
                    RoomEvent::TrackSubscribed {
                        track: RemoteTrack::Video(track),
                        publication,
                        ..
                    } if publication.sid() == sid => break track,
                    RoomEvent::Disconnected { .. } | RoomEvent::Reconnecting => {
                        panic!("connection interrupted")
                    }
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
        let remote_sid = remote.sid();
        let mut frames = NativeVideoStream::new(remote.rtc_track());
        for tier in [3, 2, 1, 0, 3] {
            let height = crate::call_quality::HEIGHTS[tier];
            let width = height * 16 / 9;
            track
                .set_single_video_encoding(
                    crate::call_quality::BITRATES[tier],
                    1080.0 / height as f64,
                    30.0,
                )
                .unwrap();
            tokio::time::timeout(Duration::from_secs(20), async {
                loop {
                    let frame = frames.next().await.unwrap();
                    let i420 = frame.buffer.to_i420();
                    if i420.width() == width && i420.height() == height {
                        break;
                    }
                }
            })
            .await
            .unwrap_or_else(|_| panic!("did not receive {width}x{height}"));
            let settle = Instant::now();
            while settle.elapsed() < Duration::from_secs(1) {
                tokio::time::timeout(Duration::from_secs(1), frames.next())
                    .await
                    .unwrap()
                    .unwrap();
            }
            let started = Instant::now();
            let mut count = 0;
            while started.elapsed() < Duration::from_secs(2) {
                let frame = tokio::time::timeout(Duration::from_secs(1), frames.next())
                    .await
                    .unwrap()
                    .unwrap();
                let i420 = frame.buffer.to_i420();
                assert_eq!((i420.width(), i420.height()), (width, height));
                count += 1;
            }
            let fps = count as f64 / started.elapsed().as_secs_f64();
            eprintln!("tier={height}p received_fps={fps:.1} sid={sid}");
            assert!(
                fps >= 24.0,
                "unexpected frame-rate loss at {height}p: {fps}"
            );
            assert_eq!(publication.sid(), sid);
            assert_eq!(remote.sid(), remote_sid);
            assert_eq!(
                publisher.connection_state(),
                livekit::ConnectionState::Connected
            );
            assert_eq!(
                subscriber.connection_state(),
                livekit::ConnectionState::Connected
            );
            while let Ok(event) = events.try_recv() {
                assert!(!matches!(
                    event,
                    RoomEvent::TrackUnsubscribed { .. }
                        | RoomEvent::Disconnected { .. }
                        | RoomEvent::Reconnecting
                ));
            }
        }
        let publisher_quality =
            crate::call_quality::start(&publisher, stop.clone(), Some("subscriber".into()));
        let subscriber_quality =
            crate::call_quality::start(&subscriber, stop.clone(), Some("publisher".into()));
        tokio::time::timeout(Duration::from_secs(8), async {
            while frames.next().await.unwrap().buffer.to_i420().height() != 720 {}
        })
        .await
        .expect("auto quality starts at 720p");
        tokio::time::timeout(Duration::from_secs(60), async {
            while frames.next().await.unwrap().buffer.to_i420().height() != 1080 {}
        })
        .await
        .expect("healthy receiver feedback restores 1080p");
        eprintln!("automatic receiver feedback restored 1080p without republishing");
        subscriber.local_participant().publish_data(DataPacket {
            payload: serde_json::to_vec(&serde_json::json!({"v": 1, "sid": sid.as_str(), "seq": 1000000, "loss": 0.2, "fps": 8.0})).unwrap(),
            topic: Some("rs-call-video-quality-v1".into()), reliable: false,
            destination_identities: vec![publisher.local_participant().identity()],
        }).await.unwrap();
        tokio::time::timeout(Duration::from_secs(8), async {
            while frames.next().await.unwrap().buffer.to_i420().height() > 720 {}
        })
        .await
        .expect("poor downlink feedback downgrades without reconnecting");
        assert_eq!(publication.sid(), sid);
        assert_eq!(remote.sid(), remote_sid);
        assert_eq!(
            publisher.connection_state(),
            livekit::ConnectionState::Connected
        );
        assert_eq!(
            subscriber.connection_state(),
            livekit::ConnectionState::Connected
        );
        eprintln!("poor receiver feedback lowered quality; SID and connections preserved");
        stop.store(true, Ordering::Relaxed);
        capture.abort();
        drop(publisher_quality);
        drop(subscriber_quality);
        publisher.close().await.unwrap();
        subscriber.close().await.unwrap();
    });
}
