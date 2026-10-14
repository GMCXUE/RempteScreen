import 'chat_storage_fixture.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/chat_outbox.dart';
import 'package:remotescreen/chat_message.dart';
import 'package:remotescreen/social_screen.dart';
import 'package:remotescreen/compact_feedback.dart';

class ChatFixture {
  ChatFixture() {
    final created = '${DateTime.now().millisecondsSinceEpoch}';
    messages.addAll([
      {
        'id': 'text1',
        'seq': '1',
        'senderId': 'peer',
        'kind': 'text',
        'text': '第一行\n第二行',
        'createdAt': created
      },
      {
        'id': 'text2',
        'seq': '2',
        'senderId': 'me',
        'kind': 'text',
        'text': '我的消息',
        'createdAt': created
      },
    ]);
  }
  final messages = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];
  final requests = <Map<String, dynamic>>[];
  bool failImage = false,
      failRecall = false,
      failReadImage = false,
      failText = false;
  final failedSync = <String>{};
  int imageAttempts = 0;
  int? failAtImage;
  final accepted = <String, Map<String, dynamic>>{};
  String get photo =>
      'data:image/png;base64,${base64Encode(File('assets/avatars/cat.png').readAsBytesSync())}';
  Future<http.Response> respond(http.Request request) async {
    final operation = request.url.pathSegments.last;
    final body = request.body.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(request.body));
    requests.add({'op': operation, ...body});
    if (failedSync.contains(operation) ||
        operation == 'local-feed' && failedSync.contains('messages')) {
      return http.Response(
          jsonEncode({
            'error': {'code': 'network', 'message': '连不上服务器，请检查网络或服务器地址'}
          }),
          503,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    Map<String, dynamic> result = {'ok': true};
    if (operation == 'state') {
      result = {
        'me': {'id': 'me', 'name': '我'},
        'friends': [
          {'id': 'peer', 'name': '好友'}
        ]
      };
    } else if (operation == 'local-feed') {
      final after = BigInt.parse(body['after'] ?? '0'),
          edit = int.parse(body['edit'] ?? '0');
      result = {
        'messages': messages
            .where((m) => BigInt.parse(m['seq']) > after)
            .map(
                (m) => {...m, 'peerId': 'peer', 'editSeq': m['editSeq'] ?? '0'})
            .toList(),
        'updates': updates
            .where((m) => int.parse(m['editSeq']) > edit)
            .map((m) => {...m, 'peerId': 'peer'})
            .toList(),
        'clears': [],
        'reads': [],
        'after': messages.isEmpty ? '0' : messages.last['seq'],
        'edit': '${updates.length}',
        'hasMore': false
      };
    } else if (operation == 'messages') {
      result = {
        'messages': messages
            .where((m) =>
                body['after'] == null ||
                BigInt.parse(m['seq']) > BigInt.parse(body['after']))
            .toList(),
        'updates': updates
            .where((m) =>
                int.parse(m['editSeq']) > int.parse(body['syncCursor'] ?? '0'))
            .toList(),
        'syncCursor': '${updates.length}',
        'serverNow': '${DateTime.now().millisecondsSinceEpoch}',
        'hasMore': false,
      };
    } else if (operation == 'recall') {
      if (failRecall) {
        return http.Response(
            jsonEncode({
              'error': {'code': 'too_late', 'message': '已超过撤回时间'}
            }),
            409,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final message = messages.firstWhere((m) => m['id'] == body['messageId']);
      retract(message);
      result = {'message': message};
    } else if (operation == 'send-image') {
      imageAttempts++;
      if (failImage || failAtImage == imageAttempts) {
        failImage = false;
        return http.Response(
            jsonEncode({
              'error': {'code': 'network', 'message': '网络不可用'}
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final message = <String, dynamic>{
        'id': 'image${messages.where((m) => m['kind'] == 'image').length + 1}',
        'seq': '${messages.length + 1}',
        'senderId': 'me',
        'clientId': body['clientId'],
        'kind': 'image',
        'text': '[图片]',
        'createdAt': '${DateTime.now().millisecondsSinceEpoch}',
        'image': {'width': 256, 'height': 256, 'thumbnail': photo}
      };
      final stored = accepted.putIfAbsent(body['clientId'], () => message);
      if (!messages.any((m) => m['id'] == stored['id'])) messages.add(stored);
      result = {'message': stored};
    } else if (operation == 'send') {
      if (failText) {
        failText = false;
        return http.Response(
            jsonEncode({
              'error': {'message': '文字发送失败'}
            }),
            503,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final stored = accepted.putIfAbsent(
          body['clientId'],
          () => {
                'id': 'sent${messages.length}',
                'clientId': body['clientId'],
                'seq': '${messages.length + 1}',
                'senderId': 'me',
                'kind': 'text',
                'text': body['text'],
                'createdAt': '${DateTime.now().millisecondsSinceEpoch}'
              });
      if (!messages.any((m) => m['id'] == stored['id'])) messages.add(stored);
      result = {'message': stored};
    } else if ((operation == 'message-image' || operation == 'local-image')) {
      if (failReadImage) {
        return http.Response(
            jsonEncode({
              'error': {'message': '图片已撤回'}
            }),
            410,
            headers: {'content-type': 'application/json; charset=utf-8'});
      }
      result = {'image': photo};
    }
    return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }

  void retract(Map<String, dynamic> message) {
    message.addAll({
      'kind': 'recalled',
      'text': '撤回了一条消息',
      'image': null,
      'recalledAt': '${DateTime.now().millisecondsSinceEpoch}',
      'editSeq': '${updates.length + 1}'
    });
    updates.add(Map<String, dynamic>.from(message));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  final clipboard = <String>[];
  final imageClipboard = <List<int>>[];
  const native = MethodChannel('remotescreen/native');
  bool systemFeedback = false;
  var failClipboard = false;
  String? clipboardImage;
  String? clipboardText;
  final imageReadUris = <String?>[];
  bool failImagePaste = false;
  Completer<String?>? pendingImageRead;
  Completer<String?>? pendingPicker;
  bool cancelPicker = false;
  PlatformException? pickerError;
  final pickerSources = <int>[];
  setUp(() async {
    chatOutbox.reset();
    clipboard.clear();
    imageClipboard.clear();
    systemFeedback = false;
    clipboardImage = null;
    clipboardText = null;
    imageReadUris.clear();
    failImagePaste = false;
    pendingImageRead = null;
    pendingPicker = null;
    cancelPicker = false;
    pickerError = null;
    pickerSources.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, (call) async {
      if (call.method == 'clipboardHasSystemFeedback') return systemFeedback;
      if (call.method == 'readChatImage') {
        imageReadUris.add(call.arguments['uri'] as String?);
        if (failImagePaste) {
          throw PlatformException(
              code: 'clipboard_failed', message: '无法读取剪贴板图片，请重新复制');
        }
        return pendingImageRead?.future ?? clipboardImage;
      }
      if (call.method == 'copyChatImage') {
        imageClipboard.add(List<int>.from(call.arguments['bytes']));
      }
      return null;
    });
    failClipboard = false;
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    await prepareChatStorage('test-token');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        if (failClipboard) throw PlatformException(code: 'unavailable');
        clipboard.add(call.arguments['text']);
      }
      if (call.method == 'Clipboard.getData') return {'text': clipboardText};
      if (call.method == 'Clipboard.hasStrings') {
        return {'value': clipboardText != null};
      }
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
      if (call.method != 'pickImage' && call.method != 'pickMedia') return null;
      pickerSources.add(
          call.method == 'pickMedia' ? 1 : call.arguments['source'] as int);
      if (pickerError != null) throw pickerError!;
      if (cancelPicker) return call.method == 'pickMedia' ? [] : null;
      final path = await (pendingPicker?.future ??
          Future.value(File('assets/avatars/cat.png').absolute.path));
      return call.method == 'pickMedia' ? [if (path != null) path] : path;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
        home: PrivateChatScreen(
            account: Account(id: 'me', email: 'me@example.test', name: '我'),
            friend: const {
          'id': 'peer',
          'name': '小林',
          'remark': '',
          'avatarId': 'rabbit'
        })));
    await pumpChat(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpChat(tester);
  }

  Future<void> choosePhoto(WidgetTester tester, {bool camera = false}) async {
    // Images are chosen before a caption now that text replaces the plus button.
    final text =
        tester.widget<TextField>(find.byType(TextField)).controller!.text;
    if (text.isNotEmpty) {
      await tester.enterText(find.byType(TextField), '');
      await pumpChat(tester);
    }
    if (find
        .byKey(const ValueKey('chat-attachment-panel'))
        .evaluate()
        .isEmpty) {
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
    }
    // Dispatch UI actions on the widget test clock. In particular, the media
    // limit notice creates its expiry timer synchronously during this tap.
    // Running the tap in runAsync would expire it on wall time under CPU load.
    await tester.tap(find.text(camera ? '拍照' : '图片与视频'));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await pumpChat(tester);
    if (text.isNotEmpty) {
      await tester.enterText(find.byType(TextField), text);
      await pumpChat(tester);
    }
  }

  testWidgets('轻提示不排队、自动消失且不占据底部输入区', (tester) async {
    final feedback = CompactFeedback();
    late BuildContext page;
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: Builder(builder: (context) {
      page = context;
      return const SizedBox();
    }))));
    feedback.show(page, '已复制');
    await tester.pump();
    final pill = find.byKey(const ValueKey('compact-feedback'));
    expect(tester.getSize(pill).width, lessThan(240));
    expect(tester.getSize(pill).height, lessThan(52));
    expect(tester.getTopLeft(pill).dy, lessThan(200));
    await tester.pump(const Duration(milliseconds: 800));
    feedback.show(page, '图片已复制');
    await tester.pump();
    expect(find.text('已复制'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1250));
    expect(pill, findsNothing);
    feedback.dismiss();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('同步失败保留聊天和草稿，短提示不反复弹，恢复后清除并重试已读', (tester) async {
    final fixture = ChatFixture();
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '未发送的草稿');
      fixture.failedSync.add('messages');
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('compact-feedback')), findsOneWidget);
      expect(find.text('第一行\n第二行'), findsOneWidget);
      expect(find.text('未发送的草稿'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 2300));
      expect(find.byKey(const ValueKey('compact-feedback')), findsNothing);
      await tester.pump(const Duration(seconds: 6));
      await pumpChat(tester);
      expect(find.text('连不上服务器，请检查网络或服务器地址'), findsNothing);
      fixture.failedSync.clear();
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      fixture.failedSync.add('read');
      fixture.messages.add({
        'id': 'retry-read',
        'seq': '3',
        'senderId': 'peer',
        'kind': 'text',
        'text': '重试已读',
        'createdAt': '${DateTime.now().millisecondsSinceEpoch}'
      });
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      final attempts = fixture.requests.where((r) => r['op'] == 'read').length;
      await tester.pump(const Duration(milliseconds: 2300));
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(fixture.requests.where((r) => r['op'] == 'read').length,
          greaterThan(attempts));
      expect(find.byKey(const ValueKey('compact-feedback')), findsNothing);
      fixture.failedSync.clear();
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(find.text('未发送的草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  test('仅本人两分钟内的文字和图片可撤回', () {
    final now = DateTime.fromMillisecondsSinceEpoch(180000);
    final message = {'senderId': 'me', 'kind': 'text', 'createdAt': '60000'};
    expect(canRecallMessage(message, 'me', now: now), isTrue);
    expect(canRecallMessage({...message, 'createdAt': '59999'}, 'me', now: now),
        isFalse);
    expect(canRecallMessage(message, 'peer', now: now), isFalse);
    for (final kind in ['call', 'recalled']) {
      expect(canRecallMessage({...message, 'kind': kind}, 'me', now: now),
          isFalse);
    }
    expect(canRecallMessage({...message, 'kind': 'image'}, 'me', now: now),
        isTrue);
    expect(chatImageBytes('https://example.test/photo.png'), isNull);
    expect(chatImageBytes('data:image/svg+xml;base64,YQ=='), isNull);
  });

  testWidgets('长按复制只复制正文，选择文字和复制失败均有明确反馈', (tester) async {
    final fixture = ChatFixture();
    await http.runWithClient(() async {
      await open(tester);
      await tester.longPress(find.text('第一行\n第二行'));
      await pumpChat(tester);
      expect(find.text('撤回'), findsNothing);
      await tester.tap(find.text('复制'));
      await pumpChat(tester);
      expect(clipboard, ['第一行\n第二行']);
      expect(find.text('已复制'), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      await tester.pump(const Duration(milliseconds: 1250));
      expect(find.text('已复制'), findsNothing);
      systemFeedback = true;
      await tester.longPress(find.text('第一行\n第二行'));
      await pumpChat(tester);
      await tester.tap(find.text('复制'));
      await pumpChat(tester);
      expect(find.text('已复制'), findsNothing);
      systemFeedback = false;
      await tester.longPress(find.text('第一行\n第二行'));
      await pumpChat(tester);
      await tester.tap(find.text('选择文字'));
      await pumpChat(tester);
      expect(find.byType(SelectableText), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await pumpChat(tester);
      failClipboard = true;
      await tester.longPress(find.text('第一行\n第二行'));
      await pumpChat(tester);
      await tester.tap(find.text('复制'));
      await pumpChat(tester);
      expect(find.text('复制失败，请重试'), findsOneWidget);
      await tester.longPress(find.text('第一行\n第二行'));
      await pumpChat(tester);
      await tester.tap(find.text('选择文字'));
      await pumpChat(tester);
      fixture.retract(fixture.messages.first);
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(find.byType(SelectableText), findsNothing);
      expect(find.text('对方撤回了一条消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('撤回需确认，失败保留原消息，成功只留下撤回提示', (tester) async {
    final fixture = ChatFixture();
    await http.runWithClient(() async {
      await open(tester);
      Future<void> recallMenu() async {
        await tester.longPress(find.text('我的消息'));
        await pumpChat(tester);
        await tester.tap(find.text('撤回'));
        await pumpChat(tester);
      }

      await recallMenu();
      await tester.tap(find.text('取消'));
      await pumpChat(tester);
      expect(fixture.requests.where((r) => r['op'] == 'recall'), isEmpty);
      fixture.failRecall = true;
      await recallMenu();
      await tester.tap(find.text('撤回'));
      await pumpChat(tester);
      expect(find.text('我的消息'), findsOneWidget);
      expect(find.textContaining('已超过撤回时间'), findsOneWidget);
      fixture.failRecall = false;
      await recallMenu();
      await tester.tap(find.text('撤回'));
      await pumpChat(tester);
      expect(find.text('我的消息'), findsNothing);
      expect(find.text('你撤回了一条消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('图库确认直接发送，错误可见，重试保留编号且不发送文字草稿', (tester) async {
    final fixture = ChatFixture()..failImage = true;
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '保留草稿');
      await choosePhoto(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('chat-draft-images')), findsNothing);
      expect(find.text('网络不可用'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留草稿');
      expect(fixture.requests.where((r) => r['op'] == 'send'), isEmpty);
      await tester.tap(find.text('发送失败 · 重试'));
      await pumpChat(tester);
      final sends =
          fixture.requests.where((r) => r['op'] == 'send-image').toList();
      expect(sends.length, 2);
      expect(sends[0]['clientId'], sends[1]['clientId']);
      expect(find.text('发送失败 · 重试'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留草稿');
      await tester.tap(find.text('发送'));
      await pumpChat(tester);
      expect(
          fixture.requests.lastWhere((r) => r['op'] == 'send')['text'], '保留草稿');
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('右侧加号开关面板，图库直接选择，拍照独立调用，取消与权限错误不改草稿', (tester) async {
    final fixture = ChatFixture();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '保留文字');
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-more-button')), findsNothing);
      expect(find.text('发送'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '');
      await pumpChat(tester);
      expect(find.text('发送'), findsNothing);
      expect(find.byKey(const ValueKey('chat-attachment-panel')), findsNothing);
      final fieldRect = tester.getRect(find.byType(TextField));
      expect(
          tester.getCenter(find.byKey(const ValueKey('chat-more-button'))).dx,
          greaterThan(fieldRect.right));
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
      expect(find.text('图片与视频'), findsOneWidget);
      expect(find.text('拍照'), findsOneWidget);
      expect(find.text('粘贴图片'), findsNothing);
      expect(find.text('文件'), findsNothing);
      expect(
          tester
              .widget<TextField>(find.byType(TextField))
              .contentInsertionConfiguration,
          isNull);
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-attachment-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
      await tester.binding.handlePopRoute();
      await pumpChat(tester);
      expect(find.byType(PrivateChatScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-attachment-panel')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
      await tester.tap(find.byType(TextField));
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-attachment-panel')), findsNothing);
      cancelPicker = true;
      await choosePhoto(tester);
      expect(pickerSources.last, 1);
      expect(find.byTooltip('移除图片 1'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      cancelPicker = false;
      pickerError = PlatformException(code: 'camera_access_denied');
      await choosePhoto(tester, camera: true);
      expect(pickerSources.last, 0);
      expect(find.text('请允许 RemoteScreen 使用摄像头后重试'), findsOneWidget);
      pickerError = null;
      await choosePhoto(tester, camera: true);
      expect(find.byKey(const ValueKey('chat-draft-images')), findsNothing);
      expect(imageReadUris, isEmpty);
      expect(fixture.requests.where((r) => r['op'] == 'send-image').length, 1);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('输入框普通文字粘贴保持系统行为，不读取图片或发送消息', (tester) async {
    final fixture = ChatFixture();
    clipboardText = '正常文字';
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '原有草稿');
      await tester.longPress(find.byType(TextField));
      await pumpChat(tester);
      await tester.tap(find.text('Paste'));
      await pumpChat(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          contains('正常文字'));
      expect(imageReadUris, isEmpty);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
          fixture.requests
              .where((r) => r['op'] == 'send' || r['op'] == 'send-image'),
          isEmpty);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('部分发送失败只重试剩余图片，文字失败也不重发已完成图片', (tester) async {
    final fixture = ChatFixture()
      ..failAtImage = 2
      ..failText = true;
    clipboardImage = fixture.photo;
    await http.runWithClient(() async {
      await open(tester);
      await tester.enterText(find.byType(TextField), '图片说明');
      Future<void> paste() async {
        await choosePhoto(tester);
      }

      await paste();
      await paste();
      await tester.tap(find.text('发送'));
      await pumpChat(tester);
      expect(find.byTooltip('移除图片 1'), findsNothing);
      expect(find.text('发送失败 · 重试'), findsNWidgets(2));
      expect(fixture.messages.where((m) => m['kind'] == 'image').length, 1);
      expect(fixture.requests.where((r) => r['op'] == 'send').length, 1);
      final failedId = fixture.requests
          .lastWhere((r) => r['op'] == 'send-image')['clientId'];
      await tester.tap(find.descendant(
          of: find.byTooltip('网络不可用'), matching: find.text('发送失败 · 重试')));
      await pumpChat(tester);
      expect(find.byKey(const ValueKey('chat-draft-images')), findsNothing);
      expect(fixture.imageAttempts, 3);
      expect(
          fixture.requests
              .lastWhere((r) => r['op'] == 'send-image')['clientId'],
          failedId);
      expect(find.byTooltip('文字发送失败'), findsOneWidget);
      final textId =
          fixture.requests.lastWhere((r) => r['op'] == 'send')['clientId'];
      await tester.tap(find.text('发送失败 · 重试'));
      await pumpChat(tester);
      expect(fixture.imageAttempts, 3);
      expect(fixture.requests.lastWhere((r) => r['op'] == 'send')['clientId'],
          textId);
      expect(fixture.messages.where((m) => m['kind'] == 'image').length, 2);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('离开聊天后丢弃迟到的相册结果', (tester) async {
    final fixture = ChatFixture();
    await http.runWithClient(() async {
      await open(tester);
      pendingPicker = Completer<String?>();
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await pumpChat(tester);
      await tester.tap(find.text('图片与视频'));
      await tester.pump();
      await close(tester);
      await tester.runAsync(() async {
        pendingPicker!.complete(File('assets/avatars/cat.png').absolute.path);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await pumpChat(tester);
      expect(fixture.requests.where((r) => r['op'] == 'send-image'), isEmpty);
      expect(tester.takeException(), isNull);
    }, () => MockClient(fixture.respond));
  });

  testWidgets('相册确认直接发送，失败重试和复制撤回仍然有效', (tester) async {
    final fixture = ChatFixture()..failImage = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await http.runWithClient(() async {
      await open(tester);
      Future<void> pick() => choosePhoto(tester);

      await pick();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('chat-draft-images')), findsNothing);
      expect(find.byTooltip('网络不可用'), findsOneWidget);
      await tester.tap(find.text('发送失败 · 重试'));
      await pumpChat(tester);
      final sends =
          fixture.requests.where((r) => r['op'] == 'send-image').toList();
      expect(sends.length, 2);
      expect(sends[0]['clientId'], sends[1]['clientId']);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.longPress(find.bySemanticsLabel('查看图片'));
      await pumpChat(tester);
      await tester.tap(find.text('复制图片'));
      await pumpChat(tester);
      expect(imageClipboard.single, chatImageBytes(fixture.photo));
      expect(find.text('图片已复制'), findsOneWidget);
      fixture.failedSync.add('message-image');
      await tester.longPress(find.bySemanticsLabel('查看图片'));
      await pumpChat(tester);
      await tester.tap(find.text('复制图片'));
      await pumpChat(tester);
      expect(imageClipboard.length, 2);
      expect(find.text('图片已复制'), findsOneWidget);
      fixture.failedSync.clear();
      await tester.pump(const Duration(milliseconds: 2300));
      await tester.tap(find.bySemanticsLabel('查看图片'));
      await pumpChat(tester);
      expect(find.byType(ChatImageViewer), findsOneWidget);
      await tester.tap(find.byTooltip('复制图片'));
      await pumpChat(tester);
      expect(imageClipboard.length, 3);
      fixture.retract(fixture.messages.last);
      await tester.pump(const Duration(seconds: 3));
      await pumpChat(tester);
      expect(find.byType(ChatImageViewer), findsNothing);
      expect(find.text('你撤回了一条消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester);
    }, () => MockClient(fixture.respond));
  });
}
