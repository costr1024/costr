// Standalone recovery tool (NOT shipped): for every NIP-51 kind-30000
// follow set authored by the nsec's pubkey whose name tag was stripped by
// an earlier Costr republish, rebuild a corrected event that restores the
// human-readable name + metadata (taken from the Amethyst original still
// living on some relays) while keeping the NEWEST p-roster, then re-sign
// with created_at = now (so it wins as the newest replaceable version) and
// publish to the relays that still carry the lists.
//
//   dart run tool/repair_lists.dart nsec1...            # dry-run: print only
//   dart run tool/repair_lists.dart nsec1... --publish   # actually publish
//
// Reuses the app's pure-Dart layers (nip19 bech32, bip340). Signing is
// reimplemented here (computeId + bip340.sign) because lib/models/event.dart
// pulls in package:flutter, which isn't available to `dart run`. CLI
// diagnostics → stdout printing is intentional.

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
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://nostr.mom',
  'wss://offchain.pub',
  'wss://relay.nostr.band',
  'wss://nostr.wine',
  'wss://auth.nostr1.com',
];

/// metadata tags we carry over from the Amethyst original (anything that
/// isn't p / client / d — d is kept from the list's own UUID).
const _metadataKeys = <String>{'name', 'alt', 'description', 'image'};

class RawEvent {
  RawEvent(this.id, this.d, this.created, this.tags, this.from);
  final String id;
  final String d;
  final int created;
  final List<List<dynamic>> tags;
  final String from;
}

String _canonicalId(String pubkey, int created, int kind, List tags, String content) {
  final serialized = jsonEncode(<dynamic>[0, pubkey, created, kind, tags, content]);
  return sha256.convert(utf8.encode(serialized)).toString();
}

Future<void> main(List<String> args) async {
  final publish = args.contains('--publish');
  final nsecArgs = args.where((a) => !a.startsWith('--')).toList();
  if (nsecArgs.isEmpty) {
    print('usage: dart run tool/repair_lists.dart nsec1... [--publish]');
    exit(1);
  }
  final privHex = nsecToHex(nsecArgs.first.trim());
  final pubHex = bip340.getPublicKey(privHex).toLowerCase();
  print('pubkey = $pubHex  (npub ${hexToNpub(pubHex)})');
  print(publish ? 'MODE = PUBLISH' : 'MODE = DRY-RUN (no publish)');
  print('');

  // 1. Fetch ALL kind-30000 by this author from a broad relay set.
  final req = jsonEncode([
    'REQ',
    'repair-fetch',
    {'kinds': [30000], 'authors': [pubHex]},
  ]);
  final byD = <String, List<RawEvent>>{};
  final sockets = <WebSocket>[];
  var pending = 0;
  var doneFetch = false;

  void finishFetch() {
    if (doneFetch) return;
    doneFetch = true;
    _summarizeAndAct(byD, pubHex, privHex, publish, sockets);
  }

  for (final url in relays) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(url, headers: {'User-Agent': 'costr-repair/1.0'})
          .timeout(const Duration(seconds: 5));
      sockets.add(ws);
      pending++;
    } catch (e) {
      continue;
    }
    ws.add(req);
    ws.listen(
      (msg) {
        try {
          final list = jsonDecode(msg as String) as List;
          if (list.first == 'EVENT') {
            final ev = (list[2] as Map).cast<String, dynamic>();
            String? d;
            for (final t in (ev['tags'] as List).cast<List>()) {
              if (t.isNotEmpty && t[0] == 'd' && t[1] is String) {
                d = t[1] as String;
                break;
              }
            }
            if (d == null || d.isEmpty) return; // default list — skip
            byD.putIfAbsent(d, () => []).add(
              RawEvent(ev['id'] as String, d, (ev['created_at'] as num).toInt(),
                  (ev['tags'] as List).cast<List<dynamic>>().toList(), url),
            );
          } else if (list.first == 'OK') {
            print('  [$url] OK accepted=${list[2]} msg=${list[3]} '
                '(id=${(list[1] as String).substring(0, 12)}…)');
          } else if (list.first == 'NOTICE') {
            print('  [$url] NOTICE: ${list[1]}');
          } else if (list.first == 'CLOSED') {
            print('  [$url] CLOSED: ${list[2]}');
          }
        } catch (_) {}
      },
      onError: (Object e) => print('  [$url] stream error: $e'),
      onDone: () {
        pending--;
        if (pending <= 0) finishFetch();
      },
      cancelOnError: true,
    );
  }
  if (pending == 0) {
    print('no relay connected');
    exit(1);
  }
  await Future<void>.delayed(const Duration(seconds: 12));
  finishFetch();
}

Future<void> _summarizeAndAct(
  Map<String, List<RawEvent>> byD,
  String pubHex,
  String privHex,
  bool publish,
  List<WebSocket> sockets,
) async {
  final dValues = byD.keys.toList()..sort();
  print('=== ${dValues.length} unique named lists ===\n');
  final toPublish = <Map<String, dynamic>>[]; // signed events (object form)
  for (final d in dValues) {
    final versions = byD[d]!;
    // Newest version → p roster (current membership).
    versions.sort((a, b) => b.created.compareTo(a.created));
    final newest = versions.first;
    // A version that carries a name tag → metadata source (Amethyst original).
    RawEvent? meta;
    for (final v in versions) {
      if (v.tags.any((t) => t.isNotEmpty && t[0] == 'name' &&
          t.length > 1 && (t[1] as String).isNotEmpty)) {
        meta = v;
        break;
      }
    }
    final pRoster = newest.tags
        .where((t) => t.isNotEmpty && t[0] == 'p')
        .map((t) => t.map((e) => e.toString()).toList())
        .toList();
    final name = meta?.tags.firstWhere(
      (t) => t.isNotEmpty && t[0] == 'name',
      orElse: () => const <dynamic>['name', ''],
    )[1] as String?;

    print('d        = $d');
    print('  name   = ${name ?? "(no Amethyst original found)"}');
    print('  p count= ${pRoster.length}  (from newest @ ${newest.from}, created ${newest.created})');
    if (meta == null) {
      // No recoverable name → the user asked to delete this broken list
      // rather than keep it. Publish a NIP-09 kind-5 deletion with an `a`
      // tag for the 30000 replaceable coordinate (deletes every version
      // of this d, not just one event id) + an `e` tag for the newest id.
      final coord = '30000:$pubHex:$d';
      final delTags = <List<String>>[
        ['e', newest.id],
        ['a', coord],
        ['client', 'Costr'],
      ];
      final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final id = _canonicalId(pubHex, created, 5, delTags, '');
      final aux = HEX.encode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)));
      final sig = bip340.sign(privHex, id, aux);
      final sigOk = bip340.verify(pubHex, id, sig);
      if (!sigOk) print('  !! local sig verify FAILED for deletion $d');
      final event = <String, dynamic>{
        'id': id,
        'pubkey': pubHex,
        'created_at': created,
        'kind': 5,
        'tags': delTags,
        'content': '',
        'sig': sig,
      };
      toPublish.add(event);
      print('  PLAN   → DELETE (kind-5) coord=$coord '
          '(e=${newest.id.substring(0, 12)}…)${sigOk ? '' : ' (SIG BAD!)'}\n');
      continue;
    }
    // Build merged tags: d + metadata(name/alt/description/image) + p roster.
    final tags = <List<String>>[['d', d]];
    for (final t in meta.tags) {
      if (t.isEmpty || t[0] == 'd' || t[0] == 'p' || t[0] == 'client') continue;
      if (_metadataKeys.contains(t[0])) {
        tags.add(t.map((e) => e.toString()).toList());
      }
    }
    // Dedup metadata keys (in case multiple versions contributed).
    final seenMeta = <String>{};
    tags.removeWhere((t) =>
        t.isNotEmpty && _metadataKeys.contains(t[0]) && !seenMeta.add(t[0]));
    tags.addAll(pRoster);
    tags.add(['client', 'Costr']);

    final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = _canonicalId(pubHex, created, 30000, tags, '');
    final aux = HEX.encode(List<int>.generate(32, (_) => Random.secure().nextInt(256)));
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
    print('  PLAN   → re-publish with name="$name" '
        '(${pRoster.length} p tags), created=$created'
        '${sigOk ? '' : ' (SIG BAD!)'}\n');
  }

  if (toPublish.isEmpty) {
    print('Nothing to publish (all lists either intact or unrecoverable).');
    _cleanup(sockets);
    exit(0);
  }
  if (!publish) {
    print('=== DRY-RUN: ${toPublish.length} event(s) would be published. '
        'Re-run with --publish to send. ===');
    for (final e in toPublish) {
      print(const JsonEncoder.withIndent('  ').convert(e));
    }
    _cleanup(sockets);
    exit(0);
  }

  // PUBLISH: fire-and-forget EVENT to all connected relays (Nostr is
  // best-effort; we verify afterwards with inspect_lists.dart). The WS
  // stream is single-subscription, so we don't try to multiplex OK replies
  // here — just send, flush, and let the relays store.
  print('=== PUBLISHING ${toPublish.length} event(s) to ${sockets.length} relays ===');
  for (final event in toPublish) {
    final msg = jsonEncode(['EVENT', event]);
    for (final ws in sockets) {
      try {
        ws.add(msg);
      } catch (_) {}
    }
    print('  sent ${(event['id'] as String).substring(0, 12)}… '
        '(name=${(event['tags'] as List).firstWhere((t) => t[0] == 'name', orElse: () => ['name','?'])[1]})');
  }
  // Let the sockets flush before closing.
  await Future<void>.delayed(const Duration(seconds: 3));
  print('\n=== done: ${toPublish.length} event(s) sent. '
      'Re-run inspect_lists.dart to verify relays now carry the name tag. ===');
  _cleanup(sockets);
  exit(0);
}

void _cleanup(List<WebSocket> sockets) {
  for (final s in sockets) {
    try {
      s.close();
    } catch (_) {}
  }
}
