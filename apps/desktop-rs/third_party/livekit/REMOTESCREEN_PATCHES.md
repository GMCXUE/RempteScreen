# RemoteScreen camera encoding patch

This is the project's resolved LiveKit 0.9.4 source, with its existing behavior
preserved. The added `LocalVideoTrack::set_single_video_encoding` validates and
updates one RTP encoding's bitrate, frame-rate cap, and resolution scale. It
preserves RID, active state, track, transceiver, SSRC and peer connection; an
unchanged configuration is a no-op. No additional protocol spatial layer is
introduced. LiveKit's LOW/MEDIUM/HIGH simulcast protocol cannot represent four
simultaneously published layers.

The desktop and Flutter clients instead use the same four-tier quality policy
and receiver-feedback topic. Keep policy tests and the continuous-track LiveKit
integration test passing when upgrading this dependency. The upstream Apache
2.0 license is retained.
