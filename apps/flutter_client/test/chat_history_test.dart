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

void main() {
  final account = Account(id: 'me', email: 'me@test.invalid', name: '我');
  final peer = <String, dynamic>{
    'id': 'peer',
    'name': '好友',
    'remark': '',
    'avatarId': 'cat',
    'pinned': false
  };
  setUp(() {
    chatOutbox.reset();
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'synthetic-token'});
  });
  test('日期筛选包含当天开始且不包含下一天，分页游标保持精度', () {
    final date = DateTime(2026, 10, 12);
    final query = historyQuery(
        query: '  中文  ', kind: 'image', date: date, before: '9007199254740993');
    expect(query['query'], '中文');
    expect(query['before'], '9007199254740993');
    expect(query['from'], date.millisecondsSinceEpoch);
    expect(query['to'], DateTime(2026, 10, 13).millisecondsSinceEpoch);
  });
  test('移动端真实 API 允许历史、定位和清空请求并带认证', () async {
    final seen = <String>[];
    await http.runWithClient(() async {
      final service = ApiService(baseUrl: 'https://history.test.invalid');
      for (final operation in ['history', 'message-context', 'clear-history']) {
        await service.social(operation, {'peerId': 'peer'});
      }
    },
        () => MockClient((request) async {
              expect(
                  request.headers['Authorization'], 'Bearer synthetic-token');
              seen.add(request.url.path);
              return http.Response('{}', 200);
            }));
    expect(seen.length, 3);
  });
  testWidgets('聊天信息仅四项功能，置顶保存且清空必须确认', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final operations = <String>[];
    String? cleared;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: ChatInformationScreen(
              account: account, friend: peer, onCleared: (v) => cleared = v)));
      await tester.pumpAndSettle();
      expect(find.text('查找聊天记录'), findsOneWidget);
      expect(find.text('消息免打扰'), findsOneWidget);
      expect(find.text('置顶聊天'), findsOneWidget);
      expect(find.text('清空聊天记录'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsNWidgets(2));
      expect(find.text('添加'), findsNothing);
      await tester.tap(find.text('置顶聊天'));
      await tester.pumpAndSettle();
      expect(operations, contains('pin'));
      await tester.tap(find.text('清空聊天记录'));
      await tester.pumpAndSettle();
      expect(operations, isNot(contains('clear-history')));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(cleared, isNull);
      await tester.tap(find.text('清空聊天记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空', skipOffstage: false));
      await tester.pumpAndSettle();
      expect(cleared, '123');
      expect(operations, contains('clear-history'));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              final body =
                  request.method == 'POST' ? jsonDecode(request.body) : {};
              Object result = {};
              if (request.url.path.endsWith('/state'))
                result = {
                  'me': {'id': 'me', 'name': '我'},
                  'friends': [peer]
                };
              if (request.url.path.endsWith('/profile')) {
                operations.add(body['action']);
                result = {'ok': true};
              }
              if (request.url.path.endsWith('/clear-history')) {
                operations.add('clear-history');
                result = {'clearedThrough': '123'};
              }
              return http.Response(jsonEncode(result), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
  testWidgets('历史搜索覆盖分类和分页，定位将消息标识返回聊天页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final requests = <Map<String, dynamic>>[];
    String? located;
    final message = {
      'id': 'old-1',
      'seq': '9007199254740993',
      'senderId': 'peer',
      'kind': 'text',
      'text': '中文历史内容',
      'createdAt': '1791768000000'
    };
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        located = await Navigator.push<String>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => ChatHistoryScreen(
                                    account: account, friend: peer)));
                      },
                      child: const Text('打开记录'))))));
      await tester.tap(find.text('打开记录'));
      await tester.pumpAndSettle();
      expect(find.text('中文历史内容'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '中文');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(requests.last['query'], '中文');
      await tester.ensureVisible(find.text('通话'));
      await tester.tap(find.text('通话'));
      await tester.pumpAndSettle();
      expect(requests.last['kind'], 'call');
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(requests.last['before'], '9007199254740993');
      await tester.tap(find.text('定位到聊天位置').first);
      await tester.pumpAndSettle();
      expect(located, 'old-1');
      await tester.pumpWidget(const SizedBox());
    },
        () => MockClient((request) async {
              Object result = {};
              if (request.url.path.endsWith('/state'))
                result = {
                  'me': {'id': 'me', 'name': '我', 'avatarId': 'cat'}
                };
              if (request.url.path.endsWith('/history')) {
                final body =
                    Map<String, dynamic>.from(jsonDecode(request.body));
                requests.add(body);
                result = {
                  'messages': [
                    body['before'] == null
                        ? message
                        : {
                            ...message,
                            'id': 'old-0',
                            'seq': '9007199254740992',
                            'text': '较早消息'
                          }
                  ],
                  'hasMore': body['before'] == null
                };
              }
              return http.Response(jsonEncode(result), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
  testWidgets('从实际聊天入口查找定位旧消息，另一设备清空后旧消息不再回流且草稿保留', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    bool cleared = false;
    final latest = {
      'id': 'latest',
      'seq': '300',
      'senderId': 'peer',
      'kind': 'text',
      'text': '当前最新消息',
      'createdAt': '1791768000000'
    };
    final old = {
      'id': 'old-target',
      'seq': '10',
      'senderId': 'peer',
      'kind': 'text',
      'text': '历史定位目标',
      'createdAt': '1791700000000'
    };
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: PrivateChatScreen(account: account, friend: peer)));
      await tester.pumpAndSettle();
      expect(find.text('当前最新消息'), findsOneWidget);
      await tester.tap(find.byTooltip('聊天信息'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查找聊天记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('定位到聊天位置'));
      await tester.pumpAndSettle();
      expect(find.text('聊天信息'), findsNothing);
      expect(find.text('历史定位目标'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '保留草稿');
      cleared = true;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('历史定位目标'), findsNothing);
      expect(find.text('当前最新消息'), findsNothing);
      expect(find.text('保留草稿'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              Object result = {};
              final operation = request.url.path.split('/').last;
              if (operation == 'state')
                result = {
                  'me': {'id': 'me', 'name': '我', 'avatarId': 'cat'},
                  'friends': [peer]
                };
              if (operation == 'messages')
                result = {
                  'messages': cleared ? [] : [latest],
                  'updates': [],
                  'hasMore': false,
                  'syncCursor': '0',
                  'clearedThrough': cleared ? '300' : '0'
                };
              if (operation == 'history')
                result = {
                  'messages': [old],
                  'hasMore': false
                };
              if (operation == 'message-context')
                result = {
                  'messages': [old],
                  'hasMore': true,
                  'syncCursor': '0',
                  'clearedThrough': '0'
                };
              return http.Response(jsonEncode(result), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
  });
}
