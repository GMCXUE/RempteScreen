import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;

/// Shared timing for small interactions. Video renderers must stay outside the
/// content transitions; animate their surrounding controls instead.
abstract final class AppMotion {
  static const feedback = Duration(milliseconds: 120);
  static const content = Duration(milliseconds: 200);
  static const panel = Duration(milliseconds: 240);
  static const curve = Cubic(.2, .8, .2, 1);

  static bool reduced(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context) ||
      MediaQuery.accessibleNavigationOf(context);

  static Duration duration(BuildContext context, Duration value) =>
      reduced(context) ? Duration.zero : value;

  static AnimationStyle style(BuildContext context,
          {Duration duration = panel, Duration reverseDuration = content}) =>
      reduced(context)
          ? AnimationStyle.noAnimation
          : AnimationStyle(
              duration: duration,
              reverseDuration: reverseDuration,
              curve: curve,
              reverseCurve: curve,
            );

  static const pageTransitions = PageTransitionsTheme(builders: {
    TargetPlatform.android:
        AppPageTransitionsBuilder(PredictiveBackPageTransitionsBuilder()),
    TargetPlatform.iOS:
        AppPageTransitionsBuilder(CupertinoPageTransitionsBuilder()),
    TargetPlatform.macOS:
        AppPageTransitionsBuilder(CupertinoPageTransitionsBuilder()),
    TargetPlatform.windows:
        AppPageTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
    TargetPlatform.linux:
        AppPageTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
    TargetPlatform.fuchsia:
        AppPageTransitionsBuilder(FadeForwardsPageTransitionsBuilder()),
  });
}

/// Retains Flutter's platform back-gesture detectors. With reduced motion,
/// programmatic navigation has no visual travel; direct manipulation still
/// follows the finger so a predictive-back or iOS edge gesture can be canceled.
class AppPageTransitionsBuilder extends PageTransitionsBuilder {
  const AppPageTransitionsBuilder(this.platformBuilder);

  final PageTransitionsBuilder platformBuilder;

  @override
  Duration get transitionDuration => AppMotion.panel;

  @override
  Duration get reverseTransitionDuration => AppMotion.content;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final stationary =
        AppMotion.reduced(context) && !route.popGestureInProgress;
    return platformBuilder.buildTransitions(
      route,
      context,
      stationary ? const AlwaysStoppedAnimation(1.0) : animation,
      stationary ? const AlwaysStoppedAnimation(0.0) : secondaryAnimation,
      child,
    );
  }
}

/// Animates the new content without keeping an outgoing copy alive. In
/// particular, rapid tab changes cannot duplicate a GlobalKey or a controller.
/// Keep [identity] stable when only the contents of the current page refresh.
class AppContentTransition extends StatefulWidget {
  const AppContentTransition({
    super.key,
    required this.identity,
    required this.child,
    this.animate = true,
  });

  final Object? identity;
  final Widget child;
  final bool animate;

  @override
  State<AppContentTransition> createState() => _AppContentTransitionState();
}

class _AppContentTransitionState extends State<AppContentTransition>
    with SingleTickerProviderStateMixin {
  late final _controller =
      AnimationController(vsync: this, duration: AppMotion.content, value: 1);
  late final _progress = _controller.drive(CurveTween(curve: AppMotion.curve));
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    if (_reduced || !widget.animate) _controller.value = 1;
  }

  @override
  void didUpdateWidget(AppContentTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduced || !widget.animate) {
      _controller.value = 1;
    } else if (oldWidget.identity != widget.identity) {
      _controller.forward(from: 0);
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
            offset: Offset(0, 8 * (1 - _progress.value)),
            child: child,
          ),
          child: widget.child,
        ),
      );
}

/// One retained child with interruptible visibility. Hidden controls stop
/// accepting taps, keyboard focus and accessibility navigation immediately,
/// even while their last frame fades away. Their own tickers stop when hidden.
class AppVisibilityTransition extends StatefulWidget {
  const AppVisibilityTransition({
    super.key,
    required this.visible,
    required this.child,
    this.collapse = false,
    this.alignment = Alignment.topCenter,
  });

  final bool visible;
  final Widget child;
  final bool collapse;
  final Alignment alignment;

  @override
  State<AppVisibilityTransition> createState() =>
      _AppVisibilityTransitionState();
}

class _AppVisibilityTransitionState extends State<AppVisibilityTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
      vsync: this,
      duration: AppMotion.panel,
      reverseDuration: AppMotion.content,
      value: widget.visible ? 1 : 0);
  late final _progress = _controller.drive(CurveTween(curve: AppMotion.curve));
  bool _reduced = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _updateVisibility();
  }

  @override
  void didUpdateWidget(AppVisibilityTransition oldWidget) {
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
  Widget build(BuildContext context) {
    Widget result = IgnorePointer(
      ignoring: !widget.visible,
      child: ExcludeSemantics(
        excluding: !widget.visible,
        child: ExcludeFocus(
          excluding: !widget.visible,
          child: TickerMode(
            enabled: widget.visible,
            child: FadeTransition(opacity: _progress, child: widget.child),
          ),
        ),
      ),
    );
    if (widget.collapse) {
      result = SizeTransition(
        sizeFactor: _progress,
        alignment: widget.alignment,
        child: result,
      );
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Offstage(
        offstage: !widget.visible && _controller.isDismissed,
        child: child,
      ),
      child: result,
    );
  }
}
