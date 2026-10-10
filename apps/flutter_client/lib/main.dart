import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'api.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'session_manager.dart';

/// 生产服务器地址。换成域名后这里要一并改，并同时改成 https。
const kServerUrl = 'http://121.43.102.154';

final ApiService api = ApiService(baseUrl: kServerUrl);

/// 应用级会话管理器：投送与观看连接都由它持有，与页面生命周期无关。
final SessionManager sessionManager = SessionManager(api: api);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 音频会话用「媒体播放」预设：观看投屏时音量键调节的是**媒体音量**（系统音量），
  // 而不是通话音量；播放也走媒体流。必须在 WebRTC 初始化前设置。
  try {
    await LiveKitClient.initialize(
      initialAudioSessionOptions: const AudioSessionOptions.mediaPlayback(),
    );
  } catch (_) {
    // 初始化失败不阻塞启动（回退到默认通信模式）
  }

  // 红屏（Flutter 默认的错误界面）在真机上既看不懂也帮不上忙，
  // 换成可读的错误卡片，并把完整堆栈打到 logcat（adb logcat -s flutter）。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('RemoteScreen 界面异常：${details.exceptionAsString()}');
  };
  ErrorWidget.builder = (details) => AppErrorCard(details);

  runApp(const RemoteScreenApp());
}

/// 界面异常时展示的卡片：给出人能看懂的信息与错误详情。
class AppErrorCard extends StatelessWidget {
  const AppErrorCard(this.details, {super.key});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final message = details.exceptionAsString();
    return Material(
      color: const Color(0xFF1B1F2A),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 20),
                  SizedBox(width: 8),
                  Text('界面出错了',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              const SizedBox(height: 10),
              const Text('已把详细堆栈写到日志。可以把下面的信息发给开发者。',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: SelectableText(
                  message.length > 600 ? '${message.substring(0, 600)}…' : message,
                  style: const TextStyle(
                      color: Color(0xFFFFB4A9),
                      fontSize: 11.5,
                      fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RemoteScreenApp extends StatelessWidget {
  const RemoteScreenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RemoteScreen',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4080FF),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
      ),
      home: const BootGate(),
    );
  }
}

/// 启动时先恢复本地保存的会话，有就进主页，没有就进登录页。
class BootGate extends StatefulWidget {
  const BootGate({super.key});

  @override
  State<BootGate> createState() => _BootGateState();
}

class _BootGateState extends State<BootGate> {
  Account? _account;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    try {
      _account = await api.me();
    } catch (_) {
      _account = null;
    }
    if (mounted) setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_account != null) {
      return HomeScreen(
        account: _account!,
        manager: sessionManager,
        onLogout: () => setState(() => _account = null),
      );
    }

    return LoginScreen(
      onLogin: (account) => setState(() => _account = account),
    );
  }
}
