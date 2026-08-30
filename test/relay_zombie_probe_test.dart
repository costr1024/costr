// Regression test: a connected-but-silent (zombie) socket must be detected
// by the pool's liveness probe and force-reconnected, and the reconnect must
// re-issue every active subscription ("关注流停更" root cause: half-dead TCP
// paths report isConnected forever and nothing re-dials them in foreground).

import 'dart:convert';
import 'dart:io';

import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('zombie socket is probed, dropped, and its subs re-issued', () async {
    // Local relay that accepts the WebSocket but NEVER answers any REQ —
    // exactly a socket whose peer went silently away.
    final received = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((msg) {
        final m = jsonDecode(msg as String) as List;
        if (m.isNotEmpty && m[0] == 'REQ') received.add(m[1] as String);
        // Zombie: no EVENT / EOSE / OK ever.
      });
    });

    final pool = RelayPool([RelayClient('ws://127.0.0.1:${server.port}')]);
    addTearDown(pool.dispose);
    pool.idleProbeThreshold = const Duration(milliseconds: 300);
    pool.probeTimeout = const Duration(seconds: 1);
    await pool.connect();
    expect(pool.states.single.status, RelayStatus.connected);

    pool.request('costr:live:1', {'kinds': [1], 'limit': 100});
    // The REQ crosses a real socket — poll until the server sees it.
    var sw = Stopwatch()..start();
    while (!received.contains('costr:live:1')) {
      if (sw.elapsed > const Duration(seconds: 5)) {
        fail('initial REQ never reached the relay');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    // Let the socket go silent past the threshold, then run the probe.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    pool.checkLiveness();

    // The probe gets no answer → dropForReconnect → backoff reconnect →
    // on-connected hook re-issues 'costr:live:1' on the fresh socket.
    final sw2 = Stopwatch()..start();
    while (received.where((s) => s == 'costr:live:1').length < 2) {
      if (sw2.elapsed > const Duration(seconds: 10)) {
        fail('zombie socket was not re-dialed; live sub never re-issued');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  test('healthy (answering) socket is NOT dropped by the probe', () async {
    // Local relay that EOSEs every REQ — the probe succeeds and the socket
    // must stay on its original connection (no second handshake).
    var handshakes = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      handshakes++;
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((msg) {
        final m = jsonDecode(msg as String) as List;
        if (m.isNotEmpty && m[0] == 'REQ') {
          ws.add(jsonEncode(['EOSE', m[1]]));
        }
      });
    });

    final pool = RelayPool([RelayClient('ws://127.0.0.1:${server.port}')]);
    addTearDown(pool.dispose);
    pool.idleProbeThreshold = const Duration(milliseconds: 200);
    pool.probeTimeout = const Duration(seconds: 2);
    await pool.connect();
    expect(handshakes, 1);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    pool.checkLiveness();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(handshakes, 1, reason: 'a live socket must not be re-dialed');
  });
}
