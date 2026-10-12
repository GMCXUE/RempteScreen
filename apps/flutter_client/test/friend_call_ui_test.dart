import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/friend_calls.dart';
import 'package:remotescreen/call_controller.dart';
import 'package:livekit_client/livekit_client.dart' show Room;

void main() {
  for (final kind in ['video', 'voice']) {
    testWidgets('$kind 没有悬浮窗权限时收起和返回键都引导授权，并保留通话页面', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final room = Room();
      final media = CallController(room, friendCall: true);
      friendCalls.media = media;
      friendCalls.current = {
        'id': 'permission-test',
        'peerName': '测试好友',
        'kind': kind,
        'status': 'active'
      };
      await tester.pumpWidget(MaterialApp(
          navigatorKey: appNavigatorKey,
          home: const Scaffold(body: Text('聊天页'))));
      friendCalls.openScreen();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起通话'));
      await tester.pumpAndSettle();
      expect(find.text('开启悬浮窗'), findsOneWidget);
      expect(find.text('去授权'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(friendCalls.screenVisible, true);
      expect(find.byType(FriendCallScreen), findsOneWidget);
      await appNavigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('开启悬浮窗'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(friendCalls.screenVisible, true);
      friendCalls.media = null;
      friendCalls.current = null;
      await friendCalls.toggleSpeaker();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      media.close();
      await tester.runAsync(() => room.dispose());
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('来电头像、名称及接通挂断图标同排，接通后卡片消失', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    friendCalls.current = {
      'id': 'incoming-ui',
      'peerName': '测试好友',
      'peerAvatarId': 'penguin',
      'role': 'callee',
      'kind': 'video',
      'status': 'ringing'
    };
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => FriendCallOverlay(child: child!),
        home: const Scaffold(body: Text('聊天页'))));
    final answer = find.byKey(const ValueKey('incoming-call-answer'));
    final hangup = find.byKey(const ValueKey('incoming-call-hangup'));
    expect(find.text('视频来电'), findsOneWidget);
    expect(find.text('接通'), findsNothing);
    expect(find.text('挂断'), findsNothing);
    expect(tester.getCenter(answer).dx, lessThan(tester.getCenter(hangup).dx));
    expect(tester.getCenter(answer).dx, greaterThan(260));
    final avatar = find.byKey(const ValueKey('incoming-call-avatar'));
    expect(tester.getSize(avatar), const Size(44, 44));
    expect(
        tester.getCenter(answer).dy, closeTo(tester.getCenter(avatar).dy, .1));
    expect(
        tester.getCenter(hangup).dy, closeTo(tester.getCenter(avatar).dy, .1));
    expect(tester.getBottomLeft(answer).dy - tester.getTopLeft(avatar).dy,
        lessThanOrEqualTo(48));
    expect(tester.getSize(answer).width, lessThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(320, 568);
    friendCalls.current = {...friendCalls.current!, 'peerName': '名称很长的测试好友名称'};
    await friendCalls.toggleSpeaker();
    await tester.pumpAndSettle();
    expect(
        tester.getTopLeft(avatar).dx, lessThan(tester.getTopLeft(answer).dx));
    expect(tester.getBottomRight(hangup).dx, lessThan(320));
    expect(
        tester.getCenter(answer).dy, closeTo(tester.getCenter(avatar).dy, .1));
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(390, 844);
    friendCalls.current = {...friendCalls.current!, 'status': 'active'};
    await friendCalls.toggleSpeaker();
    await tester.pumpAndSettle();
    expect(find.text('视频来电'), findsNothing);
    expect(answer, findsNothing);
    expect(find.textContaining('返回通话'), findsNothing);
    expect(find.byKey(const ValueKey('friend-call-mini')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('friend-call-mini'))),
        const Size(120, 160));
    friendCalls.current = null;
    await friendCalls.toggleSpeaker();
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('展开通话不显示顶部横幅，收起后仅保留返回入口，结束回到聊天', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    friendCalls.current = {
      'id': 'ui-test',
      'peerName': '测试好友',
      'kind': 'voice',
      'status': 'active',
      'acceptedAt': DateTime.now().millisecondsSinceEpoch
    };
    await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        builder: (context, child) => FriendCallOverlay(child: child!),
        home: const Scaffold(body: Center(child: Text('聊天页')))));
    friendCalls.openScreen();
    await tester.pumpAndSettle();
    expect(find.text('测试好友'), findsOneWidget);
    expect(find.textContaining('返回通话'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('收起通话'));
    await tester.pumpAndSettle();
    expect(find.text('聊天页'), findsOneWidget);
    expect(find.textContaining('返回通话'), findsOneWidget);
    expect(find.byIcon(Icons.call_end_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.textContaining('返回通话')).dy, greaterThan(600));
    await tester.tap(find.textContaining('返回通话'));
    await tester.pumpAndSettle();
    friendCalls.current = null;
    await friendCalls.toggleSpeaker();
    await tester.pumpAndSettle();
    expect(find.text('聊天页'), findsOneWidget);
    expect(find.textContaining('返回通话'), findsNothing);
    expect(find.byIcon(Icons.call_end_rounded), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('视频通话页面结束后关闭全屏画面和双方小窗', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    friendCalls.current = {
      'id': 'video-ui-test',
      'peerName': '测试好友',
      'kind': 'video',
      'status': 'active',
      'acceptedAt': DateTime.now().millisecondsSinceEpoch,
    };
    await tester.pumpWidget(MaterialApp(
        navigatorKey: appNavigatorKey,
        builder: (context, child) => FriendCallOverlay(child: child!),
        home: const Scaffold(body: Text('聊天页'))));
    friendCalls.openScreen();
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('friend-video-main'))),
        const Size(390, 844));
    expect(find.byKey(const ValueKey('friend-video-preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final size in [
      const Size(390, 844),
      const Size(320, 568),
      const Size(844, 390),
    ]) {
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
      final hangup = tester.getRect(find.byTooltip('挂断'));
      final camera = tester.getRect(find.byTooltip('打开摄像头'));
      expect(hangup.top, greaterThan(camera.bottom));
      expect(hangup.center.dx, closeTo(size.width / 2, .1));
      expect(hangup.width, greaterThan(camera.width));
      final preview =
          tester.getRect(find.byKey(const ValueKey('friend-video-preview')));
      for (final label in ['取消静音', '打开摄像头', '打开声音', '挂断']) {
        final rect = tester.getRect(find.byTooltip(label));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(size.width));
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(rect.overlaps(preview), isFalse);
      }
      expect(tester.takeException(), isNull);
    }
    friendCalls.current = null;
    await friendCalls.toggleSpeaker();
    await tester.pumpAndSettle();
    expect(find.text('聊天页'), findsOneWidget);
    expect(find.byKey(const ValueKey('friend-video-preview')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
