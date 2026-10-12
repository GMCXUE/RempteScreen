import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_outbox.dart';

Map<String, dynamic> ack(String id, String client, {String kind = 'image'}) => {
      'id': id,
      'seq': '7',
      'senderId': 'me',
      'clientId': client,
      'kind': kind,
      'createdAt': '123',
      'text': '[图片]',
    };
void main() {
  test('等待大图片上传时立即排入消息，后续文字不依赖输入框，重试保留编号', () async {
    final hold = Completer<Map<String, dynamic>>();
    final calls = <Map<String, dynamic>>[];
    final queue =
        ChatSendQueue('me', 'peer', Future.value((operation, body) async {
      calls.add(body);
      if (calls.length == 1) return hold.future;
      return {
        'message': ack('server${calls.length}', body['clientId'],
            kind: operation == 'send' ? 'text' : 'image')
      };
    }));
    queue.enqueue([
      OutgoingChatMessage(id: 'image_001', kind: 'image', image: 'fixture')
    ]);
    queue.enqueue(
        [OutgoingChatMessage(id: 'text_0001', kind: 'text', text: '下一条消息')]);
    await Future<void>.delayed(Duration.zero);
    expect(queue.items.length, 2);
    expect(queue.items.first.status, 'sending');
    hold.completeError(Exception('网络不可用'));
    await Future<void>.delayed(Duration.zero);
    expect(queue.items.single.status, 'failed');
    expect(queue.confirmed.single['kind'], 'text');
    queue.retry('image_001');
    queue.retry('image_001');
    await Future<void>.delayed(Duration.zero);
    expect(queue.items, isEmpty);
    expect(calls.map((r) => r['clientId']),
        ['image_001', 'text_0001', 'image_001']);
  });
  test('轮询先确认成功而上传响应丢失时不重复显示，退出账号忽略迟到响应', () async {
    final hold = Completer<Map<String, dynamic>>();
    final queue =
        ChatSendQueue('me', 'peer', Future.value((_, __) => hold.future));
    queue.enqueue([
      OutgoingChatMessage(id: 'image_002', kind: 'image', image: 'fixture')
    ]);
    await Future<void>.delayed(Duration.zero);
    queue.reconcile([ack('accepted', 'image_002')]);
    expect(queue.items, isEmpty);
    hold.completeError(Exception('响应丢失'));
    await Future<void>.delayed(Duration.zero);
    expect(queue.items, isEmpty);
    expect(queue.confirmed.single['id'], 'accepted');
    final late = Completer<Map<String, dynamic>>();
    final next =
        ChatSendQueue('me', 'peer', Future.value((_, __) => late.future));
    next.enqueue([OutgoingChatMessage(id: 'image_003', kind: 'image')]);
    await Future<void>.delayed(Duration.zero);
    next.cancel();
    late.complete({'message': ack('old-account', 'image_003')});
    await Future<void>.delayed(Duration.zero);
    expect(next.confirmed, isEmpty);
  });
}
