import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'package:remotescreen/call_camera_view.dart';
import 'package:remotescreen/friend_video_stage.dart';

void main() {
  testWidgets('双方摄像头方向一致，后置自拍和屏幕不翻转，交换不重开摄像头', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('FlutterWebRTC.Method');
    final calls = <String>[];
    var textureId = 40;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'createVideoRenderer') {
        final id = ++textureId;
        messenger.setMockMethodCallHandler(
            MethodChannel('FlutterWebRTC/Texture$id'), (_) async => null);
        return {'textureId': id};
      }
      if (call.method == 'getUserMedia') {
        final facing = call.arguments['constraints']['video']['facingMode'];
        return {
          'streamId': 'camera-$facing',
          'ownerTag': 'local',
          'audioTracks': [],
          'videoTracks': [
            {
              'id': 'track-$facing',
              'label': 'camera',
              'kind': 'video',
              'enabled': true,
              'settings': {'facingMode': facing}
            }
          ]
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final front = await LocalVideoTrack.createCameraTrack(
        const CameraCaptureOptions(cameraPosition: CameraPosition.front));
    final back = await LocalVideoTrack.createCameraTrack(
        const CameraCaptureOptions(cameraPosition: CameraPosition.back));
    final peer = RemoteVideoTrack(
        TrackSource.camera, front.mediaStream, front.mediaStreamTrack);
    final screen = RemoteVideoTrack(TrackSource.screenShareVideo,
        front.mediaStream, front.mediaStreamTrack);
    for (final (track, expectedMirror) in [
      (front, true),
      (back, false),
      (peer, true),
      (screen, false)
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: CallCameraView(track, key: ValueKey(track)))));
      await tester.pumpAndSettle();
      expect(
          tester.widget<rtc.RTCVideoView>(find.byType(rtc.RTCVideoView)).mirror,
          expectedMirror);
      expect(
          tester
              .widget<VideoTrackRenderer>(find.byType(VideoTrackRenderer))
              .fit,
          VideoViewFit.cover);
      final transform = tester.widget<Transform>(find.descendant(
          of: find.byType(rtc.RTCVideoView), matching: find.byType(Transform)));
      expect(transform.transform.entry(0, 0), expectedMirror ? -1 : 1);
    }
    const localKey = ValueKey('self-camera');
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FriendVideoStage(
                peerName: '测试好友',
                status: '通话中',
                onFold: () {},
                localView: CallCameraView(front, key: localKey),
                remoteView: CallCameraView(peer),
                controls: const SizedBox(height: 70)))));
    await tester.pumpAndSettle();
    final local = find.byKey(localKey);
    expect(
        tester
            .widgetList<VideoTrackRenderer>(find.byType(VideoTrackRenderer))
            .map((view) => view.fit),
        containsAll([VideoViewFit.contain, VideoViewFit.cover]));
    await tester.tap(find.byTooltip('铺满画面'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<VideoTrackRenderer>(find.byType(VideoTrackRenderer))
            .map((view) => view.fit),
        everyElement(VideoViewFit.cover));
    await tester.tap(find.byKey(const ValueKey('friend-video-preview')));
    await tester.pumpAndSettle();
    expect(tester.getSize(local), const Size(390, 844));
    expect(
        tester
            .widget<rtc.RTCVideoView>(find.descendant(
                of: local, matching: find.byType(rtc.RTCVideoView)))
            .mirror,
        true);
    expect(calls.where((method) => method == 'getUserMedia').length, 2);
    await tester.tap(find.byTooltip('完整画面'));
    await tester.pumpAndSettle();
    expect(
        tester
            .widgetList<VideoTrackRenderer>(find.byType(VideoTrackRenderer))
            .map((view) => view.fit),
        containsAll([VideoViewFit.contain, VideoViewFit.cover]));
    expect(front.mediaStreamTrack.getSettings()['facingMode'], 'user');
    expect(calls, isNot(contains('mediaStreamTrackSetEnable')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await screen.dispose();
      await peer.dispose();
      await front.dispose();
      await back.dispose();
    });
  });
}
