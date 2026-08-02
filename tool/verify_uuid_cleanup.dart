// Post-deletion verification + kind discovery for the 2 UUID lists.
// Queries the real account's NIP-51 lists (30000/30015/30003/30002/30030/10015)
// AND kind-5 deletions across a broad relay set. Reports which kind each UUID
// list is, whether they're still on relays, and whether the deletion events
// landed.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';

const targets = {
  '020c535a-2553-4b91-b2cb-5c42de9f5858',
  'd3ce9497-6a45-4712-ac0f-fce6a02e161f',
};

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
  'wss://relay.nsec.app','wss://relay.noswhere.com','wss://search.nos.today',
  'wss://relay.primal.net','wss://nostr.land','wss://relay.current.fyi',
  'wss://nostr.swissbitcoin.org','wss://nostr.mado.io','wss://relay.nostr.bg',
  'wss://relay.nostr.ro','wss://nostr.flynode.net',
];

final seen = <String>{};
// kind|d → {relay → {id, created, name, pCount}}
final lists = <String, Map<String, Map<String, dynamic>>>{};
// deletion id → {relay, a-tags, e-tags}
final dels = <String, Map<String, dynamic>>{};

Future<void> main(List<String> args) async {
  final pubHex = bip340.getPublicKey(nsecToHex(args.first)).toLowerCase();
  print('pubkey = $pubHex\n');
  final subId = 'verify-${DateTime.now().millisecondsSinceEpoch}';
  final req = jsonEncode(['REQ', subId, {
    'authors': [pubHex],
    'kinds': [30000, 30015, 30003, 30002, 30030, 39000, 10015, 5],
  }]);
  final socks = <WebSocket>[];
  var pending = 0;
  var done = false;
  void finish() {
    if (done) return;
    done = true;
    print('=== NIP-51 lists by kind|d (${lists.length}) ===');
    for (final k in lists.keys.toList()..sort()) {
      final perRelay = lists[k]!;
      final any = perRelay.values.first;
      final isTarget = targets.any((t) => k.contains(t));
      print('${isTarget ? ">>> TARGET " : "          "}kind=${any['kind']} d="${any['d']}" '
          'name="${any['name']}" p=${any['pCount']} on ${perRelay.length} relay(s)');
      for (final entry in perRelay.entries) {
        print('     @${entry.key}  id=${(entry.value['id'] as String).substring(0, 12)}… created=${entry.value['created']}');
      }
    }
    print('\n=== kind-5 deletions (${dels.length}) ===');
    for (final id in dels.keys) {
      final d = dels[id]!;
      print('  id=${id.substring(0, 12)}… a=${d['a']} e=${d['e']} on ${d.length - 2} relay(s)');
    }
    for (final s in socks) { try { s.close(); } catch (_) {} }
    exit(0);
  }
  for (final url in relays) {
    WebSocket? ws;
    try { ws = await WebSocket.connect(url, headers: {'User-Agent': 'costr-verify/1.0'}).timeout(const Duration(seconds: 5)); }
    catch (_) { continue; }
    socks.add(ws); pending++;
    ws.add(req);
    ws.listen((m) {
      try {
        final l = jsonDecode(m as String) as List;
        if (l.first != 'EVENT') return;
        final ev = (l[2] as Map).cast<String, dynamic>();
        final id = ev['id'] as String;
        if (!seen.add(id)) return;
        final kind = ev['kind'] as int;
        if (kind == 5) {
          final tags = (ev['tags'] as List).cast<List>();
          final a = tags.where((t) => t.isNotEmpty && t[0] == 'a').map((t) => t.length > 1 ? t[1].toString() : '').toList();
          final e = tags.where((t) => t.isNotEmpty && t[0] == 'e').map((t) => t.length > 1 ? t[1].toString() : '').toList();
          final rec = dels.putIfAbsent(id, () => {'a': a, 'e': e});
          rec[url] = true;
          return;
        }
        String? d, name; var p = 0;
        for (final t in (ev['tags'] as List).cast<List>()) {
          if (t.isEmpty) continue;
          if (t[0] == 'd' && d == null && t.length > 1) {
            d = t[1].toString();
          } else if (t[0] == 'name' && name == null && t.length > 1) {
            name = t[1].toString();
          } else if (t[0] == 'p') {
            p++;
          }
        }
        d ??= '(none)';
        final key = '$kind|$d';
        lists.putIfAbsent(key, () => {})[url] = {
          'kind': kind, 'id': id, 'created': ev['created_at'], 'd': d, 'name': name, 'pCount': p,
        };
      } catch (_) {}
    }, onError: (_) {}, onDone: () { pending--; if (pending <= 0) finish(); }, cancelOnError: true);
  }
  if (pending == 0) { print('no relay'); exit(1); }
  await Future<void>.delayed(const Duration(seconds: 15));
  finish();
}
