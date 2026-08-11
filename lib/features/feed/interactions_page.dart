/// Who liked / reposted a post: the raw kind-7 / kind-6-16 events that
/// reference it, as user rows (avatar + nickname + what they did — the
/// reaction glyph/image, 「转发了这条帖子」, or a quote's text). Tally chips
/// alone only show counts; this is the 「谁点赞/转发的」list behind the
/// down-chevron on the action row. Tap a row → the user's profile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../widgets/avatar.dart';
import '../../widgets/display_name.dart';
import '../../widgets/immersive.dart';
import '../../widgets/proxied_network_image.dart';

class InteractionsPage extends ConsumerWidget {
  const InteractionsPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched to TRIGGER the #e REQ (and surface fetch errors); the rows
    // themselves come from [interactorEventsProvider] — the live store+cache
    // merge — so late relay answers and likes arriving while the page is open
    // grow the list instead of being stuck on the first (possibly empty)
    // fetch snapshot ("通知里有点赞、点进来却没有" — the old first-EOSE-resolved
    // future often settled empty before the relay holding the like answered).
    final async = ref.watch(interactorsProvider(id));
    final events = ref.watch(interactorEventsProvider(id));
    return ImmersiveScaffold(
      topBar: AppBar(title: const Text('点赞与转发')),
      body: events.isNotEmpty
          ? ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: events.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 52, endIndent: 12),
              itemBuilder: (BuildContext _, int i) =>
                  _InteractorRow(event: events[i]),
            )
          : async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (Object e, _) => Center(child: Text('加载失败：$e')),
              data: (_) => const Center(child: Text('还没有点赞或转发')),
            ),
    );
  }
}

class _InteractorRow extends ConsumerWidget {
  const _InteractorRow({required this.event});
  final Event event;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final meta = ref.watch(metadataProvider(event.pubkey)).value;
    return InkWell(
      onTap: () => context.push('/u/${event.pubkey}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Avatar(pubkey: event.pubkey, radius: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DisplayName(pubkey: event.pubkey, meta: meta),
                  const SizedBox(height: 2),
                  Text(
                    _summary(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: CostrColors.of(context).text2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (event.kind == 7) _reactionGlyph(event),
          ],
        ),
      ),
    );
  }

  /// What the row's event DID to the post, in human words.
  String _summary() {
    if (event.kind == 7) {
      final c = event.content;
      if (c.isEmpty || c == '+') return '点赞了这条帖子';
      if (c.startsWith(':')) return '回应了这条帖子';
      return '回应了这条帖子 $c';
    }
    // Repost family: a kind-16 (or content-bearing kind-6) quote carries the
    // commenter's own text; a plain kind-6 is a bare repost.
    final embedded = parseEmbeddedRepost(event);
    if (embedded != null) return '转发了这条帖子';
    if (event.content.trim().isNotEmpty) {
      return '引用：${event.content.trim()}';
    }
    return '转发了这条帖子';
  }

  /// Trailing glyph for a reaction row: the NIP-30 image when the kind-7
  /// carries an `["emoji", shortcode, url]` tag, else the raw emoji text.
  Widget _reactionGlyph(Event e) {
    final c = e.content;
    if (c.startsWith(':')) {
      for (final t in e.tags) {
        if (t.length >= 3 &&
            t[0] == 'emoji' &&
            t[1] == c.substring(1, c.length - 1) &&
            t[2] is String) {
          return CostrNetworkImage(
            url: t[2] as String,
            width: 22,
            height: 22,
            fit: BoxFit.contain,
            errorWidget: (_) => const Text(''),
          );
        }
      }
      return Text(c, style: const TextStyle(fontSize: 16));
    }
    final glyph = (c.isEmpty || c == '+') ? '👍' : c;
    return Text(glyph, style: const TextStyle(fontSize: 18));
  }
}
