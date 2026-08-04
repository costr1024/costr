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
import '../../utils/nav.dart';
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import '../../widgets/display_name.dart';
import '../../widgets/markdown_content.dart';
import '../../widgets/post_actions.dart';
import '../../widgets/proxied_network_image.dart';
import 'zap_sheet.dart';

class EventCard extends ConsumerStatefulWidget {
  const EventCard({super.key, required this.event});
  final Event event;

  @override
  ConsumerState<EventCard> createState() => _EventCardState();
}

class _EventCardState extends ConsumerState<EventCard> {
  Event get event => widget.event;

  /// Per-post manual proxy toggle. Flipped by the "代理媒体" button in the
  /// name bar (only shown when [proxyMediaEnabledProvider] is ON and the post
  /// actually has media). Rebuilds this post's media through the proxy
  /// mirror. Manual per-post so the public proxy only serves what the user
  /// explicitly asked it to.
  bool _proxyMedia = false;

  void _toggleProxy() {
    if (!mounted) return;
    setState(() => _proxyMedia = !_proxyMedia);
  }

  @override
  Widget build(BuildContext context) {
    // Kind-6/16 reposts render as a "↻ 转发" header above the embedded
    // reposted note (Amethyst pattern), not as a bare text card.
    if (event.isRepost) return _RepostView(event: event);
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
    final status = ref.watch(userStatusProvider(event.pubkey)).value;
    final theme = Theme.of(context);
    return InkWell(
      onTap: () => pushPostDetail(context, event.id),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: CostrColors.of(context).border),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              // Row 1 (X-style): avatar + display name + relative time + menu,
              // all on one line so the nickname sits level with the avatar.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: <Widget>[
                  GestureDetector(
                    onTap: () => context.push('/u/${event.pubkey}'),
                    child: Avatar(pubkey: event.pubkey, radius: 16),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Row(
                      children: <Widget>[
                        Flexible(
                          child: GestureDetector(
                            onTap: () => context.push('/u/${event.pubkey}'),
                            child: DisplayName(
                              pubkey: event.pubkey,
                              meta: meta,
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
                        // Per-post "代理媒体" toggle. Shown ONLY when the
                        // user has enabled the proxy-media feature (a LOCAL
                        // setting, never synced to relays) AND this post
                        // actually contains image/video links — text-only
                        // posts hide it. Tapping routes THIS post's media
                        // through proxy.bostr.online. Hidden entirely when
                        // the feature is off.
                        if (ref.watch(proxyMediaEnabledProvider) &&
                            postHasMedia(event)) ...[
                          const SizedBox(width: 6),
                          _ProxyMediaButton(
                            active: _proxyMedia,
                            onTap: _toggleProxy,
                          ),
                        ],
                        _PostMenu(event: event),
                      ],
                    ),
                  ),
                ],
              ),
              // Row 2+: status / reply context / content / actions, indented to
              // align with the nickname (avatar diameter 32 + 10 gap = 42).
              Padding(
                padding: const EdgeInsets.only(left: 42),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (status != null && status.isNotEmpty)
                      _StatusLine(text: status),
                    if (event.isReply) _ReplyContext(event: event),
                    const SizedBox(height: 6),
                    _NsfwAwareContent(event: event, proxyMedia: _proxyMedia),
                    if (event.hashtags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      _Hashtags(tags: event.hashtags),
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
/// Per-post "代理媒体" affordance. Compact (two CJK glyphs + label) so it fits
/// in the name bar beside the nickname + time without overflow. Tapping opts
/// this post's failed media into loading through the proxy mirror.
class _ProxyMediaButton extends StatelessWidget {
  const _ProxyMediaButton({required this.active, required this.onTap});
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Active state = media is currently loading through the proxy mirror
    // (filled brand chip). Inactive = origin only (outlined chip). Compact
    // so it sits inline with the nickname + time without overflowing.
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active ? CostrColors.of(context).brand : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: active
              ? null
              : Border.all(
                  color: CostrColors.of(context).brand.withValues(alpha: 0.5),
                ),
        ),
        child: Text(
          '代理媒体',
          style: TextStyle(
            fontSize: 11,
            color: active
                ? CostrColors.of(context).onBrand
                : CostrColors.of(context).brand,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

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
          color: CostrColors.of(context).text3,
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
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: CostrColors.of(context).border),
        ),
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
                        color: CostrColors.of(context).text3,
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
                    child: Text.rich(
                      TextSpan(
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: CostrColors.of(context).text3,
                        ),
                        children: <InlineSpan>[
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: DisplayName(
                              pubkey: event.pubkey,
                              meta: meta,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: CostrColors.of(context).text3,
                              ),
                            ),
                          ),
                          const TextSpan(text: ' 转发'),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _EventCardState._relativeTime(event.createdAt),
                  style: theme.textTheme.labelSmall,
                ),
                _PostMenu(event: event),
              ],
            ),
            const SizedBox(height: 6),
            // "不可用" ONLY when there is truly nothing to show: no resolvable
            // `e` tag AND no NIP-18 embedded JSON in the content. Amethyst
            // reposts carry the full original note in content, so they render
            // even when the `e` tag's marker slot holds a pubkey (which made
            // repostedEventId null and short-circuited to "不可用" — the
            // "转发内容不可用" bug on Amethyst reposts).
            if (repostedId == null && parseEmbeddedRepost(event) == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  '转发内容不可用',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CostrColors.of(context).text3,
                  ),
                ),
              )
            else
              _RepostedEmbed(repost: event),
          ],
        ),
      ),
    );
  }
}

/// Fetches + renders the note a repost points at. Prefer the repost's own
/// embedded content (NIP-18 JSON — instant, no relay fetch), then fall back
/// to a cache + relay-hint-targeted fetch via [repostedEventProvider]. Shows a
/// placeholder while loading; when the referenced event can't be resolved the
/// placeholder carries a 重试 tap (the provider caches its null result, so
/// without an explicit invalidate the card would stay "不可用" forever even
/// after the note becomes reachable).
class _RepostedEmbed extends ConsumerWidget {
  const _RepostedEmbed({required this.repost});
  final Event repost;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(repostedEventProvider(repost.id));
    final ev = async.value;
    if (ev == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Text(
              async.isLoading ? '加载转发内容…' : '转发内容不可用',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CostrColors.of(context).text3,
              ),
            ),
            if (!async.isLoading) ...[
              const SizedBox(width: 10),
              GestureDetector(
                onTap: () => ref.invalidate(repostedEventProvider(repost.id)),
                child: Text(
                  '重试',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: CostrColors.of(context).brand,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }
    if (!ev.isPostLike) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          '转发内容不可用',
          style: theme.textTheme.bodySmall?.copyWith(
            color: CostrColors.of(context).text3,
          ),
        ),
      );
    }
    return EventCard(event: ev);
  }
}

/// "回复 @用户" context line + a compact preview of the replied-to post's
/// content above reply posts (X style) — ONE level up only (the direct
/// parent), not the full ancestor chain. Without the preview a reply in the
/// feed is unreadable ("回复 @某人" with no idea what was said); the parent
/// is resolved via [eventByIdProvider]'s 3-tier lookup (SQLite → in-memory →
/// relay REQ), so the preview fills in even when the parent isn't in the
/// current feed window. Tapping anywhere opens the parent's thread.
class _ReplyContext extends ConsumerWidget {
  const _ReplyContext({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parent = event.replyToId;
    if (parent == null) return const SizedBox.shrink();

    // Resolve the parent event (instant when cached/in-store, bounded relay
    // fetch otherwise). Watched so the box fills in the moment it lands.
    final parentEvent = ref.watch(eventByIdProvider(parent)).value;

    // Parent author for the header line: prefer the resolved event, fall back
    // to an in-memory scan so "回复 @name" renders before the async lookup
    // settles (the old behavior, kept as the fast path).
    String? parentPubkey = parentEvent?.pubkey;
    if (parentPubkey == null) {
      final store = ref.read(eventStoreProvider);
      for (final e in store) {
        if (e.id == parent) {
          parentPubkey = e.pubkey;
          break;
        }
      }
    }
    if (parentPubkey == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Icon(Icons.reply, size: 14, color: CostrColors.of(context).text3),
            const SizedBox(width: 4),
            Text(
              '回复',
              style: TextStyle(
                fontSize: 13,
                color: CostrColors.of(context).text3,
              ),
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
        onTap: () => pushPostDetail(context, parent),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.reply,
                  size: 14,
                  color: CostrColors.of(context).text3,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    '回复 @$name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: CostrColors.of(context).text3,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            if (parentEvent != null) ...[
              const SizedBox(height: 4),
              _ReplyParentPreview(parent: parentEvent),
            ],
          ],
        ),
      ),
    );
  }
}

/// The replied-to post rendered as a light preview box: the parent author's
/// name + the content truncated to a few lines (plain text — no markdown/
/// images: this is a context hint, not the post itself; media-heavy or
/// markdown formatting would bloat every reply card in the feed). Repost
/// parents show a placeholder (their content is NIP-18 JSON); NSFW parents
/// honor the autoReveal setting instead of leaking the text.
class _ReplyParentPreview extends ConsumerWidget {
  const _ReplyParentPreview({required this.parent});
  final Event parent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    String? previewText;
    if (parent.isRepost) {
      previewText = '🔁 转发的帖子';
    } else {
      final content = parent.content.trim();
      if (content.isNotEmpty) {
        final settings = ref.watch(nsfwSettingsProvider);
        previewText = (parent.isNsfw && !settings.autoReveal)
            ? '此帖可能包含敏感内容'
            // Collapse whitespace so the first lines of the post fill the
            // truncated preview instead of being eaten by blank lines.
            : content.replaceAll(RegExp(r'\s+'), ' ');
      }
    }
    final meta = ref.watch(metadataProvider(parent.pubkey)).value;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: CostrColors.of(context).bg2,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CostrColors.of(context).border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DisplayName(
            pubkey: parent.pubkey,
            meta: meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: CostrColors.of(context).text3,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (previewText != null) ...[
            const SizedBox(height: 2),
            Text(
              previewText,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: CostrColors.of(context).text2,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Shows NSFW warning overlay if the event has an "nsfw" tag, unless
/// autoReveal is on or the user has already tapped "查看" on this card.
class _NsfwAwareContent extends ConsumerStatefulWidget {
  const _NsfwAwareContent({required this.event, this.proxyMedia = false});
  final Event event;
  final bool proxyMedia;

  @override
  ConsumerState<_NsfwAwareContent> createState() => _NsfwAwareContentState();
}

class _NsfwAwareContentState extends ConsumerState<_NsfwAwareContent> {
  bool _revealed = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(nsfwSettingsProvider);
    if (!widget.event.isNsfw || settings.autoReveal || _revealed) {
      return MarkdownContent(
        event: widget.event,
        proxyMedia: widget.proxyMedia,
      );
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
                  child: MarkdownContent(
                    event: widget.event,
                    proxyMedia: widget.proxyMedia,
                  ),
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
                        child: CostrNetworkImage(
                          url: entry.value.emojiUrl!,
                          width: 16,
                          height: 16,
                          fit: BoxFit.cover,
                          errorWidget: (BuildContext _) => Text(
                            entry.key,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    )
                  else
                    Text(entry.key, style: const TextStyle(fontSize: 13)),
                  if (entry.value.count > 1) ...[
                    const SizedBox(width: 2),
                    Text(
                      '${entry.value.count}',
                      style: theme.textTheme.labelSmall,
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Hashtag row on a post. When there are more than ~2 rows of chips, collapse
/// to the first [_kCollapsedChips] + a "+N" expand chip; tap to expand/collapse.
class _Hashtags extends StatefulWidget {
  const _Hashtags({required this.tags});
  final List<String> tags;

  @override
  State<_Hashtags> createState() => _HashtagsState();
}

class _HashtagsState extends State<_Hashtags> {
  static const int _kCollapsedChips = 6;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final tags = widget.tags;
    final show = _expanded ? tags : tags.take(_kCollapsedChips).toList();
    final hidden = tags.length - show.length;
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        for (final tag in show) _HashtagChip(tag: tag),
        if (hidden > 0)
          ActionChip(
            label: Text(_expanded ? '收起' : '+$hidden'),
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
      ],
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
            ListTile(
              leading: const Icon(Icons.block, size: 20),
              title: const Text('屏蔽此标签'),
              subtitle: const Text('含此标签的帖子不再出现在信息流里'),
              onTap: () {
                Navigator.pop(ctx);
                muteEntry(ref, ['t', tag], add: true);
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
        const PopupMenuItem<String>(value: 'copy_id', child: Text('复制帖子 id')),
        const PopupMenuItem<String>(value: 'copy_content', child: Text('复制全文')),
        const PopupMenuItem<String>(value: 'zap', child: Text('打闪')),
        if (isSelf) ...[
          const PopupMenuDivider(),
          const PopupMenuItem<String>(value: 'delete', child: Text('删除')),
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
