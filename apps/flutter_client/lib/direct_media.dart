import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart';
import 'direct_transport.dart';

int? _slot(TrackSource source, TrackType kind, String name) =>
    switch ((source, kind)) {
      (TrackSource.microphone, TrackType.AUDIO) => 0,
      (TrackSource.camera, TrackType.VIDEO) => 1,
      (TrackSource.screenShareVideo, TrackType.VIDEO) => 2,
      (TrackSource.screenShareAudio, TrackType.AUDIO) => 3,
      (TrackSource.unknown, TrackType.VIDEO) when name == 'screen' => 2,
      (TrackSource.unknown, TrackType.AUDIO) => 3,
      _ => null,
    };

class _VideoSample {
  _VideoSample(this.width, this.height, this.fps, this.loss, this.frames);
  final int width, height, frames;
  final double fps, loss;
  static _VideoSample fromStats(List<rtc.StatsReport> stats) {
    for (final report in stats) {
      final r = report.values;
      if (report.type != 'inbound-rtp' ||
          (r['kind'] != 'video' &&
              r['mediaType'] != 'video' &&
              r['framesDecoded'] == null)) {
        continue;
      }
      final received = (r['packetsReceived'] as num?)?.toInt() ?? 0,
          lost = ((r['packetsLost'] as num?)?.toInt() ?? 0).clamp(0, 1 << 60);
      return _VideoSample(
          (r['frameWidth'] as num?)?.toInt() ?? 0,
          (r['frameHeight'] as num?)?.toInt() ?? 0,
          (r['framesPerSecond'] as num?)?.toDouble() ?? 0,
          received > 0 ? lost / (received + lost) : 0,
          (r['framesDecoded'] as num?)?.toInt() ?? 0);
    }
    return _VideoSample(0, 0, 0, 0, 0);
  }
}

class _Link {
  _Link(this.transport, this.id);
  final DirectTransport transport;
  final String id;
  final clock = Stopwatch()..start();
  Duration? activated, baselineSince;
  bool prepared = false, peerPrepared = false;
  bool readySent = false,
      peerReady = false,
      active = false,
      peerActive = false,
      fallback = false;
  final receivers = <int, RemoteTrack>{};
  final baseline = <int, _VideoSample>{};
  final observed = <int, (int, int, Duration)>{};
  StreamSubscription<rtc.RTCTrackEvent>? subscription;
  final ownedStreams = <rtc.MediaStream>[];
  bool closed = false;
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await subscription?.cancel();
    for (final track in receivers.values) {
      try {
        await track.dispose();
      } catch (_) {}
    }
    receivers.clear();
    try {
      await transport.close();
    } finally {
      for (final stream in ownedStreams) {
        try {
          await stream.dispose();
        } catch (_) {}
      }
      ownedStreams.clear();
    }
  }
}

/// Room authority/SIDs stay unchanged. Only a verified one-to-one path takes over.
class DirectMedia extends ChangeNotifier {
  DirectMedia(this.room, {this.peerIdentity, this.friendCallAudio = false}) {
    _events = room.createListener()..on<DataReceivedEvent>(_receive);
    room.addListener(_changed);
    _timer = Timer.periodic(
        const Duration(milliseconds: 250), (_) => unawaited(_tick()));
  }
  final Room room;
  final String? peerIdentity;
  final bool friendCallAudio;
  late final EventsListener<RoomEvent> _events;
  late final Timer _timer;
  _Link? _link;
  Completer<void>? _idle;
  bool _closed = false, _busy = false, _capable = false, _attempted = false;
  bool speakerEnabled = true, screenAudioEnabled = true;
  String _topology = '';
  Duration _topologySince = Duration.zero;
  int _hellos = 0;
  final _clock = Stopwatch()..start();
  Duration _lastHello = const Duration(seconds: -5);
  final _messages = <Map<String, dynamic>>[];
  final _routed = <String, RemoteTrack>{};
  final _pausedSenders = <String, LocalTrack>{};
  final _pausedPublications = <String, RemoteTrackPublication>{};
  bool isReceiving(String sid) => _routed.containsKey(sid);
  bool isSending(String sid) => _pausedSenders.containsKey(sid);
  RemoteTrack? resolve(RemoteTrackPublication publication) =>
      _routed[publication.sid] ?? publication.track;
  rtc.RTCRtpSender? senderFor(String sid, rtc.RTCRtpSender? original) {
    if (!isSending(sid)) return original;
    final publication = room.localParticipant?.getTrackPublicationBySid(sid);
    if (publication == null) return original;
    final slot = _slot(publication.source, publication.kind, publication.name);
    return slot == null
        ? original
        : _link?.transport.slots[slot].sender ?? original;
  }

  Future<Map<String, Object?>> diagnostic() async {
    final link = _link;
    if (link == null) return {'link': false};
    final tracks = <String, Object?>{};
    for (final entry in link.receivers.entries) {
      final stats = await entry.value.receiver?.getStats();
      tracks['${entry.key}'] = stats
          ?.where((s) => s.type == 'inbound-rtp')
          .map((s) => s.values)
          .toList();
    }
    return {
      'pc': link.transport.pc.connectionState.toString(),
      'activated': link.activated != null,
      'ready': link.readySent,
      'peerReady': link.peerReady,
      'active': link.active,
      'baseline': {
        for (final e in link.baseline.entries)
          '${e.key}': '${e.value.width}x${e.value.height}@${e.value.fps}'
      },
      'tracks': tracks
    };
  }

  void requestFallback() => _link?.fallback = true;
  void _changed() => unawaited(_tick());
  RemoteParticipant? get _peer {
    if (room.remoteParticipants.length != 1) return null;
    final peer = room.remoteParticipants.values.single;
    return peerIdentity == null || peer.identity == peerIdentity ? peer : null;
  }

  void _receive(DataReceivedEvent event) {
    if (_closed ||
        event.topic != directMediaTopic ||
        event.participant == null ||
        _peer == null ||
        event.participant!.identity != _peer!.identity ||
        event.data.length > directMaxSdp + 1024 ||
        _messages.length >= 8) {
      return;
    }
    try {
      final data = jsonDecode(utf8.decode(event.data));
      if (data is! Map ||
          data['v'] != 2 ||
          data['kind'] is! String ||
          ![
            'hello',
            'offer',
            'answer',
            'prepared',
            'ready',
            'active',
            'fallback'
          ].contains(data['kind'])) {
        return;
      }
      final id = data['id'] ?? '';
      final sdp = data['sdp'];
      final topology = data['topology'];
      if (topology != null &&
          (topology is! String || utf8.encode(topology).length > 512)) {
        return;
      }
      if (id is! String ||
          utf8.encode(id).length > 96 ||
          (data['kind'] != 'hello' && id.isEmpty) ||
          (sdp != null &&
              (sdp is! String ||
                  sdp.isEmpty ||
                  utf8.encode(sdp).length > directMaxSdp))) {
        return;
      }
      _messages.add({
        ...Map<String, dynamic>.from(data),
        '_from': event.participant!.identity
      });
      unawaited(_tick());
    } catch (_) {/* Invalid control packets cannot disturb the SFU call. */}
  }

  Future<void> _send(RemoteParticipant peer, String kind, String id,
      [String? sdp]) async {
    if (_closed) return;
    try {
      await room.localParticipant?.publishData(
          utf8.encode(jsonEncode({
            'v': 2,
            'kind': kind,
            'id': id,
            'topology': _signature(peer),
            if (sdp != null) 'sdp': sdp
          })),
          topic: directMediaTopic,
          reliable: true,
          destinationIdentities: [
            peer.identity
          ]).timeout(const Duration(seconds: 1));
    } catch (_) {}
  }

  Future<void> _reset() async {
    for (final track in _pausedSenders.values) {
      try {
        final sender = track.sender;
        if (sender != null) {
          await replaceDirectSenderTrack(sender, track.mediaStreamTrack);
          await setDirectSenderActive(sender, true);
        }
      } catch (_) {}
    }
    _pausedSenders.clear();
    _routed.clear();
    for (final p in _pausedPublications.values) {
      try {
        if (p.kind == TrackType.VIDEO) {
          await p.enable();
        } else {
          final wanted = p.source == TrackSource.microphone
              ? speakerEnabled
              : screenAudioEnabled;
          if (wanted) {
            await p.enable();
            if (p.track is RemoteAudioTrack) {
              await (p.track as RemoteAudioTrack).enable();
            }
          } else {
            await p.disable();
          }
        }
      } catch (_) {}
    }
    _pausedPublications.clear();
    final old = _link;
    _link = null;
    if (!_closed) notifyListeners();
    await old?.close();
  }

  bool _supportedSources(RemoteParticipant peer) {
    for (final publications in <Iterable<TrackPublication>>[
      room.localParticipant?.trackPublications.values ??
          <LocalTrackPublication>[],
      peer.trackPublications.values
    ]) {
      final seen = <int>{};
      for (final p in publications) {
        final index = _slot(p.source, p.kind, p.name);
        if (index == null || !seen.add(index)) return false;
      }
    }
    return true;
  }

  String _signature(RemoteParticipant peer) {
    final values = [
      for (final p in room.localParticipant?.trackPublications.values ??
          <LocalTrackPublication>[])
        '${p.sid}:${p.muted}',
      for (final p in peer.trackPublications.values) '${p.sid}:${p.muted}'
    ]..sort();
    return values.join(',');
  }

  Future<_Link> _newLink(String id, {bool answerer = false}) async {
    final transport = await DirectTransport.create(
        stunUrls: const ['stun:stun.l.google.com:19302'],
        friendCallAudio: friendCallAudio,
        answerer: answerer);
    if (_closed) {
      await transport.close();
      throw StateError('direct media closed');
    }
    final link = _Link(transport, id);
    link.subscription = transport.tracks.stream.listen((event) => unawaited(
          _track(link, event).catchError((Object error) {
            if (!link.closed) {
              link.fallback = true;
              debugPrint('[direct-media] track fallback: $error');
            }
          }),
        ));
    return link;
  }

  Future<void> _track(_Link link, rtc.RTCTrackEvent event) async {
    if (_closed || link.closed || _link != link) return;
    // onTrack arrives during SDP negotiation, before activation can send audio.
    if (event.track.kind == 'audio') event.track.enabled = false;
    final index = link.transport.sourceForMid(event.transceiver?.mid ?? '');
    debugPrint(
        '[direct-media] track slot=$index kind=${event.track.kind} receiver=${event.receiver != null}');
    if (index == null ||
        index < 0 ||
        index > 3 ||
        (event.track.kind == 'video') != (index == 1 || index == 2) ||
        event.receiver == null) {
      return;
    }
    rtc.MediaStream stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      stream = await rtc.createLocalMediaStream('rs-direct-$index');
      if (_closed || link.closed || _link != link) {
        await stream.dispose();
        return;
      }
      link.ownedStreams.add(stream);
      await stream.addTrack(event.track);
    }
    if (_closed || link.closed || _link != link) {
      return;
    }
    final source = [
      TrackSource.microphone,
      TrackSource.camera,
      TrackSource.screenShareVideo,
      TrackSource.screenShareAudio
    ][index];
    final RemoteTrack track = event.track.kind == 'video'
        ? RemoteVideoTrack(source, stream, event.track,
            receiver: event.receiver)
        : RemoteAudioTrack(source, stream, event.track,
            receiver: event.receiver);
    await track.start();
    if (_closed || link.closed || _link != link) {
      await track.dispose();
      return;
    }
    final previous = link.receivers[index];
    link.receivers[index] = track;
    await previous?.dispose();
  }

  Future<void> _syncTracks(_Link link) async {
    final pubs = room.localParticipant?.trackPublications.values.toList() ??
        <LocalTrackPublication>[];
    for (var index = 0; index < 4; index++) {
      LocalTrack? track;
      for (final p in pubs) {
        if (!p.muted && _slot(p.source, p.kind, p.name) == index) {
          track = p.track;
          break;
        }
      }
      final sender = link.transport.slots[index].sender;
      if (sender.track?.id != track?.mediaStreamTrack.id) {
        await link.transport.replaceTrack(index, track?.mediaStreamTrack,
            stream: track?.mediaStream);
      }
      if (track?.sender != null) {
        await link.transport.copyEncoding(index, track!.sender!.parameters);
      }
    }
  }

  Future<bool> _baseline(_Link link, RemoteParticipant peer) async {
    for (final p in peer.videoTrackPublications) {
      final index = _slot(p.source, p.kind, p.name);
      if (index == null || p.muted) continue;
      final track = p.track;
      if (track == null || track.receiver == null) {
        link.baselineSince = null;
        return false;
      }
      final stats = await track.receiver!
          .getStats()
          .timeout(const Duration(milliseconds: 500));
      final sample = _VideoSample.fromStats(stats);
      if (sample.width == 0 ||
          sample.height == 0 ||
          sample.fps < (index == 1 ? 27 : 1) ||
          sample.loss > .01) {
        link.baselineSince = null;
        return false;
      }
      final old = link.baseline[index];
      if (old == null ||
          old.width != sample.width ||
          old.height != sample.height) {
        link.baselineSince = null;
      }
      link.baseline[index] = sample;
    }
    if (link.baseline.isEmpty) return true;
    link.baselineSince ??= link.clock.elapsed;
    return link.clock.elapsed - link.baselineSince! >=
        const Duration(seconds: 2);
  }

  Future<bool> _healthy(_Link link, RemoteParticipant peer) async {
    if (link.fallback ||
        link.transport.pc.connectionState !=
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      return false;
    }
    for (final p in peer.trackPublications.values) {
      final index = _slot(p.source, p.kind, p.name);
      if (index == null || p.muted) continue;
      final track = link.receivers[index];
      if (track?.receiver == null) return false;
      final stats = await track!.receiver!
          .getStats()
          .timeout(const Duration(milliseconds: 500));
      if (index == 1 || index == 2) {
        final sample = _VideoSample.fromStats(stats),
            base = link.baseline[index];
        if (base == null) return false;
        final size = sample.width * sample.height >= base.width * base.height &&
            (sample.width < sample.height ? sample.width : sample.height) >=
                (base.width < base.height ? base.width : base.height);
        final floor = index == 1 ? 27.0 : (base.fps * .9).clamp(1.0, 120.0);
        if (sample.frames > 0) {
          final old = link.observed[index];
          if (old == null || old.$1 != sample.frames) {
            link.observed[index] = (sample.frames, 0, link.clock.elapsed);
          }
        }
        if (!size ||
            sample.fps < floor ||
            sample.loss > .03 ||
            link.clock.elapsed - (link.observed[index]?.$3 ?? Duration.zero) >
                const Duration(milliseconds: 1200)) {
          return false;
        }
      } else {
        rtc.StatsReport? audio;
        for (final report in stats) {
          if (report.type == 'inbound-rtp' &&
              (report.values['kind'] == 'audio' ||
                  report.values['mediaType'] == 'audio')) {
            audio = report;
            break;
          }
        }
        final packets =
                (audio?.values['packetsReceived'] as num?)?.toInt() ?? 0,
            lost = (audio?.values['packetsLost'] as num?)?.toInt() ?? 0;
        if (packets == 0) return false;
        final old = link.observed[index];
        if (old == null || packets > old.$1) {
          if (old != null) {
            final drops = (lost - old.$2).clamp(0, 1 << 60);
            if (drops / (packets - old.$1 + drops) > .03) return false;
          }
          link.observed[index] = (packets, lost, link.clock.elapsed);
        }
        if (link.clock.elapsed - (link.observed[index]?.$3 ?? Duration.zero) >
            const Duration(seconds: 3)) {
          return false;
        }
      }
    }
    return true;
  }

  Future<void> _activate(_Link link, RemoteParticipant peer) async {
    if (_closed || link.closed || _link != link) return;
    for (final p in peer.trackPublications.values) {
      final index = _slot(p.source, p.kind, p.name);
      if (index == null || p.muted) continue;
      final track = link.receivers[index];
      if (track == null) throw StateError('missing direct receiver');
      if (p.track is RemoteAudioTrack) {
        await (p.track as RemoteAudioTrack).disable();
      }
      _routed[p.sid] = track;
      _pausedPublications[p.sid] = p;
      await p.disable();
    }
    for (final p in room.localParticipant?.trackPublications.values ??
        <LocalTrackPublication>[]) {
      if (p.muted ||
          _slot(p.source, p.kind, p.name) == null ||
          p.track?.sender == null) {
        continue;
      }
      final sender = p.track!.sender!;
      _pausedSenders[p.sid] = p.track!;
      await setDirectSenderActive(sender, false);
      // Release the inactive SFU encoder's source demand, keeping its publication.
      await replaceDirectSenderTrack(sender, null);
    }
    link.active = true;
    if (!_closed) notifyListeners();
  }

  Future<void> _tick() async {
    if (_closed || _busy) return;
    _busy = true;
    _idle = Completer<void>();
    try {
      final peer = _peer, local = room.localParticipant;
      if (peer == null ||
          local == null ||
          (room.connectionState != ConnectionState.connected &&
              _link?.active != true)) {
        if (_link != null) await _reset();
        _topology = '';
        _capable = false;
        _attempted = false;
        return;
      }
      if (!_supportedSources(peer)) {
        if (_link != null) await _reset();
        _topology = '';
        _attempted = true;
        return;
      }
      final current = _signature(peer);
      if (current != _topology) {
        await _reset();
        _topology = current;
        _topologySince = _clock.elapsed;
        _attempted = false;
        _hellos = 0;
      }
      if (local.trackPublications.isEmpty && peer.trackPublications.isEmpty) {
        return;
      }
      if (_hellos < 3 &&
          _clock.elapsed - _lastHello > const Duration(seconds: 2)) {
        await _send(peer, 'hello', '');
        _hellos++;
        _lastHello = _clock.elapsed;
      }
      while (_messages.isNotEmpty) {
        if (_messages.first['_from'] != peer.identity) {
          _messages.removeAt(0);
          continue;
        }
        final signal = _messages.removeAt(0),
            kind = signal['kind'],
            id = signal['id'] ?? '';
        if (kind != 'hello' && signal['topology'] != _topology) {
          if (kind == 'offer') await _send(peer, 'hello', '');
          continue;
        }
        if (kind == 'hello') {
          _capable = true;
        } else if (kind == 'offer' &&
            !_attempted &&
            _link == null &&
            peer.identity.compareTo(local.identity) < 0 &&
            signal['sdp'] is String) {
          _capable = true;
          _attempted = true;
          await _reset();
          final link = await _newLink(id, answerer: true);
          _link = link;
          await link.transport.prepareAnswer(signal['sdp']);
          await _syncTracks(link);
          final answer = await link.transport.finishAnswer();
          if (_signature(peer) == _topology && !_closed) {
            await _send(peer, 'answer', id, answer);
          } else {
            await _reset();
            return;
          }
        } else if (_link?.id == id) {
          final link = _link!;
          if (kind == 'answer' && signal['sdp'] is String) {
            await link.transport.acceptAnswer(signal['sdp']);
          } else if (kind == 'prepared') {
            link.peerPrepared = true;
          } else if (kind == 'ready') {
            link.peerReady = true;
          } else if (kind == 'active') {
            link.peerActive = true;
          } else if (kind == 'fallback') {
            debugPrint('[direct-media] peer fallback: ${await diagnostic()}');
            await _reset();
            _attempted = true;
          }
        }
      }
      if (_link == null &&
          _capable &&
          !_attempted &&
          _clock.elapsed - _topologySince >= const Duration(seconds: 1) &&
          local.identity.compareTo(peer.identity) < 0) {
        _attempted = true;
        final id = '${local.sid}-${DateTime.now().microsecondsSinceEpoch}';
        final link = await _newLink(id);
        _link = link;
        await _syncTracks(link);
        final offer = await link.transport.offer();
        if (_signature(peer) == _topology && !_closed) {
          await _send(peer, 'offer', id, offer);
        } else {
          await _reset();
          return;
        }
      }
      if (_closed) {
        await _reset();
        return;
      }
      final link = _link;
      if (link == null || link.closed) return;
      await _syncTracks(link);
      if (link.transport.pc.connectionState ==
              rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
          link.activated == null) {
        if (!link.prepared && await _baseline(link, peer)) {
          await _send(peer, 'prepared', link.id);
          link.prepared = true;
        }
        if (link.prepared && link.peerPrepared) {
          await link.transport.activate();
          link.activated = link.clock.elapsed;
        }
      }
      var failed = false;
      final activated = link.activated;
      if (activated != null) {
        final healthy = await _healthy(link, peer);
        if (healthy && !link.readySent) {
          await _send(peer, 'ready', link.id);
          link.readySent = true;
        }
        if (healthy && link.readySent && link.peerReady && !link.active) {
          await _activate(link, peer);
          await _send(peer, 'active', link.id);
        }
        if ((!healthy && link.active) ||
            (!link.active &&
                link.clock.elapsed - activated > const Duration(seconds: 6))) {
          failed = true;
        }
        if (link.active &&
            !link.peerActive &&
            link.clock.elapsed - activated > const Duration(seconds: 10)) {
          failed = true;
        }
      } else if (link.clock.elapsed > const Duration(seconds: 16)) {
        failed = true;
      }
      if (link.fallback ||
          [
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed,
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateClosed,
            rtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected
          ].contains(link.transport.pc.connectionState)) {
        failed = true;
      }
      if (failed) {
        debugPrint('[direct-media] fallback: ${await diagnostic()}');
        await _send(peer, 'fallback', link.id);
        await _reset();
        _attempted = true;
      }
    } catch (error) {
      if (!_closed) debugPrint('[direct-media] SFU fallback: $error');
      await _reset();
      _attempted = true;
    } finally {
      _busy = false;
      _idle?.complete();
      _idle = null;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer.cancel();
    room.removeListener(_changed);
    await _events.dispose();
    await _idle?.future;
    await _reset();
    super.dispose();
  }
}
