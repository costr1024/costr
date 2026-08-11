/// In-memory cache of interaction events (kind-6/16 reposts, kind-7
/// reactions) keyed by their `e`-tag target post — the eviction-PROOF half
/// of the interaction display source (the capped [EventStore] is the other
/// half; InteractionIndexNotifier merges both).
///
/// Why this exists separately from EventStore: the store is sized for feed
/// pagination and evicts kind-7 FIRST (highest-volume, cheapest to lose).
/// Once the global firehose saturates the cap, EVERY incoming event evicts
/// the oldest held kind-7, so a reaction lives ~one event-arrival (~25ms on
/// a busy firehose): reactions fetched on thread-open, reactions/reposts
/// delivered by ANY unrouted subscription (following feed, the notifications
/// #e REQ — ingested by the EventStore merged-stream listener), and the local
/// echo of the user's OWN just-published reaction all disappear before the UI
/// can show them ("点赞不显示、点了几次都没用" — the user taps repeatedly
/// because the heart never fills, stacking duplicate reactions on the
/// relays; "通知里有点赞提醒，点进帖子却看不到" — the notification center's
/// long-lived sub saw the like, but nothing kept it for the detail page).
/// This cache never ingests the ROUTED global firehose — only what the
/// following/notification/lookup traffic and the user's own publishes carry —
/// so it cannot be crowded out; the tradeoff is deliberate — feed-card
/// tallies stay a lower bound until a thread is opened (documented
/// PostCounts semantics).
library;

import 'dart:collection';

import '../models/event.dart';

class InteractionCache {
  InteractionCache({this.maxTargets = 200, this.maxPerTarget = 500});

  /// LRU cap on DISTINCT target posts (threads opened / own interactions in
  /// a session). The least-recently-touched target drops first.
  final int maxTargets;

  /// Cap per target post (viral-post guard: a #e fetch of a post with
  /// thousands of reactions must not blow up memory).
  final int maxPerTarget;

  /// target post id -> (interaction event id -> event). LinkedHashMap keeps
  /// LRU order on targets: the most recently touched target sits last.
  final LinkedHashMap<String, LinkedHashMap<String, Event>> _byTarget =
      LinkedHashMap();

  /// Bumped whenever the held set changes — derived providers gate rebuilds
  /// on this counter (same pattern as EventStore.interactionRevision).
  int _revision = 0;
  int get revision => _revision;

  int get targetCount => _byTarget.length;

  /// Every held interaction event. An event referencing N targets is yielded
  /// once PER TARGET (callers tally per target, matching the index semantics).
  Iterable<Event> get events sync* {
    for (final bucket in _byTarget.values) {
      yield* bucket.values;
    }
  }

  /// Ingest interaction events (kind 6/16 reposts, kind 7 reactions), keyed
  /// by each `e`-tag target. Anything else (posts, metadata…) is ignored —
  /// this cache holds ONLY the interaction kinds the index tallies. Returns
  /// true when at least one new event was added.
  bool ingest(Iterable<Event> events) {
    var changed = false;
    for (final e in events) {
      if (e.kind != 6 && e.kind != 7 && e.kind != Event.kindGenericRepost) {
        continue;
      }
      for (final t in e.tags) {
        if (t.length < 2 || t[0] != 'e' || t[1] is! String) continue;
        final target = t[1] as String;
        if (target == e.id) continue; // self-reference guard (store parity)
        if (_ingestOne(target, e)) changed = true;
      }
    }
    if (changed) _revision++;
    return changed;
  }

  bool _ingestOne(String target, Event e) {
    var bucket = _byTarget[target];
    if (bucket == null) {
      bucket = LinkedHashMap<String, Event>();
      _byTarget[target] = bucket;
      // Over the target cap → drop the least-recently-touched target.
      while (_byTarget.length > maxTargets) {
        _byTarget.remove(_byTarget.keys.first);
      }
    } else {
      // Re-touch: move to the MRU position.
      _byTarget.remove(target);
      _byTarget[target] = bucket;
    }
    if (bucket.containsKey(e.id)) return false;
    bucket[e.id] = e;
    if (bucket.length > maxPerTarget) {
      // Trim the OLDEST interaction (newest are the interesting ones).
      Event? oldest;
      for (final cand in bucket.values) {
        if (oldest == null || cand.createdAt < oldest.createdAt) oldest = cand;
      }
      if (oldest != null) bucket.remove(oldest.id);
    }
    return true;
  }

  /// Remove one interaction event by id (reaction cancel via NIP-09 kind-5,
  /// or the local un-fill). [where] optionally gates on the held copy (e.g.
  /// authorship check for remote deletions). Returns true when removed.
  bool removeEvent(String eventId, {bool Function(Event)? where}) {
    var changed = false;
    for (final bucket in _byTarget.values) {
      final e = bucket[eventId];
      if (e != null && (where == null || where(e))) {
        bucket.remove(eventId);
        changed = true;
      }
    }
    if (changed) {
      _byTarget.removeWhere((_, bucket) => bucket.isEmpty);
      _revision++;
    }
    return changed;
  }

  void clear() {
    if (_byTarget.isEmpty) return;
    _byTarget.clear();
    _revision++;
  }
}
