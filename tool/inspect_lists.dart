// Standalone diagnostics tool (NOT shipped): decode an nsec, derive the
// pubkey, and pull that author's NIP-51 list events (kind 30000 etc.) from
// the app's default relays, printing raw tags so we can see exactly where
// Amethyst stores the human-readable list name vs. the `d` identifier.
//
// Run:  dart run tool/inspect_lists.dart nsec1...
//
// Reuses the app's own pure-Dart layers (nip19 bech32, bip340 pubkey).
// Uses dart:io WebSocket (eager connect) so one bad relay can't abort all.
// CLI diagnostics → stdout printing is intentional.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';

const relays = <String>[
  'wss://damus.bostr.online',
  'wss://relay.gulugulu.moe',
  'wss://relay.ditto.pub',
  'wss://relay.bostr.online',
  'wss://wheat.happytavern.co',
  'wss://relay.nostr.net',
  'wss://relay.0xchat.com',
  'wss://top.testrelay.top',
  'wss://user.kindpag.es',
  'wss://indexer.coracle.social',
  'wss://search.nos.today',
];

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('usage: dart run tool/inspect_lists.dart nsec1...');
    exit(1);
  }
  final nsec = args.first.trim();
  final privHex = nsecToHex(nsec);
  final pubHex = bip340.getPublicKey(privHex).toLowerCase();
  print('pubkey(hex) = $pubHex');
  print('npub         = ${hexToNpub(pubHex)}');
  print('');

  final subId = 'costr-inspect-${DateTime.now().millisecondsSinceEpoch}';
  final req = jsonEncode([
    'REQ',
    subId,
    {'kinds': [30000, 30001, 30015, 30030, 39000], 'authors': [pubHex]},
  ]);

  final seen = <String>{};
  final collected = <Map<String, dynamic>>[];
  final sockets = <WebSocket>[];
  var pending = 0;
  var finished = false;

  void finish() {
    if (finished) return;
    finished = true;
    print('\n=== summary: ${collected.length} unique list events ===');
    for (final s in sockets) {
      try {
        s.close();
      } catch (_) {}
    }
    exit(0);
  }

  for (final url in relays) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(
        url,
        headers: {'User-Agent': 'costr-inspect/1.0'},
      ).timeout(const Duration(seconds: 5));
      sockets.add(ws);
      pending++;
    } catch (e) {
      print('[$url] connect failed: $e');
      continue;
    }
    print('[$url] connected');
    ws.add(req);

    ws.listen(
      (msg) {
        try {
          final list = jsonDecode(msg as String) as List;
          if (list.first == 'EVENT') {
            final ev = (list[2] as Map).cast<String, dynamic>();
            final id = ev['id'] as String;
            if (seen.contains(id)) return;
            seen.add(id);
            collected.add(ev);
            // Compact one-line summary per event.
            String? dv, nm, cl;
            for (final t in (ev['tags'] as List).cast<List>()) {
              if (t.isEmpty) continue;
              if (t[0] == 'd' && dv == null) {
                dv = '${t[1]}';
              } else if (t[0] == 'name' && nm == null) {
                nm = '${t[1]}';
              } else if (t[0] == 'client' && cl == null) {
                cl = '${t[1]}';
              }
            }
            print(
              'kind=${ev['kind']} d=$dv name=$nm client=$cl '
              'created=${ev['created_at']} @$url id=$id',
            );
          }
        } catch (_) {}
      },
      onError: (Object e) => print('[$url] stream error: $e'),
      onDone: () {
        pending--;
        if (pending <= 0) finish();
      },
      cancelOnError: true,
    );
  }

  if (pending == 0) {
    print('no relay connected');
    exit(1);
  }
  await Future<void>.delayed(const Duration(seconds: 10));
  finish();
}
