//! Opportunistic one-to-one direct media. LiveKit remains the authority/fallback.
use crate::{
    direct_transport::{set_sender_active, DirectTransport, MAX_SDP, TOPIC},
    media_route,
};
use futures_util::StreamExt;
use livekit::prelude::*;
use livekit::webrtc::{
    media_stream_track::MediaStreamTrack, peer_connection::PeerConnectionState,
    rtp_sender::RtpSender, stats::RtcStats, video_stream::native::NativeVideoStream,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Serialize, Deserialize)]
struct Signal {
    v: u8,
    kind: String,
    #[serde(default)]
    id: String,
    #[serde(default)]
    sdp: Option<String>,
    #[serde(default)]
    topology: Option<String>,
}
impl Signal {
    fn valid(&self) -> bool {
        self.v == 2
            && self.topology.as_ref().is_none_or(|s| s.len() <= 512)
            && self.id.len() <= 96
            && (self.kind == "hello" || !self.id.is_empty())
            && self
                .sdp
                .as_ref()
                .is_none_or(|s| !s.is_empty() && s.len() <= MAX_SDP)
            && [
                "hello", "offer", "answer", "prepared", "ready", "active", "fallback",
            ]
            .contains(&self.kind.as_str())
    }
}
#[derive(Default, Clone, Copy, Debug)]
struct VideoSample {
    width: u32,
    height: u32,
    fps: f64,
    loss: f64,
    frames: u32,
}
fn video_sample(stats: Vec<RtcStats>) -> VideoSample {
    stats
        .into_iter()
        .find_map(|s| match s {
            RtcStats::InboundRtp(r) if r.stream.kind == "video" => Some(VideoSample {
                width: r.inbound.frame_width,
                height: r.inbound.frame_height,
                fps: r.inbound.frames_per_second,
                frames: r.inbound.frames_decoded,
                loss: if r.received.packets_received > 0 {
                    (r.received.packets_lost.max(0) as f64
                        / (r.received.packets_received + r.received.packets_lost.max(0) as u64)
                            as f64)
                        .min(1.0)
                } else {
                    0.0
                },
            }),
            _ => None,
        })
        .unwrap_or_default()
}
fn slot(source: TrackSource, kind: TrackKind, name: &str) -> Option<usize> {
    match (source, kind) {
        (TrackSource::Microphone, TrackKind::Audio) => Some(0),
        (TrackSource::Camera, TrackKind::Video) => Some(1),
        (TrackSource::Screenshare, TrackKind::Video) => Some(2),
        (TrackSource::ScreenshareAudio, TrackKind::Audio) => Some(3),
        (TrackSource::Unknown, TrackKind::Video) if name == "screen" => Some(2),
        (TrackSource::Unknown, TrackKind::Audio) => Some(3),
        _ => None,
    }
}
fn sender(track: &LocalTrack) -> Option<RtpSender> {
    match track {
        LocalTrack::Audio(t) => t.rtp_sender(),
        LocalTrack::Video(t) => t.rtp_sender(),
    }
}
fn rtc_track(track: &LocalTrack) -> MediaStreamTrack {
    match track {
        LocalTrack::Audio(t) => MediaStreamTrack::Audio(t.rtc_track()),
        LocalTrack::Video(t) => MediaStreamTrack::Video(t.rtc_track()),
    }
}
fn supported_sources(local: &LocalParticipant, remote: &RemoteParticipant) -> bool {
    for entries in [
        local
            .track_publications()
            .values()
            .map(|p| (p.source(), p.kind(), p.name()))
            .collect::<Vec<_>>(),
        remote
            .track_publications()
            .values()
            .map(|p| (p.source(), p.kind(), p.name()))
            .collect::<Vec<_>>(),
    ] {
        let mut seen = [false; 4];
        for (source, kind, name) in entries {
            let Some(index) = slot(source, kind, &name) else {
                return false;
            };
            if seen[index] {
                return false;
            }
            seen[index] = true;
        }
    }
    true
}
fn signature(local: &LocalParticipant, remote: &RemoteParticipant) -> String {
    let mut keys = local
        .track_publications()
        .values()
        .map(|p| format!("{}:{}", p.sid(), p.is_muted()))
        .collect::<Vec<_>>();
    keys.extend(
        remote
            .track_publications()
            .values()
            .map(|p| format!("{}:{}", p.sid(), p.is_muted())),
    );
    keys.sort();
    keys.join(",")
}
struct Link {
    transport: DirectTransport,
    id: String,
    started: Instant,
    activated: Option<Instant>,
    prepared: bool,
    peer_prepared: bool,
    baseline_since: Option<Instant>,
    peer_ready: bool,
    ready_sent: bool,
    active: bool,
    peer_active: bool,
    receivers: HashMap<usize, media_route::ReceiverRoute>,
    baseline: HashMap<usize, VideoSample>,
    probes: Vec<tokio::task::JoinHandle<()>>,
    observed: HashMap<usize, (u32, Instant)>,
    audio_observed: HashMap<usize, (u64, i64, Instant)>,
    fallback: Arc<AtomicBool>,
}
impl Drop for Link {
    fn drop(&mut self) {
        for p in &self.probes {
            p.abort();
        }
    }
}
impl Link {
    fn new(id: String, answerer: bool) -> Result<Self, String> {
        Ok(Self {
            transport: if answerer {
                DirectTransport::new_answerer(vec!["stun:stun.l.google.com:19302".into()])?
            } else {
                DirectTransport::new(vec!["stun:stun.l.google.com:19302".into()])?
            },
            id,
            started: Instant::now(),
            activated: None,
            prepared: false,
            peer_prepared: false,
            baseline_since: None,
            peer_ready: false,
            ready_sent: false,
            active: false,
            peer_active: false,
            receivers: HashMap::new(),
            baseline: HashMap::new(),
            probes: Vec::new(),
            observed: HashMap::new(),
            audio_observed: HashMap::new(),
            fallback: Arc::new(AtomicBool::new(false)),
        })
    }
    fn sync_tracks(&self, local: &LocalParticipant) -> Result<(), String> {
        let publications = local.track_publications();
        for index in 0..4 {
            let track = publications
                .values()
                .find(|p| !p.is_muted() && slot(p.source(), p.kind(), &p.name()) == Some(index))
                .and_then(|p| p.track());
            let outgoing = track.as_ref().map(rtc_track);
            if self.transport.bound_track_id(index) != outgoing.as_ref().map(|t| t.id()) {
                self.transport.replace_track(index, outgoing)?;
            }
            if let Some(sfu) = track.as_ref().and_then(sender) {
                self.transport.copy_encoding(index, &sfu.parameters())?;
            }
        }
        Ok(())
    }
    fn collect_tracks(&mut self) {
        while let Ok(event) = self.transport.tracks.try_recv() {
            crate::publisher::log_to_file(&format!(
                "[direct-media] received track mid={:?} video={}",
                event.transceiver.mid(),
                matches!(&event.track, MediaStreamTrack::Video(_))
            ));
            let Some(index) = event
                .transceiver
                .mid()
                .and_then(|m| self.transport.source_for_mid(&m))
            else {
                continue;
            };
            if matches!(&event.track, MediaStreamTrack::Video(_)) != (index == 1 || index == 2) {
                continue;
            }
            // Native audio must stay muted during shadow reception.
            if let MediaStreamTrack::Audio(t) = &event.track {
                t.set_enabled(false);
            }
            let route = media_route::ReceiverRoute {
                track: event.track,
                receiver: event.receiver,
                factory: self.transport.factory(),
                fallback: self.fallback.clone(),
            };
            if let MediaStreamTrack::Video(track) = &route.track {
                let track = track.clone();
                let factory = route.factory.clone();
                self.probes.push(tokio::spawn(async move {
                    let _factory = factory;
                    let mut stream = NativeVideoStream::new(track);
                    while stream.next().await.is_some() {}
                }));
            }
            self.receivers.insert(index, route);
        }
    }
    async fn diagnostic(&self, peer: &RemoteParticipant) -> String {
        let mut parts = vec![format!(
            "pc={:?} activated={} ready={}/{} active={} baseline={:?}",
            self.transport.pc.connection_state(),
            self.activated.is_some(),
            self.ready_sent,
            self.peer_ready,
            self.active,
            self.baseline
        )];
        for p in peer.track_publications().values() {
            if let Some(index) = slot(p.source(), p.kind(), &p.name()) {
                if let Some(RemoteTrack::Video(track)) = p.track() {
                    if let Ok(Ok(stats)) =
                        tokio::time::timeout(Duration::from_millis(500), track.get_stats()).await
                    {
                        let sample = video_sample(stats);
                        parts.push(format!(
                            "SFU slot={index} {}x{}@{} loss={}",
                            sample.width, sample.height, sample.fps, sample.loss
                        ));
                    }
                }
                if let Some(route) = self.receivers.get(&index) {
                    if let Ok(Ok(stats)) =
                        tokio::time::timeout(Duration::from_millis(500), route.receiver.get_stats())
                            .await
                    {
                        for r in stats {
                            if let RtcStats::InboundRtp(r) = r {
                                parts.push(format!(
                                    "slot={index} size={}x{} fps={} packets={} loss={}",
                                    r.inbound.frame_width,
                                    r.inbound.frame_height,
                                    r.inbound.frames_per_second,
                                    r.received.packets_received,
                                    r.received.packets_lost
                                ));
                            }
                        }
                    }
                } else {
                    parts.push(format!("slot={index} missing receiver"));
                }
            }
        }
        for index in [1, 2] {
            if self.transport.bound_track_id(index).is_some() {
                if let Ok(Ok(stats)) = tokio::time::timeout(
                    Duration::from_millis(500),
                    self.transport.slots[index].sender().get_stats(),
                )
                .await
                {
                    for stat in stats {
                        if let RtcStats::OutboundRtp(r) = stat {
                            parts.push(format!(
                                "send slot={index} {}x{}@{} quality={:?} target={} encoder={}",
                                r.outbound.frame_width,
                                r.outbound.frame_height,
                                r.outbound.frames_per_second,
                                r.outbound.quality_limitation_reason,
                                r.outbound.target_bitrate,
                                r.outbound.encoder_implementation
                            ));
                        }
                    }
                }
            }
        }
        parts.join("; ")
    }
    async fn sample_baseline(&mut self, remote: &RemoteParticipant) -> bool {
        for p in remote.track_publications().values() {
            let Some(index) = slot(p.source(), p.kind(), &p.name()) else {
                continue;
            };
            if p.is_muted() || (index != 1 && index != 2) {
                continue;
            }
            let Some(RemoteTrack::Video(track)) = p.track() else {
                self.baseline_since = None;
                return false;
            };
            let Ok(Ok(stats)) =
                tokio::time::timeout(Duration::from_millis(500), track.get_stats()).await
            else {
                self.baseline_since = None;
                return false;
            };
            let sample = video_sample(stats);
            if sample.width == 0
                || sample.height == 0
                || sample.fps < (if index == 1 { 27.0 } else { 1.0 })
                || sample.loss > 0.01
            {
                self.baseline_since = None;
                return false;
            }
            if self
                .baseline
                .get(&index)
                .is_none_or(|old| old.width != sample.width || old.height != sample.height)
            {
                self.baseline_since = None;
            }
            self.baseline.insert(index, sample);
        }
        if self.baseline.is_empty() {
            return true;
        }
        self.baseline_since
            .get_or_insert_with(Instant::now)
            .elapsed()
            >= Duration::from_secs(2)
    }
    async fn healthy(&mut self, remote: &RemoteParticipant) -> bool {
        if self.fallback.load(Ordering::Relaxed)
            || self.transport.pc.connection_state() != PeerConnectionState::Connected
        {
            return false;
        }
        for p in remote.track_publications().values() {
            let Some(index) = slot(p.source(), p.kind(), &p.name()) else {
                continue;
            };
            if p.is_muted() {
                continue;
            }
            let Some(route) = self.receivers.get(&index) else {
                return false;
            };
            if index == 1 || index == 2 {
                let Ok(Ok(stats)) =
                    tokio::time::timeout(Duration::from_millis(500), route.receiver.get_stats())
                        .await
                else {
                    return false;
                };
                let current = video_sample(stats);
                let Some(base) = self.baseline.get(&index) else {
                    return false;
                };
                let size_ok = u64::from(current.width) * u64::from(current.height)
                    >= u64::from(base.width) * u64::from(base.height)
                    && current.width.min(current.height) >= base.width.min(base.height);
                let fps_floor = if index == 1 {
                    27.0
                } else {
                    (base.fps * 0.9).max(1.0)
                };
                if current.frames > 0 {
                    let last = self
                        .observed
                        .entry(index)
                        .or_insert((current.frames, Instant::now()));
                    if last.0 != current.frames {
                        *last = (current.frames, Instant::now());
                    }
                    if last.1.elapsed() > Duration::from_millis(1200) {
                        return false;
                    }
                }
                if !size_ok || current.fps < fps_floor || current.loss > 0.03 {
                    return false;
                }
            } else {
                let Ok(Ok(stats)) =
                    tokio::time::timeout(Duration::from_millis(500), route.receiver.get_stats())
                        .await
                else {
                    return false;
                };
                let Some((received, lost)) = stats.into_iter().find_map(|s| match s {
                    RtcStats::InboundRtp(r) if r.stream.kind == "audio" => {
                        Some((r.received.packets_received, r.received.packets_lost))
                    }
                    _ => None,
                }) else {
                    return false;
                };
                if received == 0 {
                    return false;
                }
                let last =
                    self.audio_observed
                        .entry(index)
                        .or_insert((received, lost, Instant::now()));
                if received > last.0 {
                    let drops = (lost - last.1).max(0) as u64;
                    let packets = received - last.0;
                    if drops as f64 / (packets + drops).max(1) as f64 > 0.03 {
                        return false;
                    }
                    *last = (received, lost, Instant::now());
                }
                // Opus DTX still sends periodic comfort-noise packets.
                if last.2.elapsed() > Duration::from_secs(3) {
                    return false;
                }
            }
        }
        true
    }
}
struct Owner {
    senders: HashMap<String, LocalTrack>,
    publications: HashMap<String, RemoteTrackPublication>,
    seen: HashSet<String>,
}
impl Owner {
    fn new() -> Self {
        Self {
            senders: HashMap::new(),
            publications: HashMap::new(),
            seen: HashSet::new(),
        }
    }
    fn reset(&mut self) {
        // Restore upstream before changing render streams. The existing audio
        // reception service restores audio according to the user's gain/mute.
        for (sid, track) in self.senders.drain() {
            if let Some(sfu) = sender(&track) {
                let _ = sfu.set_track(Some(rtc_track(&track)));
                let _ = set_sender_active(&sfu, true);
            }
            media_route::set_sender(&sid, None);
        }
        for (sid, p) in self.publications.drain() {
            if p.kind() == TrackKind::Video {
                p.set_enabled(true);
            }
            media_route::set_receiver(&sid, None);
        }
    }
    fn activate(
        &mut self,
        local: &LocalParticipant,
        remote: &RemoteParticipant,
        link: &Link,
    ) -> Result<(), String> {
        for p in remote.track_publications().values() {
            let Some(index) = slot(p.source(), p.kind(), &p.name()) else {
                continue;
            };
            if p.is_muted() {
                continue;
            }
            let route = link
                .receivers
                .get(&index)
                .ok_or("missing direct receiver")?
                .clone();
            let sid = p.sid().to_string();
            self.seen.insert(sid.clone());
            if let MediaStreamTrack::Audio(t) = &route.track {
                t.set_enabled(true);
            }
            media_route::set_receiver(&sid, Some(route));
            self.publications.insert(sid, p.clone());
            p.set_enabled(false);
        }
        for p in local.track_publications().values() {
            let Some(index) = slot(p.source(), p.kind(), &p.name()) else {
                continue;
            };
            if p.is_muted() {
                continue;
            }
            let Some(track) = p.track() else {
                continue;
            };
            let Some(sfu) = sender(&track) else {
                continue;
            };
            let sid = p.sid().to_string();
            self.seen.insert(sid.clone());
            // Save the restoration handle before a parameter update can fail.
            self.senders.insert(sid.clone(), track);
            media_route::set_sender(
                &sid,
                Some(media_route::SenderRoute {
                    sender: link.transport.slots[index].sender(),
                    factory: link.transport.factory(),
                    fallback: link.fallback.clone(),
                }),
            );
            set_sender_active(&sfu, false).map_err(|e| e.to_string())?;
            // Inactive encoders retain their sink's old resolution demand.
            // Release only that input binding; publication/SSRC/SID stay intact.
            sfu.set_track(Some(link.transport.inert_track(index)))
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.reset();
        for sid in &self.seen {
            media_route::forget(sid);
        }
    }
}
async fn send(
    local: &LocalParticipant,
    peer: &RemoteParticipant,
    kind: &str,
    id: &str,
    sdp: Option<String>,
) {
    let signal = Signal {
        v: 2,
        kind: kind.into(),
        id: id.into(),
        sdp,
        topology: Some(signature(local, peer)),
    };
    let _ = tokio::time::timeout(
        Duration::from_secs(1),
        local.publish_data(DataPacket {
            payload: serde_json::to_vec(&signal).unwrap(),
            topic: Some(TOPIC.into()),
            reliable: true,
            destination_identities: vec![peer.identity()],
        }),
    )
    .await;
}
pub struct DirectTask(tauri::async_runtime::JoinHandle<()>);
impl Drop for DirectTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn start(room: &Room, stop: Arc<AtomicBool>, expected_peer: Option<String>) -> DirectTask {
    let mut events = room.subscribe();
    let local = room.local_participant();
    let mut participants = room.remote_participants();
    let mut connected = room.connection_state() == livekit::ConnectionState::Connected;
    DirectTask(tauri::async_runtime::spawn(async move {
        let mut owner = Owner::new();
        let mut link: Option<Link> = None;
        let mut topology = String::new();
        let mut topology_since = Instant::now();
        let mut capable = false;
        let mut attempted = false;
        let mut hellos = 0;
        let mut last_hello = Instant::now() - Duration::from_secs(5);
        let mut timer = tokio::time::interval(Duration::from_millis(250));
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        while !stop.load(Ordering::Relaxed) {
            let mut message: Option<Signal> = None;
            tokio::select! {
                event=events.recv()=>match event{
                    Some(RoomEvent::Disconnected{..})|None=>break,
                    Some(RoomEvent::ConnectionStateChanged(state))=>{connected=state==livekit::ConnectionState::Connected;if connected{attempted=false;hellos=0;}},
                    Some(RoomEvent::ParticipantConnected(p))|Some(RoomEvent::TrackSubscribed{participant:p,..})|Some(RoomEvent::TrackPublished{participant:p,..})=>{participants.insert(p.identity(),p);},
                    Some(RoomEvent::ParticipantDisconnected(p))=>{participants.remove(&p.identity());},
                    Some(RoomEvent::DataReceived{topic,payload,participant:Some(p),..}) if topic.as_deref()==Some(TOPIC) && payload.len()<MAX_SDP+1024=>{
                        if participants.len()==1 && participants.contains_key(&p.identity()) && expected_peer.as_ref().is_none_or(|id|id==p.identity().as_str()) {
                            if let Ok(signal)=serde_json::from_slice::<Signal>(&payload){if signal.valid(){message=Some(signal);}}
                        }
                    },_=>{},
                },
                _=timer.tick()=>{},
            }
            if !connected && participants.len() == 1 && link.as_ref().is_some_and(|l| l.active) {
                let peer = participants.values().next().unwrap();
                if let Some(l) = link.as_mut() {
                    if l.healthy(peer).await {
                        continue;
                    }
                }
                owner.reset();
                link = None;
                continue;
            }
            if participants.len() != 1 || !connected {
                owner.reset();
                link = None;
                topology.clear();
                capable = false;
                attempted = false;
                continue;
            }
            let peer = participants.values().next().unwrap();
            if expected_peer
                .as_ref()
                .is_some_and(|id| id != peer.identity().as_str())
            {
                continue;
            }
            if !supported_sources(&local, peer) {
                owner.reset();
                link = None;
                topology.clear();
                attempted = true;
                continue;
            }
            let current = signature(&local, peer);
            if current != topology {
                owner.reset();
                link = None;
                topology = current;
                topology_since = Instant::now();
                attempted = false;
                hellos = 0;
            }
            for p in peer.track_publications().values() {
                owner.seen.insert(p.sid().to_string());
            }
            if local.track_publications().is_empty() && peer.track_publications().is_empty() {
                continue;
            }
            if hellos < 3 && last_hello.elapsed() > Duration::from_secs(2) {
                send(&local, peer, "hello", "", None).await;
                hellos += 1;
                last_hello = Instant::now();
            }
            if let Some(signal) = message {
                if signal.kind != "hello" && signal.topology.as_deref() != Some(topology.as_str()) {
                    if signal.kind == "offer" {
                        send(&local, peer, "hello", "", None).await;
                    }
                    continue;
                }
                match signal.kind.as_str() {
                    "hello" => capable = true,
                    "offer"
                        if peer.identity().as_str() < local.identity().as_str()
                            && !attempted
                            && link.is_none()
                            && signal.sdp.is_some() =>
                    {
                        capable = true;
                        owner.reset();
                        link = None;
                        attempted = true;
                        if let Ok(mut new) = Link::new(signal.id.clone(), true) {
                            if new
                                .transport
                                .prepare_answer(signal.sdp.as_deref().unwrap())
                                .await
                                .is_ok()
                                && new.sync_tracks(&local).is_ok()
                            {
                                match new.transport.finish_answer().await {
                                    Ok(answer) => {
                                        if signature(&local, peer) == topology {
                                            send(&local, peer, "answer", &new.id, Some(answer))
                                                .await;
                                            new.collect_tracks();
                                            link = Some(new);
                                        }
                                    }
                                    Err(e) => crate::publisher::log_to_file(&format!(
                                        "[direct-media] answer fallback: {e}"
                                    )),
                                }
                            }
                        }
                    }
                    "answer" => {
                        if let Some(l) = link.as_mut().filter(|l| l.id == signal.id) {
                            if let Some(answer) = signal.sdp {
                                if l.transport.accept_answer(&answer).await.is_err() {
                                    owner.reset();
                                    link = None;
                                }
                            }
                        }
                    }
                    "prepared" => {
                        if let Some(l) = link.as_mut().filter(|l| l.id == signal.id) {
                            l.peer_prepared = true;
                        }
                    }
                    "ready" => {
                        if let Some(l) = link.as_mut().filter(|l| l.id == signal.id) {
                            l.peer_ready = true;
                        }
                    }
                    "active" => {
                        if let Some(l) = link.as_mut().filter(|l| l.id == signal.id) {
                            l.peer_active = true;
                        }
                    }
                    "fallback" => {
                        if link.as_ref().is_some_and(|l| l.id == signal.id) {
                            owner.reset();
                            link = None;
                            attempted = true;
                        }
                    }
                    _ => {}
                }
            }
            if link.is_none()
                && capable
                && !attempted
                && topology_since.elapsed() >= Duration::from_secs(1)
                && local.identity().as_str() < peer.identity().as_str()
            {
                attempted = true;
                let id = format!(
                    "{}-{}",
                    local.sid(),
                    SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .unwrap()
                        .as_nanos()
                );
                if let Ok(new) = Link::new(id, false) {
                    if new.sync_tracks(&local).is_ok() {
                        match new.transport.offer().await {
                            Ok(offer) => {
                                if signature(&local, peer) == topology {
                                    send(&local, peer, "offer", &new.id, Some(offer)).await;
                                    link = Some(new);
                                }
                            }
                            Err(e) => crate::publisher::log_to_file(&format!(
                                "[direct-media] offer fallback: {e}"
                            )),
                        }
                    }
                }
            }
            let mut failed = false;
            if let Some(l) = link.as_mut() {
                l.collect_tracks();
                if l.sync_tracks(&local).is_err() {
                    failed = true;
                }
                if l.transport.pc.connection_state() == PeerConnectionState::Connected
                    && l.activated.is_none()
                {
                    if !l.prepared && l.sample_baseline(peer).await {
                        send(&local, peer, "prepared", &l.id, None).await;
                        l.prepared = true;
                    }
                    if l.prepared && l.peer_prepared && l.transport.activate().is_ok() {
                        l.activated = Some(Instant::now());
                    }
                }
                if let Some(activated) = l.activated {
                    let healthy = l.healthy(peer).await;
                    if healthy && !l.ready_sent {
                        send(&local, peer, "ready", &l.id, None).await;
                        l.ready_sent = true;
                    }
                    if healthy && l.ready_sent && l.peer_ready && !l.active {
                        if owner.activate(&local, peer, l).is_ok() {
                            l.active = true;
                            send(&local, peer, "active", &l.id, None).await;
                            crate::publisher::log_to_file(
                                "[direct-media] peer media active; SFU capture/room preserved",
                            );
                        } else {
                            failed = true;
                        }
                    }
                    if (!healthy && l.active)
                        || (!l.active && activated.elapsed() > Duration::from_secs(6))
                    {
                        failed = true;
                    }
                    if l.active && !l.peer_active && activated.elapsed() > Duration::from_secs(10) {
                        failed = true;
                    }
                } else if l.started.elapsed() > Duration::from_secs(16) {
                    failed = true;
                }
                if matches!(
                    l.transport.pc.connection_state(),
                    PeerConnectionState::Failed
                        | PeerConnectionState::Closed
                        | PeerConnectionState::Disconnected
                ) {
                    failed = true;
                }
                if l.fallback.load(Ordering::Relaxed) {
                    failed = true;
                }
            }
            if failed {
                if let Some(l) = &link {
                    crate::publisher::log_to_file(&format!(
                        "[direct-media] fallback diagnostic: {}",
                        l.diagnostic(peer).await
                    ));
                    send(&local, peer, "fallback", &l.id, None).await;
                }
                owner.reset();
                link = None;
                attempted = true;
                crate::publisher::log_to_file("[direct-media] SFU fallback; room preserved");
            }
        }
        owner.reset();
        drop(link);
    }))
}

#[cfg(test)]
#[path = "direct_media_integration_test.rs"]
mod integration_tests;

#[cfg(test)]
mod signal_tests {
    use super::*;
    #[test]
    fn reject_old_protocol_oversized_or_unknown_signals() {
        let mut s = Signal {
            v: 2,
            kind: "offer".into(),
            id: "attempt".into(),
            sdp: Some("v=0".into()),
            topology: Some("TR_camera:false".into()),
        };
        assert!(s.valid());
        s.v = 1;
        assert!(!s.valid());
        s.v = 2;
        s.kind = "restart".into();
        assert!(!s.valid());
        s.kind = "answer".into();
        s.id.clear();
        assert!(!s.valid());
        s.id = "x".repeat(97);
        assert!(!s.valid());
        s.id = "attempt".into();
        s.sdp = Some("x".repeat(MAX_SDP + 1));
        assert!(!s.valid());
        s.sdp = Some("v=0".into());
        s.topology = Some("x".repeat(513));
        assert!(!s.valid());
    }
}
