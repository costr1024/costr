/// In-memory event store: dedup by id, sorted newest-first, capped.
///
/// Plain class (no riverpod) so it can be unit-tested directly. The notifier
/// wrapper lives in `lib/app/providers.dart`.
library;

import '../models/event.dart';

class EventStore {
  EventStore({this.maxEvents = 5000});

  final int maxEvents;

  final Map<String, Event> _byId = {};
  final List<Event> _sorted = [];

  /// Returns true if the event was newly added (false on duplicate id).
  bool add(Event e) {
    if (_byId.containsKey(e.id)) return false;
    _byId[e.id] = e;
    _sorted.add(e);
    _sorted.sort(_compareDesc);
    if (_sorted.length > maxEvents) {
      final removed = _sorted.removeLast();
      _byId.remove(removed.id);
    }
    return true;
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

  void clear() {
    _byId.clear();
    _sorted.clear();
  }
}
