import 'account_profile.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'chat_message.dart';
import 'chat_media.dart';
import 'chat_video_viewer.dart';
import 'chat_outbox.dart';
import 'chat_history_screen.dart';
import 'compact_feedback.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'account_avatar.dart';
import 'app_theme.dart';
import 'friend_calls.dart';
import 'native_service.dart';

/// Account-owned contacts; durable state is shared with the desktop client.
class SocialScreen extends StatefulWidget {
  const SocialScreen(
      {super.key,
      required this.account,
      this.onUnreadChanged,
      this.initialFriendsTab = false});
  final Account account;
  final ValueChanged<int>? onUnreadChanged;
  final bool initialFriendsTab;
  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  Map<String, dynamic>? _data;
  String? _error;
  final _syncFeedback = SyncErrorFeedback();
  final _actionFeedback = CompactFeedback();
  Timer? _timer;
  bool _loading = false;
  bool _mutating = false;
  bool _friendsTab = false;
  Set<String> _mutedPeers = {};
  Future<void> _loadAlertSettings() async {
    try {
      final value = await NativeMessaging.settings();
      if (mounted) {
        setState(() =>
            _mutedPeers = Set<String>.from(value['mutedPeers'] as List? ?? []));
      }
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _friendsTab = widget.initialFriendsTab;
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _syncFeedback.dismiss();
    _actionFeedback.dismiss();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_loading || !mounted) return;
    _loading = true;
    try {
      final data = await api.social('state');
      if (!mounted) return;
      _syncFeedback.recovered('contacts');
      for (final person in [
        data['me'],
        ...data['friends'] as List,
        ...data['requests'] as List,
        ...data['outgoing'] as List,
        ...data['blocked'] as List
      ]) {
        rememberAvatar(person['id'], person['avatarId'],
            revision: person['avatarRevision'] ?? '');
      }
      if (mounted) {
        setState(() {
          _data = data;
          _error = null;
        });
        final unread = (data['friends'] as List).fold<int>(
                0,
                (sum, friend) =>
                    sum +
                    (friend['blocked'] == true ? 0 : friend['unread'] as int)) +
            (data['requests'] as List).length;
        if (mounted) widget.onUnreadChanged?.call(unread);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
        _syncFeedback.failed(context, 'contacts', error);
      }
    } finally {
      _loading = false;
    }
  }

  void _notice(String text, {bool error = false}) {
    if (mounted) _actionFeedback.show(context, text, error: error);
  }

  Future<void> _action(String op, Map<String, dynamic> body) async {
    if (_mutating || !mounted) return;
    setState(() => _mutating = true);
    try {
      await api.social(op, body);
      await _refresh();
    } catch (error) {
      _notice(error.toString(), error: true);
    } finally {
      if (mounted) setState(() => _mutating = false);
    }
  }

  Future<String?> _input(String title,
      {String initial = '', int max = 100}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(title),
              content: TextField(
                  controller: controller, autofocus: true, maxLength: max),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消')),
                FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, controller.text.trim()),
                    child: const Text('确定'))
              ],
            ));
    // Dialog dismissal animates; do not dispose its controller mid-animation.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    controller.dispose();
    return value;
  }

  Future<void> _addFriend() async {
    final key = await _input('输入账号 ID 或邮箱');
    if (key == null || key.isEmpty || !mounted) return;
    try {
      final result = await api.social('search', {'query': key});
      final users = result['users'] as List;
      if (users.isEmpty) {
        _notice('没有找到该账号');
        return;
      }
      final peer = Map<String, dynamic>.from(users.first);
      if (!mounted) return;
      final note = await _input(
          '添加 ${peer['name']}（${peer['accountId'] ?? '待分配'}）',
          max: 160);
      if (note != null && mounted) {
        await _action('request', {'peerId': peer['id'], 'note': note});
      }
    } catch (error) {
      _notice(error.toString(), error: true);
    }
  }

  Future<void> _manage(Map<String, dynamic> friend, String action) async {
    final id = friend['id'];
    if (action == 'details') {
      await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => FriendProfileScreen(friend: friend)));
      return;
    }
    if (action == 'mute') {
      try {
        final value = await NativeMessaging.settings();
        final muted = Set<String>.from(value['mutedPeers'] as List? ?? []);
        final wasMuted = muted.remove(id);
        if (!wasMuted) muted.add(id);
        value['mutedPeers'] = muted.toList();
        await NativeMessaging.settings(value);
        if (mounted) setState(() => _mutedPeers = muted);
        _notice(wasMuted ? '已关闭好友免打扰' : '已开启好友免打扰，消息保留未读，来电静音');
      } catch (error) {
        _notice(error.toString(), error: true);
      }
      return;
    }
    if (action == 'remark') {
      final remark =
          await _input('好友备注', initial: friend['remark'] ?? '', max: 32);
      if (remark != null) {
        await _action(
            'profile', {'peerId': id, 'action': 'remark', 'remark': remark});
      }
      return;
    }
    if (action == 'remove' || action == 'block') {
      final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                title: Text(action == 'remove' ? '删除好友？' : '拉黑好友？'),
                content: Text(
                    action == 'remove' ? '删除后需要重新申请才能聊天。' : '拉黑后双方不能发送消息。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确定'))
                ],
              ));
      if (accepted != true) return;
    }
    await _action('profile', {
      'peerId': id,
      'action': action == 'unblock' ? 'block' : action,
      if (action == 'block' || action == 'unblock') 'blocked': action == 'block'
    });
  }

  Widget _avatar(Map<String, dynamic> peer, {bool? online}) => AccountAvatar(
      accountId: peer['id'],
      avatarId: peer['avatarId'],
      revision: peer['avatarRevision'] ?? '',
      online: online);

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
              padding: const EdgeInsets.only(bottom: 9, left: 3),
              child: Text(title,
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF8390A5)))),
          Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 74, endIndent: 16),
                  children[i],
                ],
              ])),
        ]),
      );

  Widget _empty(String title, String description) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
        child: Column(children: [
          Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                  color: const Color(0xFFEEF4FF),
                  borderRadius: BorderRadius.circular(16)),
              child: Icon(
                  _friendsTab
                      ? Icons.people_outline_rounded
                      : Icons.chat_bubble_outline_rounded,
                  color: AppTheme.accent,
                  size: 24)),
          const SizedBox(height: 18),
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 7),
          Text(description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 12, height: 1.6, color: Color(0xFF8390A5))),
        ]),
      );

  Widget _friendTile(Map<String, dynamic> friend) {
    final name = (friend['remark'] as String).isEmpty
        ? friend['name']
        : friend['remark'];
    final unread = friend['unread'] as int;
    final blocked = friend['blocked'] == true;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      leading: Badge(
          isLabelVisible: _friendsTab && unread > 0 && !blocked,
          label: Text(unread > 99 ? '99+' : '$unread'),
          child: _avatar(friend, online: friend['online'] == true)),
      title: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
              blocked
                  ? '已拉黑'
                  : !_friendsTab && (friend['lastText'] as String).isNotEmpty
                      ? friend['lastText']
                      : '账号 ID：${friend['accountId'] ?? '待分配'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8390A5)))),
      onTap: blocked
          ? null
          : () async {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => PrivateChatScreen(
                          account: widget.account, friend: friend)));
              _refresh();
            },
      trailing: _friendsTab
          ? PopupMenuButton<String>(
              enabled: !_mutating,
              icon: const Icon(Icons.more_horiz_rounded,
                  size: 21, color: Color(0xFF98A2B3)),
              onOpened: _loadAlertSettings,
              onSelected: (action) => _manage(friend, action),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'details', child: Text('好友资料')),
                const PopupMenuItem(value: 'remark', child: Text('设置备注')),
                PopupMenuItem(
                    value: 'mute',
                    child: Text(_mutedPeers.contains(friend['id'])
                        ? '关闭免打扰'
                        : '开启免打扰')),
                PopupMenuItem(
                    value: blocked ? 'unblock' : 'block',
                    child: Text(blocked ? '解除拉黑' : '拉黑')),
                const PopupMenuItem(value: 'remove', child: Text('删除好友')),
              ],
            )
          : unread > 0 && !blocked
              ? Badge(label: Text(unread > 99 ? '99+' : '$unread'))
              : const Icon(Icons.chevron_right_rounded,
                  size: 18, color: Color(0xFFB2BAC8)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final friends = (_data?['friends'] as List?) ?? [];
    final requests = (_data?['requests'] as List?) ?? [];
    final outgoing = (_data?['outgoing'] as List?) ?? [];
    final blocked = (_data?['blocked'] as List?) ?? [];
    final recent = friends
        .where((friend) =>
            friend['blocked'] != true &&
            (friend['pinned'] == true ||
                (friend['lastText'] as String).isNotEmpty ||
                (friend['unread'] as int) > 0))
        .toList();
    final list = _friendsTab ? friends : recent;
    final messageUnread = friends.fold<int>(
        0,
        (sum, friend) =>
            sum + (friend['blocked'] == true ? 0 : friend['unread'] as int));
    return RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          children: [
            Row(children: [
              for (final entry in [(false, '消息'), (true, '好友')])
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: TextButton(
                      style: TextButton.styleFrom(
                          foregroundColor: _friendsTab == entry.$1
                              ? AppTheme.accent
                              : const Color(0xFF8390A5),
                          backgroundColor: _friendsTab == entry.$1
                              ? const Color(0xFFEEF4FF)
                              : Colors.transparent,
                          minimumSize: const Size(64, 34),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 6),
                          textStyle: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                      onPressed: () => setState(() => _friendsTab = entry.$1),
                      child: Badge(
                          isLabelVisible:
                              (entry.$1 ? requests.length : messageUnread) > 0,
                          label: Text((entry.$1
                                      ? requests.length
                                      : messageUnread) >
                                  99
                              ? '99+'
                              : '${entry.$1 ? requests.length : messageUnread}'),
                          child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Text(entry.$2)))),
                ),
              const Spacer(),
              IconButton(
                  style: IconButton.styleFrom(
                      backgroundColor: const Color(0xFFEEF4FF),
                      minimumSize: const Size(34, 34),
                      padding: const EdgeInsets.all(7),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10))),
                  tooltip: '添加好友',
                  onPressed: _mutating ? null : _addFriend,
                  icon: const Icon(Icons.add_rounded,
                      size: 20, color: AppTheme.accent)),
            ]),
            const SizedBox(height: 10),
            if (_data == null && _error != null)
              Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('消息暂时无法同步',
                    style: TextStyle(color: AppTheme.muted, fontSize: 13)),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ])),
            if (_data == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (!_friendsTab && requests.isNotEmpty) ...[
              Card(
                  child: ListTile(
                      leading: const Icon(Icons.person_add_alt_1_rounded,
                          color: AppTheme.accent),
                      title: const Text('新的好友申请'),
                      subtitle: Text('${requests.length} 位好友等待确认'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => setState(() => _friendsTab = true))),
              const SizedBox(height: 18),
            ],
            if (_friendsTab && requests.isNotEmpty)
              _section(
                  '新的好友 · ${requests.length}',
                  requests.map<Widget>((value) {
                    final peer = Map<String, dynamic>.from(value);
                    return Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(children: [
                          Row(children: [
                            _avatar(peer),
                            const SizedBox(width: 12),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(peer['name'],
                                      style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 5),
                                  Text(
                                      (peer['note'] as String).isEmpty
                                          ? '希望添加你为好友'
                                          : peer['note'],
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF8390A5))),
                                ]))
                          ]),
                          const SizedBox(height: 12),
                          Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton(
                                    onPressed: _mutating
                                        ? null
                                        : () => _action('decision', {
                                              'peerId': peer['id'],
                                              'accept': false
                                            }),
                                    child: const Text('拒绝')),
                                const SizedBox(width: 8),
                                FilledButton(
                                    onPressed: _mutating
                                        ? null
                                        : () => _action('decision', {
                                              'peerId': peer['id'],
                                              'accept': true
                                            }),
                                    style: FilledButton.styleFrom(
                                        minimumSize: const Size(64, 36)),
                                    child: const Text('同意')),
                              ]),
                        ]));
                  }).toList()),
            if (_data != null)
              if (list.isEmpty)
                _empty(_friendsTab ? '还没有好友' : '还没有会话',
                    _friendsTab ? '点击右上角 +，添加你的第一位好友' : '在好友列表选择联系人，即可打开会话')
              else
                _section(
                    _friendsTab ? '全部好友 · ${friends.length}' : '最近会话',
                    list
                        .map<Widget>((friend) =>
                            _friendTile(Map<String, dynamic>.from(friend)))
                        .toList()),
            if (_friendsTab && outgoing.isNotEmpty)
              ExpansionTile(
                  title: const Text('已发送申请', style: TextStyle(fontSize: 13)),
                  subtitle: Text('${outgoing.length} 位等待确认',
                      style: const TextStyle(fontSize: 11)),
                  children: outgoing
                      .map<Widget>((peer) => ListTile(
                          leading: _avatar(peer),
                          title: Text(peer['name']),
                          subtitle: const Text('等待对方确认')))
                      .toList()),
            if (_friendsTab && blocked.isNotEmpty)
              ExpansionTile(
                  title: const Text('黑名单', style: TextStyle(fontSize: 13)),
                  children: blocked
                      .map<Widget>((peer) => ListTile(
                          leading: _avatar(peer),
                          title: Text(peer['name']),
                          trailing: TextButton(
                              onPressed: _mutating
                                  ? null
                                  : () => _manage(
                                      Map<String, dynamic>.from(peer),
                                      'unblock'),
                              child: const Text('解除拉黑'))))
                      .toList()),
          ],
        ));
  }
}

class PrivateChatScreen extends StatefulWidget {
  const PrivateChatScreen(
      {super.key, required this.account, required this.friend});
  final Account account;
  final Map<String, dynamic> friend;
  @override
  State<PrivateChatScreen> createState() => _PrivateChatScreenState();
}

class _PrivateChatScreenState extends State<PrivateChatScreen>
    with WidgetsBindingObserver {
  final _draft = TextEditingController();
  final _draftFocus = FocusNode();
  final List<ChatDraftMedia> _draftImages = [];
  String? _composeError;
  final _scroll = ScrollController();
  int _requestVersion = 0;
  String _clearedThrough = '0';
  String? _highlightMessage;
  final List<Map<String, dynamic>> _messages = [];
  Timer? _timer;
  bool _loading = false, _hasMore = false, _visible = true;
  String? _error;
  late final ChatSendQueue _outbox;
  final _seenConfirmed = <String>{};
  bool _keepAtBottom = true, _bottomScheduled = false;
  String? _readSeq, _syncCursor;
  int _clockOffset = 0;
  bool _picking = false;
  bool _moreOpen = false;
  MaterialPageRoute<void>? _imageRoute;
  String? _imageMessageId;
  final _copyFeedback = CompactFeedback();
  final _syncFeedback = SyncErrorFeedback();
  bool _copyingImage = false;
  DialogRoute<void>? _selectionRoute;
  String? _selectionMessageId;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _outbox = chatOutbox.queue(
        widget.account.id, widget.friend['id'], api.captureChatSender);
    _seenConfirmed.addAll(_outbox.confirmed.map((row) => row['id'] as String));
    _outbox.addListener(_outboxChanged);
    _draftFocus.addListener(() {
      if (mounted && _draftFocus.hasFocus) {
        if (_moreOpen) setState(() => _moreOpen = false);
        _scrollToBottom(force: true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _load());
  }

  @override
  void dispose() {
    _outbox.removeListener(_outboxChanged);
    _copyFeedback.dismiss();
    _syncFeedback.dismiss();
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (NativeMessaging.visiblePeer == widget.friend['id']) {
      unawaited(NativeMessaging.setVisiblePeer(null).catchError((_) {}));
    }
    _draftFocus.dispose();
    _draft.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = state == AppLifecycleState.resumed;
    if (!_visible) {
      unawaited(NativeMessaging.setVisiblePeer(null).catchError((_) {}));
    }
    if (_visible) _load();
  }

  void _scrollToBottom({bool force = false}) {
    if (force) _keepAtBottom = true;
    if (!_keepAtBottom || _bottomScheduled || _highlightMessage != null) return;
    _bottomScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomScheduled = false;
      if (mounted &&
          _keepAtBottom &&
          _scroll.hasClients &&
          _highlightMessage == null) {
        if ((_scroll.position.maxScrollExtent - _scroll.offset).abs() > .5) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      }
    });
  }

  @override
  void didChangeMetrics() {
    if (_draftFocus.hasFocus && _keepAtBottom) _scrollToBottom();
  }

  void _outboxChanged() {
    if (!mounted) return;
    setState(() {
      for (final row in _outbox.confirmed) {
        if (!_seenConfirmed.add(row['id'])) continue;
        if (BigInt.parse(row['seq']) <= BigInt.parse(_clearedThrough)) continue;
        if (!_messages.any((old) => old['id'] == row['id'])) {
          _messages.add(Map<String, dynamic>.from(row));
        }
      }
      _messages.sort(
          (a, b) => BigInt.parse(a['seq']).compareTo(BigInt.parse(b['seq'])));
    });
    _scrollToBottom();
  }

  bool _scrollNotice(ScrollNotification notice) {
    if (notice.depth != 0) return false;
    if (notice is ScrollStartNotification && notice.dragDetails != null) {
      _keepAtBottom = false;
    }
    if (notice is ScrollEndNotification) {
      _keepAtBottom = notice.metrics.extentAfter < 80;
    }
    return false;
  }

  Future<void> _load({bool older = false}) async {
    if (!mounted) return;
    unawaited(NativeMessaging.setVisiblePeer(
            _visible && ModalRoute.of(context)?.isCurrent == true
                ? widget.friend['id']
                : null)
        .catchError((_) {}));
    if (_loading || !_visible) return;
    if (older) _keepAtBottom = false;
    _loading = true;
    final requestVersion = ++_requestVersion;
    try {
      final result = await api.social('messages', {
        'peerId': widget.friend['id'],
        if (_syncCursor != null) 'syncCursor': _syncCursor,
        if (_messages.isNotEmpty) 'loadedFrom': _messages.first['seq'],
        if (_messages.isNotEmpty)
          (older ? 'before' : 'after'):
              older ? _messages.first['seq'] : _messages.last['seq']
      });
      if (!mounted || requestVersion != _requestVersion) return;
      final boundary = '${result['clearedThrough'] ?? '0'}';
      if (BigInt.parse(boundary) > BigInt.parse(_clearedThrough)) {
        _applyClear(boundary);
      }
      final initial = _messages.isEmpty;
      _syncFeedback.recovered('messages');
      final rows = (result['messages'] as List)
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      final bottom = !_scroll.hasClients || _scroll.position.extentAfter < 80;
      final previousHeight =
          _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
      final previousOffset = _scroll.hasClients ? _scroll.offset : 0.0;
      final known = _messages.map((m) => m['id']).toSet();
      final fresh = rows.where((m) => !known.contains(m['id'])).toList();
      setState(() {
        final updates = (result['updates'] as List? ?? const [])
            .map((row) => Map<String, dynamic>.from(row));
        for (final message in [...rows, ...updates]) {
          final index =
              _messages.indexWhere((old) => old['id'] == message['id']);
          if (index >= 0) {
            if (_messages[index]['kind'] != 'recalled' ||
                message['kind'] == 'recalled') {
              _messages[index] = message;
            }
          } else if (rows.any((row) => row['id'] == message['id'])) {
            _messages.add(message);
          }
          if (message['kind'] == 'recalled' &&
              message['id'] == _imageMessageId &&
              _imageRoute != null) {
            Navigator.of(context).removeRoute(_imageRoute!);
            _imageRoute = null;
            _imageMessageId = null;
          }
          if (message['kind'] == 'recalled' &&
              message['id'] == _selectionMessageId &&
              _selectionRoute != null) {
            Navigator.of(context).removeRoute(_selectionRoute!);
            _selectionRoute = null;
            _selectionMessageId = null;
          }
        }
        _syncCursor = result['syncCursor'] as String? ?? _syncCursor;
        if (result['serverNow'] != null) {
          _clockOffset = int.parse(result['serverNow']) -
              DateTime.now().millisecondsSinceEpoch;
        }
        _messages.sort(
            (a, b) => BigInt.parse(a['seq']).compareTo(BigInt.parse(b['seq'])));
        if (older || initial) {
          _hasMore = result['hasMore'] == true;
        }
        _error = null;
      });
      if (older) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo((previousOffset +
                    _scroll.position.maxScrollExtent -
                    previousHeight)
                .clamp(0.0, _scroll.position.maxScrollExtent));
          }
        });
      }
      _outbox.reconcile(_messages);
      if (!older &&
          (initial || bottom) &&
          (initial || fresh.isNotEmpty) &&
          _highlightMessage == null) {
        _scrollToBottom(force: true);
      }
      final last = _messages.isEmpty ? null : _messages.last;
      if (!older &&
          last != null &&
          _visible &&
          ModalRoute.of(context)?.isCurrent == true &&
          last['seq'] != _readSeq) {
        try {
          await api.social(
              'read', {'peerId': widget.friend['id'], 'seq': last['seq']});
          if (mounted) {
            _readSeq = last['seq'];
            _syncFeedback.recovered('read');
          }
        } catch (error) {
          if (mounted) _syncFeedback.failed(context, 'read', error);
        }
      }
    } catch (error) {
      if (mounted && requestVersion == _requestVersion) {
        setState(() => _error = error.toString());
        _syncFeedback.failed(context, 'messages', error);
      }
    } finally {
      if (requestVersion == _requestVersion) _loading = false;
    }
  }

  Future<void> _send() async {
    final text = _draft.text.trim();
    if (_picking || (text.isEmpty && _draftImages.isEmpty)) return;
    final batch = [
      for (final image in _draftImages)
        OutgoingChatMessage(
            id: image.id,
            kind: image.kind,
            image: image.kind == 'image' ? image.source : null,
            bytes: image.bytes,
            videoPath: image.path,
            videoName: image.name,
            videoSize: image.sizeBytes),
      if (text.isNotEmpty)
        OutgoingChatMessage(
            id: 'm_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}',
            kind: 'text',
            text: text),
    ];
    try {
      _outbox.enqueue(batch);
      setState(() {
        _highlightMessage = null;
        _draftImages.clear();
        _draft.clear();
        _composeError = null;
        _moreOpen = false;
      });
      _scrollToBottom(force: true);
    } catch (error) {
      setState(() =>
          _composeError = error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  void _notice(String text) {
    if (mounted) _copyFeedback.show(context, text, error: true);
  }

  Future<void> _messageActions(Map<String, dynamic> message) async {
    final current = _messages.firstWhere((m) => m['id'] == message['id'],
        orElse: () => message);
    if (current['kind'] == 'recalled') return;
    final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (current['kind'] == 'image') ...[
                ListTile(
                    leading: const Icon(Icons.open_in_full),
                    title: const Text('查看图片'),
                    onTap: () => Navigator.pop(context, 'image')),
                ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('复制图片'),
                    onTap: () => Navigator.pop(context, 'copy-image')),
              ] else if (current['kind'] == 'video') ...[
                ListTile(
                    leading: const Icon(Icons.play_circle_outline_rounded),
                    title: const Text('播放视频'),
                    onTap: () => Navigator.pop(context, 'image'))
              ] else ...[
                ListTile(
                    leading: const Icon(Icons.copy_outlined),
                    title: const Text('复制'),
                    onTap: () => Navigator.pop(context, 'copy')),
                ListTile(
                    leading: const Icon(Icons.text_fields),
                    title: const Text('选择文字'),
                    onTap: () => Navigator.pop(context, 'select')),
              ],
              if (canRecallMessage(current, widget.account.id,
                  now: DateTime.fromMillisecondsSinceEpoch(
                      DateTime.now().millisecondsSinceEpoch + _clockOffset)))
                ListTile(
                    leading: const Icon(Icons.undo_rounded),
                    title: const Text('撤回'),
                    onTap: () => Navigator.pop(context, 'recall')),
            ])));
    if (!mounted ||
        action == null ||
        _messages
            .any((m) => m['id'] == message['id'] && m['kind'] == 'recalled')) {
      return;
    }
    if (action == 'image') {
      await _openImage(message);
      return;
    }
    if (action == 'copy-image') {
      await _copyImage(message);
      return;
    }
    if (action == 'copy') {
      await _copyMessage(message['text']);
      return;
    }
    if (action == 'select') {
      final route = DialogRoute<void>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const Text('选择文字'),
                  content: SingleChildScrollView(
                      child: SelectableText(message['text'])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('关闭')),
                    TextButton(
                        onPressed: () => _copyMessage(message['text']),
                        child: const Text('复制全部'))
                  ]));
      _selectionRoute = route;
      _selectionMessageId = message['id'];
      await Navigator.of(context).push(route);
      if (_selectionRoute == route) {
        _selectionRoute = null;
        _selectionMessageId = null;
      }
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('撤回消息？'),
                content: const Text('撤回后，对方将无法在聊天中查看这条消息。'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('撤回'))
                ]));
    if (confirmed != true || !mounted) return;
    try {
      final response = await api.social('recall',
          {'peerId': widget.friend['id'], 'messageId': message['id']});
      if (!mounted) return;
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == message['id']);
        if (index >= 0) {
          _messages[index] = Map<String, dynamic>.from(response['message']);
        }
        _error = null;
      });
      await _load();
    } catch (error) {
      _notice(error.toString());
    }
  }

  Future<void> _copyMessage(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      await _copied('已复制');
    } catch (_) {
      if (mounted) _copyFeedback.show(context, '复制失败，请重试', error: true);
    }
  }

  Future<void> _copied(String text) async {
    // Android 13+ already confirms the copy; avoid a second bottom banner.
    final systemFeedback = await NativeChatClipboard.hasSystemFeedback();
    if (!mounted) return;
    _copyFeedback.dismiss();
    if (!systemFeedback) _copyFeedback.show(context, text);
  }

  Future<void> _copyImage(Map<String, dynamic> message) async {
    if (_copyingImage) return;
    _copyingImage = true;
    try {
      final response = await api.social('message-image',
          {'peerId': widget.friend['id'], 'messageId': message['id']});
      if (!mounted) return;
      if (_messages
          .any((m) => m['id'] == message['id'] && m['kind'] == 'recalled')) {
        throw ApiException('image_recalled', '图片已撤回');
      }
      final bytes = chatImageBytes(response['image']);
      if (bytes == null) throw ApiException('invalid_image', '无法读取图片');
      await NativeChatClipboard.copyImage(bytes);
      await _copied('图片已复制');
    } catch (error) {
      if (mounted) {
        final text = error is ApiException
            ? error.message
            : error is PlatformException
                ? error.message ?? '复制失败，请重试'
                : '复制失败，请重试';
        _copyFeedback.show(context, text, error: true);
      }
    } finally {
      _copyingImage = false;
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_picking) return;
    _draftFocus.unfocus();
    setState(() => _moreOpen = false);
    await _prepareMedia(
        () => pickChatMedia(limit: 9 - _draftImages.length, source: source));
  }

  void _toggleMore() {
    if (_picking) return;
    _draftFocus.unfocus();
    setState(() => _moreOpen = !_moreOpen);
  }

  Future<void> _prepareMedia(
      Future<List<ChatPickedMedia>> Function() read) async {
    if (_picking) return;
    if (_draftImages.length >= 9) {
      _copyFeedback.show(context, '最多添加 9 项图片或视频', error: true);
      return;
    }
    final peerId = widget.friend['id'], accountId = widget.account.id;
    setState(() => _picking = true);
    try {
      final selected = await read();
      if (!mounted ||
          widget.friend['id'] != peerId ||
          widget.account.id != accountId ||
          selected.isEmpty) {
        return;
      }
      if (selected.length + _draftImages.length > 9) {
        throw Exception('最多添加 9 项图片或视频');
      }
      setState(() {
        for (final media in selected) {
          _draftImages.add(ChatDraftMedia(
              id: 'media_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 32)}',
              kind: media.kind,
              source: media.source,
              bytes: media.bytes,
              path: media.path,
              name: media.name,
              sizeBytes: media.sizeBytes));
        }
        _composeError = null;
      });
      _draftFocus.requestFocus();
    } catch (error) {
      if (mounted) {
        final text = error is PlatformException
            ? ['camera_access_denied', 'camera_access_restricted']
                    .contains(error.code)
                ? '请允许 RemoteScreen 使用摄像头后重试'
                : error.message ?? '无法打开相机或图库，请检查权限后重试'
            : error.toString().replaceFirst('Exception: ', '');
        _copyFeedback.show(context, text, error: true);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _openImage(Map<String, dynamic> message) async {
    if (message['kind'] == 'recalled' || _imageRoute != null) return;
    _imageMessageId = message['id'];
    final route = MaterialPageRoute<void>(
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
                onCopy: () => _copyImage(message),
                load: () async {
                  final response = await api.social('message-image', {
                    'peerId': widget.friend['id'],
                    'messageId': message['id']
                  });
                  return chatImageBytes(response['image'])!;
                }));
    _imageRoute = route;
    await Navigator.of(context).push(route);
    if (_imageRoute == route) {
      _imageRoute = null;
      _imageMessageId = null;
    }
  }

  void _applyClear(String boundary) {
    _clearedThrough = boundary;
    if (_imageRoute != null) {
      Navigator.of(context).removeRoute(_imageRoute!);
      _imageRoute = null;
      _imageMessageId = null;
    }
    if (_selectionRoute != null) {
      Navigator.of(context).removeRoute(_selectionRoute!);
      _selectionRoute = null;
      _selectionMessageId = null;
    }
    setState(() {
      _outbox.clearCompleted();
      _messages
          .removeWhere((m) => BigInt.parse(m['seq']) <= BigInt.parse(boundary));
      _hasMore = false;
      _highlightMessage = null;
    });
  }

  Future<void> _chatInformation() async {
    final id = await Navigator.push<String>(
        context,
        MaterialPageRoute(
            builder: (_) => ChatInformationScreen(
                  account: widget.account,
                  friend: widget.friend,
                  onCleared: (boundary) {
                    if (!mounted) return;
                    ++_requestVersion;
                    _loading = false;
                    _syncCursor = null;
                    _readSeq = null;
                    _outbox.discardFailures();
                    _applyClear(boundary);
                  },
                )));
    if (!mounted) return;
    if (id != null) {
      await _locateMessage(id);
    } else {
      await _load();
    }
  }

  Future<void> _locateMessage(String id) async {
    if (_outbox.running) return;
    final version = ++_requestVersion;
    _keepAtBottom = false;
    _loading = true;
    try {
      final data = await api.social(
          'message-context', {'peerId': widget.friend['id'], 'messageId': id});
      if (!mounted || version != _requestVersion) return;
      final rows = (data['messages'] as List)
          .map((m) => Map<String, dynamic>.from(m))
          .toList();
      final index = rows.indexWhere((m) => m['id'] == id);
      if (index < 0) throw Exception('消息已清空或不存在');
      // Start at the selected message so variable-height image bubbles are also
      // visible immediately. Earlier context remains available through paging.
      setState(() {
        _messages
          ..clear()
          ..addAll(rows.skip(index));
        _hasMore = data['hasMore'] == true || index > 0;
        _syncCursor = data['syncCursor'];
        _clearedThrough = data['clearedThrough'];
        _highlightMessage = id;
        _error = null;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (mounted && _highlightMessage == id) {
          setState(() => _highlightMessage = null);
        }
      });
    } catch (error) {
      if (mounted && version == _requestVersion) {
        _copyFeedback.show(context, error.toString(), error: true);
      }
    } finally {
      if (version == _requestVersion) _loading = false;
    }
  }

  String _timeLabel(String value) {
    final date = DateTime.fromMillisecondsSinceEpoch(int.parse(value));
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(date.month)}/${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final display = [
      ..._messages,
      ..._outbox.items.map((item) => item.record(widget.account.id))
    ];
    return PopScope(
        canPop: !_moreOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && _moreOpen) setState(() => _moreOpen = false);
        },
        child: Scaffold(
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
              backgroundColor: Colors.white,
              titleTextStyle: const TextStyle(
                  color: AppTheme.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600),
              iconTheme: const IconThemeData(color: AppTheme.muted, size: 22),
              shape: const Border(bottom: BorderSide(color: AppTheme.line)),
              title: Row(children: [
                AccountAvatar(
                    accountId: widget.friend['id'],
                    avatarId: widget.friend['avatarId'],
                    revision: widget.friend['avatarRevision'] ?? '',
                    size: 32),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(
                        (widget.friend['remark'] as String).isEmpty
                            ? widget.friend['name']
                            : widget.friend['remark'],
                        overflow: TextOverflow.ellipsis))
              ]),
              actions: [
                IconButton(
                    tooltip: '语音通话',
                    icon: const Icon(Icons.call_outlined),
                    onPressed: () => friendCalls.start(widget.friend, 'voice')),
                IconButton(
                    tooltip: '视频通话',
                    icon: const Icon(Icons.videocam_outlined),
                    onPressed: () => friendCalls.start(widget.friend, 'video')),
                IconButton(
                    tooltip: '聊天信息',
                    icon: const Icon(Icons.more_horiz_rounded),
                    onPressed: _outbox.running ? null : _chatInformation),
              ]),
          body: Column(children: [
            Expanded(
                child: NotificationListener<ScrollNotification>(
                    onNotification: _scrollNotice,
                    child: NotificationListener<ScrollMetricsNotification>(
                        onNotification: (_) {
                          _scrollToBottom();
                          return false;
                        },
                        child: ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(16),
                            itemCount: display.length + 1,
                            itemBuilder: (context, index) {
                              if (index == 0) {
                                if (_messages.isEmpty && _error != null) {
                                  return Center(
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                        const Text('消息暂时无法同步',
                                            style: TextStyle(
                                                color: AppTheme.muted,
                                                fontSize: 13)),
                                        TextButton(
                                            onPressed: () => _load(),
                                            child: const Text('重试')),
                                      ]));
                                }
                                return _hasMore
                                    ? TextButton(
                                        onPressed: _loading
                                            ? null
                                            : () => _load(older: true),
                                        child: const Text('加载更早的消息'))
                                    : _messages.isEmpty
                                        ? const Padding(
                                            padding: EdgeInsets.symmetric(
                                                vertical: 48),
                                            child: Center(
                                                child: Text('发送一条消息，开始聊天',
                                                    style: TextStyle(
                                                        fontSize: 12,
                                                        color: Color(
                                                            0xFF98A2B3)))),
                                          )
                                        : const SizedBox(height: 8);
                              }
                              final message = display[index - 1];
                              final mine =
                                  message['senderId'] == widget.account.id;
                              final bubble = ChatMessageBubble(
                                  message: message,
                                  mine: mine,
                                  timeLabel: _timeLabel(message['createdAt']),
                                  onActions: () {
                                    if (message['localStatus'] == null) {
                                      _messageActions(message);
                                    }
                                  },
                                  onRetry: () =>
                                      _outbox.retry(message['clientId']),
                                  onOpenImage: () {
                                    if (message['localStatus'] == null) {
                                      _openImage(message);
                                    }
                                  });
                              if (message['kind'] == 'recalled') return bubble;
                              final person = mine
                                  ? {
                                      'id': widget.account.id,
                                      'avatarId': widget.account.avatarId,
                                      'avatarRevision':
                                          widget.account.avatarRevision
                                    }
                                  : widget.friend;
                              final avatar = AccountAvatar(
                                  accountId: person['id'],
                                  avatarId: person['avatarId'],
                                  revision: person['avatarRevision'] ?? '',
                                  size: 32);
                              return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                      color: _highlightMessage == message['id']
                                          ? const Color(0xFFE3EEFF)
                                          : null,
                                      borderRadius: BorderRadius.circular(12)),
                                  child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment: mine
                                          ? MainAxisAlignment.end
                                          : MainAxisAlignment.start,
                                      children: [
                                        if (!mine) ...[
                                          avatar,
                                          const SizedBox(width: 8)
                                        ],
                                        Flexible(child: bubble),
                                        if (mine) ...[
                                          const SizedBox(width: 8),
                                          avatar
                                        ]
                                      ]));
                            })))),
            DecoratedBox(
              decoration: const BoxDecoration(
                  color: Color(0xFFF7F9FC),
                  border: Border(top: BorderSide(color: AppTheme.line))),
              child: SafeArea(
                  top: false,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
                        child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                  child: Container(
                                      key:
                                          const ValueKey('chat-composer-input'),
                                      decoration: BoxDecoration(
                                          color: const Color(0xFFF7F9FC),
                                          border: Border.all(
                                              color: const Color(0xFFE4E9F2)),
                                          borderRadius:
                                              BorderRadius.circular(12)),
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (_draftImages.isNotEmpty)
                                              SizedBox(
                                                  height: 86,
                                                  child: ListView.separated(
                                                      key: const ValueKey(
                                                          'chat-draft-images'),
                                                      scrollDirection:
                                                          Axis.horizontal,
                                                      padding: const EdgeInsets
                                                          .fromLTRB(
                                                          10, 10, 10, 0),
                                                      itemCount:
                                                          _draftImages.length,
                                                      separatorBuilder:
                                                          (_, __) =>
                                                              const SizedBox(
                                                                  width: 8),
                                                      itemBuilder:
                                                          (context, index) {
                                                        final image =
                                                            _draftImages[index];
                                                        return SizedBox(
                                                            width: 76,
                                                            height: 76,
                                                            child: Stack(
                                                                children: [
                                                                  Positioned.fill(
                                                                      child: ClipRRect(
                                                                          borderRadius: BorderRadius.circular(
                                                                              8),
                                                                          child: ColoredBox(
                                                                              color: const Color(0xFFEEF2F7),
                                                                              child: image.kind == 'video' ? const Center(child: Icon(Icons.play_circle_outline_rounded, size: 34)) : Image.memory(image.bytes!, fit: BoxFit.contain, cacheWidth: 152, semanticLabel: '待发送图片 ${index + 1}')))),
                                                                  Positioned(
                                                                      top: 0,
                                                                      right: 0,
                                                                      child: IconButton(
                                                                          tooltip: '移除${image.kind == 'video' ? '视频' : '图片'} ${index + 1}',
                                                                          onPressed: _picking
                                                                              ? null
                                                                              : () {
                                                                                  setState(() {
                                                                                    _draftImages.remove(image);
                                                                                    _composeError = null;
                                                                                  });
                                                                                  _draftFocus.requestFocus();
                                                                                },
                                                                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                                                          padding: const EdgeInsets.all(5),
                                                                          icon: const DecoratedBox(decoration: BoxDecoration(color: Color(0xD9253047), shape: BoxShape.circle), child: Icon(Icons.close_rounded, color: Colors.white, size: 20))))
                                                                ]));
                                                      })),
                                            TextField(
                                                controller: _draft,
                                                focusNode: _draftFocus,
                                                onChanged: (_) => setState(() {
                                                      _composeError = null;
                                                      if (_draft
                                                          .text.isNotEmpty) {
                                                        _moreOpen = false;
                                                      }
                                                    }),
                                                maxLength: 2000,
                                                minLines: 1,
                                                maxLines: 4,
                                                decoration:
                                                    const InputDecoration(
                                                        hintText: '发送消息',
                                                        counterText: '',
                                                        filled: false,
                                                        border:
                                                            InputBorder.none,
                                                        enabledBorder:
                                                            InputBorder.none,
                                                        focusedBorder:
                                                            InputBorder.none,
                                                        contentPadding:
                                                            EdgeInsets.symmetric(
                                                                horizontal: 12,
                                                                vertical: 10))),
                                            if (_composeError != null)
                                              Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                          12, 0, 12, 8),
                                                  child: Text(_composeError!,
                                                      style: const TextStyle(
                                                          color: Colors.red,
                                                          fontSize: 12)))
                                          ]))),
                              if (_draft.text.isNotEmpty ||
                                  _draftImages.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                FilledButton(
                                    onPressed: _picking ||
                                            (_draft.text.trim().isEmpty &&
                                                _draftImages.isEmpty)
                                        ? null
                                        : _send,
                                    child: const Text('发送')),
                              ],
                              if (_draft.text.isEmpty) ...[
                                const SizedBox(width: 4),
                                IconButton(
                                    key: const ValueKey('chat-more-button'),
                                    tooltip: _moreOpen ? '收起功能' : '更多功能',
                                    onPressed: _picking ? null : _toggleMore,
                                    icon: AnimatedRotation(
                                        turns: _moreOpen ? .125 : 0,
                                        duration:
                                            const Duration(milliseconds: 160),
                                        child: Container(
                                            width: 27,
                                            height: 27,
                                            decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                    color: AppTheme.muted,
                                                    width: 1.7)),
                                            child: const Icon(Icons.add_rounded,
                                                size: 21)))),
                              ],
                            ])),
                    if (_moreOpen)
                      _ChatAttachmentPanel(
                          onGallery: () => _pickImage(ImageSource.gallery),
                          onCamera: () => _pickImage(ImageSource.camera)),
                  ])),
            ),
          ]),
        ));
  }
}

class _ChatAttachmentPanel extends StatelessWidget {
  const _ChatAttachmentPanel({required this.onGallery, required this.onCamera});
  final VoidCallback onGallery, onCamera;
  @override
  Widget build(BuildContext context) => Container(
      key: const ValueKey('chat-attachment-panel'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppTheme.line))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
            child: _ChatAttachmentAction(
                label: '图片与视频',
                icon: const Icon(Icons.image_outlined,
                    size: 27, color: AppTheme.text),
                onTap: onGallery)),
        Expanded(
            child: _ChatAttachmentAction(
                label: '拍照',
                icon: const SizedBox(
                    width: 27,
                    height: 27,
                    child: CustomPaint(painter: _ChatCameraPainter())),
                onTap: onCamera)),
        const Spacer(flex: 2),
      ]));
}

class _ChatAttachmentAction extends StatelessWidget {
  const _ChatAttachmentAction(
      {required this.label, required this.icon, required this.onTap});
  final String label;
  final Widget icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
      button: true,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFE8ECF2))),
                    child: Center(child: icon)),
                const SizedBox(height: 8),
                Text(label,
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.muted)),
              ]))));
}

// Code-drawn camera icon avoids requiring new font assets in a later Dart-only patch.
class _ChatCameraPainter extends CustomPainter {
  const _ChatCameraPainter();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = AppTheme.text
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7
      ..strokeJoin = StrokeJoin.round;
    final body = Path()
      ..moveTo(5, 7)
      ..lineTo(8, 7)
      ..lineTo(10, 4)
      ..lineTo(16, 4)
      ..lineTo(18, 7)
      ..lineTo(20, 7)
      ..quadraticBezierTo(22, 7, 22, 9)
      ..lineTo(22, 19)
      ..quadraticBezierTo(22, 21, 20, 21)
      ..lineTo(4, 21)
      ..quadraticBezierTo(2, 21, 2, 19)
      ..lineTo(2, 9)
      ..quadraticBezierTo(2, 7, 5, 7)
      ..close();
    canvas.drawPath(body, stroke);
    canvas.drawCircle(const Offset(12, 13.5), 3.5, stroke);
  }

  @override
  bool shouldRepaint(covariant _ChatCameraPainter oldDelegate) => false;
}

Future<void> showMessageAlertSettings(BuildContext context) async {
  void notice(Object error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(error.toString()),
          duration: const Duration(seconds: 2)));
    }
  }

  try {
    final value = await NativeMessaging.settings();
    var diagnostics = await NativeMessaging.diagnostics();
    String status() =>
        '系统通知：${diagnostics['notifications'] == true ? '已允许' : '未允许'}；消息服务：${diagnostics['running'] == true ? '运行中' : '已停止'}\n手机模式：${diagnostics['ringerMode'] == 1 ? '振动（不播放声音）' : diagnostics['ringerMode'] == 0 ? '静音' : '声音'}${diagnostics['dnd'] == true ? '；勿扰已开启' : ''}\n消息频道：${(diagnostics['messageAlerts'] as num? ?? 0) > 0 ? '已开启' : '已关闭'}；来电频道：${(diagnostics['callAlerts'] as num? ?? 0) > 0 ? '已开启' : '已关闭'}\n后台电池限制：${diagnostics['batteryUnrestricted'] == true ? '无限制' : '系统管理'}；来电弹出：${diagnostics['fullScreenCalls'] == true ? '已允许' : '未允许'}${(diagnostics['deliveryError'] as String? ?? '').isNotEmpty ? "\n${diagnostics['deliveryError']}" : ''}${(diagnostics['error'] as String? ?? '').isNotEmpty ? "\n${diagnostics['error']}" : ''}';
    if (!context.mounted) return;
    await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('消息与来电提醒'),
                  content: SizedBox(
                      width: 360,
                      child: SingleChildScrollView(
                          child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            for (final item in [
                              ('messageSound', '消息提示音'),
                              ('callSound', '来电铃声与振动')
                            ])
                              SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(item.$2,
                                      style: const TextStyle(fontSize: 14)),
                                  value: value[item.$1] != false,
                                  onChanged: (enabled) =>
                                      update(() => value[item.$1] = enabled)),
                            const SizedBox(height: 8),
                            const Text('免打扰可在好友菜单中设置。设置仅应用于本设备。',
                                style: TextStyle(
                                    fontSize: 12, color: AppTheme.muted)),
                            const SizedBox(height: 12),
                            ExpansionTile(
                                tilePadding: EdgeInsets.zero,
                                childrenPadding:
                                    const EdgeInsets.only(bottom: 8),
                                title: const Text('系统通知与后台设置',
                                    style: TextStyle(fontSize: 13)),
                                children: [
                                  Align(
                                      alignment: Alignment.centerLeft,
                                      child: Text(status(),
                                          style: const TextStyle(
                                              fontSize: 12,
                                              height: 1.6,
                                              color: AppTheme.muted))),
                                  TextButton(
                                      onPressed: () async {
                                        diagnostics =
                                            await NativeMessaging.diagnostics();
                                        if (dialogContext.mounted) {
                                          update(() {});
                                        }
                                      },
                                      child: const Text('刷新通知状态')),
                                  for (final option in [
                                    ('notifications', '系统通知设置'),
                                    ('calls', '来电弹出设置'),
                                    ('autostart', '后台自启动设置'),
                                    ('battery', '后台电池设置')
                                  ])
                                    ListTile(
                                        dense: true,
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(option.$2,
                                            style:
                                                const TextStyle(fontSize: 13)),
                                        trailing: const Icon(
                                            Icons.chevron_right,
                                            size: 18),
                                        onTap: () async {
                                          try {
                                            await NativeMessaging.openSettings(
                                                option.$1);
                                          } catch (error) {
                                            notice(error);
                                          }
                                        }),
                                  const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 10),
                                      child: Text(
                                          '小米手机请开启系统悬浮通知、锁屏通知和自启动，并将后台电池限制设为无限制。后台服务运行时，切换到其他应用或划掉任务仍可接收。系统强制终止进程后需重新打开应用。',
                                          style: TextStyle(
                                              fontSize: 12,
                                              height: 1.6,
                                              color: AppTheme.muted))),
                                  Wrap(spacing: 6, children: [
                                    for (final test in [
                                      ('message', '测试消息通知'),
                                      ('call', '测试来电铃声与振动')
                                    ])
                                      TextButton(
                                          onPressed: () async {
                                            try {
                                              await NativeMessaging.testAlert(
                                                  test.$1);
                                              diagnostics =
                                                  await NativeMessaging
                                                      .diagnostics();
                                              if (dialogContext.mounted) {
                                                update(() {});
                                              }
                                            } catch (error) {
                                              notice(error);
                                            }
                                          },
                                          child: Text(test.$2)),
                                  ]),
                                ]),
                          ]))),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () async {
                          try {
                            await NativeMessaging.settings(value);
                            if (dialogContext.mounted) {
                              Navigator.pop(dialogContext);
                            }
                          } catch (error) {
                            notice(error);
                          }
                        },
                        child: const Text('保存')),
                  ],
                )));
  } catch (error) {
    notice(error);
  }
}
