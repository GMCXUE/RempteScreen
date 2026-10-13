import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/friend_video_stage.dart';
import 'package:remotescreen/viewer_chrome.dart';

class _MediaProbe extends StatefulWidget {
  const _MediaProbe(
      {super.key, required this.onCreate, required this.onDispose});
  final VoidCallback onCreate, onDispose;

  @override
  State<_MediaProbe> createState() => _MediaProbeState();
}

class _MediaProbeState extends State<_MediaProbe> {
  @override
  void initState() {
    super.initState();
    widget.onCreate();
  }

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.blue, child: SizedBox.expand());
}

Widget _host(Widget child, {required bool reduced}) => MaterialApp(
      builder: (context, page) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
        child: page!,
      ),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('双方视频快速交换与收起控制栏保留双GlobalKey渲染器直到真正退出', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final remoteKey = GlobalKey<_MediaProbeState>();
    final localKey = GlobalKey<_MediaProbeState>();
    var remoteCreates = 0, remoteDisposes = 0;
    var localCreates = 0, localDisposes = 0, mediaCommands = 0;
    Widget screen(bool reduced) => _host(
        FriendVideoStage(
            peerName: '好友',
            status: '通话中',
            onFold: () => mediaCommands++,
            // Match production FriendCallScreen's persistent renderer keys.
            remoteView: _MediaProbe(
                key: remoteKey,
                onCreate: () => remoteCreates++,
                onDispose: () => remoteDisposes++),
            localView: _MediaProbe(
                key: localKey,
                onCreate: () => localCreates++,
                onDispose: () => localDisposes++),
            controls: TextButton(
                onPressed: () => mediaCommands++, child: const Text('挂断'))),
        reduced: reduced);

    await tester.pumpWidget(screen(false));
    final remoteState = remoteKey.currentState;
    final localState = localKey.currentState;
    final preview = find.byKey(const ValueKey('friend-video-preview'));
    final anchor = tester.getRect(preview);
    for (var index = 0; index < 10; index++) {
      await tester.tap(preview);
      await tester.pump(const Duration(milliseconds: 16));
      expect(tester.getSize(find.byKey(index.isEven ? localKey : remoteKey)),
          const Size(390, 844));
      await tester.tapAt(const Offset(150, 350));
      await tester.pump(const Duration(milliseconds: 30));
      expect(find.text('挂断').hitTestable(), findsNothing);
      expect(tester.getRect(preview), anchor);

      // Toggle the OS preference during an unfinished control-bar fade.
      await tester.pumpWidget(screen(index.isEven));
      expect(find.text('挂断').hitTestable(), findsNothing);
      expect(tester.getRect(preview), anchor);
      expect(remoteKey.currentState, same(remoteState));
      expect(localKey.currentState, same(localState));
      expect(find.byKey(remoteKey), findsOneWidget);
      expect(find.byKey(localKey), findsOneWidget);
      expect(remoteCreates, 1);
      expect(localCreates, 1);
      expect(remoteDisposes + localDisposes, 0);
      expect(tester.takeException(), isNull);

      await tester.tapAt(const Offset(150, 350));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('挂断').hitTestable(), findsNothing);
    expect(remoteKey.currentState, same(remoteState));
    expect(localKey.currentState, same(localState));
    expect(remoteDisposes + localDisposes, 0);
    expect(mediaCommands, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(remoteDisposes, 1);
    expect(localDisposes, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('投屏控制栏反复隐藏和减少动态切换不重建媒体或移动预览锚点', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final screenKey = GlobalKey<_MediaProbeState>();
    final cameraKey = GlobalKey<_MediaProbeState>();
    var screenCreates = 0, screenDisposes = 0;
    var cameraCreates = 0, cameraDisposes = 0, mediaCommands = 0;
    Widget viewer(bool visible, bool reduced) => _host(
        ViewerChrome(
            title: '观看设备',
            status: '已连接',
            live: true,
            visible: visible,
            fullscreen: false,
            onToggleControls: () {},
            onFullscreen: () => mediaCommands++,
            onBack: () => mediaCommands++,
            onDisconnect: () => mediaCommands++,
            controls: [
              Expanded(
                  child: TextButton(
                      onPressed: () => mediaCommands++,
                      child: const Text('媒体操作')))
            ],
            camera: _MediaProbe(
                key: cameraKey,
                onCreate: () => cameraCreates++,
                onDispose: () => cameraDisposes++),
            child: _MediaProbe(
                key: screenKey,
                onCreate: () => screenCreates++,
                onDispose: () => screenDisposes++)),
        reduced: reduced);

    await tester.pumpWidget(viewer(true, false));
    final screenState = screenKey.currentState;
    final cameraState = cameraKey.currentState;
    final mainBounds = tester.getRect(find.byKey(screenKey));
    final previewBounds = tester.getRect(find.byKey(cameraKey));
    for (var index = 0; index < 12; index++) {
      final visible = index.isOdd;
      await tester.pumpWidget(viewer(visible, index % 3 == 0));
      await tester.pump(const Duration(milliseconds: 24));
      expect(tester.getRect(find.byKey(screenKey)), mainBounds);
      expect(tester.getRect(find.byKey(cameraKey)), previewBounds);
      expect(screenKey.currentState, same(screenState));
      expect(cameraKey.currentState, same(cameraState));
      if (!visible) {
        expect(find.text('媒体操作').hitTestable(), findsNothing);
        expect(find.byTooltip('断开投屏').hitTestable(), findsNothing);
      }
      expect(screenCreates, 1);
      expect(cameraCreates, 1);
      expect(screenDisposes + cameraDisposes, 0);
      expect(tester.takeException(), isNull);
    }
    expect(mediaCommands, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(screenDisposes, 1);
    expect(cameraDisposes, 1);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  });
}
