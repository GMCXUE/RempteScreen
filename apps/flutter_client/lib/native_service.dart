import 'dart:io' show Platform;
import 'dart:convert';

import 'package:flutter/services.dart';

/// 统一账号通知入口。当前使用原生后台同步；未来厂商推送复用此
/// 生命周期、账号校验和点击路由，不改变聊天/通话界面的调用方式。
class NativeMessaging {
  static const _channel = MethodChannel('remotescreen/native');
  static Future<void> Function()? _actionReady;
  static bool _listening = false;
  static void listenForActions(Future<void> Function()? handler) {
    _actionReady = handler;
    if (_listening) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'messagingActionReady') await _actionReady?.call();
    });
  }

  static String? visiblePeer;
  static Future<void> start(
      String baseUrl, String token, String accountId) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod('requestNotificationPermission');
    await _channel.invokeMethod('startMessagingService', {
      'baseUrl': baseUrl,
      'token': token,
      'accountId': accountId,
    });
  }

  static Future<Map<String, dynamic>> settings(
      [Map<String, dynamic>? value]) async {
    if (!Platform.isAndroid) {
      return value ??
          {
            'messageEnabled': true,
            'friendEnabled': true,
            'messageSound': true,
            'messagePreview': true,
            'callSound': true,
            'mutedPeers': <String>[]
          };
    }
    final result = await _channel.invokeMethod<String>('messagingSettings',
        {'value': value == null ? null : jsonEncode(value)});
    return Map<String, dynamic>.from(jsonDecode(result!));
  }

  static Future<Map<String, dynamic>> diagnostics() async {
    if (!Platform.isAndroid) return {};
    return await _channel
            .invokeMapMethod<String, dynamic>('messagingDiagnostics') ??
        {};
  }

  static Future<void> openSettings(String kind) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('openMessagingSettings', {'kind': kind});
    }
  }

  static Future<void> testAlert(String kind) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('testMessagingAlert', {'kind': kind});
    }
  }

  static Future<Map<String, dynamic>?> takeNotice() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMapMethod<String, dynamic>('takeMessagingNotice');
  }

  static Future<void> stop() async {
    visiblePeer = null;
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('stopMessagingService');
      } catch (_) {}
    }
  }

  static Future<void> clearCall(String id) async {
    if (Platform.isAndroid) {
      try {
        await _channel.invokeMethod('clearMessagingCall', {'callId': id});
      } catch (_) {}
    }
  }

  static Future<void> setVisiblePeer(String? peer) async {
    visiblePeer = peer;
    if (Platform.isAndroid) {
      await _channel.invokeMethod('setMessagingVisiblePeer', {'peerId': peer});
    }
  }

  static Future<Map<String, dynamic>?> takeAction() async {
    if (!Platform.isAndroid) return null;
    final value =
        await _channel.invokeMapMethod<String, dynamic>('takeMessagingAction');
    return value;
  }
}

/// 与原生「待命服务」通信。
///
/// 系统（尤其 MIUI）会冻结后台应用，冻结后 Dart 侧的定时器全部停摆，
/// 观看请求就收不到了。原生前台服务在系统允许其运行时独立轮询，
/// 在通知栏提供「同意 / 拒绝」；不保证进程被清理后仍可接收。
class NativeWatchService {
  static const MethodChannel _channel = MethodChannel('remotescreen/native');

  static bool get supported => Platform.isAndroid;

  /// 注册设备后调用：让服务带着设备凭据开始待命。
  static Future<void> start({
    required String baseUrl,
    required String deviceId,
    required String sessionToken,
  }) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('requestNotificationPermission');
      await _channel.invokeMethod('startWatchService', {
        'baseUrl': baseUrl,
        'deviceId': deviceId,
        'sessionToken': sessionToken,
      });
    } catch (_) {
      // 服务起不来不影响前台使用
    }
  }

  /// 退出登录 / 解绑时调用。
  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _channel.invokeMethod('stopWatchService');
    } catch (_) {}
  }
}

class NativeCallService {
  static const _channel = MethodChannel('remotescreen/native');
  static Future<void> _queue = Future.value();

  static Future<void> prepareCapture(
      {required bool microphone, required bool camera}) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('prepareCallCapture', {
      'microphone': microphone,
      'camera': camera,
    });
  }

  static Future<void> update(String id,
      {required bool microphone,
      required bool camera,
      bool active = false,
      String? callId,
      String? accountId,
      String? clientId,
      String? peerName}) {
    if (!Platform.isAndroid) return Future.value();
    final operation =
        _queue.then((_) => _channel.invokeMethod<void>('updateCallService', {
              'id': id,
              'microphone': microphone,
              'camera': camera,
              'active': active,
              'callId': callId,
              'accountId': accountId,
              'clientId': clientId,
              'peerName': peerName,
            }));
    _queue = operation.catchError((_) {});
    return operation;
  }
}

class NativeVideoOverlay {
  static const _channel = MethodChannel('remotescreen/native');

  static Future<bool> hasPermission() async =>
      Platform.isAndroid &&
      (await _channel.invokeMethod<bool>('hasVideoOverlayPermission') ?? false);

  static Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      return await _channel
              .invokeMethod<bool>('requestVideoOverlayPermission') ??
          false;
    }
    return false;
  }

  static Future<bool> update(String id, String? trackId,
      {bool manual = false,
      bool? visible,
      String? callId,
      String? accountId,
      String kind = 'video',
      String? peerName,
      int? acceptedAt}) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('updateVideoOverlay', {
          'id': id,
          'trackId': trackId,
          'manual': manual,
          'visible': visible ?? trackId != null,
          'callId': callId,
          'accountId': accountId,
          'kind': kind,
          'peerName': peerName,
          'acceptedAt': acceptedAt,
        }) ??
        false;
  }
}

class SelectedNativeFile {
  const SelectedNativeFile({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

/// Android 系统文件选择器与公共下载目录桥接。
///
/// 选择时原生层把 content URI 复制到应用缓存，Dart 才能按块读取；接收完成后
/// 再由原生层通过 MediaStore 写入“下载/RemoteScreen-Files”，无需申请宽泛存储权限。
class NativeFileBridge {
  static const MethodChannel _channel = MethodChannel('remotescreen/native');

  static bool get supported => Platform.isAndroid;

  static Future<void> openReceivedDirectory() async {
    if (!supported) {
      throw UnsupportedError('当前移动平台暂不支持打开文件所在目录');
    }
    await _channel.invokeMethod<void>('openReceivedDirectory');
  }

  static Future<SelectedNativeFile?> pickFile() async {
    if (!supported) {
      throw UnsupportedError('当前移动平台暂不支持文件传输');
    }
    final raw = await _channel.invokeMapMethod<String, dynamic>('pickFile');
    if (raw == null) return null;
    return SelectedNativeFile(
      path: raw['path'] as String,
      name: raw['name'] as String,
      size: (raw['size'] as num).toInt(),
    );
  }

  static Future<String> saveReceivedFile({
    required String sourcePath,
    required String name,
  }) async {
    if (!supported) {
      throw UnsupportedError('当前移动平台暂不支持保存接收文件');
    }
    final path = await _channel.invokeMethod<String>('saveReceivedFile', {
      'sourcePath': sourcePath,
      'name': name,
    });
    if (path == null || path.isEmpty) {
      throw StateError('原生层没有返回文件保存位置');
    }
    return path;
  }
}

/// Android shares image bytes as a scoped content URI, not as a text path.
class NativeChatClipboard {
  static const _channel = MethodChannel('remotescreen/native');
  static Future<bool> hasSystemFeedback() async {
    try {
      return await _channel.invokeMethod<bool>('clipboardHasSystemFeedback') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> copyImage(Uint8List bytes) async {
    await _channel.invokeMethod<void>('copyChatImage', {'bytes': bytes});
  }

  static Future<String?> readImage({String? uri}) =>
      _channel.invokeMethod<String>('readChatImage', {'uri': uri});
}
