/// Post detail page — full thread view.
///
/// Renders the ancestor chain of the focused post **root-first**
/// (`[root, …, focused]`) so the replied-to main post is always visible
/// above a reply the user opened (e.g. from a notification), followed by the
/// direct replies to the focused post. Every post reuses [EventCard].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../models/event.dart';
import 'event_card.dart';

class PostDetailPage extends ConsumerWidget {
  const PostDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chainAsync = ref.watch(threadAncestorsProvider(id));
    return Scaffold(
      appBar: AppBar(title: const Text('帖子')),
      body: chainAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object e, _) => Center(child: Text('加载失败：$e')),
        data: (List<Event> chain) {
          if (chain.isEmpty) {
            return const Center(child: Text('未找到该帖子（可能未在中继上）'));
          }
          final focused = chain.last;
          final ancestors =
              chain.length > 1 ? chain.sublist(0, chain.length - 1) : <Event>[];
          final theme = Theme.of(context);
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final e in ancestors) EventCard(event: e),
                  if (ancestors.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 2),
                      child: Text(
                        '你打开的帖子',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                  EventCard(event: focused),
                  _RepliesSection(eventId: focused.id),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Direct replies to [eventId], newest-first. Plain [EventCard]s (the former
/// avatar-column connector line was removed).
class _RepliesSection extends ConsumerWidget {
  const _RepliesSection({required this.eventId});
  final String eventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(repliesProvider(eventId));
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, _) => Text('回复加载失败：$e'),
      data: (List<Event> replies) {
        if (replies.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Text('暂无回复')),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[for (final e in replies) EventCard(event: e)],
        );
      },
    );
  }
}
