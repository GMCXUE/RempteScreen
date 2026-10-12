import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:remotescreen/call_video_quality.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('切换路径的旧带宽估计保留恢复期，实际低帧率仍立即降档', () {
    final policy = CallQualityPolicy(3)..tier = 3;
    policy.routeChanged();
    for (var i = 0; i < 4; i++) {
      policy.sample(bandwidth: 300000, loss: 0, fps: 30);
      expect(policy.tier, 3);
    }
    policy.routeChanged();
    policy.sample(bandwidth: 300000, loss: 0, fps: 10);
    expect(policy.tier, lessThan(3));
  });

  test('四档都修改同一个RTP发送器，保持30fps，不重新采集或连接', () async {
    const channel = MethodChannel('FlutterWebRTC.Method');
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'getUserMedia') {
        return {
          'streamId': 'camera-stream',
          'ownerTag': 'local',
          'audioTracks': [],
          'videoTracks': [
            {
              'id': 'camera-track',
              'label': 'camera',
              'kind': 'video',
              'enabled': true,
              'settings': {'width': 1920, 'height': 1080, 'facingMode': 'user'}
            }
          ]
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final track = await LocalVideoTrack.createCameraTrack();
    final sender = _Sender();
    track.transceiver = _Transceiver(sender);
    final captureCalls = List<String>.of(calls);
    for (final tier in [3, 2, 1, 0, 3]) {
      expect(await applyCallVideoTier(track, tier, 1080), isTrue);
      final encoding = sender.parameters.encodings!.single;
      expect(encoding.maxFramerate, 30);
      expect(encoding.maxBitrate, callQualityBitrates[tier]);
      expect(encoding.scaleResolutionDownBy, 1080 / callQualityHeights[tier]);
      expect(encoding.active, isFalse, reason: '档位调整不更改SDK的启用/暂停状态');
      expect(encoding.rid, 'unchanged');
      expect(identical(track.sender, sender), isTrue);
      expect(track.mediaStreamTrack.id, 'camera-track');
    }
    expect(await applyCallVideoTier(track, 4, 1080), isFalse);
    expect(sender.updates, 5);
    expect(calls, captureCalls);
    expect(calls.where((method) => method == 'getUserMedia'), hasLength(1));
    await track.dispose();
  });
  final cases = jsonDecode(
      File('../../config/call-video-quality-test-cases.json')
          .readAsStringSync()) as List;
  for (final item in cases) {
    test(item['name'] as String, () {
      final policy = CallQualityPolicy(item['maximum'] as int);
      for (final step in item['steps']) {
        for (var i = 0; i < step['repeat']; i++) {
          policy.sample(
              bandwidth: (step['bandwidth'] as num?)?.toDouble(),
              loss: (step['loss'] as num?)?.toDouble(),
              fps: (step['fps'] as num?)?.toDouble(),
              cpuLimited: step['cpu'] == true);
        }
        expect(policy.tier, step['tier']);
      }
    });
  }
}

class _Sender extends Fake implements rtc.RTCRtpSender {
  @override
  final parameters = rtc.RTCRtpParameters(
      encodings: [rtc.RTCRtpEncoding(rid: 'unchanged', active: false)],
      transactionId: 'unchanged');
  int updates = 0;
  @override
  Future<bool> setParameters(rtc.RTCRtpParameters value) async {
    expect(identical(value, parameters), isTrue);
    expect(value.transactionId, 'unchanged');
    updates++;
    return true;
  }
}

class _Transceiver extends Fake implements rtc.RTCRtpTransceiver {
  _Transceiver(this.sender);
  @override
  final rtc.RTCRtpSender sender;
}
