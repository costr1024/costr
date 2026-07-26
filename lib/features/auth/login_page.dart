/// Login page — paste an `nsec1...` private key (NIP-19) to log in.
///
/// On success the key is persisted in OS secure storage and the router
/// redirects to the feed. Invalid input is rejected with an inline error.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final TextEditingController _controller = TextEditingController();
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final nsec = _controller.text.trim();
    if (nsec.isEmpty) {
      _snack('请输入 nsec1 开头的私钥');
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(identityProvider.notifier).login(nsec);
      if (mounted) context.go('/feed');
    } on FormatException catch (e) {
      _snack('私钥格式无效：${e.message}');
    } catch (e) {
      _snack('登录失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('登录 costr')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '用私钥登录',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                const Text(
                  '粘贴你的 nsec1 私钥。私钥仅在本机安全存储，不会发送到任何服务器。',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _controller,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'nsec1 私钥',
                    hintText: 'nsec1...',
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(_busy ? '登录中…' : '登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
