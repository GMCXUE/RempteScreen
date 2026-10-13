import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'app_theme.dart';
import 'app_components.dart';

String transferStatusLabel(String? status) => switch (status) {
  'completed' => '已完成', 'failed' => '失败', 'cancelled' => '已取消',
  'sending' => '发送中', _ => '未确认完成',
};

/// Server metadata only; never uploads or downloads file contents.
class FileTransferHistory extends StatefulWidget {
  const FileTransferHistory({super.key, required this.api});
  final ApiService api;
  @override
  State<FileTransferHistory> createState() => _FileTransferHistoryState();
}

class _FileTransferHistoryState extends State<FileTransferHistory> {
  List<Map<String, dynamic>> _items = [];
  String? _next, _error;
  bool _busy = false;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_items.length <= 50) _load();
    });
  }
  @override
  void dispose() { _timer?.cancel(); super.dispose(); }
  Future<void> _load({bool more = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await widget.api.fileTransferHistory(before: more ? _next : null);
      if (!mounted) return;
      final items = (data['items'] as List).cast<Map<String, dynamic>>();
      setState(() {
        _items = more ? [..._items, ...items] : items;
        _next = data['next'] as String?;
        _error = null;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '传输历史加载失败，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
  String _party(Map<String, dynamic> item, String prefix) =>
      '${item['${prefix}Name']}（${item['${prefix}Id']}）\n'
      '${item['${prefix}DeviceName']} · ${item['${prefix}DeviceId']}';
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(children: [
        const Expanded(child: SectionHeading('传输历史', caption: '长期保存记录，不保存文件')),
        IconButton(tooltip: '刷新传输历史', onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh)),
      ]),
      if (_error != null) Padding(padding: const EdgeInsets.all(12),
          child: Text(_error!, style: const TextStyle(color: AppTheme.danger))),
      if (_busy) const LinearProgressIndicator(minHeight: 2),
      Card(child: Column(children: [
        if (_items.isEmpty && !_busy && _error == null)
          const Padding(padding: EdgeInsets.all(24), child: Text('暂无传输历史')),
        for (final item in _items)
          Padding(padding: const EdgeInsets.all(16), child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Text(item['name'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                const SizedBox(width: 8),
                Text(transferStatusLabel(item['status'] as String?)),
              ]),
              const SizedBox(height: 6),
              Text('${formatFileSize((item['size'] as num).toInt())} · '
                  '${DateTime.fromMillisecondsSinceEpoch((item['createdAt'] as num).toInt()).toLocal().toString().split('.').first}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
              const SizedBox(height: 8),
              Text('发送方：${_party(item, 'sender')}\n接收方：${_party(item, 'recipient')}',
                  style: const TextStyle(fontSize: 12, color: AppTheme.muted)),
              const Divider(height: 20),
            ],
          )),
        if (_next != null) TextButton(onPressed: _busy ? null : () => _load(more: true),
            child: const Text('加载更早记录')),
      ])),
    ],
  );
}
