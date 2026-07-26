/// Minimal relay client.
///
/// Opens a WebSocket to a Nostr relay and listens for `EVENT` messages.
/// This is a thin foundation — pool management, REQ filters, reconnect logic,
/// and signature verification arrive with the first real feature.
library;

import 'dart:convert';
import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../models/event.dart';

class RelayClient {
  RelayClient(this.url);

  final String url;
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  StreamController<Event>? _events;

  /// Broadcast stream of text-note (kind 1) events received from this relay.
  Stream<Event> get events => _events?.stream ?? const Stream.empty();

  Future<void> connect() async {
    _events = StreamController<Event>.broadcast();
    _channel = WebSocketChannel.connect(Uri.parse(url));
    _sub = _channel!.stream.listen(_onData, onError: (e) {
      _events?.addError(e);
    }, onDone: () {
      _events?.close();
    });
  }

  void _onData(dynamic data) {
    try {
      final msg = jsonDecode(data as String) as List;
      // ["EVENT", <subscription id>, <event array>]
      if (msg case ['EVENT', String _, List<dynamic> eventList]) {
        final event = Event.fromList(eventList);
        if (event.isTextNote) {
          _events?.add(event);
        }
      }
    } catch (_) {
      // Ignore malformed messages — relays sometimes send notices or OK frames.
    }
  }

  /// Send a REQ message. A real implementation builds filters from the caller.
  void request(String subscriptionId, {List<String>? authors}) {
    final filter = <String, dynamic>{'kinds': [Event.kindTextNote]};
    if (authors != null && authors.isNotEmpty) {
      filter['authors'] = authors;
    }
    _channel?.sink.add(jsonEncode(['REQ', subscriptionId, filter]));
  }

  Future<void> close() async {
    await _sub?.cancel();
    await _channel?.sink.close();
    await _events?.close();
    _channel = null;
    _sub = null;
    _events = null;
  }
}
