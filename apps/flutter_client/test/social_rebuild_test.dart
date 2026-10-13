import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/chat_message.dart';
import 'package:remotescreen/chat_outbox.dart';
import 'package:remotescreen/social_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_messages_test.dart' show ChatFixture;
import 'chat_storage_fixture.dart';

void main() {
  setUp(() async {
    chatOutbox.reset();
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    await prepareChatStorage('test-token');
  });

  testWidgets('typing and cursor movement rebuild only the composer',
      (tester) async {
    final fixture = ChatFixture();
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: PrivateChatScreen(
              account: Account(id: 'me', email: 'me@test.invalid', name: '我'),
              friend: const {
            'id': 'peer',
            'name': '好友',
            'remark': '',
            'avatarId': 'cat'
          })));
      await pumpChat(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      final history = tester.widget<ListView>(find.byType(ListView).first);
      final bubble = tester
          .widget<ChatMessageBubble>(find.byType(ChatMessageBubble).first);
      final field = tester.widget<TextField>(find.byType(TextField));
      final offset = history.controller!.offset;
      for (final text in ['输', '输入', '输入时', '输入时保持', '输入时保持列表']) {
        await tester.enterText(find.byType(TextField), text);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<ListView>(find.byType(ListView).first),
            same(history));
        expect(
            tester.widget<ChatMessageBubble>(
                find.byType(ChatMessageBubble).first),
            same(bubble));
        expect(history.controller!.offset, offset);
        expect(tester.widget<TextField>(find.byType(TextField)), same(field));
        expect(field.focusNode!.hasFocus, isTrue);
      }
      expect(find.text('发送'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-more-button')), findsNothing);
      field.controller!.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      expect(
          tester.widget<ListView>(find.byType(ListView).first), same(history));
      field.controller!.clear();
      await tester.pump();
      expect(find.text('发送'), findsNothing);
      expect(find.byKey(const ValueKey('chat-more-button')), findsOneWidget);
      expect(
          tester.widget<ListView>(find.byType(ListView).first), same(history));
      await tester.enterText(find.byType(TextField), '发送测试');
      await tester.pump();
      await tester.tap(find.text('发送'));
      await pumpChat(tester);
      expect(find.text('发送测试'), findsOneWidget);
      expect(field.controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpChat(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets(
      'identical contact polling preserves widgets while visible changes update',
      (tester) async {
    var requests = 0;
    final friend = <String, dynamic>{
      'id': 'peer',
      'name': '好友甲',
      'remark': '',
      'unread': 1,
      'blocked': false,
      'online': true,
      'lastText': '新消息',
      'accountId': '234567',
      'avatarId': 'cat',
      'avatarRevision': '',
      'bio': '',
    };
    final applications = <Map<String, dynamic>>[];
    var reportedUnread = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SocialScreen(
                  account:
                      Account(id: 'me', email: 'me@test.invalid', name: '我'),
                  onUnreadChanged: (count) => reportedUnread = count))));
      await pumpChat(tester);
      final before = tester.widget<ListView>(find.byType(ListView).first);
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 2));
        await pumpChat(tester);
        expect(
            tester.widget<ListView>(find.byType(ListView).first), same(before));
      }
      expect(requests, greaterThanOrEqualTo(4));
      friend['lastText'] = '新的聊天预览';
      friend['online'] = false;
      friend['unread'] = 2;
      await tester.pump(const Duration(seconds: 2));
      await pumpChat(tester);
      expect(find.text('新的聊天预览'), findsOneWidget);
      expect(reportedUnread, 2);
      expect(tester.widget<ListView>(find.byType(ListView).first),
          isNot(same(before)));
      final after = tester.widget<ListView>(find.byType(ListView).first);
      applications.add({'id': 'r1', 'name': '申请甲', 'note': ''});
      await tester.pump(const Duration(seconds: 2));
      await pumpChat(tester);
      expect(find.text('新的好友申请'), findsOneWidget);
      expect(reportedUnread, 3);
      expect(tester.widget<ListView>(find.byType(ListView).first),
          isNot(same(after)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpChat(tester);
    },
        () => MockClient((request) async {
              final local = localEmptyResponse(request);
              if (local != null) return local;
              requests++;
              return http.Response(
                  jsonEncode({
                    'serverNow': '$requests',
                    'me': {'id': 'me', 'accountId': '123456'},
                    'friends': [friend],
                    'requests': applications,
                    'outgoing': [],
                    'blocked': [],
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
}
