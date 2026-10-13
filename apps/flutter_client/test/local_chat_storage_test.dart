import 'dart:io';
import 'dart:convert';
import 'package:remotescreen/local_chat.dart';
import 'package:crypto/crypto.dart';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:remotescreen/chat_store.dart';
import 'package:remotescreen/chat_backup.dart';

Map<String, dynamic> row(String id, int seq, String kind) => {
      'id': id,
      'seq': '$seq',
      'senderId': 'alice',
      'clientId': 'client_$id',
      'kind': kind,
      'text': '中文 100%_test \\',
      'createdAt': '1720000000000',
      'editSeq': '0'
    };
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  test(
      'durable offline data, isolation, merging, authenticated restore rollback',
      () async {
    final dir = await Directory.systemTemp.createTemp('rs-chat-dart-test-');
    final a = await ChatStore.open('${dir.path}/a.db'),
        b = await ChatStore.open('${dir.path}/b.db');
    try {
      await a.db.transaction((d) async {
        await ChatStore.merge(d, 'alice', 'bob', row('text', 1, 'text'));
        await ChatStore.merge(d, 'alice', 'bob', row('video', 2, 'video'));
        await ChatStore.saveBytes(
            d,
            'alice',
            'video',
            Uint8List.fromList(List.filled(ChatBackup.chunkSize + 33, 42)),
            'video/mp4',
            null);
      });
      await a.bind('synthetic-token', 'alice');
      expect(await a.owner('synthetic-token'), 'alice');
      final file = File('${dir.path}/backup.rschat');
      await ChatBackup.export(a, 'alice', file, 'synthetic-password');
      expect(
          await ChatBackup.restore(b, 'alice', file, 'synthetic-password'), 2);
      expect(
          await ChatBackup.restore(b, 'alice', file, 'synthetic-password'), 2);
      expect((await b.query('alice', 'history', {'peerId': 'bob'}))['messages'],
          hasLength(2));
      expect((await b.query('bob', 'history', {'peerId': 'alice'}))['messages'],
          isEmpty);
      expect(
          (await b.query('alice', 'history',
              {'peerId': 'bob', 'query': '%_test'}))['messages'],
          hasLength(2));
      expect(await b.bytes('alice', 'video'),
          Uint8List.fromList(List.filled(ChatBackup.chunkSize + 33, 42)));
      await expectLater(ChatBackup.restore(b, 'alice', file, 'wrong-password'),
          throwsFormatException);
      await expectLater(
          ChatBackup.restore(b, 'bob', file, 'synthetic-password'),
          throwsFormatException);
      await b.save(
          'alice', 'bob', {...row('video', 2, 'recalled'), 'editSeq': '9'});
      await ChatBackup.restore(b, 'alice', file, 'synthetic-password');
      expect((await b.message('alice', 'video'))!['kind'], 'recalled');
      expect((await b.message('alice', 'video'))!['editSeq'], '9');
      expect(await b.bytes('alice', 'video'), isNull);
      await b.db.transaction((d) => ChatStore.clear(d, 'alice', 'bob', '2'));
      await ChatBackup.restore(b, 'alice', file, 'synthetic-password');
      expect(await b.message('alice', 'text'), isNull);
      final lines = await file.readAsLines();
      lines.removeLast();
      final bad = File('${dir.path}/bad.rschat');
      await bad.writeAsString('${lines.join('\n')}\n');
      final empty = await ChatStore.open('${dir.path}/empty.db');
      try {
        await expectLater(
            ChatBackup.restore(empty, 'alice', bad, 'synthetic-password'),
            throwsFormatException);
        expect(await empty.message('alice', 'text'), isNull);
      } finally {
        await empty.db.close();
      }
      await a.db.close();
      final reopened = await ChatStore.open('${dir.path}/a.db');
      try {
        expect((await reopened.message('alice', 'text'))!['text'],
            '中文 100%_test \\');
      } finally {
        await reopened.db.close();
      }
    } finally {
      if (a.db.isOpen) await a.db.close();
      await b.db.close();
      await dir.delete(recursive: true);
    }
  });
  test(
      'receipts require committed messages and complete media; failed media retries; offline browsing',
      () async {
    final dir = await Directory.systemTemp.createTemp('rs-chat-delivery-');
    final s = await ChatStore.open('${dir.path}/chat.db');
    await s.bind('token', 'alice');
    await ChatStore.set(
        s.db,
        'alice',
        'state',
        jsonEncode({
          'me': {'id': 'alice'},
          'friends': [
            {'id': 'bob', 'unread': 0}
          ]
        }));
    final bytes = Uint8List.fromList([1, 2, 3]);
    var broken = true, offline = false;
    var mediaRequests = 0;
    final receipts = <String>{};
    final client = LocalChat(
        database: s,
        currentToken: () async => 'token',
        video: (_, __, ___, ____) => throw UnimplementedError(),
        remote: (op, body, token) async {
          if (offline) throw Exception('连不上服务器，请检查网络或服务器地址');
          if (op == 'local-activate') return {'ok': true};
          if (op == 'local-feed') {
            return {
              'messages': body['after'] == '0'
                  ? [
                      {...row('text', 1, 'text'), 'peerId': 'bob'},
                      {
                        ...row('image', 2, 'image'),
                        'peerId': 'bob',
                        'image': {
                          'bytes': 3,
                          'sha256': sha256.convert(bytes).toString()
                        }
                      }
                    ]
                  : [],
              'updates': [],
              'clears': [],
              'reads': [],
              'after': '2',
              'edit': '0',
              'hasMore': false
            };
          }
          if (op == 'local-image') {
            mediaRequests++;
            return {
              'image': 'data:image/jpeg;base64,${base64Encode(broken ? [
                  8,
                  9,
                  0,
                  1
                ] : bytes)}'
            };
          }
          if (op == 'local-saved') {
            receipts.addAll((body['ids'] as List).cast<String>());
            return {'ok': true};
          }
          throw UnimplementedError(op);
        });
    try {
      await s.db.execute('PRAGMA query_only=ON');
      await expectLater(client.syncAll('token'), throwsA(anything));
      expect(await s.get('alice', 'after'), isNull);
      expect(receipts, isEmpty);
      await s.db.execute('PRAGMA query_only=OFF');
      client.screenBusy = true;
      await client.syncAll('token');
      expect(mediaRequests, 0);
      expect(receipts, {'text'});
      client.screenBusy = false;
      await client.syncAll('token');
      expect(await s.get('alice', 'after'), '2');
      expect(receipts, {'text'});
      expect(await s.bytes('alice', 'image'), isNull);
      broken = false;
      await s.db.delete('settings',
          where: 'owner=? AND key=?', whereArgs: ['alice', 'mediaTry:image']);
      await client.syncAll('token');
      expect(receipts, {'text', 'image'});
      expect(await s.bytes('alice', 'image'), bytes);
      offline = true;
      expect(
          (await client.call(
              'history', {'peerId': 'bob'}, 'token'))['messages'],
          hasLength(2));
      expect(
          (await client.call('message-image',
              {'peerId': 'bob', 'messageId': 'image'}, 'token'))['image'],
          'data:image/jpeg;base64,${base64Encode(bytes)}');
      expect(
          (await client.call('state', {}, 'token'))['friends'][0]['lastText'],
          '中文 100%_test \\');
    } finally {
      await s.db.close();
      await dir.delete(recursive: true);
    }
  });
  test('Rust to Dart and Dart to Rust encrypted migration format', () async {
    final cross = Platform.environment['RS_CHAT_CROSS_DIR'];
    if (cross == null) return;
    final s = await ChatStore.open('$cross/dart.db');
    try {
      expect(
          await ChatBackup.restore(
              s, 'cross-account', File('$cross/rust.rschat'), 'cross-password'),
          2);
      expect(
          (await s.message('cross-account', 'cross-text'))!['text'], '两端互通 %_');
      expect(await s.bytes('cross-account', 'cross-media'),
          Uint8List.fromList(List.filled(ChatBackup.chunkSize + 13, 7)));
      await ChatBackup.export(
          s, 'cross-account', File('$cross/dart.rschat'), 'cross-password');
    } finally {
      await s.db.close();
    }
  });
}
