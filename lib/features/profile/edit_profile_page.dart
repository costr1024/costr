/// Edit profile page — edit all NIP-01 kind-0 metadata fields, sign + publish.
/// Supports uploading + cropping avatar (square) and banner (3:1) via Blossom.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_cropper/image_cropper.dart';

import '../../app/providers.dart';
import '../../models/metadata.dart';
import '../../nostr/actions.dart';
import '../../services/blossom_upload.dart';

class EditProfilePage extends ConsumerStatefulWidget {
  const EditProfilePage({super.key});

  @override
  ConsumerState<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends ConsumerState<EditProfilePage> {
  final _controllers = <String, TextEditingController>{};
  bool _saving = false;
  bool _uploading = false;

  /// (key, label, helper hint) for each kind-0 metadata field.
  static const _fields = [
    ('name', '用户名', '别人 @ 你、列表里显示的名字'),
    ('display_name', '显示名', '个人主页顶部的大名，可以更长'),
    ('about', '个人简介', '一句话介绍你自己'),
    ('picture', '头像 URL', '点上方头像上传，自动填入；也可手填'),
    ('banner', '背景图 URL', '点最上方背景图上传，自动填入；也可手填'),
    ('website', '网站', '你的主页或项目链接'),
    ('nip05', 'NIP-05 验证', '如 you@domain.com，向中继证明这把钥匙归你'),
    ('lud16', '闪电网络地址', '如 you@wallethost.com，收打赏用'),
  ];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key, String? initial) {
    return _controllers.putIfAbsent(
      key,
      () => TextEditingController(text: initial ?? ''),
    );
  }

  /// Pick an image, crop it, upload to Blossom, and fill the URL into the
  /// given field. [ratioX]/[ratioY] set the crop aspect ratio.
  Future<void> _pickAndCropAndUpload(
    String fieldKey, {
    required double ratioX,
    required double ratioY,
  }) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.path == null) {
      _snack('无法获取文件路径（桌面端请直接粘贴 URL）');
      return;
    }
    setState(() => _uploading = true);
    try {
      // Crop.
      final cropped = await ImageCropper().cropImage(
        sourcePath: f.path!,
        aspectRatio: CropAspectRatio(ratioX: ratioX, ratioY: ratioY),
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: fieldKey == 'picture' ? '裁剪头像' : '裁剪背景图',
          ),
          IOSUiSettings(),
        ],
      );
      if (cropped == null) {
        if (mounted) setState(() => _uploading = false);
        return; // user cancelled
      }
      // Read cropped bytes.
      final bytes = await cropped.readAsBytes();
      final mime = mimeForExt(cropped.path.split('.').last);
      final res = await blossomUpload(
        identity,
        bytes,
        mimetype: mime,
        note: 'costr $fieldKey',
        servers: await currentBlossomServers(ref),
      );
      if (!mounted) return;
      if (res != null) {
        _controller(
          fieldKey,
          _getMeta(
            ref.read(metadataProvider(identity.pubkeyHex)).value,
            fieldKey,
          ),
        ).text = res.url;
        _snack('${fieldKey == 'picture' ? '头像' : '背景图'}上传成功');
      } else {
        _snack('上传失败');
      }
    } catch (e) {
      _snack('错误：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) {
      _snack('未登录');
      return;
    }
    setState(() => _saving = true);
    try {
      // Start from the EXISTING kind-0 content so Amethyst-specific fields
      // we don't have UI for (damus_donation_v2, legacy lud06, etc.) are
      // preserved on edit — rebuilding from only the 8 known fields would
      // drop them, a regression for Amethyst→Costr migration.
      final data = <String, dynamic>{};
      try {
        final cache = await ref.read(localCacheProvider.future);
        final existing = await cache.queryReplaceable(identity.pubkeyHex, 0);
        if (existing != null && existing.content.isNotEmpty) {
          final parsed = jsonDecode(existing.content);
          if (parsed is Map<String, dynamic>) data.addAll(parsed);
        }
      } catch (_) {
        // No existing profile yet (or undecodable) — start fresh.
      }
      // Overlay the editable fields: non-empty sets, empty clears.
      for (final (key, _, _) in _fields) {
        final v = _controllers[key]?.text.trim() ?? '';
        if (v.isNotEmpty) {
          data[key] = v;
        } else {
          data.remove(key);
        }
      }
      final contentJson = jsonEncode(data);
      final signed = NostrActions(identity).setMetadata(contentJson);
      // Optimistically update: push the kind-0 event to the EventStore so
      // the profile page reflects the change immediately (Amethyst pattern).
      ref.read(relayPoolProvider).publish(signed);
      ref.invalidate(metadataProvider(identity.pubkeyHex));
      if (mounted) context.pop();
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
              onPressed: (_saving || _uploading) ? null : _save,
              child: Text(_saving ? '保存中…' : '保存'),
            ),
          ),
        ],
      ),
      body: meta == null && identity != null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                SingleChildScrollView(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      // Banner preview at the very top — tappable to upload.
                      // Reads the live banner controller so it updates right
                      // after an upload (setState on _uploading rebuilds it).
                      GestureDetector(
                        onTap: _uploading
                            ? null
                            : () => _pickAndCropAndUpload(
                                'banner',
                                ratioX: 3,
                                ratioY: 1,
                              ),
                        child: SizedBox(
                          height: 120,
                          width: double.infinity,
                          child:
                              _controller(
                                'banner',
                                _getMeta(meta, 'banner'),
                              ).text.isNotEmpty
                              ? Image.network(
                                  _controller(
                                    'banner',
                                    _getMeta(meta, 'banner'),
                                  ).text,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    color: theme
                                        .colorScheme
                                        .surfaceContainerHighest,
                                    child: const Icon(
                                      Icons.broken_image,
                                      size: 32,
                                    ),
                                  ),
                                )
                              : Container(
                                  color:
                                      theme.colorScheme.surfaceContainerHighest,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: const [
                                        Icon(
                                          Icons.add_photo_alternate_outlined,
                                          size: 32,
                                        ),
                                        SizedBox(height: 4),
                                        Text('点此上传背景图'),
                                      ],
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            // Avatar upload + preview.
                            Row(
                              children: [
                                GestureDetector(
                                  onTap: _uploading
                                      ? null
                                      : () => _pickAndCropAndUpload(
                                          'picture',
                                          ratioX: 1,
                                          ratioY: 1,
                                        ),
                                  child:
                                      _controller(
                                        'picture',
                                        _getMeta(meta, 'picture'),
                                      ).text.isNotEmpty
                                      ? ClipOval(
                                          child: Image.network(
                                            _controller(
                                              'picture',
                                              _getMeta(meta, 'picture'),
                                            ).text,
                                            width: 64,
                                            height: 64,
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                Container(
                                                  width: 64,
                                                  height: 64,
                                                  color: theme
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                  child: const Icon(
                                                    Icons.broken_image,
                                                  ),
                                                ),
                                          ),
                                        )
                                      : Container(
                                          width: 64,
                                          height: 64,
                                          decoration: const BoxDecoration(
                                            shape: BoxShape.circle,
                                            gradient: LinearGradient(
                                              colors: [
                                                Color(0xFF6750A4),
                                                Color(0xFF9C27B0),
                                              ],
                                            ),
                                          ),
                                          child: const Center(
                                            child: Icon(
                                              Icons.person,
                                              color: Colors.white,
                                              size: 32,
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 12),
                                FilledButton.tonalIcon(
                                  icon: const Icon(Icons.upload, size: 18),
                                  label: const Text('上传头像'),
                                  onPressed: _uploading
                                      ? null
                                      : () => _pickAndCropAndUpload(
                                          'picture',
                                          ratioX: 1,
                                          ratioY: 1,
                                        ),
                                ),
                              ],
                            ),
                            // Picture URL field (auto-filled on upload; also editable).
                            for (final (key, label, hint) in _fields.where(
                              (f) => f.$1 == 'picture',
                            ))
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: 8,
                                  bottom: 16,
                                ),
                                child: TextField(
                                  controller: _controller(
                                    key,
                                    _getMeta(meta, key),
                                  ),
                                  decoration: InputDecoration(
                                    labelText: label,
                                    helperText: hint,
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            // Banner URL field.
                            for (final (key, label, hint) in _fields.where(
                              (f) => f.$1 == 'banner',
                            ))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: TextField(
                                  controller: _controller(
                                    key,
                                    _getMeta(meta, key),
                                  ),
                                  decoration: InputDecoration(
                                    labelText: label,
                                    helperText: hint,
                                    border: const OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                            // Other text fields.
                            for (final (key, label, hint) in _fields.where(
                              (f) => f.$1 != 'picture' && f.$1 != 'banner',
                            ))
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: TextField(
                                  controller: _controller(
                                    key,
                                    _getMeta(meta, key),
                                  ),
                                  decoration: InputDecoration(
                                    labelText: label,
                                    helperText: hint,
                                    border: const OutlineInputBorder(),
                                  ),
                                  maxLines: key == 'about' ? 4 : 1,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (_uploading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
    );
  }

  String? _getMeta(Metadata? meta, String key) {
    if (meta == null) return null;
    switch (key) {
      case 'name':
        return meta.name;
      case 'display_name':
        return meta.displayName;
      case 'about':
        return meta.about;
      case 'picture':
        return meta.picture;
      case 'banner':
        return meta.banner;
      case 'website':
        return meta.website;
      case 'nip05':
        return meta.nip05;
      case 'lud16':
        return meta.lud16;
      default:
        return null;
    }
  }
}
