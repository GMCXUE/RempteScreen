import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart' as digest;
import 'chat_store.dart';

// Independent authenticated chunks bound to the exact header and sequence.
// The authenticated end record detects truncation; restore is one transaction.
class ChatBackup {
  static const chunkSize = 256 * 1024;
  static final cipher = AesGcm.with256bits();
  static Future<SecretKey> key(String password, List<int> salt) {
    if (password.runes.length < 8) {
      throw const FormatException('备份密码至少需要 8 个字符');
    }
    return compute(_deriveBackupKey, [password, salt]).then(SecretKey.new);
  }

  static List<int> nonce(int n) {
    final bytes = ByteData(12);
    bytes.setUint64(4, n, Endian.big);
    return bytes.buffer.asUint8List();
  }

  static List<int> aad(String header, int n) => utf8.encode('$header:$n');
  static Stream<String> lines(File file) async* {
    final line = <int>[];
    await for (final chunk in file.openRead()) {
      for (final b in chunk) {
        if (b == 10) {
          yield utf8.decode(line);
          line.clear();
        } else {
          line.add(b);
          if (line.length > 1024 * 1024) {
            throw const FormatException('备份文件记录过大');
          }
        }
      }
    }
    if (line.isNotEmpty) throw const FormatException('备份文件不完整');
  }

  static Future<void> export(
      ChatStore store, String owner, File target, String password) async {
    final random = Random.secure(),
        salt = List<int>.generate(16, (_) => random.nextInt(256));
    final header = jsonEncode({
          'format': 'RemoteScreenChat',
          'version': 1,
          'salt': base64Encode(salt)
        }),
        secret = await key(password, salt);
    final part = File('${target.path}.part');
    final output = await part.open(mode: FileMode.write);
    var n = 0;
    Future<void> write(Map<String, dynamic> record) async {
      final box = await cipher.encrypt(utf8.encode(jsonEncode(record)),
          secretKey: secret, nonce: nonce(n), aad: aad(header, n));
      n++;
      await output.writeString(
          '${base64Encode([...box.cipherText, ...box.mac.bytes])}\n');
    }

    try {
      await output.writeString('$header\n');
      await store.db.transaction((d) async {
        await write({'type': 'owner', 'id': owner});
        final state = await ChatStore.setting(d, owner, 'state');
        if (state != null) {
          await write({'type': 'state', 'data': jsonDecode(state)});
        }
        for (final c in await d.rawQuery(
            "SELECT key,data FROM settings WHERE owner=? AND key LIKE 'clear:%'",
            [owner])) {
          await write({
            'type': 'clear',
            'peer': (c['key'] as String).substring(6),
            'seq': c['data']
          });
        }
        // Keyset pagination keeps memory bounded independently of archive size.
        var after = 0;
        while (true) {
          final rows = await d.rawQuery(
              'SELECT id,peer,seq,row FROM messages WHERE owner=? AND seq>? ORDER BY seq LIMIT 100',
              [owner, after]);
          if (rows.isEmpty) break;
          for (final row in rows) {
            after = row['seq'] as int;
            await write({
              'type': 'message',
              'peer': row['peer'],
              'row': jsonDecode(row['row'] as String)
            });
            final media = await d.rawQuery(
                'SELECT data,mime,sha FROM media WHERE owner=? AND id=?',
                [owner, row['id']]);
            if (media.isEmpty) continue;
            final bytes = media.first['data'] as Uint8List;
            if (digest.sha256.convert(bytes).toString() != media.first['sha']) {
              throw const FormatException('本地媒体校验失败，请重新下载后备份');
            }
            await write({
              'type': 'media-start',
              'id': row['id'],
              'mime': media.first['mime'],
              'sha': media.first['sha'],
              'bytes': bytes.length
            });
            for (var i = 0; i < bytes.length; i += chunkSize) {
              await write({
                'type': 'media-chunk',
                'data': base64Encode(
                    bytes.sublist(i, min(i + chunkSize, bytes.length)))
              });
            }
            await write({'type': 'media-end'});
          }
        }
        await write({'type': 'end', 'records': n});
      });
      await output.flush();
      await output.close();
      await part.rename(target.path);
    } catch (_) {
      await output.close();
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  static Future<int> restore(
      ChatStore store, String owner, File file, String password) async {
    final iterator = StreamIterator(lines(file));
    var count = 0;
    try {
      if (!await iterator.moveNext()) throw const FormatException('备份文件为空');
      final header = iterator.current, info = jsonDecode(header);
      if (header.length > 4096 ||
          info['format'] != 'RemoteScreenChat' ||
          info['version'] != 1) {
        throw const FormatException('不支持的备份格式');
      }
      final salt = base64Decode(info['salt']);
      if (salt.length != 16) throw const FormatException('备份文件格式不正确');
      final secret = await key(password, salt);
      await store.db.transaction((d) async {
        var n = 0, ended = false, ownerChecked = false;
        Map<String, dynamic>? media;
        BytesBuilder? bytes;
        while (await iterator.moveNext()) {
          if (ended) throw const FormatException('备份文件包含多余数据');
          final encrypted = base64Decode(iterator.current);
          if (encrypted.length < 16) throw const FormatException('备份文件不完整');
          List<int> plain;
          try {
            plain = await cipher.decrypt(
                SecretBox(encrypted.sublist(0, encrypted.length - 16),
                    nonce: nonce(n),
                    mac: Mac(encrypted.sublist(encrypted.length - 16))),
                secretKey: secret,
                aad: aad(header, n));
          } catch (_) {
            throw const FormatException('备份密码错误或文件已损坏');
          }
          final record = jsonDecode(utf8.decode(plain)) as Map<String, dynamic>,
              type = record['type'];
          if (n == 0) {
            if (type != 'owner' || record['id'] != owner) {
              throw const FormatException('请登录备份所属账号后再恢复');
            }
            ownerChecked = true;
          } else if (!ownerChecked) {
            throw const FormatException('备份账号无效');
          } else if (media != null &&
              type != 'media-chunk' &&
              type != 'media-end') {
            throw const FormatException('备份媒体不完整');
          } else if (type == 'state') {
            if (record['data']?['me']?['id'] != owner) {
              throw const FormatException('备份账号无效');
            }
            if (await ChatStore.setting(d, owner, 'state') == null) {
              await ChatStore.set(
                  d, owner, 'state', jsonEncode(record['data']));
            }
          } else if (type == 'clear') {
            await ChatStore.clear(d, owner, record['peer'], record['seq']);
          } else if (type == 'message') {
            await ChatStore.merge(d, owner, record['peer'],
                Map<String, dynamic>.from(record['row']));
            count++;
          } else if (type == 'media-start') {
            if (record['bytes'] is! int ||
                record['bytes'] < 1 ||
                record['bytes'] > 50 * 1024 * 1024 ||
                !['video/mp4', 'image/jpeg'].contains(record['mime'])) {
              throw const FormatException('备份媒体格式不正确');
            }
            media = record;
            bytes = BytesBuilder(copy: false);
          } else if (type == 'media-chunk') {
            if (media == null) {
              throw const FormatException('备份媒体格式不正确');
            }
            final chunk = base64Decode(record['data']);
            if (chunk.length > chunkSize) {
              throw const FormatException('备份媒体分块过大');
            }
            bytes!.add(chunk);
            if (bytes.length > media['bytes']) {
              throw const FormatException('备份媒体大小不正确');
            }
          } else if (type == 'media-end') {
            if (media == null || bytes!.length != media['bytes']) {
              throw const FormatException('备份媒体不完整');
            }
            await ChatStore.saveBytes(d, owner, media['id'], bytes.takeBytes(),
                media['mime'], media['sha']);
            media = null;
            bytes = null;
          } else if (type == 'end') {
            if (record['records'] != n) throw const FormatException('备份文件不完整');
            ended = true;
          } else if (type != 'owner') {
            throw const FormatException('不支持的备份记录');
          } else {
            throw const FormatException('备份账号重复');
          }
          n++;
        }
        if (!ended || media != null || !ownerChecked) {
          throw const FormatException('备份文件不完整');
        }
      });
      return count;
    } finally {
      await iterator.cancel();
    }
  }
}

Future<List<int>> _deriveBackupKey(List<Object> args) async {
  final key =
      await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 210000, bits: 256)
          .deriveKey(
              secretKey: SecretKey(utf8.encode(args[0] as String)),
              nonce: args[1] as List<int>);
  return key.extractBytes();
}
