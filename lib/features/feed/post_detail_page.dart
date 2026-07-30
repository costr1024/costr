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
          if (event == null) {
            return const Center(child: Text('未找到该帖子（可能未在中继上）'));
          }
          // Watch replies so the original post knows whether to draw the
          // thread connector down to the first reply (DESIGN §3.5 / ui_demo
          // `.thread-line`). Cached by Riverpod, so re-watching here is free.
          final replies =
              ref.watch(repliesProvider(event.id)).value ?? const <Event>[];
          final hasReplies = replies.isNotEmpty;
          final theme = Theme.of(context);
          return SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // Original post. Wrapped in a Stack so the thread line can
                  // descend from the avatar (center x = 28) down to the row
                  // bottom, connecting into the replies below.
                  Stack(
                    children: <Widget>[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: () => context.push('/u/${event.pubkey}'),
                                child: Avatar(
                                    pubkey: event.pubkey, radius: 18),
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: GestureDetector(
                                  onTap: () =>
                                      context.push('/u/${event.pubkey}'),
                                  child: Consumer(
                                    builder: (BuildContext context,
                                        WidgetRef ref, _) {
                                      final meta = ref
                                          .watch(metadataProvider(
                                              event.pubkey))
                                          .value;
                                      return Text(
                                        displayLabelFor(event.pubkey, meta),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.w600),
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
                          MarkdownContent(
                              event: event, initiallyExpanded: true),
                          if (event.hashtags.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              children: <Widget>[
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
                        ],
                      ),
                      if (hasReplies)
                        Positioned(
                          left: 27,
                          top: 18,
                          bottom: 0,
                          width: 2,
                          child: ColoredBox(
                            color: theme.colorScheme.outline,
                            child: const SizedBox.expand(),
                          ),
                        ),
                    ],
                  ),
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

/// Replies section — fetches kind-1 events that reference this post via #e
/// tag and renders them as an X-style thread: each reply's avatar sits on a
/// vertical connector line that runs down from the original post (see DESIGN
/// §3.5 / ui_demo.html `.thread-line`). EventCard is reused unchanged for
/// each reply; the line is an overlay aligned to its avatar center (x=28).
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
          children: <Widget>[
            for (int i = 0; i < replies.length; i++)
              _ThreadReplyCard(
                event: replies[i],
                isLast: i == replies.length - 1,
              ),
          ],
        );
      },
    );
  }
}

/// One reply in the thread: [EventCard] with a connector line overlaid at the
/// avatar center. The avatar (opaque) hides the line's middle, so it reads as
/// segment-above — avatar — segment-below. The last reply has no segment
/// below its avatar.
class _ThreadReplyCard extends StatelessWidget {
  const _ThreadReplyCard({required this.event, required this.isLast});
  final Event event;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // EventCard avatar center: padding(12) + top(2) + radius(16) = (28, 30).
    return Stack(
      children: <Widget>[
        EventCard(event: event),
        Positioned(
          left: 27,
          top: 0,
          bottom: isLast ? null : 0,
          width: 2,
          height: isLast ? 30 : null,
          child: ColoredBox(
            color: theme.colorScheme.outline,
            child: const SizedBox.expand(),
          ),
        ),
      ],
    );
  }
}
