import 'package:flutter/material.dart';

/// App-local fallback when a system overlay is unavailable.
class FriendCallMiniPlayer extends StatefulWidget {
  const FriendCallMiniPlayer(
      {super.key, required this.video, required this.onReturn});
  final Widget video;
  final VoidCallback onReturn;
  @override
  State<FriendCallMiniPlayer> createState() => _FriendCallMiniPlayerState();
}

class _FriendCallMiniPlayerState extends State<FriendCallMiniPlayer> {
  Offset? _position;
  int _edge = 0;
  static const _videoSize = Size(120, 160), _handleSize = Size(28, 64);

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final padding = MediaQuery.paddingOf(context);
        final size = _edge == 0 ? _videoSize : _handleSize;
        final minY = padding.top + 12;
        final maxY = (box.maxHeight - padding.bottom - size.height - 12)
            .clamp(minY, double.infinity);
        final maxX = (box.maxWidth - size.width).clamp(0.0, double.infinity);
        final origin = _position ??
            Offset(box.maxWidth - _videoSize.width - 16, padding.top + 96);
        final x = _edge < 0
            ? 0.0
            : _edge > 0
                ? maxX
                : origin.dx.clamp(0.0, maxX);
        final y = origin.dy.clamp(minY, maxY);
        return Stack(children: [
          Positioned(
            left: x,
            top: y,
            width: size.width,
            height: size.height,
            child: Semantics(
              label: _edge == 0 ? '视频通话，点击返回，拖到边缘收起' : '展开视频悬浮窗',
              button: true,
              child: GestureDetector(
                key: const ValueKey('friend-call-mini'),
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (_edge == 0) {
                    widget.onReturn();
                    return;
                  }
                  setState(() {
                    _position = Offset(
                        _edge < 0
                            ? 16
                            : (box.maxWidth - _videoSize.width - 16)
                                .clamp(0.0, double.infinity),
                        y);
                    _edge = 0;
                  });
                },
                onPanUpdate: (event) => setState(() {
                  final previous = _position ?? Offset(x, y);
                  _position = Offset(
                      (previous.dx + event.delta.dx).clamp(0.0, maxX),
                      (previous.dy + event.delta.dy).clamp(minY, maxY));
                }),
                onPanEnd: (_) => setState(() {
                  if (_edge != 0) return;
                  final left = _position?.dx ?? x;
                  if (left <= 24) {
                    _edge = -1;
                  } else if (left + _videoSize.width >= box.maxWidth - 24) {
                    _edge = 1;
                  }
                }),
                child: Material(
                  color: const Color(0xFF1A293C),
                  elevation: 5,
                  borderRadius: BorderRadius.circular(_edge == 0 ? 16 : 12),
                  clipBehavior: Clip.antiAlias,
                  child: _edge == 0
                      ? IgnorePointer(child: widget.video)
                      : Icon(
                          _edge < 0
                              ? Icons.chevron_right_rounded
                              : Icons.chevron_left_rounded,
                          color: Colors.white,
                          size: 24),
                ),
              ),
            ),
          )
        ]);
      });
}
