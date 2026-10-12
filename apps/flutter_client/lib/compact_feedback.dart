import 'dart:async';
import 'package:flutter/material.dart';

/// A short, non-blocking confirmation; replacing it never queues old messages.
class CompactFeedback {
  OverlayEntry? _entry;
  Timer? _timer;

  void dismiss() {
    _timer?.cancel();
    _timer = null;
    _entry?.remove();
    _entry = null;
  }

  void show(BuildContext context, String text, {bool error = false}) {
    dismiss();
    if (!context.mounted) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _entry = OverlayEntry(
        builder: (context) => Positioned(
              top: MediaQuery.paddingOf(context).top + 72,
              left: 24,
              right: 24,
              child: IgnorePointer(
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
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(error ? Icons.info_outline : Icons.check_rounded,
                          size: 16, color: Colors.white),
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
              ))),
            ));
    overlay.insert(_entry!);
    _timer = Timer(Duration(milliseconds: error ? 2200 : 1200), dismiss);
  }
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
