// Unit tests for the feed read-freeze split logic (frozenVisible).
import 'package:costr/features/feed/feed_page.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _ev(String id, int t) => Event(
      id: id,
      pubkey: 'pk',
      createdAt: t,
      kind: 1,
      tags: const [],
      content: '',
      sig: 's',
    );

void main() {
  // Event has no value equality; compare by (id, createdAt) tuples.
  List<(String, int)> ids(List<Event> es) =>
      es.map((e) => (e.id, e.createdAt)).toList();

  // Sorted newest-first, as the EventStore presents them.
  final events = <Event>[
    _ev('c', 30),
    _ev('b', 20),
    _ev('a', 10),
  ];
  // The snapshot captured at freeze time (all three were visible).
  final snapshot = <String>{'c', 'b', 'a'};

  test('no barrier → live (everything visible, 0 pending)', () {
    final visible = frozenVisible(events, null, null, null);
    expect(visible.length, 3);
  });

  test('barrier = newest → at freeze time nothing is newer (full visible)', () {
    // Freeze to the newest (c@30). Snapshot holds all three; all visible.
    final visible = frozenVisible(events, 30, 'c', snapshot);
    expect(ids(visible), ids(events));
    expect(events.length - visible.length, 0);
  });

  test('after a new event arrives, it is held back as pending', () {
    // New event d@40 arrives → prepended in the live list.
    final live = <Event>[_ev('d', 40), ...events];
    // Barrier still c@30 (frozen before d arrived); d is not in the snapshot.
    final visible = frozenVisible(live, 30, 'c', snapshot);
    expect(ids(visible), ids(events));
    expect(live.length - visible.length, 1); // d is pending
  });

  test('multiple newer events all held back', () {
    final live = <Event>[_ev('e', 50), _ev('d', 40), ...events];
    final visible = frozenVisible(live, 30, 'c', snapshot);
    expect(ids(visible), ids(events));
    expect(live.length - visible.length, 2);
  });

  test('older events loaded via _loadMore are NOT held back', () {
    // _loadMore pulls an older event z@5 → appended at the tail. It is not in
    // the snapshot but its createdAt < barrier, so it shows.
    final live = <Event>[...events, _ev('z', 5)];
    final visible = frozenVisible(live, 30, 'c', snapshot);
    expect(ids(visible), ids(live)); // includes z
    expect(live.length - visible.length, 0);
  });

  test(
    'same-second arrivals after freeze are held back (snapshot, not id tie-break)',
    () {
      // Freeze to b@20. At freeze time the visible set at second 20 was {b, d}
      // (plus the older z@5). A new event a@20 arriving AFTER the freeze is
      // NOT in the snapshot → held back regardless of its id.
      final snap = <String>{'b', 'd', 'z'};
      final live = <Event>[
        _ev('a', 20), // arrived after freeze — held
        _ev('b', 20), // barrier
        _ev('d', 20), // was visible at freeze
        _ev('z', 5),
      ];
      final visible = frozenVisible(live, 20, 'b', snap);
      expect(ids(visible), [('b', 20), ('d', 20), ('z', 5)]);
      expect(live.length - visible.length, 1);
    },
  );

  test('null snapshot + barrier falls back to strictly-older rule', () {
    // No snapshot (older code path): only strictly-older-than-barrier + barrier
    // itself visible; same-second and newer held. Barrier b@20.
    final live = <Event>[
      _ev('a', 20),
      _ev('b', 20),
      _ev('d', 20),
      _ev('z', 5),
    ];
    final visible = frozenVisible(live, 20, 'b', null);
    // b@20 is the barrier: createdAt == 20 is NOT < 20, and not in a snapshot.
    // It must still show (it's the post being read) — the barrier id check
    // above already guaranteed it's present; include it explicitly:
    expect(visible.any((e) => e.id == 'b'), isTrue);
    // z@5 is strictly older → visible.
    expect(visible.any((e) => e.id == 'z'), isTrue);
    // a@20 and d@20 (same second, not barrier, not older) → held.
    expect(visible.any((e) => e.id == 'a'), isFalse);
    expect(visible.any((e) => e.id == 'd'), isFalse);
  });

  test('barrier evicted from the list → release (live, full visible)', () {
    final live = <Event>[_ev('d', 40), _ev('a', 10)]; // c gone
    final visible = frozenVisible(live, 30, 'c', snapshot);
    expect(ids(visible), ids(live)); // evicted → go live
    expect(live.length - visible.length, 0);
  });
}
