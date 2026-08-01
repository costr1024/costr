/// NIP-01 relay connection over WebSocket.
///
/// One [RelayClient] per relay URL. Implements [RelayConnection] so the pool
/// can be tested with fakes and can swap transports later.
///
/// Lifecycle note (the v1 regression fix): the event/eose/notice
/// [StreamController]s are created once in the constructor and are broadcast,
/// so subscribers attached before (or across) reconnects keep receiving — the
/// stream identity never changes on reconnect.
library;

import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/event.dart';

/// A relay's OK ack for a published event: `["OK", id, true/false, reason]`.
class RelayOk {
  const RelayOk(this.id, this.ok, this.reason, {this.url});
  final String id;
  final bool ok;
  final String? reason;

  /// Which relay sent this ack (for per-relay retry / NIP-42 auth flow).
  final String? url;
  @override
  String toString() =>
      'RelayOk($url: ${ok ? 'OK' : 'rejected'}${reason == null || reason!.isEmpty ? '' : ' — $reason'})';
}

/// Frame types a relay can push. v1 only consumes EVENT and EOSE; NOTICE and
/// OK are surfaced but not acted on (NOTICE is not an error; OK acks publishes
/// which v1 doesn't do).
abstract class RelayConnection {
  String get url;
  bool get isConnected;

  /// Kind-1 (and other) events received from the relay.
  Stream<Event> get events;

  /// Emits the subscription id on `["EOSE", subId]`.
  Stream<String> get eose;

  /// Emits the notice text on `["NOTICE", text]`.
  Stream<String> get notices;

  /// Emits OK acks for published events: `["OK", id, ok, reason]`.
  Stream<RelayOk> get oks;

  /// Emits NIP-42 AUTH challenges: `["AUTH", challenge]`.
  Stream<String> get auths;

  /// Send a signed NIP-42 auth response: `["AUTH", <event object>]`.
  void sendAuth(Event event);

  Future<void> connect();

  /// Send a `["REQ", subId, filter]`.
  void request(String subId, Map<String, dynamic> filter);

  /// Send a `["CLOSE", subId]`.
  void closeSubscription(String subId);

  /// Publish a signed event: `["EVENT", <wire array>]`.
  void publish(Event event);

  /// Hook fired after a successful (re)connect — the pool uses it to re-issue
  /// active subscriptions to this relay.
  void setOnConnected(void Function() cb);

  /// Hook fired when the socket drops.
  void setOnDisconnected(void Function() cb);

  Future<void> dispose();
}

class RelayClient implements RelayConnection {
  RelayClient(this.url);

  @override
  final String url;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _reconnectTimer;
  bool _connected = false;
  bool _disposed = false;
  int _backoffMs = 1000;
  int _rttCounter = 0;

  void Function()? _onConnected;
  void Function()? _onDisconnected;

  // Long-lived broadcast controllers — survive reconnect (regression fix R3).
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<(String, String)> _closed =
      StreamController<(String, String)>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;

  /// Emits `(subId, reason)` on `["CLOSED", subId, reason]`. Used by
  /// [measureRtt] to detect NIP-50-only relays that reject a plain REQ with a
  /// CLOSED notice ("error: search filter is required") instead of EOSE.
  Stream<(String, String)> get closed => _closed.stream;
  @override
  Stream<RelayOk> get oks => _oks.stream;
  @override
  Stream<String> get auths => _auths.stream;
  @override
  bool get isConnected => _connected;
  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) => _onDisconnected = cb;

  @override
  Future<void> connect() async {
    if (_disposed || _connected) return;
    final channel = WebSocketChannel.connect(Uri.parse(url));
    _channel = channel;
    // WebSocketChannel.connect is lazy — the WS/TLS handshake isn't done when
    // it returns. Await `ready` so `_connected` reflects a TRULY open socket.
    // Without this, GFW-blocked relays (handshake never completes) were marked
    // "connected" (green/在线) while RTT probes timed out with no data. A 10s
    // timeout lets silent black-holes fail fast instead of hanging.
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
    } catch (_) {
      if (_disposed) return;
      _scheduleReconnect();
      return;
    }
    if (_disposed) return;
    _sub = channel.stream.listen(
      _onData,
      onError: (Object _) => _handleDisconnect(),
      onDone: _handleDisconnect,
    );
    _connected = true;
    _backoffMs = 1000; // reset on success
    _onConnected?.call();
  }

  void _handleDisconnect() {
    if (!_connected && _reconnectTimer != null) return; // already reconnecting
    _connected = false;
    _onDisconnected?.call();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _backoffMs), () {
      _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
      connect();
    });
  }

  void _onData(dynamic data) {
    try {
      final msg = jsonDecode(data as String);
      if (msg is! List || msg.length < 2) return;
      final type = msg[0];
      if (type == 'EVENT' && msg.length >= 3) {
        // Relays send events as either the NIP-01 array form or (non-standard
        // but seen in the wild) the object form — fromMessage handles both.
        _events.add(Event.fromMessage(msg[2]));
      } else if (type == 'EOSE' && msg[1] is String) {
        _eose.add(msg[1] as String);
      } else if (type == 'NOTICE' && msg[1] is String) {
        _notices.add(msg[1] as String);
      } else if (type == 'CLOSED' && msg[1] is String) {
        final reason = (msg.length >= 3 ? msg[2] : null)?.toString() ?? '';
        _closed.add((msg[1] as String, reason));
      } else if (type == 'OK' && msg[1] is String) {
        final ok = msg[2] is bool ? msg[2] as bool : msg[2] == true;
        final reason = (msg.length >= 4 ? msg[3] : null)?.toString();
        _oks.add(RelayOk(msg[1] as String, ok, reason, url: url));
      } else if (type == 'AUTH' && msg[1] is String) {
        // NIP-42: relay challenges the client to authenticate.
        _auths.add(msg[1] as String);
      }
    } catch (_) {
      // Malformed frame — ignore. Relays occasionally send odd payloads.
    }
  }

  @override
  void request(String subId, Map<String, dynamic> filter) =>
      _send(['REQ', subId, filter]);

  @override
  void closeSubscription(String subId) => _send(['CLOSE', subId]);

  @override
  void publish(Event event) => _send(['EVENT', event.toWireObject()]);

  @override
  void sendAuth(Event event) => _send(['AUTH', event.toWireObject()]);

  void _send(List<dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
  }

  /// Measure real application-level WebSocket round-trip latency: send a REQ
  /// whose filter CANNOT match anything (`since` = 1 year in the future) and
  /// time until the relay replies — the first reply frame for an impossible
  /// filter is always `EOSE`, which the relay emits with no DB scan, so this
  /// ≈ network RTT over the live socket (not an ICMP ping). Returns null if
  /// not connected, or on [timeout] with no reply.
  ///
  /// NIP-50-only search relays (e.g. search.nos.today) reject a plain REQ
  /// with a `CLOSED` notice ("error: search filter is required") instead of
  /// EOSE. On CLOSED, retry with a NIP-50 `search` filter (which those relays
  /// DO EOSE) so their RTT is also measurable. The subscription is closed in
  /// all exit paths.
  Future<int?> measureRtt({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (_disposed || !_connected) return null;
    final subId = 'rtt${_rttCounter++}';
    final sw = Stopwatch()..start();
    final completer = Completer<int?>();
    late StreamSubscription<String> eoseSub;
    late StreamSubscription<(String, String)> closedSub;
    void complete(int? v) {
      if (!completer.isCompleted) completer.complete(v);
    }

    eoseSub = _eose.stream.where((id) => id == subId).listen((_) {
      complete(sw.elapsedMilliseconds);
    });
    var retried = false;
    closedSub = _closed.stream
        .where((pair) => pair.$1 == subId)
        .listen((_) {
          // Plain REQ rejected (e.g. NIP-50-only relay) → retry ONCE with a
          // search filter, which such relays EOSE. Restart the stopwatch so
          // the RTT reflects the search-filter round-trip only.
          if (retried) return;
          retried = true;
          sw.reset();
          _send([
            'REQ',
            subId,
            <String, dynamic>{
              'search': 'a',
              'limit': 1,
            },
          ]);
        });
    final since =
        (DateTime.now().millisecondsSinceEpoch ~/ 1000) + 31557600; // +1y
    _send([
      'REQ',
      subId,
      <String, dynamic>{
        'kinds': [1],
        'since': since,
        'limit': 1,
      },
    ]);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await eoseSub.cancel();
      await closedSub.cancel();
      _send(['CLOSE', subId]);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _sub?.cancel();
    await _channel?.sink.close();
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _closed.close();
    await _oks.close();
    await _auths.close();
  }
}
