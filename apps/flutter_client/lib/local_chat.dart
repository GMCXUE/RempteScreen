import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'chat_store.dart';

typedef ChatRemote = Future<Map<String, dynamic>> Function(
    String operation, Map<String, dynamic> body, String token);

class LocalChat {
  LocalChat(
      {required this.remote,
      required this.currentToken,
      required this.video,
      ChatStore? database}) {
    if (database != null) _store = Future.value(database);
  }
  final ChatRemote remote;
  final Future<String?> Function() currentToken;
  final Future<File> Function(String, String, String, bool) video;
  Future<ChatStore>? _store;
  final Map<String, Future<void>> _syncing = {};
  final Map<String, Future<void>> _mediaSyncing = {};
  String? lastError;
  bool screenBusy = false, callBusy = false;
  bool get mediaBlocked => screenBusy || callBusy;
  Future<ChatStore> get store => _store ??= () async {
        final root = await getApplicationSupportDirectory();
        await root.create(recursive: true);
        return ChatStore.open('${root.path}/chat-v1.sqlite');
      }();
  Future<String> owner(String token) async {
    final s = await store;
    final cached = await s.owner(token);
    if (cached != null) return cached;
    final state = await remote('state', {}, token);
    final id = state['me']['id'] as String;
    await s.bind(token, id);
    await ChatStore.set(s.db, id, 'state', jsonEncode(state));
    return id;
  }

  Future<void> record(
      String token, String peer, Map<String, dynamic> response) async {
    final id = await owner(token), s = await store;
    final row = response['message'];
    if (row is Map) await s.save(id, peer, Map<String, dynamic>.from(row));
    unawaited(sync(token).catchError((Object e) {
      lastError = e.toString();
    }));
  }

  Future<void> sync(String token) =>
      _syncing[token] ??= _sync(token).whenComplete(() {
        _syncing.remove(token);
      });
  Future<void> _sync(String token) async {
    final s = await store, id = await owner(token);
    // No opt-in until the account's database is successfully opened.
    await remote('local-activate', {}, token);
    var more = true;
    while (more && await currentToken() == token) {
      final feed = await remote(
          'local-feed',
          {
            'after': await s.get(id, 'after') ?? '0',
            'edit': await s.get(id, 'edit') ?? '0'
          },
          token);
      await s.apply(id, feed);
      more = feed['hasMore'] == true;
    }
    unawaited((_mediaSyncing[token] ??= _cacheMedia(token).whenComplete(() {
      _mediaSyncing.remove(token);
    }))
        .catchError((Object e) {
      lastError = e.toString();
    }));
  }

  Future<void> syncAll(String token) async {
    await sync(token);
    await _mediaSyncing[token];
  }

  Future<void> _cacheMedia(String token) async {
    final s = await store, id = await owner(token);
    String? mediaError;
    final attempted = <String>{};
    while (await currentToken() == token && !mediaBlocked) {
      final batch = (await s.missing(id))
          .where(
              (p) => !attempted.contains(jsonDecode(p['row'] as String)['id']))
          .toList();
      if (batch.isEmpty) break;
      for (final pending in batch) {
        if (await currentToken() != token) return;
        final row = jsonDecode(pending['row'] as String),
            peer = pending['peer'] as String;
        attempted.add(row['id']);
        await ChatStore.set(s.db, id, 'mediaTry:${row['id']}',
            DateTime.now().millisecondsSinceEpoch.toString());
        try {
          if (row['kind'] == 'image') {
            final image =
                await remote('local-image', {'messageId': row['id']}, token);
            final bytes =
                base64Decode((image['image'] as String).split(',').last);
            await s.db.transaction((d) => ChatStore.saveBytes(d, id, row['id'],
                bytes, 'image/jpeg', row['image']?['sha256']));
          } else {
            final file = await video(peer, row['id'], token, true);
            try {
              await s.db.transaction((d) async => ChatStore.saveBytes(
                  d,
                  id,
                  row['id'],
                  await file.readAsBytes(),
                  'video/mp4',
                  row['video']?['sha256']));
            } finally {
              if (await file.parent.exists()) {
                await file.parent.delete(recursive: true);
              }
            }
          }
        } catch (e) {
          mediaError = e.toString();
        } // Only the missing media stays queued; no delivery receipt.
      }
    }
    while (await currentToken() == token) {
      final ids = await s.pending(id);
      if (ids.isEmpty) break;
      if (ids.isNotEmpty) {
        await remote('local-saved', {'ids': ids}, token);
        await s.db.transaction((d) async {
          for (final message in ids) {
            await d.rawUpdate(
                'UPDATE messages SET acked=1 WHERE owner=? AND id=?',
                [id, message]);
          }
        });
      }
    }
    lastError = mediaError;
  }

  Future<Map<String, dynamic>> call(
      String operation, Map<String, dynamic> body, String token) async {
    if (![
      'state',
      'messages',
      'history',
      'message-context',
      'send',
      'send-image',
      'recall',
      'clear-history',
      'read',
      'message-image',
      'message-video'
    ].contains(operation)) {
      final result = await remote(operation, body, token);
      if (operation.startsWith('call-')) {
        final calls = [
          ...(result['calls'] ?? []) as List,
          if (result['call'] is Map) result['call']
        ];
        callBusy = calls.any((c) =>
            c['owned'] == true && ['ringing', 'active'].contains(c['status']));
      }
      return result;
    }
    final id = await owner(token), s = await store;
    if (['messages', 'history', 'message-context'].contains(operation)) {
      String? syncError;
      try {
        await sync(token);
      } catch (e) {
        lastError = e.toString();
        syncError = lastError;
      }
      if (await currentToken() != token) {
        throw const FormatException('账号已变化，请重新打开聊天');
      }
      final result = await s.query(id, operation, body);
      result['syncError'] = syncError;
      return result;
    }
    if (operation == 'message-image') {
      final row = await s.message(id, body['messageId']);
      if (row?['kind'] == 'recalled') throw const FormatException('图片已撤回');
      final bytes = await s.bytes(id, body['messageId']);
      if (bytes != null) {
        return {'image': 'data:image/jpeg;base64,${base64Encode(bytes)}'};
      }
    }
    if (operation == 'message-video') {
      final row = await s.message(id, body['messageId']);
      if (row?['kind'] == 'recalled') throw const FormatException('视频已撤回');
      if (row != null && await s.bytes(id, body['messageId']) != null) {
        return {'message': row};
      }
    }
    Map<String, dynamic> result;
    try {
      result = await remote(operation, body, token);
    } catch (e) {
      if (operation == 'state' && e.toString().contains('连不上服务器')) {
        final cached = await s.get(id, 'state');
        if (cached != null) {
          lastError = e.toString();
          final state = Map<String, dynamic>.from(jsonDecode(cached));
          state['offline'] = true;
          return s.decorate(id, state);
        }
      }
      rethrow;
    }
    if (operation == 'state') {
      await s.bind(token, result['me']['id']);
      await ChatStore.set(s.db, id, 'state', jsonEncode(result));
      unawaited(sync(token).catchError((Object e) {
        lastError = e.toString();
      }));
    }
    if (['send', 'send-image', 'recall'].contains(operation)) {
      await record(token, body['peerId'], result);
    }
    if (operation == 'clear-history') {
      await s.db.transaction((d) =>
          ChatStore.clear(d, id, body['peerId'], result['clearedThrough']));
    }
    if (operation == 'message-image') {
      final row = await s.message(id, body['messageId']);
      if (row != null) {
        await s.db.transaction((d) => ChatStore.saveBytes(
            d,
            id,
            body['messageId'],
            base64Decode((result['image'] as String).split(',').last),
            'image/jpeg',
            row['image']?['sha256']));
      }
    }
    if (operation == 'read') {
      await ChatStore.set(s.db, id, 'read:${body['peerId']}', body['seq']);
    }
    return operation == 'state' ? s.decorate(id, result) : result;
  }

  Future<File> videoFile(String peer, String message, String token) async {
    final s = await store,
        id = await owner(token),
        row = await s.message(id, message);
    if (row?['kind'] == 'recalled') throw const FormatException('视频已撤回');
    final bytes = await s.bytes(id, message);
    if (bytes != null) {
      final dir = await Directory.systemTemp.createTemp('rs-chat-view-');
      return File('${dir.path}/video.mp4').writeAsBytes(bytes, flush: true);
    }
    final file = await video(peer, message, token, false);
    if (row != null) {
      await s.db.transaction((d) async => ChatStore.saveBytes(d, id, message,
          await file.readAsBytes(), 'video/mp4', row['video']?['sha256']));
    }
    return file;
  }
}
