import 'package:flutter/material.dart';
import 'app_motion.dart';

/// Presentation only: hiding chrome never changes a media track or connection.
class ViewerChrome extends StatelessWidget {
  const ViewerChrome({
    super.key,
    required this.child,
    required this.title,
    required this.status,
    required this.live,
    required this.visible,
    required this.fullscreen,
    required this.onToggleControls,
    required this.onFullscreen,
    required this.onBack,
    required this.onDisconnect,
    required this.controls,
    this.camera,
  });

  final Widget child;
  final Widget? camera;
  final String title;
  final String status;
  final bool live, visible, fullscreen;
  final VoidCallback onToggleControls, onFullscreen, onBack, onDisconnect;
  final List<Widget> controls;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).padding;
    final landscape =
        MediaQuery.of(context).size.width > MediaQuery.of(context).size.height;
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          key: const ValueKey('viewer-stage'),
          behavior: HitTestBehavior.opaque,
          onTap: onToggleControls,
          child: child,
        ),
      ),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: _fade(
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xB3000000), Colors.transparent],
              ),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                  padding.left + 12, padding.top + 10, padding.right + 12, 26),
              child: Row(children: [
                ViewerIconButton(
                  icon: Icons.arrow_back_rounded,
                  label: fullscreen ? '退出全屏' : '返回',
                  onPressed: onBack,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Row(children: [
                        Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: live
                                    ? const Color(0xFF4ADE80)
                                    : Colors.white54)),
                        const SizedBox(width: 6),
                        Expanded(
                            child: Text(status,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 11))),
                      ]),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ViewerIconButton(
                    icon: Icons.close_rounded,
                    label: '断开投屏',
                    onPressed: onDisconnect),
              ]),
            ),
          ),
        ),
      ),
      if (camera != null)
        Positioned(
          right: padding.right + 14,
          // Keep the live texture anchored while chrome fades around it.
          top: padding.top + 88,
          width: landscape ? 120 : 112,
          height: landscape ? 90 : 84,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white24),
                borderRadius: BorderRadius.circular(16),
              ),
              child: camera!,
            ),
          ),
        ),
      Positioned(
        left: padding.left + 14,
        right: padding.right + 14,
        bottom: padding.bottom + 12,
        child: _fade(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 500),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xD91A1D24),
                  borderRadius: BorderRadius.circular(24),
                  border:
                      Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Row(children: [
                    ...controls,
                    Container(
                        height: 24,
                        width: 1,
                        color: Colors.white12,
                        margin: const EdgeInsets.symmetric(horizontal: 4)),
                    Expanded(
                        child: ViewerIconButton(
                      icon: fullscreen
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                      label: fullscreen ? '退出全屏' : '全屏',
                      onPressed: onFullscreen,
                      caption: true,
                    )),
                    Expanded(
                        child: ViewerIconButton(
                      icon: Icons.keyboard_arrow_down_rounded,
                      label: '收起控制栏',
                      onPressed: onToggleControls,
                      caption: true,
                      shortLabel: '收起',
                    )),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
      if (!visible)
        Positioned(
          right: padding.right + 14,
          bottom: padding.bottom + 12,
          child: Material(
            color: const Color(0xA61A1D24),
            shape: const StadiumBorder(),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ViewerIconButton(
                  icon: fullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  label: fullscreen ? '退出全屏' : '全屏',
                  onPressed: onFullscreen),
              ViewerIconButton(
                  icon: Icons.tune_rounded,
                  label: '展开控制栏',
                  onPressed: onToggleControls),
            ]),
          ),
        ),
    ]);
  }

  Widget _fade({required Widget child}) => AppVisibilityTransition(
        visible: visible,
        child: child,
      );
}

class ViewerIconButton extends StatelessWidget {
  const ViewerIconButton(
      {super.key,
      required this.icon,
      required this.label,
      required this.onPressed,
      this.active = false,
      this.caption = false,
      this.shortLabel});
  final IconData icon;
  final String label;
  final String? shortLabel;
  final VoidCallback? onPressed;
  final bool active, caption;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: label,
        child: TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            foregroundColor: active ? const Color(0xFF8CBAFF) : Colors.white70,
            disabledForegroundColor: Colors.white30,
            minimumSize: const Size(48, 48),
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: caption ? 22 : 24),
            if (caption) ...[
              const SizedBox(height: 3),
              Text(shortLabel ?? label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10)),
            ],
          ]),
        ),
      );
}
