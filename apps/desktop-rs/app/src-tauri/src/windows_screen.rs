//! Bounded Windows Graphics Capture queue with interruptible frame waits.
use scap::frame::{BGRAFrame, Frame};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::time::{Duration, Instant};
use windows_capture::{
    capture::{CaptureControl, Context, GraphicsCaptureApiHandler},
    frame::Frame as CaptureFrame,
    graphics_capture_api::InternalCaptureControl,
    monitor::Monitor,
    settings::{ColorFormat, CursorCaptureSettings, DrawBorderSettings, Settings},
};

type CaptureError = Box<dyn std::error::Error + Send + Sync>;
pub struct Handler {
    tx: SyncSender<Frame>,
    interval: Duration,
    last: Option<Instant>,
}

impl GraphicsCaptureApiHandler for Handler {
    type Flags = (SyncSender<Frame>, Duration);
    type Error = CaptureError;
    fn new(context: Context<Self::Flags>) -> Result<Self, Self::Error> {
        Ok(Self {
            tx: context.flags.0,
            interval: context.flags.1,
            last: None,
        })
    }
    fn on_frame_arrived(
        &mut self,
        frame: &mut CaptureFrame,
        control: InternalCaptureControl,
    ) -> Result<(), Self::Error> {
        if self.last.is_some_and(|last| last.elapsed() < self.interval) {
            return Ok(());
        }
        self.last = Some(Instant::now());
        let (width, height) = (frame.width(), frame.height());
        let mut buffer = frame.buffer()?;
        let data = buffer.as_nopadding_buffer()?.to_vec();
        let frame = Frame::BGRA(BGRAFrame {
            display_time: 0,
            width: width as i32,
            height: height as i32,
            data,
        });
        if let Err(mpsc::TrySendError::Disconnected(_)) = self.tx.try_send(frame) {
            control.stop();
        }
        Ok(())
    }
    fn on_closed(&mut self) -> Result<(), Self::Error> {
        Ok(())
    }
}

pub struct Capturer {
    control: Option<CaptureControl<Handler, CaptureError>>,
    frames: Receiver<Frame>,
}

impl Capturer {
    pub fn build(options: scap::capturer::Options) -> Result<Self, String> {
        let (tx, frames) = mpsc::sync_channel(1);
        let monitor = Monitor::primary().map_err(|error| error.to_string())?;
        let settings = Settings::new(
            monitor,
            if options.show_cursor {
                CursorCaptureSettings::WithCursor
            } else {
                CursorCaptureSettings::WithoutCursor
            },
            DrawBorderSettings::Default,
            ColorFormat::Bgra8,
            (tx, Duration::from_secs_f64(1.0 / options.fps.max(1) as f64)),
        );
        let control = Handler::start_free_threaded(settings).map_err(|error| error.to_string())?;
        Ok(Self {
            control: Some(control),
            frames,
        })
    }
    pub fn start_capture(&mut self) {}
    pub fn stop_capture(&mut self) {
        if let Some(control) = self.control.take() {
            let _ = control.stop();
        }
    }
    pub fn next_frame(&self, timeout: Duration) -> Result<Option<Frame>, String> {
        if self
            .control
            .as_ref()
            .is_none_or(|control| control.is_finished())
        {
            return Err("屏幕采集已结束".into());
        }
        match self.frames.recv_timeout(timeout) {
            Ok(frame) => Ok(Some(frame)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err("屏幕采集已结束".into()),
        }
    }
}

impl Drop for Capturer {
    fn drop(&mut self) {
        self.stop_capture();
    }
}
