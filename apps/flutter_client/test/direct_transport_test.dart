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

class _Track extends Fake implements rtc.MediaStreamTrack {
  _Track(this.kind);
  @override
  final String kind;
}

class _Receiver extends Fake implements rtc.RTCRtpReceiver {
  _Receiver(String kind) : track = _Track(kind);
  @override
  final rtc.MediaStreamTrack track;
}

class _Transceiver extends Fake implements rtc.RTCRtpTransceiver {
  _Transceiver({this.mid = '', String kind = 'video'})
      : receiver = _Receiver(kind);
  @override
  final String mid;
  @override
  final rtc.RTCRtpReceiver receiver;
  rtc.TransceiverDirection direction = rtc.TransceiverDirection.RecvOnly;
  @override
  Future<void> setDirection(rtc.TransceiverDirection value) async {
    direction = value;
  }

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
  final negotiated = <_Transceiver>[];
  @override
  Future<List<rtc.RTCRtpTransceiver>> getTransceivers() async => negotiated;
  @override
  rtc.RTCIceGatheringState get iceGatheringState =>
      rtc.RTCIceGatheringState.RTCIceGatheringStateComplete;
  @override
  Future<rtc.RTCRtpTransceiver> addTransceiver(
      {rtc.MediaStreamTrack? track,
      rtc.RTCRtpMediaType? kind,
      rtc.RTCRtpTransceiverInit? init}) async {
    kinds.add(kind!);
    expect(
        init!.direction,
        created.length < 4
            ? rtc.TransceiverDirection.SendOnly
            : rtc.TransceiverDirection.RecvOnly);
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
  Future<void> setRemoteDescription(rtc.RTCSessionDescription value) async {
    if (value.type == 'offer') {
      for (var index = 0; index < 8; index++) {
        negotiated.add(_Transceiver(
            mid: '$index',
            kind: index % 4 == 1 || index % 4 == 2 ? 'video' : 'audio'));
      }
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

final validRemoteSdp = [
  'v=0\r\n',
  for (var slot = 0; slot < 8; slot++)
    'm=${slot % 4 == 1 || slot % 4 == 2 ? 'video' : 'audio'} 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:$slot\r\na=${slot < 4 ? 'sendonly' : 'recvonly'}\r\n'
].join();

final validRemoteAnswer = validRemoteSdp
    .replaceAll('a=sendonly', 'a=temporary')
    .replaceAll('a=recvonly', 'a=sendonly')
    .replaceAll('a=temporary', 'a=recvonly');

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
              {'mimeType': 'video/VP8', 'clockRate': 90000},
              {'mimeType': 'video/rtx', 'clockRate': 90000},
              {'mimeType': 'video/red', 'clockRate': 90000},
              {'mimeType': 'video/ulpfec', 'clockRate': 90000}
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
    expect(pc.created, hasLength(8));
    await link.activate();
    expect(pc.created[1].codecs,
        ['video/H264', 'video/rtx', 'video/red', 'video/ulpfec']);
    expect(pc.created[2].codecs,
        ['video/VP8', 'video/rtx', 'video/red', 'video/ulpfec']);
    expect(await link.offer(), 'local-offer');

    await link.acceptAnswer(validRemoteAnswer);
    await link.close();
    await link.close();
    expect(pc.closed && pc.disposed, true);
  });
  test('回答端把发送器绑定到 offer 的实际 MID，避免新建未关联槽位', () async {
    final pc = _Pc();
    final link =
        await DirectTransport.create(answerer: true, factory: (_) async => pc);
    expect(pc.created, isEmpty);
    await link.prepareAnswer(validRemoteSdp);
    expect(link.slots, pc.negotiated.skip(4));
    expect(pc.negotiated.take(4).map((t) => t.direction),
        everyElement(rtc.TransceiverDirection.RecvOnly));
    expect(pc.negotiated.skip(4).map((t) => t.direction),
        everyElement(rtc.TransceiverDirection.SendOnly));
    expect(link.sourceForMid('0'), 0);
    expect(link.sourceForMid('4'), null);
    expect(await link.finishAnswer(), 'local-answer');
    expect(
        pc.negotiated
            .skip(4)
            .map((t) => t.sender.parameters.encodings!.single.active),
        everyElement(false));
    await link.close();
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
    await expectLater(
        link.acceptAnswer(
            '${validRemoteSdp}m=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:4\r\n'),
        throwsStateError);
    await expectLater(
        link.acceptAnswer(validRemoteAnswer.replaceFirst('a=mid:1', 'a=mid:2')),
        throwsStateError);
    await link.close();
  });
  test('好友通话直连沿用原有独立音频工厂', () async {
    final pc = _Pc();
    final link = await DirectTransport.create(
        friendCallAudio: true,
        factory: (config) async {
          expect(config['friendCallAudio'], true);
          return pc;
        });
    await link.close();
  });
  test('TURN 配置不会偷偷建立中继直连', () async {
    await expectLater(DirectTransport.create(stunUrls: ['turn:example.test']),
        throwsStateError);
  });
}
