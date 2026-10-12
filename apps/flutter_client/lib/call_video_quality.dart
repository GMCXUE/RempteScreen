import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';
import 'direct_media.dart';

const callQualityTopic = 'rs-call-video-quality-v1';
const callQualityHeights = [180, 360, 720, 1080];
const callQualityBitrates = [200000, 650000, 2000000, 3500000];

Future<bool> applyCallVideoTier(
    LocalVideoTrack track, int tier, int shortEdge) async {
  final sender = track.sender;
  if (sender == null ||
      track.source != TrackSource.camera ||
      tier < 0 ||
      tier > 3 ||
      shortEdge <= 0) {
    return false;
  }
  final params = sender.parameters;
  if (params.encodings?.length != 1) {
    return false;
  }
  final encoding = params.encodings!.single;
  encoding.scaleResolutionDownBy =
      math.max(1.0, shortEdge / callQualityHeights[tier]);
  encoding.maxBitrate = callQualityBitrates[tier];
  encoding.maxFramerate = 30;
  return sender.setParameters(params).timeout(const Duration(seconds: 2));
}

/// Fast downgrade and slow recovery; each tier retains the 30 fps target.
class CallQualityPolicy {
  CallQualityPolicy(this.maximum) : tier = math.min(2, maximum);
  final int maximum;
  CallQualityPolicy copy() {
    final next = CallQualityPolicy(maximum);
    next.tier = tier;
    next._bad = _bad;
    next._good = _good;
    next._grace = _grace;
    next._cooldown = _cooldown;
    return next;
  }

  int tier, _bad = 0, _good = 0, _grace = 0, _cooldown = 0;
  void routeChanged() {
    _bad = 0;
    _good = 0;
    _grace = 4;
  }

  void sample(
      {double? bandwidth, double? loss, double? fps, bool cpuLimited = false}) {
    final bad =
        cpuLimited || (loss != null && loss > .03) || (fps != null && fps < 24);
    final severe = (loss != null && loss > .12) || (fps != null && fps < 15);
    final good =
        loss != null && fps != null && !cpuLimited && loss <= .01 && fps >= 27;
    var allowed = maximum;
    if (bandwidth != null) {
      allowed = 0;
      for (var i = maximum; i > 0; i--) {
        if (bandwidth >= callQualityBitrates[i] * 1.15) {
          allowed = i;
          break;
        }
      }
    }
    final grace = _grace > 0;
    if (_grace > 0) _grace--;
    if (_cooldown > 0) _cooldown--;
    if (bad || (!grace && allowed < tier)) {
      _good = 0;
      if (severe || ++_bad >= 2) {
        tier = math.max(0, math.min(tier - 1, allowed));
        _bad = 0;
        _cooldown = 15;
      }
    } else {
      _bad = 0;
      if (good && tier < maximum && _cooldown == 0) {
        _good++;
        // A capped sender can have a capped BWE estimate. Probe the next tier
        // only after 16s of healthy receiver feedback, giving BWE 8s to rise.
        final probe = allowed >= tier && _good >= 8;
        if ((allowed > tier && _good >= 8) || probe) {
          tier++;
          _good = 0;
          _grace = 4;
        }
      } else {
        _good = 0;
      }
    }
  }
}

class _Reception {
  _Reception(this.received, this.lost, this.decoded, this.time, this.direct);
  final bool direct;
  final int received, lost, decoded;
  final DateTime time;
}

class _Feedback {
  _Feedback(this.sequence, this.loss, this.fps, this.time, this.direct);
  final bool direct;
  final int sequence;
  final double loss, fps;
  final DateTime time;
}

/// Updates the existing RTP sender; no track republish or room reconnect.
/// Receiver reports cover downlink loss and decoding load, which the sender's
/// bandwidth estimate (client to SFU only) cannot measure.
class CallVideoQuality {
  CallVideoQuality(this.room, {this.peerIdentity, this.mediaRoute}) {
    _events = room.createListener()..on<DataReceivedEvent>(_receive);
    _timer =
        Timer.periodic(const Duration(seconds: 2), (_) => unawaited(_tick()));
    unawaited(_tick());
  }
  final Room room;
  final String? peerIdentity;
  final DirectMedia? mediaRoute;
  late final EventsListener<RoomEvent> _events;
  late final Timer _timer;
  final _policies = <String, CallQualityPolicy>{};
  final _senderRoutes = <String, bool>{};
  final _receptions = <String, _Reception>{};
  final _feedback = <String, Map<String, _Feedback>>{};
  final _retry = <String>{};
  int _sequence = 0;
  bool _closed = false, _ticking = false;
  bool _accept(String identity) =>
      peerIdentity == null || peerIdentity == identity;

  void _receive(DataReceivedEvent event) {
    if (_closed ||
        event.topic != callQualityTopic ||
        event.data.length > 512 ||
        event.participant == null ||
        !_accept(event.participant!.identity)) {
      return;
    }
    try {
      final data = jsonDecode(utf8.decode(event.data));
      if (data is! Map ||
          data['v'] != 1 ||
          data['sid'] is! String ||
          data['seq'] is! int ||
          data['loss'] is! num ||
          data['fps'] is! num) {
        return;
      }
      final sid = data['sid'] as String, sequence = data['seq'] as int;
      if (data.containsKey('direct') && data['direct'] is! bool) return;
      final direct = data['direct'] == true;
      if (direct != (mediaRoute?.isSending(sid) ?? false)) return;
      if (room.localParticipant?.getTrackPublicationBySid(sid)?.source !=
          TrackSource.camera) {
        return;
      }
      final loss = (data['loss'] as num).toDouble(),
          fps = (data['fps'] as num).toDouble();
      if (!loss.isFinite ||
          !fps.isFinite ||
          loss < 0 ||
          loss > 1 ||
          fps < 0 ||
          fps > 120 ||
          sequence < 0) {
        return;
      }
      final peers = _feedback.putIfAbsent(sid, () => {});
      final identity = event.participant!.identity;
      if (sequence <= (peers[identity]?.sequence ?? -1)) return;
      peers[identity] = _Feedback(sequence, loss, fps, DateTime.now(), direct);
    } catch (_) {/* Ignore unrelated or malformed data packets. */}
  }

  Future<void> _tick() async {
    if (_closed || _ticking) return;
    if (room.connectionState != ConnectionState.connected) {
      _receptions.clear();
      _feedback.clear();
      return;
    }
    _ticking = true;
    try {
      final now = DateTime.now(), local = room.localParticipant;
      final active = <String>{};
      for (final publication
          in local?.videoTrackPublications ?? <LocalTrackPublication>[]) {
        final track = publication.track;
        if (publication.source != TrackSource.camera ||
            publication.muted ||
            track is! LocalVideoTrack) {
          continue;
        }
        final originalSender = track.sender;
        final sender = mediaRoute?.senderFor(publication.sid, originalSender) ??
            originalSender;
        final direct = mediaRoute?.isSending(publication.sid) ?? false;
        if (sender == null) continue;
        active.add(publication.sid);
        final settings = track.mediaStreamTrack.getSettings();
        final dimensions =
            publication.dimensions ?? track.currentOptions.params.dimensions;
        final width = (settings['width'] as num?)?.toInt() ?? dimensions.width;
        final height =
            (settings['height'] as num?)?.toInt() ?? dimensions.height;
        final shortEdge = math.min(width, height);
        final maximum = math.max(
            0, callQualityHeights.lastIndexWhere((size) => size <= shortEdge));
        var policy = _policies.putIfAbsent(
            publication.sid, () => CallQualityPolicy(maximum));
        final oldRoute = _senderRoutes[publication.sid];
        _senderRoutes[publication.sid] = direct;
        if (oldRoute != null && oldRoute != direct) {
          policy.routeChanged();
          _feedback.remove(publication.sid);
        }
        final stats =
            await sender.getStats().timeout(const Duration(seconds: 2));
        if (_closed ||
            track.sender != originalSender ||
            publication.muted ||
            direct != (mediaRoute?.isSending(publication.sid) ?? false)) {
          continue;
        }
        double? bandwidth;
        var cpuLimited = false;
        for (final report in stats) {
          if (report.type == 'candidate-pair' &&
              report.values['nominated'] == true) {
            final value = report.values['availableOutgoingBitrate'];
            if (value is num && value > 0 && value.isFinite) {
              bandwidth = value.toDouble();
            }
          } else if (report.type == 'outbound-rtp') {
            cpuLimited =
                cpuLimited || report.values['qualityLimitationReason'] == 'cpu';
          }
        }
        final peers = _feedback[publication.sid];
        peers?.removeWhere(
            (_, report) => now.difference(report.time).inSeconds > 6);
        double? loss, fps;
        for (final report in peers?.values ?? <_Feedback>[]) {
          if (report.direct != direct) continue;
          loss = math.max(loss ?? 0, report.loss);
          fps = math.min(fps ?? 120, report.fps);
        }
        final previous = policy.tier;
        final next = policy.copy();
        next.sample(
            bandwidth: bandwidth, loss: loss, fps: fps, cpuLimited: cpuLimited);
        if (direct &&
            (next.tier < previous ||
                cpuLimited ||
                (loss ?? 0) > .03 ||
                (fps ?? 30) < 24)) {
          mediaRoute?.requestFallback();
          continue;
        }
        policy = next;
        _policies[publication.sid] = next;
        final params = originalSender!.parameters;
        if (params.encodings?.length != 1) continue;
        final encoding = params.encodings!.single;
        final scale =
            math.max(1.0, shortEdge / callQualityHeights[policy.tier]);
        final bitrate = callQualityBitrates[policy.tier];
        if (_retry.contains(publication.sid) ||
            encoding.scaleResolutionDownBy != scale ||
            encoding.maxBitrate != bitrate ||
            encoding.maxFramerate != 30) {
          _retry.add(publication.sid);
          if (!await applyCallVideoTier(track, policy.tier, shortEdge)) {
            policy.tier = previous;
            continue;
          }
          _retry.remove(publication.sid);
          debugPrint(
              '[camera-quality] sid=${publication.sid} target=${callQualityHeights[policy.tier]}p@30 bitrate=$bitrate');
        }
      }
      _policies.removeWhere((sid, _) => !active.contains(sid));
      _senderRoutes.removeWhere((sid, _) => !active.contains(sid));
      _feedback.removeWhere((sid, _) => !active.contains(sid));
      _retry.removeWhere((sid) => !active.contains(sid));
      final receiving = <String>{};
      for (final participant in room.remoteParticipants.values) {
        if (!_accept(participant.identity)) continue;
        for (final publication in participant.videoTrackPublications) {
          final track = mediaRoute?.resolve(publication) ?? publication.track;
          final direct = mediaRoute?.isReceiving(publication.sid) ?? false;
          if (publication.source != TrackSource.camera ||
              publication.muted ||
              (!publication.enabled && !direct) ||
              track is! RemoteVideoTrack) {
            continue;
          }
          receiving.add(publication.sid);
          final stats = await track
              .getReceiverStats()
              .timeout(const Duration(seconds: 2));
          if (_closed ||
              stats == null ||
              direct != (mediaRoute?.isReceiving(publication.sid) ?? false)) {
            continue;
          }
          final sampleTime = DateTime.now();
          final received = stats.packetsReceived?.toInt(),
              lost = stats.packetsLost?.toInt(),
              decoded = stats.framesDecoded?.toInt();
          if (received == null || lost == null || decoded == null) continue;
          final previous = _receptions[publication.sid];
          _receptions[publication.sid] =
              _Reception(received, lost, decoded, sampleTime, direct);
          if (previous == null ||
              previous.direct != direct ||
              received < previous.received ||
              decoded < previous.decoded) {
            continue;
          }
          final seconds =
              sampleTime.difference(previous.time).inMilliseconds / 1000;
          if (seconds < .5 || seconds > 6) continue;
          final drops = math.max(0, lost - previous.lost),
              packets = received - previous.received;
          final loss = drops / math.max(1, drops + packets);
          final fps =
              ((decoded - previous.decoded) / seconds).clamp(0.0, 120.0);
          if (direct && (loss > .03 || fps < 24)) {
            mediaRoute?.requestFallback();
            continue;
          }
          await local?.publishData(
              utf8.encode(jsonEncode({
                'v': 1,
                'sid': publication.sid,
                'seq': ++_sequence,
                'loss': loss,
                'fps': fps,
                'direct': direct
              })),
              reliable: false,
              topic: callQualityTopic,
              destinationIdentities: [participant.identity]);
        }
      }
      _receptions.removeWhere((sid, _) => !receiving.contains(sid));
    } catch (error) {
      if (!_closed) debugPrint('[camera-quality] stats/update skipped: $error');
    } finally {
      _ticking = false;
    }
  }

  void close() {
    _closed = true;
    _timer.cancel();
    _events.dispose();
  }
}
