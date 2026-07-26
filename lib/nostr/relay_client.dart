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

  Future<void> connect();

  /// Send a `["REQ", subId, filter]`.
  void request(String subId, Map<String, dynamic> filter);

  /// Send a `["CLOSE", subId]`.
  void closeSubscription(String subId);

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

  void Function()? _onConnected;
  void Function()? _onDisconnected;

  // Long-lived broadcast controllers — survive reconnect (regression fix R3).
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices = StreamController<String>.broadcast();

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;
  @override
  bool get isConnected => _connected;
  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) => _onDisconnected = cb;

  @override
  Future<void> connect() async {
    if (_disposed || _connected) return;
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      _sub = channel.stream.listen(
        _onData,
        onError: (Object _) => _handleDisconnect(),
        onDone: _handleDisconnect,
      );
      _connected = true;
      _backoffMs = 1000; // reset on success
      _onConnected?.call();
    } catch (_) {
      _scheduleReconnect();
    }
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
    _reconnectTimer = Timer(
      Duration(milliseconds: _backoffMs),
      () {
        _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
        connect();
      },
    );
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
      }
      // 'OK' frames are publish acks — v1 doesn't publish, ignore.
    } catch (_) {
      // Malformed frame — ignore. Relays occasionally send odd payloads.
    }
  }

  @override
  void request(String subId, Map<String, dynamic> filter) =>
      _send(['REQ', subId, filter]);

  @override
  void closeSubscription(String subId) => _send(['CLOSE', subId]);

  void _send(List<dynamic> message) {
    _channel?.sink.add(jsonEncode(message));
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
  }
}
