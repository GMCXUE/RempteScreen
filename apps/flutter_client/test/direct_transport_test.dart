import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:remotescreen/direct_transport.dart';

class _Sender extends Fake implements rtc.RTCRtpSender {
  @override
  final parameters = rtc.RTCRtpParameters(
      transactionId: 'kept',
      encodings: [rtc.RTCRtpEncoding(rid: 'kept', active: true)]);
  @override
  rtc.MediaStreamTrack? track;
  @override
  Future<void> replaceTrack(rtc.MediaStreamTrack? value) async {
    track = value;
  }

  @override
  Future<bool> setParameters(rtc.RTCRtpParameters value) async {
    expect(identical(value, parameters), true);
    return true;
  }
}

class _Transceiver extends Fake implements rtc.RTCRtpTransceiver {
  @override
  final sender = _Sender();
  List<String> codecs = [];
  @override
  Future<void> setCodecPreferences(
      List<rtc.RTCRtpCodecCapability> value) async {
    codecs = value.map((c) => c.mimeType).toList();
  }
}

class _Pc extends Fake implements rtc.RTCPeerConnection {
  final created = <_Transceiver>[];
  final kinds = <rtc.RTCRtpMediaType>[];
  @override
  Function(rtc.RTCTrackEvent)? onTrack;
  @override
  rtc.RTCPeerConnectionState get connectionState =>
      rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected;
  bool closed = false, disposed = false;
  rtc.RTCSessionDescription? local;
  @override
  rtc.RTCIceGatheringState get iceGatheringState =>
      rtc.RTCIceGatheringState.RTCIceGatheringStateComplete;
  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver(
      {rtc.MediaStreamTrack? track,
      rtc.RTCRtpMediaType? kind,
      rtc.RTCRtpTransceiverInit? init}) async {
    kinds.add(kind!);
    expect(init!.direction, rtc.TransceiverDirection.SendRecv);
    expect(init.sendEncodings!.single.active, false);
    final t = _Transceiver();
    t.sender.parameters.encodings!.single.active = false;
    created.add(t);
    return t;
  }

  @override
  Future<rtc.RTCSessionDescription> createOffer(
          [Map<String, dynamic>? constraints]) async =>
      rtc.RTCSessionDescription('local-offer', 'offer');
  @override
  Future<rtc.RTCSessionDescription> createAnswer(
          [Map<String, dynamic>? constraints]) async =>
      rtc.RTCSessionDescription('local-answer', 'answer');
  @override
  Future<void> setLocalDescription(rtc.RTCSessionDescription value) async {
    local = value;
  }

  @override
  Future<rtc.RTCSessionDescription?> getLocalDescription() async => local;
  @override
  Future<void> setRemoteDescription(rtc.RTCSessionDescription value) async {}
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() => messenger.setMockMethodCallHandler(
      channel,
      (call) async => {
            'codecs': [
              {'mimeType': 'video/H264', 'clockRate': 90000},
              {'mimeType': 'video/VP8', 'clockRate': 90000}
            ],
            'headerExtensions': [],
            'fecMechanisms': []
          }));
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('四种媒体来源固定，摄像头 H264 与屏幕 VP8 分开协商', () async {
    final pc = _Pc();
    final link = await DirectTransport.create(factory: (config) async {
      expect(config['iceServers'], isEmpty);
      return pc;
    });
    expect(
        directMediaSources, ['microphone', 'camera', 'screen', 'screen_audio']);
    expect(pc.created, hasLength(4));
    await link.activate();
    expect(pc.created[1].codecs, ['video/H264']);
    expect(pc.created[2].codecs, ['video/VP8']);
    expect(await link.offer(), 'local-offer');
    expect(await link.answer('remote-offer'), 'local-answer');
    await link.acceptAnswer('remote-answer');
    await link.close();
    await link.close();
    expect(pc.closed && pc.disposed, true);
  });
  test('复制四档参数保留直连 active、RID 和 transactionId，单独暂停发送器', () async {
    final pc = _Pc();
    final link = await DirectTransport.create(factory: (_) async => pc);
    await link.activate();
    for (final tuple in [
      (3500000, 1.0),
      (2000000, 1.5),
      (650000, 3.0),
      (200000, 6.0)
    ]) {
      await link.copyEncoding(
          1,
          rtc.RTCRtpParameters(encodings: [
            rtc.RTCRtpEncoding(
                active: false,
                maxBitrate: tuple.$1,
                maxFramerate: 30,
                scaleResolutionDownBy: tuple.$2)
          ]));
      final params = pc.created[1].sender.parameters;
      expect(params.encodings!.single.active, true);
      expect(params.encodings!.single.rid, 'kept');
      expect(params.transactionId, 'kept');
      expect(params.encodings!.single.maxBitrate, tuple.$1);
      expect(params.encodings!.single.maxFramerate, 30);
    }
    await setDirectSenderActive(pc.created[1].sender, false);
    expect(pc.created[1].sender.parameters.encodings!.single.active, false);
    await setDirectSenderActive(pc.created[1].sender, true);
    expect(pc.created[1].sender.parameters.encodings!.single.active, true);
    await expectLater(
        link.acceptAnswer('x' * (directMaxSdp + 1)), throwsStateError);
    await link.close();
  });
  test('TURN 配置不会偷偷建立中继直连', () async {
    await expectLater(DirectTransport.create(stunUrls: ['turn:example.test']),
        throwsStateError);
  });
}
