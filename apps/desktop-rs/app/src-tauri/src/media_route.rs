//! Track-SID routing: renderer/audio gain survive a transport change.
use futures_util::StreamExt;
use livekit::prelude::*;
use livekit::webrtc::{
    audio_frame::AudioFrame, audio_stream::native::NativeAudioStream, audio_track::RtcAudioTrack,
    media_stream_track::MediaStreamTrack, peer_connection_factory::PeerConnectionFactory,
    rtp_receiver::RtpReceiver, rtp_sender::RtpSender, stats::RtcStats, video_frame::BoxVideoFrame,
    video_stream::native::NativeVideoStream, video_track::RtcVideoTrack,
};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    },
};
use tokio::sync::watch;

#[derive(Clone)]
pub struct ReceiverRoute {
    pub track: MediaStreamTrack,
    pub receiver: RtpReceiver,
    // A native stream/async stats request may outlive a fallback. Its factory
    // must remain alive until that last reference is gone.
    pub factory: PeerConnectionFactory,
    pub fallback: Arc<AtomicBool>,
}
#[derive(Clone)]
pub struct SenderRoute {
    pub sender: RtpSender,
    pub factory: PeerConnectionFactory,
    pub fallback: Arc<AtomicBool>,
}
#[derive(Default)]
struct Registry {
    receivers: HashMap<String, watch::Sender<Option<ReceiverRoute>>>,
    senders: HashMap<String, SenderRoute>,
}
fn registry() -> &'static Mutex<Registry> {
    static REGISTRY: OnceLock<Mutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| Mutex::new(Registry::default()))
}
fn subscription(sid: &str) -> watch::Receiver<Option<ReceiverRoute>> {
    registry()
        .lock()
        .unwrap()
        .receivers
        .entry(sid.into())
        .or_insert_with(|| watch::channel(None).0)
        .subscribe()
}
pub fn receiving_direct(sid: &str) -> bool {
    registry()
        .lock()
        .unwrap()
        .receivers
        .get(sid)
        .is_some_and(|s| s.borrow().is_some())
}
pub fn sending_direct(sid: &str) -> bool {
    registry().lock().unwrap().senders.contains_key(sid)
}
pub fn request_fallback(sid: &str) {
    let registry = registry().lock().unwrap();
    if let Some(route) = registry.senders.get(sid) {
        route.fallback.store(true, Ordering::Relaxed);
    }
    if let Some(route) = registry.receivers.get(sid).and_then(|s| s.borrow().clone()) {
        route.fallback.store(true, Ordering::Relaxed);
    }
}
pub fn set_receiver(sid: &str, route: Option<ReceiverRoute>) {
    let mut registry = registry().lock().unwrap();
    registry
        .receivers
        .entry(sid.into())
        .or_insert_with(|| watch::channel(None).0)
        .send_replace(route);
}
pub fn set_sender(sid: &str, route: Option<SenderRoute>) {
    let mut registry = registry().lock().unwrap();
    if let Some(route) = route {
        registry.senders.insert(sid.into(), route);
    } else {
        registry.senders.remove(sid);
    }
}
pub fn forget(sid: &str) {
    let mut registry = registry().lock().unwrap();
    if let Some(sender) = registry.receivers.remove(sid) {
        sender.send_replace(None);
    }
    registry.senders.remove(sid);
}
pub async fn sender_stats(track: &LocalVideoTrack) -> Result<Vec<RtcStats>, String> {
    let route = registry()
        .lock()
        .unwrap()
        .senders
        .get(track.sid().as_str())
        .cloned();
    if let Some(route) = route {
        route.sender.get_stats().await.map_err(|e| e.to_string())
    } else {
        track.get_stats().await.map_err(|e| e.to_string())
    }
}
pub async fn receiver_stats(track: &RemoteVideoTrack) -> Result<Vec<RtcStats>, String> {
    let route = registry()
        .lock()
        .unwrap()
        .receivers
        .get(track.sid().as_str())
        .and_then(|s| s.borrow().clone());
    if let Some(route) = route {
        route.receiver.get_stats().await.map_err(|e| e.to_string())
    } else {
        track.get_stats().await.map_err(|e| e.to_string())
    }
}

pub struct VideoStream {
    original: RtcVideoTrack,
    stream: NativeVideoStream,
    changes: Option<watch::Receiver<Option<ReceiverRoute>>>,
    owner: Option<ReceiverRoute>,
}
impl VideoStream {
    pub fn new(sid: Option<&str>, original: RtcVideoTrack) -> Self {
        let changes = sid.map(subscription);
        let owner = changes.as_ref().and_then(|s| s.borrow().clone());
        let track = owner
            .as_ref()
            .and_then(|r| match &r.track {
                MediaStreamTrack::Video(t) => Some(t.clone()),
                _ => None,
            })
            .unwrap_or_else(|| original.clone());
        Self {
            stream: NativeVideoStream::new(track),
            original,
            changes,
            owner,
        }
    }
    fn select(&mut self, owner: Option<ReceiverRoute>) {
        let track = owner
            .as_ref()
            .and_then(|r| match &r.track {
                MediaStreamTrack::Video(t) => Some(t.clone()),
                _ => None,
            })
            .unwrap_or_else(|| self.original.clone());
        // Drop the old native observer before releasing its factory.
        self.stream = NativeVideoStream::new(track);
        self.owner = owner;
    }
    pub async fn next(&mut self) -> Option<BoxVideoFrame> {
        loop {
            if let Some(changes) = self.changes.as_mut() {
                tokio::select! {
                    frame=self.stream.next()=> {
                        if frame.is_none() && self.owner.is_some() {self.select(None);continue;}
                        return frame;
                    },
                    changed=changes.changed()=> {
                        let owner=if changed.is_ok() {changes.borrow_and_update().clone()} else {None};
                        if changed.is_err() {self.changes=None;}
                        self.select(owner);
                    }
                }
            } else {
                return self.stream.next().await;
            }
        }
    }
}
pub struct AudioStream {
    original: RtcAudioTrack,
    stream: NativeAudioStream,
    changes: watch::Receiver<Option<ReceiverRoute>>,
    owner: Option<ReceiverRoute>,
    sample_rate: i32,
    channels: i32,
    route_closed: bool,
}
impl AudioStream {
    pub fn new(sid: &str, original: RtcAudioTrack, sample_rate: i32, channels: i32) -> Self {
        let changes = subscription(sid);
        let owner = changes.borrow().clone();
        let track = owner
            .as_ref()
            .and_then(|r| match &r.track {
                MediaStreamTrack::Audio(t) => Some(t.clone()),
                _ => None,
            })
            .unwrap_or_else(|| original.clone());
        Self {
            stream: NativeAudioStream::new(track, sample_rate, channels),
            original,
            changes,
            owner,
            sample_rate,
            channels,
            route_closed: false,
        }
    }
    fn select(&mut self, owner: Option<ReceiverRoute>) {
        let track = owner
            .as_ref()
            .and_then(|r| match &r.track {
                MediaStreamTrack::Audio(t) => Some(t.clone()),
                _ => None,
            })
            .unwrap_or_else(|| self.original.clone());
        self.stream = NativeAudioStream::new(track, self.sample_rate, self.channels);
        self.owner = owner;
    }
    pub async fn next(&mut self) -> Option<AudioFrame<'static>> {
        loop {
            if self.route_closed {
                return self.stream.next().await;
            }
            tokio::select! {
                frame=self.stream.next()=> {if frame.is_none() && self.owner.is_some() {self.select(None);continue;}return frame;},
                changed=self.changes.changed()=> {
                    let owner=if changed.is_ok(){self.changes.borrow_and_update().clone()}else{None};
                    if changed.is_err(){self.route_closed=true;}
                    self.select(owner);
                }
            }
        }
    }
}
