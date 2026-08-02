// Probe the real account: fetch its NIP-65 (kind-10002) relay list, then
// query those + a broad set for the newest kind-10015 (followed hashtags)
// and any kind-30000 / 30015 not seen before (e.g. the 2nd UUID list).
// Prints full tags of the newest kind-10015.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';

const seed = <String>[
  'wss://relay.gulugulu.moe','wss://nos.lol','wss://multiplexer.huszonegy.world',
  'wss://top.testrelay.top','wss://nostr.oxtr.dev','wss://damus.bostr.online',
  'wss://relay.ditto.pub','wss://relay.bostr.online','wss://relay.nostr.net',
  'wss://relay.0xchat.com','wss://relay.damus.io','wss://nostr.mom',
  'wss://offchain.pub','wss://relay.nostr.band','wss://nostr.wine',
  'wss://auth.nostr1.com','wss://user.kindpagages','wss://api.nostr.band',
  'wss://relay.nsec.app','wss://relay.noswhere.com','wss://search.nos.today',
  'wss://indexer.coracle.social','wss://relay.primal.net','wss://nostr.land',
  'wss://relay.current.fyi','wss://nostr.swissbitcoin.org','wss://nostr.mado.io',
  'wss://relay.nostr.bg','wss://relay.nostr.ro','wss://nostr.flynode.net',
];

Future<List<WebSocket>> q(List<String> urls, Map<String, dynamic> f, String label,
    {Duration wait = const Duration(seconds: 12)}) async {
  final subId = 'real-$label-${DateTime.now().millisecondsSinceEpoch}';
  final req = jsonEncode(['REQ', subId, f]);
  final socks = <WebSocket>[];
  var pending = 0;
  var done = false;
  void finish() { if (done) return; done = true; }
  for (final u in urls) {
    WebSocket? ws;
    try { ws = await WebSocket.connect(u, headers: {'User-Agent': 'costr-real/1.0'}).timeout(const Duration(seconds: 5)); }
    catch (_) { continue; }
    socks.add(ws); pending++;
    ws.add(req);
    ws.listen((m) {
      try {
        final l = jsonDecode(m as String) as List;
        if (l.first != 'EVENT') return;
        final ev = (l[2] as Map).cast<String, dynamic>();
        final id = ev['id'] as String;
        if (seen.contains(id)) return;
        seen.add(id);
        final kind = ev['kind'] as int;
        if (kind == 10002) {
          for (final t in (ev['tags'] as List).cast<List>()) {
            if (t.isNotEmpty && t[0] == 'r' && t.length > 1) {
              userRelays.putIfAbsent(t[1].toString(), () => t.length > 2 ? t[2].toString() : 'rw');
            }
          }
        } else if (kind == 10015 || kind == 30015) {
          final e = {'kind': kind, 'id': id, 'created': ev['created_at'], 'tags': ev['tags'], 'relay': u};
          final prev = interests[kind];
          if (prev == null || (ev['created_at'] as int) > (prev['created'] as int)) {
            interests[kind] = e;
          }
        } else if (kind == 30000) {
          String? d;
          for (final t in (ev['tags'] as List).cast<List>()) {
            if (t.isNotEmpty && t[0] == 'd' && t.length > 1) { d = t[1].toString(); break; }
          }
          d ??= '(none)';
          k30000[d] = {'id': id, 'created': ev['created_at'], 'tags': ev['tags'], 'relay': u};
        }
      } catch (_) {}
    }, onError: (_) {}, onDone: () { pending--; if (pending <= 0) finish(); }, cancelOnError: true);
  }
  if (pending == 0) return socks;
  await Future<void>.delayed(wait);
  finish();
  for (final s in socks) { try { s.close(); } catch (_) {} }
  return socks;
}

final seen = <String>{};
final userRelays = <String, String>{};
final interests = <int, Map<String, dynamic>>{}; // kind → newest
final k30000 = <String, Map<String, dynamic>>{}; // d → newest

Future<void> main(List<String> args) async {
  final pubHex = bip340.getPublicKey(nsecToHex(args.first)).toLowerCase();
  print('pubkey = $pubHex\n');
  // Phase 1: NIP-65 + interests + k30000 from seed set.
  await q(seed, {'authors': [pubHex], 'kinds': [10002, 10015, 30015, 30000]}, 'seed',
      wait: const Duration(seconds: 14));
  // Phase 2: query the user's own declared NIP-65 relays too (what Amethyst
  // reads for the user's own events).
  final extraN = userRelays.keys.where((u) => !seed.contains(u)).toList();
  if (extraN.isNotEmpty) {
    print('user NIP-65 relays not yet covered: $extraN\n');
    await q(extraN, {'authors': [pubHex], 'kinds': [10015, 30015, 30000]}, 'user',
        wait: const Duration(seconds: 12));
  }

  print('=== user NIP-65 (kind-10002) ===');
  userRelays.forEach((u, m) => print('  $u  [$m]'));

  print('\n=== kind-10015 (followed hashtags) — newest ===');
  final i10015 = interests[10015];
  if (i10015 == null) {
    print('  (none found)');
  } else {
    print('  id=${(i10015['id'] as String).substring(0, 12)}… created=${i10015['created']} @${i10015['relay']}');
    final tags = (i10015['tags'] as List).cast<List>();
    final tTags = tags.where((t) => t.isNotEmpty && t[0] == 't').map((t) => t.length > 1 ? t[1].toString() : '').toList();
    final other = tags.where((t) => t.isEmpty || t[0] != 't' && t[0] != 'd').map((t) => t.map((e) => e.toString()).toList()).toList();
    print('  t_tags = $tTags');
    print('  other tags = $other');
    print('  full tags = ${tags.map((t) => t.map((e) => e.toString()).toList()).toList()}');
  }

  print('\n=== kind-30015 (interest sets) — newest ===');
  final i30015 = interests[30015];
  if (i30015 == null) {
    print('  (none found)');
  } else {
    print('  id=${(i30015['id'] as String).substring(0, 12)}… created=${i30015['created']} @${i30015['relay']}');
    final tags = (i30015['tags'] as List).cast<List>();
    final tTags = tags.where((t) => t.isNotEmpty && t[0] == 't').map((t) => t.length > 1 ? t[1].toString() : '').toList();
    print('  t_tags = $tTags');
    print('  full tags = ${tags.map((t) => t.map((e) => e.toString()).toList()).toList()}');
  }

  print('\n=== kind-30000 follow sets (${k30000.length}) ===');
  for (final d in k30000.keys.toList()..sort()) {
    final e = k30000[d]!;
    final tags = (e['tags'] as List).cast<List>();
    String? name;
    for (final t in tags) { if (t.isNotEmpty && t[0] == 'name' && t.length > 1) { name = t[1].toString(); break; } }
    var p = 0; for (final t in tags) { if (t.isNotEmpty && t[0] == 'p') p++; }
    print('  d=$d  name="$name"  p=$p  created=${e['created']}  @${e['relay']}');
  }
  exit(0);
}
