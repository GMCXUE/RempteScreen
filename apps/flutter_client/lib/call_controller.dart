import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show WebRTC;
import 'native_service.dart';
import 'friend_audio_options.dart';
import 'call_video_options.dart';
import 'call_video_quality.dart';

/// 会话内的语音、摄像头通话控制。
///
/// 桌面/观看端使用独立通话轨。安卓投屏端因原生音频输入共用，
/// 将显式开启的麦克风混入投屏声音，保持屏幕和系统声音采集持续运行。
class CallController extends ChangeNotifier with WidgetsBindingObserver {
  static int _nextId = 0;
  static final Set<CallController> _controllers = {};
  static bool friendAudioActive = false;
  final bool friendCall;
  static Future<List<CallController>> pauseForFriend() async {
    friendAudioActive = true;
    final paused = <CallController>[];
    try {
      for (final call in _controllers.toList()) {
        if (call.friendCall || call._closed) continue;
        for (var i = 0; call.busy && i < 100; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (call.busy) throw StateError('投屏麦克风正在操作，请稍后重试');
        if (call.microphoneEnabled) {
          paused.add(call);
          await call.toggleMicrophone();
        }
      }
      return paused;
    } catch (_) {
      await restoreAfterFriend(paused);
      rethrow;
    }
  }

  static Future<void> restoreAfterFriend(List<CallController> paused) async {
    friendAudioActive = false;
    for (final call in paused) {
      if (!call._closed && !call.microphoneEnabled) {
        try {
          await call.toggleMicrophone();
        } catch (_) {
          /* Keep screen sharing alive if recapture is unavailable. */
        }
      }
    }
  }

  final String _serviceId = 'call-${++_nextId}';
  CallController(this.room,
      {this.peerIdentity,
      this.showFloatingVideo = false,
      this.friendCall = false,
      this.floatingCallId,
      this.floatingAccountId,
      this.floatingKind = 'video',
      this.floatingPeerName,
      this.floatingAcceptedAt,
      this.clientId}) {
    _floatingAllowed = !friendCall;
    _controllers.add(this);
    _peerEvents = room.createListener()
      ..on<ParticipantDisconnectedEvent>((event) {
        _departedPeers.add(event.participant.identity);
        _syncFloatingVideo(force: true);
        if (!_closed) notifyListeners();
      })
      ..on<ParticipantConnectedEvent>((event) {
        _departedPeers.remove(event.participant.identity);
        _roomChanged();
      })
      ..on<TrackUnsubscribedEvent>((event) => _refreshAfterTrackEvent())
      ..on<TrackUnpublishedEvent>((event) => _refreshAfterTrackEvent());
    room.addListener(_roomChanged);
    WidgetsBinding.instance.addObserver(this);
    _videoQuality = CallVideoQuality(room, peerIdentity: peerIdentity);
    _syncFloatingVideo();
  }

  late final EventsListener<RoomEvent> _peerEvents;
  late final CallVideoQuality _videoQuality;
  final Set<String> _departedPeers = {};

  void _refreshAfterTrackEvent() {
    scheduleMicrotask(() {
      if (!_closed) _syncFloatingVideo(force: true);
    });
  }

  final Room room;
  final String? peerIdentity;
  final bool showFloatingVideo;
  final String? floatingCallId, floatingAccountId;
  final String floatingKind;
  final String? floatingPeerName, clientId;
  final int? floatingAcceptedAt;
  bool floatingVideoVisible = false;
  String? floatingVideoError;
  String? _floatingTrackId;
  int _floatingRevision = 0;
  Future<void> _floatingQueue = Future.value();
  bool _floatingPermissionPending = false;
  bool _floatingAllowed = true;
  bool _inBackground = false;
  void setFloatingVideoVisible(bool visible) {
    _floatingAllowed = visible;
    _syncFloatingVideo(force: true);
  }

  void _syncFloatingVideo({bool force = false, bool manual = false}) {
    if (!showFloatingVideo || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    final visible = !_closed && (_floatingAllowed || _inBackground);
    final id = !visible ? null : remoteCameraTrack?.mediaStreamTrack.id;
    if (!force && id == _floatingTrackId) return;
    _floatingTrackId = id;
    final revision = ++_floatingRevision;
    _floatingQueue = _floatingQueue.then((_) async {
      // Do not reopen an old track after a newer room event or close.
      if (revision != _floatingRevision) return;
      try {
        floatingVideoVisible = await NativeVideoOverlay.update(_serviceId, id,
            manual: manual,
            visible: visible && (friendCall || id != null),
            callId: floatingCallId,
            accountId: floatingAccountId,
            kind: floatingKind,
            peerName: floatingPeerName,
            acceptedAt: floatingAcceptedAt);
        floatingVideoError = null;
      } catch (error) {
        floatingVideoVisible = false;
        floatingVideoError = error.toString();
      }
      if (!_closed) notifyListeners();
    });
  }

  Future<bool> openFloatingVideo() async {
    _floatingPermissionPending = await NativeVideoOverlay.requestPermission();
    if (_floatingPermissionPending) return false;
    _floatingAllowed = true;
    _syncFloatingVideo(force: true, manual: true);
    await _floatingQueue;
    return floatingVideoVisible;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (friendCall && state == AppLifecycleState.paused) {
      _inBackground = true;
      _syncFloatingVideo(force: true);
    }
    if (state == AppLifecycleState.resumed) {
      _inBackground = false;
      _syncFloatingVideo(force: true, manual: _floatingPermissionPending);
      _floatingPermissionPending = false;
    }
  }

  bool busy = false;
  bool speakerEnabled = true;
  bool screenAudioEnabled = true;
  bool _closed = false;
  bool _screenMicrophoneEnabled = false;

  LocalParticipant? get _local => room.localParticipant;

  bool get microphoneEnabled {
    if (_screenMicrophoneEnabled) return true;
    final publication =
        _local?.getTrackPublicationBySource(TrackSource.microphone);
    return publication != null && !publication.muted;
  }

  bool get cameraEnabled {
    final publication = _local?.getTrackPublicationBySource(TrackSource.camera);
    return publication != null && !publication.muted;
  }

  LocalVideoTrack? get localCameraTrack {
    if (_closed || !cameraEnabled) return null;
    final track =
        _local?.getTrackPublicationBySource(TrackSource.camera)?.track;
    return track is LocalVideoTrack ? track : null;
  }

  RemoteVideoTrack? get remoteCameraTrack {
    if (_closed || room.connectionState != ConnectionState.connected) {
      return null;
    }
    for (final participant in room.remoteParticipants.values) {
      if (_departedPeers.contains(participant.identity) ||
          (peerIdentity != null && participant.identity != peerIdentity)) {
        continue;
      }
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (publication.source == TrackSource.camera &&
            publication.subscribed &&
            !publication.muted &&
            track is RemoteVideoTrack) {
          return track;
        }
      }
    }
    return null;
  }

  Future<void> toggleMicrophone() async {
    final local = _local;
    if (local == null) throw StateError('通话会话尚未连接');
    if (!friendCall && friendAudioActive && !microphoneEnabled) {
      throw StateError('好友通话进行中，请先结束通话再使用投屏麦克风');
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        local.getTrackPublicationBySource(TrackSource.screenShareAudio) !=
            null) {
      await _run(() async {
        final enabled = !_screenMicrophoneEnabled;
        await WebRTC.invokeMethod(
            'setScreenCallMicrophone', {'enabled': enabled});
        _screenMicrophoneEnabled = enabled;
        if (_closed) {
          await WebRTC.invokeMethod(
              'setScreenCallMicrophone', {'enabled': false});
          _screenMicrophoneEnabled = false;
        }
        return null;
      });
      return;
    }
    final enabled = !microphoneEnabled;
    await _run(
        () => local.setMicrophoneEnabled(
              enabled,
              audioCaptureOptions:
                  friendCall && defaultTargetPlatform == TargetPlatform.android
                      ? const FriendAudioCaptureOptions()
                      : const AudioCaptureOptions(
                          echoCancellation: true,
                          noiseSuppression: true,
                          autoGainControl: true,
                          voiceIsolation: true,
                        ),
            ),
        requestedMicrophone: enabled);
  }

  Future<void> toggleCamera() async {
    final local = _local;
    if (local == null) throw StateError('通话会话尚未连接');
    final enabled = !cameraEnabled;
    await _run(() async {
      if (!enabled ||
          local.getTrackPublicationBySource(TrackSource.camera) != null) {
        return local.setCameraEnabled(enabled,
            cameraCaptureOptions: callCameraCaptureOptions);
      }
      // Publish options belong to the camera track. Changing room defaults
      // here would also change the codec/encoding of an active screen share.
      final track =
          await LocalVideoTrack.createCameraTrack(callCameraCaptureOptions);
      try {
        if (_closed) throw StateError('通话会话已经关闭');
        return await local.publishVideoTrack(track,
            publishOptions: callVideoPublishOptions);
      } catch (_) {
        await track.stop();
        rethrow;
      }
    }, requestedCamera: enabled);
  }

  Future<void> toggleSpeaker() async {
    speakerEnabled = !speakerEnabled;
    for (final participant in room.remoteParticipants.values) {
      if (peerIdentity != null && participant.identity != peerIdentity) {
        continue;
      }
      for (final publication in participant.audioTrackPublications) {
        if (publication.source != TrackSource.microphone) continue;
        final track = publication.track;
        if (track is! RemoteAudioTrack) continue;
        if (speakerEnabled) {
          await track.enable();
        } else {
          await track.disable();
        }
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> toggleScreenAudio() async {
    if (_closed) return;
    screenAudioEnabled = !screenAudioEnabled;
    for (final participant in room.remoteParticipants.values) {
      if (peerIdentity != null && participant.identity != peerIdentity) {
        continue;
      }
      for (final publication in participant.audioTrackPublications) {
        if (publication.source != TrackSource.screenShareAudio) continue;
        final track = publication.track;
        if (track is RemoteAudioTrack) {
          if (screenAudioEnabled) {
            await track.enable();
          } else {
            await track.disable();
          }
        }
      }
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _updateProtection({bool? microphone, bool? camera}) =>
      NativeCallService.update(_serviceId,
          microphone: !_closed && (microphone ?? microphoneEnabled),
          camera: !_closed && (camera ?? cameraEnabled),
          active: !_closed && friendCall,
          callId: floatingCallId,
          accountId: floatingAccountId,
          clientId: clientId,
          peerName: floatingPeerName);

  Future<void> _run(Future<Object?> Function() action,
      {bool? requestedMicrophone, bool? requestedCamera}) async {
    if (_closed) throw StateError('通话会话已经关闭');
    if (busy) return;
    busy = true;
    final previousMicrophone = microphoneEnabled;
    final previousCamera = cameraEnabled;
    final previousScreenMicrophone = _screenMicrophoneEnabled;
    if (!_closed) notifyListeners();
    try {
      if (requestedMicrophone == true || requestedCamera == true) {
        await NativeCallService.prepareCapture(
            microphone: requestedMicrophone == true,
            camera: requestedCamera == true);
        if (_closed) throw StateError('通话会话已经关闭');
        // Establish foreground protection before opening either device.
        await _updateProtection(
            microphone: previousMicrophone || requestedMicrophone == true,
            camera: previousCamera || requestedCamera == true);
        if (_closed) throw StateError('通话会话已经关闭');
      }
      await action();
      if (_closed) {
        await _local?.setMicrophoneEnabled(false);
        await _local?.setCameraEnabled(false);
      }
      await _updateProtection();
    } catch (_) {
      // Do not leave capture enabled if the OS refused background protection.
      if (_screenMicrophoneEnabled != previousScreenMicrophone) {
        await WebRTC.invokeMethod('setScreenCallMicrophone',
            {'enabled': !_closed && previousScreenMicrophone});
        _screenMicrophoneEnabled = !_closed && previousScreenMicrophone;
      } else if (microphoneEnabled != previousMicrophone) {
        await _local?.setMicrophoneEnabled(!_closed && previousMicrophone);
      }
      if (cameraEnabled != previousCamera) {
        await _local?.setCameraEnabled(!_closed && previousCamera);
      }
      await _updateProtection().catchError((_) {});
      rethrow;
    } finally {
      busy = false;
      if (!_closed) notifyListeners();
    }
  }

  void _roomChanged() {
    _syncFloatingVideo();
    if (!speakerEnabled || !screenAudioEnabled) {
      for (final participant in room.remoteParticipants.values) {
        if (peerIdentity != null && participant.identity != peerIdentity) {
          continue;
        }
        for (final publication in participant.audioTrackPublications) {
          final track = publication.track;
          if (((publication.source == TrackSource.microphone &&
                      !speakerEnabled) ||
                  (publication.source == TrackSource.screenShareAudio &&
                      !screenAudioEnabled)) &&
              track is RemoteAudioTrack) {
            unawaited(track.disable());
          }
        }
      }
    }
    if (!_closed) notifyListeners();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _controllers.remove(this);
    _peerEvents.dispose();
    _videoQuality.close();
    WidgetsBinding.instance.removeObserver(this);
    _syncFloatingVideo(force: true);
    unawaited(_updateProtection().catchError((_) {}));
    if (_screenMicrophoneEnabled) {
      unawaited(
          WebRTC.invokeMethod('setScreenCallMicrophone', {'enabled': false})
              .catchError((_) => null));
      _screenMicrophoneEnabled = false;
    }
    room.removeListener(_roomChanged);
    super.dispose();
  }
}
