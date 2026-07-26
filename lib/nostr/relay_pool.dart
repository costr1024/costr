/// Relay pool: manages N [RelayConnection]s, merges their event streams with
/// per-id dedup, tracks active subscriptions per relay, and re-issues them on
/// (re)connect. Exposes relay connection state for the UI.
///
/// v1 does not auto-CLOSE on EOSE for the global feed (live, capped by the
/// EventStore); the EOSE stream is surfaced for future use.
library;

import 'dart:async';
import 'dart:collection';

import '../models/event.dart';
import 'relay_client.dart';

enum RelayStatus { connecting, connected, disconnected, error }

class RelayState {
  const RelayState(this.url, this.status, [this.error]);
  final String url;
  final RelayStatus status;
  final String? error;

  @override
  String toString() => 'RelayState($url: $status${error == null ? '' : ' — $error'})';
}

class RelayPool {
  /// Build a pool backed by real WebSocket [RelayClient]s from [urls].
  factory RelayPool.fromUrls(List<String> urls) =>
      RelayPool(urls.map((u) => RelayClient(u)).toList());

  /// Construct with explicit connections (allows test injection of fakes).
  RelayPool(List<RelayConnection> connections)
      : _connections = List<RelayConnection>.unmodifiable(connections);

  final List<RelayConnection> _connections;
  final Map<String, Map<String, dynamic>> _activeSubs = {};
  final LinkedHashSet<String> _seenIds = LinkedHashSet();
  bool _mergedWired = false;
  bool _connecting = false;

  final StreamController<Event> _merged = StreamController<Event>.broadcast();
  // late so the initializer can reference the instance method _emitStatus.
  late final StreamController<List<RelayState>> _status =
      StreamController<List<RelayState>>.broadcast(
    onListen: () => scheduleMicrotask(_emitStatus),
  );

  /// Merged, deduped stream of all events from all relays.
  Stream<Event> get events => _merged.stream;

  /// Stream of relay connection states (emits current state on subscribe, and
  /// on every connect/disconnect thereafter).
  Stream<List<RelayState>> get statusStream => _status.stream;

  List<RelayState> get states => _connections
      .map((c) => RelayState(
            c.url,
            c.isConnected ? RelayStatus.connected : RelayStatus.disconnected,
          ))
      .toList();

  Future<void> connect() async {
    if (_connecting || _mergedWired) return;
    _connecting = true;
    _wireMerged();
    for (final c in _connections) {
      c.setOnConnected(() {
        _resendActive(c);
        _emitStatus();
      });
      c.setOnDisconnected(_emitStatus);
      await c.connect().catchError((Object _) {});
    }
    _connecting = false;
    _emitStatus();
  }

  void _wireMerged() {
    if (_mergedWired) return;
    _mergedWired = true;
    for (final c in _connections) {
      c.events.listen((e) {
        if (_seenIds.add(e.id)) {
          _merged.add(e);
        }
        // Bound the dedup set to avoid unbounded memory growth on long sessions.
        if (_seenIds.length > 10000) {
          _seenIds.remove(_seenIds.first);
        }
      });
      c.eose.listen((_) {
        // v1: no-op. EOSE surfaced for future global-snapshot CLOSE behavior.
      });
    }
  }

  void _resendActive(RelayConnection c) {
    for (final entry in _activeSubs.entries) {
      c.request(entry.key, entry.value);
    }
  }

  /// Issue a REQ to every connected relay; re-issues to relays that reconnect
  /// later. [subId] must be unique per logical subscription.
  void request(String subId, Map<String, dynamic> filter) {
    _activeSubs[subId] = filter;
    for (final c in _connections) {
      if (c.isConnected) c.request(subId, filter);
    }
  }

  /// Close a subscription on every connected relay and stop tracking it.
  void closeSubscription(String subId) {
    _activeSubs.remove(subId);
    for (final c in _connections) {
      if (c.isConnected) c.closeSubscription(subId);
    }
  }

  void _emitStatus() {
    if (!_status.isClosed) {
      _status.add(states);
    }
  }

  Future<void> dispose() async {
    for (final c in _connections) {
      await c.dispose();
    }
    await _merged.close();
    await _status.close();
  }
}
