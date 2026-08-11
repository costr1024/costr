// Regression test: a relay that CLOSEs a subscription (e.g. relay.ditto.pub
// answers "rate-limited: too many subscriptions" past ~20 open subs) must
// still count as "answered" for every "wait until all relays respond"
// consumer. RelayClient therefore synthesizes an EOSE for the CLOSED sub
// (non-rtt subs only) — without it, id-lookups for events that live ONLY on
// such a relay sat out the full timeout and resolved null, so thread parents
// on bridge relays never loaded ("桥接 relay 上的帖子看不到父帖" bug).

import 'dart:convert';
import 'dart:io';

import 'package:costr/nostr/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late List<WebSocket> sockets;

  setUp(() async {
    sockets = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      ws.listen((dynamic raw) {
        final msg = jsonDecode(raw as String) as List<dynamic>;
        if (msg[0] == 'REQ') {
          // Reject the subscription instead of answering it — exactly what
          // relay.ditto.pub does when the per-connection sub cap is hit.
          ws.add(
            jsonEncode([
              'CLOSED',
              msg[1],
              'rate-limited: too many subscriptions',
            ]),
          );
        }
      });
    });
  });

  tearDown(() async {
    for (final ws in sockets) {
      await ws.close();
    }
    await server.close(force: true);
  });

  test(
    'relay-CLOSED sub emits a synthesized EOSE so waiters can settle',
    () async {
      final client = RelayClient('ws://127.0.0.1:${server.port}');
      addTearDown(client.dispose);
      await client.connect();
      expect(client.isConnected, isTrue);

      final eoseSeen = client.eose.first;
      final closedSeen = client.closed.first;
      client.request('costr:note:7', <String, dynamic>{
        'ids': ['x' * 64],
      });

      expect(
        await eoseSeen.timeout(const Duration(seconds: 5)),
        'costr:note:7',
        reason: 'CLOSED must synthesize an EOSE for the rejected sub',
      );
      final closed = await closedSeen.timeout(const Duration(seconds: 5));
      expect(closed.$1, 'costr:note:7');
      expect(closed.$2, contains('rate-limited'));
    },
  );

  test('rtt-probe subs are excluded from the CLOSED->EOSE synthesis', () async {
    final client = RelayClient('ws://127.0.0.1:${server.port}');
    addTearDown(client.dispose);
    await client.connect();

    final eoseSeen = client.eose.first;
    final closedSeen = client.closed.first;
    client.request('rtt3', <String, dynamic>{
      'ids': ['y' * 64],
    });

    // CLOSED still surfaces on the dedicated stream (measureRtt relies on it
    // for its search-filter retry)...
    final closed = await closedSeen.timeout(const Duration(seconds: 5));
    expect(closed.$1, 'rtt3');
    // ...but NO synthesized EOSE is emitted (it would short-circuit the RTT
    // probe's retry logic).
    await expectLater(
      eoseSeen.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => 'timeout',
      ),
      completion('timeout'),
    );
  });
}
