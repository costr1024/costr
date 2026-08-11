import 'package:costr/nostr/event_store.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _e(String id, int createdAt, {int kind = 1}) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: createdAt,
  kind: kind,
  tags: const [],
  content: 'c',
  sig: 's' * 128,
);

void main() {
  group('EventStore', () {
    test('keeps events sorted newest-first', () {
      final s = EventStore();
      s.add(_e('b', 100));
      s.add(_e('a', 200));
      s.add(_e('c', 50));
      expect(s.events.map((e) => e.id), ['a', 'b', 'c']);
    });

    test('dedups by id', () {
      final s = EventStore();
      expect(s.add(_e('x', 1)), isTrue);
      expect(s.add(_e('x', 1)), isFalse);
      expect(s.length, 1);
    });

    test('caps at maxEvents, dropping oldest', () {
      final s = EventStore(maxEvents: 3);
      s.add(_e('old', 1));
      s.add(_e('mid', 2));
      s.add(_e('new', 3));
      s.add(_e('newer', 4)); // over cap → drops 'old' (lowest createdAt)
      expect(s.length, 3);
      expect(s.events.map((e) => e.id), ['newer', 'new', 'mid']);
    });

    test('stable tie-break by id for same createdAt', () {
      final s = EventStore();
      s.add(_e('z', 100));
      s.add(_e('a', 100));
      s.add(_e('m', 100));
      // Same createdAt → id ascending: a, m, z
      expect(s.events.map((e) => e.id), ['a', 'm', 'z']);
    });

    test('clear empties the store', () {
      final s = EventStore();
      s.add(_e('a', 1));
      s.clear();
      expect(s.length, 0);
      expect(s.add(_e('a', 1)), isTrue); // id reusable after clear
    });

    // --- Eviction priority -------------------------------------------------
    //
    // Old behavior evicted the single oldest event of ANY kind. Reaction
    // churn saturated the cap and every older post fetched by load-more was
    // evicted the instant it was added (it was the oldest thing held), so
    // backward pagination stalled and the spinner ran forever. Fix #1 made the
    // order kind-7 → kind-6 → kind-1 and exempted kind-0. But the global feed
    // ingests every profile update on the firehose, and never-evicted kind-0
    // accumulated until it crowded kind-1/6 out of the capped store and the
    // feed showed nothing ("过会儿全刷没"). Fix #2 therefore makes kind-0
    // evictable too — but AFTER reactions and BEFORE feed content:
    // kind-7 → kind-0 → kind-6 → kind-1. Evicted metadata is still in SQLite
    // (kind-0 is always persisted), so avatars don't regress.

    test('over cap, oldest reactions evict before posts', () {
      final s = EventStore(maxEvents: 3);
      s.add(_e('r1', 1, kind: 7)); // oldest reaction
      s.add(_e('p1', 2));
      s.add(_e('p2', 3));
      // A NEWER reaction arriving pushes the store over cap — the OLDEST
      // REACTION goes, not the oldest post.
      expect(s.add(_e('r2', 4, kind: 7)), isTrue);
      expect(s.events.map((e) => e.id), ['r2', 'p2', 'p1']);
    });

    test('load-more of OLDER posts survives a cap full of churn', () {
      // The regression itself: store saturated with posts + reactions, then
      // backward pagination ingests posts OLDER than everything held. They
      // must be kept (reactions evict instead) — the old code dropped them
      // immediately, freezing the feed at a fixed depth.
      final s = EventStore(maxEvents: 4);
      s.add(_e('r1', 50, kind: 7));
      s.add(_e('r2', 60, kind: 7));
      s.add(_e('p1', 100));
      s.add(_e('p2', 110));
      // load-more page lands two older posts:
      expect(s.add(_e('old1', 10)), isTrue);
      expect(s.add(_e('old2', 20)), isTrue);
      expect(s.byId('old1'), isNotNull);
      expect(s.byId('old2'), isNotNull);
      // …and they are the tail of the timeline:
      expect(s.events.last.id, 'old1');
    });

    test('metadata evicts BEFORE feed content but AFTER reactions', () {
      // THE "过会儿全刷没" regression: kind-0 used to be never-evicted, so
      // firehose profile updates crowded kind-1/6 out of the capped store and
      // the feed emptied. kind-0 must now be sacrificed before any kind-1/6,
      // while reactions (cheapest) still go first.
      final s = EventStore(maxEvents: 4);
      s.add(_e('m', 1, kind: 0)); // metadata
      s.add(_e('r', 2, kind: 7)); // reaction
      s.add(_e('rp', 3, kind: 6)); // repost
      s.add(_e('p', 4)); // post — store now full
      // Churn with newer posts; victims must leave in priority order.
      s.add(_e('p2', 5)); // evicts oldest kind-7 (the reaction)
      expect(s.byId('r'), isNull);
      expect(s.byId('m'), isNotNull);
      s.add(_e('p3', 6)); // evicts oldest kind-0 — feed content protected
      expect(s.byId('m'), isNull);
      expect(s.byId('rp'), isNotNull);
      expect(s.byId('p'), isNotNull);
      s.add(_e('p4', 7)); // evicts oldest kind-6
      expect(s.byId('rp'), isNull);
      s.add(_e('p5', 8)); // evicts oldest kind-1 last
      expect(s.byId('p'), isNull);
      expect(s.events.map((e) => e.id), ['p5', 'p4', 'p3', 'p2']);
    });

    test('kind-0 is replaceable per pubkey: newest wins, older dropped', () {
      final s = EventStore();
      Event mk(String id, int t) => Event(
        id: id,
        pubkey: 'author',
        createdAt: t,
        kind: 0,
        tags: const [],
        content: 'c',
        sig: 's',
      );
      expect(s.add(mk('v1', 10)), isTrue);
      // An OLDER revision than held is dropped outright.
      expect(s.add(mk('v0', 5)), isFalse);
      expect(s.byId('v1'), isNotNull);
      expect(s.byId('v0'), isNull);
      // A NEWER revision replaces the held one (single slot per author).
      expect(s.add(mk('v2', 20)), isTrue);
      expect(s.byId('v1'), isNull);
      expect(s.byId('v2'), isNotNull);
      expect(s.length, 1);
      // A distinct author keeps its own slot.
      final other = Event(
        id: 'o1',
        pubkey: 'someone-else',
        createdAt: 15,
        kind: 0,
        tags: const [],
        content: 'c',
        sig: 's',
      );
      expect(s.add(other), isTrue);
      expect(s.byId('o1'), isNotNull);
      expect(s.byId('v2'), isNotNull);
      expect(s.length, 2);
    });

    test('reposts evict before original posts', () {
      final s = EventStore(maxEvents: 2);
      s.add(_e('rp', 1, kind: 6));
      s.add(_e('p1', 2));
      s.add(_e('p2', 3)); // over cap: oldest kind-6 goes first
      expect(s.byId('rp'), isNull);
      expect(s.byId('p1'), isNotNull);
    });

    test('self-evicted older-than-everything post reports not held', () {
      // A cap already saturated with posts (no reactions/reposts left to
      // sacrifice) cannot grow backward forever — the just-added oldest post
      // is the victim and add() says so (callers treat it as "not shown").
      final s = EventStore(maxEvents: 2);
      s.add(_e('p1', 100));
      s.add(_e('p2', 110));
      expect(s.add(_e('ancient', 1)), isFalse);
      expect(s.byId('ancient'), isNull);
      expect(s.length, 2);
    });
  });

  group('revision counters (feed-rebuild gating)', () {
    test('kind-1/6 bump content+interaction; kind-7 interaction only; '
        'kind-0 neither', () {
      final s = EventStore();
      expect(s.contentRevision, 0);
      expect(s.interactionRevision, 0);
      s.add(_e('m0', 5, kind: 0)); // metadata
      expect(s.contentRevision, 0);
      expect(s.interactionRevision, 0);
      s.add(_e('r1', 10, kind: 7)); // reaction
      expect(s.contentRevision, 0);
      expect(s.interactionRevision, 1);
      s.add(_e('p1', 20)); // post
      expect(s.contentRevision, 1);
      expect(s.interactionRevision, 2);
      s.add(_e('rp1', 30, kind: 6)); // repost
      expect(s.contentRevision, 2);
      expect(s.interactionRevision, 3);
      // Duplicates change nothing.
      s.add(_e('p1', 20));
      expect(s.contentRevision, 2);
      expect(s.interactionRevision, 3);
    });

    test('remove and clear bump; self-eviction bumps the pair', () {
      final s = EventStore(maxEvents: 2);
      s.add(_e('p1', 100));
      s.add(_e('p2', 110));
      final c0 = s.contentRevision;
      final i0 = s.interactionRevision;
      // Self-evicting add: the held set is unchanged, but the add+evict pair
      // still bumps twice (revisions are change-detectors; one harmless extra
      // rebuild downstream in this rare case).
      s.add(_e('ancient', 1));
      expect(s.contentRevision, c0 + 2);
      expect(s.interactionRevision, i0 + 2);
      s.remove('p1');
      expect(s.contentRevision, c0 + 3);
      expect(s.interactionRevision, i0 + 3);
      s.clear();
      expect(s.contentRevision, greaterThan(c0 + 3));
    });

    test('eviction with the O(1) hint matches the priority order', () {
      // Mixed interleaved kinds over a small cap; the hinted victim picker must
      // evict in the priority order — oldest kind-7 first, then kind-0, then
      // kind-6, then kind-1 — exactly what a full tail-scan would pick. This
      // guards the incremental [_oldestHint] bookkeeping against drift.
      final s = EventStore(maxEvents: 6);
      s.add(_e('meta', 1, kind: 0));
      s.add(_e('r1', 2, kind: 7));
      s.add(_e('p1', 3));
      s.add(_e('r2', 4, kind: 7));
      s.add(_e('rp1', 5, kind: 6));
      s.add(_e('p2', 6));
      // Saturation churn: each new event evicts one. Expected victims in
      // order: r1 (oldest 7), r2 (next 7), meta (oldest 0), rp1 (oldest 6).
      s.add(_e('p3', 7));
      expect(s.byId('r1'), isNull);
      s.add(_e('p4', 8));
      expect(s.byId('r2'), isNull);
      s.add(_e('p5', 9));
      expect(s.byId('meta'), isNull); // metadata evicts before feed content
      expect(s.byId('rp1'), isNotNull);
      s.add(_e('p6', 10));
      expect(s.byId('rp1'), isNull);
      expect(s.byId('p1'), isNotNull); // posts evict last
      expect(s.length, 6);
      expect(
        s.events.map((e) => e.id),
        ['p6', 'p5', 'p4', 'p3', 'p2', 'p1'],
        reason: 'held set matches the priority-order eviction result',
      );
    });
  });
}
