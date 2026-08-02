/// X-style action row: 回复 / 转发 / reaction / 收藏 / 分享.
///
/// - 回复 → push Compose with a replyTo context.
/// - 转发 → pop a 二选一 menu (DESIGN §3.5): 转发 (NIP-18 kind-6, direct,
///   no comment) or 引用 (kind-1 with a `nostr:note1` quote → push Compose
///   with a quoteOf context). No hidden one-tap repost — the menu makes the
///   choice explicit to avoid misclicks.
/// - reaction → bottom-sheet emoji picker (NIP-25 kind-7, supports NIP-30
///   custom-emoji via NostrActions.reaction(customShortcode/customUrl)).
/// - 分享 → system share sheet with `https://njump.me/<note1>` (Amethyst-style).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../nostr/actions.dart';
import '../../utils/nip19.dart';

class PostActions extends ConsumerWidget {
  const PostActions({super.key, required this.event});
  final Event event;

  static const List<String> _emoji = [
    '❤️',
    '🔥',
    '👍',
    '👎',
    '😮',
    '😂',
    '🎉',
    '🤔',
    '👏',
    '🙏',
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurfaceVariant;
    final myReaction = ref.watch(myReactionProvider(event.id));
    final counts = ref.watch(postCountsProvider(event.id));
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _Action(
          icon: Icons.chat_bubble_outline,
          color: fg,
          count: counts.replies,
          onTap: () => context.push('/compose', extra: {'replyTo': event}),
        ),
        _Action(
          icon: Icons.repeat_rounded,
          color: fg,
          count: counts.reposts,
          onTap: () => _showRepostMenu(context, ref),
        ),
        _Action(
          icon: myReaction == null ? Icons.favorite_border : Icons.favorite,
          color: myReaction == null ? fg : Colors.red,
          onTap: () {
            if (myReaction == null) {
              _pickReaction(context, ref);
            } else {
              _cancelReaction(context, ref, myReaction);
            }
          },
        ),
        _Action(
          icon: Icons.bookmark_border,
          color: fg,
          onTap: () => _bookmark(context, ref),
        ),
        _Action(icon: Icons.ios_share, color: fg, onTap: () => _share(context)),
      ],
    );
  }

  /// 二选一 menu (DESIGN §3.5 / ui_demo.html `openRepostMenu`): 转发 (direct
  /// NIP-18 kind-6) or 引用 (kind-1 quoting this note → Compose).
  Future<void> _showRepostMenu(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.repeat_rounded),
              title: const Text('转发'),
              subtitle: const Text('直接转发到你的主页，不带评论'),
              onTap: () => Navigator.pop(ctx, 'repost'),
            ),
            ListTile(
              leading: const Icon(Icons.format_quote_rounded),
              title: const Text('引用'),
              subtitle: const Text('带你的评论引用这条帖子'),
              onTap: () => Navigator.pop(ctx, 'quote'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'repost') {
      if (context.mounted) await _repost(context, ref);
    } else if (choice == 'quote') {
      if (context.mounted) {
        context.push('/compose', extra: {'quoteOf': event});
      }
    }
  }

  Future<void> _repost(BuildContext context, WidgetRef ref) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final confirmed = await _confirm(context, '转发这条帖子？');
    if (confirmed != true) return;
    final signed = NostrActions(
      identity,
    ).repost(event, relay: relayHintFor(ref, event.pubkey) ?? '');
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
              Text('选择表情', style: Theme.of(ctx).textTheme.titleSmall),
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
    final signed = NostrActions(
      identity,
    ).reaction(event, emoji, relay: relayHintFor(ref, event.pubkey) ?? '');
    final ok = await ref.read(relayPoolProvider).publishAndWait(signed);
    if (context.mounted) {
      _snack(context, ok.ok ? '已发送 $emoji' : '反应失败：${ok.reason}');
    }
  }

  /// Cancel the user's own reaction to this post (NIP-09 kind-5 delete of the
  /// kind-7 reaction event). Second tap on a highlighted reaction icon.
  Future<void> _cancelReaction(
    BuildContext context,
    WidgetRef ref,
    Event myReaction,
  ) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return;
    final signed = NostrActions(identity).deleteEvent(myReaction);
    await ref.read(relayPoolProvider).publishAndWait(signed);
    // Remove locally so the icon un-fills + the tally drops immediately.
    await ref.read(eventStoreProvider.notifier).removeEvent(myReaction.id);
    if (context.mounted) {
      _snack(context, '已取消反应');
    }
  }

  Future<void> _share(BuildContext context) async {
    final url = 'https://njump.me/${hexToNote(event.id)}';
    try {
      await SharePlus.instance.share(
        ShareParams(text: url, subject: 'Costr 帖子'),
      );
    } catch (_) {
      // Desktop platforms where share_plus may be unavailable → fall back to
      // copying the link so the action still does something useful.
      try {
        await Clipboard.setData(ClipboardData(text: url));
        if (context.mounted) _snack(context, '已复制分享链接');
      } catch (_) {
        if (context.mounted) _snack(context, '分享失败');
      }
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
    final ok = await bookmarkEvent(
      ref,
      event.id,
      publicList: choice == 'public',
    );
    if (context.mounted) {
      _snack(
        context,
        ok.ok
            ? '已收藏到${choice == 'public' ? '公开' : '私人'}书签'
            : '收藏失败：${ok.reason}',
      );
    }
  }

  Future<bool?> _confirm(BuildContext context, String message) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
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
  const _Action({
    required this.icon,
    required this.color,
    required this.onTap,
    this.count = 0,
  });
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final int count;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) {
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
    // X-style: icon + a compact count to its right. Hidden when 0 so the
    // row stays clean for posts with no observed interactions.
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 32,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 4),
            Text(
              count > 999 ? '${(count / 1000).toStringAsFixed(1)}k' : '$count',
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
