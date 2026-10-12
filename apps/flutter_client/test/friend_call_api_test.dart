import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/friend_calls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'remotescreen.accountToken': 'test-token',
        'friend_call_client': 'client-api-test-111111',
      }));
  test('真实 API 入口允许全部通话操作并发送认证和请求体', () async {
    final api = ApiService(baseUrl: 'https://api.example.test');
    final seen = <String>[];
    const operations = [
      'call-start',
      'call-state',
      'call-decision',
      'call-end'
    ];
    await http.runWithClient(() async {
      for (final op in operations) {
        await api.social(op, {'clientId': 'client-api-test-111111'});
      }
    },
        () => MockClient((request) async {
              expect(request.method, 'POST');
              expect(request.headers['Authorization'], 'Bearer test-token');
              expect(jsonDecode(request.body)['clientId'],
                  'client-api-test-111111');
              seen.add(request.url.path);
              return http.Response('{}', 200);
            }));
    expect(seen, operations.map((op) => '/v1/social/$op').toList());
  });
  test('真实 API 来电同步显示待接听且不启动媒体', () async {
    final api = ApiService(baseUrl: 'https://api.example.test');
    final calls = FriendCalls(request: (op, body) => api.social(op, body));
    await http.runWithClient(() async {
      await calls.initialize(
          Account(id: 'callee', email: 'callee@example.test', name: '被叫'));
      expect(calls.current?['id'], 'incoming-api-call');
      expect(calls.current?['status'], 'ringing');
      expect(calls.media, isNull);
      await calls.logout();
    },
        () => MockClient((request) async {
              expect(request.url.path, '/v1/social/call-state');
              return http.Response(
                  jsonEncode({
                    'calls': [
                      {
                        'id': 'incoming-api-call',
                        'role': 'callee',
                        'owned': false,
                        'status': 'ringing',
                        'kind': 'voice',
                        'peerName': '好友'
                      }
                    ]
                  }),
                  200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }));
    calls.dispose();
  });
}
