import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as digest;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:remotescreen/api.dart';
import 'package:remotescreen/chat_media.dart';
import 'package:remotescreen/chat_outbox.dart';
import 'package:remotescreen/chat_video_viewer.dart';
import 'package:remotescreen/social_screen.dart';
import 'chat_messages_test.dart' show ChatFixture;

class TestVideoPlatform extends VideoPlayerPlatform {
  int played = 0, disposed = 0;
  DataSource? source;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    source = options.dataSource;
    return 7;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int id) => Stream.value(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 1),
      size: const Size(64, 48)));
  @override
  Future<void> dispose(int id) async {
    disposed++;
  }

  @override
  Future<void> play(int id) async {
    played++;
  }

  @override
  Future<void> pause(int id) async {}
  @override
  Future<void> setLooping(int id, bool value) async {}
  @override
  Future<void> setVolume(int id, double value) async {}
  @override
  Future<void> setPlaybackSpeed(int id, double value) async {}
  @override
  Future<void> setMixWithOthers(bool value) async {}
  @override
  Future<void> setAllowBackgroundPlayback(bool value) async {}
  @override
  Future<void> seekTo(int id, Duration value) async {}
  @override
  Future<Duration> getPosition(int id) async => Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox(key: ValueKey('test-video-player'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const picker = MethodChannel('plugins.flutter.io/image_picker');
  late Directory dir;
  late File video;
  late List<String> choices;
  late List<Map> pickerArgs;
  setUp(() async {
    chatOutbox.reset();
    SharedPreferences.setMockInitialValues(
        {'remotescreen.accountToken': 'test-token'});
    dir = await Directory.systemTemp.createTemp('rs-picker-test-');
    video = File('${dir.path}/clip.mp4');
    final bytes = List<int>.filled(32, 0);
    bytes.setRange(4, 8, 'ftyp'.codeUnits);
    await video.writeAsBytes(bytes);
    choices = [];
    pickerArgs = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, (call) async {
      if (call.method == 'pickMedia') {
        pickerArgs.add(Map.from(call.arguments));
        return choices;
      }
      return null;
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(picker, null);
    await dir.delete(recursive: true);
    chatOutbox.reset();
  });
  test('相册混合多选使用剩余上限，取消及超量不产生部分草稿', () async {
    choices = [
      File('assets/avatars/cat.png').absolute.path,
      File('assets/avatars/dog.png').absolute.path,
      video.path
    ];
    final selected = await pickChatMedia(limit: 4);
    expect(selected.map((m) => m.kind), ['image', 'image', 'video']);
    expect(selected[2].path, video.path);
    expect(pickerArgs.single['allowMultiple'], true);
    expect(pickerArgs.single['limit'], 4);
    choices = [];
    expect(await pickChatMedia(limit: 4), isEmpty);
    choices = List.filled(10, video.path);
    expect(pickChatMedia(limit: 9), throwsException);
    choices = [video.path];
    final f = await video.open(mode: FileMode.append);
    await f.truncate(50 * 1024 * 1024 + 1);
    await f.close();
    expect(pickChatMedia(limit: 2), throwsException);
  });
  testWidgets('混合多选立即入队，视频二进制上传和播放，退出释放缓存', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });
    final fixture = ChatFixture(),
        player = TestVideoPlatform(),
        previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = player;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    choices = [
      File('assets/avatars/cat.png').absolute.path,
      File('assets/avatars/dog.png').absolute.path,
      video.path
    ];
    final raw = video.readAsBytesSync();
    var uploads = 0;
    var revoked = false;
    http.Client clientFactory() => MockClient((request) async {
          if (request.url.path.contains('/videos/')) {
            expect(request.headers['Authorization'], 'Bearer test-token');
            if (request.method == 'PUT') {
              uploads++;
              expect(
                  request.headers['Content-Type'], 'application/octet-stream');
              expect(request.bodyBytes, raw);
              final row = {
                'id': 'video1',
                'seq': '${fixture.messages.length + 1}',
                'clientId': request.url.pathSegments.last,
                'senderId': 'me',
                'kind': 'video',
                'text': '[视频]',
                'createdAt': '${DateTime.now().millisecondsSinceEpoch}',
                'video': {
                  'width': 64,
                  'height': 48,
                  'duration': 1000,
                  'bytes': raw.length,
                  'sha256': digest.sha256.convert(raw).toString(),
                  'thumbnail': fixture.photo
                }
              };
              fixture.messages.add(row);
              return http.Response(jsonEncode({'message': row}), 200,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }
            return http.Response.bytes(raw, 200,
                headers: {'content-type': 'video/mp4'});
          }
          if (request.url.path.endsWith('/message-video')) {
            if (revoked) {
              return http.Response(
                  jsonEncode({
                    'error': {'code': 'chat_video', 'message': '视频已撤回'}
                  }),
                  410,
                  headers: {'content-type': 'application/json; charset=utf-8'});
            }
            return http.Response(
                jsonEncode({
                  'message':
                      fixture.messages.firstWhere((m) => m['kind'] == 'video')
                }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return fixture.respond(request);
        });
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: PrivateChatScreen(
              account: Account(id: 'me', email: 'me@test.invalid', name: '我'),
              friend: const {
            'id': 'peer',
            'name': '好友',
            'avatarId': 'cat',
            'remark': ''
          })));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('chat-more-button')));
      await tester.pumpAndSettle();
      await tester.runAsync(() => http.runWithClient(() async {
            await tester.tap(find.text('图片与视频'));
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }, clientFactory));
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除图片 1'), findsOneWidget);
      expect(find.byTooltip('移除图片 2'), findsOneWidget);
      expect(find.byTooltip('移除视频 3'), findsOneWidget);
      expect(uploads, 0);
      await tester.enterText(find.byType(TextField), '混合配文');
      await tester.tap(find.text('发送'));
      for (var i = 0;
          i < 60 &&
              (uploads == 0 ||
                  chatOutbox
                      .queue('me', 'peer', api.captureChatSender)
                      .running);
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byTooltip('移除视频 3'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(fixture.imageAttempts, 2);
      expect(uploads, 1,
          reason:
              '${chatOutbox.queue('me', 'peer', api.captureChatSender).items.map((m) => '${m.kind}:${m.status}:${m.error}').toList()}');
      await tester.tap(find.byKey(const ValueKey('chat-open-video1')));
      for (var i = 0; i < 60 && player.played == 0; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byType(ChatVideoViewer), findsOneWidget);
      expect(find.byKey(const ValueKey('test-video-player')), findsOneWidget);
      expect(player.played, 1);
      final cached = File.fromUri(Uri.parse(player.source!.uri!));
      expect(cached.existsSync(), true);
      revoked = true;
      await tester.pump(const Duration(seconds: 3));
      for (var i = 0; i < 30 && cached.existsSync(); i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump();
      }
      expect(find.text('视频已撤回'), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      expect(player.disposed, 1);
      expect(cached.existsSync(), false);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }, clientFactory);
  });
  test('下载校验失败不返回播放文件，视频重试保留编号', () async {
    final raw = await video.readAsBytes(),
        service = ApiService(baseUrl: 'http://video.invalid');
    await http.runWithClient(() async {
      await expectLater(service.downloadChatVideo('peer', 'video1'),
          throwsA(isA<ApiException>()));
    },
        () => MockClient((r) async => r.url.path.endsWith('/message-video')
            ? http.Response(
                jsonEncode({
                  'message': {
                    'video': {
                      'bytes': raw.length,
                      'sha256': digest.sha256.convert(raw).toString()
                    }
                  }
                }),
                200)
            : http.Response.bytes(List.filled(raw.length, 1), 200)));
    final calls = <Map<String, dynamic>>[];
    var fail = true;
    final queue = ChatSendQueue('me', 'peer', Future.value((op, body) async {
      calls.add(body);
      expect(op, 'send-video');
      if (fail) {
        fail = false;
        throw '失败';
      }
      return {
        'message': {
          'id': 'ok',
          'seq': '1',
          'clientId': body['clientId'],
          'senderId': 'me',
          'kind': 'video'
        }
      };
    }));
    queue.enqueue([
      OutgoingChatMessage(
          id: 'video-stable',
          kind: 'video',
          videoPath: video.path,
          videoSize: raw.length)
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(queue.items.single.status, 'failed');
    queue.retry('video-stable');
    await Future<void>.delayed(Duration.zero);
    expect(calls[0]['clientId'], calls[1]['clientId']);
    expect(queue.items, isEmpty);
  });
}
