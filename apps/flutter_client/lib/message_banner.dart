import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'account_avatar.dart';
import 'app_motion.dart';
import 'app_theme.dart';

class MessageNotice {
  MessageNotice.fromMap(Map<String, dynamic> value, this.onReply)
      : accountId = value['accountId'] as String,
        peerId = value['peerId'] as String,
        preview = value['preview'] != false && value['preview'] != 'false',
        name = value['name'] as String? ?? '好友',
        message = value['message'] as String? ?? '收到新消息',
        avatarId = value['avatarId'] as String?,
        avatarRevision = value['avatarRevision'] as String? ?? '',
        receivedAt = int.tryParse('${value['receivedAt']}');

  final String accountId, peerId, name, message, avatarRevision;
  final String? avatarId;
  final bool preview;
  final int? receivedAt;
  final VoidCallback onReply;
  String get title => preview ? name : 'RemoteScreen';
  String get summary => preview ? '私信了你：$message' : '收到新消息';
}

/// One foreground card, scoped to the logged-in account. No message backlog.
class MessageBannerController extends ValueNotifier<MessageNotice?> {
  MessageBannerController() : super(null);
  String? _accountId;
  bool foreground = true;

  void bind(String accountId) {
    clear();
    _accountId = accountId;
  }

  void unbind(String accountId) {
    if (_accountId != accountId) return;
    _accountId = null;
    clear();
  }

  void show(MessageNotice notice) {
    if (!foreground || notice.accountId != _accountId) return;
    if (notice.receivedAt != null &&
        DateTime.now().millisecondsSinceEpoch - notice.receivedAt! > 8000) {
      return;
    }
    value = notice;
  }

  void clear([MessageNotice? notice]) {
    if (notice == null || identical(value, notice)) value = null;
  }

  void reply(MessageNotice notice) {
    if (!identical(value, notice) ||
        notice.accountId != _accountId ||
        !foreground) {
      return;
    }
    clear();
    notice.onReply();
  }
}

final messageBanners = MessageBannerController();

/// Outside the Navigator so it also works above pushed pages; callers keep
/// incoming calls and the mandatory-update overlay above this host.
class MessageBannerHost extends StatefulWidget {
  const MessageBannerHost({super.key, required this.child, this.controller});
  final Widget child;
  final MessageBannerController? controller;
  @override
  State<MessageBannerHost> createState() => _MessageBannerHostState();
}

class _MessageBannerHostState extends State<MessageBannerHost>
    with WidgetsBindingObserver {
  Timer? _timer;
  MessageBannerController get controller => widget.controller ?? messageBanners;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.foreground = WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    controller.addListener(_changed);
  }

  void _changed() {
    _timer?.cancel();
    final notice = controller.value;
    if (notice != null) {
      // Screen readers need time to reach the reply action.
      if (!MediaQuery.accessibleNavigationOf(context)) {
        _timer =
            Timer(const Duration(seconds: 5), () => controller.clear(notice));
      }
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    controller.foreground = state == AppLifecycleState.resumed;
    if (!controller.foreground) controller.clear();
  }

  @override
  void dispose() {
    _timer?.cancel();
    controller.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notice = controller.value;
    return Stack(children: [
      widget.child,
      Positioned(
          left: 0,
          right: 0,
          top: 10,
          child: SafeArea(
              bottom: false,
              minimum: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Align(
                  alignment: Alignment.topCenter,
                  child: AnimatedSwitcher(
                      duration: AppMotion.duration(context, AppMotion.panel),
                      reverseDuration:
                          AppMotion.duration(context, AppMotion.feedback),
                      transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                              position: Tween<Offset>(
                                      begin: const Offset(0, -.45),
                                      end: Offset.zero)
                                  .animate(CurvedAnimation(
                                      parent: animation,
                                      curve: AppMotion.curve)),
                              child: child)),
                      // Departing cards never intercept taps or expose stale replies.
                      layoutBuilder: (current, previous) =>
                          Stack(alignment: Alignment.topCenter, children: [
                            for (final child in previous)
                              ExcludeSemantics(
                                  child: IgnorePointer(child: child)),
                            if (current != null) current,
                          ]),
                      child: notice == null
                          ? const SizedBox.shrink()
                          : ConstrainedBox(
                              key: ObjectKey(notice),
                              constraints: const BoxConstraints(maxWidth: 560),
                              child: Dismissible(
                                  key: ObjectKey(notice),
                                  direction: DismissDirection.up,
                                  resizeDuration: null,
                                  onDismissed: (_) => controller.clear(notice),
                                  child: MessageBannerCard(
                                      notice: notice,
                                      onReply: () => controller.reply(notice),
                                      onDismiss: () =>
                                          controller.clear(notice))))))))
    ]);
  }
}

class MessageBannerCard extends StatelessWidget {
  const MessageBannerCard(
      {super.key,
      required this.notice,
      required this.onReply,
      required this.onDismiss});
  final MessageNotice notice;
  final VoidCallback onReply, onDismiss;

  @override
  Widget build(BuildContext context) => Semantics(
      liveRegion: true,
      customSemanticsActions: {
        const CustomSemanticsAction(label: '收起通知'): onDismiss
      },
      child: Material(
          key: const ValueKey('message-banner-card'),
          color: Colors.white,
          elevation: 10,
          shadowColor: const Color(0x40212D46),
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
              onTap: onReply,
              child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 7),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      SizedBox(
                          width: 54,
                          height: 54,
                          child: Stack(children: [
                            if (notice.preview)
                              ClipOval(
                                  child: AccountAvatar(
                                      accountId: notice.peerId,
                                      avatarId: notice.avatarId,
                                      revision: notice.avatarRevision,
                                      preferCurrent: true,
                                      size: 52))
                            else
                              const CircleAvatar(
                                  radius: 26,
                                  backgroundColor: Color(0xFFECF3FF),
                                  child: Icon(Icons.cast_rounded,
                                      color: AppTheme.accent)),
                            if (notice.preview)
                              Positioned(
                                  right: 0,
                                  bottom: 0,
                                  child: Container(
                                      width: 19,
                                      height: 19,
                                      decoration: BoxDecoration(
                                          color: AppTheme.accent,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                              color: Colors.white, width: 2)),
                                      child: const Icon(
                                          Icons.chat_bubble_rounded,
                                          size: 10,
                                          color: Colors.white))),
                          ])),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                            Text(notice.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.text)),
                            const SizedBox(height: 4),
                            Text(notice.summary,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 14,
                                    height: 1.3,
                                    color: AppTheme.muted)),
                          ])),
                      const SizedBox(width: 12),
                      TextButton(
                          onPressed: onReply,
                          style: TextButton.styleFrom(
                              minimumSize: const Size(64, 44),
                              backgroundColor: const Color(0xFFECF3FF),
                              foregroundColor: AppTheme.accent,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(13))),
                          child: const Text('回复',
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.w700))),
                    ]),
                    const SizedBox(height: 10),
                    Container(
                        width: 28,
                        height: 3,
                        decoration: BoxDecoration(
                            color: const Color(0xFFD4D7DD),
                            borderRadius: BorderRadius.circular(2))),
                  ])))));
}
