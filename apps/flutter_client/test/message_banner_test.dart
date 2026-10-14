import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/app_theme.dart';
import 'package:remotescreen/friend_calls.dart';
import 'package:remotescreen/home_screen.dart';
import 'package:remotescreen/message_banner.dart';
import 'device_navigation_test.dart' show DeviceManager;

MessageNotice notice(String text,
        {String account = 'me',
        bool preview = true,
        VoidCallback? reply,
        String name = '测试小夏',
        int? receivedAt,
        int? sentAt}) =>
    MessageNotice.fromMap({
      'accountId': account,
      'peerId': 'peer',
      'name': name,
      'message': text,
      'avatarId': 'dog',
      'preview': preview,
      'sentAt':
          '${sentAt ?? DateTime.now().copyWith(hour: 12, minute: 34).millisecondsSinceEpoch}',
      if (receivedAt != null) 'receivedAt': '$receivedAt',
    }, reply ?? () {});

Widget host(MessageBannerController controller,
        {bool reduced = false,
        double scale = 1,
        Widget? home,
        ThemeData? theme,
        GlobalKey<NavigatorState>? navigator}) =>
    RepaintBoundary(
        key: const ValueKey('banner-preview'),
        child: MaterialApp(
            navigatorKey: navigator,
            debugShowCheckedModeBanner: false,
            theme: theme ?? AppTheme.light,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                    padding: const EdgeInsets.only(top: 28),
                    disableAnimations: reduced,
                    textScaler: TextScaler.linear(scale)),
                child:
                    MessageBannerHost(controller: controller, child: child!)),
            home: home ?? const Scaffold(body: Center(child: Text('当前页面')))));

void main() {
  test('发送时间使用本地绝对时间，跨日跨年保留日期，不冒充接收时间', () {
    final now = DateTime(2026, 10, 14, 15);
    expect(
        messageSentTime(DateTime(2026, 10, 14, 12, 34).millisecondsSinceEpoch,
            now: now),
        '12:34');
    expect(
        messageSentTime(DateTime(2026, 10, 13, 12, 34).millisecondsSinceEpoch,
            now: now),
        '10/13 12:34');
    expect(
        messageSentTime(DateTime(2025, 10, 13, 12, 34).millisecondsSinceEpoch,
            now: now),
        '2025/10/13 12:34');
    for (final at in [null, 0, -1, 8640000000000001]) {
      expect(messageSentTime(at, now: now), '时间未知');
    }
  });

  test('忽略其他账号、后台、过期通知；旧卡片不能误触当前回复', () {
    final c = MessageBannerController()..bind('me');
    addTearDown(c.dispose);
    var replies = 0;
    final old = notice('旧消息', reply: () => replies++);
    c.show(old);
    c.show(notice('另一账号', account: 'other'));
    expect(c.value, same(old));
    c.show(notice('已过期',
        receivedAt: DateTime.now().millisecondsSinceEpoch - 9000));
    expect(c.value, same(old));
    final latest = notice('新消息', reply: () => replies++);
    c.show(latest);
    c.reply(old);
    expect(replies, 0);
    expect(c.value, same(latest));
    c.bind('other');
    c.reply(latest);
    expect(replies, 0);
    expect(c.value, isNull);
    c.foreground = false;
    c.show(notice('后台消息', account: 'other'));
    expect(c.value, isNull);
    c.unbind('me');
    c.foreground = true;
    c.show(notice('新账号', account: 'other'));
    expect(c.value!.message, '新账号');
  });

  for (final reduced in [false, true]) {
    testWidgets('安全区域顶部卡片跨页面显示，点击回复一次（减少动态=$reduced）', (tester) async {
      final c = MessageBannerController()..bind('me');
      final navigator = GlobalKey<NavigatorState>();
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(host(c, reduced: reduced, navigator: navigator));
      navigator.currentState!.push(MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Center(child: Text('另一个聊天页面')))));
      await tester.pumpAndSettle();
      var replies = 0;
      c.show(notice('111', reply: () => replies++));
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('message-banner-card'));
      expect(tester.getTopLeft(card).dy, greaterThanOrEqualTo(28));
      expect(tester.getBottomRight(card).dy, lessThan(180));
      expect(find.text('私信了你：111'), findsOneWidget);
      expect(find.text('12:34'), findsOneWidget);
      final time =
          tester.getRect(find.byKey(const ValueKey('message-banner-time')));
      final avatar = tester.getRect(find.byType(Image).first);
      expect(time.right, greaterThan(avatar.right + 100));
      expect(time.bottom, greaterThan(avatar.center.dy));
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('另一个聊天页面'), findsOneWidget);
      await tester.tap(find.text('回复'));
      await tester.pumpAndSettle();
      expect(replies, 1);
      expect(card, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('连续消息替换并重新计时，隐藏内容不泄露发送人头像', (tester) async {
    final c = MessageBannerController()..bind('me');
    addTearDown(c.dispose);
    await tester.pumpWidget(host(c));
    c.show(notice('第一条'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    c.show(notice('敏感内容', name: '敏感联系人', preview: false));
    await tester.pumpAndSettle();
    expect(find.text('第一条'), findsNothing);
    expect(find.text('敏感联系人'), findsNothing);
    expect(find.textContaining('敏感内容'), findsNothing);
    expect(find.text('RemoteScreen'), findsOneWidget);
    expect(find.text('收到新消息'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(seconds: 3));
    expect(c.value, isNotNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(c.value, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('窄屏大字号保留跨年发送时间，时间始终贴近右下角', (tester) async {
    final c = MessageBannerController()..bind('me');
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(host(c, scale: 1.8));
    c.show(notice('正文',
        sentAt: DateTime(2025, 10, 13, 12, 34).millisecondsSinceEpoch));
    await tester.pumpAndSettle();
    expect(find.text('2025/10/13\n12:34'), findsOneWidget);
    final card =
        tester.getRect(find.byKey(const ValueKey('message-banner-card')));
    final stamp =
        tester.getRect(find.byKey(const ValueKey('message-banner-time')));
    expect(stamp.right, closeTo(card.right - 16, 1));
    expect(stamp.bottom, lessThan(card.bottom));
    expect(tester.takeException(), isNull);
    c.show(notice('无时间消息', sentAt: 0));
    await tester.pumpAndSettle();
    expect(find.text('时间未知'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('长文与大字号不溢出；上滑和切后台立即收起', (tester) async {
    final c = MessageBannerController()..bind('me');
    addTearDown(c.dispose);
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(host(c, scale: 1.8));
    c.show(notice('长内容' * 80, name: '非常长的昵称' * 8));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.drag(find.byKey(const ValueKey('message-banner-card')),
        const Offset(0, -220));
    await tester.pumpAndSettle();
    expect(c.value, isNull);
    c.show(notice('新消息'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(c.value, isNull);
    c.show(notice('后台消息'));
    expect(c.value, isNull);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('后台消息'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('真实首页顶部消息卡片视觉预览', (tester) async {
    final fontPath = Platform.environment['HOME_FONT'];
    final iconPath = Platform.environment['MATERIAL_ICON_FONT'];
    await tester.runAsync(() async {
      for (final entry in [
        (fontPath, 'MessagePreview'),
        (iconPath, 'MaterialIcons')
      ]) {
        if (entry.$1 != null) {
          final bytes = await File(entry.$1!).readAsBytes();
          await (FontLoader(entry.$2)
                ..addFont(Future.value(bytes.buffer.asByteData())))
              .load();
        }
      }
    });
    final theme = AppTheme.light;
    final previewTheme = fontPath == null
        ? theme
        : theme.copyWith(
            textTheme: theme.textTheme.apply(fontFamily: 'MessagePreview'),
            primaryTextTheme:
                theme.primaryTextTheme.apply(fontFamily: 'MessagePreview'));
    final oldShadows = debugDisableShadows;
    debugDisableShadows = false;
    addTearDown(() {
      debugDisableShadows = oldShadows;
    });
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final manager = DeviceManager();
    addTearDown(() async {
      await friendCalls.logout();
      manager.dispose();
      messageBanners.unbind('me');
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(host(messageBanners,
        theme: previewTheme,
        home: HomeScreen(
            account:
                Account(id: 'me', name: '钢门吹雪', email: 'test@example.invalid'),
            manager: manager,
            onLogout: () {})));
    await tester.pumpAndSettle();
    messageBanners.show(notice('111'));
    await tester.pumpAndSettle();
    expect(find.text('私信了你：111'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(tester.takeException(), isNull);
    final output = Platform.environment['BANNER_PREVIEW_DIR'];
    if (output != null) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('banner-preview')));
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('$output/mobile-top-message.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await friendCalls.logout();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDisableShadows = oldShadows;
  });
}
