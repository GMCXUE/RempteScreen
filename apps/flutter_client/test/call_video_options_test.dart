// Exercise the resolved SDK encoder selection to catch default frame-rate regressions.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:livekit_client/src/utils.dart';
import 'package:remotescreen/call_video_options.dart';

void main() {
  test('摄像头只发布一个可原地缩放的 30 fps 编码，最高 3.5 Mbps', () {
    for (final dimensions in [
      const VideoDimensions(1280, 720),
      const VideoDimensions(720, 1280),
      const VideoDimensions(640, 480),
    ]) {
      final encodings = Utils.computeVideoEncodings(
        isScreenShare: false,
        dimensions: dimensions,
        options: callVideoPublishOptions,
        codec: 'h264',
      )!;
      expect(encodings, hasLength(1));
      expect(encodings.single.maxFramerate, 30);
      expect(encodings.single.maxBitrate, 3500000);
    }
    expect(callCameraCaptureOptions.maxFrameRate, 30);
    expect(callCameraCaptureOptions.params.dimensions,
        const VideoDimensions(1920, 1080));
  });

  test('通话编码与用户选择的屏幕共享编码独立', () {
    final options = callVideoPublishOptions.copyWith(
      // Existing screen sharing uses a single layer independently of cameras.
      simulcast: false,
      screenShareEncoding:
          const VideoEncoding(maxBitrate: 6000000, maxFramerate: 60),
    );
    final camera = Utils.computeVideoEncodings(
        isScreenShare: false,
        dimensions: const VideoDimensions(1280, 720),
        options: options)!;
    final screen = Utils.computeVideoEncodings(
        isScreenShare: true,
        dimensions: const VideoDimensions(1920, 1080),
        options: options)!;
    expect(camera.single.maxFramerate, 30);
    expect(camera.single.maxBitrate, 3500000);
    expect(screen.single.maxFramerate, 60);
    expect(screen.single.maxBitrate, 6000000);
  });
}
