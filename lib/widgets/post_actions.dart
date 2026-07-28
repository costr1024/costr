/// X-style action row: 回复 / 转发 / reaction / 引用 / 分享.
///
/// - 回复 / 引用 → push Compose with a replyTo / quoteOf context.
/// - 转发 → sign NIP-18 kind-6 + publish (with confirm).
/// - reaction → bottom-sheet emoji picker (NIP-25 kind-7, supports NIP-30
///   custom-emoji via NostrActions.reaction(customShortcode/customUrl)).
/// - 分享 → copy `https://njump.me/<note1>` (Amethyst-style).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../nostr/actions.dart';
import '../../utils/nip19.dart';

class PostActions extends ConsumerWidget {
  const PostActions({super.key, required this.event});
  final Event event;

  static const List<String> _emoji = [
    '❤️', '🔥', '👍', '👎', '😮', '😂', '🎉', '🤔', '👏', '🙏',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _Action(
          icon: Icons.chat_bubble_outline,
          color: fg,
          onTap: () => context.push('/compose', extra: {'replyTo': event}),
        ),
        _Action(
          icon: Icons.repeat_rounded,
          color: fg,
          onTap: () => _repost(context, ref),
        ),
        _Action(
          icon: Icons.favorite_border,
          color: fg,
          onTap: () => _pickReaction(context, ref),
        ),
        _Action(
          icon: Icons.format_quote_rounded,
          color: fg,
          onTap: () => context.push('/compose', extra: {'quoteOf': event}),
        ),
        _Action(
          icon: Icons.bookmark_border,
          color: fg,
          onTap: () => _bookmark(context, ref),
        ),
        _Action(
          icon: Icons.ios_share,
          color: fg,
          onTap: () => _share(context),
        ),
      ],
    );
  }

  Future<void> _repost(BuildContext context, WidgetRef ref) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final confirmed = await _confirm(context, '转发这条帖子？');
    if (confirmed != true) return;
    final signed = NostrActions(identity).repost(event);
    final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
    if (context.mounted) {
      _snack(context, ok.ok ? '已转发' : '转发失败：${ok.reason}');
    }
  }

  Future<void> _pickReaction(BuildContext context, WidgetRef ref) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final emoji = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('选择表情',
                  style: Theme.of(ctx).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final e in _emoji)
                    ActionChip(
                      label: Text(e, style: const TextStyle(fontSize: 22)),
                      onPressed: () => Navigator.pop(ctx, e),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (emoji == null) return;
    final signed = NostrActions(identity).reaction(event, emoji);
    final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
    if (context.mounted) {
      _snack(context, ok.ok ? '已发送 $emoji' : '反应失败：${ok.reason}');
    }
  }

  Future<void> _share(BuildContext context) async {
    try {
      final url = 'https://njump.me/${hexToNote(event.id)}';
      await Clipboard.setData(ClipboardData(text: url));
      if (context.mounted) _snack(context, '已复制分享链接');
    } catch (_) {
      if (context.mounted) _snack(context, '复制失败');
    }
  }

  Future<void> _bookmark(BuildContext context, WidgetRef ref) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.public_outlined),
              title: const Text('收藏到公开书签'),
              subtitle: const Text('他人可见（NIP-51 kind 10003 公开 tag）'),
              onTap: () => Navigator.pop(ctx, 'public'),
            ),
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: const Text('收藏到私人书签'),
              subtitle: const Text('仅自己可见（NIP-44 加密）'),
              onTap: () => Navigator.pop(ctx, 'private'),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    final ok = await bookmarkEvent(ref, event.id, publicList: choice == 'public');
    if (context.mounted) {
      _snack(context, ok.ok
          ? '已收藏到${choice == 'public' ? '公开' : '私人'}书签'
          : '收藏失败：${ok.reason}');
    }
  }

  Future<bool?> _confirm(BuildContext context, String message) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认')),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.color, required this.onTap});
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 24,
        height: 32,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
