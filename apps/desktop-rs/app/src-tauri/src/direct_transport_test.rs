use super::*;
use futures_util::StreamExt;
use livekit::webrtc::peer_connection_factory::native::PeerConnectionFactoryExt;
use livekit::webrtc::{
    audio_frame::AudioFrame,
    audio_source::{native::NativeAudioSource, AudioSourceOptions},
    audio_stream::native::NativeAudioStream,
    peer_connection::PeerConnectionState,
    prelude::{I420Buffer, VideoFrame, VideoResolution, VideoRotation},
    stats::RtcStats,
    video_source::native::NativeVideoSource,
    video_stream::native::NativeVideoStream,
};
use std::{
    borrow::Cow,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Instant,
};
#[test]
#[ignore = "native Mac WebRTC direct-media integration"]
fn direct_transport_preserves_camera_tiers_audio_and_capture() {
    tauri::async_runtime::block_on(async {
        let a = DirectTransport::new(vec![]).unwrap();
        let mut b = DirectTransport::new_answerer(vec![]).unwrap();
        let video = NativeVideoSource::new(
            VideoResolution {
                width: 1920,
                height: 1080,
            },
            false,
        );
        let camera = a._factory.create_video_track("camera", video.clone());
        a.replace_track(1, Some(MediaStreamTrack::Video(camera.clone())))
            .unwrap();
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
        let mic = a._factory.create_audio_track("mic", audio.clone());
        a.replace_track(0, Some(MediaStreamTrack::Audio(mic)))
            .unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let video_capture = tokio::spawn(async move {
            let mut clock = tokio::time::interval(Duration::from_nanos(1_000_000_000 / 30));
            clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            let mut index = 0u8;
            while !stopped.load(Ordering::Relaxed) {
                clock.tick().await;
                let mut buffer = I420Buffer::new(1920, 1080);
                let (y, u, v) = buffer.data_mut();
                y.fill(80 + index % 60);
                u.fill(128);
                v.fill(128);
                video.capture_frame(&VideoFrame::new(VideoRotation::VideoRotation0, buffer));
                index = index.wrapping_add(1);
            }
        });
        let audio_capture = tokio::spawn(async move {
            let mut clock = tokio::time::interval(Duration::from_millis(10));
            let mut index = 0usize;
            loop {
                clock.tick().await;
                let data = (0..480)
                    .map(|i| {
                        (8000.0
                            * ((index + i) as f64 / 48000.0 * 440.0 * std::f64::consts::TAU).sin())
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
                index += 480;
            }
        });
        let mut initial = a.slots[1].sender().parameters();
        initial.encodings[0].max_bitrate = Some(3500000);
        initial.encodings[0].max_framerate = Some(30.0);
        initial.set_degradation_preference(
            livekit::webrtc::rtp_parameters::DegradationPreference::MaintainFramerate,
        );
        a.copy_encoding(1, &initial).unwrap();
        let offer = a.offer().await.unwrap();
        assert!(offer.contains("H264/90000") && offer.contains("VP8/90000"));
        assert_eq!(
            offer.matches("a=sendonly").count(),
            4,
            "outgoing source slots must keep independent encoder capabilities"
        );
        assert_eq!(
            offer.matches("a=recvonly").count(),
            4,
            "same PC must receive all four reverse sources"
        );
        assert!(
            offer.contains("packetization-mode=0"),
            "directional camera negotiation must keep software H264"
        );
        assert!(
            offer.contains("rtx/90000"),
            "video repair codec must survive preference selection"
        );
        b.prepare_answer(&offer).await.unwrap();
        let answer = b.finish_answer().await.unwrap();
        a.accept_answer(&answer).await.unwrap();
        tokio::time::timeout(Duration::from_secs(10), async {
            while a.pc.connection_state() != PeerConnectionState::Connected
                || b.pc.connection_state() != PeerConnectionState::Connected
            {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        a.activate().unwrap();
        b.activate().unwrap();
        let mut camera_receiver = None;
        let mut mic_receiver = None;
        tokio::time::timeout(Duration::from_secs(15), async {
            while camera_receiver.is_none() || mic_receiver.is_none() {
                let event = b.tracks.recv().await.unwrap();
                match (event.transceiver.mid().as_deref(), event.track) {
                    (Some("1"), MediaStreamTrack::Video(t)) => camera_receiver = Some(t),
                    (Some("0"), MediaStreamTrack::Audio(t)) => mic_receiver = Some(t),
                    _ => {}
                }
            }
        })
        .await
        .unwrap();
        let mut audio_stream = NativeAudioStream::new(mic_receiver.unwrap(), 48000, 1);
        let decoded = tokio::time::timeout(Duration::from_secs(10), async {
            let mut samples = Vec::new();
            while let Some(frame) = audio_stream.next().await {
                if frame.data.iter().any(|s| i32::from(*s).abs() > 500) {
                    samples.extend_from_slice(&frame.data);
                }
                if samples.len() >= 24000 {
                    break;
                }
            }
            samples
        })
        .await
        .unwrap();
        let hz = decoded.windows(2).filter(|w| w[0] <= 0 && w[1] > 0).count() as f64 * 48000.0
            / decoded.len() as f64;
        println!("direct decoded tone {hz:.1} Hz");
        assert!((hz - 440.0).abs() < 20.0);
        let mut frames = NativeVideoStream::new(camera_receiver.unwrap());
        let sender = a.slots[1].sender();
        let mut original = sender.parameters();
        original.set_degradation_preference(
            livekit::webrtc::rtp_parameters::DegradationPreference::MaintainFramerate,
        );
        for tier in [3, 2, 1, 0, 3] {
            let height = crate::call_quality::HEIGHTS[tier];
            original.encodings[0].max_bitrate = Some(crate::call_quality::BITRATES[tier]);
            original.encodings[0].max_framerate = Some(30.0);
            original.encodings[0].scale_resolution_down_by = Some(1080.0 / height as f64);
            original.encodings[0].active = false; // SFU may be paused; direct encoding must remain active.
            a.copy_encoding(1, &original).unwrap();
            assert!(sender.parameters().encodings[0].active);
            let matched = tokio::time::timeout(Duration::from_secs(15), async {
                loop {
                    let frame = frames.next().await.unwrap();
                    println!(
                        "waiting {height}p: got {}x{}",
                        frame.buffer.width(),
                        frame.buffer.height()
                    );
                    if frame.buffer.height() == height {
                        break;
                    }
                }
            })
            .await;
            if matched.is_err() {
                for stat in a.pc.get_stats().await.unwrap() {
                    match stat {
                        RtcStats::OutboundRtp(r) if r.stream.kind == "video" => {
                            println!("encoder diagnostic {:?}", r.outbound)
                        }
                        RtcStats::CandidatePair(r) if r.candidate_pair.nominated => {
                            println!("bandwidth diagnostic {:?}", r.candidate_pair)
                        }
                        _ => {}
                    }
                }
                stop.store(true, Ordering::Relaxed);
                video_capture.abort();
                audio_capture.abort();
                a.pc.close();
                b.pc.close();
                tokio::time::sleep(Duration::from_millis(500)).await;
                panic!("missing video tier {height}p");
            }
            let start = Instant::now();
            let mut count = 0;
            while start.elapsed() < Duration::from_secs(2) {
                let frame = tokio::time::timeout(Duration::from_secs(1), frames.next())
                    .await
                    .unwrap()
                    .unwrap();
                assert_eq!(frame.buffer.height(), height);
                count += 1;
            }
            let fps = count as f64 / start.elapsed().as_secs_f64();
            println!("direct tier {height}p fps={fps:.1}");
            assert!(fps >= 27.0);
            assert_eq!(a.pc.connection_state(), PeerConnectionState::Connected);
            assert_eq!(b.pc.connection_state(), PeerConnectionState::Connected);
        }
        a.replace_track(1, None).unwrap();
        assert_eq!(a.bound_track_id(1), None);
        assert!(!a.slots[1].sender().parameters().encodings[0].active);
        tokio::time::sleep(Duration::from_secs(1)).await;
        let paused = a.slots[1]
            .sender()
            .get_stats()
            .await
            .unwrap()
            .into_iter()
            .filter_map(|s| match s {
                RtcStats::OutboundRtp(r) => Some(r.outbound.frames_sent as u64),
                _ => None,
            })
            .sum::<u64>();
        tokio::time::sleep(Duration::from_secs(1)).await;
        let still = a.slots[1]
            .sender()
            .get_stats()
            .await
            .unwrap()
            .into_iter()
            .filter_map(|s| match s {
                RtcStats::OutboundRtp(r) => Some(r.outbound.frames_sent as u64),
                _ => None,
            })
            .sum::<u64>();
        assert_eq!(
            paused, still,
            "empty camera binding must not generate video"
        );
        a.replace_track(1, Some(MediaStreamTrack::Video(camera)))
            .unwrap();
        assert!(a.slots[1].sender().parameters().encodings[0].active);
        tokio::time::sleep(Duration::from_secs(2)).await;
        let resumed = a.slots[1]
            .sender()
            .get_stats()
            .await
            .unwrap()
            .into_iter()
            .filter_map(|s| match s {
                RtcStats::OutboundRtp(r) => Some(r.outbound.frames_sent as u64),
                _ => None,
            })
            .sum::<u64>();
        assert!(
            resumed > still + 45,
            "source rebind must resume near 30fps without renegotiation"
        );
        let stats = a.pc.get_stats().await.unwrap();
        assert!(stats
            .iter()
            .any(|s| matches!(s,RtcStats::CandidatePair(p) if p.candidate_pair.nominated)));
        assert!(stats.iter().all(|s|!matches!(s,RtcStats::LocalCandidate(c) if c.local_candidate.candidate_type==Some(livekit::webrtc::stats::IceCandidateType::Relay))));
        stop.store(true, Ordering::Relaxed);
        video_capture.abort();
        audio_capture.abort();
    });
}

#[test]
fn remote_sdp_rejects_source_slot_spoofing() {
    let mut sdp = "v=0\r\n".to_string();
    for index in 0..8 {
        let kind = if index % 4 == 1 || index % 4 == 2 {
            "video"
        } else {
            "audio"
        };
        sdp.push_str(&format!(
            "m={kind} 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:{index}\r\n"
        ));
    }
    assert!(validate_remote_sdp(&sdp).is_ok());
    assert!(validate_remote_sdp(&sdp.replacen("a=mid:1", "a=mid:2", 1)).is_err());
    assert!(validate_remote_sdp(&sdp.replacen("m=video", "m=audio", 1)).is_err());
    assert!(validate_remote_sdp(
        &(sdp.clone() + "m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:4\r\n")
    )
    .is_err());
    assert!(validate_remote_sdp(&"x".repeat(MAX_SDP + 1)).is_err());
}

#[test]
#[ignore = "native codec direction comparison"]
fn native_h264_formats_follow_transceiver_direction() {
    tauri::async_runtime::block_on(async {
        for receive in [false, true] {
            let peer = DirectTransport::new(vec![]).unwrap();
            let offer = peer
                .pc
                .create_offer(OfferOptions {
                    offer_to_receive_audio: receive,
                    offer_to_receive_video: receive,
                    ..Default::default()
                })
                .await
                .unwrap()
                .to_string();
            let section = offer.split("\nm=").nth(2).unwrap();
            println!("receive={receive} camera codecs:");
            for line in section
                .lines()
                .filter(|l| l.starts_with("a=fmtp:") || l.starts_with("a=send"))
            {
                println!("{line}");
            }
        }
    });
}
