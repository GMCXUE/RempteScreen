//! One direct WebRTC connection, with fixed media slots shared with Flutter.
//! This module never closes a LiveKit room or opens a capture device.
use livekit::webrtc::{
    audio_source::{native::NativeAudioSource, AudioSourceOptions},
    peer_connection_factory::native::PeerConnectionFactoryExt,
    prelude::VideoResolution,
    video_source::native::NativeVideoSource,
};
use livekit::webrtc::{
    media_stream_track::MediaStreamTrack,
    peer_connection::{AnswerOptions, IceGatheringState, OfferOptions, PeerConnection, TrackEvent},
    peer_connection_factory::{IceServer, PeerConnectionFactory, RtcConfiguration},
    rtp_parameters::RtpParameters,
    rtp_transceiver::{RtpTransceiver, RtpTransceiverDirection, RtpTransceiverInit},
    session_description::{SdpType, SessionDescription},
    MediaType, RtcError,
};
use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

// Protocol v2: microphone, camera, screen, screen audio; never infer by track order.
pub const SOURCES: [&str; 4] = ["microphone", "camera", "screen", "screen_audio"];
pub const TOPIC: &str = "rs-direct-media-v2";
pub const MAX_SDP: usize = 48 * 1024;
pub struct DirectTransport {
    pub pc: PeerConnection,
    pub slots: Vec<RtpTransceiver>,
    pub tracks: tokio::sync::mpsc::UnboundedReceiver<TrackEvent>,
    candidates: Arc<Mutex<Vec<(usize, String)>>>,
    bound_tracks: Mutex<Vec<Option<MediaStreamTrack>>>,
    inert_tracks: Vec<MediaStreamTrack>,
    pending_encoding: Mutex<Vec<Option<RtpParameters>>>,
    answerer: bool,
    activated: std::sync::atomic::AtomicBool,
    _factory: PeerConnectionFactory,
}
impl Drop for DirectTransport {
    fn drop(&mut self) {
        self.pc.close();
    }
}
impl DirectTransport {
    pub fn new(stun_urls: Vec<String>) -> Result<Self, String> {
        Self::with_role(stun_urls, false)
    }
    pub fn new_answerer(stun_urls: Vec<String>) -> Result<Self, String> {
        Self::with_role(stun_urls, true)
    }
    fn with_role(stun_urls: Vec<String>, answerer: bool) -> Result<Self, String> {
        let factory = PeerConnectionFactory::with_zero_playout_delay();
        let mut config = RtcConfiguration::default();
        // No TURN: a relay would still consume server media bandwidth. The caller
        // keeps LiveKit as fallback if host/srflx connectivity does not work.
        if !stun_urls
            .iter()
            .all(|s| s.starts_with("stun:") && s.len() <= 256)
        {
            return Err("invalid STUN configuration".into());
        }
        config.ice_servers = stun_urls
            .into_iter()
            .map(|url| IceServer {
                urls: vec![url],
                username: String::new(),
                password: String::new(),
            })
            .collect();
        let pc = factory
            .create_peer_connection(config)
            .map_err(|e| e.to_string())?;
        let candidates = Arc::new(Mutex::new(Vec::new()));
        let gathered = candidates.clone();
        pc.on_ice_candidate(Some(Box::new(move |candidate| {
            if let Ok(index) = usize::try_from(candidate.sdp_mline_index()) {
                gathered
                    .lock()
                    .unwrap()
                    .push((index, candidate.to_string()));
            }
        })));
        let (tx, tracks) = tokio::sync::mpsc::unbounded_channel();
        pc.on_track(Some(Box::new(move |event| {
            let _ = tx.send(event);
        })));
        let mut slots = Vec::new();
        for physical in 0..(if answerer { 0 } else { 8 }) {
            let slot = physical % 4;
            let kind = if slot == 1 || slot == 2 {
                MediaType::Video
            } else {
                MediaType::Audio
            };
            let transceiver = pc
                .add_transceiver_for_media(
                    kind,
                    RtpTransceiverInit {
                        direction: if physical < 4 {
                            RtpTransceiverDirection::SendOnly
                        } else {
                            RtpTransceiverDirection::RecvOnly
                        },
                        stream_ids: vec![SOURCES[slot].into()],
                        send_encodings: vec![
                            livekit::webrtc::rtp_parameters::RtpEncodingParameters {
                                active: false,
                                max_bitrate: if slot == 1 { Some(3_500_000) } else { None },
                                max_framerate: if slot == 1 { Some(30.0) } else { None },
                                ..Default::default()
                            },
                        ],
                    },
                )
                .map_err(|e| e.to_string())?;
            configure_video_codec(&factory, slot, &transceiver, physical >= 4)?;
            if physical < 4 {
                slots.push(transceiver);
            }
        }
        // libwebrtc-0.3.51 also dereferences null in RtpSender::set_track(None).
        // These disabled sources produce no frames and never stop real capture.
        static NEXT_INERT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = NEXT_INERT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let inert_tracks = (0..4)
            .map(|index| {
                if index == 1 || index == 2 {
                    let source = NativeVideoSource::new(
                        VideoResolution {
                            width: 16,
                            height: 16,
                        },
                        index == 2,
                    );
                    let track =
                        factory.create_video_track(&format!("rs-inert-{unique}-{index}"), source);
                    track.set_enabled(false);
                    MediaStreamTrack::Video(track)
                } else {
                    let source =
                        NativeAudioSource::new(AudioSourceOptions::default(), 48000, 1, 50);
                    let track =
                        factory.create_audio_track(&format!("rs-inert-{unique}-{index}"), source);
                    track.set_enabled(false);
                    MediaStreamTrack::Audio(track)
                }
            })
            .collect();
        Ok(Self {
            pc,
            slots,
            tracks,
            candidates,
            bound_tracks: Mutex::new(vec![None; 4]),
            inert_tracks,
            pending_encoding: Mutex::new(vec![None; 4]),
            answerer,
            activated: std::sync::atomic::AtomicBool::new(false),
            _factory: factory,
        })
    }
    pub fn source_for_mid(&self, mid: &str) -> Option<usize> {
        let index = mid.parse::<usize>().ok()?;
        let start = if self.answerer { 0 } else { 4 };
        (start..start + 4).contains(&index).then_some(index % 4)
    }
    pub fn factory(&self) -> PeerConnectionFactory {
        self._factory.clone()
    }

    pub fn activate(&self) -> Result<(), String> {
        if self.pc.connection_state()
            != livekit::webrtc::peer_connection::PeerConnectionState::Connected
        {
            return Err("direct connection not ready".into());
        }
        let bindings = self.bound_tracks.lock().unwrap();
        for (index, slot) in self.slots.iter().enumerate() {
            set_sender_active(&slot.sender(), bindings[index].is_some())
                .map_err(|e| e.to_string())?;
        }
        self.activated
            .store(true, std::sync::atomic::Ordering::Relaxed);
        Ok(())
    }
    pub fn replace_track(
        &self,
        slot: usize,
        track: Option<MediaStreamTrack>,
    ) -> Result<(), String> {
        let transceiver = self.slots.get(slot).ok_or("unknown media source")?;
        if let Some(track) = &track {
            let video = matches!(track, MediaStreamTrack::Video(_));
            if video != (slot == 1 || slot == 2) {
                return Err("media source kind mismatch".into());
            }
        }
        let sender = transceiver.sender();
        sender
            .set_track(Some(
                track.clone().unwrap_or_else(|| self.inert_track(slot)),
            ))
            .map_err(|e| e.to_string())?;
        if self.activated.load(std::sync::atomic::Ordering::Relaxed) {
            set_sender_active(&sender, track.is_some()).map_err(|e| e.to_string())?;
        }
        self.bound_tracks.lock().unwrap()[slot] = track;
        Ok(())
    }
    pub fn inert_track(&self, slot: usize) -> MediaStreamTrack {
        self.inert_tracks[slot].clone()
    }
    /// Native RtpSender::track() dereferences a null track in empty slots.
    /// Use only the application-owned binding record for these senders.
    pub fn bound_track_id(&self, slot: usize) -> Option<String> {
        self.bound_tracks
            .lock()
            .unwrap()
            .get(slot)
            .and_then(|track| track.as_ref().map(|t| t.id()))
    }

    pub fn copy_encoding(&self, slot: usize, original: &RtpParameters) -> Result<(), String> {
        let sender = self.slots.get(slot).ok_or("unknown media source")?.sender();
        let mut params = sender.parameters();
        if params.encodings.is_empty() && original.encodings.len() == 1 {
            self.pending_encoding.lock().unwrap()[slot] = Some(original.clone());
            return Ok(());
        }
        if params.encodings.len() != 1 || original.encodings.len() != 1 {
            return Err("single media encoding required".into());
        }
        let src = &original.encodings[0];
        if params.encodings[0].max_bitrate == src.max_bitrate
            && params.encodings[0].max_framerate == src.max_framerate
            && params.encodings[0].scale_resolution_down_by == src.scale_resolution_down_by
            && params.degradation_preference() == original.degradation_preference()
        {
            return Ok(());
        }
        let dst = &mut params.encodings[0];
        dst.max_bitrate = src.max_bitrate;
        dst.max_framerate = src.max_framerate;
        dst.scale_resolution_down_by = src.scale_resolution_down_by;
        if let Some(preference) = original.degradation_preference() {
            params.set_degradation_preference(preference);
        }
        sender.set_parameters(params).map_err(|e| e.to_string())
    }
    async fn gathered_sdp(&self, initial: String) -> Result<String, String> {
        // Bounded non-trickle exchange avoids stale ICE candidates from a prior
        // attempt. A late STUN response never blocks the existing SFU call.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(4);
        while self.pc.ice_gathering_state() != IceGatheringState::Complete
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        // libwebrtc only exposes current_local_description, which is absent
        // while an offer is pending. Append gathered candidates to the original
        // local SDP rather than reading the wrong description.
        let candidates = self.candidates.lock().unwrap();
        let sections = initial.split("m=").collect::<Vec<_>>();
        let mut sdp = sections[0].to_string();
        for (index, section) in sections.iter().skip(1).enumerate() {
            sdp.push_str("m=");
            sdp.push_str(section);
            for (_, candidate) in candidates.iter().filter(|(line, _)| *line == index) {
                sdp.push_str("a=");
                sdp.push_str(candidate.trim());
                sdp.push_str("\r\n");
            }
            sdp.push_str("a=end-of-candidates\r\n");
        }
        if sdp.len() > MAX_SDP {
            return Err("direct SDP too large".into());
        }
        Ok(sdp)
    }
    fn seed_sdp(&self, initial: &str) -> String {
        let sections = initial.split("m=").collect::<Vec<_>>();
        let mut result = sections[0].to_string();
        for (physical, section) in sections.iter().skip(1).enumerate() {
            let slot = physical % 4;
            result.push_str("m=");
            if slot == 3 {
                let lines = section.lines().map(str::trim_end).collect::<Vec<_>>();
                let opus = lines.iter().find_map(|line| {
                    line.strip_prefix("a=rtpmap:")
                        .and_then(|v| v.split_once(' '))
                        .filter(|(_, codec)| codec.eq_ignore_ascii_case("opus/48000/2"))
                        .map(|(pt, _)| pt)
                });
                for line in &lines {
                    result.push_str(line);
                    if opus.is_some_and(|pt| line.starts_with(&format!("a=fmtp:{pt} ")))
                        && !line.split([' ', ';']).any(|v| v.starts_with("stereo="))
                    {
                        result.push_str(";stereo=1");
                    }
                    result.push_str("\r\n");
                }
                if let Some(pt) = opus.filter(|pt| {
                    !lines
                        .iter()
                        .any(|line| line.starts_with(&format!("a=fmtp:{pt} ")))
                }) {
                    result.push_str(&format!("a=fmtp:{pt} stereo=1\r\n"));
                }
                continue;
            }
            if slot != 1 && slot != 2 {
                result.push_str(section);
                continue;
            }
            let Some(bps) = self.slots[slot]
                .sender()
                .parameters()
                .encodings
                .first()
                .and_then(|e| e.max_bitrate)
                .or_else(|| {
                    self.pending_encoding.lock().unwrap()[slot]
                        .as_ref()
                        .and_then(|p| p.encodings.first())
                        .and_then(|e| e.max_bitrate)
                })
                .or_else(|| (slot == 1).then_some(3_500_000))
            else {
                result.push_str(section);
                continue;
            };
            let kbps = (bps / 1000).clamp(300, 3500);
            let lines = section.lines().map(|l| l.trim_end()).collect::<Vec<_>>();
            let pts = lines
                .iter()
                .filter_map(|line| {
                    line.strip_prefix("a=rtpmap:")
                        .and_then(|r| r.split_once(' '))
                        .filter(|(_, codec)| {
                            codec.starts_with("H264/") || codec.starts_with("VP8/")
                        })
                        .map(|(pt, _)| pt)
                })
                .collect::<Vec<_>>();
            for line in &lines {
                result.push_str(line);
                if pts
                    .iter()
                    .any(|pt| line.starts_with(&format!("a=fmtp:{pt} ")))
                {
                    result.push_str(&format!(";x-google-start-bitrate={kbps}"));
                }
                result.push_str("\r\n");
                if let Some((pt, _)) = line
                    .strip_prefix("a=rtpmap:")
                    .and_then(|r| r.split_once(' '))
                {
                    if pts.contains(&pt)
                        && !lines
                            .iter()
                            .any(|l| l.starts_with(&format!("a=fmtp:{pt} ")))
                    {
                        result.push_str(&format!("a=fmtp:{pt} x-google-start-bitrate={kbps}\r\n"));
                    }
                }
            }
        }
        result
    }
    pub async fn offer(&self) -> Result<String, String> {
        let offer = self
            .pc
            .create_offer(OfferOptions {
                offer_to_receive_audio: true,
                offer_to_receive_video: true,
                ..OfferOptions::default()
            })
            .await
            .map_err(|e| e.to_string())?;
        let initial = self.seed_sdp(&offer.to_string());
        let offer =
            SessionDescription::parse(&initial, SdpType::Offer).map_err(|e| e.to_string())?;
        self.pc
            .set_local_description(offer)
            .await
            .map_err(|e| e.to_string())?;
        self.gathered_sdp(initial).await
    }
    pub async fn prepare_answer(&mut self, offer: &str) -> Result<(), String> {
        if !self.slots.is_empty() {
            return Err("answerer must start without local transceivers".into());
        }
        self.set_remote(offer, SdpType::Offer).await?;
        let mut slots = self.pc.transceivers();
        slots.sort_by_key(|t| {
            t.mid()
                .and_then(|m| m.parse::<usize>().ok())
                .unwrap_or(usize::MAX)
        });
        if slots.len() != 8 {
            return Err("invalid negotiated media slots".into());
        }
        for (index, transceiver) in slots.iter().enumerate() {
            if transceiver.mid().as_deref() != Some(index.to_string().as_str()) {
                return Err("invalid negotiated media slots".into());
            }
            transceiver
                .set_direction(if index < 4 {
                    RtpTransceiverDirection::RecvOnly
                } else {
                    RtpTransceiverDirection::SendOnly
                })
                .map_err(|e| e.to_string())?;
            configure_video_codec(&self._factory, index % 4, transceiver, index < 4)?;
            if index >= 4 {
                transceiver
                    .sender()
                    .set_track(Some(self.inert_track(index % 4)))
                    .map_err(|e| e.to_string())?;
            }
        }
        self.slots = slots.into_iter().skip(4).collect();
        Ok(())
    }
    pub async fn finish_answer(&self) -> Result<String, String> {
        let answer = self
            .pc
            .create_answer(AnswerOptions::default())
            .await
            .map_err(|e| e.to_string())?;
        let initial = self.seed_sdp(&answer.to_string());
        let answer =
            SessionDescription::parse(&initial, SdpType::Answer).map_err(|e| e.to_string())?;
        self.pc
            .set_local_description(answer)
            .await
            .map_err(|e| e.to_string())?;
        for (index, slot) in self.slots.iter().enumerate() {
            set_sender_active(&slot.sender(), false).map_err(|e| e.to_string())?;
            let original = self.pending_encoding.lock().unwrap()[index].take();
            if let Some(params) = original {
                self.copy_encoding(index, &params)?;
            }
        }
        self.gathered_sdp(initial).await
    }
    pub async fn accept_answer(&self, answer: &str) -> Result<(), String> {
        self.set_remote(answer, SdpType::Answer).await
    }
    async fn set_remote(&self, sdp: &str, kind: SdpType) -> Result<(), String> {
        validate_remote_sdp(sdp)?;
        for (index, section) in sdp.split("\nm=").skip(1).enumerate() {
            let direction = section
                .lines()
                .map(str::trim_end)
                .filter(|l| ["a=sendonly", "a=recvonly", "a=sendrecv", "a=inactive"].contains(l))
                .collect::<Vec<_>>();
            let sends = if matches!(kind, SdpType::Offer) {
                index < 4
            } else {
                index >= 4
            };
            let expected = if sends { "a=sendonly" } else { "a=recvonly" };
            if direction != [expected]
                && !(matches!(kind, SdpType::Answer) && sends && direction == ["a=inactive"])
            {
                return Err("invalid direct media direction".into());
            }
        }
        let parsed = SessionDescription::parse(sdp, kind).map_err(|e| e.to_string())?;
        tokio::time::timeout(
            Duration::from_secs(5),
            self.pc.set_remote_description(parsed),
        )
        .await
        .map_err(|_| "direct SDP timeout".to_string())?
        .map_err(|e| e.to_string())
    }
}

fn configure_video_codec(
    factory: &PeerConnectionFactory,
    slot: usize,
    transceiver: &RtpTransceiver,
    receiving: bool,
) -> Result<(), String> {
    if slot == 1 || slot == 2 {
        let preferred = if slot == 1 { "video/H264" } else { "video/VP8" };
        let capabilities = if receiving {
            factory.get_rtp_receiver_capabilities(MediaType::Video)
        } else {
            factory.get_rtp_sender_capabilities(MediaType::Video)
        };
        let mut codecs = capabilities
            .codecs
            .into_iter()
            .filter(|c| {
                c.mime_type.eq_ignore_ascii_case(preferred)
                    || ["video/rtx", "video/red", "video/ulpfec", "video/flexfec-03"]
                        .iter()
                        .any(|aux| c.mime_type.eq_ignore_ascii_case(aux))
            })
            .collect::<Vec<_>>();
        if !codecs
            .iter()
            .any(|c| c.mime_type.eq_ignore_ascii_case(preferred))
        {
            return Err(format!("unsupported codec {preferred}"));
        }
        // Keep repair codecs, preferring the SFU-compatible H264 format.
        codecs.sort_by_key(|c| {
            (
                !c.mime_type.eq_ignore_ascii_case(preferred),
                slot == 1
                    && !c.sdp_fmtp_line.as_deref().is_some_and(|p| {
                        p.contains("profile-level-id=42e01f") && p.contains("packetization-mode=0")
                    }),
            )
        });
        transceiver
            .set_codec_preferences(codecs)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn validate_remote_sdp(sdp: &str) -> Result<(), String> {
    if sdp.is_empty() || sdp.len() > MAX_SDP {
        return Err("invalid direct SDP size".into());
    }
    let sections = sdp.split("\nm=").skip(1).collect::<Vec<_>>();
    if sections.len() != 8 {
        return Err("invalid direct media slots".into());
    }
    for (index, section) in sections.iter().enumerate() {
        let expected = if index % 4 == 1 || index % 4 == 2 {
            "video"
        } else {
            "audio"
        };
        let mids = section
            .lines()
            .filter_map(|line| line.trim_end().strip_prefix("a=mid:"))
            .collect::<Vec<_>>();
        if section.split_whitespace().next() != Some(expected) || mids != [index.to_string()] {
            return Err("invalid direct media slots".into());
        }
    }
    Ok(())
}

pub fn set_sender_active(
    sender: &livekit::webrtc::rtp_sender::RtpSender,
    active: bool,
) -> Result<(), RtcError> {
    let mut params = sender.parameters();
    if params.encodings.iter().all(|e| e.active == active) {
        return Ok(());
    }
    for encoding in &mut params.encodings {
        encoding.active = active;
    }
    sender.set_parameters(params)
}

#[cfg(test)]
#[path = "direct_transport_test.rs"]
mod tests;
