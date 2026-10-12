import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/account_avatar.dart';
import 'package:remotescreen/account_profile.dart';
import 'package:remotescreen/avatar_crop.dart';

void main() {
  tearDown(clearAvatarProfiles);
  testWidgets('资料保存只提交可编辑字段，失败保留草稿并支持重试', (tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    var attempts = 0;
    Account? result;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                  body: TextButton(
                      onPressed: () async {
                        result = await Navigator.push<Account>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => AccountProfileScreen(
                                    account: Account(
                                        id: 'me',
                                        accountId: '123456',
                                        email: 'me@example.test',
                                        name: '原昵称',
                                        bio: '原简介'))));
                      },
                      child: const Text('编辑'))))));
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), '新昵称');
      await tester.enterText(find.byType(TextFormField).at(1), '新简介');
      await tester.tap(find.text('保存资料'));
      await tester.pumpAndSettle();
      expect(find.text('网络不可用'), findsOneWidget);
      expect(find.text('新昵称'), findsOneWidget);
      expect(result, isNull);
      await tester.tap(find.text('保存资料'));
      await tester.pumpAndSettle();
      expect(result?.name, '新昵称');
      expect(result?.bio, '新简介');
      expect(attempts, 2);
      expect(tester.takeException(), isNull);
    },
        () => MockClient((request) async {
              expect(request.url.path.endsWith('/account-profile'), isTrue);
              final body = jsonDecode(request.body) as Map;
              expect(body.keys.toSet(),
                  {'name', 'bio', 'region', 'gender', 'birthday'});
              if (++attempts == 1) {
                return http.Response(
                    jsonEncode({
                      'error': {'code': 'test', 'message': '网络不可用'}
                    }),
                    503,
                    headers: {'content-type': 'application/json'});
              }
              return http.Response(
                  jsonEncode({
                    'user': {
                      'id': 'me',
                      'accountId': '123456',
                      'email': 'me@example.test',
                      ...body
                    }
                  }),
                  200,
                  headers: {'content-type': 'application/json'});
            }));
  });
  testWidgets('本地照片裁剪输出 256 像素头像，退出动画不使用已释放图片', (tester) async {
    final data = (await tester
        .runAsync(() => rootBundle.load('assets/avatars/fox.png')))!;
    dynamic cropped;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      cropped = await cropAvatarPhoto(
                          context, data.buffer.asUint8List());
                    },
                    child: const Text('选图'))))));
    await tester.tap(find.text('选图'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Slider), const Offset(80, 0));
    await tester.pump();
    await tester.tap(find.text('使用照片'));
    await tester.pumpAndSettle();
    // toImage/toByteData complete on the real engine thread.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pumpAndSettle();
    expect(cropped, isNotNull);
    await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(cropped);
      final output = (await codec.getNextFrame()).image;
      expect(output.width, 256);
      expect(output.height, 256);
      output.dispose();
      codec.dispose();
    });
    expect(tester.takeException(), isNull);
  });
  testWidgets('资料页头像保存成功提示不依赖后续资料刷新', (tester) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    var saves = 0, refreshes = 0;
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: AccountProfileScreen(
              account: Account(
                  id: 'me',
                  accountId: '123456',
                  email: 'me@example.test',
                  name: '测试'))));
      await tester.tap(find.text('更换头像'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('默认头像 3'));
      await tester.pump();
      await tester.tap(find.text('保存头像'));
      await tester.pumpAndSettle();
      expect(find.byType(AvatarPicker), findsNothing);
      expect(find.text('头像已更新'), findsOneWidget);
      expect(avatarProfiles.value['me']?.id, 'fox');
      expect(saves, 1);
      expect(refreshes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('/social/avatar')) {
                saves++;
                expect(jsonDecode(request.body)['avatarId'], 'fox');
                return http.Response(
                    jsonEncode({'avatarId': 'fox', 'avatarRevision': ''}), 200,
                    headers: {'content-type': 'application/json'});
              }
              refreshes++;
              return http.Response(
                  jsonEncode({
                    'error': {'code': 'test', 'message': '暂时无法刷新资料'}
                  }),
                  503,
                  headers: {'content-type': 'application/json'});
            }));
  });
}
