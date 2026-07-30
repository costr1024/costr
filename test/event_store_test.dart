import 'package:costr/nostr/event_store.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _e(String id, int createdAt) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: createdAt,
  kind: 1,
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
  });
}
