import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/chat_store.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

// Exercise the actual sqflite method channel over real SQLite. FFI alone
// accepts result-producing SQL in execute(), unlike Android's execSQL().
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.tekartik.sqflite');
  late Directory directory;
  DatabaseFactory? previousFactory;
  final walMethods = <String>[];

  setUp(() async {
    ffi.sqfliteFfiInit();
    previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    directory = await Directory.systemTemp.createTemp('rs-chat-platform-');
    walMethods.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      final arguments = call.arguments;
      final sql = arguments is Map ? arguments['sql'] : null;
      if (sql is String &&
          RegExp(r'^PRAGMA\s+journal_mode\s*=', caseSensitive: false)
              .hasMatch(sql)) {
        walMethods.add(call.method);
        if (call.method != 'query') {
          throw PlatformException(
            code: 'sqlite_error',
            message: 'Queries can be performed using SQLiteDatabase query or '
                'rawQuery methods only.',
            details: {'sql': sql, 'arguments': []},
          );
        }
      }
      // Forward wire operations, including transactions and schema upgrades,
      // to SQLite rather than fabricating query results.
      return (ffi.databaseFactoryFfiNoIsolate as dynamic)
          .invokeMethod<dynamic>(call.method, call.arguments);
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    databaseFactoryOrNull = previousFactory;
    await directory.delete(recursive: true);
  });

  Future<void> checkConfiguration(ChatStore store) async {
    expect(
        (await store.db.rawQuery('PRAGMA journal_mode')).single.values.single,
        'wal');
    expect((await store.db.rawQuery('PRAGMA synchronous')).single.values.single,
        2);
    expect(
        (await store.db.rawQuery('PRAGMA foreign_keys')).single.values.single,
        1);
    expect(await store.db.getVersion(), 2);
  }

  test('Android channel opens and reopens durable account data', () async {
    final path = '${directory.path}/chat.db';
    final store = await ChatStore.open(path);
    try {
      await checkConfiguration(store);
      await store.bind('test-token', 'alice');
      await ChatStore.set(store.db, 'alice', 'account', '{"id":"alice"}');
    } finally {
      await store.db.close();
    }
    final reopened = await ChatStore.open(path);
    try {
      await checkConfiguration(reopened);
      expect(await reopened.owner('test-token'), 'alice');
      expect(await reopened.get('alice', 'account'), '{"id":"alice"}');
      expect(walMethods, ['query', 'query']);
    } finally {
      await reopened.db.close();
    }
  });

  test('Android channel recovers the empty file left by failed initialization',
      () async {
    final path = '${directory.path}/chat.db';
    final failed = await openDatabase(path);
    try {
      await expectLater(failed.execute('PRAGMA journal_mode=WAL'),
          throwsA(isA<DatabaseException>()));
      expect(await failed.getVersion(), 0);
    } finally {
      await failed.close();
    }
    final store = await ChatStore.open(path);
    try {
      await checkConfiguration(store);
      await store.bind('test-token', 'alice');
      expect(await store.owner('test-token'), 'alice');
    } finally {
      await store.db.close();
    }
  });

  test('Android channel upgrades v1 without dropping stored messages',
      () async {
    final path = '${directory.path}/chat.db';
    final old = await openDatabase(path, version: 1, onCreate: (db, _) async {
      for (final sql in ChatStore.schema) {
        await db.execute(sql.replaceFirst(',sender TEXT NOT NULL', ''));
      }
      await db.rawInsert(
          'INSERT INTO messages(owner,id,peer,seq,kind,text,created,edit,row) '
          'VALUES(?,?,?,?,?,?,?,?,?)',
          [
            'alice',
            'message',
            'bob',
            1,
            'text',
            '已保存',
            1,
            0,
            '{"id":"message","senderId":"alice","text":"已保存"}'
          ]);
    });
    await old.close();
    final store = await ChatStore.open(path);
    try {
      await checkConfiguration(store);
      expect((await store.message('alice', 'message'))!['text'], '已保存');
      expect(
          (await store.db.rawQuery('SELECT sender FROM messages'))
              .single['sender'],
          'alice');
    } finally {
      await store.db.close();
    }
  });
}
