import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

const _native = MethodChannel('remotescreen/native');
final appUpdates = AppUpdates();

Future<Map<String, dynamic>> verifyHotUpdateEnvelope(
    Map<String, dynamic> envelope,
    Map<String, dynamic> key,
    Map<String, dynamic> info) async {
  final payload = await verifyUpdateEnvelope(envelope, key, info);
  if (payload['kind'] != 'hot-update' ||
      payload['target']['nativeBuild'] != info['buildCode']) {
    throw const FormatException('更新信息与当前版本不兼容');
  }
  final patch = payload['patch'];
  if (patch != null &&
      (patch['revision'] is! int ||
          patch['revision'] <= 0 ||
          patch['notes'] is! String ||
          patch['resource']['patchNumber'] is! int ||
          patch['resource']['patchNumber'] <= 0)) {
    throw const FormatException('更新信息无效');
  }
  return payload;
}

/// Verify before trusting either the release, download location or forced-update flag.
Future<Map<String, dynamic>> verifyUpdateEnvelope(Map<String, dynamic> envelope,
    Map<String, dynamic> key, Map<String, dynamic> info,
    {bool cached = false}) async {
  if (envelope['algorithm'] != 'ed25519' || envelope['keyId'] != key['keyId']) {
    throw const FormatException('更新信息签名无效');
  }
  final bytes = base64Decode(envelope['payload'] as String);
  final valid = await Ed25519().verify(bytes,
      signature: Signature(base64Decode(envelope['signature'] as String),
          publicKey: SimplePublicKey(base64Decode(key['publicKey'] as String),
              type: KeyPairType.ed25519)));
  if (!valid) throw const FormatException('更新信息签名无效');
  final payload = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final target = payload['target'] as Map<String, dynamic>;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (payload['schema'] != 1 ||
      target['platform'] != info['platform'] ||
      target['arch'] != info['arch'] ||
      target['channel'] != 'stable' ||
      (!cached &&
          ((payload['expiresAt'] as num) < now ||
              (payload['checkedAt'] as num) > now + 60000))) {
    throw const FormatException('更新信息已失效，请重试');
  }
  final release = payload['release'];
  if (release != null) {
    if (release['platform'] != target['platform'] ||
        release['arch'] != target['arch'] ||
        release['channel'] != target['channel'] ||
        release['buildCode'] is! int ||
        release['buildCode'] <= 0 ||
        release['buildCode'] > 2147483647 ||
        release['forceUpdate'] is! bool ||
        release['notes'] is! String ||
        release['versionName'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(release['sha256'] ?? '') ||
        !RegExp(r'^/v1/updates/packages/rel_[a-f0-9]{18}$')
            .hasMatch(release['downloadPath'] ?? '') ||
        release['sizeBytes'] is! int ||
        release['sizeBytes'] <= 0 ||
        release['sizeBytes'] > 512 * 1024 * 1024) {
      throw const FormatException('更新信息无效');
    }
  }
  return payload;
}

class AppUpdates extends ChangeNotifier {
  AppUpdates(
      {http.Client? metadataClient,
      Map<String, dynamic>? verificationKey,
      ShorebirdUpdater? hotUpdater,
      bool? enabled})
      : _metadataClient = metadataClient ?? http.Client(),
        _hotUpdater = hotUpdater,
        _verificationKey = verificationKey,
        _enabled = enabled ?? Platform.isAndroid;
  final bool _enabled;
  final http.Client _metadataClient;
  final Map<String, dynamic>? _verificationKey;
  ShorebirdUpdater? _hotUpdater;
  Map<String, dynamic>? hotPatch;
  bool hotStaged = false;
  bool get hasUpdate => release != null || hotPatch != null;
  bool get isHotUpdate => release == null && hotPatch != null;
  String get updateTitle => isHotUpdate
      ? '界面更新'
      : release == null
          ? '检查更新'
          : '发现新版本 ${release!['versionName']}';
  String get updateNotes => (release ?? hotPatch)?['notes'] ?? '';
  @override
  void dispose() {
    _metadataClient.close();
    super.dispose();
  }

  Map<String, dynamic>? release;
  Map<String, dynamic> info = {};
  Map<String, dynamic> _key = {};
  final _ready = Completer<void>();
  Future<void> get ready => _ready.future;
  bool visible = false,
      checking = false,
      downloading = false,
      installing = false;
  double progress = 0;
  String error = '', notice = '';
  File? _package;
  bool get forced => release?['forceUpdate'] == true;
  bool get hasPackage => _package != null;
  Future<void> Function()? beforeInstall;

  Future<void> initialize() async {
    try {
      if (!_enabled) {
        _ready.complete();
        return;
      }
      info =
          Map<String, dynamic>.from(await _native.invokeMethod('updateInfo'));
      _key = _verificationKey ??
          jsonDecode(
              await rootBundle.loadString('assets/update-public-key.json'));
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('required-update-v1');
      if (cached != null) {
        try {
          final payload = await verifyUpdateEnvelope(
              jsonDecode(cached), _key, info,
              cached: true);
          final old = payload['release'];
          if (old != null &&
              old['forceUpdate'] == true &&
              old['buildCode'] > info['buildCode']) {
            release = Map<String, dynamic>.from(old);
            visible = true;
            notifyListeners();
          } else {
            await prefs.remove('required-update-v1');
          }
        } catch (_) {
          await prefs.remove('required-update-v1');
        }
      }
      await check();
    } catch (_) {
      error = '暂时无法检查更新，请稍后重试';
    } finally {
      if (!forced && !_ready.isCompleted) _ready.complete();
      notifyListeners();
    }
  }

  Future<void> _checkHot({required bool manual}) async {
    final updater = _hotUpdater ??= ShorebirdUpdater();
    if (!updater.isAvailable) return;
    try {
      final request = http.Request(
          'GET',
          Uri.parse('$kServerUrl/v1/hot-updates/check')
              .replace(queryParameters: {
            'platform': info['platform'],
            'arch': info['arch'],
            'channel': 'stable',
            'nativeBuild': '${info['buildCode']}',
          }))
        ..followRedirects = false;
      final response = await _metadataClient
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw const HttpException('检查失败');
      final data = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 10))) {
        data.addAll(chunk);
        if (data.length > 100000) throw const FormatException('更新信息过大');
      }
      final payload = await verifyHotUpdateEnvelope(
          jsonDecode(utf8.decode(data)), _key, info);
      // This check also lets the Shorebird engine process a vendor-side rollback.
      final status =
          await updater.checkForUpdate().timeout(const Duration(seconds: 20));
      final current = (await updater.readCurrentPatch())?.number ?? 0;
      final next = (await updater.readNextPatch())?.number ?? 0;
      final patch = payload['patch'];
      hotPatch = null;
      hotStaged = false;
      if (patch != null &&
          current != patch['resource']['patchNumber'] &&
          (status == UpdateStatus.outdated ||
              status == UpdateStatus.restartRequired)) {
        hotPatch = Map<String, dynamic>.from(patch);
        hotStaged = next == patch['resource']['patchNumber'];
        visible = true;
        notice = hotStaged
            ? '更新已准备好。完全退出应用后重新打开即可生效，切到后台不会应用更新。'
            : '这次更新无需下载安装包，下次完整启动应用时生效。';
      }
    } catch (_) {
      if (manual) {
        error = '暂时无法检查界面更新，请稍后重试';
        visible = true;
      }
    }
  }

  Future<void> _downloadHot() async {
    if (downloading || hotStaged || hotPatch == null) return;
    downloading = true;
    error = '';
    notifyListeners();
    try {
      await _hotUpdater!.update();
      final next = await _hotUpdater!.readNextPatch();
      if (next?.number != hotPatch!['resource']['patchNumber']) {
        throw StateError('补丁发布信息已变化，请重新检查更新');
      }
      hotStaged = true;
      notice = '更新已准备好。完全退出应用后重新打开即可生效，切到后台不会应用更新。';
    } catch (_) {
      error = '界面更新未完成，请重新检查后重试';
    } finally {
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> check({bool manual = false}) async {
    if (checking || downloading || installing || info.isEmpty) return;
    checking = true;
    error = '';
    notice = '';
    notifyListeners();
    try {
      final uri =
          Uri.parse('$kServerUrl/v1/updates/check').replace(queryParameters: {
        'platform': info['platform'],
        'arch': info['arch'],
        'channel': 'stable',
        'buildCode': '${info['buildCode']}',
      });
      final request = http.Request('GET', uri)..followRedirects = false;
      final response = await _metadataClient
          .send(request)
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) throw const HttpException('检查失败');
      final data = <int>[];
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 10))) {
        data.addAll(chunk);
        if (data.length > 100000) throw const FormatException('更新信息过大');
      }
      final envelope = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      final payload = await verifyUpdateEnvelope(envelope, _key, info);
      final candidate = payload['release'];
      final next =
          candidate != null && candidate['buildCode'] > info['buildCode']
              ? Map<String, dynamic>.from(candidate)
              : null;
      final previousSha = release?['sha256'];
      final prefs = await SharedPreferences.getInstance();
      if (next?['forceUpdate'] == true) {
        release = next;
        visible = true;
        // Persist before exposing any way to continue using the app.
        if (!await prefs.setString(
            'required-update-v1', jsonEncode(envelope))) {
          throw StateError('无法保存更新要求，请重试');
        }
      } else {
        await prefs.remove('required-update-v1');
      }
      if (previousSha != next?['sha256']) _package = null;
      release = next;
      visible = next != null;
      if (next == null && manual) {
        notice = '已是最新版本';
        visible = true;
      }
      if (!forced && !_ready.isCompleted) _ready.complete();
      if (release != null) {
        hotPatch = null;
        hotStaged = false;
      }
      if (release == null) await _checkHot(manual: manual);
      // Read the asynchronous system installation result once after returning from its UI.
      try {
        final outcome =
            await _native.invokeMethod('consumeUpdateInstallResult');
        if (outcome is Map &&
            outcome['error'] is String &&
            outcome['error'].isNotEmpty) {
          error = outcome['error'];
          visible = true;
        }
      } catch (_) {
        /* Older native baselines do not expose session installation results. */
      }
    } catch (_) {
      error = '暂时无法检查更新，请检查网络后重试';
      if (manual || forced) visible = true;
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void defer() {
    if (forced || downloading || installing) return;
    visible = false;
    notifyListeners();
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> download() async {
    if (isHotUpdate) return _downloadHot();
    if (release == null || downloading || installing) return;
    downloading = true;
    progress = 0;
    error = '';
    notifyListeners();
    final current = Map<String, dynamic>.from(release!);
    final client = http.Client();
    File? partial;
    IOSink? sink;
    try {
      final directory = await _native.invokeMethod<String>('updateCacheDir');
      final destination = File('$directory/${current['sha256']}.apk');
      partial = File('${destination.path}.part');
      final request = http.Request(
          'GET', Uri.parse('$kServerUrl${current['downloadPath']}'))
        ..followRedirects = false;
      final response =
          await client.send(request).timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw const HttpException('安装包暂不可用，请重新检查更新');
      }
      var received = 0;
      sink = partial.openWrite();
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > current['sizeBytes']) {
          throw const FormatException('安装包大小不符');
        }
        sink.add(chunk);
        progress = received / current['sizeBytes'];
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (received != current['sizeBytes'] ||
          (await hashes.sha256.bind(partial.openRead()).first).toString() !=
              current['sha256']) {
        throw const FormatException('安装包校验失败');
      }
      _package = await partial.rename(destination.path);
      notice = '下载完成。安装前将结束当前通话、投屏和文件传输。';
    } catch (_) {
      error = '下载或校验失败，请检查网络后重试';
      await sink?.close();
      if (partial != null && await partial.exists()) await partial.delete();
    } finally {
      client.close();
      downloading = false;
      notifyListeners();
    }
  }

  Future<void> install() async {
    if (_package == null || installing || release == null) return;
    installing = true;
    error = '';
    notifyListeners();
    try {
      if (await _native.invokeMethod<bool>('canInstallUpdate') != true) {
        await _native.invokeMethod('requestInstallUpdatePermission');
        notice = '请允许 RemoteScreen 安装应用，返回后再次点“安装更新”。';
        return;
      }
      // Validate before ending an ongoing call; native install revalidates as well.
      final args = {
        'path': _package!.path,
        'sha256': release!['sha256'],
        'buildCode': release!['buildCode']
      };
      await _native.invokeMethod('validateUpdate', args);
      await beforeInstall?.call();
      await _native.invokeMethod('installUpdate', args);
      notice = '请在系统页面确认安装。若取消安装，可在此重试。';
    } on PlatformException catch (e) {
      error = e.message ?? '无法安装更新，请重试';
    } catch (_) {
      error = '无法安装更新，请重试';
    } finally {
      installing = false;
      notifyListeners();
    }
  }
}

/// Above Navigator and call overlays, so back/route changes cannot dismiss a requirement.
class AppUpdateHost extends StatefulWidget {
  const AppUpdateHost(
      {required this.child,
      this.controller,
      this.initialize = true,
      super.key});
  final AppUpdates? controller;
  final bool initialize;
  final Widget child;
  @override
  State<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends State<AppUpdateHost>
    with WidgetsBindingObserver {
  AppUpdates get updates => widget.controller ?? appUpdates;
  bool _away = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    updates.addListener(_changed);
    if (widget.initialize) unawaited(updates.initialize());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _away = true;
    }
    if (state == AppLifecycleState.resumed && _away) {
      _away = false;
      unawaited(updates.check());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    updates.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = updates;
    return Stack(children: [
      // A known mandatory update owns navigation and focus until replaced or withdrawn.
      ExcludeFocus(
          excluding: u.visible,
          child: IgnorePointer(ignoring: u.visible, child: widget.child)),
      if (u.visible)
        Positioned.fill(
            child: Material(
                color: Colors.black54,
                child: SafeArea(
                    child: Center(
                        child: PopScope(
                            canPop: false,
                            onPopInvokedWithResult: (didPop, _) {
                              if (!didPop) u.defer();
                            },
                            child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 460),
                                child: Card(
                                    margin: const EdgeInsets.all(24),
                                    child: Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: SingleChildScrollView(
                                            child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.stretch,
                                                children: [
                                              const Icon(
                                                  Icons
                                                      .system_update_alt_rounded,
                                                  size: 36,
                                                  color: Color(0xff3478f6)),
                                              const SizedBox(height: 16),
                                              Text(u.updateTitle,
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .titleLarge),
                                              const SizedBox(height: 12),
                                              if (u.forced)
                                                const Padding(
                                                    padding: EdgeInsets.only(
                                                        bottom: 12),
                                                    child: Text(
                                                        '此版本需要更新后才能继续使用。')),
                                              if (u.hasUpdate)
                                                Text(u.updateNotes),
                                              if (u.downloading)
                                                Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        vertical: 16),
                                                    child: Column(children: [
                                                      LinearProgressIndicator(
                                                          value: u.isHotUpdate
                                                              ? null
                                                              : u.progress),
                                                      const SizedBox(height: 8),
                                                      Text(u.isHotUpdate
                                                          ? '正在下载…'
                                                          : '正在下载 ${(u.progress * 100).floor()}%')
                                                    ])),
                                              if (u.notice.isNotEmpty)
                                                Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 12),
                                                    child: Text(u.notice)),
                                              if (u.error.isNotEmpty)
                                                Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            top: 12),
                                                    child: Text(u.error,
                                                        style: const TextStyle(
                                                            color:
                                                                Colors.red))),
                                              const SizedBox(height: 20),
                                              if (u.hasUpdate)
                                                FilledButton(
                                                    onPressed: u.downloading ||
                                                            u.installing ||
                                                            u.hotStaged
                                                        ? null
                                                        : u.hasPackage
                                                            ? u.install
                                                            : u.download,
                                                    child: Text(u.hotStaged
                                                        ? '已准备，下次启动生效'
                                                        : u.installing
                                                            ? '正在准备安装…'
                                                            : u.downloading
                                                                ? '正在下载…'
                                                                : u.hasPackage
                                                                    ? '结束会话并安装更新'
                                                                    : '下载更新')),
                                              if (u.error.isNotEmpty)
                                                TextButton(
                                                    onPressed: u.checking ||
                                                            u.downloading ||
                                                            u.installing
                                                        ? null
                                                        : () => u.check(
                                                            manual: true),
                                                    child: Text(u.checking
                                                        ? '正在检查…'
                                                        : '重新检查更新')),
                                              if (!u.forced)
                                                TextButton(
                                                    onPressed: u.downloading ||
                                                            u.installing
                                                        ? null
                                                        : u.defer,
                                                    child: Text(!u.hasUpdate
                                                        ? '关闭'
                                                        : '稍后')),
                                            ])))))))))),
    ]);
  }
}
