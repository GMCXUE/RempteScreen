import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/update_history.dart';

void main() {
  testWidgets(
      'history retains page after failure, retries same cursor and handles back',
      (tester) async {
    final cursors = <int?>[];
    var failed = false;
    Future<Map<String, dynamic>> load(int? before) async {
      cursors.add(before);
      if (before == 5 && !failed) {
        failed = true;
        throw Exception('offline');
      }
      return {
        'items': [
          {
            'versionName': before == null ? '0.2.1' : '0.2.0',
            'buildCode': before == null ? 5 : 4,
            'notes': '第一行\n第二行',
            'publishedAt': 1700000000000
          }
        ],
        'next': before == null ? 5 : null
      };
    }

    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('打开'),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) =>
                              UpdateHistoryPage(load: load, currentBuild: 5))),
                )))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.text('当前版本'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pumpAndSettle();
    expect(find.text('版本 0.2.1'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('版本 0.2.0'), findsOneWidget);
    expect(cursors, [null, 5, 5]);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('打开'), findsOneWidget);
  });
  testWidgets('empty history is explicit', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: UpdateHistoryPage(
            currentBuild: 5, load: (_) async => {'items': [], 'next': null})));
    await tester.pumpAndSettle();
    expect(find.text('暂无更新历史'), findsOneWidget);
  });
}
