import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show ChangeNotifier;

typedef ChatSender = Future<Map<String, dynamic>> Function(
    String operation, Map<String, dynamic> body);

class OutgoingChatMessage {
  OutgoingChatMessage(
      {required this.id,
      required this.kind,
      this.text = '',
      this.image,
      this.bytes,
      this.videoPath,
      this.videoName = '',
      this.videoSize = 0})
      : createdAt = DateTime.now().millisecondsSinceEpoch;
  final String id, kind, text;
  final String? image;
  final Uint8List? bytes;
  final String? videoPath;
  final String videoName;
  final int videoSize;
  final int createdAt;
  String status = 'queued', error = '';
  Map<String, dynamic> record(String accountId) => {
        'id': 'local_$id',
        'clientId': id,
        'senderId': accountId,
        'kind': kind,
        'text': kind == 'image'
            ? '[图片]'
            : kind == 'video'
                ? '[视频]'
                : text,
        if (kind == 'video') 'video': {'name': videoName, 'bytes': videoSize},
        'createdAt': '$createdAt',
        'localStatus': status,
        'localError': error,
        if (image != null)
          'image': {'width': 240, 'height': 240, 'thumbnail': image},
        if (bytes != null) '_localImageBytes': bytes,
      };
}

/// Account-scoped in-memory uploads survive leaving and reopening a conversation.
/// Upload completion is distinct from local enqueueing; retries retain clientId.
class ChatSendQueue extends ChangeNotifier {
  ChatSendQueue(this.accountId, this.peerId, Future<ChatSender> session)
      : sender = session.then<ChatSender>((value) => value,
            onError: (Object error) =>
                (String operation, Map<String, dynamic> body) =>
                    Future<Map<String, dynamic>>.error(error));
  final String accountId, peerId;
  final Future<ChatSender> sender;
  final List<OutgoingChatMessage> items = [];
  final List<Map<String, dynamic>> confirmed = [];
  bool running = false, _cancelled = false;

  void enqueue(List<OutgoingChatMessage> batch) {
    if (_cancelled) throw StateError('账号已变化，请重新打开聊天');
    final all = [...items, ...batch];
    final videoBytes = all.fold<int>(0, (sum, m) => sum + m.videoSize);
    final bytes = all.fold<int>(0, (sum, m) => sum + (m.bytes?.length ?? 0));
    if (items.length + batch.length > 40 ||
        bytes > 80 * 1024 * 1024 ||
        videoBytes > 512 * 1024 * 1024) {
      throw StateError('发送队列较满，请等当前图片或视频发送完成后再试');
    }
    items.addAll(batch);
    notifyListeners();
    unawaited(_drain());
  }

  void retry(String id) {
    for (final item in items) {
      if (item.id == id && item.status == 'failed') {
        item.status = 'queued';
        item.error = '';
        notifyListeners();
        unawaited(_drain());
        return;
      }
    }
  }

  void _confirm(Map<String, dynamic> row) {
    final index = confirmed.indexWhere((old) => old['id'] == row['id']);
    if (index < 0) {
      confirmed.add(row);
    } else if (confirmed[index]['kind'] != 'recalled' ||
        row['kind'] == 'recalled') {
      confirmed[index] = row;
    }
    if (confirmed.length > 50) confirmed.removeAt(0);
  }

  void reconcile(Iterable<Map<String, dynamic>> rows) {
    var changed = false;
    for (final row in rows) {
      if (row['senderId'] != accountId || row['clientId'] == null) continue;
      if (items.any((m) => m.id == row['clientId'])) {
        items.removeWhere((m) => m.id == row['clientId']);
        _confirm(row);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  Future<void> _drain() async {
    if (running || _cancelled) return;
    running = true;
    try {
      while (!_cancelled) {
        final queued = items.where((m) => m.status == 'queued').toList();
        if (queued.isEmpty) break;
        final item = queued.first;
        item.status = 'sending';
        notifyListeners();
        try {
          final send = await sender;
          if (_cancelled || !items.contains(item)) continue;
          final response = await send(
              item.kind == 'image'
                  ? 'send-image'
                  : item.kind == 'video'
                      ? 'send-video'
                      : 'send',
              {
                'peerId': peerId,
                'clientId': item.id,
                if (item.kind == 'image')
                  'image': item.image
                else if (item.kind == 'video')
                  'videoPath': item.videoPath
                else
                  'text': item.text,
              });
          if (_cancelled) return;
          final row = Map<String, dynamic>.from(response['message']);
          row['clientId'] ??= item.id;
          _confirm(row);
          items.remove(item);
        } catch (error) {
          if (_cancelled) return;
          if (items.contains(item)) {
            item.status = 'failed';
            item.error = error.toString();
          }
        }
        notifyListeners();
      }
    } finally {
      running = false;
      if (!_cancelled) notifyListeners();
    }
  }

  void cancel() {
    _cancelled = true;
    items.clear();
    confirmed.clear();
    notifyListeners();
  }

  void clearCompleted() {
    confirmed.clear();
  }

  void discardFailures() {
    items.removeWhere((item) => item.status == 'failed');
    confirmed.clear();
    notifyListeners();
  }
}

class ChatOutboxStore {
  final _queues = <(String, String), ChatSendQueue>{};
  ChatSendQueue queue(String accountId, String peerId,
          Future<ChatSender> Function() sender) =>
      _queues.putIfAbsent((accountId, peerId),
          () => ChatSendQueue(accountId, peerId, sender()));
  void reset() {
    for (final queue in _queues.values) {
      queue.cancel();
    }
    _queues.clear();
  }
}

final chatOutbox = ChatOutboxStore();
