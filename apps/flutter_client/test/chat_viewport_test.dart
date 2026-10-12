import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/chat_outbox.dart';
import 'package:remotescreen/social_screen.dart';
import 'chat_messages_test.dart' show ChatFixture;

Widget conversation() => MaterialApp(
        home: PrivateChatScreen(
            account: Account(id: 'me', email: 'me@test.invalid', name: '我'),
            friend: const {
          'id': 'peer',
          'name': '好友',
          'remark': '',
          'avatarId': 'cat'
        }));
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    chatOutbox.reset();
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
  });
  testWidgets('初次进入定位真实底部，键盘挤压后最新消息仍在输入栏上方，阅读历史不被拉走', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetViewInsets();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final fixture = ChatFixture();
    fixture.messages.clear();
    for (var i = 0; i < 60; i++) {
      fixture.messages.add({
        'id': 'history$i',
        'seq': '${i + 1}',
        'senderId': 'peer',
        'kind': 'text',
        'text': i == 59 ? '最后一条消息' : '第$i条历史记录\n${'较长的聊天内容' * (i % 4 + 1)}',
        'createdAt': '123456'
      });
    }
    await http.runWithClient(() async {
      await tester.pumpWidget(conversation());
      await tester.pumpAndSettle();
      final list = find.byType(ListView).first;
      final controller = tester.widget<ListView>(list).controller!;
      expect(controller.position.extentAfter, lessThan(2));
      expect(find.text('最后一条消息'), findsOneWidget);
      await tester.tap(find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 330);
      await tester.pumpAndSettle();
      expect(controller.position.extentAfter, lessThan(2));
      expect(tester.getRect(find.text('最后一条消息')).bottom,
          lessThan(tester.getRect(find.byType(TextField)).top));
      expect(tester.getRect(find.byType(TextField)).bottom,
          lessThanOrEqualTo(514));
      await tester.drag(list, const Offset(0, 280));
      await tester.pumpAndSettle();
      final offset = controller.offset;
      expect(controller.position.extentAfter, greaterThan(100));
      tester.view.viewInsets = const FakeViewPadding(bottom: 370);
      await tester.pumpAndSettle();
      expect(controller.offset, closeTo(offset, 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, () => MockClient(fixture.respond));
  });
  testWidgets('上传等待期间图片立即进聊天，清空输入框并可输入下一条，失败在消息中重试', (tester) async {
    final hold = Completer<void>(), fixture = ChatFixture();
    fixture.failImage = true;
    const picker = MethodChannel('plugins.flutter.io/image_picker');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        picker,
        (call) async => call.method == 'pickMedia'
            ? [File('assets/avatars/cat.png').absolute.path]
            : call.method == 'pickImage'
                ? File('assets/avatars/cat.png').absolute.path
                : null);
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null));
    await http.runWithClient(() async {
      await tester.pumpWidget(conversation());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('图片与视频'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('发送'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chat-draft-images')), findsNothing);
      expect(find.text('发送中'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      await tester.enterText(find.byType(TextField), '下一条文字');
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
      hold.complete();
      await tester.pumpAndSettle();
      expect(find.text('发送失败 · 重试'), findsOneWidget);
      await tester.tap(find.text('发送失败 · 重试'));
      await tester.pumpAndSettle();
      expect(find.text('发送失败 · 重试'), findsNothing);
      expect(fixture.imageAttempts, 2);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '下一条文字');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
        () => MockClient((request) async {
              if (request.url.path.endsWith('send-image') &&
                  !hold.isCompleted) {
                await hold.future;
              }
              return fixture.respond(request);
            }));
  });
}
