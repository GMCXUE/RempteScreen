import 'package:flutter/material.dart';
import 'api.dart';

/// 登录与注册共用一屏，用分段控件切换。
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin});

  /// 登录成功后回调，由外层决定接下来去哪。
  final ValueChanged<Account> onLogin;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _register = false;
  bool _busy = false;
  String? _error;

  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = '请把邮箱和密码都填上');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final account = _register
          ? await api.register(email: email, password: password, name: _name.text)
          : await api.login(email: email, password: password);

      if (!mounted) return;
      widget.onLogin(account);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 20),
                Icon(Icons.cast, size: 44, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 14),
                Text(
                  _register ? '注册账号' : '登录',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                ),
                Text(
                  '设备会绑定到你的账号下',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 26),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('登录')),
                    ButtonSegment(value: true, label: Text('注册')),
                  ],
                  selected: {_register},
                  onSelectionChanged: (selection) =>
                      setState(() => _register = selection.first),
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: Icon(Icons.alternate_email),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                if (_register) ...[
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: '昵称',
                      prefixIcon: Icon(Icons.badge_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: _register
                      ? const [AutofillHints.newPassword]
                      : const [AutofillHints.password],
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.lock_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(_busy
                      ? '请稍候…'
                      : (_register ? '注册' : '登录')),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
