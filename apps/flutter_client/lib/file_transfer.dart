import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:livekit_client/livekit_client.dart';

import 'native_service.dart';

const _controlTopic = 'rs-file-ctl';
const _binaryTopic = 'rs-file-bin';
const _chunkSize = 12 * 1024;
const _progressInterval = 256 * 1024;
const _maxActiveReceives = 8;
const maxTransferFileBytes = 50 * 1024 * 1024;
const transferFileTooLarge = '单个文件不能超过 50 MB';

String? transferFileSizeError(int size) => size < 0
    ? '文件大小无效'
    : size > maxTransferFileBytes ? transferFileTooLarge : null;

enum FileTransferDirection { send, receive }

class FileTransferProgress {
  const FileTransferProgress({
    required this.direction,
    required this.id,
    required this.name,
    required this.transferred,
    required this.size,
    required this.done,
    this.savedPath,
    this.error,
  });

  final FileTransferDirection direction;
  final int id;
  final String name;
  final int transferred;
  final int size;
  final bool done;
  final String? savedPath;
  final String? error;

  double get fraction =>
      size <= 0 ? 0 : (transferred / size).clamp(0, 1).toDouble();
}

class _ReceiveState {
  _ReceiveState({
    required this.id,
    required this.sender,
    required this.name,
    required this.size,
    required this.directory,
    required this.file,
  });

  final int id;
  final String sender;
  final String name;
  final int size;
  final Directory directory;
  final RandomAccessFile file;
  int received = 0;
  int nextSequence = 0;
  int lastProgress = 0;
  DateTime lastActivity = DateTime.now();
}

/// 与桌面端共用的 LiveKit 文件协议实现。
///
/// 观看会话使用 [sendSelectedFile] 向 caster 定向发送；投送会话开启
/// [receiveEnabled] 后接收来自观看端的文件，并保存到公共下载目录。
class FileTransferController extends ChangeNotifier {
  FileTransferController({
    required this.room,
    required this.receiveEnabled,
    this.destinationIdentity,
    this.recordStart,
    this.recordFinish,
  }) {
    _listener = room.createListener(synchronized: true)
      ..on<DataReceivedEvent>(_handleDataReceived);
    _expiryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final expired = _receives.entries
          .where((entry) =>
              DateTime.now().difference(entry.value.lastActivity).inSeconds >=
              60)
          .toList();
      for (final entry in expired) {
        _receives.remove(entry.key);
        unawaited(_failReceive(entry.value, '接收超时，文件传输已中止'));
      }
    });
  }

  final Room room;
  final bool receiveEnabled;
  final String? destinationIdentity;
  final Future<String> Function(String clientId, String name, int size)? recordStart;
  final Future<void> Function(String id, String status)? recordFinish;

  late final EventsListener<RoomEvent> _listener;
  late final Timer _expiryTimer;
  final List<FileTransferProgress> history = [];
  final Map<String, _ReceiveState> _receives = {};
  final Map<int, String> _sendCancellations = {};
  int? _activeSendId;
  bool _picking = false;
  final Map<int, Set<String>> _acks = {};
  bool _closed = false;

  FileTransferProgress? latestProgress;
  bool get sending => _picking || _activeSendId != null;

  void _update(FileTransferProgress progress) {
    latestProgress = progress;
    history.removeWhere(
        (p) => p.id == progress.id && p.direction == progress.direction);
    history.insert(0, progress);
    if (history.length > 100) history.removeLast();
    if (!_closed) notifyListeners();
  }

  Future<bool> sendSelectedFile() async {
    if (_closed) throw StateError('文件传输会话已经关闭');
    if (sending) throw StateError('已有文件正在发送');
    final destination = destinationIdentity;
    if (destination == null || destination.isEmpty) {
      throw StateError('尚未找到投送端，暂时不能发送文件');
    }

    _picking = true;
    SelectedNativeFile? selected;
    try {
      selected = await NativeFileBridge.pickFile();
    } finally {
      _picking = false;
    }
    if (selected == null) return false;
    final id = _newFileId();
    _activeSendId = id;
    _sendCancellations.remove(id);
    _acks[id] = {};
    String? recordId;

    try {
      _throwIfSendCancelled(id);
      final sizeError = transferFileSizeError(selected.size);
      if (sizeError != null) throw StateError(sizeError);
      final actualSize = await File(selected.path).length();
      final actualError = transferFileSizeError(actualSize);
      if (actualError != null) throw StateError(actualError);
      if (actualSize != selected.size) throw StateError('文件已变化，请重新选择');
      recordId = await recordStart?.call('mobile-$id', selected.name, selected.size);
      _throwIfSendCancelled(id);
      await _sendControl(
        destination,
        {
          't': 'meta',
          'id': id,
          'name': selected.name,
          'size': selected.size,
          'ack': 1
        },
      );
      _update(FileTransferProgress(
        direction: FileTransferDirection.send,
        id: id,
        name: selected.name,
        transferred: 0,
        size: selected.size,
        done: false,
      ));

      await _waitForAck(id, 'ready');
      final input = await File(selected.path).open();
      var sequence = 0;
      var sent = 0;
      var lastProgress = 0;
      try {
        while (true) {
          _throwIfSendCancelled(id);
          final chunk = await input.read(_chunkSize);
          if (chunk.isEmpty) break;
          if (sent + chunk.length > selected.size) {
            throw StateError('文件已变化，请重新选择');
          }
          final header = ByteData(12)
            ..setUint64(0, id, Endian.little)
            ..setUint32(8, sequence, Endian.little);
          final packet = BytesBuilder(copy: false)
            ..add(header.buffer.asUint8List())
            ..add(chunk);
          await _publish(
            destination: destination,
            topic: _binaryTopic,
            data: packet.takeBytes(),
          );
          sequence += 1;
          sent += chunk.length;
          if (sent - lastProgress >= _progressInterval) {
            lastProgress = sent;
            _update(FileTransferProgress(
              direction: FileTransferDirection.send,
              id: id,
              name: selected.name,
              transferred: sent,
              size: selected.size,
              done: false,
            ));
          }
        }
      } finally {
        await input.close();
      }

      _throwIfSendCancelled(id);
      await _sendControl(destination, {'t': 'end', 'id': id});
      await _waitForAck(id, 'saved');
      await _finishRecord(recordId, 'completed');
      _update(FileTransferProgress(
        direction: FileTransferDirection.send,
        id: id,
        name: selected.name,
        transferred: selected.size,
        size: selected.size,
        done: true,
      ));
      return true;
    } catch (error) {
      final message = _errorText(error);
      await _finishRecord(recordId, message == '已取消发送' ? 'cancelled' : 'failed');
      unawaited(_sendControl(
        destination,
        {'t': 'cancel', 'id': id, 'reason': message},
      ).catchError((_) {}));
      _update(FileTransferProgress(
        direction: FileTransferDirection.send,
        id: id,
        name: selected.name,
        transferred: 0,
        size: selected.size,
        done: true,
        error: message,
      ));
      rethrow;
    } finally {
      _acks.remove(id);
      _activeSendId = null;
      _sendCancellations.remove(id);
      try {
        await File(selected.path).delete();
      } catch (_) {
        // 文件选择器创建的缓存由系统后续清理也不影响使用。
      }
    }
  }

  void cancelSend() {
    final id = _activeSendId;
    if (id != null) _sendCancellations[id] = '已取消发送';
  }

  Future<void> _finishRecord(String? id, String status) async {
    if (id == null || recordFinish == null) return;
    try {
      await recordFinish!(id, status);
    } catch (_) {
      // Never turn a successfully saved file into a failed transfer because the
      // receipt service is temporarily offline. History shows "未确认完成".
      debugPrint('传输记录结果同步失败');
    }
  }

  void _throwIfSendCancelled(int id) {
    if (_closed) throw StateError('文件传输会话已经关闭');
    final reason = _sendCancellations.remove(id);
    if (reason != null) throw StateError(reason);
  }

  Future<void> _waitForAck(int id, String kind) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      _throwIfSendCancelled(id);
      if (_acks[id]?.contains(kind) ?? false) return;
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(kind == 'ready'
            ? '对方未确认接收，请检查连接并确认双端已更新'
            : '未收到对方保存回执，请先检查对方下载目录再重试');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _handleDataReceived(DataReceivedEvent event) async {
    if (_closed) return;
    final sender = event.participant?.identity;
    if (sender == null || sender.isEmpty) return;

    if (event.topic == _controlTopic) {
      await _handleControl(sender, event.data);
    } else if (event.topic == _binaryTopic && receiveEnabled) {
      await _handleBinary(sender, event.data);
    }
  }

  Future<void> _handleControl(String sender, List<int> data) async {
    Map<String, dynamic> message;
    try {
      message = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = message['t'] as String? ?? '';
    final id = (message['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return;
    final key = '$sender:$id';

    if (type == 'ready' || type == 'saved') {
      if (sender == destinationIdentity && id == _activeSendId) {
        _acks[id]?.add(type);
      }
      return;
    }
    if (type == 'cancel') {
      final reason = message['reason'] as String? ?? '对方取消了文件传输';
      final receiving = _receives.remove(key);
      if (receiving != null) {
        await _failReceive(receiving, reason, notifyRemote: false);
      } else if (_activeSendId == id && sender == destinationIdentity) {
        _sendCancellations[id] = reason;
      }
      return;
    }

    if (!receiveEnabled) {
      if (type == 'meta') {
        await _sendControl(sender, {
          't': 'cancel',
          'id': id,
          'reason': '当前会话不接收文件',
        });
      }
      return;
    }
    if (type == 'meta') {
      if (_receives.length >= _maxActiveReceives &&
          !_receives.containsKey(key)) {
        await _sendControl(sender, {
          't': 'cancel',
          'id': id,
          'reason': '同时接收的文件过多',
        });
        return;
      }
      final previous = _receives.remove(key);
      if (previous != null) {
        await _discardReceive(previous);
      }
      final name = _safeName(message['name'] as String? ?? 'file');
      final size = (message['size'] as num?)?.toInt() ?? 0;
      final sizeError = transferFileSizeError(size);
      if (sizeError != null) {
        await _sendControl(sender, {
          't': 'cancel',
          'id': id,
          'reason': sizeError,
        });
        return;
      }
      Directory? directory;
      try {
        final receiveDirectory =
            await Directory.systemTemp.createTemp('remotescreen-recv-');
        directory = receiveDirectory;
        final file = await File('${receiveDirectory.path}/payload')
            .open(mode: FileMode.write);
        if (_closed) {
          await file.close();
          await receiveDirectory.delete(recursive: true);
          return;
        }
        _receives[key] = _ReceiveState(
          id: id,
          sender: sender,
          name: name,
          size: size,
          directory: receiveDirectory,
          file: file,
        );
        await _sendControl(sender, {'t': 'ready', 'id': id});
        _update(FileTransferProgress(
          direction: FileTransferDirection.receive,
          id: id,
          name: name,
          transferred: 0,
          size: size,
          done: false,
        ));
      } catch (error) {
        final failed = _receives.remove(key);
        if (failed != null) await _discardReceive(failed);
        if (directory != null) {
          try {
            await directory.delete(recursive: true);
          } catch (_) {
            // 系统临时目录后续清理即可。
          }
        }
        final reason = '创建接收文件失败：${_errorText(error)}';
        await _sendControl(sender, {
          't': 'cancel',
          'id': id,
          'reason': reason,
        });
        _update(FileTransferProgress(
          direction: FileTransferDirection.receive,
          id: id,
          name: name,
          transferred: 0,
          size: size,
          done: true,
          error: reason,
        ));
      }
      return;
    }

    if (type == 'end') {
      final state = _receives.remove(key);
      if (state == null) return;
      if (state.received != state.size) {
        await _failReceive(
          state,
          '文件数据不完整：应收 ${state.size} 字节，实际收到 ${state.received} 字节',
        );
        return;
      }
      try {
        await state.file.flush();
        await state.file.close();
        final savedPath = await NativeFileBridge.saveReceivedFile(
          sourcePath: '${state.directory.path}/payload',
          name: state.name,
        );
        try {
          await state.directory.delete(recursive: true);
        } catch (_) {}
        unawaited(
            _sendControl(sender, {'t': 'saved', 'id': id}).catchError((_) {}));
        _update(FileTransferProgress(
          direction: FileTransferDirection.receive,
          id: state.id,
          name: state.name,
          transferred: state.received,
          size: state.size,
          done: true,
          savedPath: savedPath,
        ));
      } catch (error) {
        await _failReceive(state, _errorText(error));
      }
    }
  }

  Future<void> _handleBinary(String sender, List<int> data) async {
    if (data.length < 12) return;
    final bytes = data is Uint8List ? data : Uint8List.fromList(data);
    final header = ByteData.sublistView(bytes, 0, 12);
    final id = header.getUint64(0, Endian.little);
    final sequence = header.getUint32(8, Endian.little);
    final key = '$sender:$id';
    final state = _receives[key];
    if (state == null) return;
    state.lastActivity = DateTime.now();
    final payload = Uint8List.sublistView(bytes, 12);

    if (sequence != state.nextSequence) {
      _receives.remove(key);
      await _failReceive(
        state,
        '文件数据顺序错误：期望分块 ${state.nextSequence}，收到 $sequence',
      );
      return;
    }
    if (state.received + payload.length > state.size) {
      _receives.remove(key);
      await _failReceive(state, '收到的文件数据超过声明大小');
      return;
    }
    try {
      await state.file.writeFrom(payload);
    } catch (error) {
      _receives.remove(key);
      await _failReceive(state, '写入临时文件失败：$error');
      return;
    }
    state.nextSequence += 1;
    state.received += payload.length;
    if (state.received - state.lastProgress >= _progressInterval) {
      state.lastProgress = state.received;
      _update(FileTransferProgress(
        direction: FileTransferDirection.receive,
        id: state.id,
        name: state.name,
        transferred: state.received,
        size: state.size,
        done: false,
      ));
    }
  }

  Future<void> _failReceive(
    _ReceiveState state,
    String reason, {
    bool notifyRemote = true,
  }) async {
    try {
      await state.file.close();
    } catch (_) {}
    try {
      await state.directory.delete(recursive: true);
    } catch (_) {}
    if (notifyRemote) {
      unawaited(_sendControl(state.sender, {
        't': 'cancel',
        'id': state.id,
        'reason': reason,
      }).catchError((_) {}));
    }
    _update(FileTransferProgress(
      direction: FileTransferDirection.receive,
      id: state.id,
      name: state.name,
      transferred: state.received,
      size: state.size,
      done: true,
      error: reason,
    ));
  }

  Future<void> _discardReceive(_ReceiveState state) async {
    try {
      await state.file.close();
    } catch (_) {}
    try {
      await state.directory.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _sendControl(String destination, Map<String, dynamic> value) =>
      _publish(
        destination: destination,
        topic: _controlTopic,
        data: utf8.encode(jsonEncode(value)),
      );

  Future<void> _publish({
    required String destination,
    required String topic,
    required List<int> data,
  }) async {
    final participant = room.localParticipant;
    if (participant == null) throw StateError('LiveKit 会话尚未连接');
    await participant
        .publishData(
          data,
          reliable: true,
          destinationIdentities: [destination],
          topic: topic,
        )
        .timeout(const Duration(seconds: 30));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _expiryTimer.cancel();
    await _listener.dispose();
    final states = _receives.values.toList();
    _receives.clear();
    for (final state in states) {
      await _discardReceive(state);
    }
    super.dispose();
  }
}

int _fileCounter = 0;

int _newFileId() {
  _fileCounter = (_fileCounter + 1) & 0xff;
  return (DateTime.now().millisecondsSinceEpoch << 8) | _fileCounter;
}

String _safeName(String value) {
  final normalized = value.replaceAll('\\', '/');
  final leaf = normalized.split('/').last.trim();
  final cleaned = leaf.replaceAll(RegExp(r'[\x00-\x1f]'), '_');
  return cleaned.isEmpty ? 'file' : cleaned;
}

String _errorText(Object error) {
  final text = error.toString();
  return text.startsWith('Bad state: ') ? text.substring(11) : text;
}
