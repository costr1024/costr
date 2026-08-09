// Read+write probe for candidate relays (real account). Verifies a relay can
// both SERVE reads (REQ → EVENT/EOSE) and ACCEPT writes (EVENT → OK true),
// plus how it answers a duplicate re-send, before it is added to the defaults.
// Usage: dart run tool/probe_rw.dart <nsec> [wss-url ...]
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;
import 'dart:math';

import 'package:bip340/bip340.dart' as bip340;
import 'package:crypto/crypto.dart' as crypto;
import 'package:costr/utils/nip19.dart';
import 'package:hex/hex.dart';

String sha256Hex(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

Map<String, dynamic> sign(
  String priv,
  String pub, {
  required int kind,
  required String content,
  List<List<String>> tags = const [],
}) {
  final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final id = sha256Hex(jsonEncode([0, pub, ts, kind, tags, content]));
  final aux = HEX.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
  return {
    'id': id,
    'pubkey': pub,
    'created_at': ts,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': bip340.sign(priv, id, aux),
  };
}

Future<void> probe(String url, String priv, String pub) async {
  print('\n========== $url ==========');
  WebSocket ws;
  try {
    ws = await WebSocket.connect(url).timeout(const Duration(seconds: 8));
  } catch (e) {
    print('CONNECT FAILED: $e');
    return;
  }
  final frames = StreamController<String>.broadcast();
  ws.listen((m) {
    final s = m.toString();
    frames.add(s);
    print('  << $s');
  }, onError: (Object e) => print('  !! ws error: $e'), onDone: () => print('  !! ws closed'));
  Future<void> wait(Duration d) => Future<void>.delayed(d);

  // READ: REQ kind-1 limit 1 → alive = any EVENT or EOSE within 5s.
  print('READ: REQ {kinds:[1], limit:1}');
  var gotEvent = false, gotEose = false;
  final rsub = frames.stream.listen((s) {
    try {
      final l = jsonDecode(s) as List;
      if (l.first == 'EVENT') gotEvent = true;
      if (l.first == 'EOSE') gotEose = true;
    } catch (_) {}
  });
  ws.add(jsonEncode(['REQ', 'rd', {'kinds': [1], 'limit': 1}]));
  await wait(const Duration(seconds: 5));
  await rsub.cancel();
  print('  READ -> ${(gotEvent || gotEose) ? "OK" : "FAIL"} (event=$gotEvent eose=$gotEose)');
  ws.add(jsonEncode(['CLOSE', 'rd']));

  // WRITE: kind-30078 probe event (auto-expiring) + duplicate + NIP-09 delete.
  final ev = sign(priv, pub,
      kind: 30078,
      content: 'costr rw-probe (auto-deleted)',
      tags: [
        ['d', 'costr-rw-${DateTime.now().millisecondsSinceEpoch}'],
        ['expiration', '${(DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600}'],
      ]);
  final id = ev['id'] as String;
  print('WRITE: EVENT ${id.substring(0, 12)}…');
  ws.add(jsonEncode(['EVENT', ev]));
  await wait(const Duration(seconds: 4));
  print('WRITE duplicate: re-send same event');
  ws.add(jsonEncode(['EVENT', ev]));
  await wait(const Duration(seconds: 4));
  print('DELETE: kind-5 cleanup');
  final del = sign(priv, pub, kind: 5, content: 'probe cleanup', tags: [['e', id]]);
  ws.add(jsonEncode(['EVENT', del]));
  await wait(const Duration(seconds: 3));
  try { await ws.close(); } catch (_) {}
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/probe_rw.dart <nsec> [wss-url ...]');
    exit(2);
  }
  final priv = nsecToHex(args.first);
  final pub = bip340.getPublicKey(priv);
  for (final u in args.sublist(1)) {
    await probe(u, priv, pub);
  }
  exit(0);
}
