/// Compose page — write a kind-1 note, sign it, publish. Supports reply
/// (replyTo), quote (quoteOf), and media/file attachments via Blossom.
///
/// Attachments: up to 9 images OR 1 video (not mixed), plus optional files
/// (pdf/zip/etc per Blossom server's supported types). Limits: image 10MB,
/// video 100MB, file 100MB. Uploaded to Blossom servers with fallback retry;
/// each becomes a NIP-92 imeta tag in the signed event.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../nostr/actions.dart';
import '../../services/blossom_upload.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';

class ComposePage extends ConsumerStatefulWidget {
  const ComposePage({super.key, this.replyTo, this.quoteOf});

  final Event? replyTo;
  final Event? quoteOf;

  @override
  ConsumerState<ComposePage> createState() => _ComposePageState();
}

class _Attachment {
  _Attachment({
    required this.url,
    required this.sha256,
    required this.mime,
    required this.name,
    required this.kind,
  });
  final String url;
  final String sha256;
  final String mime;
  final String name;
  final String kind; // 'image' | 'video' | 'file'
}

class _ComposePageState extends ConsumerState<ComposePage> {
  final TextEditingController _controller = TextEditingController();
  final List<_Attachment> _attachments = [];

  /// Pubkeys explicitly @-mentioned via autocomplete → emitted as NIP-27 `p`
  /// tags on send (alongside the `nostr:npub1…` text reference in content).
  final Set<String> _mentions = {};
  bool _uploading = false;
  bool _sending = false;
  bool _nsfw = false;

  static const int _softLimit = 280;
  static const int _maxImages = 9;
  static const int _maxFiles = 4;
  static const int _maxImageBytes = 10 * 1024 * 1024;
  static const int _maxVideoBytes = 100 * 1024 * 1024;
  static const int _maxFileBytes = 100 * 1024 * 1024;

  bool get _hasImages => _attachments.any((a) => a.kind == 'image');
  bool get _hasVideo => _attachments.any((a) => a.kind == 'video');

  @override
  void initState() {
    super.initState();
    _nsfw = ref.read(nsfwSettingsProvider).defaultComposeNsfw;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _hint {
    if (widget.replyTo != null) return '回复…';
    if (widget.quoteOf != null) return '引用评论…';
    return '有什么新鲜事？';
  }

  /// Append a URL to the editor text as a bare URL (one per line, maximum
  /// cross-client compat). Called as each upload completes.
  void _appendToEditor(_Attachment a) {
    final url = a.url;
    final cur = _controller.text;
    _controller.text = cur.isEmpty ? url : '$cur\n$url';
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
  }

  Future<void> _pickImages() async {
    if (_hasVideo) {
      _snack('已添加视频，不能与图片混合');
      return;
    }
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final current = _attachments.where((a) => a.kind == 'image').length;
    if (current >= _maxImages) {
      _snack('最多 $_maxImages 张图片');
      return;
    }
    final remaining = _maxImages - current;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    // The native picker can't hard-cap the selection count, so cap here and
    // warn loudly (don't silently drop the extras).
    if (result.files.length > remaining) {
      _snack('最多 $_maxImages 张图片，已只添加前 $remaining 张');
    }
    final files = result.files.take(remaining).where((f) {
      if (f.size > _maxImageBytes) {
        _snack('图片超过 10MB: ${f.name}');
        return false;
      }
      return true;
    }).toList();
    if (files.isEmpty) return;
    setState(() => _uploading = true);
    // Concurrent upload.
    final results = await Future.wait(
      files.map((f) async {
        final bytes = _bytesOf(f);
        if (bytes == null) return null;
        final mime = mimeForExt(f.extension ?? f.name);
        final res = await blossomUpload(
          identity,
          bytes,
          mimetype: mime,
          note: 'costr image',
        );
        return res == null ? null : (f, mime, res);
      }),
    );
    if (!mounted) return;
    for (final r in results) {
      if (r == null) continue;
      final att = _Attachment(
        url: r.$3.url,
        sha256: r.$3.sha256,
        mime: r.$2,
        name: r.$1.name,
        kind: 'image',
      );
      setState(() {
        _attachments.add(att);
        _appendToEditor(att);
      });
    }
    if (mounted) setState(() => _uploading = false);
  }

  Future<void> _pickVideo() async {
    if (_hasImages) {
      _snack('已添加图片，不能与视频混合');
      return;
    }
    if (_hasVideo) return;
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.size > _maxVideoBytes) {
      _snack('视频超过 100MB');
      return;
    }
    final bytes = _bytesOf(f);
    if (bytes == null) return;
    final mime = mimeForExt(f.extension ?? f.name);
    setState(() => _uploading = true);
    final res = await blossomUpload(
      identity,
      bytes,
      mimetype: mime,
      note: 'costr video',
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (res != null) {
      final att = _Attachment(
        url: res.url,
        sha256: res.sha256,
        mime: mime,
        name: f.name,
        kind: 'video',
      );
      setState(() {
        _attachments.add(att);
        _appendToEditor(att);
      });
    } else {
      _snack('视频上传失败');
    }
  }

  Future<void> _pickFile() async {
    if (_attachments.where((a) => a.kind == 'file').length >= _maxFiles) {
      _snack('最多 $_maxFiles 个附件');
      return;
    }
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    if (f.size > _maxFileBytes) {
      _snack('附件超过 100MB');
      return;
    }
    final bytes = _bytesOf(f);
    if (bytes == null) return;
    final mime = mimeForExt(f.extension ?? f.name);
    setState(() => _uploading = true);
    final res = await blossomUpload(
      identity,
      bytes,
      mimetype: mime,
      note: 'costr file ${f.name}',
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    if (res != null) {
      final att = _Attachment(
        url: res.url,
        sha256: res.sha256,
        mime: mime,
        name: f.name,
        kind: 'file',
      );
      setState(() {
        _attachments.add(att);
        _appendToEditor(att);
      });
    } else {
      _snack('附件上传失败: ${f.name}');
    }
  }

  List<int>? _bytesOf(PlatformFile f) {
    if (f.bytes != null) return f.bytes;
    if (f.path != null) return File(f.path!).readAsBytesSync();
    return null;
  }

  List<List<String>> _imetaTags() => [
    for (final a in _attachments)
      ['imeta', 'url ${a.url}', 'm ${a.mime}', 'x ${a.sha256}'],
  ];

  /// NIP-27 event references pasted into the content as `nostr:nevent1…` /
  /// `nostr:note1…`. Emits `e` mention tags (+ `p` author tags for nevent with
  /// an author hint) so other clients can fetch + render the referenced post.
  /// The `nostr:…` text stays in the content (rendered as an embed by
  /// MarkdownContent). Mirrors the @-mention path for npub.
  List<List<String>> _neventMentionTags() {
    final text = _controller.text;
    final regex = RegExp(
      r'(?:nostr:)?((?:nevent1|note1)[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{6,})',
    );
    final tags = <List<String>>[];
    final seenIds = <String>{};
    for (final m in regex.allMatches(text)) {
      final entity = m.group(1)!;
      final ev = neventDecode(entity); // null for note1
      final id = ev?.id ?? entityToEventIdHex(entity);
      if (id == null || !seenIds.add(id)) continue;
      final relay = (ev?.relays.isNotEmpty ?? false) ? ev!.relays.first : '';
      tags.add(['e', id, relay, 'mention']);
      final author = ev?.author;
      if (author != null && author.isNotEmpty) tags.add(['p', author]);
    }
    return tags;
  }

  /// If the caret is right after an `@<query>` token that starts on a word
  /// boundary, returns `(query, startOfAt)`. Used to drive @-mention
  /// autocomplete. `@` must be preceded by whitespace / start / punctuation
  /// so emails and `nostr:npub1…` don't trigger it.
  (String, int)? _mentionQuery() {
    final text = _controller.text;
    final sel = _controller.selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final caret = sel.baseOffset;
    if (caret <= 0 || caret > text.length) return null;
    const word = r'[\p{L}\p{N}_.]';
    final wordRe = RegExp(word, unicode: true);
    var i = caret;
    while (i > 0 && wordRe.hasMatch(text[i - 1])) {
      i--;
    }
    if (i == 0 || text[i - 1] != '@') return null;
    final before = i >= 2 ? text[i - 2] : ' ';
    if (i > 1 && !RegExp(r'[\s@#\(\[\{<>\.,;:!?]').hasMatch(before)) {
      return null;
    }
    final q = text.substring(i, caret);
    if (q.length > 30) return null;
    return (q, i - 1);
  }

  List<KnownUser> _filteredCandidates(String query) {
    final all = ref.read(knownUsersProvider);
    final q = query.toLowerCase();
    if (q.isEmpty) return all.take(8).toList();
    final out = <KnownUser>[];
    for (final u in all) {
      if (out.length >= 8) break;
      final label = u.label.toLowerCase();
      final npub = hexToNpub(u.pubkey).toLowerCase();
      if (label.contains(q) || npub.contains(q)) out.add(u);
    }
    return out;
  }

  void _insertMention(KnownUser user, int atStart) {
    final npub = hexToNpub(user.pubkey);
    final insert = 'nostr:$npub ';
    final text = _controller.text;
    final caret = _controller.selection.baseOffset;
    final end = caret.clamp(0, text.length);
    final newText = text.replaceRange(atStart, end, insert);
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: atStart + insert.length),
    );
    _mentions.add(user.pubkey);
    setState(() {});
  }

  /// Candidates to show right now, or null to hide the panel.
  List<KnownUser>? get _mentionPanel {
    final mq = _mentionQuery();
    if (mq == null) return null;
    final cands = _filteredCandidates(mq.$1);
    return cands.isEmpty ? null : cands;
  }

  void _onMentionSelected(KnownUser user) {
    final mq = _mentionQuery();
    if (mq == null) return;
    _insertMention(user, mq.$2);
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final identity = ref.read(identityProvider).value;
    if (identity == null) {
      _snack('未登录');
      return;
    }
    if (text.isEmpty && widget.quoteOf == null) {
      _snack('内容不能为空');
      return;
    }
    setState(() => _sending = true);
    try {
      final actions = NostrActions(identity);
      final imeta = _imetaTags();
      final extraTags = <List<String>>[
        ...imeta,
        if (_nsfw) ['t', 'nsfw'],
        // NIP-27: each @-mentioned pubkey gets a `p` tag (the content already
        // carries the `nostr:npub1…` text reference, rendered as a tappable
        // @name mention by MarkdownContent).
        for (final pk in _mentions) ['p', pk],
        // NIP-27 event references pasted as `nostr:nevent1…` / `nostr:note1…`:
        // emit `e` mention tags (+ `p` author for nevent) so other clients can
        // fetch + render the referenced post (Amethyst-compatible).
        ..._neventMentionTags(),
      ];
      // Content already has attachment URLs (appended by _appendToEditor on
      // upload completion) — don't append again.
      final signed = widget.replyTo != null
          ? actions.reply(widget.replyTo!, text, extraTags: extraTags)
          : widget.quoteOf != null
          ? actions.quote(widget.quoteOf!, text, extraTags: extraTags)
          : identity.signEvent(kind: 1, content: text, tags: extraTags);
      final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
      if (!mounted) return;
      _snack(ok.ok ? '已发布' : '发布失败：${ok.reason}');
      // Refresh the profile Posts/Replies tabs so the just-published note
      // (already cached to SQLite by EventStoreNotifier) shows immediately —
      // userPostsProvider is non-autoDispose so it wouldn't re-run on its own.
      if (ok.ok) {
        ref.invalidate(userPostsProvider(identity.pubkeyHex));
      }
      if (ok.ok && context.mounted) context.pop();
    } catch (e) {
      _snack('发送失败：$e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final count = _controller.text.length;
    final over = count > _softLimit;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.replyTo != null
              ? '回复'
              : widget.quoteOf != null
              ? '引用'
              : '发帖',
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: TextButton(
              onPressed: (_sending || _uploading) ? null : _send,
              child: Text(_sending ? '发送中…' : '发送'),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (widget.replyTo != null)
              _ContextCard(event: widget.replyTo!, label: '回复'),
            if (widget.quoteOf != null)
              _ContextCard(event: widget.quoteOf!, label: '引用'),
            // @-mention autocomplete panel — shown when the caret is after an
            // active `@query` (NIP-27 mentions, Amethyst/Jumble pattern).
            if (_mentionPanel != null)
              _MentionPanel(
                candidates: _mentionPanel!,
                onSelect: _onMentionSelected,
              ),
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                decoration: InputDecoration(
                  hintText: _hint,
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            if (_attachments.isNotEmpty)
              _AttachmentGrid(
                attachments: _attachments,
                onRemove: (a) => setState(() => _attachments.remove(a)),
              ),
            if (_uploading) const LinearProgressIndicator(),
            const SizedBox(height: 8),
            Row(
              children: [
                _AttachBtn(
                  icon: Icons.image_outlined,
                  label: '图片',
                  onPressed: _hasVideo ? null : _pickImages,
                ),
                _AttachBtn(
                  icon: Icons.movie_outlined,
                  label: '视频',
                  onPressed: _hasImages ? null : _pickVideo,
                ),
                _AttachBtn(
                  icon: Icons.attach_file,
                  label: '文件',
                  onPressed: _pickFile,
                ),
                const Spacer(),
                FilterChip(
                  label: const Text('NSFW'),
                  selected: _nsfw,
                  onSelected: (v) => setState(() => _nsfw = v),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Text(
                  '$count',
                  style: TextStyle(
                    color: over
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachBtn extends StatelessWidget {
  const _AttachBtn({
    required this.icon,
    required this.label,
    required this.onPressed,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: Icon(icon, size: 20),
    label: Text(label, style: const TextStyle(fontSize: 13)),
    onPressed: onPressed,
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
  );
}

class _AttachmentGrid extends StatelessWidget {
  const _AttachmentGrid({required this.attachments, required this.onRemove});
  final List<_Attachment> attachments;
  final void Function(_Attachment) onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final a in attachments)
            Stack(
              children: [
                _attachThumb(context, a),
                Positioned(
                  right: -4,
                  top: -4,
                  child: IconButton(
                    icon: const Icon(Icons.cancel, size: 20),
                    onPressed: () => onRemove(a),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _attachThumb(BuildContext context, _Attachment a) {
    if (a.kind == 'image') {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          a.url,
          width: 80,
          height: 80,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) =>
              Container(width: 80, height: 80, color: Colors.grey),
        ),
      );
    }
    return Container(
      width: 120,
      height: 56,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            a.kind == 'video' ? Icons.movie : Icons.insert_drive_file_outlined,
            size: 20,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              a.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact quoted context (the post being replied to / quoted).
class _ContextCard extends StatelessWidget {
  const _ContextCard({required this.event, required this.label});
  final Event event;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.labelSmall),
          const SizedBox(height: 4),
          Text(
            event.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// @-mention autocomplete panel (NIP-27 mentions, Amethyst/Jumble pattern).
/// Shown above the composer when the caret is after an `@<query>` token.
class _MentionPanel extends StatelessWidget {
  const _MentionPanel({required this.candidates, required this.onSelect});
  final List<KnownUser> candidates;
  final ValueChanged<KnownUser> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: candidates.length,
        itemBuilder: (BuildContext _, int i) {
          final u = candidates[i];
          return ListTile(
            dense: true,
            leading: Avatar(pubkey: u.pubkey, radius: 14),
            title: Text(u.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () => onSelect(u),
          );
        },
      ),
    );
  }
}
