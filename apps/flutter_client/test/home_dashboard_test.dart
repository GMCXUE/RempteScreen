import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/app_theme.dart';
import 'package:remotescreen/home_dashboard.dart';

void main() {
  testWidgets('首页在窄屏和大字体下可连接、进入设备及传输，更新状态保留草稿', (tester) async {
    final fontPath = Platform.environment['HOME_FONT'];
    final iconPath = Platform.environment['MATERIAL_ICON_FONT'];
    await tester.runAsync(() async {
      for (final entry in [
        (fontPath, 'HomePreview'),
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
            textTheme: theme.textTheme.apply(fontFamily: 'HomePreview'),
            primaryTextTheme:
                theme.primaryTextTheme.apply(fontFamily: 'HomePreview'),
            appBarTheme: theme.appBarTheme.copyWith(
                titleTextStyle: theme.appBarTheme.titleTextStyle
                    ?.copyWith(fontFamily: 'HomePreview')));
    final code = TextEditingController(), password = TextEditingController();
    addTearDown(code.dispose);
    addTearDown(password.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final boundaryKey = GlobalKey();
    var connections = 0, files = 0, devices = 0, casts = 0;
    Widget screen(
            {double scale = 1,
            bool busy = false,
            bool publishing = false,
            bool live = false}) =>
        MaterialApp(
            theme: previewTheme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: RepaintBoundary(
                key: boundaryKey,
                child: Scaffold(
                    appBar: AppBar(
                        toolbarHeight: 56,
                        automaticallyImplyLeading: false,
                        titleSpacing: 18,
                        title: const Text('首页'),
                        actions: [
                          IconButton(
                              onPressed: () {}, icon: const Icon(Icons.refresh))
                        ]),
                    body: HomeDashboard(
                      account: Account(
                          id: 'me', email: 'me@example.test', name: '钢门吹雪'),
                      connection: HomeConnectCard(
                          deviceId: code,
                          password: password,
                          busy: busy,
                          onConnect: () => connections++),
                      deviceCount: 3,
                      onlineCount: 2,
                      deviceName: '钢门吹雪 的 Android',
                      publishing: publishing,
                      ready: true,
                      onRefresh: () async {},
                      onProfile: () {},
                      onFiles: () => files++,
                      onDevices: () => devices++,
                      onCast: () => casts++,
                      sessions: live
                          ? const Card(
                              child: Padding(
                                  padding: EdgeInsets.all(18),
                                  child: Text('继续观看 Mac')))
                          : null,
                    ))));
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(screen());
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '522 952 991');
    await tester.enterText(
        find.byType(TextField).last, 'custom-password-123456');
    expect(code.text, '522952991');
    final connect = find.widgetWithText(FilledButton, '连接设备');
    await tester.tap(connect);
    await tester.pump();
    expect(connections, 1);
    if (Platform.environment['HOME_SCREENSHOT'] case final String path) {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await tester.pumpAndSettle();
      final boundary = boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(path).writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    for (final size in [const Size(320, 680), const Size(600, 740)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(screen(scale: 1.4, publishing: true));
      await tester.pumpAndSettle();
      expect(code.text, '522952991');
      expect(password.text, 'custom-password-123456');
      for (final label in ['文件传输', '我的设备', '管理投屏']) {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    }
    expect(files, 2);
    expect(devices, 2);
    expect(casts, 2);
    await tester.pumpWidget(screen(live: true));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('继续观看 Mac'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('继续观看 Mac')).dy,
        lessThan(tester.getTopLeft(find.text('输入设备代码，开始观看')).dy));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('连接输入保留 64 位自定义密码，处理期间按钮和键盘均不重复连接', (tester) async {
    final code = TextEditingController(), password = TextEditingController();
    addTearDown(code.dispose);
    addTearDown(password.dispose);
    var connections = 0;
    Widget screen(bool busy) => MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
            body: HomeConnectCard(
                deviceId: code,
                password: password,
                busy: busy,
                onConnect: () => connections++)));
    await tester.pumpWidget(screen(false));
    await tester.enterText(find.byType(TextField).first, '1234567890123');
    await tester.enterText(find.byType(TextField).last, 'a' * 64);
    expect(code.text, '123456789');
    expect(password.text.length, 64);
    await tester.pumpWidget(screen(true));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '连接设备'));
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(connections, 0);
    await tester.pumpWidget(screen(false));
    await tester.pump();
    await tester.showKeyboard(find.byType(TextField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(connections, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
