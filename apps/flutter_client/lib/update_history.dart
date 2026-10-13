import 'package:flutter/material.dart';

typedef UpdateHistoryLoader = Future<Map<String, dynamic>> Function(
    int? before);

class UpdateHistoryPage extends StatelessWidget {
  const UpdateHistoryPage(
      {super.key, required this.load, required this.currentBuild});
  final UpdateHistoryLoader load;
  final int? currentBuild;
  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('更新历史')),
      body: SafeArea(
          child: UpdateHistoryList(load: load, currentBuild: currentBuild)));
}

class UpdateHistoryList extends StatefulWidget {
  const UpdateHistoryList(
      {super.key, required this.load, required this.currentBuild});
  final UpdateHistoryLoader load;
  final int? currentBuild;
  @override
  State<UpdateHistoryList> createState() => _UpdateHistoryListState();
}

class _UpdateHistoryListState extends State<UpdateHistoryList> {
  final _items = <Map<String, dynamic>>[];
  int? _next;
  bool _loading = false, _loaded = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.load(_next);
      if (!mounted) return;
      setState(() {
        _items.addAll(
            (page['items'] as List).map((r) => Map<String, dynamic>.from(r)));
        _next = page['next'] as int?;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '暂时无法加载更新历史，请检查网络后重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _date(int millis) {
    final d = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    String pad(int n) => '$n'.padLeft(2, '0');
    return '${d.year}/${pad(d.month)}/${pad(d.day)} ${pad(d.hour)}:${pad(d.minute)}';
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
      padding: const EdgeInsets.all(20),
      itemCount: _items.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('当前平台的完整版本更新记录'));
        }
        if (index <= _items.length) {
          final item = _items[index - 1];
          return Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text('版本 ${item['versionName']}',
                                  style:
                                      Theme.of(context).textTheme.titleMedium),
                              if (item['buildCode'] == widget.currentBuild)
                                const Chip(label: Text('当前版本')),
                            ]),
                        const SizedBox(height: 8),
                        Text(_date(item['publishedAt'] as int),
                            style: Theme.of(context).textTheme.bodySmall),
                        const SizedBox(height: 12),
                        Text(item['notes'] as String,
                            style: const TextStyle(height: 1.6)),
                      ])));
        }
        return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(children: [
              if (_loading) const CircularProgressIndicator(),
              if (_error != null) ...[
                Text(_error!, textAlign: TextAlign.center),
                TextButton(onPressed: _load, child: const Text('重试'))
              ],
              if (!_loading && _error == null && _loaded)
                if (_next != null)
                  TextButton(onPressed: _load, child: const Text('加载更多'))
                else
                  Text(_items.isEmpty ? '暂无更新历史' : '已显示全部更新记录'),
            ]));
      });
}
