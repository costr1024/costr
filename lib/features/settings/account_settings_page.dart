/// Account settings page: account-level NSFW settings (local, not synced to
/// relays) + private-key backup (copy nsec, gated behind biometric / device
/// lock auth via local_auth). DESIGN §7.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';

class AccountSettingsPage extends ConsumerWidget {
  const AccountSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nsfw = ref.watch(nsfwSettingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('账号备份')),
      body: ListView(
        children: [
          const _SectionHeader('账号级 NSFW 设置'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '只保存在本机，不上传中继。',
              style: TextStyle(
                fontSize: 12,
                color: CostrColors.of(context).text2,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('自动显示敏感内容'),
            subtitle: const Text('不再用模糊遮罩盖住 NSFW 帖子，直接显示'),
            value: nsfw.autoReveal,
            onChanged: (v) =>
                ref.read(nsfwSettingsProvider.notifier).setAutoReveal(v),
          ),
          SwitchListTile(
            title: const Text('发帖默认标记为敏感'),
            subtitle: const Text('写新帖子时默认勾选 NSFW 标签'),
            value: nsfw.defaultComposeNsfw,
            onChanged: (v) => ref
                .read(nsfwSettingsProvider.notifier)
                .setDefaultComposeNsfw(v),
          ),
          const SizedBox(height: 16),
          const _SectionHeader('备份私钥'),
          const _DangerWarning(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: CostrColors.of(context).red,
              ),
              icon: const Icon(Icons.key, size: 18),
              label: const Text('验证身份并复制私钥'),
              onPressed: () => _copyKey(context, ref),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<void> _copyKey(BuildContext context, WidgetRef ref) async {
    final auth = LocalAuthentication();
    bool canAuth = false;
    try {
      canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
    } catch (_) {
      canAuth = false;
    }
    if (!canAuth) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('此设备不支持生物识别/锁屏验证，无法复制私钥')));
      return;
    }
    bool ok = false;
    try {
      ok = await auth.authenticate(
        localizedReason: '验证你的身份，以复制账号私钥',
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      ok = false;
    }
    if (!ok) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('身份验证未通过，私钥未复制')));
      return;
    }
    // The ACTIVE account's nsec — with multi-account, each stored account
    // keeps its own key in the registry; backup always targets the current one.
    final nsec = ref.read(identityProvider).value?.nsec;
    if (nsec == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未读取到本地私钥')));
      return;
    }
    await Clipboard.setData(ClipboardData(text: nsec));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('私钥已复制到剪贴板，请尽快转移到安全的地方')));
  }
}

class _DangerWarning extends StatelessWidget {
  const _DangerWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CostrColors.of(context).red.withValues(alpha: 0.08),
        border: Border.all(
          color: CostrColors.of(context).red.withValues(alpha: 0.4),
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_rounded,
            size: 20,
            color: CostrColors.of(context).red,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '危险操作：复制私钥可能导致私钥泄漏。'
              'Nostr 账号无法销毁——一旦私钥泄漏，会被他人盗用，'
              '你永远无法再拿回账号控制权。仅在确需迁移账号时使用，'
              '复制后尽快粘贴到离线、可信的地方，不要留在剪贴板里。',
              style: TextStyle(
                fontSize: 13,
                color: CostrColors.of(context).red,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: CostrColors.of(context).text3,
      ),
    ),
  );
}
