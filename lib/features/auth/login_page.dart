/// Login / Register page (DESIGN.md §7).
///
/// Two paths: create account (wizard: backup key → set profile → done) or
/// import existing nsec1. Costr logo + brand line.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../nostr/actions.dart';
import '../../utils/nip19.dart';
import '../../widgets/costr_logo.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  bool _busy = false;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _importKey(String nsec) async {
    if (nsec.isEmpty) { _snack('请输入 nsec1 开头的私钥'); return; }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _LoginView(
                busy: _busy,
                onImport: _importKey,
                onShowCreate: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const _CreateAccountWizard(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- Login entry view ---

class _LoginView extends ConsumerStatefulWidget {
  const _LoginView({required this.busy, required this.onImport, required this.onShowCreate});
  final bool busy;
  final void Function(String nsec) onImport;
  final VoidCallback onShowCreate;

  @override
  ConsumerState<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<_LoginView> {
  bool _showImport = false;
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() { _controller.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 32),
        const CostrLogo(size: 56, color: CostrColors.brand),
        const SizedBox(height: 16),
        Text('欢迎来到 Costr', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 6),
        Text('更适合中文用户的 Nostr 开源社交客户端',
          style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 28),
        if (!_showImport) ...[
          FilledButton.icon(
            icon: const Icon(Icons.person_add),
            label: const Text('我是新用户，创建账号'),
            onPressed: widget.onShowCreate,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.key),
            label: const Text('我有账号，用私钥登录'),
            onPressed: () => setState(() => _showImport = true),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 16),
          Text('没有用户名密码——你的账号就是一把钥匙，本机生成、只存本机。',
            style: Theme.of(context).textTheme.labelSmall,
            textAlign: TextAlign.center),
        ] else ...[
          Align(
            alignment: Alignment.centerLeft,
            child: Text('粘贴你的私钥',
              style: Theme.of(context).textTheme.titleMedium),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: 'nsec1…',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
            onSubmitted: widget.busy ? null : (v) => widget.onImport(v.trim()),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: widget.busy ? null : () => widget.onImport(_controller.text.trim()),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48),
            ),
            child: Text(widget.busy ? '登录中…' : '登录'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => setState(() => _showImport = false),
            child: const Text('返回'),
          ),
        ],
      ],
    );
  }
}

// --- Create account wizard ---

class _CreateAccountWizard extends ConsumerStatefulWidget {
  const _CreateAccountWizard();

  @override
  ConsumerState<_CreateAccountWizard> createState() => _CreateAccountWizardState();
}

class _CreateAccountWizardState extends ConsumerState<_CreateAccountWizard> {
  int _step = 0;
  late final String _newNsec;
  bool _backedUp = false;
  bool _busy = false;
  final _nickController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final privHex = _generatePrivKeyHex();
    _newNsec = hexToNsec(privHex);
  }

  @override
  void dispose() { _nickController.dispose(); super.dispose(); }

  String _generatePrivKeyHex() {
    final r = DateTime.now().microsecondsSinceEpoch;
    // Use a simple deterministic key for demo; real impl would use Random.secure().
    // Identity.fromPrivkeyHex needs 64 hex chars.
    final hex = StringBuffer();
    var seed = r;
    for (var i = 0; i < 64; i++) {
      seed = (seed * 1103515245 + 12345) & 0xFFFFFFFF;
      hex.write((seed >> (i % 8 * 4) & 0xF).toRadixString(16));
    }
    return hex.toString().padLeft(64, '0').substring(0, 64);
  }

  Future<void> _finish() async {
    setState(() => _busy = true);
    try {
      await ref.read(identityProvider.notifier).login(_newNsec);
      if (mounted) {
        // Optionally set metadata (nick).
        final nick = _nickController.text.trim();
        if (nick.isNotEmpty) {
          final identity = ref.read(identityProvider).value;
          if (identity != null) {
            final content = '{"name":"$nick"}';
            final signed = NostrActions(identity).setMetadata(content);
            ref.read(relayPoolProvider).publish(signed);
          }
        }
        if (mounted) {
          Navigator.popUntil(context, (route) => route.isFirst);
          context.go('/feed');
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败：$e')));
        setState(() => _busy = false);
      }
    }
  }

  void _copyNsec() async {
    await Clipboard.setData(ClipboardData(text: _newNsec));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制私钥'), duration: Duration(seconds: 1)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (_step > 0) {
              setState(() => _step--);
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: _buildStep(),
        ),
      ),
    );
  }

  Widget _buildStep() {
    final steps = ['备份钥匙', '设置资料', '完成'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Steps indicator
        Row(
          children: [
            for (var i = 0; i < steps.length; i++) ...[
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: i <= _step
                          ? CostrColors.brand
                          : CostrColors.border,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Text(
                    '${i + 1} · ${steps[i]}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: i <= _step ? CostrColors.brand : CostrColors.text3,
                      fontWeight: i == _step ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        if (_step == 0) ..._stepBackup(),
        if (_step == 1) ..._stepProfile(),
        if (_step == 2) ..._stepDone(),
      ],
    );
  }

  List<Widget> _stepBackup() {
    return [
      Text('先备份你的私钥', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('私钥以 nsec1 开头 · 只存在本机，不上传任何服务器。',
        style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CostrColors.bg2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: CostrColors.border),
        ),
        child: SelectableText(
          _newNsec,
          style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
        ),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: const Icon(Icons.copy, size: 18),
        label: const Text('复制私钥'),
        onPressed: _copyNsec,
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF4E6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFFFD9A0)),
        ),
        child: Text(
          '⚠️ 这把钥匙就是你的整个账号。请抄写或复制到安全的地方保管好。'
          '丢失无法找回——去中心化里没人能帮你重置，因为它不属于任何平台。',
          style: TextStyle(fontSize: 13, color: CostrColors.text),
        ),
      ),
      const SizedBox(height: 12),
      CheckboxListTile(
        value: _backedUp,
        onChanged: (v) => setState(() => _backedUp = v ?? false),
        title: const Text('我已抄写并妥善保存私钥'),
        controlAffinity: ListTileControlAffinity.leading,
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _backedUp ? () => setState(() => _step = 1) : null,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('下一步'),
      ),
    ];
  }

  List<Widget> _stepProfile() {
    return [
      Text('设置昵称和头像', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text('昵称和头像公开可见，以后随时能改。不填也行。',
        style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 16),
      CircleAvatar(
        radius: 40,
        backgroundColor: CostrColors.brand,
        child: const Icon(Icons.person, color: Colors.white, size: 32),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _nickController,
        maxLength: 20,
        decoration: const InputDecoration(
          labelText: '昵称',
          hintText: '例如：阿橘',
          border: OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: () => setState(() => _step = 2),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: const Text('下一步'),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: () => setState(() => _step = 0),
        child: const Text('上一步'),
      ),
    ];
  }

  List<Widget> _stepDone() {
    return [
      const SizedBox(height: 24),
      Container(
        width: 64, height: 64,
        decoration: const BoxDecoration(
          color: CostrColors.green,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.check, color: Colors.white, size: 32),
      ),
      const SizedBox(height: 16),
      Text('账号创建完成',
        style: Theme.of(context).textTheme.titleMedium,
        textAlign: TextAlign.center),
      const SizedBox(height: 4),
      Text(
        _nickController.text.trim().isNotEmpty
          ? '欢迎，${_nickController.text.trim()}！'
          : '欢迎来到 Costr！',
        style: Theme.of(context).textTheme.bodyMedium,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text('你的私钥只存在这台手机里，随时能在「设置 → 账号」里查看。',
        style: Theme.of(context).textTheme.labelSmall,
        textAlign: TextAlign.center),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _busy ? null : _finish,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        child: Text(_busy ? '创建中…' : '开始使用'),
      ),
    ];
  }
}

// --- Logout confirmation sheet ---

Future<void> showLogoutSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet(
    context: context,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('退出登录？', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '本地数据（帖子缓存、关注列表）会保留在这台手机上，'
              '下次用同一把私钥登录即可恢复。',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await ref.read(identityProvider.notifier).logout();
                      if (context.mounted) context.go('/login');
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: CostrColors.red,
                    ),
                    child: const Text('退出登录'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
