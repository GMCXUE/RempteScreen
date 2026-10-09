import 'package:flutter/material.dart';
import 'api.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'session_manager.dart';

/// 生产服务器地址。换成域名后这里要一并改，并同时改成 https。
const kServerUrl = 'http://91.208.104.182';

final ApiService api = ApiService(baseUrl: kServerUrl);

/// 应用级会话管理器：投送与观看连接都由它持有，与页面生命周期无关。
final SessionManager sessionManager = SessionManager(api: api);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RemoteScreenApp());
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
