import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/friend_calls.dart';
import 'package:remotescreen/home_screen.dart';
import 'package:remotescreen/session_manager.dart';

class DeviceApi extends ApiService {
  DeviceApi() : super(baseUrl: 'http://127.0.0.1');
  @override
  Future<List<Device>> listDevices() async => [];
}

class DeviceManager extends SessionManager {
  DeviceManager() : super(api: DeviceApi());
  @override
  Future<DeviceRegistration> registerDevice(
      {required String platform, required String deviceName}) async {
    return registration = DeviceRegistration(
        deviceId: '123456789',
        password: '',
        sessionToken: '',
        roomName: '',
        livekitUrl: '',
        publishToken: '',
        deviceName: deviceName);
  }
}

void main() {
  testWidgets('我的设备消费系统返回；弹窗先关闭；首页保留系统退出行为', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final manager = DeviceManager();
    var exits = 0;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exits++;
      return null;
    });
    addTearDown(() async {
      await friendCalls.logout();
      manager.dispose();
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    await tester.pumpWidget(MaterialApp(
        home: HomeScreen(
            account: Account(
                id: 'navigation-test',
                name: '测试用户',
                email: 'test@example.invalid'),
            manager: manager,
            onLogout: () {})));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('我的设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的设备'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回上一页面'), findsOneWidget);
    final dialog = showDialog<void>(
        context: tester.element(find.byType(HomeScreen)),
        builder: (_) => const AlertDialog(title: Text('测试弹窗')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await dialog;
    expect(find.text('测试弹窗'), findsNothing);
    expect(find.byTooltip('返回上一页面'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byTooltip('返回上一页面'), findsNothing);
    expect(find.text('输入设备代码，开始观看'), findsOneWidget);
    expect(exits, 0);
    await tester.ensureVisible(find.text('我的设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的设备'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('返回上一页面'));
    await tester.pumpAndSettle();
    expect(find.text('输入设备代码，开始观看'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exits, 1);
    await friendCalls.logout();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
