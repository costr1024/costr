/// Edit profile page — edit all NIP-01 kind-0 metadata fields, sign + publish.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/metadata.dart';
import '../../nostr/actions.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _controllers = <String, TextEditingController>{};
  bool _saving = false;

  static const _fields = [
    ('name', '用户名'),
    ('display_name', '显示名'),
    ('about', '个人简介'),
    ('picture', '头像 URL'),
    ('banner', '背景图 URL'),
    ('website', '网站'),
    ('nip05', 'NIP-05 验证'),
    ('lud16', '闪电网络地址'),
  ];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key, String? initial) {
    return _controllers.putIfAbsent(key, () => TextEditingController(text: initial ?? ''));
  }

  Future<void> _save() async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) { _snack('未登录'); return; }
    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{};
      for (final (key, _) in _fields) {
        final v = _controllers[key]?.text.trim() ?? '';
        if (v.isNotEmpty) data[key] = v;
      }
      final contentJson = jsonEncode(data);
      final signed = NostrActions(identity).setMetadata(contentJson);
      final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
      if (!mounted) return;
      _snack(ok.ok ? '资料已更新' : '更新失败：${ok.reason}');
      if (ok.ok) {
        ref.invalidate(metadataProvider(identity.pubkeyHex));
        if (context.mounted) context.pop();
      }
    } catch (e) {
      _snack('错误：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final identity = ref.watch(identityProvider).value;
    final meta = identity != null
        ? ref.watch(metadataProvider(identity.pubkeyHex)).value
        : null;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('编辑资料'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
      body: meta == null && identity != null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  for (final (key, label) in _fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: TextField(
                        controller: _controller(key, _getMeta(meta, key)),
                        decoration: InputDecoration(
                          labelText: label,
                          border: const OutlineInputBorder(),
                        ),
                        maxLines: key == 'about' ? 4 : 1,
                      ),
                    ),
                  Text(
                    '头像和背景图支持直接粘贴 Blossom/图床 URL。'
                    '图片裁剪上传功能将在后续版本支持。',
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
    );
  }

  String? _getMeta(Metadata? meta, String key) {
    if (meta == null) return null;
    switch (key) {
      case 'name': return meta.name;
      case 'display_name': return meta.displayName;
      case 'about': return meta.about;
      case 'picture': return meta.picture;
      case 'banner': return meta.banner;
      case 'website': return meta.website;
      case 'nip05': return meta.nip05;
      case 'lud16': return meta.lud16;
      default: return null;
    }
  }
}
