// Broad recovery probe: find ALL of the user's kind-30000 follow sets,
// kind-30015 interest sets, AND kind-10015 (single-instance interests, where
// Amethyst likely stores followed hashtags) across a large relay set.
// Prints full d-tags, names, t-tags, p-counts, and hosting relays.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket, exit;

import 'package:bip340/bip340.dart' as bip340;
import 'package:costr/utils/nip19.dart';

const relays = <String>[
  // user NIP-65
  'wss://damus.bostr.online','wss://relay.gulugulu.moe','wss://relay.ditto.pub',
  'wss://relay.bostr.online','wss://multiplexer.huszonegy.world',
  'wss://relay.nostr.net','wss://relay.0xchat.com','wss://top.testrelay.top',
  // amethyst-ish / common defaults
  'wss://relay.damus.io','wss://nos.lol','wss://nostr.mom','wss://offchain.pub',
  'wss://relay.nostr.band','wss://nostr.wine','wss://auth.nostr1.com',
  'wss://relay.snort.social','wss://relay.primal.net','wss://nostr.bitcoiner.social',
  'wss://nostr.oxtr.dev','wss://relay.current.fyi','wss://relay.nostrid.com',
  'wss://nostr.swissbitcoin.org','wss://nostr.land','wss://relay.nostr.bg',
  'wss://nostr.mado.io','wss://relay.bolisbrew.com','wss://relay.kronk.com',
  'wss://nostr.realyan.com','wss://jiggyt.page','wss://nostr.coollr.com',
  'wss://nostr.thingmgr.net','wss://relay.lex.is','wss://relay.farside.link',
  'wss://nostr.openchain.fr','wss://relay.nostr.ro','wss://nostr.flynode.net',
  'wss://relay.pedyax.com','wss://relay.n0565835.com','wss://nostr.luige.im',
  'wss://relay.nostrgraph.net','wss://nostr.zebloid.com','wss://relay.developer.li',
  'wss://nostr.1711.home.pl','wss://relay.czs.tencent.construction',
  'wss://relay.nostr.ventsare.io','wss://relay.zerodao.com',
  'wss://nostr.einexistierenderbund.de','wss://nostr.verifiedadmins.com',
  'wss://relay.stealth-finance.com','wss://nostr.1complete.cc',
  'wss://relay.0xchat.com','wss://nostr.racampeon.com.br',
  'wss://relay.dogskicks.com',
  // Index relays — crawl/index all events globally, queried by author.
  'wss://user.kindpag.es', // npub index
  'wss://api.nostr.band', 'wss://relay.nsec.app',
  'wss://relay.noswhere.com', 'wss://search.nos.today',
  'wss://relay.nsec.app', 'wss://indexer.coracle.social',
];

final seen = <String>{};
// key "k|d" → {relay → event summary}
final lists = <String, Map<String, Map<String, dynamic>>>{};

Future<void> main(List<String> args) async {
  final pubHex = bip340.getPublicKey(nsecToHex(args.first)).toLowerCase();
  print('pubkey = $pubHex\n');
  final subId = 'recover-${DateTime.now().millisecondsSinceEpoch}';
  final req = jsonEncode(['REQ', subId, {
    'authors': [pubHex],
    'kinds': [30000, 30015, 10015],
  }]);

  final sockets = <WebSocket>[];
  var pending = 0;
  var done = false;
  void finish() {
    if (done) return;
    done = true;
    print('\n=== ${lists.length} unique list/interest events ===\n');
    final keys = lists.keys.toList()..sort();
    for (final k in keys) {
      final perRelay = lists[k]!;
      final any = perRelay.values.first;
      print('kind=${any['kind']} d="${any['d']}" name="${any['name']}" '
          'p=${any['pCount']} t_tags=${any['tTags']}  on ${perRelay.length} relay(s)');
      for (final entry in perRelay.entries) {
        print('   @${entry.key}  id=${(entry.value['id'] as String).substring(0, 12)}… '
            'created=${entry.value['created']}');
      }
    }
    for (final s in sockets) { try { s.close(); } catch (_) {} }
    exit(0);
  }

  for (final url in relays) {
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(url, headers: {'User-Agent': 'costr-recover/1.0'})
          .timeout(const Duration(seconds: 5));
    } catch (_) { continue; }
    sockets.add(ws); pending++;
    ws.add(req);
    ws.listen(
      (msg) {
        try {
          final list = jsonDecode(msg as String) as List;
          if (list.first != 'EVENT') return;
          final ev = (list[2] as Map).cast<String, dynamic>();
          final id = ev['id'] as String;
          if (!seen.add(id)) return;
          final kind = ev['kind'] as int;
          String? d, name;
          final tTags = <String>[];
          var pCount = 0;
          for (final t in (ev['tags'] as List).cast<List>()) {
            if (t.isEmpty) {
              continue;
            } else if (t[0] == 'd' && d == null && t.length > 1) {
              d = t[1].toString();
            } else if (t[0] == 'name' && name == null && t.length > 1) {
              name = t[1].toString();
            } else if (t[0] == 't' && t.length > 1) {
              tTags.add(t[1].toString());
            } else if (t[0] == 'p') {
              pCount++;
            }
          }
          d ??= '(none)';
          final key = '$kind|$d';
          lists.putIfAbsent(key, () => {})[url] = {
            'kind': kind, 'id': id, 'created': ev['created_at'],
            'd': d, 'name': name, 'pCount': pCount, 'tTags': tTags,
          };
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () { pending--; if (pending <= 0) finish(); },
      cancelOnError: true,
    );
  }
  if (pending == 0) { print('no relay connected'); exit(1); }
  await Future<void>.delayed(const Duration(seconds: 15));
  finish();
}
