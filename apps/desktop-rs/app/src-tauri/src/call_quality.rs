//! Four camera tiers on one RTP sender. Receiver feedback covers SFU -> phone
//! loss/decoder load; sender BWE only covers client -> SFU bandwidth.
use livekit::prelude::*;
use livekit::webrtc::stats::{QualityLimitationReason, RtcStats};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

pub const HEIGHTS: [u32; 4] = [180, 360, 720, 1080];
pub const BITRATES: [u64; 4] = [200_000, 650_000, 2_000_000, 3_500_000];
const TOPIC: &str = "rs-call-video-quality-v1";

#[derive(Clone)]
pub struct Policy {
    pub tier: usize,
    maximum: usize,
    bad: u8,
    good: u8,
    grace: u8,
    cooldown: u8,
}
impl Policy {
    pub fn new(maximum: usize) -> Self {
        Self {
            tier: maximum.min(2),
            maximum,
            bad: 0,
            good: 0,
            grace: 0,
            cooldown: 0,
        }
    }
    fn route_changed(&mut self) {
        self.bad = 0;
        self.good = 0;
        self.grace = 4;
    }
    pub fn sample(
        &mut self,
        bandwidth: Option<f64>,
        loss: Option<f64>,
        fps: Option<f64>,
        cpu: bool,
    ) {
        let bad = cpu || loss.is_some_and(|x| x > 0.03) || fps.is_some_and(|x| x < 24.0);
        let severe = loss.is_some_and(|x| x > 0.12) || fps.is_some_and(|x| x < 15.0);
        let good = loss.is_some()
            && fps.is_some()
            && !cpu
            && loss.is_none_or(|x| x <= 0.01)
            && fps.is_none_or(|x| x >= 27.0);
        let allowed = bandwidth.map_or(self.maximum, |b| {
            (0..=self.maximum)
                .rev()
                .find(|&i| i == 0 || b >= BITRATES[i] as f64 * 1.15)
                .unwrap_or(0)
        });
        let grace = self.grace > 0;
        self.grace = self.grace.saturating_sub(1);
        self.cooldown = self.cooldown.saturating_sub(1);
        if bad || (!grace && allowed < self.tier) {
            self.good = 0;
            self.bad += 1;
            if severe || self.bad >= 2 {
                self.tier = self.tier.saturating_sub(1).min(allowed);
                self.bad = 0;
                self.cooldown = 15;
            }
        } else {
            self.bad = 0;
            if good && self.tier < self.maximum && self.cooldown == 0 {
                self.good += 1;
                let probe =
                    loss.is_some() && fps.is_some() && allowed >= self.tier && self.good >= 8;
                if (allowed > self.tier && self.good >= 8) || probe {
                    self.tier += 1;
                    self.good = 0;
                    self.grace = 4;
                }
            } else {
                self.good = 0;
            }
        }
    }
}

#[derive(Serialize, Deserialize, Clone)]
struct Feedback {
    v: u8,
    sid: String,
    seq: u64,
    loss: f64,
    fps: f64,
    #[serde(default)]
    direct: bool,
}
impl Feedback {
    fn valid(&self) -> bool {
        self.v == 1
            && self.loss.is_finite()
            && (0.0..=1.0).contains(&self.loss)
            && self.fps.is_finite()
            && (0.0..=120.0).contains(&self.fps)
    }
}
struct Reception {
    received: u64,
    lost: i64,
    decoded: u32,
    time: Instant,
    direct: bool,
}
pub struct QualityTask(tauri::async_runtime::JoinHandle<()>);
impl Drop for QualityTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn start(room: &livekit::Room, stop: Arc<AtomicBool>, peer: Option<String>) -> QualityTask {
    let mut events = room.subscribe();
    let local = room.local_participant();
    let mut participants = room.remote_participants();
    let mut connected = room.connection_state() == livekit::ConnectionState::Connected;
    QualityTask(tauri::async_runtime::spawn(async move {
        let mut policies: HashMap<String, Policy> = HashMap::new();
        let mut sender_routes: HashMap<String,bool>=HashMap::new();
        let mut feedback: HashMap<(String, ParticipantIdentity), (Feedback, Instant)> =
            HashMap::new();
        let mut receptions: HashMap<String, Reception> = HashMap::new();
        let mut sequence = 0;
        let mut timer = tokio::time::interval(Duration::from_secs(2));
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        while !stop.load(Ordering::Relaxed) {
            tokio::select! {
                event = events.recv() => match event {
                    Some(RoomEvent::DataReceived{topic, payload, participant: Some(participant), ..})
                        if topic.as_deref() == Some(TOPIC) && payload.len() <= 512 => {
                        if peer.as_ref().is_some_and(|p| p != participant.identity().as_str()) { continue; }
                        if let Ok(report) = serde_json::from_slice::<Feedback>(&payload) {
                            if !report.valid() { continue; }
                            if report.direct != crate::media_route::sending_direct(&report.sid) {continue;}
                            if !local.track_publications().values().any(|p| p.sid().as_str() == report.sid && p.source() == TrackSource::Camera) {continue;}
                            let key = (report.sid.clone(), participant.identity());
                            if feedback.get(&key).is_none_or(|(old, _)| report.seq > old.seq) {
                                feedback.insert(key, (report, Instant::now()));
                            }
                        }
                    },
                    Some(RoomEvent::Disconnected{..}) | None => break,
                    Some(RoomEvent::ConnectionStateChanged(state)) => {
                        connected = state == livekit::ConnectionState::Connected;
                        if !connected { receptions.clear(); feedback.clear(); }
                    },
                    Some(RoomEvent::ParticipantConnected(participant)) | Some(RoomEvent::TrackSubscribed{participant, ..}) => {
                        participants.insert(participant.identity(), participant);
                    },
                    Some(RoomEvent::ParticipantDisconnected(participant)) => {participants.remove(&participant.identity());},
                    _ => {},
                },
                _ = timer.tick() => {
                    if !connected {continue;}
                    let now = Instant::now();
                    let publications = local.track_publications();
                    policies.retain(|sid, _| publications.values().any(|p| p.sid().as_str() == sid && !p.is_muted()));
                    sender_routes.retain(|sid,_|policies.contains_key(sid));
                    feedback.retain(|(sid, _), (_, time)| now.duration_since(*time) <= Duration::from_secs(6)
                        && publications.values().any(|p| p.sid().as_str() == sid));
                    for publication in publications.values() {
                        if publication.source() != TrackSource::Camera || publication.is_muted() {continue;}
                        let Some(LocalTrack::Video(track)) = publication.track() else {continue;};
                        let resolution = track.rtc_source().video_resolution();
                        let short_edge = resolution.width.min(resolution.height);
                        let maximum = HEIGHTS.iter().rposition(|&h| h <= short_edge).unwrap_or(0);
                        let sid = publication.sid().to_string();
                        let policy = policies.entry(sid.clone()).or_insert_with(|| Policy::new(maximum));
                        let direct=crate::media_route::sending_direct(&sid);
                        if sender_routes.insert(sid.clone(),direct).is_some_and(|old|old!=direct) {
                            policy.route_changed();
                            feedback.retain(|(feedback_sid,_),_|feedback_sid!=&sid);
                        }
                        let Ok(Ok(stats)) = tokio::time::timeout(Duration::from_secs(2), crate::media_route::sender_stats(&track)).await else {continue;};
                        if stop.load(Ordering::Relaxed) || track.is_muted() || direct!=crate::media_route::sending_direct(&sid) {continue;}
                        let mut bandwidth = None;
                        let mut cpu = false;
                        for report in stats {
                            match report {
                                RtcStats::CandidatePair(p) if p.candidate_pair.nominated && p.candidate_pair.available_outgoing_bitrate.is_finite() && p.candidate_pair.available_outgoing_bitrate > 0.0 => {
                                    bandwidth = Some(p.candidate_pair.available_outgoing_bitrate);
                                },
                                RtcStats::OutboundRtp(p) => cpu |= p.outbound.quality_limitation_reason == QualityLimitationReason::Cpu,
                                _ => {},
                            }
                        }
                        let mut loss: Option<f64> = None;
                        let mut fps: Option<f64> = None;
                        for ((feedback_sid, _), (report, _)) in &feedback {
                            if feedback_sid == &sid && report.direct == direct {
                                loss = Some(loss.unwrap_or(0.0).max(report.loss));
                                fps = Some(fps.unwrap_or(120.0).min(report.fps));
                            }
                        }
                        let previous = policy.tier;
                        let mut next=policy.clone();
                        next.sample(bandwidth, loss, fps, cpu);
                        if direct && (next.tier < previous || cpu || loss.is_some_and(|x|x>0.03) || fps.is_some_and(|x|x<24.0)) {
                            crate::media_route::request_fallback(&sid);continue;
                        }
                        *policy=next;
                        let scale = (short_edge as f64 / HEIGHTS[policy.tier] as f64).max(1.0);
                        if let Err(error) = track.set_single_video_encoding(BITRATES[policy.tier], scale, 30.0) {
                            policy.tier = previous;
                            crate::publisher::log_to_file(&format!("[camera-quality] update skipped: {error}"));
                        } else if previous != policy.tier {
                            crate::publisher::log_to_file(&format!("[camera-quality] sid={sid} target={}p@30 bitrate={}", HEIGHTS[policy.tier], BITRATES[policy.tier]));
                        }
                    }
                    let mut receiving = std::collections::HashSet::new();
                    for participant in participants.values() {
                        if peer.as_ref().is_some_and(|p| p != participant.identity().as_str()) {continue;}
                        for publication in participant.track_publications().values() {
                            if publication.source() != TrackSource::Camera || publication.is_muted() {continue;}
                            let Some(RemoteTrack::Video(track)) = publication.track() else {continue;};
                            let sid = publication.sid().to_string(); receiving.insert(sid.clone());
                            let direct=crate::media_route::receiving_direct(&sid);
                            let Ok(Ok(stats)) = tokio::time::timeout(Duration::from_secs(2), crate::media_route::receiver_stats(&track)).await else {continue;};
                            if stop.load(Ordering::Relaxed) {break;}
                            if direct!=crate::media_route::receiving_direct(&sid) {continue;}
                            for report in stats {
                                let RtcStats::InboundRtp(stats) = report else {continue;};
                                if stats.inbound.frame_width == 0 {continue;}
                                let next = Reception {received: stats.received.packets_received, lost: stats.received.packets_lost,
                                    decoded: stats.inbound.frames_decoded, time: Instant::now(), direct};
                                let Some(old) = receptions.insert(sid.clone(), next) else {continue;};
                                let next = &receptions[&sid]; let elapsed = next.time.duration_since(old.time).as_secs_f64();
                                if next.direct!=old.direct || !(0.5..=6.0).contains(&elapsed) || next.received < old.received || next.decoded < old.decoded {continue;}
                                let lost = (next.lost - old.lost).max(0) as u64;
                                let loss = lost as f64 / (lost + next.received - old.received).max(1) as f64;
                                let fps = ((next.decoded - old.decoded) as f64 / elapsed).clamp(0.0, 120.0);
                                sequence += 1;
                                let report = Feedback {v: 1, sid: sid.clone(), seq: sequence, loss, fps, direct};
                                if report.direct && (loss>0.03 || fps<24.0) {crate::media_route::request_fallback(&sid);continue;}
                                let _ = local.publish_data(DataPacket {payload: serde_json::to_vec(&report).unwrap(),
                                    topic: Some(TOPIC.into()), reliable: false,
                                    destination_identities: vec![participant.identity()]}).await;
                            }
                        }
                    }
                    receptions.retain(|sid, _| receiving.contains(sid));
                }
            }
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn route_change_ignores_stale_bandwidth_but_not_frame_loss() {
        let mut policy=Policy::new(3);policy.tier=3;policy.route_changed();
        for _ in 0..4 {policy.sample(Some(300_000.0),Some(0.0),Some(30.0),false);assert_eq!(policy.tier,3);}
        policy.route_changed();policy.sample(Some(300_000.0),Some(0.0),Some(10.0),false);assert!(policy.tier<3);
    }

    #[test]
    fn desktop_and_mobile_share_quality_policy_cases() {
        let cases: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../../config/call-video-quality-test-cases.json"
        ))
        .unwrap();
        for case in cases.as_array().unwrap() {
            let mut policy = Policy::new(case["maximum"].as_u64().unwrap() as usize);
            for step in case["steps"].as_array().unwrap() {
                for _ in 0..step["repeat"].as_u64().unwrap() {
                    policy.sample(
                        step["bandwidth"].as_f64(),
                        step["loss"].as_f64(),
                        step["fps"].as_f64(),
                        step["cpu"].as_bool().unwrap_or(false),
                    );
                }
                assert_eq!(
                    policy.tier as u64,
                    step["tier"].as_u64().unwrap(),
                    "{}",
                    case["name"]
                );
            }
        }
    }
    #[test]
    fn rejects_invalid_receiver_feedback() {
        for (v, loss, fps) in [
            (2, 0.0, 30.0),
            (1, -0.1, 30.0),
            (1, 1.1, 30.0),
            (1, 0.0, -1.0),
            (1, 0.0, 130.0),
            (1, f64::NAN, 30.0),
        ] {
            assert!(!Feedback {
                v,
                loss,
                fps,
                sid: "camera".into(),
                seq: 1,
                direct: false,
            }
            .valid());
        }
    }
}
