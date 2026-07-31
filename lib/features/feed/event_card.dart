/// Renders one kind-1 text note: avatar, display name/npub, relative time, content.
library;

import 'dart:ui' as dart_ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../nostr/actions.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import '../../widgets/markdown_content.dart';
import '../../widgets/post_actions.dart';
import 'zap_sheet.dart';

class EventCard extends ConsumerWidget {
  const EventCard({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Kind-6/16 reposts render as a "↻ 转发" header above the embedded
    // reposted note (Amethyst pattern), not as a bare text card.
    if (event.isRepost) return _RepostView(event: event);
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
    final status = ref.watch(userStatusProvider(event.pubkey)).value;
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => context.push('/n/${event.id}'),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFEFF3F4))),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 10),
                child: GestureDetector(
                  onTap: () => context.push('/u/${event.pubkey}'),
                  child: Avatar(pubkey: event.pubkey, radius: 16),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: GestureDetector(
                            onTap: () => context.push('/u/${event.pubkey}'),
                            child: Text(
                              displayLabelFor(event.pubkey, meta),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _relativeTime(event.createdAt),
                          style: theme.textTheme.labelSmall,
                        ),
                        _PostMenu(event: event),
                      ],
                    ),
                    if (status != null && status.isNotEmpty)
                      _StatusLine(text: status),
                    if (event.isReply) _ReplyContext(event: event),
                    const SizedBox(height: 6),
                    _NsfwAwareContent(event: event),
                    if (event.hashtags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in event.hashtags)
                            _HashtagChip(tag: tag),
                        ],
                      ),
                    ],
                    const SizedBox(height: 2),
                    _ReactionChips(eventId: event.id),
                    const SizedBox(height: 2),
                    PostActions(event: event),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relativeTime(int createdAt) {
    final eventTime = DateTime.fromMillisecondsSinceEpoch(
      createdAt * 1000,
      isUtc: true,
    );
    final delta = DateTime.now().difference(eventTime);
    if (delta.isNegative) return '刚刚';
    final mins = delta.inMinutes;
    if (mins < 1) return '刚刚';
    if (mins < 60) return '$mins分';
    final hours = delta.inHours;
    if (hours < 24) return '$hours时';
    final days = delta.inDays;
    if (days < 30) return '$days天';
    return '${eventTime.year}-${eventTime.month.toString().padLeft(2, '0')}'
        '-${eventTime.day.toString().padLeft(2, '0')}';
  }
}

/// NIP-38 user status shown under the author name in the feed (Amethyst
/// pattern). Single line; if it overflows, it scrolls horizontally instead of
/// ellipsizing (so the full status is reachable, not truncated).
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Text(
        text,
        maxLines: 1,
        softWrap: false,
        style: theme.textTheme.bodySmall?.copyWith(
          color: CostrColors.text3,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}

/// Renders a kind-6/16 repost: a "↻ 转发" header (reposter avatar + name +
/// time + post menu) above the embedded reposted note. The reposted note is
/// fetched via [eventByIdProvider] and rendered as a nested [EventCard]; if
/// it hasn't arrived yet, a placeholder is shown. Tapping the inner card
/// opens the reposted note's detail page (Amethyst behavior).
class _RepostView extends ConsumerWidget {
  const _RepostView({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
    final theme = Theme.of(context);
    final repostedId = event.repostedEventId;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFEFF3F4))),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => context.push('/u/${event.pubkey}'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.repeat_rounded,
                        size: 15,
                        color: CostrColors.text3,
                      ),
                      const SizedBox(width: 6),
                      Avatar(pubkey: event.pubkey, radius: 10),
                      const SizedBox(width: 5),
                    ],
                  ),
                ),
                Flexible(
                  child: GestureDetector(
                    onTap: () => context.push('/u/${event.pubkey}'),
                    child: Text(
                      '${displayLabelFor(event.pubkey, meta)} 转发',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: CostrColors.text3,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  EventCard._relativeTime(event.createdAt),
                  style: theme.textTheme.labelSmall,
                ),
                _PostMenu(event: event),
              ],
            ),
            const SizedBox(height: 6),
            if (repostedId == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '转发内容不可用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CostrColors.text3,
                  ),
                ),
              )
            else
              _RepostedEmbed(id: repostedId),
          ],
        ),
      ),
    );
  }
}

/// Fetches + renders the note a repost points at. Falls back to a placeholder
/// while loading or if the referenced event isn't a post (a repost should
/// only embed a post-like note).
class _RepostedEmbed extends ConsumerWidget {
  const _RepostedEmbed({required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(eventByIdProvider(id));
    final ev = async.value;
    if (ev == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          async.isLoading ? '加载转发内容…' : '转发内容不可用',
          style: theme.textTheme.bodySmall?.copyWith(color: CostrColors.text3),
        ),
      );
    }
    if (!ev.isPostLike) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '转发内容不可用',
          style: theme.textTheme.bodySmall?.copyWith(color: CostrColors.text3),
        ),
      );
    }
    return EventCard(event: ev);
  }
}

/// "回复 @用户" context line above reply posts (X style).
class _ReplyContext extends ConsumerWidget {
  const _ReplyContext({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = event.replyToId;
    if (parent == null) return const SizedBox.shrink();

    // Find the parent event's author in the store.
    String? parentPubkey;
    final store = ref.read(eventStoreProvider);
    for (final e in store) {
      if (e.id == parent) {
        parentPubkey = e.pubkey;
        break;
      }
    }
    if (parentPubkey == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Icon(Icons.reply, size: 14, color: CostrColors.text3),
            const SizedBox(width: 4),
            Text(
              '回复',
              style: TextStyle(fontSize: 13, color: CostrColors.text3),
            ),
          ],
        ),
      );
    }

    final meta = ref.watch(metadataProvider(parentPubkey)).value;
    final name = meta?.bestName ?? shortenEntity(hexToNpub(parentPubkey));

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        onTap: () => context.push('/n/$parent'),
        child: Row(
          children: [
            Icon(Icons.reply, size: 14, color: CostrColors.text3),
            const SizedBox(width: 4),
            Text(
              '回复 @$name',
              style: TextStyle(
                fontSize: 13,
                color: CostrColors.text3,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows NSFW warning overlay if the event has an "nsfw" tag, unless
/// autoReveal is on or the user has already tapped "查看" on this card.
class _NsfwAwareContent extends ConsumerStatefulWidget {
  const _NsfwAwareContent({required this.event});
  final Event event;

  @override
  ConsumerState<_NsfwAwareContent> createState() => _NsfwAwareContentState();
}

class _NsfwAwareContentState extends ConsumerState<_NsfwAwareContent> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(nsfwSettingsProvider);
    if (!widget.event.isNsfw || settings.autoReveal || _revealed) {
      return MarkdownContent(event: widget.event);
    }
    // NSFW warning overlay.
    final theme = Theme.of(context);
    // The Stack's only non-positioned child is the (blurred) content, so for a
    // short NSFW post the Stack would shrink to the content's tiny size and
    // squeeze the warning overlay into a few-dozen pixels — making the warning
    // text wrap one char per line and overflow into the next card. Force full
    // width (SizedBox) + a minimum height (ConstrainedBox) so the warning
    // always has room, while long posts still size the Stack by their content.
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 200),
        child: Stack(
          children: [
            // Blurred content behind.
            ClipRect(
              child: ImageFiltered(
                imageFilter: dart_ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: Opacity(
                  opacity: 0.3,
                  child: MarkdownContent(event: widget.event),
                ),
              ),
            ),
            // Warning overlay.
            Positioned.fill(
              child: Container(
                color: theme.colorScheme.surface.withValues(alpha: 0.7),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 36,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 8),
                    Text('此帖可能包含敏感内容', style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.visibility, size: 18),
                      label: const Text('点击查看'),
                      onPressed: () => setState(() => _revealed = true),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReactionChips extends ConsumerWidget {
  const _ReactionChips({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(reactionsProvider(eventId));
    if (counts.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Wrap(
        spacing: 6,
        runSpacing: 2,
        children: [
          for (final entry in counts.entries)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (entry.value.emojiUrl != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 3),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Image.network(
                          entry.value.emojiUrl!,
                          width: 16,
                          height: 16,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (_, Object e, _) =>
                              Text(entry.key, style: const TextStyle(fontSize: 13)),
                        ),
                      ),
                    )
                  else
                    Text(entry.key, style: const TextStyle(fontSize: 13)),
                  if (entry.value.count > 1) ...[
                    const SizedBox(width: 2),
                    Text('${entry.value.count}', style: theme.textTheme.labelSmall),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Hashtag chip on a post. Tap → filter the home feed by this tag (matches
/// the demo `.tag-chip`). Long-press → a sheet to follow / unfollow the tag
/// (NIP-51 kind-30015) or filter the feed.
class _HashtagChip extends ConsumerWidget {
  const _HashtagChip({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final followed = (ref.watch(followedTagsProvider).value ?? const <String>[])
        .contains(tag);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        ref.read(tagFilterProvider.notifier).set(tag);
        context.go('/feed');
      },
      onLongPress: () => _showTagSheet(context, ref, followed),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '#$tag',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  void _showTagSheet(BuildContext context, WidgetRef ref, bool followed) {
    showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('#$tag', style: Theme.of(ctx).textTheme.titleSmall),
            ),
            ListTile(
              leading: const Icon(Icons.filter_alt_outlined, size: 20),
              title: const Text('在首页按此标签过滤'),
              onTap: () {
                Navigator.pop(ctx);
                ref.read(tagFilterProvider.notifier).set(tag);
                context.go('/feed');
              },
            ),
            ListTile(
              leading: Icon(
                followed
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
                size: 20,
              ),
              title: Text(followed ? '取消关注此标签' : '关注此标签'),
              onTap: () {
                Navigator.pop(ctx);
                if (followed) {
                  ref.read(followedTagsProvider.notifier).remove(tag);
                } else {
                  ref.read(followedTagsProvider.notifier).add(tag);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-right `⋮` menu for a post: copy post id / copy full content / zap (打闪).
/// For the user's OWN posts, a 删除 (NIP-09 kind-5) item is appended.
class _PostMenu extends ConsumerWidget {
  const _PostMenu({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final myPubkey = ref.watch(identityProvider).value?.pubkeyHex;
    final isSelf = myPubkey != null && myPubkey == event.pubkey;
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'copy_id',
          child: Text('复制帖子 id'),
        ),
        const PopupMenuItem<String>(
          value: 'copy_content',
          child: Text('复制全文'),
        ),
        const PopupMenuItem<String>(value: 'zap', child: Text('打闪')),
        if (isSelf) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'delete',
            child: Text('删除'),
          ),
        ],
      ],
      onSelected: (String value) async {
        if (value == 'zap') {
          showZapSheet(context, event);
          return;
        }
        if (value == 'delete') {
          final ok = await _confirmDelete(context);
          if (!ok) return;
          final id = ref.read(identityProvider).value;
          if (id == null) return;
          final signed = NostrActions(id).deleteEvent(event);
          await ref.read(relayPoolProvider).publishAndWait(signed);
          await ref.read(eventStoreProvider.notifier).removeEvent(event.id);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已请求删除（部分中继可能不支持）'),
                duration: Duration(seconds: 2),
              ),
            );
          }
          return;
        }
        if (value == 'copy_id') {
          // Copy as `nostr:nevent1…` (NIP-19) with relay + author hints, like
          // Amethyst — so pasting it elsewhere can fetch + render the post.
          final nevent = hexToNevent(
            event.id,
            relays: defaultRelays.take(2).toList(),
            authorHex: event.pubkey,
            kind: event.kind,
          );
          await Clipboard.setData(ClipboardData(text: 'nostr:$nevent'));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('已复制帖子 id（nostr:nevent1…）'),
                duration: Duration(seconds: 1),
              ),
            );
          }
          return;
        }
        final text = event.content;
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制全文'),
              duration: Duration(seconds: 1),
            ),
          );
        }
      },
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除帖子？'),
        content: const Text(
          '将向中继发送 NIP-09 删除请求。注意：并非所有中继都支持删除，'
          '已传播的帖子可能仍被其他客户端/中继保留。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}
