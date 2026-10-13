import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:remotescreen/api.dart';

Directory? _directory;
bool _initialized = false;
Future<void> prepareChatStorage(String token) async {
  if (!_initialized) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    _initialized = true;
  }
  _directory ??= await Directory.systemTemp.createTemp('rs-chat-widget-');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => _directory!.path);
  final s = await api.localChat.store;
  await s.db.transaction((d) async {
    await d.delete('media');
    await d.delete('messages');
    await d.delete('settings');
    await d.delete('bindings');
  });
  await s.bind(token, 'me');
}

// SQLite FFI file I/O uses the real event loop, outside widget fake time.
Future<void> pumpChat(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 5));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    });
  }
  await tester.pumpAndSettle();
}

http.Response? localEmptyResponse(http.Request request) {
  final op = request.url.pathSegments.last;
  if (op == 'local-feed') {
    final body = jsonDecode(request.body);
    return http.Response(
        jsonEncode({
          'messages': [],
          'updates': [],
          'clears': [],
          'reads': [],
          'after': body['after'],
          'edit': body['edit'],
          'hasMore': false
        }),
        200);
  }
  if (op == 'local-activate' || op == 'local-saved') {
    return http.Response('{"ok":true}', 200);
  }
  return null;
}
