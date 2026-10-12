import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'remote_camera_view.dart';
import 'session_manager.dart';
import 'viewer_chrome.dart';
import 'viewer_viewport.dart';

/// 观看某一路会话的画面。
///
/// 连接由 SessionManager 持有 —— 从这个页面返回**不会**断开连接，
/// 会话仍在「会话」列表里，随时可以回来看。
/// 真正断开的条件只有两个：在会话页或这里点「断开」，或对端停止投送。
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.manager,
    required this.sessionId,
  });

  final SessionManager manager;
  final String sessionId;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen>
    with WidgetsBindingObserver {
  bool _controlsVisible = true;
  bool _fullscreen = false;
  bool _viewportBusy = false;
  int _viewportGeneration = 0;
  Timer? _controlsTimer;
  RTCVideoRenderer? _renderer;
  lk.RemoteVideoTrack? _attachedTrack;
  int _renderGeneration = 0;

  ViewingSession get session =>
      widget.manager.sessionById(widget.sessionId) ?? _lastKnown;

  // 会话可能已被断开（manager 里查不到），仍保留最后一次状态用于展示
  late ViewingSession _lastKnown;

  /// 防止重复收起页面（断开按钮与状态回调可能同时触发）。
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _lastKnown = widget.manager.sessionById(widget.sessionId)!;
    widget.manager.addListener(_onManagerChanged);
    _attach();
    WidgetsBinding.instance.addObserver(this);
    _scheduleHide();
  }

  @override
  void dispose() {
    // 关键：这里**不**断开连接 —— 连接由 SessionManager 持有
    _controlsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_restoreViewport());
    widget.manager.removeListener(_onManagerChanged);
    _teardownRenderer();
    super.dispose();
  }

  /// 拆掉渲染器。
  ///
  /// 必须在页面被弹出**之前**做：否则会有一帧拿着已经销毁的轨道去渲染，
  /// 原生层直接抛异常（真机上表现为满屏红）。
  void _teardownRenderer() {
    _renderGeneration++;
    final renderer = _renderer;
    _renderer = null;
    _attachedTrack = null;
    if (renderer != null) {
      renderer.srcObject = null;
      renderer.dispose();
    }
  }

  void _onManagerChanged() {
    if (!mounted || _closing) return;

    // 会话被断开 → 先撤渲染器，再收起页面
    if (session.state == ViewingSessionState.ended) {
      final messenger = ScaffoldMessenger.of(context);
      final notice = session.endedByPeer ? '${session.deviceName} 已停止投送' : null;
      _closeViewer();
      if (notice != null) {
        messenger.showSnackBar(SnackBar(content: Text(notice)));
      }
      return;
    }
    _attach();
    if (session.state != ViewingSessionState.live || session.call.busy) {
      _controlsTimer?.cancel();
      _controlsVisible = true;
    } else if (_controlsVisible && !(_controlsTimer?.isActive ?? false)) {
      _scheduleHide();
    }
    setState(() {});
  }

  Future<void> _toggleCall(Future<void> Function() action) async {
    _showControls();
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('通话操作失败：$error')),
      );
    } finally {
      _scheduleHide();
    }
  }

  void _closeViewer() {
    if (_closing) return;
    _closing = true;
    _viewportGeneration++;
    _controlsTimer?.cancel();
    _teardownRenderer();
    if (!mounted) return;
    setState(() => _fullscreen = false);
    unawaited(_restoreViewport());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  Future<void> _attach() async {
    final track = session.videoTrack;
    if (track == _attachedTrack || _closing) return;
    _teardownRenderer();
    _attachedTrack = track;
    final generation = _renderGeneration;
    if (track == null) return;
    final renderer = RTCVideoRenderer();
    try {
      await renderer.initialize();
      if (!mounted ||
          _closing ||
          generation != _renderGeneration ||
          session.videoTrack != track) {
        await renderer.dispose();
        return;
      }
      renderer.srcObject = track.mediaStream;
      setState(() => _renderer = renderer);
    } catch (error) {
      await renderer.dispose();
      if (generation == _renderGeneration) _attachedTrack = null;
      debugPrint('画面渲染失败：$error');
    }
  }

  void _scheduleHide() {
    _controlsTimer?.cancel();
    if (!_controlsVisible ||
        _closing ||
        _viewportBusy ||
        session.state != ViewingSessionState.live ||
        session.call.busy) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_closing && !session.call.busy) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _showControls() {
    if (!mounted || _closing) return;
    setState(() => _controlsVisible = true);
    _scheduleHide();
  }

  void _toggleControls() {
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = !_controlsVisible);
    _scheduleHide();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _showControls();
    } else {
      _controlsTimer?.cancel();
    }
  }

  Future<void> _restoreViewport() async {
    try {
      await ViewerViewport.setFullscreen(false);
    } catch (error) {
      debugPrint('恢复观看窗口失败：$error');
    }
  }

  Future<void> _toggleFullscreen() async {
    // Back/exit must work even while the previous enter request is pending.
    if (_closing || (_viewportBusy && !_fullscreen)) return;
    final generation = ++_viewportGeneration;
    final fullscreen = !_fullscreen;
    setState(() {
      _viewportBusy = true;
      _fullscreen = fullscreen;
    });
    _showControls();
    try {
      final renderer = _renderer;
      await ViewerViewport.setFullscreen(fullscreen,
          landscape:
              renderer != null && renderer.videoWidth > renderer.videoHeight);
    } catch (error) {
      if (!mounted || generation != _viewportGeneration) return;
      setState(() => _fullscreen = false);
      await _restoreViewport();
      if (!mounted || generation != _viewportGeneration) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('无法切换全屏，请重试')));
    } finally {
      if (mounted && generation == _viewportGeneration) {
        setState(() => _viewportBusy = false);
        _scheduleHide();
      }
    }
  }

  Future<void> _confirmDisconnect() async {
    _controlsTimer?.cancel();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('断开投屏'),
        content: Text('断开与「${session.deviceName}」的观看连接？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('断开')),
        ],
      ),
    );
    if (!mounted || _closing) return;
    if (confirmed == true) {
      await widget.manager.disconnectSession(session.id);
    } else {
      _scheduleHide();
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = session.call;
    final connected = session.state != ViewingSessionState.ended &&
        session.state != ViewingSessionState.peerEnded;
    final status = switch (session.state) {
      ViewingSessionState.live => '正在观看',
      ViewingSessionState.connecting => '正在连接…',
      ViewingSessionState.waiting => '等待对方开始投送…',
      ViewingSessionState.reconnecting => '网络波动，重连中…',
      _ => '投屏已结束',
    };
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _fullscreen) unawaited(_toggleFullscreen());
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF080A0E),
          body: ViewerChrome(
            title: session.deviceName,
            status: status,
            live: session.state == ViewingSessionState.live,
            visible: _controlsVisible,
            fullscreen: _fullscreen,
            onToggleControls: _toggleControls,
            onFullscreen: _toggleFullscreen,
            onBack: () {
              if (_fullscreen) {
                _toggleFullscreen();
              } else {
                _closeViewer();
              }
            },
            onDisconnect: _confirmDisconnect,
            camera: call.remoteCameraTrack == null
                ? null
                : RemoteCameraView(track: call.remoteCameraTrack),
            controls: [
              _controlButton(
                  icon: call.screenAudioEnabled
                      ? Icons.speaker_rounded
                      : Icons.volume_off_rounded,
                  label: call.screenAudioEnabled ? '投屏声音' : '投屏静音',
                  active: call.screenAudioEnabled,
                  onPressed: connected
                      ? () => _toggleCall(call.toggleScreenAudio)
                      : null),
              _controlButton(
                  icon: call.microphoneEnabled
                      ? Icons.mic_rounded
                      : Icons.mic_off_rounded,
                  label: call.microphoneEnabled ? '麦克风' : '麦克风关',
                  active: call.microphoneEnabled,
                  onPressed: connected && !call.busy
                      ? () => _toggleCall(call.toggleMicrophone)
                      : null),
              _controlButton(
                  icon: call.speakerEnabled
                      ? Icons.volume_up_rounded
                      : Icons.volume_off_rounded,
                  label: call.speakerEnabled ? '通话声音' : '通话静音',
                  active: call.speakerEnabled,
                  onPressed:
                      connected ? () => _toggleCall(call.toggleSpeaker) : null),
            ],
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _controlButton(
          {required IconData icon,
          required String label,
          required bool active,
          required VoidCallback? onPressed}) =>
      Expanded(
        child: ViewerIconButton(
            icon: icon,
            label: label,
            active: active,
            onPressed: onPressed,
            caption: true),
      );

  Widget _buildBody() {
    final state = session.state;

    final renderer = _renderer;
    if (renderer != null && state != ViewingSessionState.ended) {
      return RTCVideoView(
        renderer,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      );
    }

    final hint = switch (state) {
      ViewingSessionState.connecting => '正在连接…',
      ViewingSessionState.waiting => '已连上，等待对方开始投送…',
      ViewingSessionState.reconnecting => '网络波动，重连中…',
      ViewingSessionState.peerEnded => '对方已停止投送',
      ViewingSessionState.ended => '会话已断开',
      _ => '',
    };

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (state == ViewingSessionState.connecting ||
              state == ViewingSessionState.reconnecting)
            const CircularProgressIndicator(color: Colors.white)
          else
            const Icon(Icons.videocam_off, size: 40, color: Colors.grey),
          const SizedBox(height: 14),
          Text(hint, style: const TextStyle(color: Colors.white)),
          const SizedBox(height: 6),
          Text(
            '对方：${session.deviceName}',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}
