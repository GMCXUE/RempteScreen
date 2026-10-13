import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/app_motion.dart';
import 'package:remotescreen/app_theme.dart';
import 'package:remotescreen/compact_feedback.dart';

void main() {
  Widget host(Widget child, {bool reduced = false, bool accessible = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
              disableAnimations: reduced, accessibleNavigation: accessible),
          child: Scaffold(body: child),
        ),
      );

  testWidgets('both accessibility preferences immediately settle content',
      (tester) async {
    for (final accessible in [false, true]) {
      Widget content(Object id, bool reduced) => host(
            AppContentTransition(identity: id, child: const Text('content')),
            reduced: reduced && !accessible,
            accessible: reduced && accessible,
          );
      await tester.pumpWidget(content(0, false));
      final fade = find.descendant(
          of: find.byType(AppContentTransition),
          matching: find.byType(FadeTransition));
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      await tester.pumpWidget(content(1, false));
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.widget<FadeTransition>(fade).opacity.value,
          inExclusiveRange(0, 1));
      await tester.pumpWidget(content(1, true));
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      await tester.pumpWidget(content(2, true));
      expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('rapid content changes retain exactly one keyed child and state',
      (tester) async {
    final key = GlobalKey<_MountProbeState>();
    var created = 0;
    var disposed = 0;
    Widget content(Object id) => host(AppContentTransition(
          identity: id,
          child: _MountProbe(
              key: key, onCreate: () => created++, onDispose: () => disposed++),
        ));
    await tester.pumpWidget(content('home'));
    final state = key.currentState;
    for (var i = 0; i < 8; i++) {
      await tester.pumpWidget(content(i));
      await tester.pump(const Duration(milliseconds: 15));
      expect(key.currentState, same(state));
      expect(find.byKey(key), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(created, 1);
    expect(disposed, 0);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(disposed, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('hidden panels cannot receive input, focus or accessibility',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var taps = 0;
    Widget panel(bool visible) => host(Center(
          child: AppVisibilityTransition(
            visible: visible,
            collapse: true,
            child: SizedBox(
              height: 80,
              width: 160,
              child: TextButton(
                  focusNode: focus,
                  onPressed: () => taps++,
                  child: const Text('panel action')),
            ),
          ),
        ));
    await tester.pumpWidget(panel(false));
    expect(find.text('panel action'), findsNothing);
    expect(find.text('panel action', skipOffstage: false), findsOneWidget);
    await tester.pumpWidget(panel(true));
    await tester.pumpAndSettle();
    final position = tester.getCenter(find.text('panel action'));
    await tester.tapAt(position);
    expect(taps, 1);
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    await tester.pumpWidget(panel(false));
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.tapAt(position);
    expect(taps, 1);
    // Finder.bySemanticsLabel can still see a retained widget's old annotation;
    // the exported semantics tree must no longer contain the hidden control.
    expect(
        tester
            .getSemantics(find.byType(AppVisibilityTransition))
            .toStringDeep(),
        isNot(contains('panel action')));
    // Reversing an unfinished exit does not create another child or restart at 0.
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(panel(true));
    expect(find.text('panel action'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.pumpWidget(panel(false));
    await tester.pumpAndSettle();
    expect(find.text('panel action'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    semantics.dispose();
  });

  testWidgets('reduced motion changes panel layout without a running ticker',
      (tester) async {
    Widget panel(bool visible, bool reduced) => host(
          AppVisibilityTransition(
              visible: visible,
              collapse: true,
              child: const SizedBox(height: 80, child: Text('panel'))),
          reduced: reduced,
        );
    await tester.pumpWidget(panel(false, false));
    await tester.pumpWidget(panel(true, false));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pumpWidget(panel(true, true));
    expect(tester.getSize(find.byType(AppVisibilityTransition)).height, 80);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(panel(false, true));
    expect(find.text('panel'), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('toast animates, replaces immediately and respects its deadline',
      (tester) async {
    final feedback = CompactFeedback();
    addTearDown(feedback.dismiss);
    late BuildContext page;
    await tester.pumpWidget(host(Builder(builder: (context) {
      page = context;
      return const SizedBox();
    })));
    feedback.show(page, 'first');
    await tester.pump();
    final pill = find.byKey(const ValueKey('compact-feedback'));
    final fade =
        find.ancestor(of: pill, matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(fade).opacity.value, 0);
    await tester.pump(const Duration(milliseconds: 240));
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    feedback.show(page, 'replacement');
    await tester.pump();
    expect(find.text('first'), findsNothing);
    expect(find.text('replacement'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1080));
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 60));
    expect(pill, findsNothing);
    feedback.show(page, 'dispose while entering');
    await tester.pump();
    feedback.dismiss();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
    expect(tester.binding.transientCallbackCount, 0);
  });

  Future<void> backGesture(WidgetTester tester, String method,
      [Map<String, Object>? arguments]) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'flutter/backgesture',
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (ByteData? _) {},
    );
  }

  for (final reduced in [false, true]) {
    testWidgets(
        'Android predictive back cancels and commits (reduced=$reduced)',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: AppTheme.light.copyWith(platform: TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: const Scaffold(body: Text('home')),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('details'))));
      await tester.pumpAndSettle();
      for (final commit in [false, true]) {
        await backGesture(tester, 'startBackGesture', {
          'touchOffset': <double>[5, 300],
          'progress': 0.0,
          'swipeEdge': 0,
        });
        await tester.pump();
        expect(nav.currentState!.userGestureInProgress, isTrue);
        await backGesture(tester, 'updateBackGestureProgress', {
          'touchOffset': <double>[100, 300],
          'progress': 0.35,
          'swipeEdge': 0,
        });
        await tester.pump();
        await backGesture(
            tester, commit ? 'commitBackGesture' : 'cancelBackGesture');
        await tester.pumpAndSettle();
        expect(find.text('details'), commit ? findsNothing : findsOneWidget);
      }
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('iOS edge back remains usable (reduced=$reduced)',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        theme: AppTheme.light.copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
          child: child!,
        ),
        home: const Scaffold(body: Text('home')),
      ));
      nav.currentState!.push(MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('details'))));
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(1, 300), const Offset(700, 0));
      await tester.pumpAndSettle();
      expect(find.text('details'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
  }
}

class _MountProbe extends StatefulWidget {
  const _MountProbe(
      {super.key, required this.onCreate, required this.onDispose});
  final VoidCallback onCreate;
  final VoidCallback onDispose;

  @override
  State<_MountProbe> createState() => _MountProbeState();
}

class _MountProbeState extends State<_MountProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('retained');
}
