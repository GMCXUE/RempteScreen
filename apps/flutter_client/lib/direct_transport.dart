import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

// Fixed Unified Plan slots match Rust. SDP carries gathered host/srflx candidates.
const directMediaSources = ['microphone', 'camera', 'screen', 'screen_audio'];
const directMediaTopic = 'rs-direct-media-v2';
const directMaxSdp = 48 * 1024;

class DirectTransport {
  DirectTransport._(this.pc, this.answerer);
  final rtc.RTCPeerConnection pc;
  final bool answerer;
  final slots = <rtc.RTCRtpTransceiver>[];
  final tracks = StreamController<rtc.RTCTrackEvent>.broadcast();
  bool _closed = false;
  final _pendingEncoding = <int, rtc.RTCRtpParameters>{};

  static Future<DirectTransport> create(
      {List<String> stunUrls = const [],
      bool friendCallAudio = false,
      bool answerer = false,
      Future<rtc.RTCPeerConnection> Function(Map<String, dynamic>)?
          factory}) async {
    if (!stunUrls.every((s) => s.startsWith('stun:') && s.length <= 256)) {
      {
        throw StateError('invalid STUN configuration');
      }
    }
    final pc = await (factory ?? (config) => rtc.createPeerConnection(config))({
      'sdpSemantics': 'unified-plan',
      'friendCallAudio': friendCallAudio,
      'iceServers': [
        for (final url in stunUrls) {'urls': url}
      ],
    });
    final link = DirectTransport._(pc, answerer);
    try {
      pc.onTrack = (event) {
        if (!link._closed) link.tracks.add(event);
      };
      for (var physical = 0; physical < (answerer ? 0 : 8); physical++) {
        final slot = physical % 4;
        final video = slot == 1 || slot == 2;
        final transceiver = await pc.addTransceiver(
          kind: video
              ? rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo
              : rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: rtc.RTCRtpTransceiverInit(
              direction: physical < 4
                  ? rtc.TransceiverDirection.SendOnly
                  : rtc.TransceiverDirection.RecvOnly,
              sendEncodings: [
                rtc.RTCRtpEncoding(
                    active: false,
                    maxBitrate: slot == 1 ? 3500000 : null,
                    maxFramerate: slot == 1 ? 30 : null)
              ]),
        );
        await _configureVideoCodec(slot, transceiver, receiving: physical >= 4);
        if (physical < 4) {
          link.slots.add(transceiver);
        }
      }
      return link;
    } catch (_) {
      await link.close();
      rethrow;
    }
  }

  static Future<void> _configureVideoCodec(
      int slot, rtc.RTCRtpTransceiver transceiver,
      {bool receiving = false}) async {
    if (slot == 1 || slot == 2) {
      final preferred = slot == 1 ? 'video/h264' : 'video/vp8';
      final capabilities = receiving
          ? await rtc.getRtpReceiverCapabilities('video')
          : await rtc.getRtpSenderCapabilities('video');
      final codecs = capabilities.codecs
              ?.where((c) =>
                  c.mimeType.toLowerCase() == preferred ||
                  ['video/rtx', 'video/red', 'video/ulpfec', 'video/flexfec-03']
                      .contains(c.mimeType.toLowerCase()))
              .toList() ??
          [];
      if (!codecs.any((c) => c.mimeType.toLowerCase() == preferred)) {
        throw StateError('unsupported codec $preferred');
      }
      codecs.sort((a, b) {
        final primary = (a.mimeType.toLowerCase() == preferred ? 0 : 1)
            .compareTo(b.mimeType.toLowerCase() == preferred ? 0 : 1);
        if (primary != 0 || slot != 1) return primary;
        int h264Rank(rtc.RTCRtpCodecCapability c) =>
            c.sdpFmtpLine?.contains('profile-level-id=42e01f') == true &&
                    c.sdpFmtpLine?.contains('packetization-mode=0') == true
                ? 0
                : 1;
        return h264Rank(a).compareTo(h264Rank(b));
      });
      await transceiver.setCodecPreferences(codecs);
    }
  }

  int? sourceForMid(String mid) {
    final index = int.tryParse(mid), start = answerer ? 0 : 4;
    return index != null && index >= start && index < start + 4
        ? index % 4
        : null;
  }

  Future<void> activate() async {
    if (pc.connectionState !=
        rtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
      throw StateError('direct connection not ready');
    }
    for (final slot in slots) {
      await setDirectSenderActive(slot.sender, true);
    }
  }

  Future<void> replaceTrack(int slot, rtc.MediaStreamTrack? track,
      {rtc.MediaStream? stream}) async {
    if (slot < 0 || slot >= slots.length) {
      throw StateError('unknown media source');
    }
    if (track != null && (track.kind == 'video') != (slot == 1 || slot == 2)) {
      {
        throw StateError('media source kind mismatch');
      }
    }
    final sender = slots[slot].sender;
    await replaceDirectSenderTrack(sender, track);
    if (stream != null && track != null) await sender.setStreams([stream]);
  }

  Future<void> copyEncoding(int slot, rtc.RTCRtpParameters original) async {
    final sender = slots[slot].sender;
    final params = sender.parameters;
    if ((params.encodings?.isEmpty ?? true) &&
        original.encodings?.length == 1) {
      _pendingEncoding[slot] = original;
      return;
    }
    if (params.encodings?.length != 1 || original.encodings?.length != 1) {
      throw StateError('single media encoding required');
    }
    final src = original.encodings!.single;
    final dst = params.encodings!.single;
    if (dst.maxBitrate == src.maxBitrate &&
        dst.maxFramerate == src.maxFramerate &&
        dst.scaleResolutionDownBy == src.scaleResolutionDownBy &&
        params.degradationPreference == original.degradationPreference) {
      return;
    }
    dst.maxBitrate = src.maxBitrate;
    dst.maxFramerate = src.maxFramerate;
    dst.scaleResolutionDownBy = src.scaleResolutionDownBy;
    params.degradationPreference = original.degradationPreference;
    if (!await sender.setParameters(params)) {
      throw StateError('direct encoding update failed');
    }
  }

  Future<String> _gatheredSdp() async {
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!_closed &&
        pc.iceGatheringState !=
            rtc.RTCIceGatheringState.RTCIceGatheringStateComplete &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (_closed) throw StateError('direct transport closed');
    final sdp = (await pc.getLocalDescription())?.sdp;
    if (sdp == null || sdp.isEmpty || utf8.encode(sdp).length > directMaxSdp) {
      throw StateError('invalid direct SDP size');
    }
    return sdp;
  }

  String _seedSdp(String initial) {
    final sections = initial.split('m=');
    final result = StringBuffer(sections.first);
    for (var physical = 0; physical < sections.length - 1; physical++) {
      final slot = physical % 4;
      final section = sections[physical + 1];
      result.write('m=');
      if (slot == 3) {
        final lines = const LineSplitter().convert(section);
        final opus = lines
            .map((line) =>
                RegExp(r'^a=rtpmap:(\d+) opus/48000/2$', caseSensitive: false)
                    .firstMatch(line)
                    ?.group(1))
            .whereType<String>()
            .firstOrNull;
        for (final line in lines) {
          result.write(line);
          if (opus != null &&
              line.startsWith('a=fmtp:$opus ') &&
              !line
                  .split(RegExp(r'[ ;]'))
                  .any((p) => p.startsWith('stereo='))) {
            result.write(';stereo=1');
          }
          result.write('\r\n');
        }
        if (opus != null && !lines.any((l) => l.startsWith('a=fmtp:$opus '))) {
          result.write('a=fmtp:$opus stereo=1\r\n');
        }
        continue;
      }
      if (slot != 1 && slot != 2) {
        result.write(section);
        continue;
      }
      final encoding = slots[slot].sender.parameters.encodings;
      final bps = encoding?.firstOrNull?.maxBitrate ??
          _pendingEncoding[slot]?.encodings?.firstOrNull?.maxBitrate ??
          (slot == 1 ? 3500000 : null);
      if (bps == null) {
        result.write(section);
        continue;
      }
      final kbps = (bps ~/ 1000).clamp(300, 3500);
      final lines = const LineSplitter().convert(section);
      final pts = <String>[];
      for (final line in lines) {
        final match = RegExp(r'^a=rtpmap:(\d+) (H264|VP8)/').firstMatch(line);
        if (match != null) pts.add(match.group(1)!);
      }
      for (final line in lines) {
        result.write(line);
        if (pts.any((pt) => line.startsWith('a=fmtp:$pt '))) {
          result.write(';x-google-start-bitrate=$kbps');
        }
        result.write('\r\n');
        final match = RegExp(r'^a=rtpmap:(\d+) ').firstMatch(line);
        final pt = match?.group(1);
        if (pt != null &&
            pts.contains(pt) &&
            !lines.any((l) => l.startsWith('a=fmtp:$pt '))) {
          result.write('a=fmtp:$pt x-google-start-bitrate=$kbps\r\n');
        }
      }
    }
    return result.toString();
  }

  Future<String> offer() async {
    final offer = await pc.createOffer();
    await pc.setLocalDescription(
        rtc.RTCSessionDescription(_seedSdp(offer.sdp!), 'offer'));
    return _gatheredSdp();
  }

  Future<void> prepareAnswer(String offer) async {
    if (slots.isNotEmpty) {
      throw StateError('answerer must start without local transceivers');
    }
    await _setRemote(offer, 'offer');
    final negotiated = await pc.getTransceivers();
    negotiated.sort((a, b) =>
        (int.tryParse(a.mid) ?? 99).compareTo(int.tryParse(b.mid) ?? 99));
    if (negotiated.length != 8) {
      throw StateError('invalid negotiated media slots');
    }
    for (var index = 0; index < 8; index++) {
      final transceiver = negotiated[index];
      if (transceiver.mid != '$index' ||
          (transceiver.receiver.track?.kind == 'video') !=
              (index % 4 == 1 || index % 4 == 2)) {
        throw StateError('invalid negotiated media slots');
      }
      await transceiver.setDirection(index < 4
          ? rtc.TransceiverDirection.RecvOnly
          : rtc.TransceiverDirection.SendOnly);
      await _configureVideoCodec(index % 4, transceiver, receiving: index < 4);
    }
    slots.addAll(negotiated.skip(4));
  }

  Future<String> finishAnswer() async {
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(
        rtc.RTCSessionDescription(_seedSdp(answer.sdp!), 'answer'));
    for (var index = 0; index < slots.length; index++) {
      await setDirectSenderActive(slots[index].sender, false);
      final original = _pendingEncoding.remove(index);
      if (original != null) await copyEncoding(index, original);
    }
    return _gatheredSdp();
  }

  Future<void> acceptAnswer(String answer) => _setRemote(answer, 'answer');
  Future<void> _setRemote(String sdp, String type) async {
    if (sdp.isEmpty || utf8.encode(sdp).length > directMaxSdp) {
      throw StateError('invalid direct SDP size');
    }
    final sections = sdp.split('\nm=').skip(1).toList();
    if (sections.length != 8) throw StateError('invalid direct media slots');
    for (var index = 0; index < 8; index++) {
      final expected = index % 4 == 1 || index % 4 == 2 ? 'video' : 'audio';
      final lines = const LineSplitter().convert(sections[index]);
      final directions = lines
          .where((line) => [
                'a=sendonly',
                'a=recvonly',
                'a=sendrecv',
                'a=inactive'
              ].contains(line))
          .toList();
      final sends = type == 'offer' ? index < 4 : index >= 4;
      final expectedDirection = sends ? 'a=sendonly' : 'a=recvonly';
      if (directions.length != 1 ||
          (directions.single != expectedDirection &&
              !(type == 'answer' &&
                  sends &&
                  directions.single == 'a=inactive'))) {
        throw StateError('invalid direct media direction');
      }
      final mids = const LineSplitter()
          .convert(sections[index])
          .where((l) => l.startsWith('a=mid:'))
          .toList();
      if (sections[index].split(RegExp(r'\s+')).first != expected ||
          mids.length != 1 ||
          mids.single != 'a=mid:$index') {
        throw StateError('invalid direct media slots');
      }
    }
    await pc
        .setRemoteDescription(rtc.RTCSessionDescription(sdp, type))
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    pc.onTrack = null;
    try {
      await pc.close();
    } finally {
      try {
        await pc.dispose();
      } finally {
        await tracks.close();
      }
    }
  }
}

// The Web adapter returns before its JS replaceTrack Promise has settled.
// Wait for the actual binding before creating SDP or reactivating an encoder.
Future<void> replaceDirectSenderTrack(
    rtc.RTCRtpSender sender, rtc.MediaStreamTrack? track) async {
  await sender.replaceTrack(track);
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (sender.track?.id != track?.id) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('sender source update timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> setDirectSenderActive(rtc.RTCRtpSender sender, bool active) async {
  final params = sender.parameters;
  if (params.encodings == null || params.encodings!.isEmpty) {
    throw StateError('missing sender encoding');
  }
  if (params.encodings!.every((e) => e.active == active)) return;
  for (final encoding in params.encodings!) {
    encoding.active = active;
  }
  if (!await sender.setParameters(params)) {
    throw StateError('sender forwarding update failed');
  }
}
