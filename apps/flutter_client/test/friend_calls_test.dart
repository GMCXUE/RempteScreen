import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/friend_calls.dart';
import 'package:remotescreen/friend_audio_options.dart';
import 'package:livekit_client/livekit_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(
      {'friend_call_client': 'client-test-1111111111'}));
  final account = Account(
      id: 'user-test',
      email: 'test@example.test',
      name: '测试',
      accountId: '123456');
  test('服务器 ICE 和重连配置更新后仍选择独立好友音频工厂', () {
    const initial = FriendRTCConfiguration();
    final updated = initial.copyWith(iceServers: const [
      RTCIceServer(
          urls: ['turn:local.test'], username: 'test', credential: 'test')
    ]).copyWith(iceTransportPolicy: RTCIceTransportPolicy.relay);
    expect(updated.toMap()['friendCallAudio'], true);
    expect(updated.toMap()['iceServers'][0]['urls'], ['turn:local.test']);
    expect(
        const RTCConfiguration().toMap().containsKey('friendCallAudio'), false);
    expect(
        const FriendAudioCaptureOptions()
            .toMediaConstraintsMap()['friendCallAudio'],
        true);
  });
  test('挂断信令失败后不重新打开通话，重试期间不续租', () async {
    Map<String, dynamic>? serverCall;
    var failures = 2, ends = 0;
    List<dynamic> lastSkip = [];
    final calls = FriendCalls(request: (op, body) async {
      if (op == 'call-start') {
        serverCall = {
          'id': 'ring-call',
          'peerName': '好友',
          'role': 'caller',
          'kind': 'voice',
          'status': 'ringing',
          'owned': true
        };
        return {'call': serverCall};
      }
      if (op == 'call-end') {
        ends++;
        if (failures-- > 0) throw StateError('network');
        serverCall = {...serverCall!, 'status': 'ended', 'reason': 'hangup'};
        return {'call': serverCall};
      }
      lastSkip = body['skipCallIds'] ?? [];
      return {
        'calls': serverCall == null ? [] : [serverCall]
      };
    });
    await calls.initialize(account);
    await calls.start({'id': 'peer'}, 'voice');
    expect(calls.current?['status'], 'ringing');
    await calls.hangup();
    expect(calls.current, isNull);
    await calls.poll();
    expect(calls.current, isNull);
    expect(lastSkip, ['ring-call']);
    await calls.poll();
    expect(ends, 3);
    expect(calls.current, isNull);
    await calls.logout();
    calls.dispose();
  });
  test('其他设备接听后本设备来电自动消失，不启动媒体', () async {
    final cleared = <String>[];
    var call = <String, dynamic>{
      'id': 'incoming',
      'peerName': '好友',
      'role': 'callee',
      'kind': 'video',
      'status': 'ringing',
      'owned': false
    };
    final calls = FriendCalls(
        clearNotification: (id) async => cleared.add(id),
        request: (op, body) async => {
              'calls': [call]
            });
    await calls.initialize(account);
    expect(calls.current?['status'], 'ringing');
    expect(cleared, isEmpty);
    call = {...call, 'status': 'active', 'owned': false};
    await calls.poll();
    expect(calls.current, isNull);
    expect(calls.media, isNull);
    expect(cleared, ['incoming']);
    expect(calls.notice, '通话已在其他设备接听');
    await calls.logout();
    calls.dispose();
  });
  test('对方取消未接来电后清理原生通知', () async {
    final cleared = <String>[];
    var call = <String, dynamic>{
      'id': 'cancelled-incoming',
      'peerName': '好友',
      'role': 'callee',
      'kind': 'voice',
      'status': 'ringing',
      'owned': false
    };
    final calls = FriendCalls(
        clearNotification: (id) async => cleared.add(id),
        request: (op, body) async => {
              'calls': [call]
            });
    await calls.initialize(account);
    expect(cleared, isEmpty);
    call = {...call, 'status': 'ended', 'reason': 'cancelled'};
    await calls.poll();
    expect(calls.current, isNull);
    expect(cleared, ['cancelled-incoming']);
    expect(calls.notice, '对方取消了通话');
    await calls.poll();
    expect(cleared, ['cancelled-incoming']);
    await calls.logout();
    calls.dispose();
  });
  testWidgets('正常挂断无额外结束提示，断线提示短暂显示后自动消失', (tester) async {
    final cleared = <String>[];
    var call = <String, dynamic>{
      'id': 'ended-call',
      'peerName': '好友',
      'role': 'callee',
      'kind': 'voice',
      'status': 'ringing',
      'owned': false,
    };
    final calls = FriendCalls(
        clearNotification: (id) async => cleared.add(id),
        request: (op, body) async => {
              'calls': [call]
            });
    await tester.runAsync(() => calls.initialize(account));
    calls.current = {...call, 'status': 'active', 'owned': true};
    calls.notice = '之前的提示';
    call = {...call, 'status': 'ended', 'reason': 'hangup'};
    await calls.poll();
    expect(calls.current, isNull);
    expect(calls.notice, isNull);
    expect(cleared, ['ended-call']);

    calls.current = {...call, 'status': 'active', 'owned': true};
    call = {...call, 'reason': 'offline'};
    await calls.poll();
    expect(calls.current, isNull);
    expect(calls.notice, '对方已离线，通话已结束');
    await tester.pump(const Duration(milliseconds: 2201));
    expect(calls.notice, isNull);
    await calls.logout();
    calls.dispose();
  });
  test('退出登录后丢弃迟到的呼叫响应', () async {
    final started = Completer<void>(),
        response = Completer<Map<String, dynamic>>();
    final calls = FriendCalls(request: (op, body) async {
      if (op == 'call-start') {
        started.complete();
        return response.future;
      }
      return {'calls': []};
    });
    await calls.initialize(account);
    final pending = calls.start({'id': 'peer'}, 'voice');
    await started.future;
    await calls.logout();
    response.complete({
      'call': {
        'id': 'stale',
        'status': 'ringing',
        'role': 'caller',
        'owned': true
      }
    });
    await pending;
    expect(calls.current, isNull);
    expect(calls.account, isNull);
    calls.dispose();
  });
}
