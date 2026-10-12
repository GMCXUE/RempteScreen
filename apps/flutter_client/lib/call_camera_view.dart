import 'package:flutter/widgets.dart';
import 'package:livekit_client/livekit_client.dart';

/// Fit changes only presentation. Keeping the full frame avoids magnifying a
/// narrow crop when the peer's camera orientation differs from the screen.
class CallCameraFit extends InheritedWidget {
  const CallCameraFit({super.key, required this.fill, required super.child});
  final bool fill;

  @override
  bool updateShouldNotify(CallCameraFit oldWidget) => fill != oldWidget.fill;
}

/// Both camera views follow the same selfie direction. Screen sharing retains
/// its original orientation; this changes presentation, not the published track.
class CallCameraView extends StatelessWidget {
  const CallCameraView(this.track, {super.key});
  final VideoTrack track;

  @override
  Widget build(BuildContext context) => VideoTrackRenderer(track,
      fit: context.dependOnInheritedWidgetOfExactType<CallCameraFit>()?.fill !=
              false
          ? VideoViewFit.cover
          : VideoViewFit.contain,
      mirrorMode: track is LocalVideoTrack
          ? VideoViewMirrorMode.auto
          : track.source == TrackSource.camera
              ? VideoViewMirrorMode.mirror
              : VideoViewMirrorMode.off);
}
