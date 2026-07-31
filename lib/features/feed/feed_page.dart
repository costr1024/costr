/// Feed page — global / following text-note timeline with pull-to-refresh
/// and load-more on scroll.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../nostr/relay_pool.dart';
import '../../widgets/costr_logo.dart';
import 'event_card.dart';

class FeedPage extends ConsumerStatefulWidget {
  const FeedPage({super.key});

  @override
  ConsumerState<FeedPage> createState() => _FeedPageState();
}

/// Apply the read-freeze to a feed list. While frozen ([barrierCreatedAt] +
/// [barrierId] set), keep only events not newer than the barrier (the
/// freeze-time list + any older posts loaded later); newer live events are
/// held back as pending. Pure + testable.
@visibleForTesting
List<Event> frozenVisible(
  List<Event> events,
  int? barrierCreatedAt,
  String? barrierId,
) {
  if (barrierId == null || barrierCreatedAt == null) return events;
  if (!events.any((e) => e.id == barrierId)) return events; // evicted → live
  return events.where((e) {
    final c = e.createdAt.compareTo(barrierCreatedAt);
    if (c != 0) return c < 0; // strictly older → visible
    return e.id.compareTo(barrierId) >= 0; // same time: barrier or tie-older
  }).toList();
}

class _FeedPageState extends ConsumerState<FeedPage> {
  bool _loadingMore = false;
  static const int _loadMoreThreshold = 300; // px from bottom

  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Amethyst-style "don't disrupt reading" freeze. When the user scrolls
  /// away from the top, we freeze the feed at the then-newest post (the
  /// "barrier") and route newer live events into a pending counter shown as a
  /// "N 条新帖" pill instead of prepending them (which would push the post
  /// being read downward). Returning to the top or tapping the pill releases
  /// the pending posts and jumps to the top. `null` = live (no freeze).
  int? _barrierCreatedAt;
  String? _barrierId;

  void _freeze() {
    final ev = ref.read(currentFeedEventsProvider);
    if (ev.isEmpty) return;
    final newest = ev.first;
    setState(() {
      _barrierCreatedAt = newest.createdAt;
      _barrierId = newest.id;
    });
  }

  void _release() {
    setState(() {
      _barrierCreatedAt = null;
      _barrierId = null;
    });
  }

  void _onPillTap() {
    _release();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _refresh() async {
    // Re-issue the feed subscription (closes the old sub, opens a new one).
    _release();
    ref.invalidate(feedSubscriptionProvider);
    // Show the spinner briefly while relays respond.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    final events = ref.read(currentFeedEventsProvider);
    if (events.isEmpty) return;
    final mode = ref.read(feedModeProvider);
    final follows = ref.read(followingStateProvider).value ?? const <String>[];
    if (mode == FeedMode.following && follows.isEmpty) return;
    final oldest = events
        .map((e) => e.createdAt)
        .reduce((a, b) => a < b ? a : b);
    final filter = buildFeedFilter(mode, follows);
    filter['until'] = oldest - 1;
    setState(() => _loadingMore = true);
    final pool = ref.read(relayPoolProvider);
    final subId = nextSubId('more');
    pool.request(subId, filter, closeOnEose: true);
    await Future<void>.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(feedModeProvider);
    final events = ref.watch(currentFeedEventsProvider);
    final following = ref.watch(followingStateProvider);
    final relays = ref.watch(relayStatusProvider);
    final lang = ref.watch(languageFilterProvider);
    final tagFilter = ref.watch(tagFilterProvider);

    final followingLoading = mode == FeedMode.following && following.isLoading;
    final followingEmpty =
        mode == FeedMode.following &&
        following.hasValue &&
        (following.value ?? const []).isEmpty;

    // Apply the freeze: while frozen, only show events not newer than the
    // barrier (the freeze-time list + any older posts loaded via _loadMore);
    // newer live events are held back as pending.
    final visible = frozenVisible(events, _barrierCreatedAt, _barrierId);
    final pending = _barrierId == null ? 0 : events.length - visible.length;

    return Scaffold(
      appBar: AppBar(
        title: const CostrWordmark(logoSize: 26, fontSize: 19),
        actions: [
          _LanguageGlobeButton(value: lang),
          _RelayStatusChip(relays: relays.value ?? const []),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SegmentedButton<FeedMode>(
              segments: const [
                ButtonSegment(value: FeedMode.global, label: Text('全球')),
                ButtonSegment(value: FeedMode.following, label: Text('关注')),
              ],
              selected: {mode},
              onSelectionChanged: (Set<FeedMode> s) {
                if (s.isNotEmpty) {
                  ref.read(feedModeProvider.notifier).set(s.first);
                }
              },
            ),
          ),
          if (tagFilter != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _TagFilterBar(tag: tagFilter),
              ),
            ),
          if (followingLoading || _loadingMore) const LinearProgressIndicator(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: events.isEmpty
                  ? ListView(
                      children: [_EmptyState(followingEmpty: followingEmpty)],
                    )
                  : Stack(
                      children: <Widget>[
                        NotificationListener<ScrollNotification>(
                          onNotification: (ScrollNotification n) {
                            if (n is ScrollUpdateNotification) {
                              final atTop = n.metrics.pixels <= 0;
                              if (!atTop && _barrierId == null) {
                                _freeze();
                              } else if (atTop && _barrierId != null) {
                                _release();
                              }
                            }
                            if (n is ScrollEndNotification &&
                                n.metrics.pixels >=
                                    n.metrics.maxScrollExtent -
                                        _loadMoreThreshold) {
                              _loadMore();
                            }
                            return false;
                          },
                          child: ListView.builder(
                            controller: _controller,
                            // Increase the build window downward so scrolling
                            // back up doesn't flash empty cards while the
                            // builder catches up.
                            addAutomaticKeepAlives: false,
                            itemCount: visible.length,
                            itemBuilder: (BuildContext context, int i) =>
                                EventCard(event: visible[i]),
                          ),
                        ),
                        if (pending > 0)
                          Positioned(
                            top: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: _NewPostsPill(
                                count: pending,
                                onTap: _onPillTap,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Floating "N 条新帖" pill shown at the top of the feed while new live
/// events are held back during a read freeze. Tap releases them and jumps to
/// the top.
class _NewPostsPill extends StatelessWidget {
  const _NewPostsPill({required this.count, required this.onTap});
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: CostrColors.brand,
            borderRadius: BorderRadius.circular(999),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x44000000),
                blurRadius: 6,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(Icons.arrow_upward, size: 14, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                '$count 条新帖',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.followingEmpty});
  final bool followingEmpty;

  @override
  Widget build(BuildContext context) {
    final text = followingEmpty
        ? '你还没有关注任何人。\n关注其他用户后这里会显示他们的帖子。'
        : '暂无帖子。\n下拉刷新或等待中继数据。';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 80, horizontal: 24),
      child: Center(child: Text(text, textAlign: TextAlign.center)),
    );
  }
}

class _LanguageGlobeButton extends ConsumerWidget {
  const _LanguageGlobeButton({required this.value});
  final LanguageFilter value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The button itself shows the current selection's flag so the active
    // language is visible at a glance (not just a generic globe).
    final rec = _entries.firstWhere(
      (e) => e.$2 == value,
      orElse: () => ('全部', LanguageFilter.all, '🌐'),
    );
    return PopupMenuButton<String>(
      icon: Text(rec.$3, style: const TextStyle(fontSize: 18)),
      tooltip: '语言：${rec.$1}',
      onSelected: (String v) {
        final f = LanguageFilter.values.firstWhere((e) => e.name == v);
        ref.read(languageFilterProvider.notifier).set(f);
      },
      itemBuilder: (_) => _entries
          .map(
            (e) => PopupMenuItem<String>(
              value: e.$2.name,
              child: Row(
                children: [
                  Text(e.$3, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Text(e.$1),
                  if (e.$2 == value) ...[
                    const Spacer(),
                    const Icon(Icons.check, size: 16, color: CostrColors.brand),
                  ],
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  static const List<(String, LanguageFilter, String)> _entries = [
    ('全部', LanguageFilter.all, '🌐'),
    ('中文', LanguageFilter.zh, '🇨🇳'),
    ('英文', LanguageFilter.en, '🇬🇧'),
    ('日文', LanguageFilter.ja, '🇯🇵'),
  ];
}

/// The active tag-filter bar: `#tag` + a star to follow/unfollow the tag
/// (NIP-51 kind-30015) + a clear (✕) button. Shown at the top of the home
/// feed when a tag filter is active — the most discoverable entry point for
/// "follow this tag".
class _TagFilterBar extends ConsumerWidget {
  const _TagFilterBar({required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final followed = (ref.watch(followedTagsProvider).value ?? const <String>[])
        .contains(tag);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('#$tag', style: theme.textTheme.labelLarge),
          IconButton(
            tooltip: followed ? '已关注，点击取消' : '关注此标签',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(
              followed ? Icons.star_rounded : Icons.star_border_rounded,
              color: followed ? theme.colorScheme.primary : null,
            ),
            onPressed: () {
              if (followed) {
                ref.read(followedTagsProvider.notifier).remove(tag);
              } else {
                ref.read(followedTagsProvider.notifier).add(tag);
              }
            },
          ),
          IconButton(
            tooltip: '清除',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(tagFilterProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

class _RelayStatusChip extends StatelessWidget {
  const _RelayStatusChip({required this.relays});
  final List<RelayState> relays;

  @override
  Widget build(BuildContext context) {
    if (relays.isEmpty) return const SizedBox.shrink();
    final connectedCount = relays
        .where((r) => r.status == RelayStatus.connected)
        .length;
    final allConnected = connectedCount == relays.length;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      // Tappable → 服务器节点 page (relay + Blossom RTT).
      child: ActionChip(
        visualDensity: VisualDensity.compact,
        onPressed: () => context.push('/settings/relays'),
        avatar: Icon(
          allConnected ? Icons.cloud_done : Icons.cloud_off,
          size: 18,
          color: allConnected ? Colors.green : Colors.amber,
        ),
        label: Text('$connectedCount/${relays.length}'),
      ),
    );
  }
}
