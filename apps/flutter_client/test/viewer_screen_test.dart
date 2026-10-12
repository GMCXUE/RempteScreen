import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:remotescreen/call_controller.dart';
import 'package:remotescreen/session_manager.dart';
import 'package:remotescreen/viewer_screen.dart';
import 'package:remotescreen/viewer_chrome.dart';
import 'package:remotescreen/viewer_viewport.dart';

class _Call extends ChangeNotifier implements CallController {
  @override
  bool busy = false;
  @override
  bool screenAudioEnabled = true;
  @override
  bool speakerEnabled = true;
  @override
  bool microphoneEnabled = false;
  @override
  lk.RemoteVideoTrack? get remoteCameraTrack => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements ViewingSession {
  @override
  final id = 'watch';
  @override
  final deviceName = '测试设备';
  @override
  final call = _Call();
  @override
  ViewingSessionState state = ViewingSessionState.live;
  @override
  bool endedByPeer = false;
  @override
  lk.RemoteVideoTrack? get videoTrack => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Manager extends ChangeNotifier implements SessionManager {
  final session = _Session();
  int disconnects = 0;
  @override
  ViewingSession? sessionById(String id) => session;
  @override
  Future<void> disconnectSession(String id) async {
    disconnects++;
    session.state = ViewingSessionState.ended;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final nativeCalls = <MethodCall>[];
  final platformCalls = <MethodCall>[];
  Completer<void>? pendingEnter;
  setUp(() {
    nativeCalls.clear();
    platformCalls.clear();
    pendingEnter = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      platformCalls.add(call);
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('remotescreen/native'),
            (call) async {
      nativeCalls.add(call);
      if (call.arguments['enabled'] == true && pendingEnter != null) {
        await pendingEnter!.future;
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), null);
  });

  Future<GlobalKey<NavigatorState>> open(
      WidgetTester tester, _Manager manager) async {
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: key, home: const Scaffold(body: Text('会话列表'))));
    key.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => ViewerScreen(manager: manager, sessionId: 'watch')));
    await tester.pumpAndSettle();
    return key;
  }

  testWidgets('自动收起与点按恢复不改变媒体，窄屏和横屏不溢出', (tester) async {
    final manager = _Manager();
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, manager);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byTooltip('展开控制栏').hitTestable(), findsOneWidget);
    expect(manager.disconnects, 0);
    expect(manager.session.call.screenAudioEnabled, isTrue);
    expect(manager.session.call.speakerEnabled, isTrue);
    await tester.tap(find.byKey(const ValueKey('viewer-stage')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('收起控制栏').hitTestable(), findsOneWidget);
    tester.view.physicalSize = const Size(700, 320);
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    manager.dispose();
  });

  testWidgets('全屏返回先退出全屏，退出观看不切断会话', (tester) async {
    final manager = _Manager();
    final key = await open(tester, manager);
    await tester.tap(find.byTooltip('全屏').hitTestable());
    await tester.pumpAndSettle();
    expect(nativeCalls.last.arguments, {'enabled': true});
    await key.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsOneWidget);
    expect(nativeCalls.last.arguments, {'enabled': false});
    await key.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(find.text('会话列表'), findsOneWidget);
    expect(manager.disconnects, 0);
    manager.dispose();
  });

  testWidgets('全屏时对端结束仍能自动退出并恢复系统栏', (tester) async {
    final manager = _Manager();
    await open(tester, manager);
    await tester.tap(find.byTooltip('全屏').hitTestable());
    await tester.pumpAndSettle();
    manager.session.endedByPeer = true;
    manager.session.state = ViewingSessionState.ended;
    manager.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsNothing);
    expect(find.text('测试设备 已停止投送'), findsOneWidget);
    expect(nativeCalls.last.arguments, {'enabled': false});
    manager.dispose();
  });

  test('横向全屏请求横屏，退出后解除方向限制并恢复系统栏', () async {
    await ViewerViewport.setFullscreen(true, landscape: true);
    await ViewerViewport.setFullscreen(false);
    final orientations = platformCalls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(orientations[0].arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight'
    ]);
    expect(orientations[1].arguments, isEmpty);
    expect(nativeCalls.map((c) => c.arguments['enabled']), [true, false]);
  });

  testWidgets('进入全屏尚未返回时也能退出，迟到的回调不能改回全屏', (tester) async {
    final manager = _Manager();
    final key = await open(tester, manager);
    pendingEnter = Completer<void>();
    await tester.tap(find.byTooltip('全屏').hitTestable());
    await tester.pump();
    await key.currentState!.maybePop();
    await tester.pumpAndSettle();
    expect(nativeCalls.last.arguments, {'enabled': false});
    pendingEnter!.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ViewerScreen), findsOneWidget);
    expect(find.byTooltip('全屏').hitTestable(), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    manager.dispose();
  });

  testWidgets('收起后摄像头保留，快捷全屏入口可用', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ViewerChrome(
      title: '设备',
      status: '正在观看',
      live: true,
      visible: false,
      fullscreen: false,
      onToggleControls: () {},
      onFullscreen: () {},
      onBack: () {},
      onDisconnect: () {},
      controls: const [],
      camera: const ColoredBox(key: ValueKey('camera'), color: Colors.blue),
      child: const ColoredBox(color: Colors.black),
    ))));
    expect(find.byKey(const ValueKey('camera')).hitTestable(), findsOneWidget);
    expect(find.byTooltip('全屏').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
