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
