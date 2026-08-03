// Regression test: a just-published reply must show in the parent post's
// thread view WITHOUT leaving and re-entering.
//
// Root cause (fixed in compose_page._send): repliesProvider is a ONE-SHOT
// load — its relay REQ closes on EOSE and the stream controller closes once
// the outbox phase finishes (~0–10s after the page opens). The publish echo
// goes to pool.events, not the rawEvents stream the provider listens on, and
// nothing invalidated the provider after send — so the open thread page kept
// its stale pre-reply snapshot until something forced a re-run (re-enter).
//
// Test 1 pins the staleness (late rawEvents arrivals can never fix it alone);
// test 2 proves the fix mechanism: awaited cacheThreadEvent + invalidate →
// the list reloads from SQLite and contains the reply.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay: answers every REQ with an immediate EOSE (no events unless the
/// test emits them) — i.e. "relay has nothing more", so repliesProvider's
/// one-shot phases complete promptly, mirroring a real relay round-trip.
class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;
  @override
  Stream<RelayOk> get oks => _oks.stream;
  @override
  Stream<String> get auths => _auths.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _onConnected?.call();
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    sent.add(['REQ', subId, filter]);
    scheduleMicrotask(() {
      if (!_eose.isClosed) _eose.add(subId);
    });
  }

  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);

  @override
  void publish(Event event) => sent.add(['EVENT', event.toWireObject()]);

  @override
  void sendAuth(Event event) => sent.add(['AUTH', event.toWireObject()]);

  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emit(Event e) => _events.add(e);
}

/// In-memory LocalCache double: stores written kind-1 rows and serves them
/// back from queryReplies (the e-tag join) + queryEventById, like SQLite.
class _ReplyCache implements cache.LocalCache {
  final Map<String, cache.EventRow> _rows = {};
  final Map<String, List<List<dynamic>>> _tags = {};

  void seedEvent(Event e) {
    _rows[e.id] = cache.EventRow(
      id: e.id,
      pubkey: e.pubkey,
      kind: e.kind,
      createdAt: e.createdAt,
      content: e.content,
      sig: e.sig,
      raw: '{}',
      tagsJson: const <List<dynamic>>[].toString(),
      receivedAt: 0,
    );
    _tags[e.id] = e.tags;
  }

  @override
  Future<void> writeEvent({
    required String id,
    required String pubkey,
    required int kind,
    required int createdAt,
    required String content,
    required String sig,
    required String raw,
    required String tagsJson,
    required List tags,
  }) async {
    _rows[id] = cache.EventRow(
      id: id,
      pubkey: pubkey,
      kind: kind,
      createdAt: createdAt,
      content: content,
      sig: sig,
      raw: raw,
      tagsJson: tagsJson,
      receivedAt: 0,
    );
    _tags[id] = tags
        .map((t) => List<dynamic>.from(t as Iterable))
        .toList();
  }

  @override
  Future<List<cache.EventRow>> queryReplies(String eventId) async {
    return _rows.values.where((r) {
      if (r.kind != 1) return false;
      final tags = _tags[r.id] ?? const <List<dynamic>>[];
      return tags.any(
        (t) => t.length >= 2 && t[0] == 'e' && t[1] == eventId,
      );
    }).toList();
  }

  @override
  Future<cache.EventRow?> queryEventById(String id) async => _rows[id];

  @override
  Future<List<cache.EventRow>> queryFeed({int limit = 200}) async => const [];
  @override
  Future<List<cache.EventRow>> queryRecentReactions({int limit = 500}) async =>
      const [];
  @override
  Future<List<cache.ReplaceableEvent>> queryAllMetadata() async => const [];
  @override
  Future<cache.ReplaceableEvent?> queryReplaceable(
    String pubkey,
    int kind, {
    String dTag = '',
  }) async => null;

  @override
  Future<String?> readConfig(String key) async => null;
  @override
  Future<void> writeConfig(String key, String value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

Event _note({
  required String id,
  required String pubkey,
  List<List<dynamic>> tags = const [],
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: 1,
  tags: tags,
  content: 'text',
  sig: 's' * 128,
);

void main() {
  late ProviderContainer container;
  late RelayPool pool;
  late RelayPool indexerPool;
  late _FakeRelay relay;
  late _ReplyCache db;

  Future<void> setUpPools() async {
    relay = _FakeRelay('wss://a');
    pool = RelayPool([relay]);
    indexerPool = RelayPool([_FakeRelay('wss://idx')]);
    await pool.connect();
    await indexerPool.connect();
    db = _ReplyCache();
    container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        indexerPoolProvider.overrideWith((ref) => indexerPool),
        localCacheProvider.overrideWith((ref) async => db),
        identityProvider.overrideWith(() => _NullId()),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(pool.dispose);
    addTearDown(indexerPool.dispose);
    container.read(eventStoreProvider.notifier);
    await container.read(localCacheProvider.future);
  }

  Future<void> pollUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) fail('condition not met within $timeout');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Wait until the one-shot replies REQ (#e = parentId) has been CLOSEd —
  /// that is the moment the provider's stream closes and the snapshot is
  /// frozen (the bug window).
  Future<void> awaitRepliesReqClosed(String parentId) async {
    await pollUntil(() {
      for (final m in relay.sent) {
        if (m[0] != 'REQ') continue;
        final f = m[2] as Map<String, dynamic>;
        final e = f['#e'];
        if (e is List && e.contains(parentId)) {
          final subId = m[1] as String;
          return relay.sent.any((c) => c[0] == 'CLOSE' && c[1] == subId);
        }
      }
      return false;
    });
  }

  test(
      'root cause: once the one-shot load closes, late relay arrivals never '
      'reach the reply list (stale until invalidated)', () async {
    await setUpPools();
    final parent = _note(id: 'parent1', pubkey: 'a' * 64);
    db.seedEvent(parent);

    final sub = container.listen(repliesProvider('parent1'), (_, _) {});
    addTearDown(sub.close);
    await awaitRepliesReqClosed('parent1');
    expect(container.read(repliesProvider('parent1')).value, isEmpty);

    // The relay now holds the reply (publish landed) and pushes it on the
    // raw stream — but the provider's controller already closed.
    final reply = _note(
      id: 'reply1',
      pubkey: 'm' * 64,
      tags: [
        ['e', 'parent1', '', 'reply'],
      ],
    );
    relay.emit(reply);
    // > the provider's 250ms debounce — plenty of time IF it could still emit.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(container.read(repliesProvider('parent1')).value, isEmpty);
  });

  test(
      'fix: awaited cacheThreadEvent + invalidate(repliesProvider) shows the '
      'just-published reply immediately', () async {
    await setUpPools();
    final parent = _note(id: 'parent2', pubkey: 'b' * 64);
    db.seedEvent(parent);

    final sub = container.listen(repliesProvider('parent2'), (_, _) {});
    addTearDown(sub.close);
    await awaitRepliesReqClosed('parent2');
    expect(container.read(repliesProvider('parent2')).value, isEmpty);

    // Exactly what compose_page._send now does after a successful reply
    // publish: persist first (awaited), then invalidate the parent's list.
    final reply = _note(
      id: 'reply2',
      pubkey: 'm' * 64,
      tags: [
        ['e', 'parent2', '', 'reply'],
      ],
    );
    await container.read(eventStoreProvider.notifier).cacheThreadEvent(reply);
    container.invalidate(repliesProvider('parent2'));

    await pollUntil(
      () =>
          container
              .read(repliesProvider('parent2'))
              .value
              ?.any((e) => e.id == 'reply2') ??
          false,
    );
    final list = container.read(repliesProvider('parent2')).value!;
    expect(list.map((e) => e.id), contains('reply2'));
  });
}
