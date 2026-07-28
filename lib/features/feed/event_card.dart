/// Renders one kind-1 text note: avatar, display name/npub, relative time, content.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
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
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => context.push('/n/${event.id}'),
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
                  const SizedBox(height: 6),
                  MarkdownContent(event: event),
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
                  // Reaction display (NIP-25 kind-7).
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

/// Reaction emoji chips (NIP-25 kind-7 counts).
class _ReactionChips extends ConsumerWidget {
  const _ReactionChips({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(reactionsProvider(eventId));
    return async.when(
      loading: () => const SizedBox.shrink(),
      error: (_, _) => const SizedBox.shrink(),
      data: (Map<String, int> counts) {
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
      },
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
