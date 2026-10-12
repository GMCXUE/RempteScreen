//! One direct WebRTC connection, with fixed media slots shared with Flutter.
//! This module never closes a LiveKit room or opens a capture device.
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

// Protocol v1: microphone, camera, screen, screen audio; never infer by track order.
pub const SOURCES: [&str; 4] = ["microphone", "camera", "screen", "screen_audio"];
pub const TOPIC: &str = "rs-direct-media-v1";
pub const MAX_SDP: usize = 48 * 1024;
pub struct DirectTransport {
    pub pc: PeerConnection,
    pub slots: Vec<RtpTransceiver>,
    pub tracks: tokio::sync::mpsc::UnboundedReceiver<TrackEvent>,
    candidates: Arc<Mutex<Vec<(usize, String)>>>,
    _factory: PeerConnectionFactory,
}
impl Drop for DirectTransport {
    fn drop(&mut self) {
        self.pc.close();
    }
}
impl DirectTransport {
    pub fn new(stun_urls: Vec<String>) -> Result<Self, String> {
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
        for slot in 0..4 {
            let kind = if slot == 1 || slot == 2 {
                MediaType::Video
            } else {
                MediaType::Audio
            };
            let transceiver = pc
                .add_transceiver_for_media(
                    kind,
                    RtpTransceiverInit {
                        direction: RtpTransceiverDirection::SendRecv,
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
            if kind == MediaType::Video {
                let preferred = if slot == 1 { "video/H264" } else { "video/VP8" };
                let mut codecs = factory
                    .get_rtp_sender_capabilities(kind)
                    .codecs
                    .into_iter()
                    .filter(|c| c.mime_type.eq_ignore_ascii_case(preferred))
                    .collect::<Vec<_>>();
                if codecs.is_empty() {
                    pc.close();
                    return Err(format!("unsupported codec {preferred}"));
                }
                // Match LiveKit's interoperable constrained-baseline preference.
                if slot == 1 {
                    codecs.sort_by_key(|c| {
                        !c.sdp_fmtp_line
                            .as_deref()
                            .is_some_and(|p| p.contains("profile-level-id=42e01f"))
                    });
                }
                transceiver
                    .set_codec_preferences(codecs)
                    .map_err(|e| e.to_string())?;
            }
            slots.push(transceiver);
        }
        Ok(Self {
            pc,
            slots,
            tracks,
            candidates,
            _factory: factory,
        })
    }
    pub fn activate(&self) -> Result<(), String> {
        if self.pc.connection_state()
            != livekit::webrtc::peer_connection::PeerConnectionState::Connected
        {
            return Err("direct connection not ready".into());
        }
        for slot in &self.slots {
            set_sender_active(&slot.sender(), true).map_err(|e| e.to_string())?;
        }
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
        transceiver
            .sender()
            .set_track(track)
            .map_err(|e| e.to_string())
    }
    pub fn copy_encoding(&self, slot: usize, original: &RtpParameters) -> Result<(), String> {
        let sender = self.slots.get(slot).ok_or("unknown media source")?.sender();
        let mut params = sender.parameters();
        if params.encodings.len() != 1 || original.encodings.len() != 1 {
            return Err("single media encoding required".into());
        }
        let src = &original.encodings[0];
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
        for (slot, section) in sections.iter().skip(1).enumerate() {
            result.push_str("m=");
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
            .create_offer(OfferOptions::default())
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
    pub async fn answer(&self, offer: &str) -> Result<String, String> {
        self.set_remote(offer, SdpType::Offer).await?;
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
        self.gathered_sdp(initial).await
    }
    pub async fn accept_answer(&self, answer: &str) -> Result<(), String> {
        self.set_remote(answer, SdpType::Answer).await
    }
    async fn set_remote(&self, sdp: &str, kind: SdpType) -> Result<(), String> {
        if sdp.is_empty() || sdp.len() > MAX_SDP {
            return Err("invalid direct SDP size".into());
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
