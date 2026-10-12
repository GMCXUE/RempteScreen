import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

// Fixed Unified Plan slots match Rust. SDP carries gathered host/srflx candidates.
const directMediaSources = ['microphone', 'camera', 'screen', 'screen_audio'];
const directMediaTopic = 'rs-direct-media-v1';
const directMaxSdp = 48 * 1024;

class DirectTransport {
  DirectTransport._(this.pc);
  final rtc.RTCPeerConnection pc;
  final slots = <rtc.RTCRtpTransceiver>[];
  final tracks = StreamController<rtc.RTCTrackEvent>.broadcast();
  bool _closed = false;

  static Future<DirectTransport> create(
      {List<String> stunUrls = const [],
      Future<rtc.RTCPeerConnection> Function(Map<String, dynamic>)?
          factory}) async {
    if (!stunUrls.every((s) => s.startsWith('stun:') && s.length <= 256)) {
      {
        throw StateError('invalid STUN configuration');
      }
    }
    final pc = await (factory ?? (config) => rtc.createPeerConnection(config))({
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        for (final url in stunUrls) {'urls': url}
      ],
    });
    final link = DirectTransport._(pc);
    try {
      pc.onTrack = (event) {
        if (!link._closed) link.tracks.add(event);
      };
      for (var slot = 0; slot < 4; slot++) {
        final video = slot == 1 || slot == 2;
        final transceiver = await pc.addTransceiver(
          kind: video
              ? rtc.RTCRtpMediaType.RTCRtpMediaTypeVideo
              : rtc.RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: rtc.RTCRtpTransceiverInit(
              direction: rtc.TransceiverDirection.SendRecv,
              sendEncodings: [
                rtc.RTCRtpEncoding(
                    active: false,
                    maxBitrate: slot == 1 ? 3500000 : null,
                    maxFramerate: slot == 1 ? 30 : null)
              ]),
        );
        if (video) {
          final preferred = slot == 1 ? 'video/h264' : 'video/vp8';
          final capabilities = await rtc.getRtpSenderCapabilities('video');
          final codecs = capabilities.codecs
                  ?.where((c) => c.mimeType.toLowerCase() == preferred)
                  .toList() ??
              [];
          if (codecs.isEmpty) throw StateError('unsupported codec $preferred');
          if (slot == 1) {
            codecs.sort((a, b) =>
                (a.sdpFmtpLine?.contains('profile-level-id=42e01f') == true
                        ? 0
                        : 1)
                    .compareTo(
                        b.sdpFmtpLine?.contains('profile-level-id=42e01f') ==
                                true
                            ? 0
                            : 1));
          }
          await transceiver.setCodecPreferences(codecs);
        }
        link.slots.add(transceiver);
      }
      return link;
    } catch (_) {
      await link.close();
      rethrow;
    }
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

  Future<void> replaceTrack(int slot, rtc.MediaStreamTrack? track) async {
    if (slot < 0 || slot >= slots.length) {
      throw StateError('unknown media source');
    }
    if (track != null && (track.kind == 'video') != (slot == 1 || slot == 2)) {
      {
        throw StateError('media source kind mismatch');
      }
    }
    await slots[slot].sender.replaceTrack(track);
  }

  Future<void> copyEncoding(int slot, rtc.RTCRtpParameters original) async {
    final sender = slots[slot].sender;
    final params = sender.parameters;
    if (params.encodings?.length != 1 || original.encodings?.length != 1) {
      throw StateError('single media encoding required');
    }
    final src = original.encodings!.single;
    final dst = params.encodings!.single;
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
    for (var slot = 0; slot < sections.length - 1; slot++) {
      final section = sections[slot + 1];
      result.write('m=');
      if (slot != 1 && slot != 2) {
        result.write(section);
        continue;
      }
      final encoding = slots[slot].sender.parameters.encodings;
      final bps = encoding?.firstOrNull?.maxBitrate;
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

  Future<String> answer(String offer) async {
    await _setRemote(offer, 'offer');
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(
        rtc.RTCSessionDescription(_seedSdp(answer.sdp!), 'answer'));
    return _gatheredSdp();
  }

  Future<void> acceptAnswer(String answer) => _setRemote(answer, 'answer');
  Future<void> _setRemote(String sdp, String type) async {
    if (sdp.isEmpty || utf8.encode(sdp).length > directMaxSdp) {
      throw StateError('invalid direct SDP size');
    }
    await pc
        .setRemoteDescription(rtc.RTCSessionDescription(sdp, type))
        .timeout(const Duration(seconds: 5));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    pc.onTrack = null;
    await pc.close();
    await pc.dispose();
    await tracks.close();
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
