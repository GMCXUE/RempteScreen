import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'api.dart';
import 'chat_backup.dart';
import 'chat_errors.dart';
import 'native_service.dart';

class ChatArchiveScreen extends StatefulWidget {
  const ChatArchiveScreen({super.key});
  @override
  State<ChatArchiveScreen> createState() => _ChatArchiveScreenState();
}

class _ChatArchiveScreenState extends State<ChatArchiveScreen> {
  bool _busy = false;
  String _status = '服务器暂存 7 天，本地记录长期保存';
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final owner = await api.chatOwner(), s = await api.localChat.store;
      final count = (await s.db.rawQuery(
              'SELECT COUNT(*) AS n FROM messages WHERE owner=?', [owner]))
          .first['n'];
      final missing = (await s.db.rawQuery(
              "SELECT COUNT(*) AS n FROM messages m WHERE owner=? AND kind IN ('image','video') AND NOT EXISTS(SELECT 1 FROM media b WHERE b.owner=m.owner AND b.id=m.id)",
              [owner]))
          .first['n'];
      if (mounted) {
        setState(() => _status = '本机 $count 条记录，$missing 项媒体待下载。服务器暂存 7 天。');
      }
    } catch (e) {
      if (mounted) setState(() => _status = e.toString());
    }
  }

  Future<String?> _password(bool export) async {
    final first = TextEditingController(), second = TextEditingController();
    final value = await showDialog<String>(
        context: context,
        builder: (c) => AlertDialog(
                title: Text(export ? '设置备份密码' : '输入备份密码'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('至少 8 个字符。备份只可恢复到同一账号，密码遗失后无法恢复。'),
                  TextField(
                      controller: first,
                      obscureText: true,
                      autofocus: true,
                      decoration: const InputDecoration(labelText: '备份密码')),
                  if (export)
                    TextField(
                        controller: second,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '再次输入密码'))
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c),
                      child: const Text('取消')),
                  TextButton(
                      onPressed: () {
                        if (first.text.runes.length < 8 ||
                            (export && first.text != second.text)) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(first.text.runes.length < 8
                                  ? '备份密码至少需要 8 个字符'
                                  : '两次输入的密码不一致')));
                          return;
                        }
                        Navigator.pop(c, first.text);
                      },
                      child: const Text('确定'))
                ]));
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () {
      first.dispose();
      second.dispose();
    }));
    return value;
  }

  Future<void> _run(String action) async {
    if (_busy) return;
    final password =
        action == 'sync' ? null : await _password(action == 'export');
    if (!mounted || (action != 'sync' && password == null)) return;
    setState(() {
      _busy = true;
      _status = action == 'sync'
          ? '正在同步到本机…'
          : action == 'export'
              ? '正在备份，请稍候…'
              : '正在恢复，请稍候…';
    });
    Directory? temp;
    SelectedNativeFile? selected;
    try {
      final owner = await api.chatOwner(), s = await api.localChat.store;
      String message;
      if (action == 'sync') {
        await api.syncLocalChat();
        message = '已同步记录，待下载媒体会继续重试';
      } else if (action == 'export') {
        temp = await Directory.systemTemp.createTemp('rs-chat-backup-');
        final file = File('${temp.path}/RemoteScreen聊天备份.rschat');
        await ChatBackup.export(s, owner, file, password!);
        final saved = await NativeFileBridge.saveReceivedFile(
            sourcePath: file.path, name: 'RemoteScreen聊天备份.rschat');
        message = '备份已保存到 $saved，可复制到其他设备后恢复';
      } else {
        selected = await NativeFileBridge.pickFile();
        if (selected == null) return;
        final count =
            await ChatBackup.restore(s, owner, File(selected.path), password!);
        message = '恢复完成，已合并 $count 条记录';
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(message), duration: const Duration(seconds: 6)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(chatError(e)), duration: const Duration(seconds: 6)));
      }
    } finally {
      if (temp != null && await temp.exists()) {
        await temp.delete(recursive: true);
      }
      if (selected != null && await File(selected.path).exists()) {
        await File(selected.path).delete();
      }
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: Scaffold(
          appBar: AppBar(title: const Text('本地保存与迁移')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Text(_status),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            ListTile(
                title: const Text('同步到本机'),
                subtitle: const Text('下载聊天记录和图片视频'),
                trailing: const Icon(Icons.download_outlined),
                onTap: _busy ? null : () => _run('sync')),
            ListTile(
                title: const Text('备份聊天记录'),
                subtitle: const Text('加密保存，可迁移到手机或电脑'),
                trailing: const Icon(Icons.save_outlined),
                onTap: _busy ? null : () => _run('export')),
            ListTile(
                title: const Text('恢复聊天记录'),
                subtitle: const Text('导入同一账号的备份并合并去重'),
                trailing: const Icon(Icons.restore_outlined),
                onTap: _busy ? null : () => _run('import')),
            const SizedBox(height: 24),
            const Text('备份仅包含本机已下载的记录和媒体。卸载、清理应用数据或换机前，请先备份。备份密码遗失后无法恢复。'),
          ])));
}
