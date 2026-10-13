import 'app_updates.dart';
import 'chat_archive_screen.dart';
import 'account_feedback.dart';
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'account_avatar.dart';
import 'account_profile.dart';
import 'file_transfer.dart';
import 'file_transfer_screen.dart';
import 'session_manager.dart';
import 'app_theme.dart';
import 'app_motion.dart';
import 'app_components.dart';
import 'home_dashboard.dart';
import 'viewer_screen.dart';
import 'social_screen.dart';
import 'friend_calls.dart';
import 'native_service.dart';

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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  DeviceRegistration? _registration;
  final List<Device> _devices = [];
  final _remoteDeviceId = TextEditingController();
  final _remotePassword = TextEditingController();

  late Account _account = widget.account;
  void _applyProfile(Account account) {
    rememberAvatar(account.id, account.avatarId,
        revision: account.avatarRevision);
    if (mounted && account.id == widget.account.id) {
      setState(() => _account = account);
    }
  }

  Future<void> _editProfile() async {
    await _refreshAvatar();
    if (!mounted) return;
    final result = await Navigator.of(context).push<Account>(MaterialPageRoute(
        builder: (_) => AccountProfileScreen(account: _account)));
    if (result != null && mounted) {
      _applyProfile(result);
      showAccountFeedback(context, '资料已更新');
    } else {
      unawaited(_refreshAvatar());
    }
  }

  Future<void> _refreshAvatar() async {
    try {
      final account = await api.me();
      if (mounted && account.id == widget.account.id) {
        _applyProfile(account);
      }
    } catch (_) {/* Keep the last known avatar when offline. */}
  }

  Future<void> _chooseAvatar() async {
    await _refreshAvatar();
    if (!mounted) return;
    final selected = await chooseAccountAvatar(context,
        accountId: widget.account.id,
        current: avatarProfiles.value[widget.account.id] ??
            AvatarSelection(_account.avatarId,
                revision: _account.avatarRevision));
    if (selected != null && mounted) {
      rememberAvatar(widget.account.id, selected.id,
          revision: selected.revision);
      unawaited(_refreshAvatar());
      showAccountFeedback(context, '头像已更新');
    }
  }

  bool _busy = true;
  String? _error;
  int _selectedTab = 0;
  bool _devicesPage = false;
  int _socialUnread = 0;
  Timer? _notificationActions;
  DateTime _lastNotificationCheck = DateTime.fromMillisecondsSinceEpoch(0);
  bool _notificationStarting = false;
  String? _notificationError;
  Future<void> _ensureNotifications() async {
    if (_notificationStarting || !mounted) return;
    _notificationStarting = true;
    try {
      final state = await NativeMessaging.diagnostics();
      if (state['running'] != true) {
        await api.startAccountNotifications(widget.account);
      }
      _notificationError = null;
    } catch (error) {
      if (mounted && _notificationError != error.toString()) {
        _notificationError = error.toString();
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('消息后台服务启动失败：$error')));
      }
    } finally {
      _notificationStarting = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_handleNotification());
      unawaited(_ensureNotifications());
      unawaited(_refreshAvatar());
    }
  }

  bool _openingNotification = false;
  Future<void> _openMessageNotice(Map<String, dynamic> value) async {
    if (!mounted || value['accountId'] != widget.account.id) return;
    setState(() {
      _selectedTab = 1;
      _devicesPage = false;
    });
    if (NativeMessaging.visiblePeer == value['peerId']) return;
    try {
      final data = await api.social('state');
      final friends = (data['friends'] as List).where((friend) =>
          friend['id'] == value['peerId'] && friend['blocked'] != true);
      if (friends.isNotEmpty && mounted) {
        unawaited(appNavigatorKey.currentState?.push(MaterialPageRoute(
                builder: (_) => PrivateChatScreen(
                    account: _account,
                    friend: Map<String, dynamic>.from(friends.first)))) ??
            Future.value());
      }
    } catch (_) {}
  }

  Future<void> _handleNotification() async {
    if (_openingNotification || !mounted) return;
    _openingNotification = true;
    try {
      if (DateTime.now().difference(_lastNotificationCheck).inSeconds >= 15) {
        _lastNotificationCheck = DateTime.now();
        unawaited(_ensureNotifications());
      }
      final notice = await NativeMessaging.takeNotice();
      if (mounted && notice?['accountId'] == widget.account.id) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(notice!['text'] as String),
            action: SnackBarAction(
                label: '查看', onPressed: () => _openMessageNotice(notice)),
            duration: const Duration(seconds: 3)));
      }
      final value = await NativeMessaging.takeAction();
      if (value == null ||
          !mounted ||
          value['accountId'] != widget.account.id) {
        return;
      }
      final action = value['action'];
      if (['answer', 'reject', 'call'].contains(action)) {
        if (action == 'call' && friendCalls.current?['id'] == value['callId']) {
          friendCalls.openScreen();
          return;
        }
        await friendCalls.pollForNotification();
        if (friendCalls.current?['id'] != value['callId']) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('来电已结束')));
          }
          return;
        }
        if (action == 'answer') {
          await friendCalls.answer();
        } else if (action == 'reject') {
          await friendCalls.hangup();
        } else {
          friendCalls.openScreen();
        }
      } else if (action == 'message') {
        await _openMessageNotice(value);
      } else if (action == 'friends') {
        setState(() {
          _selectedTab = 1;
          _devicesPage = false;
        });
        if (mounted) {
          unawaited(appNavigatorKey.currentState?.push(MaterialPageRoute(
                  builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('新的好友')),
                      body: SocialScreen(
                          account: _account, initialFriendsTab: true)))) ??
              Future.value());
        }
      }
    } catch (_) {
      // Keep the app usable when a notification has expired or the OS bridge is unavailable.
    } finally {
      _openingNotification = false;
    }
  }

  int? _reportedReceiveId;
  bool? _reportedReceiveSuccess;

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
    clearAvatarProfiles();
    rememberAvatar(widget.account.id, widget.account.avatarId,
        revision: widget.account.avatarRevision);
    unawaited(_refreshAvatar());
    WidgetsBinding.instance.addObserver(this);
    widget.manager.addListener(_onManagerChanged);
    manager.loadShareSettings();
    _registerAndStart();
    unawaited(friendCalls.initialize(widget.account));
    unawaited(_ensureNotifications());
    _notificationActions = Timer.periodic(
        const Duration(seconds: 1), (_) => _handleNotification());
    NativeMessaging.listenForActions(_handleNotification);
  }

  @override
  void dispose() {
    NativeMessaging.listenForActions(null);
    WidgetsBinding.instance.removeObserver(this);
    _notificationActions?.cancel();
    widget.manager.removeListener(_onManagerChanged);
    _remoteDeviceId.dispose();
    _remotePassword.dispose();
    super.dispose();
  }

  /// 管理器状态变化 → 刷新界面
  void _onManagerChanged() {
    api.localChat.screenBusy =
        manager.publishing || manager.activeSessions.isNotEmpty;
    if (mounted) setState(() {});
    _maybeShowConnectRequest();
    _maybeShowFileTransferResult();
  }

  void _maybeShowFileTransferResult() {
    final progress = manager.fileHost?.latestProgress;
    if (progress == null ||
        progress.direction != FileTransferDirection.receive ||
        !progress.done) {
      return;
    }
    final success = progress.error == null;
    if (_reportedReceiveId == progress.id &&
        _reportedReceiveSuccess == success) {
      return;
    }
    _reportedReceiveId = progress.id;
    _reportedReceiveSuccess = success;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast(success
          ? '已收到「${progress.name}」，保存至 ${progress.savedPath}'
          : '文件「${progress.name}」接收失败：${progress.error}');
    });
  }

  /// 有待处理的观看请求时弹窗征求用户同意（同一时刻只弹一个）。
  bool _dialogShowing = false;

  Future<void> _maybeShowConnectRequest() async {
    if (_dialogShowing || !mounted) return;
    final requests = widget.manager.pendingRequests;
    if (requests.isEmpty) return;

    _dialogShowing = true;
    final request = requests.first;
    final isFileTransfer = request.purpose == 'files';
    final approved = await showDialog<bool>(
      context: context,
      animationStyle: AppMotion.style(context),
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: Text(isFileTransfer ? '收到文件传输请求' : '收到观看请求'),
        content: Text(isFileTransfer
            ? '「${request.viewerName}」请求与本机建立文件传输连接。\n\n同意后即可接收对方选择的文件。'
            : '「${request.viewerName}」请求观看本机屏幕。\n\n同意后对方即可实时看到这台设备的画面，可随时停止投送。'),
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
      _toast(isFileTransfer ? '已同意文件传输请求' : '已同意观看请求');
    }
    // 还有排队的请求就继续弹
    _maybeShowConnectRequest();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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

  Future<void> _toggleCall(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      _toast('通话操作失败：$error');
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
      sheetAnimationStyle: AppMotion.style(context),
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
                          onSelected: (_) =>
                              setSheetState(() => fps = option.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext,
                          current.copyWith(height: height, fps: fps)),
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
      animationStyle: AppMotion.style(context),
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
            fileToken: registration.fileToken,
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
  Future<ViewingSession?> _connectToDevice(
    String deviceId,
    String password, {
    bool openViewer = true,
    String viewerName = 'RemoteScreen 移动端',
  }) async {
    final id = deviceId.replaceAll(RegExp(r'\D'), '');
    final transferOnly = viewerName.contains('文件传输');
    if (id.length != 9) {
      _toast('设备 ID 是 9 位数字');
      return null;
    }

    // 本机不可观看自己（兜底：界面上已经没有入口，防止别处误调）
    if (id == _registration?.deviceId) {
      _toast('本机屏幕就在眼前，无需观看；请从另一台设备观看本机');
      return null;
    }

    // 同账号设备免确认直连（账号即授权）；跨账号才需要对方同意
    final owned = _devices.any((item) => item.deviceId == id);
    if (owned) {
      setState(() => _busy = true);
      try {
        final session = await widget.manager.connectToDevice(
          deviceId: id,
          viewerName: viewerName,
          fileOnly: !openViewer,
        );
        if (!mounted) return null;
        if (openViewer) _openSession(session);
        return session;
      } on ApiException catch (error) {
        if (mounted) _toast(error.message);
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return null;
    }

    setState(() => _busy = true);

    ValueNotifier<String>? status;
    var dialogOpen = false;
    // 取消令牌：点「取消」立刻置位，轮询循环随即结束并通知服务端
    final token = WatchRequestToken();
    if (password.isEmpty) {
      status = ValueNotifier<String>(
        transferOnly ? '正在向对方发送文件传输请求…' : '正在向对方发送观看请求…',
      );
      dialogOpen = true;
      // 不 await：等待期间还要继续跑请求轮询
      showDialog<void>(
        context: context,
        animationStyle: AppMotion.style(context),
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: Text(transferOnly ? '等待文件传输授权' : '等待对方同意'),
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
                token.cancelled = true; // 让轮询循环尽快收尾
                // 立刻通知服务端撤销：不能等长轮询返回（最多 20 秒），
                // 否则对方设备上会一直挂着这个请求
                final requestId = token.requestId;
                if (requestId != null) {
                  widget.manager.cancelWatchRequest(requestId);
                }
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
        viewerName: viewerName,
        fileOnly: !openViewer,
        onStatus: (text) => status?.value = text,
        token: token,
      );
      closeDialog();
      if (!mounted) return null;
      if (openViewer) _openSession(session);
      return session;
    } on ApiException catch (error) {
      closeDialog();
      if (!mounted) return null;
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
    return null;
  }

  /// 明确的结果提示（拒绝 / 超时这类需要用户知道的事，不能只用一个一闪而过的提示条）。
  Future<void> _showNoticeDialog(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      animationStyle: AppMotion.style(context),
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

  void _openFileTransfer() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FileTransferScreen(
          manager: manager,
          devices: List<Device>.of(_devices),
          currentDeviceId: _registration?.deviceId,
          onConnect: (deviceId, password) => _connectToDevice(
            deviceId,
            password,
            openViewer: false,
            viewerName: 'RemoteScreen 移动端 · 文件传输',
          ),
        ),
      ),
    );
  }

  Future<void> _logout() async {
    await NativeMessaging.stop();
    await friendCalls.logout();
    await manager.disconnectAll();
    await api.logout();
    widget.onLogout();
  }

  Widget _buildAccountMenu() => PopupMenuButton<String>(
        tooltip: '账号菜单',
        position: PopupMenuPosition.under,
        offset: const Offset(0, 8),
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: AppTheme.line)),
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 260),
        onSelected: (action) {
          if (action == 'profile') {
            setState(() {
              _selectedTab = 3;
              _devicesPage = false;
            });
            unawaited(_refreshAvatar());
          }
          if (action == 'avatar') unawaited(_chooseAvatar());
          if (action == 'logout') unawaited(_logout());
        },
        itemBuilder: (_) => [
          PopupMenuItem<String>(
            enabled: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_account.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.text, fontWeight: FontWeight.w600)),
                Text(
                    '账号 ID：${_account.accountId.isEmpty ? '待分配' : _account.accountId}',
                    style:
                        const TextStyle(fontSize: 12, color: AppTheme.muted)),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'profile', child: Text('个人资料')),
          const PopupMenuItem(value: 'avatar', child: Text('更换头像')),
          const PopupMenuItem(
              value: 'logout',
              child: Text('退出登录', style: TextStyle(color: AppTheme.danger))),
        ],
        child: AccountAvatar(
            accountId: _account.id,
            avatarId: _account.avatarId,
            revision: _account.avatarRevision,
            size: 44),
      );

  @override
  Widget build(BuildContext context) {
    const titles = ['首页', '消息', '投屏', '我的'];

    return PopScope(
      canPop: !_devicesPage,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _devicesPage) {
          setState(() => _devicesPage = false);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 56,
          automaticallyImplyLeading: false,
          titleSpacing: _devicesPage ? null : 18,
          leading: _devicesPage
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回上一页面',
                  onPressed: () => setState(() => _devicesPage = false))
              : null,
          title: Text(_devicesPage ? '我的设备' : titles[_selectedTab]),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '刷新',
              onPressed: _devicesPage ? _loadDevices : _registerAndStart,
            ),
          ],
        ),
        body: _registration == null && _busy
            ? const Center(child: CircularProgressIndicator())
            : AppContentTransition(
                identity: _devicesPage ? 4 : _selectedTab,
                child: IndexedStack(
                  index: _devicesPage ? 4 : _selectedTab,
                  children: [
                    _buildHomeTab(context),
                    SocialScreen(
                        key: ValueKey(widget.account.id),
                        account: _account,
                        onUnreadChanged: (count) {
                          if (mounted && count != _socialUnread) {
                            setState(() => _socialUnread = count);
                          }
                        }),
                    _buildCastTab(context),
                    _buildProfileTab(context),
                    _buildDevicesTab(context),
                  ]
                      .asMap()
                      .entries
                      .map((entry) => TickerMode(
                            enabled:
                                entry.key == (_devicesPage ? 4 : _selectedTab),
                            child: ExcludeFocus(
                              excluding: entry.key !=
                                  (_devicesPage ? 4 : _selectedTab),
                              child: entry.value,
                            ),
                          ))
                      .toList(),
                )),
        bottomNavigationBar: _buildBottomNavigation(),
      ),
    );
  }

  Widget _buildBottomNavigation() {
    const labels = ['首页', '消息', '投屏', '我的'];
    const icons = [
      Icons.home_outlined,
      Icons.chat_bubble_outline_rounded,
      Icons.cast_rounded,
      Icons.person_outline_rounded
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.line),
            boxShadow: const [
              BoxShadow(
                  color: Color(0x080F2445),
                  blurRadius: 12,
                  offset: Offset(0, 4))
            ],
          ),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              height: 56,
              child: LayoutBuilder(
                  builder: (context, box) => Stack(children: [
                        Positioned.fill(
                            child: IgnorePointer(
                                child: AnimatedAlign(
                          alignment: Alignment(-1 + _selectedTab * 2 / 3, 0),
                          duration:
                              AppMotion.duration(context, AppMotion.content),
                          curve: AppMotion.curve,
                          child: SizedBox(
                            width: box.maxWidth / 4,
                            height: 44,
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 5),
                              child: DecoratedBox(
                                  decoration: BoxDecoration(
                                color: const Color(0xFFECF3FF),
                                borderRadius: BorderRadius.circular(13),
                              )),
                            ),
                          ),
                        ))),
                        Row(
                            children: List.generate(labels.length, (index) {
                          final selected = _selectedTab == index;
                          final color = selected
                              ? AppTheme.accent
                              : const Color(0xFF8A94A5);
                          return Expanded(
                            child: Semantics(
                              selected: selected,
                              button: true,
                              label: labels[index],
                              excludeSemantics: true,
                              child: InkWell(
                                onTap: () => setState(() {
                                  _selectedTab = index;
                                  _devicesPage = false;
                                }),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Badge(
                                        isLabelVisible:
                                            index == 1 && _socialUnread > 0,
                                        label: Text(_socialUnread > 99
                                            ? '99+'
                                            : '$_socialUnread'),
                                        child: AnimatedScale(
                                            scale: selected ? 1.04 : 1,
                                            duration: AppMotion.duration(
                                                context, AppMotion.feedback),
                                            curve: AppMotion.curve,
                                            child: Icon(icons[index],
                                                size: 22, color: color))),
                                    const SizedBox(height: 3),
                                    Text(labels[index],
                                        maxLines: 1,
                                        style: TextStyle(
                                            fontSize: 10,
                                            height: 1.2,
                                            color: color,
                                            fontWeight: selected
                                                ? FontWeight.w600
                                                : FontWeight.w500)),
                                  ],
                                ),
                              ),
                            ),
                          );
                        })),
                      ])),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTab(BuildContext context) => HomeDashboard(
        account: _account,
        connection: _buildConnectCard(context),
        deviceCount: _devices.length,
        onlineCount: _devices.where((device) => device.online).length,
        deviceName:
            _registration?.deviceName ?? '${_account.name} 的 $_platformName',
        publishing: manager.publishing,
        ready: _registration != null,
        onRefresh: _loadDevices,
        onProfile: _editProfile,
        accountMenu: _buildAccountMenu(),
        onFiles: _openFileTransfer,
        onDevices: () => setState(() => _devicesPage = true),
        onCast: () => setState(() => _selectedTab = 2),
        sessions:
            manager.activeSessions.isEmpty ? null : _buildSessionsCard(context),
        error: _error,
        onRetry: _busy ? null : _registerAndStart,
      );

  Widget _buildCastTab(BuildContext context) => ListView(
        key: const PageStorageKey('cast-tab'),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          _buildLocalCard(context),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
        ],
      );

  Widget _buildDevicesTab(BuildContext context) => RefreshIndicator(
        onRefresh: _loadDevices,
        child: ListView(
          key: const PageStorageKey('devices-tab'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
          children: [_buildDevicesCard(context)],
        ),
      );

  Widget _buildProfileTab(BuildContext context) => ListView(
        key: const PageStorageKey('profile-tab'),
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 28),
        children: [
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Semantics(
                              button: true,
                              label: '更换头像',
                              child: InkWell(
                                  onTap: _chooseAvatar,
                                  borderRadius: BorderRadius.circular(18),
                                  child: AccountAvatar(
                                      accountId: _account.id,
                                      avatarId: _account.avatarId,
                                      revision: _account.avatarRevision,
                                      size: 64))),
                          const SizedBox(width: 14),
                          Expanded(
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                Text(_account.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.w600)),
                                Row(children: [
                                  Expanded(
                                      child: Text(
                                          '账号 ID：${_account.accountId.isEmpty ? '待分配' : _account.accountId}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: AppTheme.muted))),
                                  IconButton(
                                      tooltip: '复制账号 ID',
                                      icon: const Icon(Icons.copy_outlined,
                                          size: 16),
                                      onPressed: _account.accountId.isEmpty
                                          ? null
                                          : () async {
                                              await Clipboard.setData(
                                                  ClipboardData(
                                                      text:
                                                          _account.accountId));
                                              if (context.mounted) {
                                                showAccountFeedback(
                                                    context, '账号 ID 已复制');
                                              }
                                            }),
                                ]),
                              ])),
                        ]),
                        if (_account.bio.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_account.bio,
                              style: const TextStyle(
                                  fontSize: 13, color: AppTheme.muted))
                        ],
                        const SizedBox(height: 12),
                        Row(children: [
                          TextButton(
                              onPressed: _chooseAvatar,
                              child: const Text('更换头像')),
                          const Spacer(),
                          OutlinedButton(
                              onPressed: _editProfile,
                              child: const Text('编辑资料'))
                        ]),
                      ]))),
          const SectionHeading('个人信息'),
          Card(
              child: Column(children: [
            ProfileInfoRow('性别', genderLabel(_account.gender)),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ProfileInfoRow('生日', _account.birthday),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ProfileInfoRow('地区', _account.region),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ProfileInfoRow('邮箱', _account.email),
          ])),
          const SectionHeading('提醒与投屏'),
          Card(
              child: Column(children: [
            ListTile(
                leading:
                    const Icon(Icons.notifications_none_outlined, size: 22),
                title: const Text('消息与来电提醒'),
                subtitle: const Text('通知、提示音与来电铃声'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => showMessageAlertSettings(context)),
            const Divider(height: 1, indent: 16, endIndent: 16),
            ListTile(
                leading: const Icon(Icons.tune_outlined, size: 22),
                title: const Text('投屏画质'),
                subtitle: const Text('清晰度与帧率'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => setState(() => _selectedTab = 2)),
          ])),
          const SectionHeading('聊天记录'),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: const Text('本地保存与迁移'),
                  subtitle: const Text('备份与恢复聊天记录'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ChatArchiveScreen())))),
          const SectionHeading('关于'),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.system_update_alt, size: 22),
                  title: const Text('检查更新'),
                  subtitle: Text(
                      'RemoteScreen ${appUpdates.info['versionName'] ?? '0.2.0'}'),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => appUpdates.check(manual: true))),
          const SizedBox(height: 18),
          Card(
              child: ListTile(
                  leading: const Icon(Icons.logout,
                      size: 22, color: AppTheme.danger),
                  title: const Text('退出登录',
                      style: TextStyle(color: AppTheme.danger)),
                  onTap: _logout)),
        ],
      );

  Widget _buildLocalCard(BuildContext context) {
    final registration = _registration;
    final deviceId = registration?.deviceId;
    final password = registration?.password ?? '';
    final publishing = manager.publishing;
    final call = manager.publishCall;

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
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.tune, size: 20),
                  tooltip: '投屏画质',
                  onPressed: _showShareSettingsDialog,
                ),
                Switch(
                  value: publishing,
                  onChanged: registration == null ? null : _togglePublishing,
                ),
              ],
            ),
            Text(
              publishing
                  ? '投送中 —— 其他设备正在观看这台屏幕'
                  : '打开后，其他设备就能看到本设备屏幕（画质 ${_qualityLabel(manager.shareSettings)}）',
              style: TextStyle(
                fontSize: 12,
                color: publishing ? Colors.green : Colors.grey.shade600,
              ),
            ),
            if (publishing && call != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: call.busy
                        ? null
                        : () => _toggleCall(call.toggleMicrophone),
                    icon: Icon(
                        call.microphoneEnabled ? Icons.mic : Icons.mic_off),
                    label: Text(call.microphoneEnabled ? '关闭麦克风' : '打开麦克风'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _toggleCall(call.toggleSpeaker),
                    icon: Icon(call.speakerEnabled
                        ? Icons.volume_up
                        : Icons.volume_off),
                    label: Text(call.speakerEnabled ? '关闭通话声音' : '打开通话声音'),
                  ),
                ],
              ),
              if (Platform.isAndroid) ...[
                const SizedBox(height: 8),
                const Text('安卓投屏时，麦克风声音随投屏声音一起发送。',
                    style: TextStyle(fontSize: 12, color: Color(0xFF667085))),
              ],
            ],
            const SizedBox(height: 16),
            _credentialRow(
              '设备代码',
              _formatDeviceId(deviceId),
              Icons.copy_all_outlined,
              onTap: deviceId == null ? null : () => _toast('设备代码：$deviceId'),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
      decoration: BoxDecoration(
          color: const Color(0xFFF7F9FD),
          borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    letterSpacing: 1.4,
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
      ),
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
                  child: Text('正在观看',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
                Text('${sessions.length} 个会话',
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
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '已连接 ${session.duration.inMinutes} 分钟 · ${_stateLabel(session.state)}'),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton.icon(
                              onPressed: () => _openSession(session),
                              icon: const Icon(Icons.play_arrow_rounded,
                                  size: 18),
                              label: const Text('继续观看'),
                            ),
                            TextButton(
                              onPressed: () => _disconnectSession(session),
                              child: const Text('断开',
                                  style: TextStyle(color: Colors.red)),
                            ),
                          ],
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

  Widget _buildConnectCard(BuildContext context) => HomeConnectCard(
        deviceId: _remoteDeviceId,
        password: _remotePassword,
        busy: _busy,
        onConnect: () =>
            _connectToDevice(_remoteDeviceId.text, _remotePassword.text),
      );

  Widget _buildDevicesCard(BuildContext context) {
    final current = _devices
        .where((device) => device.deviceId == _registration?.deviceId)
        .toList();
    final others = _devices
        .where((device) => device.deviceId != _registration?.deviceId)
        .toList();
    Widget heading(String label) => Padding(
          padding: const EdgeInsets.fromLTRB(2, 18, 2, 10),
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Color(0xFF7A879A))),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 8),
          child: Text(
              '${_devices.length} 台设备 · ${_devices.where((device) => device.online).length} 台在线',
              style: const TextStyle(fontSize: 12, color: Color(0xFF8390A5))),
        ),
        if (current.isNotEmpty) ...[
          heading('当前设备'),
          ...current.map(_buildDeviceRow),
        ],
        heading('其他设备'),
        if (others.isEmpty)
          const Card(
              child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('还没有其他设备',
                      style: TextStyle(color: Color(0xFF8390A5)))))
        else
          ...others.map(_buildDeviceRow),
        const Padding(
          padding: EdgeInsets.only(top: 18),
          child: Center(
              child: Text('下拉可刷新设备状态',
                  style: TextStyle(fontSize: 11, color: Color(0xFFA1AABA)))),
        ),
      ],
    );
  }

  Widget _buildDeviceRow(Device device) {
    final isCurrent = device.deviceId == _registration?.deviceId;
    final color = device.online ? AppTheme.accent : const Color(0xFF98A2B3);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                      color: device.online
                          ? const Color(0xFFEEF4FF)
                          : const Color(0xFFF3F5F9),
                      borderRadius: BorderRadius.circular(13)),
                  child: Icon(
                      isCurrent
                          ? Icons.smartphone_rounded
                          : Icons.devices_outlined,
                      size: 23,
                      color: color),
                ),
                const SizedBox(width: 13),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(device.name,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      Row(children: [
                        if (!isCurrent) ...[
                          Icon(Icons.circle,
                              size: 6,
                              color: device.online
                                  ? const Color(0xFF31B982)
                                  : const Color(0xFFA1AABA)),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                            child: Text(
                                isCurrent
                                    ? '本机 · ${device.online ? '已就绪' : '离线'}'
                                    : device.online
                                        ? '在线'
                                        : '离线',
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF8390A5)))),
                      ]),
                    ])),
                if (isCurrent)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                        color: const Color(0xFFF3F5F9),
                        borderRadius: BorderRadius.circular(8)),
                    child: const Text('本机',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF8390A5))),
                  ),
              ]),
              if (!isCurrent) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: Text(_formatDeviceId(device.deviceId),
                          style: const TextStyle(
                              fontSize: 13, color: Color(0xFF7A879A)))),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        minimumSize: const Size(64, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(9)),
                        textStyle: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                    onPressed: device.online
                        ? () => _connectToDevice(device.deviceId, '')
                        : null,
                    child: Text(device.online ? '连接' : '离线'),
                  ),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
