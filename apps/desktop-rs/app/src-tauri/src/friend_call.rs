//! An account call owns its media room; it never closes the screen session.
use livekit::prelude::*;
use std::sync::{Arc, Mutex};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use crate::{call, viewer, audio_playout};

pub struct FriendSession {
    pub frames: viewer::FrameStore,
    pub local: Arc<Mutex<Option<LocalParticipant>>>,
    pub media: Arc<Mutex<call::CallMedia>>,
    pub stop: Arc<AtomicBool>,
    pub heartbeat: Arc<Mutex<std::time::Instant>>,
    pub ready: Arc<AtomicBool>,
    pub status: Arc<Mutex<String>>,
    pub error: Arc<Mutex<String>>,
    pub volume: audio_playout::Volume,
    pub paused: Vec<(LocalParticipant, Arc<Mutex<call::CallMedia>>)>,
}
impl Drop for FriendSession {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.media.lock().unwrap().close();
    }
}
impl FriendSession {
    pub fn start(url: String, token: String, peer: String, video: bool, frames: viewer::FrameStore,
        paused: Vec<(LocalParticipant, Arc<Mutex<call::CallMedia>>)>) -> Self {
        let session=Self {frames: frames.clone(), local: Arc::new(Mutex::new(None)),media: Arc::new(Mutex::new(call::CallMedia::default())),
            stop: Arc::new(AtomicBool::new(false)),ready: Arc::new(AtomicBool::new(false)),heartbeat: Arc::new(Mutex::new(std::time::Instant::now())),status: Arc::new(Mutex::new("connecting".into())),
            error: Arc::new(Mutex::new(String::new())),volume: Arc::new(AtomicU8::new(100)),paused};
        let heartbeat=session.heartbeat.clone();let ready=session.ready.clone();let local=session.local.clone();let media=session.media.clone();let stop=session.stop.clone();
        let status=session.status.clone();let error=session.error.clone();let volume=session.volume.clone();
        tauri::async_runtime::spawn(async move {
            while !ready.load(Ordering::Relaxed) && !stop.load(Ordering::Relaxed){tokio::time::sleep(std::time::Duration::from_millis(50)).await;}
            if stop.load(Ordering::Relaxed){return;}
            let result=run(&url,&token,&peer,video,frames.clone(),local.clone(),media.clone(),stop.clone(),status.clone(),error.clone(),volume,heartbeat).await;
            if let Err(message)=result {*error.lock().unwrap()=message;}
            stop.store(true,Ordering::Relaxed);media.lock().unwrap().close();
            *local.lock().unwrap()=None;*frames.lock().unwrap()=None;*status.lock().unwrap()="ended".into();
        });
        session
    }
}
async fn run(url:&str,token:&str,peer:&str,video:bool,frames:viewer::FrameStore,
    local_out:Arc<Mutex<Option<LocalParticipant>>>,media:Arc<Mutex<call::CallMedia>>,stop:Arc<AtomicBool>,
    status:Arc<Mutex<String>>,error:Arc<Mutex<String>>,volume:audio_playout::Volume,heartbeat:Arc<Mutex<std::time::Instant>>)->Result<(),String>{
    let (room,mut events)=Room::connect(url,token,RoomOptions::default()).await.map_err(|e|format!("连接通话失败：{e}"))?;
    if stop.load(Ordering::Relaxed) {let _=room.close().await;return Ok(());}
    let local=room.local_participant();*local_out.lock().unwrap()=Some(local.clone());

    // Listen immediately: camera permission dialogs must not delay incoming audio.
    let event_stop=stop.clone();let event_frames=frames.clone();let peer=peer.to_owned();let event_error=error.clone();let event_media=media.clone();
    let listener=tauri::async_runtime::spawn(async move {
        let mut playouts=std::collections::HashMap::new();let mut decoder:Option<Arc<AtomicBool>>=None;
        while !event_stop.load(Ordering::Relaxed) {
            if heartbeat.lock().unwrap().elapsed()>std::time::Duration::from_secs(35) {
                event_stop.store(true,Ordering::Relaxed);event_media.lock().unwrap().close();break;
            }
            let event=match tokio::time::timeout(std::time::Duration::from_millis(300),events.recv()).await {Ok(Some(e))=>e,Ok(None)=>break,Err(_)=>continue};
            match event {
                RoomEvent::TrackSubscribed{track,publication,participant} if participant.identity().as_str()==peer => match track {
                    RemoteTrack::Audio(track) if publication.source()==TrackSource::Microphone => {
                        match audio_playout::start(&track,volume.clone()){Ok(p)=>{playouts.insert(publication.sid().to_string(),p);},Err(e)=>*event_error.lock().unwrap()=e}
                    },
                    RemoteTrack::Video(track) if publication.source()==TrackSource::Camera => {
                        if let Some(c)=decoder.take(){c.store(true,Ordering::Relaxed);}
                        decoder=Some(viewer::spawn_camera_decoder(track,event_frames.clone(),event_stop.clone()));
                    },_=>{}
                },
                RoomEvent::TrackUnpublished{publication,..}|RoomEvent::TrackUnsubscribed{publication,..} => {
                    if publication.source()==TrackSource::Camera {
                        if let Some(c)=decoder.take(){c.store(true,Ordering::Relaxed);}*event_frames.lock().unwrap()=None;
                    } else if publication.source()==TrackSource::Microphone {playouts.remove(&publication.sid().to_string());}
                },
                RoomEvent::TrackMuted{publication,..} if publication.source()==TrackSource::Camera => {*event_frames.lock().unwrap()=None;},
                RoomEvent::ParticipantDisconnected(p) if p.identity().as_str()==peer => {event_stop.store(true,Ordering::Relaxed);break;},
                RoomEvent::Disconnected{..} => {event_stop.store(true,Ordering::Relaxed);break;},
                _=>{}
            }
        }
        if let Some(c)=decoder.take(){c.store(true,Ordering::Relaxed);}*event_frames.lock().unwrap()=None;
    });
    if let Err(e)=call::set_microphone(&local,&media,true).await {*error.lock().unwrap()=e;}
    if video && !stop.load(Ordering::Relaxed) {if let Err(e)=call::set_camera(&local,&media,true).await {*error.lock().unwrap()=e;}}
    *status.lock().unwrap()="connected".into();
    while !stop.load(Ordering::Relaxed){tokio::time::sleep(std::time::Duration::from_millis(200)).await;}
    media.lock().unwrap().close();let _=room.close().await;let _=listener.await;
    Ok(())
}
