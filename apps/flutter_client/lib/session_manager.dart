import 'dart:convert';
// 会话管理器 —— 应用级单例，持有所有连接的生命周期。
//
// 这层存在的意义：把「连接」从页面生命周期里解放出来。
// 之前 Room 在观看页的 State 里创建、在 dispose 时销毁，
// 用户一返回列表页连接就没了 —— 那是把「看连接的窗口」当成了「连接本身」。
//
// 正确的语义：
//   · 会话由这里持有，页面只是展示它的窗口
//   · 只有三种情况会真正断开：用户手动断开、投送端停止、网络不可用
//   · 退出登录会断开全部（凭据失效，必须断）

import 'dart:async';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'native_service.dart';

/// 投屏质量设置（持久化到 SharedPreferences）。
///
/// height = 0 表示跟随手机屏幕原始分辨率；否则按该高度等比缩放（保持宽高比）。
class ScreenShareSettings {
  const ScreenShareSettings({required this.height, required this.fps});

  /// 采集高度上限：720 / 1080 / 0（原始）
  final int height;

  /// 采集帧率：15 / 30 / 60
  final int fps;

  static const _heightKey = 'remotescreen.shareHeight';
  static const _fpsKey = 'remotescreen.shareFps';

  static const defaults = ScreenShareSettings(height: 1080, fps: 30);

  static Future<ScreenShareSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    return ScreenShareSettings(
      height: prefs.getInt(_heightKey) ?? defaults.height,
      fps: prefs.getInt(_fpsKey) ?? defaults.fps,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_heightKey, height);
    await prefs.setInt(_fpsKey, fps);
  }

  ScreenShareSettings copyWith({int? height, int? fps}) =>
      ScreenShareSettings(height: height ?? this.height, fps: fps ?? this.fps);

  /// 编码上限（发布端）：livekit 的默认 screenShareEncoding 是 1080p@15fps，
  /// 不覆盖它的话采集端帧率再高也会被编码器钳到 15。
  VideoEncoding toEncoding() {
    final int maxBitrate;
    if (height == 0) {
      maxBitrate = switch (fps) { 60 => 12 * 1000 * 1000, 30 => 8 * 1000 * 1000, _ => 5 * 1000 * 1000 };
    } else if (height <= 720) {
      maxBitrate = switch (fps) { 60 => 4 * 1000 * 1000, 30 => 2500 * 1000, _ => 1500 * 1000 };
    } else {
      maxBitrate = switch (fps) { 60 => 6 * 1000 * 1000, 30 => 3800 * 1000, _ => 2500 * 1000 };
    }
    return VideoEncoding(maxBitrate: maxBitrate, maxFramerate: fps);
  }

  /// 转成 livekit 的投屏采集参数。
  ///
  /// 约束值表示「屏幕长边」上限（竖屏=高、横屏=宽），原生补丁版
  /// flutter_webrtc 按它等比缩放采集；height=0 表示不约束（原始分辨率）。
  ScreenShareCaptureOptions toCaptureOptions() {
    // dimensions 只用来向原生层传递长边约束（width, height 中取大者）
    final dims = height == 0
        ? const VideoDimensions(0, 0)
        : height <= 720
            ? const VideoDimensions(1280, 720)
            : const VideoDimensions(1920, 1080);

    return ScreenShareCaptureOptions(
      params: VideoParameters(dimensions: dims, encoding: toEncoding()),
    );
  }
}

/// 一个观看会话的状态。
enum ViewingSessionState {
  connecting, // 正在连接
  waiting,    // 已连上但对方还没开始投送
  live,       // 画面正常
  reconnecting, // 网络波动重连中
  peerEnded,  // 对端停止了投送（会话保留，对方恢复后自动回到 live）
  ended,      // 已断开
}

/// 进行中的一路观看会话。
class ViewingSession extends ChangeNotifier {
  ViewingSession({
    required this.id,
    required this.deviceId,
    required this.deviceName,
    required this.room,
  }) {
    // livekit_client 的 Room 是 ChangeNotifier，轨道与状态变化都会通知
    room.addListener(_syncFromRoom);
  }

  final String id;
  final String deviceId;
  final String deviceName;
  final Room room;

  final DateTime startedAt = DateTime.now();

  RemoteVideoTrack? videoTrack;
  ViewingSessionState state = ViewingSessionState.connecting;

  Duration get duration => DateTime.now().difference(startedAt);

  /// 把房间的状态同步到会话上。
  ///
  /// 注意房间事件是异步到达的：即使本会话已被手动断开，
  /// 迟到的回调也可能触发这里 —— 所以断开后要摘掉监听。
  void _syncFromRoom() {
    // 对端画面
    RemoteVideoTrack? found;
    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.videoTrackPublications) {
        final track = publication.track;
        if (track is RemoteVideoTrack && publication.subscribed) {
          found ??= track;
        }
      }
    }
    final hadVideo = videoTrack != null;
    videoTrack = found;

    // 连接状态映射
    switch (room.connectionState) {
      case ConnectionState.connected:
        state = videoTrack != null
            ? ViewingSessionState.live
            : (hadVideo ? ViewingSessionState.live : ViewingSessionState.waiting);
      case ConnectionState.reconnecting:
        state = ViewingSessionState.reconnecting;
      case ConnectionState.disconnected:
        // 房间被服务端断开（对端把房间关了）→ 视为对端结束
        state = ViewingSessionState.peerEnded;
      default:
        state = ViewingSessionState.connecting;
    }

    // 音频轨订阅状态变化时记一条日志（排障用：确认远端音频有没有被订阅）
    final hasAudioNow = room.remoteParticipants.values
        .any((participant) => participant.audioTrackPublications.any((pub) => pub.subscribed));
    if (hasAudioNow != _lastAudioSubscribed) {
      _lastAudioSubscribed = hasAudioNow;
      debugPrint('RemoteScreen 音频轨订阅: $hasAudioNow');
    }

    notifyListeners();
  }

  /// 上一次的音频订阅状态（用于变化检测，避免刷日志）。
  bool _lastAudioSubscribed = false;

  /// 用户主动断开。
  ///
  /// 顺序很重要：**先标记结束并通知界面**，界面据此撤掉视频渲染器（否则会短暂渲染
  /// 已被销毁的轨道，触发原生层异常 → 真机上就是满屏红），然后再拆房间连接。
  /// 拆连接本身的异常不向用户抛：连接已经在断开了，这里失败不该影响体验。
  Future<void> disconnect() async {
    room.removeListener(_syncFromRoom);
    state = ViewingSessionState.ended;
    notifyListeners();
    try {
      await room.disconnect();
    } catch (error) {
      debugPrint('断开房间失败（忽略）：$error');
    }
  }
}

/// 观看请求的取消令牌：界面点「取消」后置位，轮询循环会尽快结束并通知服务端。
class WatchRequestToken {
  WatchRequestToken();

  /// 请求 id 由 watchDevice 填入，取消时用它通知服务端
  String? requestId;
  bool cancelled = false;
}

/// 会话管理器：应用级单例。
///
/// 持有投送连接与全部观看会话 —— 它们活在应用生命周期里，
/// 页面进进出出、前后台切换都不影响。
class SessionManager extends ChangeNotifier {
  SessionManager({required this.api});

  final ApiService api;

  // ---- 心跳（设备在线）----
  Timer? _heartbeat;
  /// 长轮询循环的「代」：递增即让旧循环退出
  int _heartbeatGeneration = 0;
  DeviceRegistration? registration;

  // ---- 投送 ----
  Room? _publishRoom;
  bool get publishing => _publishRoom != null;

  /// 当前投屏质量设置（启动时加载，界面可改）
  ScreenShareSettings shareSettings = ScreenShareSettings.defaults;

  Future<void> loadShareSettings() async {
    shareSettings = await ScreenShareSettings.load();
    notifyListeners();
  }

  // ---- 观看会话 ----
  final Map<String, ViewingSession> _sessions = {};
  /// 进行中的观看会话（不含已断开的）
  List<ViewingSession> get activeSessions =>
      _sessions.values.where((s) => s.state != ViewingSessionState.ended).toList();

  ViewingSession? sessionById(String id) => _sessions[id];

  // MARK: - 设备注册

  /// 注册本机设备并开始心跳。应用启动（已登录）时调用。
  Future<DeviceRegistration> registerDevice({
    required String platform,
    required String deviceName,
  }) async {
    // 带上本地持久化的设备凭据，服务端才能认出这是同一台设备、沿用原设备 ID
    final reg = await api.registerDevice(
      platform: platform,
      deviceName: deviceName,
    );
    startHeartbeat(reg);
    // 让原生待命服务接管后台：MIUI 冻结应用后仍能收到观看请求
    await NativeWatchService.start(
      baseUrl: api.baseUrl,
      deviceId: reg.deviceId,
      sessionToken: reg.sessionToken,
    );
    return reg;
  }

  // MARK: - 心跳

  void startHeartbeat(DeviceRegistration reg) {
    registration = reg;
    _heartbeat?.cancel();
    // 长轮询循环：连接挂住等请求，服务端一有变化立刻返回（同时兼作心跳）。
    // 「代」计数用于让旧循环在重启心跳时自行退出。
    _heartbeatGeneration += 1;
    unawaited(_notificationLoop(_heartbeatGeneration));
  }

  /// 立刻撤销一个观看请求（界面点「取消」时调用，不等长轮询返回）。
  ///
  /// 只在客户端停轮询是不够的：设备端是靠服务端下发的列表弹窗的，
  /// 不撤销的话对方那边会一直看到这个请求（直到 60 秒过期）。
  void cancelWatchRequest(String requestId) {
    unawaited(api.cancelConnectRequest(requestId).catchError((_) {}));
  }

  /// 设置/刷新连接密码，返回更新后的注册对象（界面据此刷新显示）。
  Future<DeviceRegistration> setConnectionPassword(String? password) async {
    final current = registration;
    if (current == null) throw ApiException('unauthorized', '设备尚未注册');

    final applied = await api.setDevicePassword(
      deviceId: current.deviceId,
      sessionToken: current.sessionToken,
      password: password,
    );
    final updated = current.withPassword(applied);
    registration = updated;
    notifyListeners();
    return updated;
  }

  /// SSE 长连接循环：服务端一有变化立刻推（实测 ~10ms），
  /// 连接每 10 分钟由服务端轮换一次，这里自动重连即可。
  /// 心跳也由服务端在流内处理（每 15 秒刷新在线状态），客户端不再需要定时上报。
  Future<void> _notificationLoop(int generation) async {
    while (_heartbeatGeneration == generation) {
      final reg = registration;
      if (reg == null) return;

      final client = http.Client();
      try {
        final request = http.Request(
          'GET',
          Uri.parse('${api.baseUrl}/v1/devices/${reg.deviceId}/notifications/stream'),
        );
        request.headers['X-Device-Token'] = reg.sessionToken;
        request.headers['Accept'] = 'text/event-stream';

        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw ApiException('stream', '通知流连接失败（HTTP ${response.statusCode}）');
        }
        if (_heartbeatGeneration != generation) return;

        var buffer = '';
        await for (final chunk in response.stream.transform(utf8.decoder)) {
          if (_heartbeatGeneration != generation) return;
          buffer += chunk;

          // 按「空行」切事件块
          while (buffer.contains('\n\n')) {
            final boundary = buffer.indexOf('\n\n');
            final block = buffer.substring(0, boundary + 2);
            buffer = buffer.substring(boundary + 2);
            _handleEventBlock(block);
          }
        }
        // 流正常结束（服务端 10 分钟轮换）→ 循环重连
      } catch (_) {
        // 网络抖动：退回一次普通心跳保活，稍后重连
        try {
          await api.heartbeat(reg.deviceId, reg.sessionToken);
        } catch (_) {
          // 真的连不上，等一会儿再说
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      } finally {
        client.close();
      }
    }
  }

  /// 解析一条 SSE 事件块，把请求列表同步到本地状态。
  void _handleEventBlock(String block) {
    String eventName = '';
    String data = '';
    for (final line in block.split('\n')) {
      if (line.startsWith('event:')) eventName = line.substring(6).trim();
      if (line.startsWith('data:')) data = line.substring(5).trim();
    }
    if (data.isEmpty) return;
    final parsed = jsonDecode(data) as Map<String, dynamic>;

    // 有观看者连入（同账号直连时服务端通知）：自动打开「允许远程观看本设备」。
    // 仅在前台执行 —— Android 的录屏授权弹窗必须由用户在界面上确认，
    // 应用在后台时弹不出来，等用户回到应用再由下一次通知触发。
    if (eventName == 'viewer-connected') {
      final reg = registration;
      final resumed =
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
      if (reg != null && !publishing && resumed) {
        unawaited(
          startPublishing(reg).catchError(
            (Object error) => debugPrint('观看者连入后自动开启投送失败：$error'),
          ),
        );
      }
      return;
    }

    if (eventName != 'requests') return;

    final raw = (parsed['pendingRequests'] as List?) ?? const [];
    final incoming = raw
        .whereType<Map<String, dynamic>>()
        .map(ConnectRequestInfo.fromJson)
        .toList();

    if (incoming.isEmpty) {
      if (pendingRequests.isNotEmpty) {
        pendingRequests = [];
        notifyListeners();
      }
      return;
    }

    // 只保留还没处理过的请求，避免重复弹窗
    final fresh = incoming
        .where((request) => !_handledRequestIds.contains(request.requestId))
        .toList();
    if (fresh.isNotEmpty) {
      pendingRequests = [...pendingRequests, ...fresh];
      notifyListeners();
    }
  }

  /// 待用户处理的观看请求（界面据此弹窗）。
  List<ConnectRequestInfo> pendingRequests = [];

  /// 已处理过的请求 id（同意/拒绝/超时后不再弹窗）。
  final Set<String> _handledRequestIds = {};

  /// 用户对观看请求做出决定。
  Future<void> decideRequest(ConnectRequestInfo request, bool approve) async {
    final reg = registration;
    if (reg == null) return;
    _handledRequestIds.add(request.requestId);
    pendingRequests = pendingRequests
        .where((item) => item.requestId != request.requestId)
        .toList();
    notifyListeners();
    try {
      await api.decideConnectRequest(
        requestId: request.requestId,
        sessionToken: reg.sessionToken,
        approve: approve,
      );
    } catch (_) {
      // 失败就让它自然过期，界面上不再提示
      return;
    }

    // 同意观看后自动开启投送（等价于手动打开「允许远程观看本设备」），
    // 否则对方连上了也看不到画面。
    if (approve && !publishing) {
      try {
        await startPublishing(reg);
      } catch (error) {
        debugPrint('同意后自动开启投送失败：$error');
      }
    }
  }

  void stopHeartbeat() {
    _heartbeatGeneration += 1; // 让长轮询循环自行退出
    _heartbeat?.cancel();
    _heartbeat = null;
    registration = null;
    pendingRequests = [];
    NativeWatchService.stop();
  }

  // MARK: - 投送

  Future<void> startPublishing(DeviceRegistration reg) async {
    if (publishing) return;
    registration = reg;

    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: true,
        dynacast: true,
        // 发布端编码上限：默认的 screenShareEncoding 是 1080p@15fps，
        // 不覆盖它，采集帧率再高也会被编码器钳到 15
        defaultVideoPublishOptions: VideoPublishOptions(
          screenShareEncoding: shareSettings.toEncoding(),
          // 单层发布：观看端拿到的就是完整画质，不会被自适应切到 1/4 码率的低清层
          simulcast: false,
          // 带宽吃紧时优先保帧率、降分辨率（投屏场景帧率比清晰度更影响体验）
          degradationPreference: DegradationPreference.maintainFramerate,
        ),
      ),
    );
    _publishRoom = room;

    try {
      await room.connect(reg.livekitUrl, reg.publishToken);
      // Publish both tracks returned by native display capture. Android requests
      // RECORD_AUDIO and MediaProjection permission for internal playback audio.
      await room.localParticipant!.setScreenShareEnabled(
        true,
        captureScreenAudio: true,
        screenShareCaptureOptions: shareSettings.toCaptureOptions(),
      );
    } catch (_) {
      _publishRoom = null;
      await room.disconnect();
      await room.dispose();
      notifyListeners();
      rethrow;
    }

    notifyListeners();
  }

  Future<void> stopPublishing() async {
    final room = _publishRoom;
    _publishRoom = null;
    await room?.disconnect();
    notifyListeners();
  }

  // MARK: - 观看会话

  /// 连接一台设备，返回会话对象。页面拿它渲染，断开与否由会话管理器决定。
  Future<ViewingSession> connectToDevice({
    required String deviceId,
    String? password,
  }) async {
    final session = await api.connect(deviceId: deviceId, password: password);
    return _attachSession(session);
  }

  /// 观看一台设备：
  ///   有连接密码 → 直接连（设备主人分享的凭据，不打扰对方）
  ///   没有密码   → 发起观看请求，等对方在自己设备上同意
  Future<ViewingSession> watchDevice({
    required String deviceId,
    String? password,
    void Function(String status)? onStatus,
    WatchRequestToken? token,
  }) async {
    if (password != null && password.isNotEmpty) {
      return connectToDevice(deviceId: deviceId, password: password);
    }

    final handle = await api.createConnectRequest(deviceId: deviceId);
    token?.requestId = handle.requestId;

    // 发起后立刻检查一次：用户可能在请求刚建好时就点了取消
    if (token?.cancelled ?? false) {
      await api.cancelConnectRequest(handle.requestId);
      throw ApiException('cancelled', '已取消等待');
    }

    onStatus?.call('已向「${handle.deviceName}」发送观看请求，等待对方同意…');

    final deadline = DateTime.now().add(Duration(seconds: handle.expiresInSec));
    while (DateTime.now().isBefore(deadline)) {
      if (token?.cancelled ?? false) {
        await api.cancelConnectRequest(handle.requestId);
        throw ApiException('cancelled', '已取消等待');
      }

      // 长轮询：服务端挂住最多 20 秒，对方一决策就立刻返回
      final granted = await api.pollConnectRequest(handle.requestId, waitSec: 20);
      if (granted != null) {
        onStatus?.call('对方已同意，正在连接…');
        return _attachSession(granted);
      }
    }
    throw ApiException('timeout', '等待对方同意超时，请重试');
  }

  Future<ViewingSession> _attachSession(ViewerSession session) async {
    // Android 默认走「通信模式」，远端音频路由到**听筒**——音量小到像没有声音。
    // 观看投屏必须走扬声器。
    try {
      await Hardware.instance.setSpeakerphoneOn(true);
      // setPreferSpeakerOutput 已废弃，新 API 走 AudioManager
      await AudioManager.instance.setSpeakerOutputPreferred(true);
    } catch (_) {
      // 路由设置失败不影响连接
    }

    final room = Room(roomOptions: const RoomOptions(adaptiveStream: true));
    await room.connect(session.livekitUrl, session.subscribeToken);

    final viewing = ViewingSession(
      id: 'view-${DateTime.now().millisecondsSinceEpoch}',
      deviceId: session.deviceId,
      deviceName: session.deviceName,
      room: room,
    );
    viewing.addListener(notifyListeners);
    _sessions[viewing.id] = viewing;

    // 立刻从房间里找远端轨道
    viewing.notifyListeners();
    notifyListeners();

    return viewing;
  }

  /// 手动断开某路会话。
  Future<void> disconnectSession(String id) async {
    final session = _sessions[id];
    if (session == null) return;
    await session.disconnect();
    notifyListeners();
  }

  /// 退出登录：断开全部会话与投送，清空心跳。
  Future<void> disconnectAll() async {
    for (final session in _sessions.values) {
      await session.disconnect();
    }
    _sessions.clear();
    await stopPublishing();
    stopHeartbeat();
    notifyListeners();
  }
}
