# Local libwebrtc source patch

Vendored libwebrtc 0.3.51, licensed under Apache-2.0 (see LICENSE). The dependency continues to use the existing webrtc-sys 0.3.48 native binary.

The native public RtpTransceiver::set_direction method delegates to the existing native implementation. It allows the answerer to bind the transceivers actually associated with incoming SDP, without creating unrelated sender slots. The added API is restricted to native targets.

Direct media uses separate send and receive directions to preserve existing H264 software encoder formats; sendrecv negotiates only the intersection of encoder and decoder capabilities on macOS. See docs/changes/2026-10-13-media-routing-plan.md for the interoperability verification.
