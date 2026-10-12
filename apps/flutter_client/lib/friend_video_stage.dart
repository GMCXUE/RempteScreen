import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'call_camera_view.dart';

/// Swapping and hiding controls only change presentation, never the call tracks.
class FriendVideoStage extends StatefulWidget {
  const FriendVideoStage({
    super.key,
    required this.remoteView,
    required this.localView,
    required this.peerName,
    required this.status,
    required this.controls,
    required this.onFold,
    this.canHide = true,
  });
  final Widget remoteView, localView, controls;
  final String peerName, status;
  final VoidCallback onFold;
  final bool canHide;
  @override
  State<FriendVideoStage> createState() => _FriendVideoStageState();
}

class _FriendVideoStageState extends State<FriendVideoStage> {
  bool _localMain = false, _visible = true, _fill = false;
  Timer? _hideTimer;
  @override
  void initState() {
    super.initState();
    _armHide();
  }

  @override
  void didUpdateWidget(FriendVideoStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.canHide != widget.canHide) {
      if (!widget.canHide) _visible = true;
      _armHide();
    }
  }

  void _armHide() {
    _hideTimer?.cancel();
    if (_visible && widget.canHide) {
      _hideTimer = Timer(const Duration(seconds: 4), () => _show(false));
    }
  }

  void _show(bool visible) {
    if (!mounted) return;
    setState(() => _visible = visible);
    _armHide();
  }

  Widget _fade(Widget child) => IgnorePointer(
      ignoring: !_visible,
      child: ExcludeSemantics(
          excluding: !_visible,
          child: AnimatedOpacity(
              opacity: _visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: child)));

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final landscape =
        MediaQuery.sizeOf(context).width > MediaQuery.sizeOf(context).height;
    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _show(!_visible),
            child: Stack(fit: StackFit.expand, children: [
              Positioned.fill(
                  key: const ValueKey('friend-video-main'),
                  child: Semantics(
                      label: _localMain ? '自己的视频' : '对方视频',
                      // Local SDK video includes tap-to-focus/zoom recognizers.
                      // Presentation gestures belong to the call stage instead.
                      child: CallCameraFit(
                          fill: _fill,
                          child: IgnorePointer(
                              child: _localMain
                                  ? widget.localView
                                  : widget.remoteView)))),
              Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: _fade(Container(
                      decoration: const BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0x99000000), Colors.transparent])),
                      padding: EdgeInsets.fromLTRB(padding.left + 16,
                          padding.top + 12, padding.right + 12, 24),
                      child: Row(children: [
                        Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              Text(widget.peerName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 5),
                              Text(widget.status,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 12)),
                            ])),
                        IconButton(
                            tooltip: _fill ? '完整画面' : '铺满画面',
                            onPressed: () {
                              setState(() => _fill = !_fill);
                              _armHide();
                            },
                            icon: Icon(_fill ? Icons.fit_screen : Icons.crop,
                                color: Colors.white)),
                        IconButton(
                            tooltip: '收起通话',
                            onPressed: widget.onFold,
                            icon: const Icon(Icons.keyboard_arrow_down_rounded,
                                color: Colors.white)),
                      ])))),
              AnimatedPositioned(
                  key: const ValueKey('friend-video-preview'),
                  duration: const Duration(milliseconds: 180),
                  right: padding.right + 16,
                  top: padding.top + (_visible ? 88 : 16),
                  width: landscape ? 104 : 112,
                  height: landscape ? 138 : 150,
                  child: Semantics(
                      label: '切换双方画面',
                      button: true,
                      child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() => _localMain = !_localMain);
                            _armHide();
                          },
                          child: ClipRRect(
                              borderRadius: BorderRadius.circular(16),
                              child: DecoratedBox(
                                  decoration: BoxDecoration(
                                      color: const Color(0xFF1A293C),
                                      borderRadius: BorderRadius.circular(16),
                                      border:
                                          Border.all(color: Colors.white30)),
                                  child: Stack(fit: StackFit.expand, children: [
                                    CallCameraFit(
                                        fill: true,
                                        child: IgnorePointer(
                                            child: _localMain
                                                ? widget.remoteView
                                                : widget.localView)),
                                    Positioned(
                                        left: 8,
                                        right: 8,
                                        bottom: 8,
                                        child: Text(
                                            _localMain ? widget.peerName : '我',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 10,
                                                shadows: [
                                                  Shadow(blurRadius: 4)
                                                ]))),
                                  ])))))),
              Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: _fade(Container(
                      decoration: const BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xBB000000)])),
                      padding: EdgeInsets.fromLTRB(padding.left + 12, 40,
                          padding.right + 12, padding.bottom + 20),
                      child: Listener(
                          onPointerDown: (_) => _hideTimer?.cancel(),
                          onPointerUp: (_) => _armHide(),
                          child:
                              Column(mainAxisSize: MainAxisSize.min, children: [
                            widget.controls,
                            if (widget.canHide)
                              TextButton(
                                  onPressed: () => _show(false),
                                  child: const Text('隐藏控制栏',
                                      style: TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11))),
                          ]))))),
              if (!_visible)
                Positioned(
                    right: padding.right + 16,
                    bottom: padding.bottom + 16,
                    child: TextButton(
                        onPressed: () => _show(true),
                        style: TextButton.styleFrom(
                            backgroundColor: const Color(0x66152238),
                            foregroundColor: Colors.white70,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8)),
                        child: const Text('显示控制栏',
                            style: TextStyle(fontSize: 11)))),
            ])));
  }
}
