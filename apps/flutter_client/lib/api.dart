// 设备目录服务客户端。
//
// 与桌面端 / 浏览器端调用的是同一套服务端接口（server/README.md 有完整契约），
// 只是这里的 HTTP 客户端换成了 Dart 的 http 包。
//
// 账号令牌存 SharedPreferences —— 移动端没有 localStorage，
// 但语义一致：应用重启后仍保持登录状态。

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// 全局唯一实例，各界面直接 import api.dart 使用
final ApiService api = ApiService(baseUrl: kServerUrl);

class ApiException implements Exception {
  ApiException(this.code, this.message, {this.status, this.details});
  final String code;
  final String message;
  final int? status;
  final Map<String, dynamic>? details;

  @override
  String toString() => message;
}

class Account {
  Account({required this.id, required this.email, required this.name});
  final String id;
  final String email;
  final String name;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        email: json['email'] as String,
        name: json['name'] as String,
      );
}

class Device {
  Device({
    required this.deviceId,
    required this.name,
    required this.platform,
    required this.online,
  });
  final String deviceId;
  final String name;
  final String platform;
  final bool online;

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        deviceId: json['deviceId'] as String,
        name: json['name'] as String,
        platform: json['platform'] as String? ?? 'unknown',
        online: json['online'] as bool? ?? false,
      );
}

/// 注册设备后由服务端下发的完整连接要素
class DeviceRegistration {
  DeviceRegistration({
    required this.deviceId,
    required this.password,
    required this.sessionToken,
    required this.roomName,
    required this.livekitUrl,
    required this.publishToken,
    required this.deviceName,
  });
  final String deviceId;
  final String password;
  final String sessionToken;
  final String roomName;
  final String livekitUrl;
  final String publishToken;
  final String deviceName;

  factory DeviceRegistration.fromJson(Map<String, dynamic> json) =>
      DeviceRegistration(
        deviceId: json['deviceId'] as String,
        password: json['password'] as String,
        sessionToken: json['sessionToken'] as String,
        roomName: json['roomName'] as String,
        livekitUrl: json['livekitUrl'] as String,
        publishToken: json['token'] as String,
        deviceName: json['deviceName'] as String? ?? '未命名设备',
      );
}

/// 观看端换取到的连接要素
class ViewerSession {
  ViewerSession({
    required this.deviceId,
    required this.deviceName,
    required this.roomName,
    required this.livekitUrl,
    required this.subscribeToken,
    required this.via,
  });
  final String deviceId;
  final String deviceName;
  final String roomName;
  final String livekitUrl;
  final String subscribeToken;
  final String via;

  factory ViewerSession.fromJson(Map<String, dynamic> json) => ViewerSession(
        deviceId: json['deviceId'] as String? ?? '',
        deviceName: json['deviceName'] as String? ?? '已连接',
        roomName: json['roomName'] as String,
        livekitUrl: json['livekitUrl'] as String,
        subscribeToken: json['token'] as String,
        via: json['via'] as String? ?? 'password',
      );
}

class ApiService {
  ApiService({required this.baseUrl});

  final String baseUrl;
  static const _tokenKey = 'remotescreen.accountToken';

  Future<String?> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<void> _saveToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (token == null) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, token);
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
    bool auth = true,
    int timeoutSeconds = 15,
  }) async {
    final headers = <String, String>{};
    if (body != null) headers['Content-Type'] = 'application/json';

    if (auth) {
      final token = await _token();
      if (token != null) headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;
    try {
      final request = http.Request(method, Uri.parse('$baseUrl$path'))
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);

      final streamed = await request.send().timeout(Duration(seconds: timeoutSeconds));
      response = await http.Response.fromStream(streamed);
    } catch (cause) {
      throw ApiException('network', '连不上服务器，请检查网络或服务器地址');
    }

    final text = response.body;
    Map<String, dynamic> parsed = {};
    try {
      parsed = text.isNotEmpty ? jsonDecode(text) as Map<String, dynamic> : {};
    } catch (_) {
      parsed = {};
    }

    if (response.statusCode >= 400) {
      final error = parsed['error'] as Map<String, dynamic>?;
      // 令牌失效就地清掉，避免界面一直拿着坏令牌重试
      if (response.statusCode == 401 && auth) await _saveToken(null);
      throw ApiException(
        error?['code'] as String? ?? 'unknown',
        error?['message'] as String? ?? '请求失败（HTTP ${response.statusCode}）',
        status: response.statusCode,
        details: error ?? {},
      );
    }
    return parsed;
  }

  /// 设备凭据的持久化。
  ///
  /// 服务端靠它识别「这是同一台设备」—— 不存的话每次启动都会被当作新设备，
  /// 账号下会堆一堆离线设备。桌面端对应的是 device-store.js（0600 权限的 JSON）。
  Future<({String? deviceId, String? sessionToken})> loadDeviceCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      deviceId: prefs.getString('remotescreen.deviceId'),
      sessionToken: prefs.getString('remotescreen.sessionToken'),
    );
  }

  Future<void> saveDeviceCredentials({
    required String deviceId,
    required String sessionToken,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('remotescreen.deviceId', deviceId);
    await prefs.setString('remotescreen.sessionToken', sessionToken);
  }

  Future<Account> register({
    required String email,
    required String password,
    required String name,
  }) async {
    final result = await _request('POST', '/v1/auth/register', body: {
      'email': email,
      'password': password,
      'name': name,
    }, auth: false);
    await _saveToken(result['token'] as String);
    return Account.fromJson(result['user'] as Map<String, dynamic>);
  }

  Future<Account> login({
    required String email,
    required String password,
  }) async {
    final result = await _request('POST', '/v1/auth/login', body: {
      'email': email,
      'password': password,
    }, auth: false);
    await _saveToken(result['token'] as String);
    return Account.fromJson(result['user'] as Map<String, dynamic>);
  }

  Future<void> logout() async {
    try {
      await _request('POST', '/v1/auth/logout');
    } finally {
      await _saveToken(null);
    }
  }

  Future<Account> me() async {
    final result = await _request('GET', '/v1/me');
    return Account.fromJson(result['user'] as Map<String, dynamic>);
  }

  Future<List<Device>> listDevices() async {
    final result = await _request('GET', '/v1/devices');
    return (result['devices'] as List)
        .map((item) => Device.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<DeviceRegistration> registerDevice({
    required String platform,
    required String deviceName,
  }) async {
    final stored = await loadDeviceCredentials();
    final result = await _request('POST', '/v1/devices/register', body: {
      if (stored.deviceId != null) 'deviceId': stored.deviceId,
      if (stored.sessionToken != null) 'sessionToken': stored.sessionToken,
      'platform': platform,
      'deviceName': deviceName,
    });
    final registration = DeviceRegistration.fromJson(result);
    // 服务端每次注册都会轮换 sessionToken，必须覆盖写入
    await saveDeviceCredentials(
      deviceId: registration.deviceId,
      sessionToken: registration.sessionToken,
    );
    return registration;
  }

  Future<void> heartbeat(String deviceId, String sessionToken) async {
    await _request('POST', '/v1/devices/$deviceId/heartbeat',
        body: {'sessionToken': sessionToken});
  }

  Future<String> refreshDevicePassword({
    required String deviceId,
    required String sessionToken,
  }) async {
    final result = await _request('POST', '/v1/devices/$deviceId/password',
        body: {'sessionToken': sessionToken});
    return result['password'] as String;
  }

  Future<ViewerSession> connect({
    required String deviceId,
    String? password,
  }) async {
    final result = await _request('POST', '/v1/connect', body: {
      'deviceId': deviceId,
      if (password != null && password.isNotEmpty) 'password': password,
      'viewerName': 'Flutter 观看端',
    });
    return ViewerSession.fromJson(result);
  }
}
