import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:remotescreen/direct_media.dart';
import 'package:remotescreen/call_video_quality.dart';
import 'package:remotescreen/call_video_options.dart';

void main() {
  runApp(const MaterialApp(home: Harness()));
}

class Harness extends StatefulWidget {
  const Harness({super.key});
  @override
  State<Harness> createState() => _HarnessState();
}

class _HarnessState extends State<Harness> {
  Room? room;
  DirectMedia? route;
  CallVideoQuality? quality;
  Timer? timer;
  bool busy = false;
  String status = 'waiting';
  @override
  void initState() {
    super.initState();
    unawaited(connect());
  }

  Future<void> connect() async {
    try {
      Map<String, dynamic>? config;
      for (var i = 0; i < 180; i++) {
        final response = await http.get(Uri.base.resolve('/interop-config'));
        if (response.statusCode == 200) {
          config = jsonDecode(response.body);
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (config == null) throw StateError('native publisher not ready');
      final r = Room(
          roomOptions:
              const RoomOptions(adaptiveStream: false, dynacast: true));
      room = r;
      await r.connect(config['url'], config['token']);
      if (config['reverse'] == true) {
        // Test launcher forces synthetic Chrome devices; never real capture.
        final camera =
            await LocalVideoTrack.createCameraTrack(callCameraCaptureOptions);
        await r.localParticipant!
            .publishVideoTrack(camera, publishOptions: callVideoPublishOptions);
        final microphone = await LocalAudioTrack.create(
            const AudioCaptureOptions(
                echoCancellation: false,
                noiseSuppression: false,
                autoGainControl: false));
        await r.localParticipant!.publishAudioTrack(microphone);
      }
      if (config['quality'] == true) {
        route = DirectMedia(r, peerIdentity: config['peer']);
        quality = CallVideoQuality(r,
            peerIdentity: config['peer'], mediaRoute: route);
      } else {
        // Establish full-resolution SFU quality before probing a second encoder.
        var stable = 0;
        for (var attempt = 0; attempt < 50 && stable < 3; attempt++) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final cameras = r.remoteParticipants.values
              .expand((p) => p.videoTrackPublications)
              .where((p) => p.source == TrackSource.camera);
          final track = cameras.firstOrNull?.track;
          final stats = await track?.receiver?.getStats();
          final good = stats?.any((s) =>
                  s.type == 'inbound-rtp' &&
                  s.values['frameWidth'] == 1920 &&
                  s.values['frameHeight'] == 1080 &&
                  ((s.values['framesPerSecond'] as num?) ?? 0) >= 27) ??
              false;
          stable = good ? stable + 1 : 0;
        }
        if (stable < 3) {
          throw StateError(
              'SFU baseline must reach 1080p30 before direct probe');
        }
        route = DirectMedia(r, peerIdentity: config['peer']);
      }
      r.addListener(changed);
      route!.addListener(changed);
      timer = Timer.periodic(
          const Duration(seconds: 1), (_) => unawaited(report()));
      status = 'connected';
      changed();
    } catch (error) {
      status = error.toString();
      changed();
      await http.post(Uri.base.resolve('/result'),
          body: jsonEncode({'error': status}));
    }
  }

  void changed() {
    if (room != null && route != null) {
      for (final p in room!.remoteParticipants.values
          .expand((p) => p.audioTrackPublications)) {
        final track = route!.resolve(p);
        if (track is RemoteAudioTrack && route!.isReceiving(p.sid)) {
          unawaited(track.enable());
        }
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> report() async {
    if (busy) return;
    busy = true;
    try {
      final tracks = <Map<String, dynamic>>[];
      var sfuBytes = 0;
      for (final peer in room!.remoteParticipants.values) {
        for (final p in peer.trackPublications.values) {
          final original = await p.track?.receiver?.getStats();
          for (final report in original ?? []) {
            if (report.type == 'inbound-rtp') {
              sfuBytes +=
                  (report.values['bytesReceived'] as num?)?.toInt() ?? 0;
            }
          }
          final track = route!.resolve(p);
          if (track == null) continue;
          final raw = await track.receiver?.getStats();
          final reports = raw
              ?.where((r) => r.type == 'inbound-rtp')
              .map((r) => r.values)
              .toList();
          tracks.add({
            'sid': p.sid,
            'trackId': track.mediaStreamTrack.id,
            'source': p.source.name,
            'direct': route!.isReceiving(p.sid),
            'stats': reports
          });
        }
      }
      await http.post(Uri.base.resolve('/result'),
          body: jsonEncode({
            'state': room!.connectionState.name,
            'sfuBytes': sfuBytes,
            'tracks': tracks,
            'route': await route!.diagnostic()
          }));
    } catch (error) {
      await http.post(Uri.base.resolve('/result'),
          body: jsonEncode({'error': error.toString()}));
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final videos = <Widget>[];
    if (room != null && route != null) {
      for (final peer in room!.remoteParticipants.values) {
        for (final p in peer.videoTrackPublications) {
          final track = route!.resolve(p);
          if (track is RemoteVideoTrack) {
            videos.add(Expanded(
                child: VideoTrackRenderer(track,
                    key: ValueKey('${p.sid}:${track.mediaStreamTrack.id}'))));
          }
        }
      }
    }
    return Scaffold(body: Column(children: [Text(status), ...videos]));
  }

  @override
  void dispose() {
    timer?.cancel();
    quality?.close();
    room?.removeListener(changed);
    route?.removeListener(changed);
    unawaited(route?.close() ?? Future.value());
    unawaited(room?.dispose() ?? Future.value());
    super.dispose();
  }
}
