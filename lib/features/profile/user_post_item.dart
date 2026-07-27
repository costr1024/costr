/// One item in a user's profile post list: a top-level post, or a reply shown
/// with the parent post quoted above it (indented, hierarchy via a left rule).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../feed/event_card.dart';

class UserPostItem extends ConsumerWidget {
  const UserPostItem({super.key, required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parentId = event.replyToId;
    if (parentId == null) {
      return EventCard(event: event);
    }
    // Reply: quoted parent (indented) + the reply itself.
    return Padding(
      padding: const EdgeInsets.only(left: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  width: 2,
                ),
              ),
            ),
            padding: const EdgeInsets.only(left: 8),
            child: _QuotedParent(parentId: parentId),
          ),
          const SizedBox(height: 4),
          EventCard(event: event),
        ],
      ),
    );
  }
}

/// Compact quoted parent post: avatar + name + content preview, tappable to
/// the parent's detail page. Fetches via [eventByIdProvider].
class _QuotedParent extends ConsumerWidget {
  const _QuotedParent({required this.parentId});
  final String parentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(eventByIdProvider(parentId));
    final theme = Theme.of(context);
    return async.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('回复的帖子加载中…', style: theme.textTheme.labelSmall),
      ),
      error: (Object e, _) => Text('父帖加载失败：$e',
          style: theme.textTheme.labelSmall),
      data: (Event? parent) {
        if (parent == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('回复的帖子未在中继上', style: theme.textTheme.labelSmall),
          );
        }
        return GestureDetector(
          onTap: () => context.push('/n/$parentId'),
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final meta = ref.watch(metadataProvider(parent.pubkey)).value;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Avatar(pubkey: parent.pubkey, radius: 10),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            displayLabelFor(parent.pubkey, meta),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      parent.content,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }
}
