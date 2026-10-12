//! Pause unwanted SFU audio without unsubscribing or replacing its track.
use crate::audio_playout::Volume;
use livekit::prelude::*;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::Duration;

pub struct ReceptionTask(tauri::async_runtime::JoinHandle<()>);
impl Drop for ReceptionTask {
    fn drop(&mut self) {
        self.0.abort();
    }
}

pub fn start(
    room: &Room,
    stop: Arc<AtomicBool>,
    microphone: Option<Volume>,
    screen: Option<Volume>,
    peer: Option<String>,
) -> ReceptionTask {
    let mut events = room.subscribe();
    let mut participants = room.remote_participants();
    let mut connected = room.connection_state() == livekit::ConnectionState::Connected;
    ReceptionTask(tauri::async_runtime::spawn(async move {
        let mut timer = tokio::time::interval(Duration::from_millis(200));
        timer.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        while !stop.load(Ordering::Relaxed) {
            tokio::select! {
                event = events.recv() => match event {
                    Some(RoomEvent::Disconnected { .. }) | None => break,
                    Some(RoomEvent::ConnectionStateChanged(state)) => connected = state == livekit::ConnectionState::Connected,
                    Some(RoomEvent::ParticipantConnected(participant)) | Some(RoomEvent::TrackSubscribed { participant, .. }) => {
                        participants.insert(participant.identity(), participant);
                    },
                    Some(RoomEvent::ParticipantDisconnected(participant)) => { participants.remove(&participant.identity()); },
                    _ => {},
                },
                _ = timer.tick() => {},
            }
            if !connected {
                continue;
            }
            for participant in participants.values() {
                if peer
                    .as_ref()
                    .is_some_and(|p| p != participant.identity().as_str())
                {
                    continue;
                }
                for publication in participant.track_publications().values() {
                    if publication.kind() != TrackKind::Audio {
                        continue;
                    }
                    let volume = match publication.source() {
                        TrackSource::Microphone => microphone.as_ref(),
                        TrackSource::ScreenshareAudio | TrackSource::Unknown => screen.as_ref(),
                        _ => None,
                    };
                    if let Some(volume) = volume {
                        publication.set_enabled(volume.load(Ordering::Relaxed) > 0 && !crate::media_route::receiving_direct(publication.sid().as_str()));
                    }
                }
            }
        }
    }))
}

#[cfg(test)]
#[path = "audio_reception_integration_test.rs"]
mod integration_tests;
