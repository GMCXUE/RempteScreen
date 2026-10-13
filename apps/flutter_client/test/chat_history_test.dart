import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/chat_outbox.dart';
import 'package:remotescreen/app_theme.dart';
import 'package:remotescreen/chat_history_screen.dart';
import 'package:remotescreen/social_screen.dart';
import 'chat_storage_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final account = Account(id: 'me', email: 'me@test.invalid', name: '我');
  final peer = <String, dynamic>{
    'id': 'peer',
    'name': '好友',
    'remark': '',
    'avatarId': 'cat',
    'pinned': false
  };
  var cleared = false;
  final seen = <String>[], actions = <String>[];
  setUp(() async {
    chatOutbox.reset();
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'synthetic-token'});
    await prepareChatStorage('synthetic-token');
    cleared = false;
    seen.clear();
    actions.clear();
  });
  Future<http.Response> remote(http.Request request) async {
    expect(request.headers['Authorization'], 'Bearer synthetic-token');
    final op = request.url.pathSegments.last;
    seen.add(op);
    final body = request.body.isEmpty ? {} : jsonDecode(request.body);
    Object result = {'ok': true};
    if (op == 'state') {
      result = {
        'me': {'id': 'me', 'name': '我'},
        'friends': [peer]
      };
    }
    if (op == 'local-feed') {
      result = {
        'messages': [],
        'updates': [],
        'clears': cleared
            ? [
                {'peerId': 'peer', 'seq': '300'}
              ]
            : [],
        'reads': [],
        'after': body['after'],
        'edit': body['edit'],
        'hasMore': false
      };
    }
    if (op == 'clear-history') {
      actions.add(op);
      result = {'clearedThrough': '300'};
    }
    if (op == 'profile') actions.add(body['action']);
    return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  Future<void> seed(List<Map<String, dynamic>> rows) async {
    final s = await api.localChat.store;
    for (final row in rows) {
      await s.save('me', 'peer', row);
    }
  }

  Map<String, dynamic> row(String id, String seq, String text,
          {String kind = 'text'}) =>
      {
        'id': id,
        'seq': seq,
        'senderId': 'peer',
        'kind': kind,
        'text': text,
        'createdAt': '1791768000000',
        'editSeq': '0',
        if (kind == 'call') 'call': {'kind': 'voice', 'durationSec': 12}
      };
  test('日期筛选与大整数游标保持精度', () {
    final date = DateTime(2026, 10, 12);
    final q = historyQuery(
        query: ' 中文 ', kind: 'image', date: date, before: '9007199254740993');
    expect(q['query'], '中文');
    expect(q['before'], '9007199254740993');
    expect(q['from'], date.millisecondsSinceEpoch);
    expect(q['to'], DateTime(2026, 10, 13).millisecondsSinceEpoch);
  });
  test('真实 API 从本地查询历史和定位，清空仍同步认证边界', () async {
    await seed([row('local-1', '1', '本地历史')]);
    await http.runWithClient(() async {
      expect((await api.social('history', {'peerId': 'peer'}))['messages'],
          hasLength(1));
      expect(
          (await api.social('message-context',
              {'peerId': 'peer', 'messageId': 'local-1'}))['messages'],
          hasLength(1));
      await api.social('clear-history', {'peerId': 'peer'});
      expect((await api.social('history', {'peerId': 'peer'}))['messages'],
          isEmpty);
    }, () => MockClient(remote));
    expect(seen, contains('local-feed'));
    expect(seen, contains('clear-history'));
    expect(seen, isNot(contains('history')));
    expect(seen, isNot(contains('message-context')));
  });
  testWidgets('聊天信息置顶与清空确认，清空边界持久化', (tester) async {
    String? boundary;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: ChatInformationScreen(
              account: account, friend: peer, onCleared: (s) => boundary = s)));
      await pumpChat(tester);
      expect(find.byType(SwitchListTile), findsNWidgets(2));
      await tester.tap(find.text('置顶聊天'));
      await pumpChat(tester);
      expect(actions, contains('pin'));
      await tester.tap(find.text('清空聊天记录'));
      await pumpChat(tester);
      await tester.tap(find.text('取消'));
      await pumpChat(tester);
      expect(boundary, isNull);
      await tester.tap(find.text('清空聊天记录'));
      await pumpChat(tester);
      await tester.tap(find.text('清空', skipOffstage: false));
      await pumpChat(tester);
      expect(boundary, '300');
      expect(actions, contains('clear-history'));
      await tester.pumpWidget(const SizedBox());
      await pumpChat(tester);
    }, () => MockClient(remote));
  });
  testWidgets('本地历史搜索分类与完整分页，可返回定位标识', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => seed([
          row('old-1', '9007199254740993', '中文历史内容'),
          for (var i = 0; i < 61; i++)
            row('call-$i', '${9007199254740900 + i}', '中文通话 $i', kind: 'call')
        ]));
    String? located;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Builder(
              builder: (c) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        located = await Navigator.push<String>(
                            c,
                            MaterialPageRoute(
                                builder: (_) => ChatHistoryScreen(
                                    account: account, friend: peer)));
                      },
                      child: const Text('打开记录'))))));
      await tester.tap(find.text('打开记录'));
      await pumpChat(tester);
      expect(find.text('中文历史内容'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '中文');
      await tester.pump(const Duration(milliseconds: 350));
      await pumpChat(tester);
      await tester.ensureVisible(find.text('通话'));
      await tester.tap(find.text('通话'));
      await pumpChat(tester);
      expect(find.text('中文历史内容'), findsNothing);
      await tester.scrollUntilVisible(find.text('加载更多'), 500,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text('加载更多'));
      await pumpChat(tester);
      expect(find.text('加载更多'), findsNothing);
      await tester.ensureVisible(find.text('定位到聊天位置').first);
      await tester.tap(find.text('定位到聊天位置').first);
      await pumpChat(tester);
      expect(located, startsWith('call-'));
      expect(seen, isNot(contains('history')));
      await tester.pumpWidget(const SizedBox());
      await pumpChat(tester);
    }, () => MockClient(remote));
  });
  testWidgets('查找定位旧记录，远端清空后不回流且草稿保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() => seed([
          row('old-target', '10', '历史定位目标'),
          for (var i = 20; i < 80; i++) row('filler-$i', '$i', '中间记录 $i'),
          row('latest', '300', '当前最新消息')
        ]));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: PrivateChatScreen(account: account, friend: peer)));
      await pumpChat(tester);
      expect(find.text('当前最新消息'), findsOneWidget);
      await tester.tap(find.byTooltip('聊天信息'));
      await pumpChat(tester);
      await tester.tap(find.text('查找聊天记录'));
      await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '历史定位目标');
      await tester.pump(const Duration(milliseconds: 350));
      await pumpChat(tester);
      await tester.tap(find.text('定位到聊天位置'));
      await pumpChat(tester);
      expect(find.text('聊天信息'), findsNothing);
      expect(find.text('历史定位目标'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '保留草稿');
      cleared = true;
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(find.text('历史定位目标'), findsNothing);
      expect(find.text('当前最新消息'), findsNothing);
      expect(find.text('保留草稿'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await pumpChat(tester);
    }, () => MockClient(remote));
  });
}
