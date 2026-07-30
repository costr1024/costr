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
import '../../utils/nip19.dart';
import '../../widgets/avatar.dart';
import '../../widgets/markdown_content.dart';
import '../../widgets/post_actions.dart';

class EventCard extends ConsumerWidget {
  const EventCard({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
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
                            ActionChip(
                              label: Text('#$tag'),
                              visualDensity: VisualDensity.compact,
                              onPressed: () => ref
                                  .read(tagFilterProvider.notifier)
                                  .set(tag),
                            ),
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
    final eventTime =
        DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
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
      if (e.id == parent) { parentPubkey = e.pubkey; break; }
    }
    if (parentPubkey == null) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            Icon(Icons.reply, size: 14, color: CostrColors.text3),
            const SizedBox(width: 4),
            Text('回复', style: TextStyle(fontSize: 13, color: CostrColors.text3)),
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
            Text('回复 @$name',
              style: TextStyle(fontSize: 13, color: CostrColors.text3, fontWeight: FontWeight.w600)),
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
    return Stack(
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
                Icon(Icons.warning_amber_rounded,
                    size: 40, color: theme.colorScheme.error),
                const SizedBox(height: 8),
                Text('此帖可能包含敏感内容',
                    style: theme.textTheme.bodyMedium),
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(entry.key,
                          style: const TextStyle(fontSize: 13)),
                      if (entry.value > 1) ...[
                        const SizedBox(width: 2),
                        Text('${entry.value}',
                            style: theme.textTheme.labelSmall),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
  }
}

/// Top-right `⋮` menu for a post: copy event id / copy full content.
class _PostMenu extends StatelessWidget {
  const _PostMenu({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 18),
      padding: EdgeInsets.zero,
      itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'copy_id',
          child: Text('复制 event id'),
        ),
        PopupMenuItem<String>(
          value: 'copy_content',
          child: Text('复制全文'),
        ),
      ],
      onSelected: (String value) async {
        final text = value == 'copy_id' ? event.id : event.content;
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          final label = value == 'copy_id' ? 'event id' : '全文';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已复制 $label'), duration: const Duration(seconds: 1)),
          );
        }
      },
    );
  }
}
