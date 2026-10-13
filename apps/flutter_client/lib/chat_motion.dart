import 'package:flutter/material.dart';
import 'app_motion.dart';

/// Client IDs join an outgoing placeholder to its confirmed server message.
String chatMotionIdentity(Map<String, dynamic> message) {
  final clientId = message['clientId'];
  return '${message['senderId']}:${clientId is String && clientId.isNotEmpty ? clientId : message['id']}';
}

/// History, polling, retries and virtualization never replay arrival effects.
class ChatArrivals {
  ChatArrivals({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _seen = <String>{};
  final _pending = <String, DateTime>{};

  void observe(Iterable<Map<String, dynamic>> messages,
      {required bool animate}) {
    final now = _now();
    _pending.removeWhere((_, at) => now.difference(at).inMilliseconds > 1000);
    final fresh = <String>[];
    for (final message in messages) {
      final id = chatMotionIdentity(message);
      if (_seen.add(id) && animate && message['kind'] != 'recalled') {
        fresh.add(id);
      }
    }
    // A reconnect must not cascade animations through an entire backlog.
    for (final id in fresh.skip(fresh.length > 6 ? fresh.length - 6 : 0)) {
      _pending[id] = now;
    }
  }

  bool take(String id) {
    final at = _pending.remove(id);
    return at != null && _now().difference(at).inMilliseconds <= 1000;
  }
}

/// Paint-only arrival: message height and the reader's scroll anchor stay fixed.
class ChatMessageArrival extends StatefulWidget {
  const ChatMessageArrival({
    super.key,
    required this.animate,
    required this.child,
  });
  final bool animate;
  final Widget child;

  @override
  State<ChatMessageArrival> createState() => _ChatMessageArrivalState();
}

class _ChatMessageArrivalState extends State<ChatMessageArrival>
    with SingleTickerProviderStateMixin {
  late final _controller =
      AnimationController(vsync: this, duration: AppMotion.content, value: 1);
  late final _progress = _controller.drive(CurveTween(curve: AppMotion.curve));
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller.value = 1;
    } else if (!_initialized && widget.animate) {
      _controller.forward(from: 0);
    }
    _initialized = true;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
      opacity: _progress.drive(Tween(begin: .45, end: 1.0)),
      child: AnimatedBuilder(
          animation: _progress,
          builder: (_, child) => Transform.translate(
              offset: Offset(0, 6 * (1 - _progress.value)), child: child),
          child: widget.child));
}
