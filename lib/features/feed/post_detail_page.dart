/// Post detail page — single post full-screen + reply placeholder.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../../widgets/markdown_content.dart';
import '../../widgets/post_actions.dart';
import 'event_card.dart';

class PostDetailPage extends ConsumerWidget {
  const PostDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final evAsync = ref.watch(eventByIdProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('帖子')),
      body: evAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => Center(child: Text('加载失败：$e')),
        data: (Event? event) {
          if (event == null) return const Center(child: Text('未找到该帖子（可能未在中继上）'));
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => context.push('/u/${event.pubkey}'),
                        child: Avatar(pubkey: event.pubkey, radius: 18),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: GestureDetector(
                          onTap: () => context.push('/u/${event.pubkey}'),
                          child: Consumer(
                            builder: (BuildContext context, WidgetRef ref, _) {
                              final meta = ref
                                  .watch(metadataProvider(event.pubkey))
                                  .value;
                              return Text(
                                displayLabelFor(event.pubkey, meta),
                                style: Theme.of(context)
                                    .textTheme
                                    .labelMedium
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  MarkdownContent(event: event, initiallyExpanded: true),
                  if (event.hashtags.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final t in event.hashtags)
                          Chip(
                            label: Text('#$t'),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                  const Divider(height: 24),
                  PostActions(event: event),
                  const SizedBox(height: 16),
                  _RepliesSection(eventId: event.id),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Replies section — fetches kind-1 events that reference this post via #e tag.
class _RepliesSection extends ConsumerWidget {
  const _RepliesSection({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(repliesProvider(eventId));
    final theme = Theme.of(context);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, _) => Text('回复加载失败：$e'),
      data: (List<Event> replies) {
        if (replies.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: Text('暂无回复', style: theme.textTheme.labelSmall),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('回复 (${replies.length})', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            for (final reply in replies)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: EventCard(event: reply),
              ),
          ],
        );
      },
    );
  }
}
