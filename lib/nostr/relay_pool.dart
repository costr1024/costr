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
  final Set<String> _closeOnEose = {};
  final LinkedHashSet<String> _seenIds = LinkedHashSet();
  bool _mergedWired = false;
  bool _connecting = false;

  final StreamController<Event> _merged = StreamController<Event>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  // late so the initializer can reference the instance method _emitStatus.
  late final StreamController<List<RelayState>> _status =
      StreamController<List<RelayState>>.broadcast(
    onListen: () => scheduleMicrotask(_emitStatus),
  );

  /// Merged, deduped stream of all events from all relays.
  Stream<Event> get events => _merged.stream;

  /// Merged stream of OK acks from all relays (publish verdicts).
  Stream<RelayOk> get oks => _oks.stream;

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
      c.eose.listen((String subId) {
        // On EOSE for a closeOnEose subscription, close it (bounded snapshot
        // instead of an unbounded live firehose — critical on small hosts).
        if (_closeOnEose.remove(subId)) {
          closeSubscription(subId);
        }
      });
      c.oks.listen((RelayOk ok) {
        if (!_oks.isClosed) _oks.add(ok);
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
  ///
  /// If [closeOnEose] is true (used for the global feed), the subscription is
  /// CLOSED on the first EOSE from any relay, bounding it to a recent snapshot
  /// instead of an unbounded live firehose.
  void request(String subId, Map<String, dynamic> filter,
      {bool closeOnEose = false}) {
    _activeSubs[subId] = filter;
    if (closeOnEose) _closeOnEose.add(subId);
    for (final c in _connections) {
      if (c.isConnected) c.request(subId, filter);
    }
  }

  /// Close a subscription on every connected relay and stop tracking it.
  void closeSubscription(String subId) {
    _activeSubs.remove(subId);
    _closeOnEose.remove(subId);
    for (final c in _connections) {
      if (c.isConnected) c.closeSubscription(subId);
    }
  }

  /// Publish a signed event to every connected relay (`["EVENT", ...]`).
  /// Also echoes it locally so the author sees their post in the feed
  /// immediately (relays only ack with OK, they don't echo EVENT on publish).
  void publish(Event event) {
    for (final c in _connections) {
      if (c.isConnected) c.publish(event);
    }
    if (!_merged.isClosed) _merged.add(event);
  }

  /// Publish and wait for relay OK verdicts. Resolves on the first relay that
  /// accepts (OK true); if all connected relays reject, resolves with the
  /// joined rejection reasons; times out if no ack within [timeout].
  Future<RelayOk> publishAndWait(Event event,
      {Duration timeout = const Duration(seconds: 10)}) async {
    final expected = event.id;
    final connected = _connections.where((c) => c.isConnected).toList();
    final rejected = <String>[];
    final completer = Completer<RelayOk>();
    bool resolved = false;

    final sub = oks.listen((RelayOk ok) {
      if (ok.id != expected || resolved) return;
      if (ok.ok) {
        resolved = true;
        completer.complete(ok);
      } else {
        rejected.add(ok.reason?.isNotEmpty == true ? ok.reason! : 'rejected');
        if (rejected.length >= connected.length) {
          resolved = true;
          completer.complete(RelayOk(expected, false, rejected.join('; ')));
        }
      }
    });

    publish(event);

    return completer.future
        .timeout(timeout,
            onTimeout: () => RelayOk(expected, false,
                'no relay ack in ${timeout.inSeconds}s (${connected.length} connected)'))
        .whenComplete(() => sub.cancel());
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
    await _oks.close();
    await _status.close();
  }
}
