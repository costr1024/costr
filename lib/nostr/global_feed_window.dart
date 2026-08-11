/// Ephemeral firehose window for the 全球 (global) feed — the "偶尔打开看一
/// 眼" tier. Memory-only, never persisted (no SQLite, no shared EventStore),
/// cleared when the global tab is left.
///
/// Why this exists separately from [EventStore]: the 20000-event capped store
/// is reserved for the FOLLOWING feed + related events (own posts, opened
/// threads, targeted fetches, social-graph metadata). The global firehose
/// (~40 ev/s) used to stream into that same store and saturate the cap in
/// ~8 minutes, after which every incoming event evicted the oldest kind-7 —
/// reactions on the following feed died ~25ms after arrival. Routing the
/// firehose here instead keeps the store following-only.
///
/// Contents (all bounded):
/// - posts: kind-1/6, newest-first by createdAt, capped at [maxPosts];
/// - interactions: kind-6/7 targeting a currently-held post, capped at
///   [maxInteractions] (oldest-arrival churn once full);
/// - metadata: per-author newest kind-0, capped at [maxMetadata].
///
/// Dedup is two-layer: [_seenIds] rejects cross-relay duplicates (bounded
/// like the pool's dedup set), and per-tier id guards make late re-delivery
/// after a seen-trim idempotent.
library;

import 'dart:collection';

import '../models/event.dart';

class GlobalFeedWindow {
  GlobalFeedWindow({
    this.maxPosts = 1000,
    this.maxInteractions = 5000,
    this.maxMetadata = 5000,
    this.maxSeen = 20000,
  });

  final int maxPosts;
  final int maxInteractions;
  final int maxMetadata;
  final int maxSeen;

  /// Posts (kind 1/6), newest-first by createdAt.
  final List<Event> _posts = [];
  final Map<String, Event> _postById = {};

  /// Interactions (kind 6/7) targeting a post held at INGEST time, keyed by
  /// event id in arrival order (LinkedHashMap so over-cap churn drops the
  /// oldest arrival in O(1)).
  final LinkedHashMap<String, Event> _interactions = LinkedHashMap();

  /// Per-author newest kind-0 (replaceable semantics by createdAt).
  final Map<String, Event> _metadata = {};

  /// Cross-relay dedup, bounded (a trimmed id re-ingests idempotently).
  final LinkedHashSet<String> _seenIds = LinkedHashSet();

  int _contentRevision = 0;
  int _interactionRevision = 0;
  int _metadataRevision = 0;

  int get contentRevision => _contentRevision;
  int get interactionRevision => _interactionRevision;
  int get metadataRevision => _metadataRevision;

  /// Posts newest-first — the global feed list source.
  List<Event> get posts => List.unmodifiable(_posts);

  /// Interaction events (kind 6/7) — merged into the interaction index.
  Iterable<Event> get interactions => _interactions.values;

  Event? postById(String id) => _postById[id];

  /// Kind-0 for [pubkey] if the firehose delivered it while the window was
  /// open (stranger metadata is never persisted — user decision).
  Event? metadataFor(String pubkey) => _metadata[pubkey];

  bool get isEmpty =>
      _posts.isEmpty && _interactions.isEmpty && _metadata.isEmpty;

  /// Every held event for scan-style consumers (feed repost-target index,
  /// interaction-index merge). Kind-6 reposts live in BOTH [_posts] and
  /// [_interactions]; they are yielded once.
  Iterable<Event> get events sync* {
    yield* _posts;
    for (final i in _interactions.values) {
      if (!_postById.containsKey(i.id)) yield i;
    }
  }

  /// Ingest one firehose event. Returns true if any tier changed (the
  /// notifier re-emits its throttled state snapshot on true).
  bool ingest(Event e) {
    if (!_seenIds.add(e.id)) return false;
    while (_seenIds.length > maxSeen) {
      _seenIds.remove(_seenIds.first);
    }
    switch (e.kind) {
      case 0:
        return _ingestMetadata(e);
      case 1:
        return _ingestPost(e);
      case 6:
        // A repost is BOTH a feed card (kind-6 in the timeline) and an
        // interaction on its target (repost count).
        final asPost = _ingestPost(e);
        final asInteraction = _ingestInteraction(e);
        return asPost || asInteraction;
      case 7:
        return _ingestInteraction(e);
      default:
        return false;
    }
  }

  bool _ingestPost(Event e) {
    if (_postById.containsKey(e.id)) return false; // seen-trim re-delivery
    // Binary-search insert keeping _posts sorted by createdAt DESC (ties:
    // later arrival after earlier — stable across relay duplicates).
    var lo = 0;
    var hi = _posts.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_posts[mid].createdAt >= e.createdAt) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _posts.insert(lo, e);
    _postById[e.id] = e;
    _contentRevision++;
    if (_posts.length > maxPosts) {
      final dropped = _posts.removeLast();
      _postById.remove(dropped.id);
    }
    return true;
  }

  bool _ingestInteraction(Event e) {
    if (_interactions.containsKey(e.id)) return false; // seen-trim re-delivery
    // Only keep interactions targeting a post CURRENTLY in the window — the
    // firehose's kind-7 vastly outnumbers our 1000 held posts and the rest
    // has nothing to display against.
    var targetsHeld = false;
    for (final t in e.tags) {
      if (t.length >= 2 &&
          t[0] == 'e' &&
          t[1] is String &&
          t[1] != e.id &&
          _postById.containsKey(t[1] as String)) {
        targetsHeld = true;
        break;
      }
    }
    if (!targetsHeld) return false;
    _interactions[e.id] = e;
    _interactionRevision++;
    if (_interactions.length > maxInteractions) {
      _interactions.remove(_interactions.keys.first);
    }
    return true;
  }

  bool _ingestMetadata(Event e) {
    final prev = _metadata[e.pubkey];
    if (prev != null && prev.createdAt >= e.createdAt) return false;
    _metadata[e.pubkey] = e;
    _metadataRevision++;
    if (_metadata.length > maxMetadata) {
      // Drop the oldest-created profile (rare — one scan per overflow).
      String? oldestKey;
      var oldestAt = 1 << 62;
      _metadata.forEach((k, v) {
        if (v.createdAt < oldestAt) {
          oldestAt = v.createdAt;
          oldestKey = k;
        }
      });
      if (oldestKey != null) _metadata.remove(oldestKey);
    }
    return true;
  }

  /// Drop everything (leaving the global tab / account switch). Bumps every
  /// revision so dependents rebuild to the empty state.
  void clear() {
    if (isEmpty && _seenIds.isEmpty) return;
    _posts.clear();
    _postById.clear();
    _interactions.clear();
    _metadata.clear();
    _seenIds.clear();
    _contentRevision++;
    _interactionRevision++;
    _metadataRevision++;
  }
}
