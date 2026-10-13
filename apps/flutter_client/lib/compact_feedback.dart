import 'dart:async';
import 'package:flutter/material.dart';
import 'app_motion.dart';

/// A short, non-blocking confirmation; replacing it never queues old messages.
class CompactFeedback {
  OverlayEntry? _entry;
  Timer? _timer;
  Timer? _exitTimer;
  bool _leaving = false;

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    _exitTimer?.cancel();
    _exitTimer = null;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
  }

  void show(BuildContext context, String text, {bool error = false}) {
    dismiss();
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _leaving = false;
    _entry = OverlayEntry(
        builder: (context) => Positioned(
              top: MediaQuery.paddingOf(context).top + 72,
              left: 24,
              right: 24,
              child: IgnorePointer(
                  child: _FeedbackTransition(
                      visible: !_leaving,
                      child: Center(
                          child: Semantics(
                        liveRegion: true,
                        child: Material(
                          key: const ValueKey('compact-feedback'),
                          color: const Color(0xED253047),
                          borderRadius: BorderRadius.circular(24),
                          elevation: 3,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            child:
                                Row(mainAxisSize: MainAxisSize.min, children: [
                              Icon(
                                  error
                                      ? Icons.info_outline
                                      : Icons.check_rounded,
                                  size: 16,
                                  color: Colors.white),
                              const SizedBox(width: 7),
                              Flexible(
                                  child: Text(text,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          height: 1.3))),
                            ]),
                          ),
                        ),
                      )))),
            ));
    overlay.insert(_entry!);
    final lifetime = Duration(milliseconds: error ? 2200 : 1200);
    // The deadline is independent of the animation clock. Delayed frames or a
    // paused app cannot keep an expired toast alive, or queue an old message.
    _exitTimer = Timer(lifetime - AppMotion.feedback, () {
      _leaving = true;
      _entry?.markNeedsBuild();
    });
    _timer = Timer(lifetime, dismiss);
  }
}

class _FeedbackTransition extends StatefulWidget {
  const _FeedbackTransition({required this.visible, required this.child});
  final bool visible;
  final Widget child;

  @override
  State<_FeedbackTransition> createState() => _FeedbackTransitionState();
}

class _FeedbackTransitionState extends State<_FeedbackTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: AppMotion.content,
    reverseDuration: AppMotion.feedback,
  );
  late final _progress = _controller.drive(CurveTween(curve: AppMotion.curve));
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _updateVisibility();
  }

  @override
  void didUpdateWidget(_FeedbackTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) _updateVisibility();
  }

  void _updateVisibility() {
    if (_reduced) {
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _progress,
        child: AnimatedBuilder(
          animation: _progress,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, -6 * (1 - _progress.value)),
            child: child,
          ),
          child: widget.child,
        ),
      );
}

/// Report one short notice per failing sync source, until that source recovers.
/// Another successful request must not hide an unrelated failure.
class SyncErrorFeedback {
  final _feedback = CompactFeedback();
  final _failures = <String, String>{};
  String? _shownSource;

  void failed(BuildContext context, String source, Object error) {
    if (ModalRoute.of(context)?.isCurrent == false) return;
    final text = error.toString();
    if (_failures[source] == text) return;
    final alreadyShown = _failures.values.contains(text);
    _failures[source] = text;
    if (alreadyShown) return;
    _shownSource = source;
    _feedback.show(context, text, error: true);
  }

  void recovered(String source) {
    final text = _failures.remove(source);
    if (_shownSource == source) {
      for (final remaining in _failures.entries) {
        if (remaining.value == text) {
          _shownSource = remaining.key;
          return;
        }
      }
      _feedback.dismiss();
      _shownSource = null;
    }
  }

  void dismiss() {
    _feedback.dismiss();
    _failures.clear();
    _shownSource = null;
  }
}
