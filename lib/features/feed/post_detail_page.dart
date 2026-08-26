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

  /// Flash the focused card's highlight and auto-turn it off. Idempotent while
  /// already highlighted. Shared by the top-level positioning (focused post IS
  /// the root) and the reply-tree path ([_RepliesSection.onFocusedReady]).
  void _flashHighlight() {
    if (!mounted) return;
    if (!_highlight) setState(() => _highlight = true);
    _highlightOff?.cancel();
    _highlightOff = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlight = false);
    });
  }

  /// Scroll the focused card into view (near the top, keeping a little
  /// context above it) and flash a highlight so it's easy to spot. Scheduled
  /// post-frame because the card must be laid out before it can be scrolled
  /// to. Idempotent per chain length. (When the focused post is a REPLY shown
  /// inside the async reply tree, the scroll happens in [_RepliesSection]
  /// instead once the reply is actually laid out.)
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
      _flashHighlight();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Mute filtering of the reply tree happens inside [_RepliesSection] (which
    // watches the mute set itself); the thread root / focused post stay
    // visible since the user navigated here explicitly.
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
            final displayFocused = chain.isNotEmpty ? chain.last : focused;
            // The thread ROOT: the topmost resolved ancestor. When the focused
            // post has no ancestors it IS the root (a top-level post).
            final threadRoot = chain.isNotEmpty ? chain.first : displayFocused;
            final focusedIsRoot = threadRoot.id == displayFocused.id;
            final theme = Theme.of(context);
            // Once the chain has settled (AsyncValue data), position to the
            // focused post. Called during build but only schedules a post-frame
            // callback — no setState during build. Re-runs when the chain
            // length changes (ancestors resolve async).
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
                    if (chain.isNotEmpty && threadRoot.isReply)
                      _AncestorsRetryRow(top: threadRoot, focusedId: widget.id),
                    if (focusedIsRoot) ...[
                      // The focused post IS the thread root (a top-level
                      // post, or a reply whose ancestors haven't resolved
                      // yet): show it as the highlighted focus card with its
                      // replies below — the pre-existing layout.
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
                        child: EventCard(event: threadRoot),
                      ),
                      _RepliesSection(eventId: threadRoot.id),
                    ] else ...[
                      // The focused post is a REPLY deep in a thread. Show
                      // the thread ROOT, then the root's COMPLETE reply tree —
                      // every sibling reply, threaded — highlighting and
                      // scrolling to the focused reply within it. This surfaces
                      // the whole conversation ("从 root 到全部回复"), not just
                      // the focused reply's narrow ancestor/descendant chain.
                      EventCard(event: threadRoot),
                      const SizedBox(height: 4),
                      Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 2),
                        child: Text(
                          '你打开的帖子在下方高亮',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: CostrColors.of(context).text3,
                          ),
                        ),
                      ),
                      _RepliesSection(
                        eventId: threadRoot.id,
                        highlightId: displayFocused.id,
                        highlightKey: _focusedKey,
                        ensureEvent: displayFocused,
                      ),
                    ],
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

/// Replies to [eventId], threaded. Plain [EventCard]s (the former
/// avatar-column connector line was removed).
///
/// When [highlightId] is set (the focused post is a reply shown inside its
/// root's reply tree), the matching reply is kept visible even if its author
/// is muted and wrapped in a highlight [AnimatedContainer] keyed by
/// [highlightKey]. Because the reply tree loads ASYNC (the focused reply may
/// not be laid out when the page first builds), this section scrolls the
/// highlighted reply into view ITSELF once it is rendered and flashes the
/// highlight — the highlight state lives here so flashing it rebuilds only
/// this section, never the parent's SingleChildScrollView (which would reset
/// the just-performed scroll).
/// [ensureEvent] (the focused post) is spliced in if the fetched replies
/// don't contain it yet, so the post the user opened never vanishes while the
/// root's reply tree is still loading.
class _RepliesSection extends ConsumerStatefulWidget {
  const _RepliesSection({
    required this.eventId,
    this.highlightId,
    this.highlightKey,
    this.ensureEvent,
  });
  final String eventId;
  final String? highlightId;
  final GlobalKey? highlightKey;
  final Event? ensureEvent;

  @override
  ConsumerState<_RepliesSection> createState() => _RepliesSectionState();
}

class _RepliesSectionState extends ConsumerState<_RepliesSection> {
  bool _scrolledToHighlight = false;
  // Highlight flash state lives HERE (not in the parent) so flashing it only
  // rebuilds this section — rebuilding the parent would recreate the
  // SingleChildScrollView and reset the scroll we just performed.
  bool _highlight = false;
  Timer? _highlightOff;

  @override
  void dispose() {
    _highlightOff?.cancel();
    super.dispose();
  }

  /// Scroll the highlighted reply into view once it is actually laid out. The
  /// reply tree loads async and can be tall, so the target's RenderObject may
  /// not be attached on the very first post-frame callback — retry a handful
  /// of frames until it is (or it never appears, e.g. filtered away).
  void _maybeScrollToHighlight() {
    if (_scrolledToHighlight) return;
    if (widget.highlightKey == null) return;
    _attemptHighlightScroll(20);
  }

  void _attemptHighlightScroll(int remaining) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scrolledToHighlight) return;
      final ctx = widget.highlightKey?.currentContext;
      if (ctx == null) {
        if (remaining > 0) _attemptHighlightScroll(remaining - 1);
        return;
      }
      _scrolledToHighlight = true;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.25,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      ).then((_) {
        // Flash the highlight only AFTER the scroll animation finishes, and
        // via THIS section's setState so the parent (and its
        // SingleChildScrollView) is not rebuilt and the scroll is kept.
        if (!mounted) return;
        setState(() => _highlight = true);
        _highlightOff?.cancel();
        _highlightOff = Timer(const Duration(milliseconds: 1800), () {
          if (mounted) setState(() => _highlight = false);
        });
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(repliesProvider(widget.eventId));
    // Mute set is read at the top (not inside the data closure) so the watch
    // is registered on every build.
    final mute = ref.watch(myMuteSetProvider);
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (Object e, _) => Text('回复加载失败：$e'),
      data: (List<Event> replies) {
        // Splice in the focused post if the fetched replies don't contain it
        // yet (still loading / cached separately) so it never disappears.
        var all = replies;
        final ensure = widget.ensureEvent;
        if (ensure != null && !replies.any((e) => e.id == ensure.id)) {
          all = <Event>[...replies, ensure];
        }
        // Replies from muted authors are dropped BEFORE threading — their
        // children get reparented to the root by [threadReplies], so a
        // blocked author can't hide a conversation branch, only themself.
        // The highlighted reply (the post the user explicitly opened) is
        // exempt so it never vanishes out from under the navigation.
        final shown = mute.isEmpty
            ? all
            : all
                  .where(
                    (e) => e.id == widget.highlightId || !mute.hidesEvent(e),
                  )
                  .toList();
        if (shown.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: Text('暂无回复')),
          );
        }
        // Flatten into a timeline-ordered + hierarchical tree (each reply
        // followed by its own sub-thread) and indent per depth so the reply
        // structure is visible instead of a flat createdAt-desc jumble.
        final threaded = threadReplies(shown, widget.eventId);
        final hasHighlight =
            widget.highlightId != null &&
            threaded.any((tr) => tr.event.id == widget.highlightId);
        if (hasHighlight) _maybeScrollToHighlight();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final tr in threaded)
              // X-style threading: a SMALL capped indent per level (deep
              // threads no longer compress into a sliver) plus a full-height
              // vertical thread line drawn inside EventCard at the card's
              // left edge. The line is in its own slot, so it never covers
              // the avatar.
              Padding(
                padding: EdgeInsets.only(
                  left: (tr.depth > 4 ? 4 : tr.depth) * 10.0,
                ),
                child: tr.event.id == widget.highlightId
                    ? AnimatedContainer(
                        key: widget.highlightKey,
                        duration: const Duration(milliseconds: 600),
                        decoration: BoxDecoration(
                          color: _highlight
                              ? CostrColors.of(
                                  context,
                                ).brand.withValues(alpha: 0.10)
                              : null,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: EventCard(
                          event: tr.event,
                          threadDepth: tr.depth,
                        ),
                      )
                    : EventCard(event: tr.event, threadDepth: tr.depth),
              ),
          ],
        );
      },
    );
  }
}
