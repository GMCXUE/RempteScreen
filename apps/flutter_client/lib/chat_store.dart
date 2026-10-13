import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

// The UI never acknowledges receipt until this transaction has committed.
class ChatStore {
  ChatStore(this.db);
  final Database db;
  static Future<ChatStore> open(String path) async {
    final db = await openDatabase(path, version: 2, onConfigure: (d) async {
      await d.execute('PRAGMA journal_mode=WAL');
      await d.execute('PRAGMA synchronous=FULL');
      await d.execute('PRAGMA foreign_keys=ON');
    }, onCreate: (d, _) async {
      for (final sql in schema) {
        await d.execute(sql);
      }
    }, onUpgrade: (d, old, version) async {
      if (old < 2) {
        await d.execute(
            "ALTER TABLE messages ADD COLUMN sender TEXT NOT NULL DEFAULT ''");
        for (final row
            in await d.rawQuery('SELECT owner,id,row FROM messages')) {
          await d.rawUpdate(
              'UPDATE messages SET sender=? WHERE owner=? AND id=?', [
            jsonDecode(row['row'] as String)['senderId'],
            row['owner'],
            row['id']
          ]);
        }
      }
    });
    return ChatStore(db);
  }

  static const schema = [
    'CREATE TABLE bindings(token TEXT PRIMARY KEY,owner TEXT NOT NULL)',
    'CREATE TABLE settings(owner TEXT NOT NULL,key TEXT NOT NULL,data TEXT NOT NULL,PRIMARY KEY(owner,key))',
    'CREATE TABLE messages(owner TEXT NOT NULL,id TEXT NOT NULL,peer TEXT NOT NULL,seq INTEGER NOT NULL,kind TEXT NOT NULL,text TEXT NOT NULL,created INTEGER NOT NULL,edit INTEGER NOT NULL,row TEXT NOT NULL,acked INTEGER NOT NULL DEFAULT 0,sender TEXT NOT NULL,PRIMARY KEY(owner,id))',
    'CREATE INDEX chat_pair ON messages(owner,peer,seq)',
    'CREATE UNIQUE INDEX chat_sequence ON messages(owner,seq)',
    'CREATE TABLE media(owner TEXT NOT NULL,id TEXT NOT NULL,data BLOB NOT NULL,sha TEXT NOT NULL,mime TEXT NOT NULL,PRIMARY KEY(owner,id),FOREIGN KEY(owner,id) REFERENCES messages(owner,id) ON DELETE CASCADE)',
  ];
  static String tokenKey(String token) =>
      sha256.convert(utf8.encode(token)).toString();
  Future<void> bind(String token, String owner) async => db.rawInsert(
      'INSERT OR REPLACE INTO bindings VALUES(?,?)', [tokenKey(token), owner]);
  Future<String?> owner(String token) async {
    final rows = await db.rawQuery(
        'SELECT owner FROM bindings WHERE token=?', [tokenKey(token)]);
    return rows.isEmpty ? null : rows.first['owner'] as String;
  }

  static Future<String?> setting(
      DatabaseExecutor d, String owner, String key) async {
    final rows = await d.rawQuery(
        'SELECT data FROM settings WHERE owner=? AND key=?', [owner, key]);
    return rows.isEmpty ? null : rows.first['data'] as String;
  }

  static Future<void> set(
      DatabaseExecutor d, String owner, String key, String data) async {
    if ((['after', 'edit'].contains(key) || key.startsWith('read:')) &&
        int.parse(await setting(d, owner, key) ?? '0') > int.parse(data)) {
      return;
    }
    await d.rawInsert(
        'INSERT OR REPLACE INTO settings VALUES(?,?,?)', [owner, key, data]);
  }

  Future<String?> get(String owner, String key) => setting(db, owner, key);
  static Future<void> clear(
      DatabaseExecutor d, String owner, String peer, String seq) async {
    final boundary = int.parse(seq),
        old = int.parse(await setting(d, owner, 'clear:$peer') ?? '0');
    if (boundary <= old) return;
    await set(d, owner, 'clear:$peer', seq);
    await d.delete('messages',
        where: 'owner=? AND peer=? AND seq<=?',
        whereArgs: [owner, peer, boundary]);
  }

  static Future<void> merge(DatabaseExecutor d, String owner, String peer,
      Map<String, dynamic> row) async {
    final id = row['id'],
        kind = row['kind'],
        seq = int.tryParse('${row['seq']}'),
        created = int.tryParse('${row['createdAt']}');
    if (id is! String ||
        id.isEmpty ||
        id.length > 100 ||
        peer.isEmpty ||
        peer.length > 100 ||
        peer == owner ||
        seq == null ||
        seq < 1 ||
        created == null ||
        !['text', 'image', 'video', 'call', 'recalled'].contains(kind) ||
        row['senderId'] is! String ||
        ![owner, peer].contains(row['senderId'])) {
      throw const FormatException('聊天记录格式不正确');
    }
    if (seq <= int.parse(await setting(d, owner, 'clear:$peer') ?? '0')) return;
    final existing = await d.rawQuery(
        'SELECT peer,seq,row,edit,kind FROM messages WHERE owner=? AND id=?',
        [owner, id]);
    if (existing.isNotEmpty &&
        (existing.first['peer'] != peer ||
            existing.first['seq'] != seq ||
            jsonDecode(existing.first['row'] as String)['senderId'] !=
                row['senderId'])) {
      throw const FormatException('聊天记录身份不一致');
    }
    final edit = int.tryParse('${row['editSeq'] ?? 0}');
    if (edit == null ||
        edit < 0 ||
        created < 0 ||
        created > 8640000000000000 ||
        row['text'] is! String) {throw const FormatException('聊天记录格式不正确');}
    row = {...row, 'seq': '$seq', 'createdAt': '$created', 'editSeq': '$edit'};
    if (existing.isEmpty) {
      await d.rawInsert(
          'INSERT INTO messages(owner,id,peer,seq,kind,text,created,edit,row,sender) VALUES(?,?,?,?,?,?,?,?,?,?)',
          [
            owner,
            id,
            peer,
            seq,
            kind,
            row['text'] ?? '',
            created,
            edit,
            jsonEncode(row),
            row['senderId']
          ]);
    } else if ((edit >= (existing.first['edit'] as int) ||
            (kind == 'recalled' && existing.first['kind'] != 'recalled')) &&
        (existing.first['kind'] != 'recalled' || kind == 'recalled')) {
      await d.rawUpdate(
          'UPDATE messages SET kind=?,text=?,edit=?,row=?,acked=0 WHERE owner=? AND id=?',
          [kind, row['text'] ?? '', edit, jsonEncode(row), owner, id]);
    }
    if (kind == 'recalled') {
      await d
          .delete('media', where: 'owner=? AND id=?', whereArgs: [owner, id]);
    }
  }

  Future<void> save(String owner, String peer, Map<String, dynamic> row) =>
      db.transaction((d) => merge(d, owner, peer, row));
  Future<void> apply(String owner, Map<String, dynamic> feed) =>
      db.transaction((d) async {
        for (final r in (feed['reads'] ?? []) as List) {
          await set(d, owner, 'read:${r['peerId']}', r['seq']);
        }
        for (final c in feed['clears'] as List) {
          await clear(d, owner, c['peerId'], c['seq']);
        }
        for (final row in [
          ...feed['messages'] as List,
          ...feed['updates'] as List
        ]) {
          await merge(d, owner, row['peerId'], Map<String, dynamic>.from(row));
        }
        await set(d, owner, 'after', feed['after']);
        await set(d, owner, 'edit', feed['edit']);
      });
  Future<Map<String, dynamic>?> message(String owner, String id) async {
    final rows = await db.rawQuery(
        'SELECT row FROM messages WHERE owner=? AND id=?', [owner, id]);
    return rows.isEmpty
        ? null
        : jsonDecode(rows.first['row'] as String) as Map<String, dynamic>;
  }

  Future<Uint8List?> bytes(String owner, String id) async {
    final rows = await db.rawQuery(
        'SELECT data,sha FROM media WHERE owner=? AND id=?', [owner, id]);
    if (rows.isEmpty) return null;
    final data = rows.first['data'] as Uint8List;
    if (sha256.convert(data).toString() != rows.first['sha']) {
      await db
          .delete('media', where: 'owner=? AND id=?', whereArgs: [owner, id]);
      return null;
    }
    return data;
  }

  static Future<void> saveBytes(DatabaseExecutor d, String owner, String id,
      Uint8List data, String mime, String? expected) async {
    final row = (await d.rawQuery(
        'SELECT kind,row FROM messages WHERE owner=? AND id=?', [owner, id]));
    if (row.isEmpty || row.first['kind'] == 'recalled') return;
    if (data.isEmpty || data.length > 50 * 1024 * 1024) {
      throw const FormatException('媒体大小不正确');
    }
    final message = jsonDecode(row.first['row'] as String);
    final meta = message[message['kind']];
    if (meta is Map && meta['bytes'] != null && data.length != meta['bytes']) {
      throw const FormatException('媒体大小校验失败');
    }
    final hash = sha256.convert(data).toString();
    if (expected != null && hash != expected) {
      throw const FormatException('媒体校验失败');
    }
    await d.rawInsert('INSERT OR REPLACE INTO media VALUES(?,?,?,?,?)',
        [owner, id, data, hash, mime]);
  }

  Future<List<Map<String, dynamic>>> missing(String owner) => db.rawQuery(
      "SELECT m.row,m.peer FROM messages m LEFT JOIN settings r ON r.owner=m.owner AND r.key='mediaTry:'||m.id WHERE m.owner=? AND kind IN ('image','video') AND COALESCE(CAST(r.data AS INTEGER),0)<? AND NOT EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id) ORDER BY COALESCE(CAST(r.data AS INTEGER),0),seq LIMIT 20",
      [owner, DateTime.now().millisecondsSinceEpoch - 60000]);
  Future<List<String>> pending(String owner) async => (await db.rawQuery(
          "SELECT id FROM messages m WHERE owner=? AND acked=0 AND (kind NOT IN ('image','video') OR EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id)) LIMIT 100",
          [owner]))
      .map((r) => r['id'] as String)
      .toList();
  Future<Map<String, dynamic>> decorate(
      String owner, Map<String, dynamic> state) async {
    for (final friend in (state['friends'] ?? []) as List) {
      final peer = friend['id'];
      final rows = await db.rawQuery(
          'SELECT row FROM messages WHERE owner=? AND peer=? ORDER BY seq DESC LIMIT 1',
          [owner, peer]);
      if (rows.isNotEmpty) {
        friend['lastText'] = jsonDecode(rows.first['row'] as String)['text'];
      }
      final read = int.parse(await get(owner, 'read:$peer') ?? '0');
      final localUnread = (await db.rawQuery(
              "SELECT COUNT(*) AS n FROM messages WHERE owner=? AND peer=? AND seq>? AND kind<>'recalled' AND sender=?",
              [owner, peer, read, peer]))
          .first['n'];
      final remoteUnread = (friend['unread'] as num?)?.toInt() ?? 0;
      friend['unread'] = state['offline'] == true
          ? localUnread
          : ((localUnread as int) > remoteUnread ? localUnread : remoteUnread);
    }
    return state;
  }

  Future<Map<String, dynamic>> query(
      String owner, String op, Map<String, dynamic> body) async {
    final peer = body['peerId'] as String,
        where = ['owner=?', 'peer=?'],
        args = <Object?>[owner, peer];
    if (body['before'] != null) {
      where.add('seq<?');
      args.add(int.parse(body['before'].toString()));
    }
    if (body['after'] != null) {
      where.add('seq>?');
      args.add(int.parse(body['after'].toString()));
    }
    if (op == 'history') {
      where.add("kind<>'recalled'");
      final kind = body['kind'] ?? 'all';
      if (kind == 'link') {
        where.add(
            "kind='text' AND (text LIKE '%http://%' OR text LIKE '%https://%')");
      } else if (kind == 'media') {
        where.add("kind IN ('image','video')");
      } else if (kind != 'all') {
        where.add('kind=?');
        args.add(kind);
      }
      final q = (body['query'] ?? '').toString().trim();
      if (q.isNotEmpty) {
        where.add("text LIKE ? ESCAPE '\\'");
        args.add(
            '%${q.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_')}%');
      }
      if (body['from'] != null) {
        where.add('created>=?');
        args.add(body['from']);
      }
      if (body['to'] != null) {
        where.add('created<?');
        args.add(body['to']);
      }
    }
    if (op == 'message-context') {
      final target = await message(owner, body['messageId']);
      if (target == null) throw const FormatException('消息已清空或不存在');
      final seq = int.parse(target['seq']);
      final lower = await db.rawQuery(
          'SELECT row FROM messages WHERE owner=? AND peer=? AND seq<=? ORDER BY seq DESC LIMIT 26',
          [owner, peer, seq]);
      final upper = await db.rawQuery(
          'SELECT row FROM messages WHERE owner=? AND peer=? AND seq>? ORDER BY seq LIMIT 26',
          [owner, peer, seq]);
      return {
        ...await meta(owner, peer),
        'messages': [...lower.take(25).toList().reversed, ...upper.take(25)]
            .map((r) => jsonDecode(r['row'] as String))
            .toList(),
        'hasMore': lower.length > 25,
        'hasNewer': upper.length > 25
      };
    }
    final ascending = op == 'messages' && body['after'] != null;
    final rows = await db.rawQuery(
        'SELECT row FROM messages WHERE ${where.join(' AND ')} ORDER BY seq ${ascending ? 'ASC' : 'DESC'} LIMIT 51',
        args);
    final selected =
        rows.take(50).map((r) => jsonDecode(r['row'] as String)).toList();
    final updates = op == 'messages'
        ? (await db.rawQuery(
                'SELECT row FROM messages WHERE owner=? AND peer=? AND kind=?',
                [owner, peer, 'recalled']))
            .map((r) => jsonDecode(r['row'] as String))
            .toList()
        : [];
    return {
      ...await meta(owner, peer),
      'messages': op == 'messages' && !ascending
          ? selected.reversed.toList()
          : selected,
      'updates': updates,
      'hasMore': rows.length > 50
    };
  }

  Future<Map<String, dynamic>> meta(String owner, String peer) async => {
        'clearedThrough': await get(owner, 'clear:$peer') ?? '0',
        'syncCursor': '0',
        'serverNow': DateTime.now().millisecondsSinceEpoch.toString()
      };
}
