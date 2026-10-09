import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 与原生「待命服务」通信。
///
/// 系统（尤其 MIUI）会冻结后台应用，冻结后 Dart 侧的定时器全部停摆，
/// 观看请求就收不到了。原生前台服务带常驻通知不会被冻结，
/// 由它轮询并在通知栏直接提供「同意 / 拒绝」。
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
