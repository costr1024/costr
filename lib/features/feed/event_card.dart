/// Renders one kind-1 text note: shortened npub, relative time, content.
library;

import 'package:flutter/material.dart';

import '../../models/event.dart';
import '../../utils/nip19.dart';

class EventCard extends StatelessWidget {
  const EventCard({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context) {
    final npub = hexToNpub(event.pubkey);
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  shortenEntity(npub),
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  _relativeTime(event.createdAt),
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              event.content,
              style: theme.textTheme.bodyMedium,
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
