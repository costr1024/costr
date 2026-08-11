// Regression test for the "全球/关注流过会儿全刷没" bug.
//
// Root cause: the global feed subscription has no author filter, so it ingests
// every kind-0 profile update on the firehose. kind-0 was exempt from eviction,
// so it accumulated and crowded kind-1/6 out of the capped store until the feed
// (kind-1/6 only) showed nothing. A secondary defect: once only kind-0 remained,
// `_pickEvictionVictimIndex` returned null and `add()` evicted nothing, so the
// store grew past its cap unboundedly (memory leak).
//
// Fix under test (EventStore):
//  - kind-0 is replaceable-by-pubkey (one metadata slot per author), and
//  - eviction priority is kind-7 → kind-0 → kind-6 → kind-1, so feed content
//    (kind-1/6) is protected over metadata, and the cap ALWAYS holds.
//
// These scenarios drive the store far past saturation — the regime the live
// harness never reached (it topped out well under the cap, so eviction never
// fired there).

import 'dart:math';

import 'package:costr/models/event.dart';
import 'package:costr/nostr/event_store.dart';
import 'package:flutter_test/flutter_test.dart';

Event mk(int kind, int i, int createdAt, {String? pubkey}) => Event(
  id: '${kind}_$i',
  pubkey: pubkey ?? 'p${i % 500}',
  createdAt: createdAt,
  kind: kind,
  tags: const [],
  content: 'c$i',
  sig: 's',
);

({int k16, int k7, int k0, int k6}) counts(EventStore s) {
  var k16 = 0;
  var k7 = 0;
  var k0 = 0;
  var k6 = 0;
  for (final e in s.events) {
    switch (e.kind) {
      case 1:
        k16++;
      case 6:
        k6++;
        k16++;
      case 7:
        k7++;
      case 0:
        k0++;
    }
  }
  return (k16: k16, k7: k7, k0: k0, k6: k6);
}

void main() {
  const cap = 2000;

  test('kind-0 flood (distinct authors) can never empty the feed or break '
      'the cap', () {
    final store = EventStore(maxEvents: cap);
    final rnd = Random(7);
    var t = 1000000;
    var minK16AfterSaturation = 1 << 30;
    // 40% kind-0 (each from a DISTINCT pubkey, so replaceable-by-pubkey can't
    // help — only the eviction order can protect the feed), 40% kind-7,
    // 15% kind-1, 5% kind-6.
    for (var i = 0; i < 15000; i++) {
      t += 1;
      final r = rnd.nextInt(100);
      final kind = r < 40 ? 0 : (r < 80 ? 7 : (r < 95 ? 1 : 6));
      // distinct pubkey per kind-0 → worst case for metadata accumulation
      store.add(mk(kind, i, t, pubkey: kind == 0 ? 'meta$i' : null));
      // Invariant 1: the cap ALWAYS holds (no unbounded growth).
      expect(store.length, lessThanOrEqualTo(cap), reason: 'at i=$i');
      if (i % 1000 == 0 && store.length == cap) {
        final c = counts(store);
        if (c.k16 < minK16AfterSaturation) minK16AfterSaturation = c.k16;
      }
    }
    final c = counts(store);
    // Invariant 2: the feed content survives the flood.
    expect(c.k16, greaterThan(0), reason: 'feed must not empty');
    expect(
      minK16AfterSaturation,
      greaterThan(0),
      reason: 'feed must not empty at any saturated sample',
    );
    expect(store.length, lessThanOrEqualTo(cap));
    // ignore: avoid_print
    print(
      'flood end: len=${store.length} k1/6=${c.k16} k7=${c.k7} '
      'k0=${c.k0} minK16=$minK16AfterSaturation',
    );
  });

  test('repeated profile updates by the same authors do not accumulate', () {
    final store = EventStore(maxEvents: cap);
    var t = 1000000;
    // 300 authors each update their profile many times, interleaved with a
    // little feed content. Replaceable-by-pubkey must keep ≤300 kind-0 total.
    for (var round = 0; round < 20; round++) {
      for (var a = 0; a < 300; a++) {
        t += 1;
        store.add(mk(0, round * 1000 + a, t, pubkey: 'author$a'));
      }
      for (var k = 0; k < 50; k++) {
        t += 1;
        store.add(mk(1, round * 100 + k, t));
      }
    }
    final c = counts(store);
    expect(
      c.k0,
      lessThanOrEqualTo(300),
      reason: 'one metadata slot per author',
    );
    expect(c.k16, greaterThan(0));
    expect(store.length, lessThanOrEqualTo(cap));
    // ignore: avoid_print
    print('dedup end: len=${store.length} k1/6=${c.k16} k0=${c.k0}');
  });

  test('realistic firehose keeps feed content healthy', () {
    final store = EventStore(maxEvents: cap);
    final rnd = Random(42);
    var t = 1000000;
    // ~55% reactions, 30% posts, 10% reposts, 5% metadata — like a live relay.
    for (var i = 0; i < 15000; i++) {
      t += 1;
      final r = rnd.nextInt(100);
      final kind = r < 55 ? 7 : (r < 85 ? 1 : (r < 95 ? 6 : 0));
      store.add(mk(kind, i, t, pubkey: kind == 0 ? 'meta$i' : null));
      expect(store.length, lessThanOrEqualTo(cap));
    }
    final c = counts(store);
    expect(
      c.k16,
      greaterThan(cap ~/ 4),
      reason: 'posts+reposts should dominate a healthy feed',
    );
    // ignore: avoid_print
    print(
      'realistic end: len=${store.length} k1/6=${c.k16} k7=${c.k7} '
      'k0=${c.k0}',
    );
  });
}
