/// Feed page — global / following text-note timeline with pull-to-refresh
/// and load-more on scroll.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../app/theme.dart';
import '../../models/event.dart';
import '../../nostr/outbox_router.dart';
import '../../nostr/relay_client.dart';
import '../../nostr/relay_pool.dart';
import '../../widgets/costr_logo.dart';
import '../../widgets/double_tap_shortcut.dart';
import '../../widgets/immersive.dart';
import 'event_card.dart';

class FeedPage extends ConsumerStatefulWidget {
  const FeedPage({super.key});

  @override
  ConsumerState<FeedPage> createState() => _FeedPageState();
}

/// Apply the read-freeze to a feed list. While frozen (a [snapshot] of the
/// freeze-time visible ids + [barrierCreatedAt] + [barrierId] set), keep only
/// events that were visible at freeze time ([snapshot]) OR strictly older
/// posts loaded later via `_loadMore` (createdAt < barrier). Anything that
/// arrived after the freeze — including same-`created_at`-second events the
/// sort tie-break can't reliably classify as newer — is held back as pending.
/// Pure + testable.
@visibleForTesting
List<Event> frozenVisible(
  List<Event> events,
  int? barrierCreatedAt,
  String? barrierId,
  Set<String>? snapshot,
) {
  if (barrierId == null || barrierCreatedAt == null) return events;
  if (!events.any((e) => e.id == barrierId)) return events; // evicted → live
  final snap = snapshot;
  return events.where((e) {
    if (e.id == barrierId) return true; // the post being read is always visible
    if (snap != null && snap.contains(e.id)) return true; // freeze-time visible
    return e.createdAt < barrierCreatedAt; // older posts from _loadMore
  }).toList();
}

/// True when ANY post in a backward [page] belongs under the [want] language
/// filter — the stop condition of the global feed's auto backward-paging
/// ("keep digging until the filtered language shows up"). Repost language
/// resolves against [held] (the window's current posts) PLUS the page
/// itself, since a repost's target may sit elsewhere in the same page.
/// Same [Event.matchesLanguage] predicate the feed renders with, so "the
/// page extended the filtered feed" is decided exactly the way the feed
/// does.
@visibleForTesting
bool pageHasLanguage(List<Event> page, String want, Iterable<Event> held) {
  final byId = <String, Event>{
    for (final e in held) e.id: e,
    for (final e in page) e.id: e,
  };
  for (final e in page) {
    if (e.matchesLanguage(want, (id) => byId[id])) return true;
  }
  return false;
}

class _FeedPageState extends ConsumerState<FeedPage> {
  bool _loadingMore = false;
  static const int _loadMoreThreshold = 300; // px from bottom

  /// Language-filter auto backward-paging bounds (全球 + 语言过滤): matching
  /// posts are a tiny fraction of the firehose, so one backward page almost
  /// never contains any — the loop keeps paging until one does, bounded by
  /// BOTH a page count and a wall clock so the spinner always stops (the
  /// never-stopping black progress bar was the unbounded re-trigger loop,
  /// which the cooldown below still guards against).
  static const int _kLangBackfillMaxPages = 10;
  static const Duration _kLangBackfillBudget = Duration(seconds: 20);

  /// Global backward-paging depth cursor: pages with `created_at <` this
  /// value were already fetched by a previous load-more. With a language
  /// filter the VISIBLE oldest post moves back rarely (matching posts are
  /// sparse), so restarting every gesture from `filteredOldest - 1` would
  /// re-fetch the same giant non-matching band over and over; the cursor
  /// continues from the deepest point reached instead. Validated against the
  /// window's generation in [_loadMore]: ANY window wipe (refresh, mode
  /// switch, account switch, tag filter on/off, follows change) bumps it,
  /// and a cursor into wiped history would skip the band between the fresh
  /// firehose and the old depth.
  int? _globalDeepUntil;
  int _cursorGeneration = 0;

  /// Last time a load-more finished WITHOUT extending the feed (relays
  /// returned nothing older / were unreachable). Load-more skips itself
  /// while inside [_kEmptyLoadMoreCooldown] so a dead end doesn't keep
  /// re-firing on every scroll tick at the bottom (that loop was the
  /// never-stopping black progress bar + perpetual tail spinner).
  DateTime? _emptyLoadMoreAt;
  static const Duration _kEmptyLoadMoreCooldown = Duration(seconds: 30);

  /// The language filter active when the cooldown was set. Switching the
  /// filter invalidates the cooldown: a depth that had no 中文 may still hold
  /// 日文, so the new filter gets to dig immediately.
  LanguageFilter? _cooldownLang;

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

  /// Ids of the events visible at the moment the freeze was set. While frozen,
  /// only these (plus strictly older posts from `_loadMore`) stay visible;
  /// everything that arrives after the freeze is held back as pending — even
  /// same-`created_at`-second arrivals the sort tie-break can't classify.
  Set<String>? _frozenSnapshot;

  void _freeze() {
    final ev = ref.read(currentFeedEventsProvider);
    if (ev.isEmpty) return;
    final newest = ev.first;
    setState(() {
      _barrierCreatedAt = newest.createdAt;
      _barrierId = newest.id;
      _frozenSnapshot = ev.map((e) => e.id).toSet();
    });
  }

  void _release() {
    setState(() {
      _barrierCreatedAt = null;
      _barrierId = null;
      _frozenSnapshot = null;
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

  /// Double-tap on the 全球/关注 tab row: jump straight back to the newest
  /// post (user: "下滑刷了 200 条帖子，没办法一键回到最新的帖子位置").
  /// The read-freeze releases itself on arrival — the scroll listener's
  /// "atTop → _release()" fires as the animation lands at the top, so the
  /// held-back "N 条新帖" unroll at the same time. Chrome restores too
  /// (the immersive detector shows on any upward scroll).
  void _scrollToTop() {
    if (!_controller.hasClients) return;
    final px = _controller.offset;
    if (px <= 0) return;
    // Duration scales with distance (long jumps shouldn't take forever,
    // short ones shouldn't snap).
    final ms = (px / 60).clamp(250, 700).toInt();
    _controller.animateTo(
      0,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _refresh() async {
    // Re-issue the feed fetch (closes the old sub/router, opens a new one).
    // Following mode → outbox router rebuilds with a `since`增量 cursor;
    // global mode → default-relay broadcast re-issues. The rebuild's dispose
    // clears the global window (bumping its generation, which is what
    // invalidates the paging depth cursor on its next use).
    _release();
    _emptyLoadMoreAt = null; // a refresh may revive dead relays
    final mode = ref.read(feedModeProvider);
    if (mode == FeedMode.following) {
      ref.invalidate(followingOutboxProvider);
    } else {
      ref.invalidate(feedSubscriptionProvider);
    }
    // Tag timeline (a tapped hashtag in any mode, or the following dropdown's
    // `tag:`) → re-issue the hashtag's `#t` REQ.
    ref.invalidate(tagTimelineFeedProvider);
    // Show the spinner briefly while relays respond.
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }

  Future<void> _loadMore() async {
    if (_loadingMore) return;
    // Empty-result cooldown: a load-more that failed to extend the feed
    // (relays dead, nothing older, …) used to re-trigger on EVERY scroll
    // tick at the bottom — each attempt opens ~30 transient relay
    // connections and takes up to ~20s, so the top progress bar + tail
    // spinner looked permanent ("黑色的进度条一直在动…永远不会停止").
    // Back off for a while instead of hammering. The cooldown is tied to the
    // language filter it was earned under — switching the filter lifts it.
    final lang = ref.read(languageFilterProvider);
    final now = DateTime.now();
    final cooldown = _emptyLoadMoreAt == null
        ? Duration.zero
        : now.difference(_emptyLoadMoreAt!);
    if (cooldown < _kEmptyLoadMoreCooldown && lang == _cooldownLang) return;
    final events = ref.read(currentFeedEventsProvider);
    if (events.isEmpty) return;
    final mode = ref.read(feedModeProvider);
    final follows = ref.read(followingStateProvider).value ?? const <String>[];
    // Hashtag filter active → the feed is the tag's `#t` timeline (any
    // author), so pagination pages THAT backward — not the followees' outbox
    // nor the plain firehose. Two triggers: a tapped hashtag (any mode) wins,
    // else the following dropdown's `tag:`. follows may even be empty here;
    // only guard the follows-empty case when no tag is active.
    final ff = ref.read(followingFilterProvider);
    final tappedTag = ref.read(tagFilterProvider);
    String? activeTag;
    if (tappedTag != null && tappedTag.isNotEmpty) {
      activeTag = tappedTag.toLowerCase();
    } else if (mode == FeedMode.following &&
        ff != null &&
        ff.startsWith('tag:')) {
      activeTag = ff.substring(4).toLowerCase();
    }
    if (mode == FeedMode.following && follows.isEmpty && activeTag == null) {
      return;
    }
    final oldest = events
        .map((e) => e.createdAt)
        .reduce((a, b) => a < b ? a : b);
    var until = oldest - 1;
    // Global mode: the depth cursor skips bands a previous gesture already
    // paged through (with a language filter the visible oldest barely moves
    // while the actual fetch went much deeper for matching posts). Not used
    // for a hashtag timeline — that pages the TAG's own history, and the
    // cursor belongs to the firehose. Generation check drops a cursor whose
    // window was wiped since it was set.
    if (mode == FeedMode.global && activeTag == null) {
      final windowNotifier = ref.read(globalFeedWindowProvider.notifier);
      if (windowNotifier.generation != _cursorGeneration) {
        _globalDeepUntil = null;
        _cursorGeneration = windowNotifier.generation;
      }
      if (_globalDeepUntil != null && _globalDeepUntil! < until) {
        until = _globalDeepUntil!;
      }
    }
    setState(() => _loadingMore = true);
    try {
      if (activeTag != null) {
        await _loadMoreTag(activeTag, until);
      } else if (mode == FeedMode.following) {
        await _loadMoreFollowing(follows, until);
      } else {
        await _loadMoreGlobal(until);
      }
      // Did the page actually extend the feed? If the oldest visible post
      // didn't move back, record an empty attempt so the trigger backs off
      // (instead of spinning on every further scroll tick at the bottom).
      // Flush the debounced store/window first so `after` reflects what just
      // landed (following load-more → store; global load-more → window).
      ref.read(eventStoreProvider.notifier).flushNow();
      ref.read(globalFeedWindowProvider.notifier).flushNow();
      final after = ref.read(currentFeedEventsProvider);
      final oldestAfter = after.isEmpty
          ? null
          : after.map((e) => e.createdAt).reduce((a, b) => a < b ? a : b);
      if (oldestAfter == null || oldestAfter >= oldest) {
        _emptyLoadMoreAt = DateTime.now();
        _cooldownLang = lang;
      } else {
        _emptyLoadMoreAt = null;
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Global load-more: backward page broadcast to the main pool. With NO
  /// language filter this is a single page (`until` from the visible oldest
  /// post), exactly as before. With a language filter it AUTO-PAGES: one
  /// backward page is almost entirely non-matching posts (the filtered
  /// language is a tiny fraction of the firehose), so while a page brings no
  /// matching post the paging keeps going DEEPER — previously it stopped at
  /// the first non-extending page, the empty-page cooldown kicked in, and the
  /// filtered feed sat at "十几条" forever ("下刷一直返回空不更新"). Bounded by
  /// [_kLangBackfillMaxPages] + [_kLangBackfillBudget] per gesture; the depth
  /// cursor lets the next gesture continue where this one stopped, and the
  /// window's language-aware retention keeps the dug-up matching posts from
  /// being churned back out by the live firehose.
  Future<void> _loadMoreGlobal(int until) async {
    final want = languageFilterCode(ref.read(languageFilterProvider));
    var cursor = until;
    var pages = 0;
    final deadline = DateTime.now().add(_kLangBackfillBudget);
    while (true) {
      final page = await _fetchGlobalPage(cursor);
      pages++;
      if (!mounted) break; // user left the page mid-loop — stop paging
      if (page.isEmpty) break; // relays returned nothing older — dead end
      var pageOldest = page.first.createdAt;
      for (final e in page) {
        if (e.createdAt < pageOldest) pageOldest = e.createdAt;
      }
      // The cursor advances on EVERY page (matching or not): it marks the
      // band already fetched, so the next gesture skips straight past it.
      _globalDeepUntil = pageOldest - 1;
      if (want == null) break; // unfiltered: one page, historic behavior
      if (pageHasLanguage(
        page,
        want,
        ref.read(globalFeedWindowProvider.notifier).window.posts,
      )) {
        break; // feed extended with matching posts
      }
      if (pages >= _kLangBackfillMaxPages ||
          !deadline.isAfter(DateTime.now())) {
        break; // bounded: the next gesture digs further from the cursor
      }
      cursor = pageOldest - 1;
    }
  }

  /// One global backward page (`until` cursor, kinds 1/6 only — backward
  /// pages exist to deepen the POST timeline; kind-7 reactions vastly
  /// outnumber posts and would eat the `limit`, stalling the cursor).
  /// Resolves on the first relay EOSE so a slow relay doesn't stall the
  /// snapshot (the pool's closeOnEose waits ALL; we resolve locally first).
  /// Routed into the ephemeral window, same as the live firehose sub.
  /// Returns the events the relays delivered (may contain cross-relay
  /// duplicates — harmless for the cursor/match decisions).
  Future<List<Event>> _fetchGlobalPage(int until) async {
    final pool = ref.read(relayPoolProvider);
    final follows = ref.read(followingStateProvider).value ?? const <String>[];
    final filter = buildFeedFilter(FeedMode.global, follows);
    filter['kinds'] = [1, 6];
    filter['until'] = until;
    final window = ref.read(globalFeedWindowProvider.notifier);
    final got = <Event>[];
    final subId = nextSubId('more');
    final done = Completer<void>();
    final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
      if (!done.isCompleted) done.complete();
    });
    pool.request(
      subId,
      filter,
      closeOnEose: true,
      onEvent: (e) {
        got.add(e);
        window.ingest(e);
      },
    );
    final t = Timer(const Duration(seconds: 5), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    t.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
    return got;
  }

  /// Following load-more: backward page via NIP-65 outbox routing. Builds the
  /// same relay→authors map the live subscription uses, then opens TRANSIENT
  /// outbox clients (close on EOSE) with `until` to back-fill older posts
  /// directly from each followee's outbox relays. Default-bucket followees
  /// (no usable outbox) fall back to a broadcast `until` page on the main
  /// pool. Events stream into the store via [ingest] as they arrive.
  Future<void> _loadMoreFollowing(List<String> follows, int until) async {
    final store = ref.read(eventStoreProvider.notifier);
    final map = await buildOutboxMap(
      (pk) => ref.read(userRelayListProvider(pk).future),
      follows,
    );
    final router = OutboxRouter(
      makeClient: RelayClient.new,
      identityGetter: () => ref.read(identityProvider).value,
    );
    // Outbox tier: one-shot fetch with `until`. kinds [1,6] only — backward
    // pages deepen the POST timeline; kind-0/7 would eat most of each relay's
    // `limit` (reactions vastly outnumber posts), stalling the `until` cursor
    // a few hours deep. onEvent ingests as they arrive (debounced by
    // EventStoreNotifier's _scheduleFlush), so the UI fills in live instead
    // of waiting for the whole batch.
    await router.fetchOnce(
      map.relayToAuthors,
      until: until,
      kinds: const [1, 6],
      onEvent: (e) => store.ingest(e),
    );
    await router.close();
    // Default bucket: broadcast `until` page to the main pool, resolve on
    // first EOSE (same pattern as _loadMoreGlobal).
    if (map.defaultBucket.isNotEmpty) {
      final pool = ref.read(relayPoolProvider);
      final filter = <String, dynamic>{
        'kinds': [1, 6],
        'authors': List<String>.from(map.defaultBucket),
        'limit': 200,
        'until': until,
      };
      final subId = nextSubId('more-follows');
      final done = Completer<void>();
      final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
        if (!done.isCompleted) done.complete();
      });
      pool.request(subId, filter, closeOnEose: true);
      final t = Timer(const Duration(seconds: 5), () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      t.cancel();
      await eoseSub.cancel();
      pool.closeSubscription(subId);
    }
  }

  /// Hashtag-feed load-more: backward `#t` page (until = oldest-1) broadcast
  /// to the main pool. The destination follows the mode's feed source: GLOBAL
  /// → ROUTED into the ephemeral window (the global feed reads the window, and
  /// routed pages keep the firehose's "never the capped store" invariant);
  /// FOLLOWING → UNROUTED, so the page flows through the pool's merged stream
  /// into the EventStore (the following tag feed's source).
  ///
  /// The UI unlocks on the FIRST relay EOSE (5s cap — a slow relay must not
  /// stall the spinner), but the REQ itself stays open for stragglers until
  /// ALL connected relays EOSE (the pool's closeOnEose semantic), hard-capped
  /// 8s later — closing on the first EOSE cut the slow relays' page off, and
  /// the NEXT page's `until` anchor (newest oldest-1) already sits below the
  /// gap, so the missed posts would never be re-requested (a permanent hole
  /// in the tag timeline). Stragglers keep streaming in after the UI unlocked;
  /// the sorted source shows them at their right position.
  Future<void> _loadMoreTag(String tag, int until) async {
    final pool = ref.read(relayPoolProvider);
    final filter = <String, dynamic>{
      '#t': hashtagAlts(tag),
      'kinds': [1, 6],
      'limit': 200,
      'until': until,
    };
    final subId = nextSubId('more-tag');
    final done = Completer<void>();
    final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
      if (!done.isCompleted) done.complete();
    });
    if (ref.read(feedModeProvider) == FeedMode.global) {
      final window = ref.read(globalFeedWindowProvider.notifier);
      pool.request(subId, filter, closeOnEose: true, onEvent: window.ingest);
    } else {
      pool.request(subId, filter, closeOnEose: true);
    }
    final t = Timer(const Duration(seconds: 5), () {
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    t.cancel();
    await eoseSub.cancel();
    // The REQ stays OPEN for stragglers after the UI unlocked: the pool's
    // closeOnEose closes it once ALL connected relays EOSE. A hard cap
    // guarantees cleanup if some relay never EOSEs (a double close after the
    // pool already closed it is harmless).
    Timer(const Duration(seconds: 8), () => pool.closeSubscription(subId));
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
    final visible = frozenVisible(
      events,
      _barrierCreatedAt,
      _barrierId,
      _frozenSnapshot,
    );
    final pending = _barrierId == null ? 0 : events.length - visible.length;

    return ImmersiveScaffold(
      topBar: AppBar(
        title: const CostrWordmark(logoSize: 26, fontSize: 19),
        actions: [
          if (mode == FeedMode.following) const _FollowingFilterButton(),
          _LanguageGlobeButton(value: lang),
          _RelayStatusChip(relays: relays.value ?? const []),
        ],
      ),
      // The 全球/关注 toggle is part of the top chrome: collapsing it WITH
      // the AppBar on scroll-down gives the true fullscreen reading mode
      // (user: "全球和关注 tab 不会隐藏"). Fixed 64 height keeps the
      // ImmersiveScaffold collapse math exact. Double-tapping the row jumps
      // back to the newest post (Amethyst "tap the tab to scroll to top").
      belowBarHeight: 64,
      belowBar: DoubleTapShortcut(
        onDoubleTap: _scrollToTop,
        child: SizedBox(
          height: 64,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              child: SegmentedButton<FeedMode>(
                segments: const [
                  ButtonSegment(value: FeedMode.global, label: Text('全球')),
                  ButtonSegment(value: FeedMode.following, label: Text('关注')),
                ],
                selected: {mode},
                onSelectionChanged: (Set<FeedMode> s) {
                  if (s.isNotEmpty) {
                    // Release any read-freeze before switching modes so the new
                    // mode's list isn't pinned behind the old mode's barrier
                    // (the barrier post id likely isn't in the new mode's events
                    // anyway, but clearing avoids a one-frame freeze artifact).
                    _release();
                    _emptyLoadMoreAt = null; // new mode = new pagination state
                    ref.read(feedModeProvider.notifier).set(s.first);
                  }
                },
              ),
            ),
          ),
        ),
      ),
      body: Column(
        children: [
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
            child: ImmersiveScrollDetector(
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
                              // Only the feed list itself drives the freeze /
                              // load-more logic. Nested scrollables inside
                              // cards (a post's horizontal author-status
                              // line) also bubble notifications up here;
                              // their HORIZONTAL metrics used to misfire the
                              // freeze (`pixels <= 0` read as "at top" →
                              // `_release()`, `pixels > 0` → `_freeze()`) and
                              // could even trigger `_loadMore()` when the
                              // horizontal offset neared its own max extent.
                              final axis = n.metrics.axisDirection;
                              if (axis != AxisDirection.down &&
                                  axis != AxisDirection.up) {
                                return false;
                              }
                              if (n is ScrollUpdateNotification) {
                                final atTop = n.metrics.pixels <= 0;
                                if (!atTop && _barrierId == null) {
                                  _freeze();
                                } else if (atTop && _barrierId != null) {
                                  _release();
                                }
                                // Trigger load-more on scroll-update near the
                                // bottom too (not only on scroll-end) — a fling
                                // that overshoots the end may not fire a clean
                                // ScrollEnd within the threshold, leaving the
                                // user stuck at the bottom with "no older posts".
                                if (n.metrics.pixels >=
                                    n.metrics.maxScrollExtent -
                                        _loadMoreThreshold) {
                                  _loadMore();
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
                              // Per-mode scroll position: switching 全球↔关注
                              // restores each mode's own saved offset instead of
                              // carrying the other's (so 关注 stays at the top
                              // after you scrolled 全球 back 2h). PageStorage keeps
                              // the offset per key across rebuilds.
                              key: PageStorageKey<FeedMode>(mode),
                              // +1 item: a trailing load-more indicator so the
                              // user gets feedback (and a slightly taller build
                              // window to nudge the scroll metrics).
                              addAutomaticKeepAlives: false,
                              itemCount: visible.length + 1,
                              itemBuilder: (BuildContext context, int i) {
                                if (i < visible.length) {
                                  return EventCard(event: visible[i]);
                                }
                                // Trailing indicator: spinner while loading
                                // more, else a quiet hint. The mere presence of
                                // this row also keeps the list scrollable past
                                // the last real post so the scroll-update trigger
                                // above can fire even when the feed barely fills
                                // the screen.
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 24,
                                  ),
                                  child: Center(
                                    child: _loadingMore
                                        ? SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              color: CostrColors.of(
                                                context,
                                              ).text3,
                                            ),
                                          )
                                        : const SizedBox(height: 22),
                                  ),
                                );
                              },
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
            color: CostrColors.of(context).brand,
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
              Icon(
                Icons.arrow_upward,
                size: 14,
                color: CostrColors.of(context).onBrand,
              ),
              const SizedBox(width: 5),
              Text(
                '$count 条新帖',
                style: TextStyle(
                  color: CostrColors.of(context).onBrand,
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

/// Following-feed filter dropdown (DESIGN §8): 全部关注 / a custom follow
/// group / a followed hashtag. Only shown in 关注 mode. Selection persists
/// across relaunch ([FollowingFilterNotifier]). Client-side filter — see
/// [currentFeedEventsProvider].
class _FollowingFilterButton extends ConsumerWidget {
  const _FollowingFilterButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(identityProvider).value;
    final me = identity?.pubkeyHex;
    final groups = me == null
        ? const <FollowGroup>[]
        : (ref.watch(userGroupedFollowsProvider(me)).value ??
              const <FollowGroup>[]);
    final tags = me == null
        ? const <String>[]
        : (ref.watch(followedTagsProvider).value ?? const <String>[]);
    final ff = ref.watch(followingFilterProvider);

    String label;
    if (ff == null) {
      label = '全部关注';
    } else if (ff.startsWith('group:')) {
      label = ff.substring(6);
    } else if (ff.startsWith('tag:')) {
      label = '#${ff.substring(4)}';
    } else {
      label = '全部关注';
    }

    return PopupMenuButton<String>(
      tooltip: '过滤关注信息流',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.filter_list, size: 18),
            const SizedBox(width: 4),
            Text(label, style: Theme.of(context).textTheme.labelMedium),
          ],
        ),
      ),
      onSelected: (String v) =>
          ref.read(followingFilterProvider.notifier).set(v.isEmpty ? null : v),
      itemBuilder: (BuildContext ctx) => <PopupMenuEntry<String>>[
        PopupMenuItem(
          value: '',
          child: Row(
            children: [
              Icon(
                ff == null ? Icons.check : Icons.check_box_outline_blank,
                size: 18,
              ),
              const SizedBox(width: 8),
              const Text('全部关注'),
            ],
          ),
        ),
        if (groups.length > 1) const PopupMenuDivider(),
        for (final g in groups)
          if (g.name != '默认分组')
            PopupMenuItem(
              value: 'group:${g.name}',
              child: Row(
                children: [
                  Icon(
                    ff == 'group:${g.name}' ? Icons.check : Icons.label_outline,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(g.name)),
                  Text(
                    '${g.pubkeys.length}',
                    style: Theme.of(ctx).textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        if (tags.isNotEmpty) const PopupMenuDivider(),
        for (final t in tags)
          PopupMenuItem(
            value: 'tag:$t',
            child: Row(
              children: [
                Icon(ff == 'tag:$t' ? Icons.check : Icons.tag, size: 18),
                const SizedBox(width: 8),
                Text('#$t'),
              ],
            ),
          ),
      ],
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
                    Icon(
                      Icons.check,
                      size: 16,
                      color: CostrColors.of(context).brand,
                    ),
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
