//! Frame-aligned PCM buffering. A slot always contains one complete stereo frame.
//! Keeping channels together prevents an overflow from shifting L/R sample order.

use rtrb::{Consumer, Producer};

pub type StereoFrame = [i16; 2];

#[derive(Debug, PartialEq, Eq)]
pub enum PacketError {
    InvalidChannels,
    Full,
}

pub fn push_packet(
    producer: &mut Producer<StereoFrame>,
    samples: &[i16],
    channels: usize,
) -> Result<(), PacketError> {
    if !(1..=2).contains(&channels) || samples.len() % channels != 0 {
        return Err(PacketError::InvalidChannels);
    }
    // Only the consumer can free slots, so this check guarantees the whole packet
    // fits. Never enqueue part of a packet or wait inside the per-sample loop.
    if producer.slots() < samples.len() / channels {
        return Err(PacketError::Full);
    }
    for frame in samples.chunks_exact(channels) {
        let pair = [frame[0], frame[channels - 1]];
        producer.push(pair).expect("packet capacity checked");
    }
    Ok(())
}

pub struct BufferedPlayout {
    consumer: Consumer<StereoFrame>,
    prebuffer_frames: usize,
    ramp_frames: usize,
    playing: bool,
    attack: usize,
    tail: usize,
    last: [f32; 2],
    gain: f32,
    pub underruns: u64,
}

impl BufferedPlayout {
    pub fn new(consumer: Consumer<StereoFrame>, rate: u32) -> Self {
        Self {
            consumer,
            prebuffer_frames: (rate as usize * 30 / 1000).max(1),
            ramp_frames: (rate as usize * 5 / 1000).max(1),
            playing: false,
            attack: 0,
            tail: 0,
            last: [0.0; 2],
            gain: 0.0,
            underruns: 0,
        }
    }

    /// One call per physical output frame, independent of the device's channels.
    pub fn next_frame(&mut self, volume: u8) -> [f32; 2] {
        let target_gain = f32::from(volume.min(100)) / 100.0;
        let step = 1.0 / self.ramp_frames as f32;
        self.gain += (target_gain - self.gain).clamp(-step, step);

        if self.tail > 0 {
            self.tail -= 1;
            let scale = self.tail as f32 / self.ramp_frames as f32;
            // Respect an immediate mute even during the fade of a lost packet.
            return if volume == 0 {
                [0.0; 2]
            } else {
                self.last.map(|s| s * scale)
            };
        }
        if !self.playing {
            if self.consumer.slots() < self.prebuffer_frames {
                return [0.0; 2];
            }
            self.playing = true;
            self.attack = 0;
        }
        match self.consumer.pop() {
            Ok(frame) => {
                self.attack = (self.attack + 1).min(self.ramp_frames);
                let gain = self.gain * self.attack as f32 / self.ramp_frames as f32;
                self.last = frame.map(|s| f32::from(s) / 32768.0 * gain);
                self.last
            }
            Err(_) => {
                self.underruns += 1;
                self.playing = false;
                self.tail = self.ramp_frames - 1;
                self.last
                    .map(|s| s * self.tail as f32 / self.ramp_frames as f32)
            }
        }
    }
}

/// WebRTC supplies mono/stereo PCM. On a surround endpoint use front L/R only;
/// feeding the SDK a 5.1/7.1 channel count is not a supported voice remix path.
pub fn output_channel(frame: [f32; 2], channel: usize, channels: usize) -> f32 {
    match (channels, channel) {
        (1, 0) => (frame[0] + frame[1]) * 0.5,
        (_, 0) => frame[0],
        (_, 1) => frame[1],
        _ => 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rtrb::RingBuffer;

    #[test]
    fn overflow_rejects_whole_packet_without_shifting_channels() {
        let (mut producer, mut consumer) = RingBuffer::new(4);
        push_packet(&mut producer, &[1, -1, 2, -2, 3, -3], 2).unwrap();
        assert_eq!(
            push_packet(&mut producer, &[4, -4, 5, -5], 2),
            Err(PacketError::Full)
        );
        assert_eq!(consumer.pop().unwrap(), [1, -1]);
        assert_eq!(consumer.pop().unwrap(), [2, -2]);
        push_packet(&mut producer, &[6, -6, 7, -7], 2).unwrap();
        assert_eq!(consumer.pop().unwrap(), [3, -3]);
        assert_eq!(consumer.pop().unwrap(), [6, -6]);
        assert_eq!(consumer.pop().unwrap(), [7, -7]);
        assert!(consumer.pop().is_err());
    }

    #[test]
    fn malformed_packet_does_not_partially_enqueue() {
        let (mut producer, mut consumer) = RingBuffer::new(4);
        assert_eq!(
            push_packet(&mut producer, &[1, 2, 3], 2),
            Err(PacketError::InvalidChannels)
        );
        assert_eq!(
            push_packet(&mut producer, &[1, 2, 3], 6),
            Err(PacketError::InvalidChannels)
        );
        assert!(consumer.pop().is_err());
        push_packet(&mut producer, &[123, -456], 1).unwrap();
        assert_eq!(consumer.pop().unwrap(), [123, 123]);
        assert_eq!(consumer.pop().unwrap(), [-456, -456]);
    }

    #[test]
    fn jitter_prebuffers_then_fades_on_underrun_and_recovery() {
        let (mut producer, consumer) = RingBuffer::new(200);
        let mut playout = BufferedPlayout::new(consumer, 1000);
        push_packet(&mut producer, &[16384; 20], 1).unwrap();
        for _ in 0..100 {
            assert_eq!(playout.next_frame(100), [0.0; 2]);
        }
        push_packet(&mut producer, &[16384; 10], 1).unwrap();
        for i in 1..=5 {
            assert!((playout.next_frame(100)[0] - 0.5 * i as f32 / 5.0).abs() < 1e-6);
        }
        for _ in 5..30 {
            assert_eq!(playout.next_frame(100), [0.5; 2]);
        }
        for i in (0..5).rev() {
            assert!((playout.next_frame(100)[0] - 0.5 * i as f32 / 5.0).abs() < 1e-6);
        }
        assert_eq!(playout.underruns, 1);
        for _ in 0..100 {
            assert_eq!(playout.next_frame(100), [0.0; 2]);
        }
        push_packet(&mut producer, &[16384; 30], 1).unwrap();
        assert!((playout.next_frame(100)[0] - 0.1).abs() < 1e-6);
    }

    #[test]
    fn gain_never_boosts_and_mapping_preserves_mono_stereo_surround() {
        let (mut producer, consumer) = RingBuffer::new(200);
        let mut playout = BufferedPlayout::new(consumer, 1000);
        let samples: Vec<i16> = (0..100).flat_map(|_| [i16::MAX, i16::MIN]).collect();
        push_packet(&mut producer, &samples, 2).unwrap();
        let mut frame = [0.0; 2];
        for _ in 0..10 {
            frame = playout.next_frame(255);
        }
        assert_eq!(frame, [32767.0 / 32768.0, -1.0]);
        for i in 0..8 {
            assert_eq!(
                output_channel(frame, i, 8),
                if i < 2 { frame[i] } else { 0.0 }
            );
        }
        assert_eq!(output_channel([0.5, -0.5], 0, 1), 0.0);
        for _ in 0..5 {
            frame = playout.next_frame(50);
        }
        assert_eq!(frame, [32767.0 / 65536.0, -0.5]);
    }
}
