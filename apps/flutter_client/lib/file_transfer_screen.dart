import 'package:flutter/material.dart';

import 'api.dart';
import 'app_components.dart';
import 'app_theme.dart';
import 'compact_feedback.dart';
import 'file_transfer.dart';
import 'file_transfer_history.dart';
import 'session_manager.dart';
import 'native_service.dart';

typedef FileTransferConnector = Future<ViewingSession?> Function(
  String deviceId,
  String password,
);

/// 独立文件传输页面。
///
/// 文件仍通过端到端 LiveKit 数据通道发送，但这里不会打开屏幕观看页面。
class FileTransferScreen extends StatefulWidget {
  const FileTransferScreen({
    super.key,
    required this.manager,
    required this.devices,
    required this.currentDeviceId,
    required this.onConnect,
  });

  final SessionManager manager;
  final List<Device> devices;
  final String? currentDeviceId;
  final FileTransferConnector onConnect;

  @override
  State<FileTransferScreen> createState() => _FileTransferScreenState();
}

class _FileTransferScreenState extends State<FileTransferScreen> {
  final _deviceId = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  final _feedback = CompactFeedback();

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_refresh);
  }

  @override
  void dispose() {
    widget.manager.removeListener(_refresh);
    _feedback.dismiss();
    _deviceId.dispose();
    _password.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _toast(String message) {
    if (!mounted) return;
    _feedback.show(context, message, error: true);
  }

  Future<void> _send(ViewingSession session) async {
    try {
      final selected = await widget.manager.sendFile(session.id);
      if (!selected) return;
    } catch (error) {
      _toast('文件发送失败：$error');
    }
  }

  Future<void> _connectAndSend(String deviceId, String password) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final session = await widget.onConnect(deviceId, password);
      if (session != null && mounted) await _send(session);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  ViewingSession? _sessionFor(String deviceId) {
    for (final session in widget.manager.fileSessions) {
      if (session.deviceId == deviceId) return session;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.manager.fileSessions;
    final devices = widget.devices
        .where((d) => d.deviceId != widget.currentDeviceId)
        .toList();
    final history = widget.manager.fileHistory.take(100).toList();
    final ready = widget.manager.fileReceivingReady;
    return Scaffold(
      appBar: AppBar(title: const Text('文件传输')),
      body: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                  padding: const EdgeInsets.only(top: 5),
                  child: Icon(Icons.circle,
                      size: 7,
                      color: ready ? AppTheme.success : AppTheme.danger)),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(
                      ready
                          ? '本机已就绪，可接收文件'
                          : widget.manager.fileHostError ??
                              '文件接收连接未就绪，请重新登录后重试',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.muted))),
            ]),
            const SizedBox(height: 14),
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                    color:
                                        AppTheme.accent.withValues(alpha: .08),
                                    borderRadius: BorderRadius.circular(12)),
                                child: const Icon(Icons.folder_open_outlined,
                                    size: 23, color: AppTheme.accent)),
                            const SizedBox(width: 12),
                            const Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text('连接设备',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600)),
                                  SizedBox(height: 3),
                                  Text('输入对方的设备代码',
                                      style: TextStyle(
                                          fontSize: 12, color: AppTheme.muted)),
                                ])),
                          ]),
                          const SizedBox(height: 20),
                          TextField(
                              controller: _deviceId,
                              keyboardType: TextInputType.number,
                              maxLength: 9,
                              decoration: const InputDecoration(
                                  labelText: '设备代码',
                                  hintText: '9 位数字',
                                  counterText: '')),
                          const SizedBox(height: 12),
                          TextField(
                              controller: _password,
                              decoration:
                                  const InputDecoration(labelText: '连接密码（可选）')),
                          const SizedBox(height: 16),
                          SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                  onPressed: _busy
                                      ? null
                                      : () => _connectAndSend(
                                          _deviceId.text, _password.text),
                                  icon: const Icon(Icons.upload_file_outlined,
                                      size: 20),
                                  label: Text(_busy ? '正在连接…' : '连接并选择文件'))),
                          const SizedBox(height: 10),
                          const Text('自己的设备免密，其他设备可请求同意',
                              style: TextStyle(
                                  fontSize: 11, color: AppTheme.subtle)),
                        ]))),
            if (sessions.isNotEmpty) ...[
              const SectionHeading('已连接设备'),
              for (final session in sessions) ...[
                _sessionCard(session),
                const SizedBox(height: 10)
              ],
            ],
            const SectionHeading('我的设备'),
            Card(
                child: Column(children: [
              if (devices.isEmpty)
                const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无其他设备',
                        style: TextStyle(fontSize: 13, color: AppTheme.muted))),
              for (var i = 0; i < devices.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
                    leading: const Icon(Icons.devices_outlined, size: 24),
                    title: Row(children: [
                      Flexible(
                          child: Text(devices[i].name,
                              maxLines: 1, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 6),
                      Icon(Icons.circle,
                          size: 7,
                          color: devices[i].online
                              ? AppTheme.success
                              : AppTheme.subtle)
                    ]),
                    subtitle: Text(_formatDeviceId(devices[i].deviceId)),
                    trailing: TextButton(
                        onPressed: !devices[i].online || _busy
                            ? null
                            : () {
                                final session =
                                    _sessionFor(devices[i].deviceId);
                                if (session != null) {
                                  _send(session);
                                } else {
                                  _connectAndSend(devices[i].deviceId, '');
                                }
                              },
                        child: Text(_sessionFor(devices[i].deviceId) == null
                            ? (devices[i].online ? '连接发送' : '离线')
                            : '发送文件'))),
              ],
            ])),
            _receiveProgress(),
            const SectionHeading('本次传输', caption: '单个文件不能超过 50 MB'),
            Card(
                child: Column(children: [
              if (history.isEmpty)
                const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                        child: Column(children: [
                      Icon(Icons.folder_open_outlined,
                          color: AppTheme.subtle, size: 30),
                      SizedBox(height: 10),
                      Text('暂无传输记录',
                          style:
                              TextStyle(fontSize: 13, color: AppTheme.muted)),
                    ]))),
              for (var i = 0; i < history.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
                _taskRow(history[i]),
              ],
            ])),
            FileTransferHistory(api: widget.manager.api),
          ]),
    );
  }

  Widget _taskRow(FileTransferProgress task) {
    final color = task.error != null
        ? AppTheme.danger
        : task.done
            ? AppTheme.success
            : AppTheme.accent;
    return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          FileTypeIcon(task.name),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(task.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 5),
                Text(
                    '${task.direction == FileTransferDirection.receive ? '接收' : '发送'} · ${formatFileSize(task.size)}',
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.muted)),
                if (task.error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(task.error!,
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.danger))),
                if (task.direction == FileTransferDirection.receive &&
                    task.done && task.error == null && task.savedPath != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: SelectableText('保存位置：${task.savedPath}',
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.muted))),
                if (!task.done && task.error == null)
                  Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                              value: task.size > 0 ? task.fraction : null,
                              minHeight: 3))),
              ])),
          const SizedBox(width: 10),
          Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              decoration: BoxDecoration(
                  color: color.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(6)),
              child: Text(
                  task.error != null
                      ? '失败'
                      : task.done
                          ? '已完成'
                          : '${(task.fraction * 100).round()}%',
                  style: TextStyle(color: color, fontSize: 11))),
          if (task.direction == FileTransferDirection.receive &&
              task.done &&
              task.error == null &&
              task.savedPath != null)
            IconButton(
                tooltip: '打开所在目录',
                icon: const Icon(Icons.folder_open_outlined, size: 20),
                onPressed: () => _openReceivedDirectory(task.savedPath!)),
        ]));
  }

  Future<void> _openReceivedDirectory(String savedPath) async {
    try {
      await NativeFileBridge.openReceivedDirectory();
    } catch (_) {
      if (!mounted) return;
      await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
                title: const Text('无法打开文件所在目录'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('系统未能打开文件管理器。请手动打开文件管理，按保存位置查找：'),
                  const SizedBox(height: 12),
                  SelectableText(savedPath),
                ]),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('知道了')),
                ],
              ));
    }
  }

  Widget _sessionCard(ViewingSession session) {
    final progress = session.fileTransfer.latestProgress;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                const Icon(Icons.devices_other, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(session.deviceName,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(_formatDeviceId(session.deviceId),
                          style: const TextStyle(
                              fontSize: 12, color: AppTheme.muted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: session.fileTransfer.sending ? '取消发送' : '断开文件连接',
                  onPressed: () async {
                    if (session.fileTransfer.sending) {
                      session.fileTransfer.cancelSend();
                    } else {
                      await widget.manager.disconnectSession(session.id);
                    }
                  },
                  icon: Icon(session.fileTransfer.sending
                      ? Icons.cancel_outlined
                      : Icons.link_off),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: session.fileTransfer.sending
                      ? null
                      : () => _send(session),
                  icon: const Icon(Icons.upload_file_outlined, size: 18),
                  label: Text(session.fileTransfer.sending ? '发送中' : '选择文件'),
                )),
            if (progress != null &&
                progress.direction == FileTransferDirection.send) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  progress.error != null
                      ? '发送失败：${progress.error}'
                      : progress.done
                          ? '已发送：${progress.name}'
                          : '正在发送：${progress.name}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: progress.error == null
                        ? AppTheme.muted
                        : AppTheme.danger,
                  ),
                ),
              ),
              if (!progress.done) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: progress.size > 0 ? progress.fraction : null,
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _receiveProgress() {
    final progress = widget.manager.fileHost?.latestProgress;
    if (progress == null ||
        progress.direction != FileTransferDirection.receive ||
        progress.done) {
      return const SizedBox.shrink();
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.download_for_offline_outlined),
        title: Text(progress.done ? '最近接收' : '正在接收'),
        trailing: progress.done &&
                progress.error == null &&
                progress.savedPath != null
            ? IconButton(
                tooltip: '打开所在目录',
                icon: const Icon(Icons.folder_open_outlined),
                onPressed: () => _openReceivedDirectory(progress.savedPath!),
              )
            : null,
        subtitle: Text(
          progress.error != null
              ? '${progress.name}：${progress.error}'
              : progress.done
                  ? '${progress.name}\n${progress.savedPath ?? ''}'
                  : '${progress.name} ${(progress.fraction * 100).round()}%',
        ),
      ),
    );
  }

  String _formatDeviceId(String id) {
    if (id.length != 9) return id;
    return '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}';
  }
}
