import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'account_avatar.dart';
import 'call_controller.dart';
import 'call_camera_view.dart';
import 'app_theme.dart';
import 'friend_audio_options.dart';
import 'call_video_options.dart';
import 'friend_video_stage.dart';
import 'friend_call_miniplayer.dart';
import 'native_service.dart';
import 'package:flutter/foundation.dart';

final friendCalls = FriendCalls();
final appNavigatorKey = GlobalKey<NavigatorState>();

class FriendCalls extends ChangeNotifier {
  FriendCalls(
      {Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)?
          request,
      Future<void> Function(String)? clearNotification})
      : _request = request ?? ((op, body) => api.social(op, body)),
        _clearNotification = clearNotification ?? NativeMessaging.clearCall;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
      _request;
  final Future<void> Function(String) _clearNotification;
  Account? account;
  String? _clientId;
  Timer? _timer;
  int _generation = 0;
  bool _polling = false;
  bool busy = false;
  bool connecting = false;
  bool screenVisible = false;
  void openScreen() {
    final navigator = appNavigatorKey.currentState;
    if (screenVisible || current == null || navigator == null) return;
    screenVisible = true;
    media?.setFloatingVideoVisible(false);
    _notify();
    navigator
        .push(MaterialPageRoute(builder: (_) => const FriendCallScreen()))
        .whenComplete(() {
      screenVisible = false;
      media?.setFloatingVideoVisible(true);
      _notify();
    });
  }

  Map<String, dynamic>? current;
  Room? _room;
  CallController? media;
  List<CallController> _paused = [];
  EventsListener<RoomEvent>? _events;
  String? _joined;
  String? notice;
  DateTime _lastSuccess = DateTime.now();
  Timer? _noticeTimer;
  Future<void>? _joinFuture;
  bool _closing = false;
  final Map<String, Map<String, dynamic>> _ending = {};

  Future<Map<String, dynamic>> _api(String op,
          [Map<String, dynamic> body = const {}]) =>
      _request(op, {...body, 'clientId': _clientId});

  Future<void> initialize(Account value) async {
    if (account?.id == value.id) return;
    final generation = ++_generation;
    _timer?.cancel();
    await _closeMedia(restore: false);
    if (generation != _generation) return;
    account = value;
    _ending.clear();
    current = null;
    notice = null;
    final prefs = await SharedPreferences.getInstance();
    _clientId = prefs.getString('friend_call_client');
    if (_clientId == null) {
      final random = Random.secure();
      _clientId = List.generate(
              24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join();
      await prefs.setString('friend_call_client', _clientId!);
    }
    if (generation != _generation) return;
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => poll());
    await poll();
  }

  void _notify() {
    notifyListeners();
  }

  void _show(String message) {
    notice = message;
    _noticeTimer?.cancel();
    _noticeTimer = Timer(const Duration(milliseconds: 2200), () {
      notice = null;
      _notify();
    });
    _notify();
  }

  Future<void> logout() async {
    try {
      if (current != null && current!['owned'] == true) {
        await _api('call-end', {'callId': current!['id']});
      }
    } catch (_) {}
    ++_generation;
    _timer?.cancel();
    _noticeTimer?.cancel();
    notice = null;
    account = null;
    current = null;
    await _closeMedia(restore: false);
    _notify();
  }

  Future<void> start(Map<String, dynamic> peer, String kind) =>
      _action(() async {
        if (current != null) throw StateError('你正在通话，请先结束当前通话');
        final generation = _generation;
        final result =
            await _api('call-start', {'peerId': peer['id'], 'kind': kind});
        if (generation != _generation) return;
        current = Map<String, dynamic>.from(result['call']);
        openScreen();
        _notify();
        await poll();
      });
  Future<void> answer() => _action(() async {
        final id = current!['id'] as String;
        await _clearNotification(id);
        await _api('call-decision', {'callId': current!['id'], 'accept': true});
        await poll();
        if (current?['status'] == 'active') openScreen();
      });
  Future<void> hangup() => _action(() async {
        final call = current;
        if (call == null) return;
        await _clearNotification(call['id']);
        final operation =
            call['status'] == 'ringing' && call['role'] == 'callee'
                ? 'call-decision'
                : 'call-end';
        final body = <String, dynamic>{
          'callId': call['id'],
          if (operation == 'call-decision') 'accept': false
        };
        _ending[call['id']] = {'operation': operation, 'body': body};
        current = null;
        await _closeMedia();
        _notify();
        if (call['status'] == 'ringing' && call['role'] == 'callee') {
          await _api('call-decision', {'callId': call['id'], 'accept': false});
        } else {
          await _api('call-end', {'callId': call['id']});
        }
        _ending.remove(call['id']);
      });
  Future<void> _action(Future<void> Function() action) async {
    if (busy) return;
    busy = true;
    notice = null;
    _notify();
    try {
      await action();
    } catch (error) {
      _show(error.toString());
    } finally {
      busy = false;
      _notify();
    }
  }

  static const _reasons = {
    'hangup': '通话已结束',
    'cancelled': '对方取消了通话',
    'rejected': '对方拒绝了通话',
    'unanswered': '对方未接听',
    'offline': '对方已离线，通话已结束',
    'friend_changed': '好友关系已变化，通话已结束'
  };
  Future<void> poll() async {
    if (_polling || account == null || _clientId == null) return;
    _polling = true;
    final generation = _generation;
    try {
      for (final entry in _ending.entries.toList()) {
        try {
          await _api(entry.value['operation'],
              Map<String, dynamic>.from(entry.value['body']));
          _ending.remove(entry.key);
        } catch (_) {}
      }
      final data =
          await _api('call-state', {'skipCallIds': _ending.keys.toList()});
      if (generation != _generation) return;
      _lastSuccess = DateTime.now();
      final calls = (data['calls'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      for (final c in calls) {
        if (c['status'] == 'ended') _ending.remove(c['id']);
      }
      Map<String, dynamic>? next;
      for (final call in calls) {
        if (!_ending.containsKey(call['id']) &&
            call['status'] != 'ended' &&
            (call['owned'] == true ||
                (call['status'] == 'ringing' && call['role'] == 'callee'))) {
          next = call;
          break;
        }
      }
      final previous = current;
      if (previous != null &&
          (next == null ||
              next['id'] != previous['id'] ||
              (previous['status'] == 'ringing' &&
                  next['status'] != 'ringing'))) {
        await _clearNotification(previous['id']);
        if (generation != _generation) return;
      }
      if (next == null) {
        final old = current;
        current = null;
        if (old != null) {
          Map<String, dynamic>? ended;
          for (final c in calls) {
            if (c['id'] == old['id']) {
              ended = c;
            }
          }
          await _closeMedia();
          if (ended?['status'] == 'ended' && ended?['reason'] == 'hangup') {
            // The durable call record already contains the outcome and duration.
            _noticeTimer?.cancel();
            notice = null;
          } else {
            _show(ended?['status'] == 'ended'
                ? (_reasons[ended!['reason']] ?? '通话已结束')
                : '通话已在其他设备接听');
          }
        }
      } else {
        current = next;
        if (next['status'] == 'active' &&
            next['owned'] == true &&
            _joined != next['id'] &&
            !connecting &&
            !_closing) {
          _joined = next['id'];
          connecting = true;
          _notify();
          // Joining runs separately so signaling heartbeats continue during permission prompts.
          _joinFuture = _join(next, generation);
          unawaited(_joinFuture!);
        }
      }
      _notify();
    } catch (error) {
      if (generation != _generation) return;
      if (current != null &&
          DateTime.now().difference(_lastSuccess).inSeconds > 30) {
        final id = current!['id'] as String;
        current = null;
        await _clearNotification(id);
        if (generation != _generation) return;
        await _closeMedia();
        _show('网络已断开，通话已结束');
      } else if (current != null) {
        _show(error.toString());
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> pollForNotification() async {
    final deadline = DateTime.now().add(const Duration(seconds: 16));
    while (_polling && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!_polling) await poll();
  }

  Future<void> _join(Map<String, dynamic> call, int generation) async {
    Room? room;
    List<CallController> paused = [];
    try {
      paused = await CallController.pauseForFriend();
      if (generation != _generation || current?['id'] != call['id']) {
        await CallController.restoreAfterFriend(paused);
        return;
      }
      _paused = paused;
      final grant = Map<String, dynamic>.from(call['grant']);
      room = Room(
          roomOptions: const RoomOptions(
        adaptiveStream: false,
        // Native background overlays do not register Flutter visibility. Keep
        // subscriptions alive; the SFU still adapts layers to actual bandwidth.
        dynacast: true,
        defaultVideoPublishOptions: callVideoPublishOptions,
      ));
      _room = room;
      await room.connect(grant['livekitUrl'], grant['token'],
          connectOptions: ConnectOptions(
              rtcConfiguration: defaultTargetPlatform == TargetPlatform.android
                  ? const FriendRTCConfiguration()
                  : const RTCConfiguration()));
      if (generation != _generation || current?['id'] != call['id']) {
        await room.disconnect();
        return;
      }
      media = CallController(room,
          peerIdentity: grant['peerIdentity'],
          showFloatingVideo: true,
          floatingCallId: call['id'],
          floatingAccountId: account?.id,
          floatingKind: call['kind'],
          floatingPeerName: call['peerName'],
          floatingAcceptedAt: (call['acceptedAt'] as num?)?.toInt(),
          clientId: _clientId,
          friendCall: true);
      media!.setFloatingVideoVisible(!screenVisible);
      media!.addListener(_notify);
      _events = room.createListener()
        ..on<ParticipantDisconnectedEvent>((event) {
          if (event.participant.identity == grant['peerIdentity']) {
            unawaited(hangup());
          }
        })
        ..on<RoomDisconnectedEvent>((event) {
          if (current?['id'] == call['id']) {
            unawaited(hangup());
          }
        });
      try {
        await media!.toggleMicrophone();
      } catch (e) {
        _show(e.toString());
      }
      if (call['kind'] == 'video' && current?['id'] == call['id']) {
        try {
          await media!.toggleCamera();
        } catch (e) {
          _show(e.toString());
        }
      }
    } catch (error) {
      if (generation == _generation && current?['id'] == call['id']) {
        _show('连接通话失败：$error');
        try {
          await _api('call-end', {'callId': call['id']});
        } catch (_) {}
        current = null;
      }
      // Cleanup is performed after this join future finishes; never await ourselves.
      if (generation == _generation) {
        scheduleMicrotask(() => _closeMedia());
      }
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> _closeMedia({bool restore = true}) async {
    if (_closing) return;
    _closing = true;
    try {
      _joined = null;
      _events?.dispose();
      _events = null;
      media?.removeListener(_notify);
      media?.close();
      media = null;
      final room = _room;
      _room = null;
      await room?.disconnect();
      // A pending permission action observes current==null before publishing further media.
      if (_joinFuture != null) {
        try {
          await _joinFuture;
        } catch (_) {}
        _joinFuture = null;
      }
      await room?.dispose();
      final paused = _paused;
      _paused = [];
      if (restore) {
        await CallController.restoreAfterFriend(paused);
      } else {
        CallController.friendAudioActive = false;
      }
    } finally {
      connecting = false;
      _closing = false;
    }
  }

  Future<void> toggleMicrophone() => _action(() async {
        await media?.toggleMicrophone();
      });
  Future<void> toggleCamera() => _action(() async {
        await media?.toggleCamera();
      });
  Future<void> toggleSpeaker() => _action(() async {
        await media?.toggleSpeaker();
      });
}

String callStatus(FriendCalls calls) {
  final call = calls.current;
  if (call == null) return '通话已结束';
  if (call['status'] == 'ringing') {
    return call['role'] == 'callee' ? '邀请你通话' : '等待对方接听';
  }
  if (calls.connecting) return '正在连接通话…';
  final started = (call['acceptedAt'] as num?)?.toInt();
  final seconds = started == null
      ? 0
      : ((DateTime.now().millisecondsSinceEpoch - started) ~/ 1000)
          .clamp(0, 999999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class FriendCallOverlay extends StatelessWidget {
  const FriendCallOverlay({super.key, required this.child});
  final Widget child;
  Widget _incomingCard(Map<String, dynamic> call) => Row(
        children: [
          AccountAvatar(
              key: const ValueKey('incoming-call-avatar'),
              accountId: call['peerId'],
              avatarId: call['peerAvatarId'],
              revision: call['peerAvatarRevision'] ?? '',
              preferCurrent: true,
              size: 44),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                Text(call['peerName'],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                Text(call['kind'] == 'video' ? '视频来电' : '语音来电',
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF8390A5))),
              ])),
          const SizedBox(width: 12),
          Semantics(
              label: '接通',
              button: true,
              child: IconButton.filled(
                  key: const ValueKey('incoming-call-answer'),
                  style: IconButton.styleFrom(
                      minimumSize: const Size(40, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: AppTheme.success,
                      foregroundColor: Colors.white),
                  onPressed: friendCalls.busy ? null : friendCalls.answer,
                  icon: const Icon(Icons.call_rounded, size: 18))),
          const SizedBox(width: 8),
          Semantics(
              label: '挂断',
              button: true,
              child: IconButton.filled(
                  key: const ValueKey('incoming-call-hangup'),
                  style: IconButton.styleFrom(
                      minimumSize: const Size(40, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      backgroundColor: AppTheme.danger,
                      foregroundColor: Colors.white),
                  onPressed: friendCalls.busy ? null : friendCalls.hangup,
                  icon: const Icon(Icons.call_end_rounded, size: 18))),
        ],
      );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: friendCalls,
      builder: (context, _) {
        final call = friendCalls.current;
        final incoming =
            call?['status'] == 'ringing' && call?['role'] == 'callee';
        final miniVideo = call?['kind'] == 'video' &&
            call?['status'] == 'active' &&
            !friendCalls.screenVisible;
        return Stack(children: [
          child,
          if (miniVideo && friendCalls.media?.floatingVideoVisible != true)
            Positioned.fill(
                child: FriendCallMiniPlayer(
              key: ValueKey('mini-${call!['id']}'),
              onReturn: friendCalls.openScreen,
              video: friendCalls.media?.remoteCameraTrack != null
                  ? CallCameraView(friendCalls.media!.remoteCameraTrack!)
                  : ColoredBox(
                      color: const Color(0xFF152238),
                      child: Center(
                          child: AccountAvatar(
                              accountId: call['peerId'],
                              avatarId: call['peerAvatarId'],
                              revision: call['peerAvatarRevision'] ?? '',
                              size: 64))),
            )),
          if (call != null &&
              !friendCalls.screenVisible &&
              !miniVideo &&
              (incoming || friendCalls.media?.floatingVideoVisible != true))
            Positioned(
              right: 16,
              left: incoming ? 16 : null,
              top: incoming ? MediaQuery.paddingOf(context).top + 8 : null,
              bottom:
                  incoming ? null : MediaQuery.paddingOf(context).bottom + 84,
              child: Material(
                color: Colors.white,
                elevation: 3,
                shadowColor: const Color(0x22152340),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(incoming ? 16 : 28),
                    side: const BorderSide(color: AppTheme.line)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(28),
                  onTap: friendCalls.openScreen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: incoming
                        ? _incomingCard(call)
                        : Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(
                                call['kind'] == 'video'
                                    ? Icons.videocam_outlined
                                    : Icons.call_outlined,
                                size: 20,
                                color: AppTheme.success),
                            const SizedBox(width: 10),
                            Text('返回通话 · ${callStatus(friendCalls)}',
                                style: const TextStyle(
                                    color: AppTheme.text, fontSize: 13)),
                            Semantics(
                                label: '挂断',
                                button: true,
                                child: IconButton(
                                    onPressed: friendCalls.busy
                                        ? null
                                        : friendCalls.hangup,
                                    icon: const Icon(Icons.call_end_rounded,
                                        color: Color(0xFFE45C64)))),
                          ]),
                  ),
                ),
              ),
            ),
          if (friendCalls.notice != null)
            Positioned(
                left: 24,
                right: 24,
                bottom: MediaQuery.paddingOf(context).bottom + 145,
                child: Material(
                    color: const Color(0xFF253047),
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(friendCalls.notice!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12))))),
        ]);
      });
}

class FriendCallScreen extends StatefulWidget {
  const FriendCallScreen({super.key});
  @override
  State<FriendCallScreen> createState() => _FriendCallScreenState();
}

class _FriendCallScreenState extends State<FriendCallScreen> {
  Timer? _clock;
  final _remoteVideoKey = GlobalKey(), _localVideoKey = GlobalKey();
  bool _folding = false, _allowPop = false;
  Future<void> _fold() async {
    if (_folding) return;
    _folding = true;
    final media = friendCalls.media;
    final callId = friendCalls.current?['id'];
    try {
      if (media != null && defaultTargetPlatform == TargetPlatform.android) {
        if (!await NativeVideoOverlay.hasPermission()) {
          if (!mounted) return;
          final authorize = await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                    title: const Text('开启悬浮窗'),
                    content: const Text(
                        '允许 RemoteScreen 显示在其他应用上层，收起后才能显示通话悬浮窗并返回通话。'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(dialog, false),
                          child: const Text('取消')),
                      FilledButton(
                          onPressed: () => Navigator.pop(dialog, true),
                          child: const Text('去授权'))
                    ],
                  ));
          if (authorize == true) await NativeVideoOverlay.requestPermission();
          return;
        }
        if (!mounted || friendCalls.current?['id'] != callId) return;
        if (!await media.openFloatingVideo()) {
          media.setFloatingVideoVisible(false);
          friendCalls._show('打开通话悬浮窗失败，请重试');
          return;
        }
      }
      if (!mounted || friendCalls.current?['id'] != callId) return;
      setState(() => _allowPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted && friendCalls.current?['id'] == callId) {
        friendCalls._show('打开通话悬浮窗失败，请在系统设置中允许悬浮窗权限后重试');
      }
    } finally {
      _folding = false;
      if (friendCalls.current == null) _callChanged();
    }
  }

  Widget _videoPlaceholder(
          {required bool local, required Map<String, dynamic>? call}) =>
      ColoredBox(
          color: const Color(0xFF152238),
          child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            AccountAvatar(
                accountId: local ? friendCalls.account?.id : call?['peerId'],
                avatarId: local
                    ? friendCalls.account?.avatarId
                    : call?['peerAvatarId'],
                revision: local
                    ? friendCalls.account?.avatarRevision ?? ''
                    : call?['peerAvatarRevision'] ?? '',
                size: local ? 52 : 96),
            const SizedBox(height: 12),
            Text(local ? '摄像头已关闭' : '等待对方视频',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white54, fontSize: 11)),
          ])));
  void _callChanged() {
    if (friendCalls.current != null || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          friendCalls.current == null &&
          ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    friendCalls.addListener(_callChanged);
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    friendCalls.removeListener(_callChanged);
    _clock?.cancel();
    super.dispose();
  }

  Widget control(IconData icon, String label, VoidCallback? onTap,
          {bool selected = false,
          bool danger = false,
          bool answer = false,
          bool large = false}) =>
      SizedBox(
          width: large ? 96 : 76,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton.filled(
                tooltip: label,
                onPressed: onTap,
                style: IconButton.styleFrom(
                    backgroundColor: danger
                        ? const Color(0xFFE45C64)
                        : answer
                            ? const Color(0xFF21A67A)
                            : selected
                                ? Colors.white
                                : const Color(0xFF334158),
                    foregroundColor: selected && !danger && !answer
                        ? const Color(0xFF253047)
                        : Colors.white,
                    disabledBackgroundColor: const Color(0xFF334158),
                    disabledForegroundColor: Colors.white38,
                    padding: EdgeInsets.all(large ? 18 : 14)),
                icon: Icon(icon, size: large ? 30 : 24)),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
          ]));
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: friendCalls,
      builder: (context, _) {
        final call = friendCalls.current, media = friendCalls.media;
        final track = media?.remoteCameraTrack;
        final active = call?['status'] == 'active';
        final enabled = active && !friendCalls.busy && !friendCalls.connecting;
        final incoming =
            call?['status'] == 'ringing' && call?['role'] == 'callee';
        if (call?['kind'] == 'video') {
          final localTrack = media?.localCameraTrack;
          return PopScope(
              canPop: _allowPop,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) unawaited(_fold());
              },
              child: Scaffold(
                  backgroundColor: const Color(0xFF152238),
                  body: FriendVideoStage(
                      key: ValueKey(call?['id']),
                      peerName: call?['peerName'] ?? '视频通话',
                      status: callStatus(friendCalls),
                      canHide: active &&
                          !friendCalls.busy &&
                          !friendCalls.connecting,
                      onFold: () => _fold(),
                      remoteView: track != null
                          ? CallCameraView(track, key: _remoteVideoKey)
                          : _videoPlaceholder(local: false, call: call),
                      localView: localTrack != null
                          ? CallCameraView(localTrack, key: _localVideoKey)
                          : _videoPlaceholder(local: true, call: call),
                      controls:
                          Column(mainAxisSize: MainAxisSize.min, children: [
                        if (active)
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              control(
                                  media?.microphoneEnabled == true
                                      ? Icons.mic_none_rounded
                                      : Icons.mic_off_outlined,
                                  media?.microphoneEnabled == true
                                      ? '静音'
                                      : '取消静音',
                                  enabled
                                      ? () => friendCalls.toggleMicrophone()
                                      : null,
                                  selected: media?.microphoneEnabled != true),
                              control(
                                  media?.cameraEnabled == true
                                      ? Icons.videocam_outlined
                                      : Icons.videocam_off_outlined,
                                  media?.cameraEnabled == true
                                      ? '关闭摄像头'
                                      : '打开摄像头',
                                  enabled
                                      ? () => friendCalls.toggleCamera()
                                      : null,
                                  selected: media?.cameraEnabled == true),
                              control(
                                  media?.speakerEnabled == true
                                      ? Icons.volume_up_outlined
                                      : Icons.volume_off_outlined,
                                  media?.speakerEnabled == true
                                      ? '关闭声音'
                                      : '打开声音',
                                  enabled
                                      ? () => friendCalls.toggleSpeaker()
                                      : null,
                                  selected: media?.speakerEnabled == true),
                            ],
                          ),
                        if (active) const SizedBox(height: 16),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 16,
                          children: [
                            if (incoming)
                              control(
                                  Icons.call_rounded,
                                  '接通',
                                  friendCalls.busy
                                      ? null
                                      : () => friendCalls.answer(),
                                  answer: true),
                            control(
                                Icons.call_end_rounded,
                                active || incoming ? '挂断' : '取消',
                                friendCalls.busy
                                    ? null
                                    : () => friendCalls.hangup(),
                                danger: true,
                                large: active),
                          ],
                        ),
                      ]))));
        }
        return PopScope(
            canPop: _allowPop,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) unawaited(_fold());
            },
            child: Scaffold(
                backgroundColor: const Color(0xFF152238),
                body: SafeArea(
                    child: LayoutBuilder(
                        builder: (context, constraints) =>
                            SingleChildScrollView(
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    minHeight: constraints.maxHeight),
                                child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        20, 8, 20, 28),
                                    child: Column(children: [
                                      Row(children: [
                                        IconButton(
                                            tooltip: '收起通话',
                                            onPressed: () => _fold(),
                                            icon: const Icon(
                                                Icons
                                                    .keyboard_arrow_down_rounded,
                                                color: Colors.white)),
                                        const Spacer(),
                                        Text(
                                            call?['kind'] == 'video'
                                                ? '视频通话'
                                                : '语音通话',
                                            style: const TextStyle(
                                                color: Colors.white60,
                                                fontSize: 13)),
                                        const Spacer(),
                                        const SizedBox(width: 48)
                                      ]),
                                      const SizedBox(height: 24),
                                      Text(call?['peerName'] ?? '通话已结束',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 22,
                                              fontWeight: FontWeight.w600)),
                                      const SizedBox(height: 10),
                                      Text(callStatus(friendCalls),
                                          style: const TextStyle(
                                              color: Colors.white60,
                                              fontSize: 13)),
                                      const SizedBox(height: 28),
                                      SizedBox(
                                          height: (constraints.maxHeight * .34)
                                              .clamp(130.0, 320.0),
                                          width: double.infinity,
                                          child: track != null
                                              ? ClipRRect(
                                                  borderRadius:
                                                      BorderRadius.circular(16),
                                                  child: CallCameraView(track))
                                              : Center(
                                                  child: AccountAvatar(
                                                      accountId:
                                                          call?['peerId'],
                                                      preferCurrent: true,
                                                      avatarId:
                                                          call?['peerAvatarId'],
                                                      revision: call?[
                                                              'peerAvatarRevision'] ??
                                                          '',
                                                      size: 112))),
                                      const SizedBox(height: 30),
                                      Wrap(
                                          alignment: WrapAlignment.center,
                                          spacing: 16,
                                          runSpacing: 20,
                                          children: [
                                            if (active) ...[
                                              control(
                                                  media?.microphoneEnabled ==
                                                          true
                                                      ? Icons.mic_none_rounded
                                                      : Icons.mic_off_outlined,
                                                  media?.microphoneEnabled ==
                                                          true
                                                      ? '静音'
                                                      : '取消静音',
                                                  enabled
                                                      ? () => friendCalls
                                                          .toggleMicrophone()
                                                      : null,
                                                  selected: media
                                                          ?.microphoneEnabled !=
                                                      true),
                                              if (call?['kind'] == 'video')
                                                control(
                                                    media?.cameraEnabled == true
                                                        ? Icons
                                                            .videocam_outlined
                                                        : Icons
                                                            .videocam_off_outlined,
                                                    media?.cameraEnabled == true
                                                        ? '关闭摄像头'
                                                        : '打开摄像头',
                                                    enabled
                                                        ? () => friendCalls
                                                            .toggleCamera()
                                                        : null,
                                                    selected:
                                                        media?.cameraEnabled ==
                                                            true),
                                              control(
                                                  media?.speakerEnabled == true
                                                      ? Icons.volume_up_outlined
                                                      : Icons
                                                          .volume_off_outlined,
                                                  media?.speakerEnabled == true
                                                      ? '关闭声音'
                                                      : '打开声音',
                                                  enabled
                                                      ? () => friendCalls
                                                          .toggleSpeaker()
                                                      : null,
                                                  selected:
                                                      media?.speakerEnabled ==
                                                          true),
                                            ],
                                            if (incoming)
                                              control(
                                                  Icons.call_rounded,
                                                  '接通',
                                                  friendCalls.busy
                                                      ? null
                                                      : () =>
                                                          friendCalls.answer(),
                                                  answer: true),
                                            if (call != null)
                                              control(
                                                  Icons.call_end_rounded,
                                                  incoming
                                                      ? '挂断'
                                                      : active
                                                          ? '挂断'
                                                          : '取消',
                                                  friendCalls.busy
                                                      ? null
                                                      : () =>
                                                          friendCalls.hangup(),
                                                  danger: true),
                                          ]),
                                      if (call == null)
                                        Padding(
                                            padding:
                                                const EdgeInsets.only(top: 24),
                                            child: TextButton(
                                                onPressed: () =>
                                                    Navigator.of(context).pop(),
                                                child: const Text('返回聊天'))),
                                    ])),
                              ),
                            )))));
      });
}
