/// In-memory event store: dedup by id, sorted newest-first, capped.
///
/// Plain class (no riverpod) so it can be unit-tested directly. The notifier
/// wrapper lives in `lib/app/providers.dart`.
library;

import '../models/event.dart';

class EventStore {
  EventStore({this.maxEvents = 20000});

  /// Memory cap. Raised from the original 5000: with indiscriminate eviction
  /// a saturated store made backward pagination IMPOSSIBLE — every older post
  /// fetched by load-more was evicted the moment it was added (it was the
  /// oldest thing in the store), so the feed froze a few hundred posts deep
  /// and the load-more spinner ran forever ("无法加载更老的帖子…一直转圈").
  /// 20000 leaves headroom for deep backward paging in a session.
  final int maxEvents;

  final Map<String, Event> _byId = {};
  final List<Event> _sorted = [];

  /// Bumped whenever the held kind-1/6 (feed-content) set changes — an
  /// add/evict/remove of a kind-1 or kind-6 event. Derived providers gate on
  /// this int so kind-7 (reaction) firehose churn does NOT rebuild the feed
  /// ("全球 tab 下滑卡顿": the store flushes every 200ms while any events
  /// arrive, and reactions are the highest-volume kind).
  int _contentRevision = 0;
  int get contentRevision => _contentRevision;

  /// Bumped whenever the held kind-1/6/7 set changes (superset of
  /// [contentRevision]) — gates the per-post interaction index.
  int _interactionRevision = 0;
  int get interactionRevision => _interactionRevision;

  /// Cached index into [_sorted] of the OLDEST event per evictable kind, so
  /// over-cap eviction picks its victim in O(1) instead of up to three
  /// full-store scans per ingested event (at firehose saturation those scans
  /// ran continuously on the UI isolate — part of the 全球 scroll jank).
  /// Maintained incrementally on insert/remove; a kind's entry is dropped
  /// when its hinted event is evicted and lazily re-scanned on demand (the
  /// next-oldest kind-7 sits ~1 slot from the tail, so the rescan is short).
  final Map<int, int> _oldestHint = {};

  void _bumpForAdd(int kind) {
    if (kind == 1 || kind == 6) _contentRevision++;
    if (kind == 1 || kind == 6 || kind == 7) _interactionRevision++;
  }

  void _bumpForRemove(int kind) {
    if (kind == 1 || kind == 6) _contentRevision++;
    if (kind == 1 || kind == 6 || kind == 7) _interactionRevision++;
  }

  /// Returns true if the event is held in the store after the call (false on
  /// duplicate id, unsupported kind, or immediate eviction — a fetch of
  /// content OLDER than everything held can still self-evict once the cap is
  /// saturated with posts; the caller treats that as "not shown").
  bool add(Event e) {
    // Store kind-0 (metadata), kind-1 (text notes), kind-6 (reposts),
    // kind-7 (reactions). These all come in via the global feed subscription
    // (kinds:[0,1,6,7]).
    if (e.kind != 0 && e.kind != 1 && e.kind != 6 && e.kind != 7) return false;
    if (_byId.containsKey(e.id)) return false;
    _byId[e.id] = e;
    _insertSorted(e);
    _bumpForAdd(e.kind);
    if (_sorted.length > maxEvents) {
      final vi = _pickEvictionVictimIndex();
      if (vi != null) {
        final victim = _sorted[vi];
        _removeAt(vi);
        // Even a self-evicting add (new event older than everything held,
        // held set unchanged) bumps twice (add + evict): revisions are
        // change-detectors, and one harmless extra downstream rebuild beats
        // non-monotonic counters missing real changes.
        _bumpForRemove(victim.kind);
      }
    }
    return _byId.containsKey(e.id);
  }

  /// Binary-search insert into the newest-first list (a full re-sort per add
  /// was O(n log n) — a load-more burst of hundreds of events re-sorted the
  /// whole cap-sized list every time). Maintains [_oldestHint].
  void _insertSorted(Event e) {
    var lo = 0;
    var hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compareDesc(e, _sorted[mid]) <= 0) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    _sorted.insert(lo, e);
    // Everything at/after the insert point shifted one slot right.
    for (final k in _oldestHint.keys.toList()) {
      final h = _oldestHint[k]!;
      if (h >= lo) _oldestHint[k] = h + 1;
    }
    // An event older than the current oldest of its kind becomes the hint.
    if (e.kind == 1 || e.kind == 6 || e.kind == 7) {
      final cur = _oldestHint[e.kind];
      if (cur == null || lo > cur) _oldestHint[e.kind] = lo;
    }
  }

  void _removeAt(int r) {
    final e = _sorted[r];
    _byId.remove(e.id);
    _sorted.removeAt(r);
    for (final k in _oldestHint.keys.toList()) {
      final h = _oldestHint[k]!;
      if (h == r) {
        _oldestHint.remove(k); // lazily re-scanned on the next eviction
      } else if (h > r) {
        _oldestHint[k] = h - 1;
      }
    }
  }

  /// Over-cap eviction priority: OLDEST kind-7 reactions first, then kind-6
  /// reposts, then kind-1 posts; kind-0 metadata is NEVER evicted.
  ///
  /// The old behavior evicted the single oldest event regardless of kind.
  /// That broke two things at once:
  /// - Reactions (kind-7) are by far the highest-volume kind on a following
  ///   feed, so the cap saturated with reaction churn and backward pagination
  ///   stalled: load-more fetched older POSTS, which sorted to the end and
  ///   were evicted immediately — the visible feed never got older and the
  ///   `until` cursor (derived from the oldest held post) never advanced.
  /// - Kind-0 metadata rows got evicted too, latching stale avatars/names
  ///   for the rest of the session ("连我的个人信息都是旧的比如头像和背景"
  ///   on the first launch after an update, fixed only by a restart).
  /// Reactions are the cheapest to lose (counts on old posts degrade to what
  /// is held; live counts on recent posts are unaffected), metadata the most
  /// expensive (every avatar/name in the UI reads it).
  int? _pickEvictionVictimIndex() {
    for (final kind in const [7, 6, 1]) {
      final idx = _oldestIndexFor(kind);
      if (idx != null) return idx;
    }
    return null; // only kind-0 left — never evict metadata
  }

  int? _oldestIndexFor(int kind) {
    final hint = _oldestHint[kind];
    if (hint != null) return hint;
    for (var i = _sorted.length - 1; i >= 0; i--) {
      if (_sorted[i].kind == kind) {
        _oldestHint[kind] = i;
        return i;
      }
    }
    return null;
  }

  /// Newest-first: higher createdAt first; ties broken by id ascending so the
  /// order is stable across rebuilds (no flicker).
  static int _compareDesc(Event a, Event b) {
    final c = b.createdAt.compareTo(a.createdAt);
    if (c != 0) return c;
    return a.id.compareTo(b.id);
  }

  /// Unmodifiable newest-first view.
  List<Event> get events => List.unmodifiable(_sorted);

  int get length => _sorted.length;

  /// Look up a live event by id (O(1)). Used to validate a NIP-09 kind-5
  /// deletion's authorship before removing the deleted event from the store
  /// (you can only delete your own posts). Returns null if not held.
  Event? byId(String id) => _byId[id];

  /// Remove an event by id (e.g. after a NIP-09 kind-5 deletion). Returns true
  /// if it was present.
  bool remove(String id) {
    final e = _byId[id];
    if (e == null) return false;
    final r = _sorted.indexOf(e);
    assert(r >= 0, 'byId/store index out of sync');
    _removeAt(r);
    _bumpForRemove(e.kind);
    return true;
  }

  void clear() {
    if (_sorted.isNotEmpty) {
      _contentRevision++;
      _interactionRevision++;
    }
    _byId.clear();
    _sorted.clear();
    _oldestHint.clear();
  }
}
