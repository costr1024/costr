// Standalone tombstone tool (NOT shipped): republish a NIP-51 kind-30000
// follow set as an EMPTY, clearly-labeled "deleted" stub so Amethyst's filter
// picker (which shows unloaded addressable stubs by raw d-tag UUID) displays
// "(已删除)" instead of the迷惑 UUID. The `d` is preserved verbatim so the
// new event replaces (not forks) the old list; p tags are emptied so the list
// is harmless. This is a WORKAROUND for Amethyst's gap (it doesn't subscribe
// to the user's own kind-5 deletions, so a-coord deletes are lost on cache
// wipe) — see delete_follow_set.dart for the proper (but Amethyst-side-gated)
// NIP-09 path.
//
//   dart run tool/tombstone_follow_set.dart nsec1... <d-tag> [<d-tag> ...]            # dry-run
//   dart run tool/tombstone_follow_set.dart nsec1... <d-tag> [<d-tag> ...] --publish  # actually publish
//
// Signing reimplemented here (computeId + bip340.sign) because
// lib/models/event.dart pulls in package:flutter, unavailable to `dart run`.
// CLI diagnostics → stdout printing is intentional.

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;
import 'dart:math' show Random;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';
import 'package:crypto/crypto.dart';
import 'package:hex/hex.dart';

const relays = <String>[
  'wss://damus.bostr.online','wss://relay.gulugulu.moe','wss://relay.ditto.pub',
  'wss://relay.bostr.online','wss://wheat.happytavern.co','wss://relay.nostr.net',
  'wss://relay.0xchat.com','wss://top.testrelay.top','wss://bostr.online',
  'wss://bostr.shop','wss://relay.artiostr.ch','wss://nostr.data.haus',
  'wss://asia.vectorapp.io/nostr','wss://relay.nostrzh.org',
  'wss://relay.nostrzh.org/inbox','wss://relay.damus.io','wss://nos.lol',
  'wss://nostr.mom','wss://offchain.pub','wss://relay.nostr.band',
  'wss://nostr.wine','wss://nostr.oxtr.dev','wss://auth.nostr1.com',
  'wss://user.kindpag.es','wss://api.nostr.band','wss://indexer.coracle.social',
];

String _canonicalId(String pubkey, int created, int kind, List tags, String content) {
  final serialized = jsonEncode(<dynamic>[0, pubkey, created, kind, tags, content]);
  return sha256.convert(utf8.encode(serialized)).toString();
}

Future<void> main(List<String> args) async {
  final publish = args.contains('--publish');
  final rest = args.where((a) => !a.startsWith('--')).toList();
  if (rest.length < 2) {
    print('usage: dart run tool/tombstone_follow_set.dart nsec1... '
        '<d-tag> [<d-tag> ...] [--publish]');
    print('  Republishes each kind-30000 as an empty "(已删除)" stub (d preserved).');
    print('  Dry-run by default; add --publish to send.');
    exit(1);
  }
  final privHex = nsecToHex(rest.first.trim());
  final pubHex = bip340.getPublicKey(privHex).toLowerCase();
  final dTags = rest.sublist(1);
  print('pubkey = $pubHex');
  print(publish ? 'MODE = PUBLISH' : 'MODE = DRY-RUN (no publish)');
  for (final d in dTags) {
    print('  • $d');
  }
  print('');

  final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final toPublish = <Map<String, dynamic>>[];
  for (final d in dTags) {
    // Tombstone: same d (replace, not fork), name="(已删除)", no p tags.
    final tags = <List<String>>[
      ['d', d],
      ['name', '(已删除)'],
      ['client', 'Costr'],
    ];
    final id = _canonicalId(pubHex, created, 30000, tags, '');
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
      'kind': 30000,
      'tags': tags,
      'content': '',
      'sig': sig,
    };
    toPublish.add(event);
    print('PLAN → TOMBSTONE d=$d name=(已删除) p=0 id=${id.substring(0, 12)}…'
        '${sigOk ? '' : ' (SIG BAD!)'}');
  }

  if (!publish) {
    print('\n=== DRY-RUN: ${toPublish.length} tombstone(s) would be published. '
        'Re-run with --publish to send. ===');
    for (final e in toPublish) {
      print(const JsonEncoder.withIndent('  ').convert(e));
    }
    exit(0);
  }

  print('\n=== PUBLISHING ${toPublish.length} tombstone(s) to ${relays.length} relays ===');
  final sockets = <WebSocket>[];
  var pending = 0;
  for (final url in relays) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(url, headers: {'User-Agent': 'costr-tomb/1.0'})
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
        '(d=${(event['tags'] as List).firstWhere((t) => t[0] == 'd')[1]})');
  }
  final deadline = DateTime.now().millisecondsSinceEpoch + 5000;
  while (pending > 0 && DateTime.now().millisecondsSinceEpoch < deadline) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  for (final s in sockets) {
    try {
      s.close();
    } catch (_) {}
  }
  print('\n=== done: ${toPublish.length} tombstone(s) sent. '
      'Re-open Amethyst (sync) — the chips should read "(已删除)" instead of '
      'the raw UUID once the new kind-30000 loads. ===');
  exit(0);
}
