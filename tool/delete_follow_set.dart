// Standalone cleanup tool (NOT shipped): publish proper NIP-09 kind-5
// deletions for kind-30000 follow sets whose `d` you pass on the CLI. Uses
// an `a` coordinate tag (30000:pubkey:d) — the CORRECT form for
// parameterized-replaceable events, which deletes every version of the
// coordinate. Amethyst's own delete only sends an `e` (event-id) tag, which
// is ineffective for kind-30000 and is why those UUID-named ghost lists
// linger in Amethyst's local cache. This tool fires the form Amethyst will
// honor on next sync.
//
// The lists need not be on the network — they may exist only in Amethyst's
// local cache. As long as Amethyst receives this kind-5 and matches the `a`
// coordinate against its cache, it removes the list. Published to the user's
// own NIP-65 relays (what Amethyst reads for the user's events) + a broad set.
//
//   dart run tool/delete_follow_set.dart nsec1... <d-tag> [<d-tag> ...]            # dry-run
//   dart run tool/delete_follow_set.dart nsec1... <d-tag> [<d-tag> ...] --publish  # actually publish
//
// Reuses the app's pure-Dart layers (nip19 bech32, bip340). Signing is
// reimplemented here (computeId + bip340.sign) because lib/models/event.dart
// pulls in package:flutter, unavailable to `dart run`. CLI diagnostics →
// stdout printing is intentional.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;
import 'dart:math' show Random;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';
import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';

// The user's own NIP-65 declared relays (what Amethyst reads for their own
// events) + a broad fallback. Keep in sync with the live list if it changes
// — re-run recover_lists.dart / probe_real.dart to see the current set.
const relays = <String>[
  // User's REAL account NIP-65 read/write relays (Amethyst syncs the user's
  // own events here, so this is where a-coordinate deletions must land).
  'wss://damus.bostr.online',
  'wss://relay.gulugulu.moe',
  'wss://relay.ditto.pub',
  'wss://relay.bostr.online',
  'wss://wheat.happytavern.co',
  'wss://relay.nostr.net',
  'wss://relay.0xchat.com',
  'wss://top.testrelay.top',
  'wss://bostr.online',
  'wss://bostr.shop',
  'wss://relay.artiostr.ch',
  'wss://nostr.data.haus',
  'wss://asia.vectorapp.io/nostr',
  'wss://relay.nostrzh.org',
  'wss://relay.nostrzh.org/inbox',
  // Broad fallback (Amethyst's bundled defaults + common relays).
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://nostr.mom',
  'wss://offchain.pub',
  'wss://relay.nostr.band',
  'wss://nostr.wine',
  'wss://nostr.oxtr.dev',
  'wss://auth.nostr1.com',
  'wss://user.kindpag.es',
  'wss://api.nostr.band',
  'wss://indexer.coracle.social',
];

String _canonicalId(String pubkey, int created, int kind, List tags, String content) {
  final serialized = jsonEncode(<dynamic>[0, pubkey, created, kind, tags, content]);
  return sha256.convert(utf8.encode(serialized)).toString();
}

Future<void> main(List<String> args) async {
  final publish = args.contains('--publish');
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.length < 2) {
    print('usage: dart run tool/delete_follow_set.dart nsec1... '
        '<d-tag> [<d-tag> ...] [--publish]');
    print('  Publishes a NIP-09 kind-5 with a=30000:pubkey:d for each d-tag.');
    print('  Dry-run by default; add --publish to send.');
    exit(1);
  }
  final privHex = nsecToHex(rest.first.trim());
  final pubHex = bip340.getPublicKey(privHex).toLowerCase();
  final dTags = rest.sublist(1);
  print('pubkey = $pubHex  (npub ${hexToNpub(pubHex)})');
  print(publish ? 'MODE = PUBLISH' : 'MODE = DRY-RUN (no publish)');
  print('deleting ${dTags.length} d-tag(s):');
  for (final d in dTags) {
    print('  • $d');
  }
  print('');

  final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final toPublish = <Map<String, dynamic>>[];
  for (final d in dTags) {
    final coord = '30000:$pubHex:$d';
    final tags = <List<String>>[
      ['a', coord],
      ['client', 'Costr'],
    ];
    final id = _canonicalId(pubHex, created, 5, tags, '');
    final aux = HEX.encode(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    final sig = bip340.sign(privHex, id, aux);
    final sigOk = bip340.verify(pubHex, id, sig);
    if (!sigOk) print('  !! local sig verify FAILED for $d');
    final event = <String, dynamic>{
      'id': id,
      'pubkey': pubHex,
      'created_at': created,
      'kind': 5,
      'tags': tags,
      'content': '',
      'sig': sig,
    };
    toPublish.add(event);
    print('PLAN → DELETE coord=$coord id=${id.substring(0, 12)}…'
        '${sigOk ? '' : ' (SIG BAD!)'}');
  }

  if (!publish) {
    print('\n=== DRY-RUN: ${toPublish.length} deletion(s) would be published. '
        'Re-run with --publish to send. ===');
    for (final e in toPublish) {
      print(const JsonEncoder.withIndent('  ').convert(e));
    }
    exit(0);
  }

  // PUBLISH: fire-and-forget EVENT to all connected relays.
  print('\n=== PUBLISHING ${toPublish.length} deletion(s) to ${relays.length} relays ===');
  final sockets = <WebSocket>[];
  var pending = 0;
  for (final url in relays) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(url, headers: {'User-Agent': 'costr-del/1.0'})
          .timeout(const Duration(seconds: 5));
      sockets.add(ws);
      pending++;
    } catch (e) {
      print('  [$url] connect failed: $e');
      continue;
    }
    ws.listen(
      (msg) {
        try {
          final list = jsonDecode(msg as String) as List;
          if (list.first == 'OK') {
            print('  [$url] OK accepted=${list[2]} id=${(list[1] as String).substring(0, 12)}…');
          } else if (list.first == 'NOTICE') {
            print('  [$url] NOTICE: ${list[1]}');
          }
        } catch (_) {}
      },
      onError: (Object e) => print('  [$url] stream error: $e'),
      onDone: () => pending--,
      cancelOnError: true,
    );
  }
  for (final event in toPublish) {
    final msg = jsonEncode(['EVENT', event]);
    for (final ws in sockets) {
      try {
        ws.add(msg);
      } catch (_) {}
    }
    print('  sent ${(event['id'] as String).substring(0, 12)}… '
        '(a=${(event['tags'] as List).firstWhere((t) => t[0] == 'a')[1]})');
  }
  // Let sockets flush + collect OK replies.
  final deadline = DateTime.now().millisecondsSinceEpoch + 5000;
  while (pending > 0 &&
      DateTime.now().millisecondsSinceEpoch < deadline) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  for (final s in sockets) {
    try {
      s.close();
    } catch (_) {}
  }
  print('\n=== done: ${toPublish.length} deletion(s) sent. '
      'Re-open Amethyst (force a sync) — it should drop the lists on receipt '
      'of the a-coordinate kind-5. ===');
  exit(0);
}
