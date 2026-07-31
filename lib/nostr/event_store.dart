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
    // Store kind-0 (metadata), kind-1 (text notes), kind-6 (reposts),
    // kind-7 (reactions). These all come in via the global feed subscription
    // (kinds:[0,1,6,7]).
    if (e.kind != 0 && e.kind != 1 && e.kind != 6 && e.kind != 7) return false;
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

  /// Remove an event by id (e.g. after a NIP-09 kind-5 deletion). Returns true
  /// if it was present.
  bool remove(String id) {
    final e = _byId.remove(id);
    if (e == null) return false;
    _sorted.remove(e);
    return true;
  }

  void clear() {
    _byId.clear();
    _sorted.clear();
  }
}
