// 设备目录服务客户端。
//
// 与桌面端 / 浏览器端调用的是同一套服务端接口（server/README.md 有完整契约），
// 只是这里的 HTTP 客户端换成了 Dart 的 http 包。
//
// 账号令牌存 SharedPreferences —— 移动端没有 localStorage，
// 但语义一致：应用重启后仍保持登录状态。

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart' as digest;
import 'package:flutter/foundation.dart';
import 'chat_outbox.dart';
import 'local_chat.dart';
import 'chat_store.dart';
import 'chat_errors.dart';
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';
import 'native_service.dart';

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
  Account(
      {required this.id,
      required this.email,
      required this.name,
      this.accountId = '',
      this.avatarId = 'cat',
      this.avatarRevision = '',
      this.bio = '',
      this.region = '',
      this.gender = '',
      this.birthday = ''});
  final String avatarId;
  final String avatarRevision, bio, region, gender, birthday;
  final String accountId;
  final String id;
  final String email;
  final String name;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        accountId: json['accountId'] as String? ?? '',
        avatarId: json['avatarId'] as String? ?? 'cat',
        avatarRevision: json['avatarRevision'] as String? ?? '',
        bio: json['bio'] as String? ?? '',
        region: json['region'] as String? ?? '',
        gender: json['gender'] as String? ?? '',
        birthday: json['birthday'] as String? ?? '',
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
    this.fileToken = '',
    required this.deviceName,
  });
  final String deviceId;
  final String password;
  final String sessionToken;
  final String roomName;
  final String livekitUrl;
  final String publishToken;
  final String fileToken;
  final String deviceName;

  /// 换掉连接密码，其余字段不变。
  DeviceRegistration withPassword(String next) => DeviceRegistration(
        deviceId: deviceId,
        password: next,
        sessionToken: sessionToken,
        roomName: roomName,
        livekitUrl: livekitUrl,
        publishToken: publishToken,
        fileToken: fileToken,
        deviceName: deviceName,
      );

  factory DeviceRegistration.fromJson(Map<String, dynamic> json) =>
      DeviceRegistration(
        deviceId: json['deviceId'] as String,
        password: json['password'] as String,
        sessionToken: json['sessionToken'] as String,
        roomName: json['roomName'] as String,
        livekitUrl: json['livekitUrl'] as String,
        publishToken: json['token'] as String,
        fileToken: json['fileToken'] as String? ?? '',
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

/// 观看方发起的请求句柄。
class ConnectRequestHandle {
  ConnectRequestHandle({
    required this.requestId,
    required this.owned,
    required this.deviceName,
    required this.expiresInSec,
  });

  final String requestId;

  /// 是否是自己名下的设备（界面上可据此提示，但确认流程一样要走）
  final bool owned;
  final String deviceName;
  final int expiresInSec;
}

/// 服务端下发给设备的「观看请求」。
class ConnectRequestInfo {
  ConnectRequestInfo({
    required this.requestId,
    this.purpose = 'screen',
    required this.viewerName,
    required this.expiresInSec,
  });

  final String requestId;
  final String purpose;
  final String viewerName;
  final int expiresInSec;

  factory ConnectRequestInfo.fromJson(Map<String, dynamic> json) {
    return ConnectRequestInfo(
      purpose: json['purpose'] as String? ?? 'screen',
      requestId: json['requestId'] as String? ?? '',
      viewerName: json['viewerName'] as String? ?? '未知设备',
      expiresInSec: (json['expiresInSec'] as num?)?.toInt() ?? 60,
    );
  }
}

class ApiService {
  ApiService({required this.baseUrl});

  final String baseUrl;
  Future<Map<String, dynamic>> fileTransferHistory({String? before}) async {
    final token = await _token();
    if (token == null) throw ApiException('unauthorized', '请先登录');
    final result = await _request('GET', '/v1/file-transfers${before == null ? '' : '?before=${Uri.encodeComponent(before)}'}', expectedToken: token);
    if (await _token() != token) throw ApiException('session_changed', '账号已变化，请重新加载');
    return result;
  }

  Future<String> createFileTransferRecord(String grant, String deviceId,
      String clientId, String name, int size) async {
    final result = await _request('POST', '/v1/file-transfers', body: {
      'grant': grant, 'senderDeviceId': deviceId, 'clientId': clientId,
      'name': name, 'size': size,
    });
    return result['transfer']['id'] as String;
  }

  Future<void> finishFileTransferRecord(String id, String status) async {
    await _request('PATCH', '/v1/file-transfers/${Uri.encodeComponent(id)}', body: {'status': status});
  }
  late final LocalChat localChat=LocalChat(currentToken:_token,
    remote:(operation,body,token)=>_request(operation=='state'?'GET':'POST','/v1/social/$operation',body:operation=='state'?null:body,expectedToken:token,timeoutSeconds:operation=='local-image'||operation=='message-image'||operation=='send-image'?45:15),
    video:_downloadChatVideoRemote);
  Future<void> syncLocalChat() async {final token=await _token();if(token==null)throw ApiException('unauthorized','请先登录');await localChat.syncAll(token);}
  Future<String> chatOwner() async {final token=await _token();if(token==null)throw ApiException('unauthorized','请先登录');return localChat.owner(token);}

  Future<ChatSender> captureChatSender() async {
    final token = await _token();
    if (token == null) throw ApiException('unauthorized', '请先登录');
    return (operation,body) async {
      final result=operation=='send-video'?await _uploadChatVideo(body,token):await localChat.call(operation,body,token);
      if(operation=='send-video')await localChat.record(token,body['peerId'],result);
      return result;
    };
  }

  Future<void> startAccountNotifications(Account account) async {
    final token = await _token();
    if (token != null) await NativeMessaging.start(baseUrl, token, account.id);
  }

  Future<Map<String, dynamic>> social(String operation,
      [Map<String, dynamic>? body]) async {
    if (!const {
      'account-profile',
      'avatar-image',
      'avatar',
      'state',
      'search',
      'request',
      'decision',
      'profile',
      'history',
      'message-context',
      'clear-history',
      'messages',
      'send',
      'send-image',
      'message-image',
      'message-video',
      'recall',
      'read',
      'call-start',
      'call-state',
      'call-decision',
      'call-end'
    }.contains(operation)) {
      throw ArgumentError('不支持的好友操作');
    }
    final token=await _token();if(token==null)throw ApiException('unauthorized','请先登录');
    try{return await localChat.call(operation,body??{},token);}
    on DatabaseException catch(e){throw ApiException('local_storage',chatError(e));}
    on FormatException catch(e){final message=chatError(e);throw ApiException(message.contains('账号已变化')?'session_changed':'local_chat',message,status:message.contains('已撤回')?410:null);}
  }

  static const _tokenKey = 'remotescreen.accountToken';

  Future<String?> _token() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<void> _saveToken(String? token) async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_tokenKey) != token) chatOutbox.reset();
    if (token == null) {
      localChat.callBusy=false;localChat.screenBusy=false;
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
    String? expectedToken,
  }) async {
    final headers = <String, String>{};
    if (body != null) headers['Content-Type'] = 'application/json';

    final token = auth ? await _token() : null;
    if (expectedToken != null && token != expectedToken) {
      throw ApiException('session_changed', '账号已变化，请重新发送');
    }
    if (token != null) headers['Authorization'] = 'Bearer $token';

    http.Response response;
    try {
      final request = http.Request(method, Uri.parse('$baseUrl$path'))
        ..headers.addAll(headers);
      if (body != null) {
        request.body = path == '/v1/social/send-image' &&
                (body['image'] as String? ?? '').length > 1024 * 1024
            ? await compute(jsonEncode, body)
            : jsonEncode(body);
      }

      final streamed =
          await request.send().timeout(Duration(seconds: timeoutSeconds));
      response = await http.Response.fromStream(streamed)
          .timeout(Duration(seconds: timeoutSeconds));
    } catch (cause) {
      throw ApiException('network', '连不上服务器，请检查网络或服务器地址');
    }

    return _parseResponse(response, token, auth);
  }

  Future<Map<String, dynamic>> _parseResponse(
      http.Response response, String? token, bool auth) async {
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
      if (response.statusCode == 401 && auth && await _token() == token) {
        await _saveToken(null);
      }
      throw ApiException(
        error?['code'] as String? ?? 'unknown',
        error?['message'] as String? ?? '请求失败（HTTP ${response.statusCode}）',
        status: response.statusCode,
        details: error ?? {},
      );
    }
    return parsed;
  }

  Future<Map<String, dynamic>> _uploadChatVideo(
      Map<String, dynamic> body, String token) async {
    if (await _token() != token) {
      throw ApiException('session_changed', '账号已变化，请重新发送');
    }
    final file = File(body['videoPath'] as String);
    int size;
    try {
      size = await file.length();
    } on FileSystemException {
      throw ApiException('video_missing', '视频文件不可用，请重新选择');
    }
    if (size > 50 * 1024 * 1024) {
      throw ApiException('too_large', '视频过大，请选择 50 MB 以内的视频');
    }
    final url = Uri.parse(
            '$baseUrl/v1/social/videos/${Uri.encodeComponent(body['clientId'])}')
        .replace(queryParameters: {'peerId': body['peerId']});
    final request = http.StreamedRequest('PUT', url)
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/octet-stream'
      })
      ..contentLength = size;
    try {
      final reply = request.send().timeout(const Duration(seconds: 240));
      unawaited(reply.then<void>((_) {}, onError: (Object _) {}));
      await request.sink
          .addStream(file.openRead())
          .timeout(const Duration(seconds: 240));
      await request.sink.close();
      final response = await http.Response.fromStream(await reply)
          .timeout(const Duration(seconds: 240));
      return await _parseResponse(response, token, true);
    } on ApiException {
      rethrow;
    } catch (_) {
      throw ApiException('network', '连不上服务器，请检查网络或服务器地址');
    }
  }

  Future<File> downloadChatVideo(String peerId,String messageId) async {
    final token=await _token();if(token==null)throw ApiException('unauthorized','请先登录');
    return localChat.videoFile(peerId,messageId,token);
  }
  Future<File> _downloadChatVideoRemote(String peerId,String messageId,String token,bool background) async {
    final result = await _request('POST', '/v1/social/local-video',
        body: {'peerId': peerId, 'messageId': messageId}, expectedToken: token);
    final meta = result['message']?['video'] as Map<String, dynamic>?;
    final size = (meta?['bytes'] as num?)?.toInt() ?? 0, sha = meta?['sha256'];
    if (size < 1 ||
        size > 50 * 1024 * 1024 ||
        sha is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw ApiException('video', '视频信息无效');
    }
    final dir = await Directory.systemTemp.createTemp('rs-chat-video-');
    final file = File('${dir.path}/video.mp4');
    try {
      final request = http.Request(
          'GET',
          Uri.parse(
                  '$baseUrl/v1/social/videos/${Uri.encodeComponent(messageId)}')
              .replace(queryParameters: {'peerId': peerId,'archive':'1'}))
        ..headers['Authorization'] = 'Bearer $token';
      final response =
          await request.send().timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        await _parseResponse(
            await http.Response.fromStream(response), token, true);
        throw ApiException('video', '视频下载失败，请重试');
      }
      final sink = file.openWrite();
      var bytes = 0;
      try {
        await for (final chunk
            in response.stream.timeout(const Duration(seconds: 30))) {
          if(background&&localChat.mediaBlocked)throw ApiException('media_deferred','通话或投屏期间暂缓媒体下载');
          bytes += chunk.length;
          if (bytes > size) throw ApiException('video', '视频下载校验失败，请重试');
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (bytes != size || await compute(_chatVideoDigest, file.path) != sha) {
        throw ApiException('video', '视频下载校验失败，请重试');
      }
      if (await _token() != token) {
        throw ApiException('session_changed', '账号已变化，请重新打开视频');
      }
      return file;
    } catch (error) {
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  /// 设备凭据的持久化。
  ///
  /// 服务端靠它识别「这是同一台设备」—— 不存的话每次启动都会被当作新设备，
  /// 账号下会堆一堆离线设备。桌面端对应的是 device-store.js（0600 权限的 JSON）。
  Future<({String? deviceId, String? sessionToken})>
      loadDeviceCredentials() async {
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
    final result = await _request('POST', '/v1/auth/register',
        body: {
          'email': email,
          'password': password,
          'name': name,
        },
        auth: false);
    await _saveToken(result['token'] as String);
    final store=await localChat.store,user=result['user'] as Map<String,dynamic>;await store.bind(result['token'],user['id']);await ChatStore.set(store.db,user['id'],'account',jsonEncode(user));
    return Account.fromJson(result['user'] as Map<String, dynamic>);
  }

  Future<Account> login({
    required String email,
    required String password,
  }) async {
    final result = await _request('POST', '/v1/auth/login',
        body: {
          'email': email,
          'password': password,
        },
        auth: false);
    await _saveToken(result['token'] as String);
    final store=await localChat.store,user=result['user'] as Map<String,dynamic>;await store.bind(result['token'],user['id']);await ChatStore.set(store.db,user['id'],'account',jsonEncode(user));
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
    try {
      final result = await _request('GET', '/v1/me');
      final token=await _token();
      if(token!=null){final store=await localChat.store;final user=result['user'] as Map<String,dynamic>;await store.bind(token,user['id']);await ChatStore.set(store.db,user['id'],'account',jsonEncode(user));}
      return Account.fromJson(result['user'] as Map<String, dynamic>);
    } on ApiException catch(e) {
      if(e.code!='network')rethrow;
      final token=await _token();if(token==null)rethrow;
      final store=await localChat.store,id=await store.owner(token);if(id==null)rethrow;
      final cached=await store.get(id,'account');if(cached==null)rethrow;
      return Account.fromJson(jsonDecode(cached));
    }
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

  /// 长轮询：把连接挂住等「新的观看请求」，服务端一有变化立刻返回。
  ///
  /// 取代了原来 15 秒一次的定时心跳 —— 它同时也在刷新在线状态，
  /// 请求送达延迟从「最坏 15 秒」降到百毫秒级。
  Future<List<ConnectRequestInfo>> waitNotifications({
    required String deviceId,
    required String sessionToken,
    int waitSec = 25,
    List<String> seen = const [],
  }) async {
    final result = await _request(
      'POST',
      '/v1/devices/$deviceId/notifications',
      // seen：已经知道的请求 id。不带它的话，服务端一见有请求就立刻返回，
      // 客户端拿到又马上再问 —— 会变成每秒好几次的空转。
      body: {'sessionToken': sessionToken, 'waitSec': waitSec, 'seen': seen},
      // 服务端会把连接挂住 waitSec 秒，读超时要留出余量
      timeoutSeconds: waitSec + 15,
    );
    return _parseRequests(result);
  }

  /// 普通心跳（长轮询失败时兜底保活）。
  Future<List<ConnectRequestInfo>> heartbeat(
    String deviceId,
    String sessionToken,
  ) async {
    final result = await _request('POST', '/v1/devices/$deviceId/heartbeat',
        body: {'sessionToken': sessionToken});
    return _parseRequests(result);
  }

  List<ConnectRequestInfo> _parseRequests(Map<String, dynamic> result) {
    final raw = (result['pendingRequests'] as List?) ?? const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(ConnectRequestInfo.fromJson)
        .toList();
  }

  /// 取消自己发出的观看请求（对方那边会立刻不再显示）。
  Future<void> cancelConnectRequest(String requestId) async {
    await _request('DELETE', '/v1/connect-requests/$requestId');
  }

  /// 发起观看请求（无密码连接时用），返回请求句柄。
  Future<ConnectRequestHandle> createConnectRequest({
    required String deviceId,
    String viewerName = 'Flutter 观看端',
    String purpose = 'screen',
  }) async {
    final result = await _request('POST', '/v1/connect-requests', body: {
      'deviceId': deviceId,
      'viewerName': viewerName,
      'purpose': purpose,
    });
    return ConnectRequestHandle(
      requestId: result['requestId'] as String? ?? '',
      owned: result['owned'] as bool? ?? false,
      deviceName: result['deviceName'] as String? ?? '远程设备',
      expiresInSec: (result['expiresInSec'] as num?)?.toInt() ?? 60,
    );
  }

  /// 轮询观看请求：还在等待返回 null；同意则直接返回可连接的会话；
  /// 被拒绝或过期抛出带原因的异常。
  Future<ViewerSession?> pollConnectRequest(String requestId,
      {int waitSec = 0}) async {
    final path = waitSec > 0
        ? '/v1/connect-requests/$requestId?wait=$waitSec'
        : '/v1/connect-requests/$requestId';
    final result = await _request('GET', path, timeoutSeconds: waitSec + 15);
    switch (result['status'] as String? ?? 'pending') {
      case 'approved':
        return ViewerSession.fromJson({...result, 'via': 'approval'});
      case 'denied':
        throw ApiException('denied', '对方拒绝了这次观看请求');
      case 'cancelled':
        throw ApiException('cancelled', '连接请求已取消');
      case 'expired':
        throw ApiException('expired', '对方没有在有效期内确认，请求已过期');
      default:
        return null;
    }
  }

  /// 设置连接密码：password 为 null 时随机刷新，给出时采用自定义值。
  /// 需要设备自己的 sessionToken（账号主人改不了别台设备的密码）。
  Future<String> setDevicePassword({
    required String deviceId,
    required String sessionToken,
    String? password,
  }) async {
    final result =
        await _request('POST', '/v1/devices/$deviceId/password', body: {
      'sessionToken': sessionToken,
      if (password != null) 'password': password,
    });
    return result['password'] as String;
  }

  /// 同意 / 拒绝一次观看请求。设备凭据即身份凭证。
  Future<void> decideConnectRequest({
    required String requestId,
    required String sessionToken,
    required bool approve,
  }) async {
    await _request('POST', '/v1/connect-requests/$requestId/decision',
        body: {'sessionToken': sessionToken, 'approve': approve});
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
    String viewerName = 'Flutter 观看端',
    String purpose = 'screen',
  }) async {
    final result = await _request('POST', '/v1/connect', body: {
      'deviceId': deviceId,
      if (password != null && password.isNotEmpty) 'password': password,
      'viewerName': viewerName,
      'purpose': purpose,
    });
    return ViewerSession.fromJson(result);
  }
}

Future<String> _chatVideoDigest(String path) async =>
    (await digest.sha256.bind(File(path).openRead()).first).toString();
