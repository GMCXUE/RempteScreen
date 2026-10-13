import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/app_motion.dart';
import 'package:remotescreen/app_theme.dart';
import 'package:remotescreen/friend_calls.dart';
import 'package:remotescreen/home_screen.dart';

import 'device_navigation_test.dart' show DeviceManager;

class _MotionDeviceApi extends ApiService {
  _MotionDeviceApi() : super(baseUrl: 'http://127.0.0.1');

  @override
  Future<List<Device>> listDevices() async => List.generate(
      12,
      (index) => Device(
          deviceId: '${100000000 + index}',
          name: '测试设备 $index',
          platform: 'android',
          online: true));
}

class _MotionDeviceManager extends DeviceManager {
  final _devicesApi = _MotionDeviceApi();

  @override
  ApiService get api => _devicesApi;
}

Finder _tab(String label) => find.byWidgetPredicate((widget) =>
    widget is Semantics &&
    widget.properties.button == true &&
    widget.properties.label == label);

Finder _list(String name) => find.byKey(PageStorageKey<String>(name));

ScrollableState _scrollable(WidgetTester tester, String name) => tester.state(
    find.descendant(of: _list(name), matching: find.byType(Scrollable)).first);

Finder _input(String label, {bool skipOffstage = true}) =>
    find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
        skipOffstage: skipOffstage);

void main() {
  for (final reduced in [false, true]) {
    testWidgets('快速切换四个页面与我的设备保留滚动和表单（减少动态=$reduced）', (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1;
      final manager = _MotionDeviceManager();
      addTearDown(() async {
        await friendCalls.logout();
        manager.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduced),
              child: child!),
          home: HomeScreen(
              account: Account(
                  id: 'motion-test',
                  name: '动效测试用户',
                  email: 'motion@example.invalid'),
              manager: manager,
              onLogout: () {})));
      await tester.pumpAndSettle();
      await tester.enterText(_input('设备代码'), '987654321');
      await tester.enterText(_input('连接密码（可选）'), 'retained-password');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.drag(_list('home-dashboard'), const Offset(0, -220));
      await tester.pumpAndSettle();
      final homeScroll = _scrollable(tester, 'home-dashboard');
      final homeOffset = homeScroll.position.pixels;
      expect(homeOffset, greaterThan(50));

      for (final label in ['消息', '投屏', '我的', '首页', '我的', '消息', '投屏', '首页']) {
        await tester.tap(_tab(label));
        await tester.pump(const Duration(milliseconds: 18));
        expect(find.byType(HomeScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (label != '首页') {
          final hiddenField = _input('设备代码', skipOffstage: false);
          expect(tester.widget<TextField>(hiddenField).controller!.text,
              '987654321');
          final editable = find.descendant(
              of: hiddenField,
              matching: find.byType(EditableText, skipOffstage: false));
          expect(tester.widget<EditableText>(editable).focusNode.hasFocus,
              isFalse);
        }
        if (reduced) {
          final fade = find.descendant(
              of: find.byType(AppContentTransition),
              matching: find.byType(FadeTransition));
          expect(tester.widget<FadeTransition>(fade.first).opacity.value, 1);
        }
      }
      await tester.pumpAndSettle();
      expect(_scrollable(tester, 'home-dashboard'), same(homeScroll));
      expect(homeScroll.position.pixels, closeTo(homeOffset, .5));
      expect(tester.widget<TextField>(_input('连接密码（可选）')).controller!.text,
          'retained-password');

      await tester.ensureVisible(find.text('我的设备'));
      await tester.pumpAndSettle();
      final beforeDevices = homeScroll.position.pixels;
      await tester.tap(find.text('我的设备'));
      await tester.pumpAndSettle();
      final devicesScroll = _scrollable(tester, 'devices-tab');
      await tester.drag(_list('devices-tab'), const Offset(0, -400));
      await tester.pumpAndSettle();
      final devicesOffset = devicesScroll.position.pixels;
      expect(devicesOffset, greaterThan(100));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(_scrollable(tester, 'home-dashboard'), same(homeScroll));
      expect(homeScroll.position.pixels, closeTo(beforeDevices, .5));
      await tester.tap(find.text('我的设备'));
      await tester.pumpAndSettle();
      expect(_scrollable(tester, 'devices-tab'), same(devicesScroll));
      expect(devicesScroll.position.pixels, closeTo(devicesOffset, .5));
      await tester.tap(_tab('首页'));
      await tester.pumpAndSettle();
      expect(homeScroll.position.pixels, closeTo(beforeDevices, .5));
      expect(tester.takeException(), isNull);

      await friendCalls.logout();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
    });
  }
}
