// Regression test: a profile must load the author's FULL newest window, not
// just posts newer than the partial cache.
//
// Root cause (fixed in userPostsProvider): the relay REQ used a `since`
// filter anchored on the newest cached post. For users outside the social
// graph, posts are never persisted to SQLite, so the cache is only whatever
// happened to flow through the global feed (a partial glimpse). Anchoring
// `since` there meant the relay was asked only for posts NEWER than that
// glimpse — the rest of the author's history was never fetched, so the
// profile showed just a handful of posts and pull-refresh never loaded more.
//
// The fake relay honors `since` like a real relay (drops events with
// created_at <= since), so if the `since` anchor is ever re-introduced the
// older posts stop arriving and this test fails.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay that applies `authors` / `kinds` / `since` like a real relay.
class _FilteringRelay implements RelayConnection {
  _FilteringRelay(this.url, [this.seeded = const []]);

  @override
  final String url;
  final List<Event> seeded;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<(String, Event)> get taggedEvents =>
      _events.stream.map((e) => ('fake', e));
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
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    sent.add(['REQ', subId, filter]);
    final authors = filter['authors'];
    final kinds = filter['kinds'];
    final since = filter['since'];
    scheduleMicrotask(() {
      for (final e in seeded) {
        if (authors is List && !authors.contains(e.pubkey)) continue;
        if (kinds is List && !kinds.contains(e.kind)) continue;
        // Real-relay semantics: `since` is exclusive-lower-bound.
        if (since is int && e.createdAt <= since) continue;
        if (!_events.isClosed) _events.add(e);
      }
    });
    // Emit EOSE on a short delay — a real relay sends EOSE as a separate
    // frame AFTER the last EVENT, giving the events time to propagate through
    // the pool's async broadcast streams. Emitting both in the same microtask
    // would race the provider's `done` close ahead of the event delivery.
    Timer(const Duration(milliseconds: 30), () {
      if (!_eose.isClosed) _eose.add(subId);
    });
  }

  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);

  @override
  void publish(Event event) {}

  @override
  void sendAuth(Event event) {}

  @override
  void setOnConnected(void Function() cb) {}
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
}

/// LocalCache double with no stored rows (the user isn't in the social graph,
/// so nothing of theirs was ever persisted).
class _EmptyCache implements cache.LocalCache {
  @override
  Future<List<cache.EventRow>> queryUserPosts(
    String pubkey, {
    int limit = 100,
  }) async => const [];

  @override
  Future<cache.ReplaceableEvent?> queryReplaceable(
    String pubkey,
    int kind, {
    String dTag = '',
  }) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

/// Fixed in-memory store holding the partial "glimpsed in the feed" cache.
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _note(String id, String pubkey, int createdAt) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 1,
  tags: const [],
  content: 'note $id',
  sig: 's' * 128,
);

void main() {
  test('profile loads the author\'s OLDER history, not just posts newer than '
      'the partial cache (no `since` anchor)', () async {
    const author =
        'a111111111111111111111111111111111111111111111111111111111111111';
    // Partial cache: two recent posts glimpsed in the global feed.
    final recent1 = _note('recent1', author, 1000);
    final recent2 = _note('recent2', author, 1001);
    // The author's older history lives only on the relay.
    final older = [
      _note('old3', author, 700),
      _note('old2', author, 600),
      _note('old1', author, 500),
    ];

    final relay = _FilteringRelay('wss://a', older);
    final pool = RelayPool([relay]);
    final indexerPool = RelayPool([_FilteringRelay('wss://idx')]);
    await pool.connect();
    await indexerPool.connect();
    addTearDown(pool.dispose);
    addTearDown(indexerPool.dispose);

    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        indexerPoolProvider.overrideWith((ref) => indexerPool),
        localCacheProvider.overrideWith((ref) async => _EmptyCache()),
        identityProvider.overrideWith(() => _NullId()),
        eventStoreProvider.overrideWith(() => _FixedStore([recent2, recent1])),
      ],
    );
    addTearDown(container.dispose);
    await container.read(localCacheProvider.future);

    final sub = container.listen(userPostsProvider(author), (_, _) {});
    addTearDown(sub.close);

    // Poll until the older history arrives (it never does if a `since`
    // anchor excludes it).
    final sw = Stopwatch()..start();
    bool hasAll() {
      final v = container.read(userPostsProvider(author)).value;
      if (v == null) return false;
      final ids = v.map((e) => e.id).toSet();
      return ids.containsAll({'recent1', 'recent2', 'old1', 'old2', 'old3'});
    }

    while (!hasAll()) {
      if (sw.elapsed > const Duration(seconds: 5)) {
        fail('older posts never loaded — `since` anchor likely re-introduced');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final list = container.read(userPostsProvider(author)).value!;
    expect(list.map((e) => e.id), containsAll(['old1', 'old2', 'old3']));
    // Newest-first ordering.
    expect(list.first.id, 'recent2');
  });
}
