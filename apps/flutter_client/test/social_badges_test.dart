import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/social_screen.dart';

void main() {
  testWidgets('首次同步失败用轻提示和重试入口，恢复后不保留错误栏', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    var offline = true;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SocialScreen(
                  account: Account(
                      id: 'me', email: 'me@example.test', name: '我')))));
      await tester.pumpAndSettle();
      expect(find.text('消息暂时无法同步'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 2300));
      await tester.pumpAndSettle();
      expect(find.text('连不上服务器，请检查网络或服务器地址'), findsNothing);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('连不上服务器，请检查网络或服务器地址'), findsNothing);
      offline = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('消息暂时无法同步'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(find.text('还没有会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async => http.Response(
            jsonEncode(offline
                ? {
                    'error': {
                      'code': 'network',
                      'message': '连不上服务器，请检查网络或服务器地址'
                    }
                  }
                : {
                    'me': {'id': 'me', 'accountId': '123456'},
                    'friends': [],
                    'requests': [],
                    'outgoing': [],
                    'blocked': []
                  }),
            offline ? 503 : 200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
  });

  testWidgets('消息分栏、好友申请和好友列表均保留未读提示', (tester) async {
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    var unread = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SocialScreen(
                  account:
                      Account(id: 'me', email: 'me@example.test', name: '我'),
                  onUnreadChanged: (count) => unread = count))));
      await tester.pumpAndSettle();
      expect(unread, 5);
      expect(find.text('3'),
          findsNWidgets(2)); // messages tab and recent conversation
      expect(find.text('2'), findsOneWidget); // friend requests tab
      await tester.tap(find.text('好友'));
      await tester.pumpAndSettle();
      expect(
          find.text('3'), findsNWidgets(2)); // messages tab and friend avatar
      expect(find.text('好友甲'), findsOneWidget);
      await tester.tap(find.byTooltip('消息与来电提醒'));
      await tester.pumpAndSettle();
      expect(find.text('消息提示音'), findsOneWidget);
      expect(find.text('来电铃声与振动'), findsOneWidget);
      await tester.tap(find.text('消息提示音'));
      await tester.pumpAndSettle();
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches.first.value, isFalse);
      expect(switches.last.value, isTrue);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async => http.Response(
            jsonEncode({
              'me': {'id': 'me', 'accountId': '123456'},
              'friends': [
                {
                  'id': 'peer',
                  'name': '好友甲',
                  'remark': '',
                  'unread': 3,
                  'blocked': false,
                  'online': true,
                  'lastText': '新消息',
                  'accountId': '234567'
                }
              ],
              'requests': [
                {'id': 'r1', 'name': '申请甲', 'note': ''},
                {'id': 'r2', 'name': '申请乙', 'note': ''}
              ],
              'outgoing': [],
              'blocked': []
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'})));
  });
}
