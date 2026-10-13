import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_motion.dart';

Map<String, dynamic> message(String id,
        {String? clientId, String kind = 'text'}) =>
    {
      'id': id,
      'senderId': 'alice',
      'kind': kind,
      if (clientId != null) 'clientId': clientId,
    };

void main() {
  test('history, polling, acknowledgement and retries do not replay arrivals',
      () {
    final arrivals = ChatArrivals();
    final history = message('history'),
        local = message('local_a', clientId: 'a');
    final confirmed = message('server_a', clientId: 'a');
    arrivals.observe([history], animate: false);
    arrivals.observe([history, local], animate: true);
    expect(arrivals.take(chatMotionIdentity(history)), isFalse);
    expect(arrivals.take(chatMotionIdentity(local)), isTrue);
    arrivals.observe([confirmed], animate: true);
    expect(arrivals.take(chatMotionIdentity(confirmed)), isFalse);
    arrivals.observe([message('old')], animate: false);
    arrivals.observe([message('old'), message('recall', kind: 'recalled')],
        animate: true);
    expect(arrivals.take(chatMotionIdentity(message('old'))), isFalse);
    expect(arrivals.take(chatMotionIdentity(message('recall'))), isFalse);
  });

  test('reconnect backlog is bounded and offscreen arrivals expire', () {
    expect(chatMotionIdentity(message('a', clientId: '')),
        isNot(chatMotionIdentity(message('b', clientId: ''))));
    var now = DateTime(2026, 10, 13);
    final arrivals = ChatArrivals(now: () => now);
    final batch = List.generate(50, (i) => message('$i'));
    arrivals.observe(batch, animate: true);
    expect(batch.where((m) => arrivals.take(chatMotionIdentity(m))).length, 6);
    arrivals.observe([message('late')], animate: true);
    now = now.add(const Duration(seconds: 2));
    expect(arrivals.take(chatMotionIdentity(message('late'))), isFalse);
  });

  testWidgets(
      'arrival preserves layout, survives rebuild and settles immediately with reduced motion',
      (tester) async {
    Widget screen({bool reduced = false, bool animate = true}) => MaterialApp(
          home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduced),
              child: Scaffold(
                body: Column(children: [
                  ChatMessageArrival(
                      key: const ValueKey('arrival'),
                      animate: animate,
                      child: const SizedBox(
                          width: 200, height: 80, child: Text('新消息'))),
                  const SizedBox(key: ValueKey('anchor'), height: 20),
                ]),
              )),
        );
    await tester.pumpWidget(screen());
    final anchor = tester.getTopLeft(find.byKey(const ValueKey('anchor')));
    final fade = find.descendant(
        of: find.byType(ChatMessageArrival),
        matching: find.byType(FadeTransition));
    final initial = tester.widget<FadeTransition>(fade).opacity.value;
    expect(initial, lessThan(1));
    await tester.pump(const Duration(milliseconds: 70));
    final midway = tester.widget<FadeTransition>(fade).opacity.value;
    expect(midway, greaterThan(initial));
    await tester.pumpWidget(screen(animate: false));
    expect(tester.widget<FadeTransition>(fade).opacity.value,
        greaterThanOrEqualTo(midway));
    expect(tester.getTopLeft(find.byKey(const ValueKey('anchor'))), anchor);
    await tester.pumpWidget(screen(reduced: true));
    expect(tester.widget<FadeTransition>(fade).opacity.value, 1);
    expect(tester.getTopLeft(find.byKey(const ValueKey('anchor'))), anchor);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
