// Regression test: a relay-side CLOSED of a LIVE subscription (rate-limit,
// relay restart that kept the socket) must be re-issued with backoff instead
// of leaving the sub silently dead forever ("关注流停更，刷新无效" root cause).

import 'dart:async';

import 'package:costr/models/event.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<(String, Event)> _tagged =
      StreamController<(String, Event)>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;
  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<(String, Event)> get taggedEvents => _tagged.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;
  @override
  Stream<RelayOk> get oks => _oks.stream;
  @override
  Stream<String> get auths => _auths.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _onConnected?.call();
  }

  @override
  void request(String subId, Map<String, dynamic> filter) =>
      sent.add(['REQ', subId, filter]);
  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);
  @override
  void publish(Event event) => sent.add(['EVENT', event.toWireObject()]);
  @override
  void sendAuth(Event event) => sent.add(['AUTH', event.toWireObject()]);
  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _tagged.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  int reqCount(String subId) =>
      sent.where((f) => f[0] == 'REQ' && f[1] == subId).length;
}

void main() {
  test('CLOSED on a live sub is re-issued on the same connection', () async {
    final relay = _FakeRelay('wss://a');
    final pool = RelayPool([relay]);
    addTearDown(pool.dispose);
    await pool.connect();

    pool.request('costr:feed-me:1', {'kinds': [1], 'limit': 100});
    expect(relay.reqCount('costr:feed-me:1'), 1);

    // The relay drops the live sub (what strfry does past its sub cap).
    pool.resubscribeAfterClosed(relay, 'costr:feed-me:1');

    // Backoff starts at 2 s — the REQ must be re-sent on the same socket.
    final sw = Stopwatch()..start();
    while (relay.reqCount('costr:feed-me:1') < 2) {
      if (sw.elapsed > const Duration(seconds: 5)) {
        fail('live sub was not re-issued after relay CLOSED');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  test('CLOSED on a closeOnEose sub is NOT re-issued', () async {
    final relay = _FakeRelay('wss://a');
    final pool = RelayPool([relay]);
    addTearDown(pool.dispose);
    await pool.connect();

    pool.request('costr:one-shot:1', {'kinds': [3]}, closeOnEose: true);
    pool.resubscribeAfterClosed(relay, 'costr:one-shot:1');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(relay.reqCount('costr:one-shot:1'), 1);
  });

  test('CLOSED of an already-closed sub is ignored', () async {
    final relay = _FakeRelay('wss://a');
    final pool = RelayPool([relay]);
    addTearDown(pool.dispose);
    await pool.connect();

    pool.request('costr:live:1', {'kinds': [1]});
    pool.closeSubscription('costr:live:1');
    pool.resubscribeAfterClosed(relay, 'costr:live:1');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(relay.reqCount('costr:live:1'), 1);
  });
}
