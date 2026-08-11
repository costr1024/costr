// Unit tests for InteractionCache — the eviction-proof tier that keeps
// fetched reactions/reposts, the user's own publishes, AND live-delivered
// kind-1 replies displayable after the capped EventStore evicts them on a
// saturated feed ("点赞不显示、点了几次都没用" + "信息流回复计数" regressions).

import 'package:costr/models/event.dart';
import 'package:costr/nostr/interaction_cache.dart';
import 'package:flutter_test/flutter_test.dart';

Event _ev(
  String id, {
  required int kind,
  required String target,
  String pubkey = 'b',
  String content = '+',
  int at = 1700000000,
}) => Event(
  id: id.padRight(64, '0'),
  pubkey: pubkey.padRight(64, '0'),
  createdAt: at,
  kind: kind,
  tags: [
    ['e', target.padRight(64, '0')],
  ],
  content: content,
  sig: 's' * 128,
);

void main() {
  final target = 't'.padRight(64, '0');

  test('ingest indexes kind-7 by e-tag target and bumps the revision', () {
    final c = InteractionCache();
    expect(c.revision, 0);
    expect(c.ingest([_ev('a', kind: 7, target: target)]), isTrue);
    expect(c.revision, 1);
    expect(c.events.single.id, 'a'.padRight(64, '0'));
    expect(c.targetCount, 1);
  });

  test('non-interaction kinds and self-references are ignored', () {
    final c = InteractionCache();
    // kind-0 metadata: still rejected (not a tallied interaction/reply).
    expect(c.ingest([_ev('k0', kind: 0, target: target)]), isFalse);
    // kind-1 REPLY (has an e-tag target): now HELD — it backs the eviction-
    // proof feed reply COUNT ("信息流回复计数" fix).
    expect(c.ingest([_ev('k1', kind: 1, target: target)]), isTrue);
    // kind-1 top-level post (no e tags): nothing to key onto → ignored.
    final topLevel = Event(
      id: 'tl'.padRight(64, '0'),
      pubkey: 'b'.padRight(64, '0'),
      createdAt: 1700000000,
      kind: 1,
      tags: const [],
      content: 'top-level',
      sig: 's' * 128,
    );
    expect(c.ingest([topLevel]), isFalse);
    // kind-7 whose e-tag points at itself: rejected (store parity).
    final selfId = 'x' * 64;
    final selfRef = Event(
      id: selfId,
      pubkey: 'b' * 64,
      createdAt: 1700000000,
      kind: 7,
      tags: [
        ['e', selfId],
      ],
      content: '+',
      sig: 's' * 128,
    );
    expect(c.ingest([selfRef]), isFalse);
    // Only the kind-1 reply landed → one target, one held event.
    expect(c.targetCount, 1);
    expect(c.events.length, 1);
  });

  test('duplicate ids are deduped (relay answers overlap)', () {
    final c = InteractionCache();
    expect(c.ingest([_ev('a', kind: 7, target: target)]), isTrue);
    expect(c.ingest([_ev('a', kind: 7, target: target)]), isFalse);
    expect(c.events.length, 1);
    expect(c.revision, 1);
  });

  test('kind-6 and kind-16 reposts are held too', () {
    final c = InteractionCache();
    c.ingest([
      _ev('r6', kind: 6, target: target),
      _ev('r16', kind: 16, target: target),
    ]);
    expect(c.events.map((e) => e.kind).toSet(), {6, 16});
  });

  test('removeEvent drops across targets; where gates on the held copy', () {
    final c = InteractionCache();
    final other = 'o'.padRight(64, '0');
    c.ingest([
      _ev('a', kind: 7, target: target, pubkey: 'mine'),
      _ev('b', kind: 7, target: other, pubkey: 'stranger'),
    ]);
    // Authorship gate fails → nothing removed.
    expect(
      c.removeEvent('a'.padRight(64, '0'), where: (e) => e.pubkey == 'z' * 64),
      isFalse,
    );
    expect(c.targetCount, 2);
    // Gate passes → removed; empty targets drop out.
    expect(
      c.removeEvent(
        'a'.padRight(64, '0'),
        where: (e) => e.pubkey == 'mine'.padRight(64, '0'),
      ),
      isTrue,
    );
    expect(c.targetCount, 1);
    expect(c.events.single.id, 'b'.padRight(64, '0'));
  });

  test('target LRU cap drops the least-recently-touched post', () {
    final c = InteractionCache(maxTargets: 2);
    final t1 = '1'.padRight(64, '0');
    final t2 = '2'.padRight(64, '0');
    final t3 = '3'.padRight(64, '0');
    c.ingest([_ev('a', kind: 7, target: t1)]);
    c.ingest([_ev('b', kind: 7, target: t2)]);
    // Re-touch t1 so t2 becomes LRU.
    c.ingest([_ev('c', kind: 7, target: t1)]);
    c.ingest([_ev('d', kind: 7, target: t3)]);
    final targets = <String>{};
    for (final e in c.events) {
      for (final t in e.tags) {
        if (t[0] == 'e') targets.add(t[1] as String);
      }
    }
    expect(targets, {t1, t3}); // t2 evicted
  });

  test('per-target cap drops the oldest interaction (viral-post guard)', () {
    final c = InteractionCache(maxPerTarget: 3);
    c.ingest([
      for (var i = 0; i < 5; i++)
        _ev('e$i', kind: 7, target: target, at: 1700000000 + i),
    ]);
    final held = c.events.map((e) => e.id).toSet();
    expect(held.length, 3);
    // Oldest two (e0, e1) dropped; newest three kept.
    expect(held, {
      'e2'.padRight(64, '0'),
      'e3'.padRight(64, '0'),
      'e4'.padRight(64, '0'),
    });
  });

  test('clear empties and bumps once', () {
    final c = InteractionCache();
    c.ingest([_ev('a', kind: 7, target: target)]);
    final before = c.revision;
    c.clear();
    expect(c.targetCount, 0);
    expect(c.revision, before + 1);
    c.clear(); // already empty → no bump
    expect(c.revision, before + 1);
  });
}
