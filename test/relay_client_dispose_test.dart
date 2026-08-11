// Regression: RelayClient.dispose() must NEVER hang, even when the WS/TLS
// handshake never completes — the GFW pattern for blocked foreign relays
// (SYN black-holed / TLS stalled mid-handshake: the socket accepts but never
// upgrades). Before the fix, dispose() awaited sink.close(), which blocks on
// the still-pending connect future forever. Every transient-connection path
// (server discovery probes → 推荐中继 «一直加载中», RelayPool.fetchFromUrls
// outbox/profile fetches) awaits dispose, so one blocked relay wedged the
// whole operation.
import 'dart:io' show ServerSocket, Socket;

import 'package:costr/nostr/relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'dispose() returns promptly when the handshake never completes',
    () async {
      // A "black-hole" server: accepts the TCP connection, sends nothing,
      // never upgrades to WebSocket — exactly what a GFW-blocked relay looks
      // like from the client side.
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final accepted = <Socket>[];
      server.listen(accepted.add); // hold the socket open, stay silent
      addTearDown(() async {
        for (final s in accepted) {
          try {
            s.destroy();
          } catch (_) {}
        }
        await server.close();
      });

      final client = RelayClient('ws://127.0.0.1:${server.port}')
        ..connectTimeout = const Duration(milliseconds: 200);

      await client.connect();
      expect(client.isConnected, isFalse, reason: 'handshake never finished');

      // The actual regression: pre-fix this awaited sink.close() on the
      // never-ready channel and never returned. Cap it so a regression fails
      // instead of hanging the whole suite.
      await client.dispose().timeout(
        const Duration(seconds: 3),
        onTimeout: () => fail('dispose() hung on a never-ready connection'),
      );
    },
  );

  test('dispose() is safe before any connect', () async {
    final client = RelayClient('ws://127.0.0.1:1');
    await client.dispose().timeout(const Duration(seconds: 3));
  });

  test(
    'measureRtt on a never-connected client returns null, no hang',
    () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      final accepted = <Socket>[];
      server.listen(accepted.add);
      addTearDown(() async {
        for (final s in accepted) {
          try {
            s.destroy();
          } catch (_) {}
        }
        await server.close();
      });
      final client = RelayClient('ws://127.0.0.1:${server.port}')
        ..connectTimeout = const Duration(milliseconds: 150);
      await client.connect();
      expect(
        await client.measureRtt(timeout: const Duration(milliseconds: 200)),
        isNull,
      );
      await client.dispose().timeout(const Duration(seconds: 3));
    },
  );
}
