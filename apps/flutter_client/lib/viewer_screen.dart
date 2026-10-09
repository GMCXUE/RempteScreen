import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import 'session_manager.dart';

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

class _ViewerScreenState extends State<ViewerScreen> {
  RTCVideoRenderer? _renderer;
  lk.RemoteVideoTrack? _attachedTrack;

  ViewingSession get session =>
      widget.manager.sessionById(widget.sessionId) ?? _lastKnown;

  // 会话可能已被断开（manager 里查不到），仍保留最后一次状态用于展示
  late ViewingSession _lastKnown;

  @override
  void initState() {
    super.initState();
    _lastKnown = widget.manager.sessionById(widget.sessionId)!;
    widget.manager.addListener(_onManagerChanged);
    _attach();
  }

  @override
  void dispose() {
    // 关键：这里**不**断开连接 —— 连接由 SessionManager 持有
    widget.manager.removeListener(_onManagerChanged);
    _renderer?.srcObject = null;
    _renderer?.dispose();
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;

    // 会话被手动断开 → 回到列表页
    if (session.state == ViewingSessionState.ended) {
      Navigator.of(context).pop();
      return;
    }
    _attach();
    setState(() {});
  }

  Future<void> _attach() async {
    final track = session.videoTrack;
    if (track == null || track == _attachedTrack) return;

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = track.mediaStream;

    if (!mounted) return;
    setState(() {
      _attachedTrack = track;
      _renderer = renderer;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(session.deviceName, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () {
              widget.manager.disconnectSession(session.id);
              if (mounted && Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('断开', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    final state = session.state;

    if (_renderer != null) {
      return RTCVideoView(
        _renderer!,
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
