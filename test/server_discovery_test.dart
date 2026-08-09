// Unit tests for decentralized server discovery (services/server_discovery.
// dart): pure aggregation/voting/ranking, NIP-11 parse+fetch, WS liveness
// probe, Blossom test-upload probe, 24h cache, and the recommend()
// orchestration — all with injected fakes, no network.
import 'dart:async';
import 'dart:convert';

import 'package:costr/app/server_list_rules.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:costr/services/server_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

// --- Fakes -----------------------------------------------------------------

/// Map-backed LocalCache stub. Only the methods discovery touches are
/// implemented; anything else throws via noSuchMethod (a discovery call into
/// an unstubbed method is a bug worth failing loudly).
class _FakeDb implements cache.LocalCache {
  final Map<String, String> config = {};
  final Map<int, List<cache.ReplaceableEvent>> replaceableByKind = {};

  @override
  Future<String?> readConfig(String key) async => config[key];

  @override
  Future<void> writeConfig(String key, String value) async =>
      config[key] = value;

  @override
  Future<List<String>?> readServerList(String key) async {
    final raw = config[key];
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return null;
  }

  @override
  Future<void> writeServerList(String key, List<String> urls) async =>
      config[key] = jsonEncode(urls);

  @override
  Future<List<cache.ReplaceableEvent>> queryAllReplaceableOfKind(
    int kind, {
    int limit = 500,
  }) async => (replaceableByKind[kind] ?? const []).take(limit).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

cache.ReplaceableEvent _row(String id, int kind, List<List<dynamic>> tags) =>
    cache.ReplaceableEvent(
      pubkey: 'pk-$id',
      kind: kind,
      dTag: '',
      id: id,
      createdAt: 1700000000,
      content: '',
      sig: 's',
      raw: '{}',
      tagsJson: jsonEncode(tags),
    );

enum _Reply { eose, event, nothing }

/// Fake transient WS connection for probeRelayAlive: connects iff [connects],
/// answers the probe REQ with an EOSE / one EVENT / nothing per [reply].
class _ProbeConn implements RelayConnection {
  _ProbeConn(this.url, {this.connects = true, this.reply = _Reply.eose});

  @override
  final String url;
  final bool connects;
  final _Reply reply;
  bool disposed = false;
  final List<Map<String, dynamic>> requests = [];
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  bool get isConnected => connects;

  @override
  Future<void> connect() async {}

  @override
  void request(String subId, Map<String, dynamic> filter) {
    requests.add(filter);
    scheduleMicrotask(() {
      if (disposed) return;
      switch (reply) {
        case _Reply.eose:
          _eose.add(subId);
        case _Reply.event:
          _events.add(
            Event(
              id: 'e-$subId',
              pubkey: 'p',
              createdAt: 1,
              kind: 1,
              tags: const [],
              content: '',
              sig: 's',
            ),
          );
        case _Reply.nothing:
          break;
      }
    });
  }

  @override
  void closeSubscription(String subId) {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await _events.close();
    await _eose.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// NIP-11 responder: per-host info documents; unknown host → 404.
MockClient _nip11(Map<String, Map<String, Object?>> byHost) =>
    MockClient((req) async {
      final doc = byHost[req.url.host];
      if (doc == null) return http.Response('', 404);
      return http.Response(
        jsonEncode(doc),
        200,
        headers: const {'content-type': 'application/json'},
      );
    });

/// Blossom upload responder: per-host status for PUT /upload.
MockClient _blossom(Map<String, int> statusByHost) => MockClient((req) async {
  final status = statusByHost[req.url.host] ?? 500;
  if (status == 200 || status == 201) {
    return http.Response(
      jsonEncode({'url': 'https://${req.url.host}/f.txt', 'sha256': 'x'}),
      status,
    );
  }
  return http.Response('', status);
});

ServerDiscovery _discovery(
  _FakeDb db, {
  Identity? identity,
  http.Client? httpClient,
  RelayConnection Function(String)? makeClient,
}) => ServerDiscovery(
  db: db,
  identity: identity,
  httpClient: httpClient,
  makeClient: makeClient ?? ((url) => _ProbeConn(url)),
);

// --- Tests -----------------------------------------------------------------

void main() {
  group('tag extraction', () {
    test('relayUrlsFromTags: r tags with/without markers, normalized', () {
      expect(
        relayUrlsFromTags([
          ['r', 'wss://A.example/'],
          ['r', 'wss://b.example', 'write'],
          ['r', 'https://not-a-relay.example'],
          ['p', 'deadbeef'],
          ['r'],
        ]),
        ['wss://a.example', 'wss://b.example'],
      );
    });

    test('blossomUrlsFromTags: server + r tags, https only', () {
      expect(
        blossomUrlsFromTags([
          ['server', 'HTTPS://Good.example/'],
          ['r', 'https://also.example'],
          ['server', 'http://insecure.example'],
          ['server', 'wss://wrong.example'],
        ]),
        ['https://good.example', 'https://also.example'],
      );
    });

    test('parseTagsJson: malformed JSON → empty, never throws', () {
      expect(parseTagsJson('[[["r","wss://a.example"]]'), isEmpty);
      expect(parseTagsJson('not json'), isEmpty);
      expect(parseTagsJson('[["r","wss://a.example"]]'), [
        ['r', 'wss://a.example'],
      ]);
    });
  });

  group('voteServerUrls', () {
    test('counts per event; repeats within one event vote once', () {
      expect(
        voteServerUrls([
          ['wss://a', 'wss://b'],
          ['wss://a', 'wss://a'],
          ['wss://c'],
        ]),
        {'wss://a': 2, 'wss://b': 1, 'wss://c': 1},
      );
    });
  });

  group('topServerCandidates', () {
    test('excludes configured, sorts by votes desc, caps', () {
      final votes = {
        'wss://low': 1,
        'wss://high': 5,
        'wss://mid': 3,
        'wss://configured': 9,
      };
      expect(
        topServerCandidates(votes, exclude: {'wss://configured'}, limit: 2),
        ['wss://high', 'wss://mid'],
      );
    });

    test('tie: boosted (NIP-11-free-confirmed) sorts first, then URL', () {
      final votes = {'wss://b': 2, 'wss://a': 2, 'wss://c': 2};
      expect(
        topServerCandidates(votes, exclude: const {}, boost: {'wss://c'}),
        ['wss://c', 'wss://a', 'wss://b'],
      );
    });
  });

  group('mapConcurrent', () {
    test('preserves input order', () async {
      final out = await mapConcurrent([3, 1, 2], 2, (i) async {
        await Future<void>.delayed(Duration(milliseconds: i * 10));
        return i * 10;
      });
      expect(out, [30, 10, 20]);
    });
  });

  group('Nip11Info.parse', () {
    test('free relay with NIP-50', () {
      final info = Nip11Info.parse({
        'limitation': {'auth_required': false, 'payment_required': false},
        'supported_nips': [1, 2, 50],
      })!;
      expect(info.isFree, isTrue);
      expect(info.supportsNip50, isTrue);
    });

    test('auth-required / payment-required / fees each kill isFree', () {
      expect(
        Nip11Info.parse({
          'limitation': {'auth_required': true},
        })!.isFree,
        isFalse,
      );
      expect(
        Nip11Info.parse({
          'limitation': {'payment_required': true},
        })!.isFree,
        isFalse,
      );
      expect(
        Nip11Info.parse({
          'fees': {'admission': 1000},
        })!.isFree,
        isFalse,
      );
      expect(
        Nip11Info.parse({
          'fees': {'publication': 5},
        })!.isFree,
        isFalse,
      );
    });

    test('missing/absent fields default free; non-map → null', () {
      expect(Nip11Info.parse(<String, dynamic>{})!.isFree, isTrue);
      expect(Nip11Info.parse([1, 2]), isNull);
      expect(Nip11Info.parse(null), isNull);
    });
  });

  group('fetchNip11', () {
    test('wss→https GET with nostr+json Accept; parses doc', () async {
      Uri? seenUri;
      String? seenAccept;
      final client = MockClient((req) async {
        seenUri = req.url;
        seenAccept = req.headers['Accept'];
        return http.Response(
          jsonEncode({
            'supported_nips': [50],
          }),
          200,
        );
      });
      final info = await fetchNip11('wss://relay.example/', client: client);
      expect(seenUri.toString(), 'https://relay.example/');
      expect(seenAccept, 'application/nostr+json');
      expect(info!.supportsNip50, isTrue);
    });

    test('non-200 → null; network error → null', () async {
      expect(
        await fetchNip11('wss://a.example', client: _nip11(const {})),
        isNull,
      );
      expect(
        await fetchNip11(
          'wss://a.example',
          client: MockClient((req) async => throw Exception('boom')),
        ),
        isNull,
      );
    });
  });

  group('probeRelayAlive', () {
    test('EOSE within window → alive', () async {
      final conn = _ProbeConn('wss://a');
      expect(await probeRelayAlive('wss://a', makeClient: (_) => conn), isTrue);
      expect(conn.requests.single, {
        'kinds': [1],
        'limit': 1,
      });
      expect(conn.disposed, isTrue);
    });

    test('EVENT (no EOSE, multiplexer-style) → alive', () async {
      final conn = _ProbeConn('wss://a', reply: _Reply.event);
      expect(await probeRelayAlive('wss://a', makeClient: (_) => conn), isTrue);
      expect(conn.disposed, isTrue);
    });

    test('cannot connect → not alive', () async {
      expect(
        await probeRelayAlive(
          'wss://a',
          makeClient: (url) => _ProbeConn(url, connects: false),
        ),
        isFalse,
      );
    });

    test('no frame within timeout → not alive, still disposed', () async {
      final conn = _ProbeConn('wss://a', reply: _Reply.nothing);
      expect(
        await probeRelayAlive(
          'wss://a',
          makeClient: (_) => conn,
          timeout: const Duration(milliseconds: 50),
        ),
        isFalse,
      );
      expect(conn.disposed, isTrue);
    });
  });

  group('probeBlossomWritable', () {
    final identity = Identity.fromPrivkeyHex(_priv);

    test('2xx upload → writable', () async {
      expect(
        await probeBlossomWritable(
          'https://good.example/',
          identity,
          client: _blossom({'good.example': 200}),
        ),
        isTrue,
      );
    });

    test('403 (whitelist/paid) → not writable', () async {
      expect(
        await probeBlossomWritable(
          'https://bad.example',
          identity,
          client: _blossom({'bad.example': 403}),
        ),
        isFalse,
      );
    });
  });

  group('ServerDiscovery.recommend — relay', () {
    test(
      'votes rank, configured excluded, paid excluded, unknown NIP-11 kept',
      () async {
        final db = _FakeDb();
        db.replaceableByKind[10002] = [
          _row('e1', 10002, [
            ['r', 'wss://a.example/'],
            ['r', 'wss://b.example', 'write'],
            ['r', 'wss://paid.example'],
            ['r', 'wss://configured.example'],
          ]),
          _row('e2', 10002, [
            ['r', 'WSS://A.example'], // second vote for a
          ]),
        ];
        db.config['relay_list'] = jsonEncode(['wss://configured.example/']);

        final d = _discovery(
          db,
          httpClient: _nip11({
            'paid.example': {
              'limitation': {'payment_required': true},
            },
            // a/b: 404 → unknown NIP-11 → still recommendable.
          }),
        );
        expect(await d.recommend(ServerCategory.relay), [
          'wss://a.example',
          'wss://b.example',
        ]);
        // Result cached under the per-category key.
        expect(db.config.containsKey('server_reco:relay'), isTrue);
      },
    );

    test('fresh cache is served WITHOUT probing; force re-probes', () async {
      final db = _FakeDb();
      final fresh = jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
        'urls': ['wss://cached.example'],
      });
      db.config['server_reco:relay'] = fresh;

      var probed = false;
      final d = _discovery(
        db,
        httpClient: _nip11(const {}),
        makeClient: (url) {
          probed = true;
          return _ProbeConn(url);
        },
      );
      expect(await d.recommend(ServerCategory.relay), ['wss://cached.example']);
      expect(probed, isFalse);

      // force:true ignores the cache and probes (no candidates here → empty,
      // which also proves the probe path ran instead of the cache read).
      db.replaceableByKind[10002] = [
        _row('e1', 10002, [
          ['r', 'wss://a.example'],
        ]),
      ];
      expect(await d.recommend(ServerCategory.relay, force: true), [
        'wss://a.example',
      ]);
      expect(probed, isTrue);
    });

    test('expired cache (>24h) is re-probed', () async {
      final db = _FakeDb();
      db.config['server_reco:relay'] = jsonEncode({
        'at': DateTime.now().millisecondsSinceEpoch ~/ 1000 - 25 * 3600,
        'urls': ['wss://stale.example'],
      });
      db.replaceableByKind[10002] = [
        _row('e1', 10002, [
          ['r', 'wss://fresh.example'],
        ]),
      ];
      expect(
        await _discovery(
          db,
          httpClient: _nip11(const {}),
        ).recommend(ServerCategory.relay),
        ['wss://fresh.example'],
      );
    });

    test(
      'empty results are NOT cached (transient failure hides nothing)',
      () async {
        final db = _FakeDb();
        await _discovery(
          db,
          makeClient: (url) => _ProbeConn(url, connects: false),
        ).recommend(ServerCategory.relay);
        expect(db.config.containsKey('server_reco:relay'), isFalse);
      },
    );
  });

  group('ServerDiscovery.recommend — search', () {
    test('needs alive + NIP-11 self-declared NIP-50; paid excluded', () async {
      final db = _FakeDb();
      db.replaceableByKind[10002] = [
        _row('e1', 10002, [
          ['r', 'wss://search.example'],
          ['r', 'wss://no50.example'],
          ['r', 'wss://nodoc.example'],
          ['r', 'wss://paid50.example'],
        ]),
      ];
      final d = _discovery(
        db,
        httpClient: _nip11({
          'search.example': {
            'limitation': <String, dynamic>{},
            'supported_nips': [1, 50],
          },
          'no50.example': {
            'limitation': <String, dynamic>{},
            'supported_nips': [1],
          },
          'paid50.example': {
            'limitation': {'payment_required': true},
            'supported_nips': [50],
          },
          // nodoc.example → 404: can't verify search support → excluded.
        }),
      );
      expect(await d.recommend(ServerCategory.search), [
        'wss://search.example',
      ]);
    });
  });

  group('ServerDiscovery.recommend — blossom', () {
    final identity = Identity.fromPrivkeyHex(_priv);

    test('logged out → no recommendations (UI shows the hint)', () async {
      final db = _FakeDb();
      db.replaceableByKind[10063] = [
        _row('e1', 10063, [
          ['server', 'https://good.example'],
        ]),
      ];
      expect(await _discovery(db).recommend(ServerCategory.blossom), isEmpty);
    });

    test(
      'test-upload probe: writable kept, 403 rejected, configured excluded',
      () async {
        final db = _FakeDb();
        db.replaceableByKind[10063] = [
          _row('e1', 10063, [
            ['server', 'https://good.example/'],
            ['server', 'https://bad.example'],
            ['server', 'https://configured.example'],
          ]),
          _row('e2', 10063, [
            ['server', 'https://good.example'], // second vote
          ]),
        ];
        db.config['blossom_list'] = jsonEncode(['https://configured.example']);
        final d = _discovery(
          db,
          identity: identity,
          httpClient: _blossom({
            'good.example': 200,
            'bad.example': 403, // whitelist/paid → rejected
          }),
        );
        expect(await d.recommend(ServerCategory.blossom), [
          'https://good.example',
        ]);
      },
    );
  });

  group('ServerDiscovery.recommend — edge cases', () {
    test('indexer is unsupported this iteration → always empty', () async {
      final db = _FakeDb();
      db.replaceableByKind[10002] = [
        _row('e1', 10002, [
          ['r', 'wss://a.example'],
        ]),
      ];
      expect(await _discovery(db).recommend(ServerCategory.indexer), isEmpty);
      expect(discoverySupported(ServerCategory.indexer), isFalse);
    });

    test('no candidates anywhere → empty (UI hides the block)', () async {
      expect(
        await _discovery(_FakeDb()).recommend(ServerCategory.relay),
        isEmpty,
      );
    });
  });
}
