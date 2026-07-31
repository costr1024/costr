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

  test('no barrier → live (everything visible, 0 pending)', () {
    final visible = frozenVisible(events, null, null);
    expect(visible.length, 3);
  });

  test('barrier = newest → at freeze time nothing is newer (full visible)', () {
    // Freeze to the newest (c@30). No event is newer, so all visible, 0 pending.
    final visible = frozenVisible(events, 30, 'c');
    expect(ids(visible), ids(events));
    expect(events.length - visible.length, 0);
  });

  test('after a new event arrives, it is held back as pending', () {
    // New event d@40 arrives → prepended in the live list.
    final live = <Event>[_ev('d', 40), ...events];
    // Barrier still c@30 (frozen before d arrived).
    final visible = frozenVisible(live, 30, 'c');
    // d is newer than the barrier → excluded; visible stays the freeze-time list.
    expect(ids(visible), ids(events));
    expect(live.length - visible.length, 1); // d is pending
  });

  test('multiple newer events all held back', () {
    final live = <Event>[_ev('e', 50), _ev('d', 40), ...events];
    final visible = frozenVisible(live, 30, 'c');
    expect(ids(visible), ids(events));
    expect(live.length - visible.length, 2);
  });

  test('older events loaded via _loadMore are NOT held back', () {
    // _loadMore pulls an older event z@5 → appended at the tail.
    final live = <Event>[...events, _ev('z', 5)];
    final visible = frozenVisible(live, 30, 'c');
    expect(ids(visible), ids(live)); // includes z
    expect(live.length - visible.length, 0);
  });

  test('same createdAt, tie broken by id (lower id = newer, held back)', () {
    // Barrier is b@20. A new event a@20 (id 'a' < 'b') is "newer" by the sort
    // tie-break and must be held back; an older-tie d@20 (id 'd' > 'b') is
    // older and visible.
    final live = <Event>[
      _ev('a', 20), // newer tie
      _ev('b', 20), // barrier
      _ev('d', 20), // older tie
      _ev('z', 5),
    ];
    final visible = frozenVisible(live, 20, 'b');
    expect(ids(visible), [('b', 20), ('d', 20), ('z', 5)]);
    expect(live.length - visible.length, 1);
  });

  test('barrier evicted from the list → release (live, full visible)', () {
    final live = <Event>[_ev('d', 40), _ev('a', 10)]; // c gone
    final visible = frozenVisible(live, 30, 'c');
    expect(ids(visible), ids(live)); // evicted → go live
    expect(live.length - visible.length, 0);
  });
}
