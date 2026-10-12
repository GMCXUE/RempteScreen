import 'package:livekit_client/livekit_client.dart';

/// Matches the desktop call camera policy. Screen encoding stays independent.
const callCameraCaptureOptions = CameraCaptureOptions(
  cameraPosition: CameraPosition.front,
  maxFrameRate: 30,
  params: VideoParameters(dimensions: VideoDimensions(1920, 1080)),
);

const callVideoPublishOptions = VideoPublishOptions(
  videoCodec: 'h264',
  videoEncoding: VideoEncoding(maxBitrate: 3500000, maxFramerate: 30),
  // LiveKit has only three simultaneous spatial layers. The four camera tiers
  // instead adjust this one sender in place through call_video_quality.dart.
  simulcast: false,
  degradationPreference: DegradationPreference.maintainFramerate,
);
