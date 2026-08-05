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

    // --- Eviction priority (the "无法加载更老的帖子" fix) -------------------
    //
    // Old behavior evicted the single oldest event of ANY kind. Reaction
    // churn saturated the cap and every older post fetched by load-more was
    // evicted the instant it was added (it was the oldest thing held), so
    // backward pagination stalled and the spinner ran forever. Now:
    // kind-7 → kind-6 → kind-1, and kind-0 metadata is never evicted.

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

    test('metadata (kind-0) is never evicted', () {
      final s = EventStore(maxEvents: 2);
      s.add(_e('m', 1, kind: 0));
      s.add(_e('p1', 2));
      s.add(_e('r1', 3, kind: 7)); // over cap: reaction goes
      expect(s.byId('m'), isNotNull);
      s.add(_e('p2', 4)); // over cap again: oldest post goes, not metadata
      expect(s.byId('m'), isNotNull);
      expect(s.byId('p1'), isNull);
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
}
