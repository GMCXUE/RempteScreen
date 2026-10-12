import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'call_camera_view.dart';

/// 使用 SDK 渲染器上报可见性，避免自适应流误认为摄像头无人观看。
class RemoteCameraView extends StatelessWidget {
  const RemoteCameraView({super.key, required this.track});
  final lk.RemoteVideoTrack? track;

  @override
  Widget build(BuildContext context) {
    final video = track;
    if (video == null) return const SizedBox.shrink();
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: CallCameraView(video),
      ),
    );
  }
}
