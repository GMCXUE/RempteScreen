import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remotescreen/app_updates.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

class FakeHotUpdater implements ShorebirdUpdater {
  int downloads = 0;
  @override
  bool get isAvailable => true;
  @override
  Future<Patch?> readCurrentPatch() async => null;
  @override
  Future<Patch?> readNextPatch() async =>
      downloads > 0 ? const Patch(number: 2) : null;
  @override
  Future<UpdateStatus> checkForUpdate({UpdateTrack? track}) async =>
      downloads > 0 ? UpdateStatus.restartRequired : UpdateStatus.outdated;
  @override
  Future<void> update({UpdateTrack? track}) async {
    downloads++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final info = <String, dynamic>{
    'platform': 'android',
    'arch': 'arm64',
    'buildCode': 5
  };
  final release = <String, dynamic>{
    'id': 'rel_aaaaaaaaaaaaaaaaaa',
    'platform': 'android',
    'arch': 'arm64',
    'channel': 'stable',
    'buildCode': 6,
    'versionName': '0.2.0',
    'forceUpdate': true,
    'notes': '修复通话\n优化界面',
    'downloadPath': '/v1/updates/packages/rel_aaaaaaaaaaaaaaaaaa',
    'sizeBytes': 123,
    'sha256': 'a' * 64
  };
  late SimpleKeyPair pair;
  late Map<String, dynamic> key;
  Future<Map<String, dynamic>> signed(Map<String, dynamic> payload) async {
    final bytes = utf8.encode(jsonEncode(payload));
    final signature = await Ed25519().sign(bytes, keyPair: pair);
    return {
      'algorithm': 'ed25519',
      'keyId': 'test-key',
      'payload': base64Encode(bytes),
      'signature': base64Encode(signature.bytes)
    };
  }

  Map<String, dynamic> payload() => {
        'schema': 1,
        'target': {'platform': 'android', 'arch': 'arm64', 'channel': 'stable'},
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
        'expiresAt': DateTime.now().millisecondsSinceEpoch + 10000,
        'release': release
      };
  setUp(() async {
    pair = await Ed25519().newKeyPair();
    key = {
      'keyId': 'test-key',
      'publicKey': base64Encode((await pair.extractPublicKey()).bytes)
    };
  });
  test('history verifies signatures, target, expiry, ordering and cursor',
      () async {
    final history = {
      ...payload(),
      'release': null,
      'kind': 'update-history',
      'items': [
        {
          'buildCode': 5,
          'versionName': '0.2.1',
          'notes': '历史说明',
          'publishedAt': DateTime.now().millisecondsSinceEpoch
        }
      ],
      'next': 5
    };
    final envelope = await signed(history);
    expect((await verifyUpdateHistoryEnvelope(envelope, key, info))['next'], 5);
    await expectLater(
        verifyUpdateEnvelope(envelope, key, info), throwsFormatException);
    await expectLater(
        verifyUpdateHistoryEnvelope(envelope, key, info, before: 5),
        throwsFormatException);
    await expectLater(
        verifyUpdateHistoryEnvelope(
            envelope, key, {...info, 'platform': 'macos'}),
        throwsFormatException);
    for (final change in [
      {'kind': 'update'},
      {'next': 6},
      {'expiresAt': 1},
      {'items': []}
    ]) {
      await expectLater(
          verifyUpdateHistoryEnvelope(
              await signed({...history, ...change}), key, info),
          throwsFormatException);
    }
    envelope['payload'] =
        base64Encode(utf8.encode(jsonEncode({...history, 'next': null})));
    await expectLater(verifyUpdateHistoryEnvelope(envelope, key, info),
        throwsFormatException);
  });
  test('signed metadata rejects tampering and wrong platform', () async {
    final envelope = await signed(payload());
    expect(
        (await verifyUpdateEnvelope(envelope, key, info))['release']
            ['forceUpdate'],
        true);
    final wrongTarget = {...info, 'arch': 'x64'};
    await expectLater(verifyUpdateEnvelope(envelope, key, wrongTarget),
        throwsFormatException);
    envelope['payload'] = base64Encode(utf8.encode(jsonEncode({
      ...payload(),
      'release': {...release, 'forceUpdate': false}
    })));
    await expectLater(
        verifyUpdateEnvelope(envelope, key, info), throwsFormatException);
  });
  test(
      'expired online response is rejected; learned requirement verifies offline',
      () async {
    final envelope = await signed({...payload(), 'expiresAt': 1});
    await expectLater(
        verifyUpdateEnvelope(envelope, key, info), throwsFormatException);
    expect(
        (await verifyUpdateEnvelope(envelope, key, info,
            cached: true))['release']['buildCode'],
        6);
  });
  test('signed metadata cannot redirect a package to a different endpoint',
      () async {
    final envelope = await signed({
      ...payload(),
      'release': {...release, 'downloadPath': 'https://other.example/file.apk'}
    });
    await expectLater(
        verifyUpdateEnvelope(envelope, key, info), throwsFormatException);
  });
  test('hot update requires an authenticated compatible native baseline',
      () async {
    final hot = {
      ...payload(),
      'release': null,
      'kind': 'hot-update',
      'target': {...payload()['target'], 'nativeBuild': 5},
      'patch': {
        'revision': 1,
        'notes': '优化界面',
        'resource': {'patchNumber': 2}
      }
    };
    expect(
        (await verifyHotUpdateEnvelope(await signed(hot), key, info))['patch']
            ['revision'],
        1);
    await expectLater(
        verifyHotUpdateEnvelope(
            await signed({
              ...hot,
              'target': {...hot['target'], 'nativeBuild': 6}
            }),
            key,
            info),
        throwsFormatException);
    final tampered = await signed(hot);
    tampered['payload'] = base64Encode(utf8.encode('{}'));
    await expectLater(
        verifyHotUpdateEnvelope(tampered, key, info), throwsFormatException);
  });
  test(
      'hot patches download only after a user choice and preserve full-update priority',
      () async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), (call) async => info);
    final hot = await signed({
      ...payload(),
      'release': null,
      'kind': 'hot-update',
      'target': {...payload()['target'], 'nativeBuild': 5},
      'patch': {
        'revision': 1,
        'notes': '优化界面',
        'resource': {'patchNumber': 2}
      }
    });
    var full = false;
    final updater = FakeHotUpdater();
    final controller = AppUpdates(
        enabled: true,
        verificationKey: key,
        hotUpdater: updater,
        metadataClient: MockClient((request) async => http.Response(
            jsonEncode(request.url.path.contains('/hot-updates/')
                ? hot
                : await signed(
                    {...payload(), 'release': full ? release : null})),
            200)));
    await controller.initialize();
    expect(controller.isHotUpdate, true);
    expect(updater.downloads, 0);
    controller.defer();
    expect(controller.visible, false);
    expect(updater.downloads, 0);
    await controller.check(manual: true);
    await controller.download();
    expect(updater.downloads, 1);
    expect(controller.hotStaged, true);
    expect(controller.notice, contains('完全退出'));
    full = true;
    await controller.check();
    expect(controller.forced, true);
    expect(controller.hotPatch, null);
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), null);
  });
  test(
      'mandatory gate survives offline restart and a verified withdrawal clears it',
      () async {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), (call) async => info);
    final envelope = await signed(payload());
    final first = AppUpdates(
        enabled: true,
        verificationKey: key,
        metadataClient:
            MockClient((_) async => http.Response(jsonEncode(envelope), 200)));
    await first.initialize();
    expect(first.forced, true);
    first.dispose();
    var online = false;
    final withdrawn = await signed({...payload(), 'release': null});
    final restarted = AppUpdates(
        enabled: true,
        verificationKey: key,
        metadataClient: MockClient((_) async {
          if (!online) throw Exception('offline');
          return http.Response(jsonEncode(withdrawn), 200);
        }));
    await restarted.initialize();
    expect(restarted.visible, true);
    expect(restarted.forced, true);
    restarted.defer();
    expect(restarted.visible, true);
    online = true;
    await restarted.check();
    expect(restarted.forced, false);
    await restarted.ready;
    expect(
        (await SharedPreferences.getInstance()).getString('required-update-v1'),
        isNull);
    restarted.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), null);
  });
  test('system install cancellation is consumed once and remains retryable',
      () async {
    SharedPreferences.setMockInitialValues({});
    var outcome = '安装已取消，可重新尝试更新';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('remotescreen/native'),
            (call) async {
      if (call.method == 'consumeUpdateInstallResult') {
        final result = {'error': outcome};
        outcome = '';
        return result;
      }
      return info;
    });
    final envelope = await signed({
      ...payload(),
      'release': {...release, 'forceUpdate': false}
    });
    final controller = AppUpdates(
        enabled: true,
        verificationKey: key,
        metadataClient:
            MockClient((_) async => http.Response(jsonEncode(envelope), 200)));
    await controller.initialize();
    expect(controller.error, contains('安装已取消'));
    expect(controller.visible, true);
    expect(controller.forced, false);
    controller.defer();
    expect(controller.visible, false);
    await controller.check(manual: true);
    expect(controller.error, '');
    expect(controller.release, isNotNull);
    controller.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('remotescreen/native'), null);
  });
  testWidgets('required prompt blocks background and has no dismiss control',
      (tester) async {
    final controller = AppUpdates()
      ..release = release
      ..visible = true;
    var taps = 0;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        builder: (context, child) => AppUpdateHost(
            controller: controller,
            navigatorKey: navigator,
            initialize: false,
            child: child!),
        home: Scaffold(
            body: TextButton(
                onPressed: () => taps++, child: const Text('后台操作')))));
    expect(find.text('发现新版本 0.2.0'), findsOneWidget);
    expect(find.text('稍后'), findsNothing);
    controller.defer();
    await tester.pump();
    expect(controller.visible, true);
    await tester.tapAt(const Offset(2, 2));
    await tester.pump();
    expect(controller.visible, true);
    expect(taps, 0);
    await tester.tap(find.text('更新历史'));
    await tester.pumpAndSettle();
    expect(find.text('更新历史'), findsOneWidget);
    expect(find.text('发现新版本 0.2.0'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 0.2.0'), findsOneWidget);
    expect(controller.forced, true);
    expect(taps, 0);
    controller.error = '安装已取消';
    controller.notifyListeners();
    await tester.pump();
    expect(find.text('稍后'), findsNothing);
    expect(find.text('重新检查更新'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
  testWidgets('optional prompt shows notes and permits later', (tester) async {
    final controller = AppUpdates()
      ..release = {...release, 'forceUpdate': false}
      ..visible = true;
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => AppUpdateHost(
            controller: controller, initialize: false, child: child!),
        home: const Scaffold()));
    expect(find.text('修复通话\n优化界面'), findsOneWidget);
    await tester.tap(find.text('稍后'));
    await tester.pump();
    expect(controller.visible, false);
    await controller.ready;
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
