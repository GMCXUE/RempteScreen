import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'account_avatar.dart';
import 'app_theme.dart';
import 'chat_message.dart';
import 'chat_video_viewer.dart';
import 'compact_feedback.dart';
import 'native_service.dart';

const historyFilters = <String, String>{
  'all': '全部',
  'text': '文字',
  'media': '图片与视频',
  'link': '链接',
  'call': '通话'
};
Map<String, dynamic> historyQuery(
        {required String query,
        required String kind,
        DateTime? date,
        String? before}) =>
    {
      'query': query.trim(),
      'kind': kind,
      if (date != null)
        'from':
            DateTime(date.year, date.month, date.day).millisecondsSinceEpoch,
      if (date != null)
        'to': DateTime(date.year, date.month, date.day + 1)
            .millisecondsSinceEpoch,
      if (before != null) 'before': before,
    };
String conversationName(Map<String, dynamic> friend) =>
    '${friend['remark'] ?? ''}'.isNotEmpty ? friend['remark'] : friend['name'];

class ChatInformationScreen extends StatefulWidget {
  const ChatInformationScreen(
      {super.key,
      required this.account,
      required this.friend,
      required this.onCleared});
  final Account account;
  final Map<String, dynamic> friend;
  final ValueChanged<String> onCleared;
  @override
  State<ChatInformationScreen> createState() => _ChatInformationScreenState();
}

class _ChatInformationScreenState extends State<ChatInformationScreen> {
  bool _muted = false, _pinned = false, _busy = false, _ready = false;
  String? _error;
  final _feedback = CompactFeedback();
  @override
  void initState() {
    super.initState();
    _pinned = widget.friend['pinned'] == true;
    _load();
  }

  @override
  void dispose() {
    _feedback.dismiss();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final settings = await NativeMessaging.settings();
      final state = await api.social('state');
      final matches = (state['friends'] as List)
          .cast<Map>()
          .where((f) => f['id'] == widget.friend['id'] && f['blocked'] != true);
      if (matches.isEmpty) throw Exception('好友关系已变化');
      final friend = matches.first;
      if (mounted) {
        setState(() {
          _muted = (settings['mutedPeers'] as List? ?? [])
              .contains(widget.friend['id']);
          _pinned = friend['pinned'] == true;
          _ready = true;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy || !_ready) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) _feedback.show(context, error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _mute(bool value) => _run(() async {
        final settings = await NativeMessaging.settings();
        final peers = Set<String>.from(settings['mutedPeers'] as List? ?? []);
        value
            ? peers.add(widget.friend['id'])
            : peers.remove(widget.friend['id']);
        settings['mutedPeers'] = peers.toList();
        await NativeMessaging.settings(settings);
        if (mounted) setState(() => _muted = value);
      });
  Future<void> _pin(bool value) => _run(() async {
        await api.social('profile',
            {'peerId': widget.friend['id'], 'action': 'pin', 'pinned': value});
        if (mounted) setState(() => _pinned = value);
      });
  Future<void> _clear() => _run(() async {
        final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const Text('清空聊天记录？'),
                  content: const Text(
                      '将清空你与该好友的聊天记录，并同步到你登录的其他设备。对方的记录不受影响，清空后无法恢复。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('取消')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('清空',
                            style: TextStyle(color: AppTheme.danger)))
                  ],
                ));
        if (confirmed != true || !mounted) return;
        final result =
            await api.social('clear-history', {'peerId': widget.friend['id']});
        widget.onCleared(result['clearedThrough']);
        if (mounted) _feedback.show(context, '聊天记录已清空');
      });
  Future<void> _history() async {
    final messageId = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => ChatHistoryScreen(
                account: widget.account, friend: widget.friend)));
    if (mounted && messageId != null) Navigator.pop(context, messageId);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('聊天信息'), centerTitle: true),
        body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 16),
            children: [
              if (!_ready && _error == null) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(children: [
                      Text(_error!,
                          style: const TextStyle(color: AppTheme.muted)),
                      TextButton(onPressed: _load, child: const Text('重试'))
                    ])),
              Material(
                  color: Colors.white,
                  child: ListTile(
                      title: const Text('查找聊天记录'),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.muted),
                      onTap: _history)),
              const SizedBox(height: 12),
              Material(
                  color: Colors.white,
                  child: Column(children: [
                    SwitchListTile(
                        title: const Text('消息免打扰'),
                        value: _muted,
                        onChanged: _ready && !_busy ? _mute : null),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                        title: const Text('置顶聊天'),
                        value: _pinned,
                        onChanged: _ready && !_busy ? _pin : null),
                  ])),
              const SizedBox(height: 12),
              Material(
                  color: Colors.white,
                  child: ListTile(
                      title: const Text('清空聊天记录',
                          style: TextStyle(color: AppTheme.danger)),
                      trailing: const Icon(Icons.chevron_right,
                          color: AppTheme.muted),
                      onTap: _ready && !_busy ? _clear : null)),
            ]),
      );
}

class ChatHistoryScreen extends StatefulWidget {
  const ChatHistoryScreen(
      {super.key, required this.account, required this.friend});
  final Account account;
  final Map<String, dynamic> friend;
  @override
  State<ChatHistoryScreen> createState() => _ChatHistoryScreenState();
}

class _ChatHistoryScreenState extends State<ChatHistoryScreen> {
  final _query = TextEditingController();
  final _scroll = ScrollController();
  final List<Map<String, dynamic>> _rows = [];
  Map<String, dynamic>? _me;
  String _kind = 'all';
  DateTime? _date;
  Timer? _debounce;
  int _generation = 0;
  bool _loading = false, _more = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
    _loadMe();
  }

  Future<void> _loadMe() async {
    try {
      final state = await api.social('state');
      if (mounted) setState(() => _me = Map<String, dynamic>.from(state['me']));
    } catch (_) {}
  }

  @override
  void dispose() {
    _generation++;
    _debounce?.cancel();
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (more && _loading) return;
    final version = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      if (!more) {
        _rows.clear();
        _more = false;
      }
    });
    try {
      final result = await api.social('history', {
        'peerId': widget.friend['id'],
        ...historyQuery(
            query: _query.text,
            kind: _kind,
            date: _date,
            before: more && _rows.isNotEmpty ? _rows.last['seq'] : null)
      });
      if (!mounted || version != _generation) return;
      setState(() {
        _rows.addAll((result['messages'] as List)
            .map((row) => Map<String, dynamic>.from(row)));
        _more = result['hasMore'] == true;
      });
      if (!more && _scroll.hasClients) _scroll.jumpTo(0);
    } catch (error) {
      if (mounted && version == _generation) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted && version == _generation) setState(() => _loading = false);
    }
  }

  Future<void> _pickDate() async {
    final date = await showDatePicker(
        context: context,
        initialDate: _date ?? DateTime.now(),
        firstDate: DateTime(2000),
        lastDate: DateTime.now());
    if (date != null && mounted) {
      setState(() => _date = date);
      _load();
    }
  }

  void _preview(Map<String, dynamic> message) => Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => message['kind'] == 'video'
              ? ChatVideoViewer(
                  validate: () async {
                    await api.social('message-video', {
                      'peerId': widget.friend['id'],
                      'messageId': message['id']
                    });
                  },
                  load: () =>
                      api.downloadChatVideo(widget.friend['id'], message['id']))
              : ChatImageViewer(
                  thumbnail: chatImageBytes(message['image']?['thumbnail']),
                  load: () async {
                    final result = await api.social('message-image', {
                      'peerId': widget.friend['id'],
                      'messageId': message['id']
                    });
                    return chatImageBytes(result['image'])!;
                  },
                )));
  String _time(dynamic value) {
    final date = DateTime.fromMillisecondsSinceEpoch(int.parse('$value'));
    String two(int n) => '$n'.padLeft(2, '0');
    return '${date.year}/${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  Widget _row(Map<String, dynamic> message) {
    final mine = message['senderId'] == widget.account.id;
    final person = mine
        ? (_me ??
            {
              'id': widget.account.id,
              'name': widget.account.name,
              'avatarId': widget.account.avatarId,
              'avatarRevision': widget.account.avatarRevision
            })
        : widget.friend;
    final video = message['kind'] == 'video';
    final image = message['kind'] == 'image' || video,
        bytes = image
            ? chatImageBytes(message[video ? 'video' : 'image']?['thumbnail'])
            : null;
    return Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AccountAvatar(
              accountId: person['id'],
              avatarId: person['avatarId'],
              revision: person['avatarRevision'] ?? '',
              size: 36),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(children: [
                  Expanded(
                      child: Text(conversationName(person),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.muted))),
                  Text(_time(message['createdAt']),
                      style:
                          const TextStyle(fontSize: 11, color: AppTheme.muted))
                ]),
                const SizedBox(height: 8),
                if (image)
                  InkWell(
                      onTap: () => _preview(message),
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Stack(alignment: Alignment.center, children: [
                            bytes == null
                                ? Text(video ? '[视频]' : '[图片]')
                                : Image.memory(bytes,
                                    width: 140,
                                    height: 100,
                                    fit: BoxFit.contain),
                            if (video)
                              const Icon(Icons.play_circle_fill_rounded,
                                  color: Colors.white, size: 40)
                          ])))
                else
                  Text(message['text'] ?? '',
                      style: const TextStyle(fontSize: 14, height: 1.5)),
                Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                        onPressed: () =>
                            Navigator.pop(context, '${message['id']}'),
                        child: const Text('定位到聊天位置',
                            style: TextStyle(fontSize: 12))))
              ]))
        ]));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.white,
        appBar:
            AppBar(title: const Text('聊天记录'), backgroundColor: Colors.white),
        body: Column(children: [
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                  controller: _query,
                  textInputAction: TextInputAction.search,
                  maxLength: 200,
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索聊天内容',
                      counterText: '',
                      isDense: true),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce =
                        Timer(const Duration(milliseconds: 280), () => _load());
                  },
                  onSubmitted: (_) {
                    _debounce?.cancel();
                    _load();
                  })),
          SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                  children: historyFilters.entries
                      .map((filter) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                              label: Text(filter.value),
                              selected: _kind == filter.key,
                              onSelected: (_) {
                                setState(() => _kind = filter.key);
                                _load();
                              })))
                      .toList())),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                TextButton.icon(
                    onPressed: _pickDate,
                    icon: const Icon(Icons.calendar_today_outlined, size: 16),
                    label: Text(_date == null
                        ? '日期'
                        : '${_date!.year}/${_date!.month}/${_date!.day}')),
                const Spacer(),
                TextButton(
                    onPressed: () {
                      _query.clear();
                      setState(() {
                        _date = null;
                        _kind = 'all';
                      });
                      _load();
                    },
                    child: const Text('清除筛选'))
              ])),
          const Divider(height: 1),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                      child: Text(_error!,
                          style: const TextStyle(color: AppTheme.danger))),
                  TextButton(
                      onPressed: () => _load(more: _rows.isNotEmpty),
                      child: const Text('重试'))
                ])),
          Expanded(
              child: !_loading && _rows.isEmpty && _error == null
                  ? const Center(
                      child: Text('没有找到聊天记录',
                          style: TextStyle(color: AppTheme.muted)))
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _rows.length + (_more ? 1 : 0),
                      itemBuilder: (_, index) => index == _rows.length
                          ? TextButton(
                              onPressed:
                                  _loading ? null : () => _load(more: true),
                              child: const Text('加载更多'))
                          : _row(_rows[index]))),
        ]),
      );
}
