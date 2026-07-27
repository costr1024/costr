/// Renders one kind-1 text note: avatar, display name/npub, relative time, content.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../../widgets/markdown_content.dart';

class EventCard extends ConsumerWidget {
  const EventCard({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relativeTime(int createdAt) {
    final eventTime =
        DateTime.fromMillisecondsSinceEpoch(createdAt * 1000, isUtc: true);
    final delta = DateTime.now().difference(eventTime);
    if (delta.isNegative) return 'just now';
    final mins = delta.inMinutes;
    if (mins < 1) return 'just now';
    if (mins < 60) return '${mins}m';
    final hours = delta.inHours;
    if (hours < 24) return '${hours}h';
    final days = delta.inDays;
    if (days < 30) return '${days}d';
    return '${eventTime.year}-${eventTime.month.toString().padLeft(2, '0')}'
        '-${eventTime.day.toString().padLeft(2, '0')}';
  }
}
