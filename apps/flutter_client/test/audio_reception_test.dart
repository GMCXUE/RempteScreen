import 'dart:async';
import 'dart:collection';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:remotescreen/call_controller.dart';

class _Room extends Room {
  final peers = <String, RemoteParticipant>{};
  @override
  UnmodifiableMapView<String, RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(peers);
  void changed() => notifyListeners();
}

class _Peer extends Fake implements RemoteParticipant {
  _Peer(this.identity, this.audioTrackPublications);
  @override
  final String identity;
  @override
  final List<RemoteTrackPublication<RemoteAudioTrack>> audioTrackPublications;
  @override
  List<RemoteTrackPublication<RemoteVideoTrack>> get videoTrackPublications => [];
}

class _Publication extends Fake implements RemoteTrackPublication<RemoteAudioTrack> {
  _Publication(this.source);
  @override
  final TrackSource source;
  @override
  bool enabled = true;
  @override
  RemoteAudioTrack? get track => null;
  int pauses = 0, resumes = 0;
  Completer<void>? gate;
  @override
  Future<void> disable() async {
    enabled = false;
    pauses++;
    await gate?.future;
  }

  @override
  Future<void> enable() async {
    enabled = true;
    resumes++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('声音开关分别暂停麦克风和投屏音频，保留订阅并处理迟到音轨', () async {
    final room = _Room();
    final mic = _Publication(TrackSource.microphone);
    final screen = _Publication(TrackSource.screenShareAudio);
    final other = _Publication(TrackSource.microphone);
    final publications = <RemoteTrackPublication<RemoteAudioTrack>>[mic, screen];
    room.peers['peer'] = _Peer('peer', publications);
    room.peers['other'] = _Peer('other', [other]);
    final controller = CallController(room, peerIdentity: 'peer');
    await controller.toggleSpeaker();
    expect(mic.enabled, false);
    expect(screen.enabled, true);
    expect(other.enabled, true);
    final late = _Publication(TrackSource.microphone);
    publications.add(late);
    room.changed();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(late.enabled, false);
    await controller.toggleScreenAudio();
    expect(screen.enabled, false);
    await controller.toggleSpeaker();
    expect(mic.enabled, true);
    expect(late.enabled, true);
    expect(screen.enabled, false);
    await controller.toggleScreenAudio();
    expect(screen.enabled, true);
    expect(identical(publications.first, mic), true);
    expect(mic.pauses, 1);
    expect(mic.resumes, 1);
    controller.close();
    await room.dispose();
  });
  test('快速连续操作以最后一个开关状态为准', () async {
    final room = _Room();
    final mic = _Publication(TrackSource.microphone)..gate = Completer<void>();
    room.peers['peer'] = _Peer('peer', [mic]);
    final controller = CallController(room, peerIdentity: 'peer');
    final pause = controller.toggleSpeaker();
    await Future<void>.delayed(Duration.zero);
    final resume = controller.toggleSpeaker();
    mic.gate!.complete();
    await Future.wait([pause, resume]);
    expect(mic.enabled, true);
    expect(mic.resumes, 1);
    controller.close();
    await room.dispose();
  });
}
