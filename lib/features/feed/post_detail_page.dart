/// Post detail page — full thread view.
///
/// Renders the ancestor chain of the focused post **root-first**
/// (`[root, …, focused]`) so the replied-to main post is always visible
/// above a reply the user opened (e.g. from a notification), followed by the
/// direct replies to the focused post. Every post reuses [EventCard].
///
/// When opened from a notification the focused post is usually a REPLY deep
/// in the chain — the page therefore auto-scrolls to it (and flashes a short
/// highlight) once the ancestor chain settles, so the user lands on the
/// exact post they tapped, not the thread root ("回帖通知没定位到那条回帖"
/// bug). Re-positions when the chain grows (ancestors resolve async and are
/// prepended, shifting the focused card down).
///
/// When the chain resolves TRUNCATED (the topmost post is itself a reply but
/// its parent couldn't be fetched — the parent lives only on a relay that
/// was down / rate-limiting / slow at lookup time, or the parent was
/// deleted), a retry row is shown above the chain: the one-shot lookups
/// cache their miss for the session, so without an explicit retry the parent
/// would stay missing even after the relay recovers ("桥接 relay 上的帖子
/// 看不到父帖" bug).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../widgets/immersive.dart';
import 'event_card.dart';

class PostDetailPage extends ConsumerStatefulWidget {
  const PostDetailPage({super.key, required this.id});
  final String id;

  @override
  ConsumerState<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends ConsumerState<PostDetailPage> {
  final GlobalKey _focusedKey = GlobalKey();
  Timer? _highlightOff;
  bool _highlight = false;
  // Chain length last time we positioned to the focused card. Ancestors
  // resolve async and are PREPENDED, which shifts the focused card down —
  // re-position whenever the chain length changes so the user still lands on
  // the focused post after the prepend.
  int _positionedForLen = -1;

  @override
  void didUpdateWidget(PostDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.id != widget.id) {
      _positionedForLen = -1; // a different post — position again
    }
  }

  @override
  void dispose() {
    _highlightOff?.cancel();
    super.dispose();
  }

  /// Scroll the focused card into view (near the top, keeping a little
  /// context above it) and flash a highlight so it's easy to spot. Scheduled
  /// post-frame because the card must be laid out before it can be scrolled
  /// to. Idempotent per chain length.
  void _positionToFocused(int chainLen) {
    if (_positionedForLen == chainLen) return;
    _positionedForLen = chainLen;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _focusedKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
      if (!_highlight) setState(() => _highlight = true);
      _highlightOff?.cancel();
      _highlightOff = Timer(const Duration(milliseconds: 1800), () {
        if (mounted) setState(() => _highlight = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    // Fetch this post's reactions/reposts while the thread is open. The
    // like tally / reaction chips / 「谁点赞/转发了」chevron all derive from
    // the capped in-memory store, which evicts kind-7 first — on a live
    // firehose reactions to anything but the newest posts are usually gone
    // (or never arrived), leaving the entry dead-locked invisible. Watching
    // [interactorsProvider] issues the one-shot #e REQ here (same as
    // [_RepliesSection] does for replies); its answers also flow through the
    // pool's merged stream into the store, so the counts + chevron populate
    // deterministically instead of by firehose luck.
    ref.watch(interactorsProvider(widget.id));
    // Show the focused post as soon as it resolves (usually instant — it's
    // cached when opened from the feed/notifications). Ancestors load in the
    // background via threadAncestorsProvider and are prepended above when
    // ready, so the page is never blank while the chain resolves.
    final focusedAv = ref.watch(eventByIdProvider(widget.id));
    final chainAv = ref.watch(threadAncestorsProvider(widget.id));
    return ImmersiveScaffold(
      topBar: AppBar(title: const Text('帖子')),
      body: ImmersiveScrollDetector(
        child: focusedAv.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (Object e, _) => Center(child: Text('加载失败：$e')),
          data: (Event? focused) {
            if (focused == null) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('未找到该帖子（可能未在中继上）'),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () =>
                          ref.invalidate(eventByIdProvider(widget.id)),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              );
            }
            // chain is root-first ending in focused; null while still loading.
            final chain = chainAv.value ?? const <Event>[];
            final ancestors = chain.length > 1
                ? chain.sublist(0, chain.length - 1)
                : <Event>[];
            final displayFocused = chain.isNotEmpty ? chain.last : focused;
            final theme = Theme.of(context);
            // Once the chain has settled (AsyncValue data), position to the
            // focused post. Called during build but only schedules a post-frame
            // callback — no setState during build. Re-runs when the chain
            // length changes (ancestors prepended async).
            if (chainAv.value != null) _positionToFocused(chain.length);
            return SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    // Truncated chain: the topmost post is itself a reply, so
                    // there SHOULD be more above it — its parent couldn't be
                    // fetched (parent lives only on a relay that was down /
                    // rate-limited / slow at lookup time, or was deleted).
                    // Offer an explicit retry: the one-shot lookups cache
                    // their miss, so without it the parent stays missing for
                    // the whole session even after the relay recovers.
                    if (chain.isNotEmpty && chain.first.isReply)
                      _AncestorsRetryRow(
                        top: chain.first,
                        focusedId: widget.id,
                      ),
                    for (final e in ancestors) EventCard(event: e),
                    if (ancestors.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 2),
                        child: Text(
                          '你打开的帖子',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: CostrColors.of(context).text3,
                          ),
                        ),
                      ),
                    ],
                    // Highlight flash on the focused card right after the
                    // auto-scroll, so the user can pick it out of the chain.
                    AnimatedContainer(
                      key: _focusedKey,
                      duration: const Duration(milliseconds: 600),
                      decoration: BoxDecoration(
                        color: _highlight
                            ? CostrColors.of(
                                context,
                              ).brand.withValues(alpha: 0.10)
                            : null,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: EventCard(event: displayFocused),
                    ),
                    _RepliesSection(eventId: displayFocused.id),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Retry row shown above a TRUNCATED ancestor chain (the topmost post is
/// itself a reply whose parent didn't resolve). Tapping retry clears the
/// cached lookup misses for the referenced ancestor ids and re-runs the
/// chain walk — recovering the parent once its relay is reachable again.
class _AncestorsRetryRow extends ConsumerWidget {
  const _AncestorsRetryRow({required this.top, required this.focusedId});
  final Event top;
  final String focusedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '上面的对话没加载出来（原帖可能删了，或中继刚才没回应）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: CostrColors.of(context).text3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonal(
            onPressed: () {
              for (final t in top.tags) {
                if (t.length >= 2 && t[0] == 'e' && t[1] is String) {
                  ref.invalidate(eventByIdProvider(t[1] as String));
                }
              }
              ref.invalidate(threadAncestorsProvider(focusedId));
            },
            child: const Text('重试'),
          ),
        ],
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
        // Flatten into a timeline-ordered + hierarchical tree (each reply
        // followed by its own sub-thread) and indent per depth so the reply
        // structure is visible instead of a flat createdAt-desc jumble.
        final threaded = threadReplies(replies, eventId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final tr in threaded)
              Padding(
                padding: EdgeInsets.only(left: tr.depth * 24.0),
                child: EventCard(event: tr.event),
              ),
          ],
        );
      },
    );
  }
}
