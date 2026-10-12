import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/friend_video_stage.dart';

void main() {
  testWidgets('摄像头渲染器的点击对焦手势不抢占小窗交换和控制栏', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var focusTaps = 0;
    // LiveKit wraps mobile local video in tap-to-focus and scale recognizers.
    final local = GestureDetector(
        onTapDown: (_) => focusTaps++,
        onScaleStart: (_) {},
        onScaleUpdate: (_) {},
        child: const ColoredBox(
            key: ValueKey('interactive-local-feed'), color: Colors.green));
    const remote = ColoredBox(
        key: ValueKey('interactive-remote-feed'), color: Colors.blue);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FriendVideoStage(
                peerName: '测试好友',
                status: '2:42',
                onFold: () {},
                remoteView: remote,
                localView: local,
                controls: const SizedBox(height: 70)))));
    final localFeed = find.byKey(const ValueKey('interactive-local-feed'));
    final remoteFeed = find.byKey(const ValueKey('interactive-remote-feed'));
    await tester.tapAt(tester.getCenter(localFeed));
    await tester.pumpAndSettle();
    expect(tester.getSize(localFeed), const Size(390, 844));
    expect(tester.getSize(remoteFeed), const Size(112, 150));
    expect(focusTaps, 0);
    await tester.tapAt(const Offset(150, 350));
    await tester.pumpAndSettle();
    expect(find.text('显示控制栏'), findsOneWidget);
    expect(focusTaps, 0);
    await tester.tapAt(tester.getCenter(remoteFeed));
    await tester.pumpAndSettle();
    expect(tester.getSize(remoteFeed), const Size(390, 844));
    expect(find.text('显示控制栏'), findsOneWidget);
    await tester.tapAt(tester.getCenter(localFeed));
    await tester.pumpAndSettle();
    expect(tester.getSize(localFeed), const Size(390, 844));
    expect(focusTaps, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('视频铺满屏幕，点小窗交换双方，隐藏控制栏不移除视频', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var commands = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: FriendVideoStage(
                peerName: '测试好友',
                status: '2:42',
                onFold: () => commands++,
                remoteView: const ColoredBox(
                    key: ValueKey('remote-feed'), color: Colors.blue),
                localView: const ColoredBox(
                    key: ValueKey('local-feed'), color: Colors.green),
                controls: TextButton(
                    onPressed: () => commands++, child: const Text('挂断'))))));
    final remote = find.byKey(const ValueKey('remote-feed'));
    final local = find.byKey(const ValueKey('local-feed'));
    expect(tester.getRect(remote), const Rect.fromLTWH(0, 0, 390, 844));
    expect(tester.getSize(local), const Size(112, 150));
    await tester.tap(find.byKey(const ValueKey('friend-video-preview')));
    await tester.pumpAndSettle();
    expect(tester.getRect(local), const Rect.fromLTWH(0, 0, 390, 844));
    expect(tester.getSize(remote), const Size(112, 150));
    expect(commands, 0, reason: '交换画面不发送媒体或挂断操作');
    await tester.tap(find.text('隐藏控制栏'));
    await tester.pumpAndSettle();
    expect(find.text('显示控制栏'), findsOneWidget);
    expect(tester.getSize(local), const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('friend-video-preview')));
    await tester.pumpAndSettle();
    expect(tester.getSize(remote), const Size(390, 844));
    expect(find.text('显示控制栏'), findsOneWidget);
    expect(commands, 0);
    await tester.tapAt(const Offset(150, 350));
    await tester.pumpAndSettle();
    expect(find.text('显示控制栏'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text('显示控制栏'), findsOneWidget);
    expect(commands, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('等待接听不自动隐藏操作，横竖屏小窗均不超出屏幕', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final size in [const Size(320, 568), const Size(844, 390)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: FriendVideoStage(
                  canHide: false,
                  peerName: '名字比较长的测试好友',
                  status: '等待对方接听',
                  onFold: () {},
                  remoteView: const ColoredBox(color: Colors.blue),
                  localView: const ColoredBox(color: Colors.green),
                  controls: const SizedBox(height: 70, child: Text('接通'))))));
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('显示控制栏'), findsNothing);
      final bounds =
          tester.getRect(find.byKey(const ValueKey('friend-video-preview')));
      expect(bounds.right, lessThanOrEqualTo(size.width));
      expect(bounds.bottom, lessThanOrEqualTo(size.height));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
