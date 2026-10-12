import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'account_avatar.dart';
import 'api.dart';
import 'app_theme.dart';

/// Home keeps frequent actions visible; live sessions take priority when present.
class HomeDashboard extends StatelessWidget {
  const HomeDashboard(
      {super.key,
      required this.account,
      required this.connection,
      required this.deviceCount,
      required this.onlineCount,
      required this.deviceName,
      required this.publishing,
      required this.ready,
      required this.onRefresh,
      required this.onProfile,
      required this.onFiles,
      required this.onDevices,
      required this.onCast,
      this.accountMenu,
      this.sessions,
      this.error,
      this.onRetry});

  final Account account;
  final Widget connection;
  final Widget? accountMenu;
  final Widget? sessions;
  final int deviceCount, onlineCount;
  final String deviceName;
  final bool publishing, ready;
  final Future<void> Function() onRefresh;
  final VoidCallback onProfile, onFiles, onDevices, onCast;
  final String? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          key: const PageStorageKey('home-dashboard'),
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 24),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 22),
              child: Row(children: [
                accountMenu ??
                    Semantics(
                        button: true,
                        label: '个人资料',
                        child: InkWell(
                            onTap: onProfile,
                            borderRadius: BorderRadius.circular(14),
                            child: AccountAvatar(
                                accountId: account.id,
                                avatarId: account.avatarId,
                                revision: account.avatarRevision,
                                size: 44))),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('你好，${account.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF232936))),
                      const SizedBox(height: 3),
                      const Text('设备连接与文件传输',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8390A5))),
                    ])),
              ]),
            ),
            if (error != null) ...[
              Container(
                  padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
                  decoration: BoxDecoration(
                      color: const Color(0xFFFFF3F1),
                      borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    const Icon(Icons.info_outline_rounded,
                        color: Color(0xFFC5483B), size: 19),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(error!,
                            style: const TextStyle(
                                fontSize: 12, color: Color(0xFFC5483B)))),
                    TextButton(onPressed: onRetry, child: const Text('重试')),
                  ])),
              const SizedBox(height: 14),
            ],
            if (sessions != null) ...[sessions!, const SizedBox(height: 14)],
            connection,
            const SizedBox(height: 22),
            const Padding(
                padding: EdgeInsets.only(left: 2, bottom: 10),
                child: Text('常用功能',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF667085)))),
            IntrinsicHeight(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  Expanded(
                      child: _Shortcut(
                          title: '文件传输',
                          subtitle: '发送与接收文件',
                          icon: Icons.folder_copy_outlined,
                          onTap: onFiles)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _Shortcut(
                          title: '我的设备',
                          subtitle: '$deviceCount 台设备 · $onlineCount 台在线',
                          icon: Icons.devices_outlined,
                          onTap: onDevices)),
                ])),
            const SizedBox(height: 14),
            Card(
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 6, 14),
                    child: Row(children: [
                      const Icon(Icons.smartphone_rounded,
                          color: Color(0xFF7A879A), size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            Text(deviceName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Row(children: [
                              Icon(Icons.circle,
                                  size: 6,
                                  color: publishing
                                      ? const Color(0xFF31B982)
                                      : const Color(0xFF98A2B3)),
                              const SizedBox(width: 5),
                              Flexible(
                                  child: Text(
                                      publishing
                                          ? '本机正在投屏'
                                          : ready
                                              ? '当前设备'
                                              : '设备尚未就绪',
                                      style: const TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF8390A5)))),
                            ]),
                          ])),
                      TextButton(
                          onPressed: onCast,
                          child: Text(publishing ? '管理投屏' : '去投屏')),
                    ]))),
          ],
        ),
      );
}

class _Shortcut extends StatelessWidget {
  const _Shortcut(
      {required this.title,
      required this.subtitle,
      required this.icon,
      required this.onTap});
  final String title, subtitle;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: AppTheme.line)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: onTap,
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                              color: const Color(0xFFEEF4FF),
                              borderRadius: BorderRadius.circular(11)),
                          child: Icon(icon, color: AppTheme.accent, size: 21)),
                      const SizedBox(height: 12),
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 11, color: Color(0xFF8390A5))),
                    ]))),
      );
}

class HomeConnectCard extends StatelessWidget {
  const HomeConnectCard(
      {super.key,
      required this.deviceId,
      required this.password,
      required this.busy,
      required this.onConnect});
  final TextEditingController deviceId, password;
  final bool busy;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
            padding: const EdgeInsets.all(18),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                        color: const Color(0xFFEEF4FF),
                        borderRadius: BorderRadius.circular(12)),
                    child: const Icon(Icons.cast_rounded,
                        color: AppTheme.accent, size: 22)),
                const SizedBox(width: 12),
                const Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text('连接设备',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      SizedBox(height: 3),
                      Text('输入设备代码，开始观看',
                          style: TextStyle(
                              fontSize: 12, color: Color(0xFF8390A5))),
                    ])),
              ]),
              const SizedBox(height: 20),
              TextField(
                  controller: deviceId,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  maxLength: 9,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                      labelText: '设备代码',
                      hintText: '9 位数字',
                      counterText: '',
                      prefixIcon: Icon(Icons.devices_outlined, size: 20))),
              const SizedBox(height: 12),
              TextField(
                  controller: password,
                  maxLength: 64,
                  textInputAction: TextInputAction.done,
                  onSubmitted: busy ? null : (_) => onConnect(),
                  decoration: const InputDecoration(
                      labelText: '连接密码（可选）',
                      counterText: '',
                      prefixIcon: Icon(Icons.lock_outline_rounded, size: 20))),
              const SizedBox(height: 12),
              const Text('自己的设备免密，其他设备可请求同意',
                  style: TextStyle(fontSize: 11, color: Color(0xFF8390A5))),
              const SizedBox(height: 18),
              SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                      onPressed: busy ? null : onConnect,
                      icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                      iconAlignment: IconAlignment.end,
                      label: const Text('连接设备'))),
            ])),
      );
}
