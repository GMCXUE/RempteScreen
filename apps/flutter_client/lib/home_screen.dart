import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'api.dart';
import 'session_manager.dart';
import 'viewer_screen.dart';

/// 主界面：本机的投送信息、进行中的会话、连接其他设备、我的设备列表。
///
/// 连接全部由 SessionManager 持有 —— 本页退出、前后台切换都不影响连接。
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.account,
    required this.manager,
    required this.onLogout,
  });

  final Account account;
  final SessionManager manager;
  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  DeviceRegistration? _registration;
  final List<Device> _devices = [];
  final _remoteDeviceId = TextEditingController();
  final _remotePassword = TextEditingController();

  bool _busy = true;
  String? _error;

  SessionManager get manager => widget.manager;

  String get _platformName {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    return Platform.operatingSystem;
  }

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_onManagerChanged);
    manager.loadShareSettings();
    _registerAndStart();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_onManagerChanged);
    _remoteDeviceId.dispose();
    _remotePassword.dispose();
    super.dispose();
  }

  /// 管理器状态变化 → 刷新界面
  void _onManagerChanged() {
    if (mounted) setState(() {});
    _maybeShowConnectRequest();
  }

  /// 有待处理的观看请求时弹窗征求用户同意（同一时刻只弹一个）。
  bool _dialogShowing = false;

  Future<void> _maybeShowConnectRequest() async {
    if (_dialogShowing || !mounted) return;
    final requests = widget.manager.pendingRequests;
    if (requests.isEmpty) return;

    _dialogShowing = true;
    final request = requests.first;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('收到观看请求'),
        content: Text('「${request.viewerName}」请求观看本机屏幕。\n\n'
            '同意后对方即可实时看到这台设备的画面，可随时停止投送。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('同意'),
          ),
        ],
      ),
    );
    _dialogShowing = false;

    if (approved == null) return;
    await widget.manager.decideRequest(request, approved);
    if (approved && mounted) {
      _toast('已同意观看请求');
    }
    // 还有排队的请求就继续弹
    _maybeShowConnectRequest();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  // MARK: - 注册与数据

  Future<void> _registerAndStart() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      _registration = await widget.manager.registerDevice(
        platform: _platformName,
        deviceName: '${widget.account.name} 的 $_platformName',
      );
      await _loadDevices();
      if (mounted) setState(() => _busy = false);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  Future<void> _loadDevices() async {
    try {
      final devices = await widget.manager.api.listDevices();
      if (!mounted) return;
      setState(() => _devices
        ..clear()
        ..addAll(devices));
    } catch (_) {
      // 列表刷新失败不打断使用
    }
  }

  // MARK: - 投送

  Future<void> _togglePublishing(bool enabled) async {
    final registration = _registration;
    if (registration == null) return;

    setState(() => _busy = true);
    try {
      if (enabled) {
        await widget.manager.startPublishing(registration);
        _toast('已开始投送');
      } else {
        await widget.manager.stopPublishing();
      }
    } catch (error) {
      _toast('投送操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // MARK: - 密码

  /// 投屏画质标签，如「高清 · 30帧」
  String _qualityLabel(ScreenShareSettings s) {
    final res = switch (s.height) {
      0 => '原始分辨率',
      <= 720 => '流畅',
      _ => '高清',
    };
    return '$res · ${s.fps}帧';
  }

  /// 投屏画质设置：清晰度（按高度等比缩放）与帧率。
  Future<void> _showShareSettingsDialog() async {
    final current = manager.shareSettings;
    final result = await showModalBottomSheet<ScreenShareSettings>(
      context: context,
      builder: (sheetContext) {
        var height = current.height;
        var fps = current.fps;
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('投屏画质',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 14),
                  const Text('清晰度（按屏幕比例缩放）',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in const [
                        (720, '流畅（长边 720）'),
                        (1080, '高清（长边 1080）'),
                        (0, '原始分辨率'),
                      ])
                        ChoiceChip(
                          label: Text(option.$2),
                          selected: height == option.$1,
                          onSelected: (_) =>
                              setSheetState(() => height = option.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('帧率',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final option in const [
                        (15, '15 帧'),
                        (30, '30 帧'),
                        (60, '60 帧'),
                      ])
                        ChoiceChip(
                          label: Text(option.$2),
                          selected: fps == option.$1,
                          onSelected: (_) => setSheetState(() => fps = option.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(
                          sheetContext, current.copyWith(height: height, fps: fps)),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (result == null) return;
    await result.save();
    setState(() => manager.shareSettings = result);
    _toast('画质已设为 ${_qualityLabel(result)}，下次投送生效');
  }

  /// 自定义连接密码：密码归属设备，只有本机能改。
  Future<void> _setCustomPassword() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final password = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('自定义连接密码'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '4–64 个字符，不能包含空格。设置后旧密码立即失效，已分享出去的密码需要重新告知对方。',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '新密码',
                  hintText: '例如 my-pass-8888',
                ),
                validator: (value) {
                  final text = value ?? '';
                  if (text.length < 4 || text.length > 64) {
                    return '长度需在 4 到 64 个字符之间';
                  }
                  if (RegExp(r'\s').hasMatch(text)) return '不能包含空格';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.pop(dialogContext, controller.text);
              }
            },
            child: const Text('设置'),
          ),
        ],
      ),
    );

    if (password == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final updated = await widget.manager.setConnectionPassword(password);
      if (mounted) setState(() => _registration = updated);
      _toast('连接密码已更新，旧密码立即失效');
    } on ApiException catch (error) {
      _toast(error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshPassword() async {
    final registration = _registration;
    if (registration == null) return;

    try {
      final password = await widget.manager.api.refreshDevicePassword(
        deviceId: registration.deviceId,
        sessionToken: registration.sessionToken,
      );
      if (!mounted) return;
      setState(() => _registration = DeviceRegistration(
            deviceId: registration.deviceId,
            password: password,
            sessionToken: registration.sessionToken,
            roomName: registration.roomName,
            livekitUrl: registration.livekitUrl,
            publishToken: registration.publishToken,
            deviceName: registration.deviceName,
          ));
      _toast('密码已更新，旧密码立即失效');
    } on ApiException catch (error) {
      _toast(error.message);
    }
  }

  // MARK: - 会话

  void _openSession(ViewingSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ViewerScreen(
          manager: widget.manager,
          sessionId: session.id,
        ),
      ),
    );
  }

  Future<void> _disconnectSession(ViewingSession session) async {
    await widget.manager.disconnectSession(session.id);
    _toast('已断开');
  }

  // MARK: - 连接其他设备

  /// 连接一台设备。
  ///
  /// 没有连接密码 → 走「请求对方同意」：弹等待框，对方在自己设备上同意后自动接上，
  /// 并且对方会顺带自动打开「允许远程观看本设备」。
  /// 有连接密码 → 直接连（设备主人主动分享的凭据，不打扰对方）。
  Future<void> _connectToDevice(String deviceId, String password) async {
    final id = deviceId.replaceAll(RegExp(r'\D'), '');
    if (id.length != 9) {
      _toast('设备 ID 是 9 位数字');
      return;
    }

    // 本机不可观看自己（兜底：界面上已经没有入口，防止别处误调）
    if (id == _registration?.deviceId) {
      _toast('本机屏幕就在眼前，无需观看；请从另一台设备观看本机');
      return;
    }

    setState(() => _busy = true);

    ValueNotifier<String>? status;
    var dialogOpen = false;
    // 取消令牌：点「取消」立刻置位，轮询循环随即结束并通知服务端
    final token = WatchRequestToken();
    if (password.isEmpty) {
      status = ValueNotifier<String>('正在向对方发送观看请求…');
      dialogOpen = true;
      // 不 await：等待期间还要继续跑请求轮询
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('等待对方同意'),
          content: ValueListenableBuilder<String>(
            valueListenable: status!,
            builder: (_, value, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(value, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 14),
                const LinearProgressIndicator(minHeight: 3),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                token.cancelled = true;   // 让轮询循环尽快收尾
                dialogOpen = false;
                Navigator.of(dialogContext).pop();
                // 立刻复位，避免取消后界面一直转圈
                if (mounted) setState(() => _busy = false);
                _toast('已取消等待，对方那边的请求也一并撤销');
              },
              child: const Text('取消'),
            ),
          ],
        ),
      );
    }

    void closeDialog() {
      if (!dialogOpen) return;
      dialogOpen = false;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }

    try {
      final session = await widget.manager.watchDevice(
        deviceId: id,
        password: password,
        onStatus: (text) => status?.value = text,
        token: token,
      );
      closeDialog();
      if (!mounted) return;
      _openSession(session);
    } on ApiException catch (error) {
      closeDialog();
      if (!mounted) return;
      // 用户自己取消的不必再弹窗；其余（被拒绝 / 过期 / 超时）要明确告知
      if (error.code != 'cancelled') {
        await _showNoticeDialog('无法连接', error.message);
      }
    } catch (error) {
      closeDialog();
      if (mounted) await _showNoticeDialog('连接失败', '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 明确的结果提示（拒绝 / 超时这类需要用户知道的事，不能只用一个一闪而过的提示条）。
  Future<void> _showNoticeDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(message, style: const TextStyle(fontSize: 13)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  // MARK: - 构建

  @override
  Widget build(BuildContext context) {
    final manager = widget.manager;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RemoteScreen'),
        actions: [
          IconButton(
              icon: const Icon(Icons.refresh), onPressed: _registerAndStart),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle),
            itemBuilder: (_) => [
              PopupMenuItem(enabled: false, child: Text(widget.account.email)),
              const PopupMenuItem(value: 'logout', child: Text('退出登录')),
            ],
            onSelected: (value) async {
              if (value == 'logout') {
                await manager.disconnectAll();
                await api.logout();
                widget.onLogout();
              }
            },
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDevices,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _buildLocalCard(context),
                  const SizedBox(height: 14),
                  _buildSessionsCard(context),
                  const SizedBox(height: 14),
                  _buildConnectCard(context),
                  const SizedBox(height: 14),
                  _buildDevicesCard(context),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'RemoteScreen',
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade400),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildLocalCard(BuildContext context) {
    final registration = _registration;
    final deviceId = registration?.deviceId;
    final password = registration?.password ?? '';
    final publishing = manager.publishing;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '允许远程观看本设备',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.tune, size: 20),
                  tooltip: '投屏画质',
                  onPressed: _showShareSettingsDialog,
                ),
                Switch(
                  value: publishing,
                  onChanged:
                      registration == null ? null : _togglePublishing,
                ),
              ],
            ),
            Text(
              publishing
                  ? '投送中 —— 其他设备正在观看这台屏幕'
                  : '打开后，其他设备就能看到这台电脑的屏幕（画质 ${_qualityLabel(manager.shareSettings)}）',
              style: TextStyle(
                fontSize: 12,
                color: publishing ? Colors.green : Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 16),
            _credentialRow(
              '设备代码',
              _formatDeviceId(deviceId),
              Icons.copy_all_outlined,
              onTap: deviceId == null
                  ? null
                  : () => _toast('设备代码：$deviceId'),
            ),
            const SizedBox(height: 12),
            _credentialRow(
              '连接密码',
              password.isEmpty ? '— — —' : password,
              Icons.autorenew,
              onTap: _refreshPassword,
              hint: '点右侧图标可随机刷新或自定义',
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: registration == null ? null : _setCustomPassword,
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('自定义密码', style: TextStyle(fontSize: 12)),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '把这两项告诉对方，对方输入后就能看到你的屏幕',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDeviceId(String? id) {
    if (id == null || id.length != 9) return '— — —';
    return '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}';
  }

  Widget _credentialRow(String label, String value, IconData icon,
      {VoidCallback? onTap, String? hint}) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 2),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  letterSpacing: 2,
                ),
              ),
              if (hint != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(hint,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.grey)),
                ),
            ],
          ),
        ),
        IconButton(icon: Icon(icon), onPressed: onTap),
      ],
    );
  }

  Widget _readyBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.green.shade200),
        borderRadius: BorderRadius.circular(999),
        color: Colors.green.shade50,
      ),
      child: const Text('已准备好连接',
          style: TextStyle(fontSize: 11, color: Colors.green)),
    );
  }

  Widget _buildSessionsCard(BuildContext context) {
    final sessions = manager.activeSessions;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('进行中的会话',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Text('${sessions.length} 路',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              ],
            ),
            const SizedBox(height: 10),
            if (sessions.isEmpty)
              Text('当前没有观看中的会话',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500))
            else
              ...sessions.map((session) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(
                      Icons.circle,
                      size: 10,
                      color: session.state == ViewingSessionState.live
                          ? Colors.green
                          : Colors.orange,
                    ),
                    title: Text(session.deviceName),
                    subtitle: Text(
                        '已连接 ${session.duration.inMinutes} 分钟 · ${_stateLabel(session.state)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => _openSession(session),
                          child: const Text('继续观看'),
                        ),
                        TextButton(
                          onPressed: () => _disconnectSession(session),
                          child: const Text('断开',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }

  String _stateLabel(ViewingSessionState state) => switch (state) {
        ViewingSessionState.connecting => '连接中',
        ViewingSessionState.waiting => '等待画面',
        ViewingSessionState.live => '观看中',
        ViewingSessionState.reconnecting => '重连中',
        ViewingSessionState.peerEnded => '对端已停止',
        ViewingSessionState.ended => '已断开',
      };

  Widget _buildConnectCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('连接其他设备',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                _readyBadge(),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _remoteDeviceId,
              keyboardType: TextInputType.number,
              maxLength: 9,
              decoration: const InputDecoration(
                labelText: '对方的设备代码',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _remotePassword,
              maxLength: 6,
              decoration: const InputDecoration(
                labelText: '连接密码（连自己的设备可留空）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () => _connectToDevice(
                        _remoteDeviceId.text, _remotePassword.text),
                child: const Text('连接'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDevicesCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('我的设备',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                    icon: const Icon(Icons.refresh), onPressed: _loadDevices),
              ],
            ),
            const SizedBox(height: 8),
            if (_devices.isEmpty)
              const Text('还没有绑定设备',
                  style: TextStyle(fontSize: 12, color: Colors.grey))
            else
              ..._devices.map(_buildDeviceRow),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceRow(Device device) {
    final isCurrent = device.deviceId == _registration?.deviceId;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(
        Icons.circle,
        size: 10,
        color: device.online ? Colors.green : Colors.grey,
      ),
      title: Text(isCurrent ? '${device.name}（本机）' : device.name),
      subtitle: Text(
        isCurrent ? '屏幕就在眼前，无需观看' : _formatDeviceId(device.deviceId),
        style: const TextStyle(fontSize: 11.5),
      ),
      trailing: isCurrent
          // 本机不提供观看入口：自己看自己没意义，还会白占一路上行
          ? Chip(
              label: const Text('本机', style: TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: Colors.grey.shade300),
              backgroundColor: Colors.grey.shade100,
            )
          : FilledButton.tonal(
              onPressed: device.online
                  ? () => _connectToDevice(device.deviceId, '')
                  : null,
              child: Text(device.online ? '连接' : '离线'),
            ),
    );
  }
}
