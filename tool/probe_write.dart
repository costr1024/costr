// Probe a relay's WRITE path exactly the way RelayPool does it:
//   1. EVENT (kind 30078 probe event, d=costr-probe-*, expiration +1h)
//   2. capture OK / AUTH frames (NIP-42 challenge?)
//   3. answer AUTH with kind-22242 (Costr tag shape: relay + challenge)
//   4. re-send EVENT (post-auth) → capture OK
//   5. re-send EVENT again (DUPLICATE) → capture OK reason
//   6. NIP-09 delete the probe event
// Usage: dart run tool/probe_write.dart <nsec> [wss-url ...]
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
  int? createdAt,
}) {
  final ts = createdAt ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
  final canonical = jsonEncode([0, pub, ts, kind, tags, content]);
  final id = sha256Hex(canonical);
  final aux = HEX.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
  final sig = bip340.sign(priv, id, aux);
  return {
    'id': id,
    'pubkey': pub,
    'created_at': ts,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
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

  final probeEv = sign(priv, pub,
      kind: 30078,
      content: 'costr write-path probe (auto-deleted)',
      tags: [
        ['d', 'costr-probe-${DateTime.now().millisecondsSinceEpoch}'],
        ['expiration', '${(DateTime.now().millisecondsSinceEpoch ~/ 1000) + 3600}'],
      ]);
  final evId = probeEv['id'] as String;

  Future<void> wait(Duration d) => Future<void>.delayed(d);

  // Step 1: first EVENT.
  print('STEP 1: send EVENT ${evId.substring(0, 12)}…');
  ws.add(jsonEncode(['EVENT', probeEv]));
  await wait(const Duration(seconds: 4));

  // Step 2: answer any AUTH challenge that arrived.
  // (frames already printed; parse from a fresh subscribe not possible — scan
  // buffered output instead: simplest is to just try challenge flow.)
  // We re-request a challenge by listening for AUTH frames live below.
  print('STEP 2: watch for late AUTH challenge 2s more…');
  String? challenge;
  final sub = frames.stream.listen((s) {
    try {
      final l = jsonDecode(s) as List;
      if (l.first == 'AUTH') challenge = l[1].toString();
    } catch (_) {}
  });
  await wait(const Duration(seconds: 2));
  await sub.cancel();

  if (challenge != null) {
    final authEv = sign(priv, pub,
        kind: 22242,
        content: '',
        tags: [
          ['relay', url],
          ['challenge', challenge!],
        ]);
    print('STEP 3: send AUTH (kind 22242) for challenge ${challenge!.substring(0, 8)}…');
    ws.add(jsonEncode(['AUTH', authEv]));
    await wait(const Duration(seconds: 3));

    print('STEP 4: re-send EVENT after auth');
    ws.add(jsonEncode(['EVENT', probeEv]));
    await wait(const Duration(seconds: 4));
  } else {
    print('STEP 3: no AUTH challenge seen');
  }

  print('STEP 5: re-send EVENT again (duplicate test)');
  ws.add(jsonEncode(['EVENT', probeEv]));
  await wait(const Duration(seconds: 4));

  print('STEP 6: NIP-09 delete probe event');
  final del = sign(priv, pub,
      kind: 5,
      content: 'probe cleanup',
      tags: [
        ['e', evId],
      ]);
  ws.add(jsonEncode(['EVENT', del]));
  await wait(const Duration(seconds: 3));

  try {
    await ws.close();
  } catch (_) {}
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/probe_write.dart <nsec> [wss-url ...]');
    exit(2);
  }
  final priv = nsecToHex(args.first);
  final pub = bip340.getPublicKey(priv);
  final urls = args.length > 1
      ? args.sublist(1)
      : ['wss://relay.bostr.online'];
  for (final u in urls) {
    await probe(u, priv, pub);
  }
  exit(0);
}
