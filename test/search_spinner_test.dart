// Regression test: user search with ZERO matching results must resolve to an
// empty list, not spin forever.
//
// Root cause: searchUsersProvider has no initial yield (unlike
// searchPostsProvider, which yields the SQLite-FTS snapshot first) — it only
// emits via its StreamController when relay results arrive, and the final
// flush on EOSE/timeout was gated by `if (dirty)`. With zero results nothing
// was ever added to the controller, so the stream closed WITHOUT emitting and
// Riverpod left the provider in AsyncLoading forever: the perpetual 用户列表
// spinner the user saw (posts resolved via their initial yield; users didn't),
// which even survived leaving and re-entering the search tab (non-autoDispose
// family caches the stuck loading state).
//
// Fix mirrors repliesProvider: ALWAYS emit a final snapshot (even empty)
// before closing the controller.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake NIP-50 relay: answers every REQ with an optional seeded payload, then
/// an immediate EOSE.
class _SearchRelay implements RelayConnection {
  _SearchRelay(this.url, [this.seeded = const []]);

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
    scheduleMicrotask(() {
      for (final e in seeded) {
        if (!_events.isClosed) _events.add(e);
      }
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

Event _meta(String pubkey, String name) => Event(
  id: 'meta$pubkey',
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: 0,
  tags: const [],
  content: '{"name":"$name"}',
  sig: 's' * 128,
);

void main() {
  late ProviderContainer container;
  late RelayPool searchPool;

  Future<void> setUpPool(List<Event> seeded) async {
    searchPool = RelayPool([_SearchRelay('wss://search', seeded)]);
    await searchPool.connect();
    container = ProviderContainer(
      overrides: [
        searchPoolProvider.overrideWith((ref) => searchPool),
        // No SQLite in the unit test — .value stays null so the FTS phase is
        // skipped and search goes straight to the (fake) relay pool.
        localCacheProvider.overrideWith(
          (ref) => Completer<cache.LocalCache>().future,
        ),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(searchPool.dispose);
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

  test('zero user results resolve to an EMPTY LIST instead of spinning '
      'forever (the reported 百度-search bug)', () async {
    await setUpPool(const []); // relay answers EOSE with nothing
    final sub = container.listen(searchUsersProvider('百度'), (_, _) {});
    addTearDown(sub.close);

    // The provider must reach AsyncData — before the fix it stayed in
    // AsyncLoading forever because the controller closed without emitting.
    await pollUntil(() => container.read(searchUsersProvider('百度')).hasValue);
    expect(container.read(searchUsersProvider('百度')).value, isEmpty);
  });

  test('user results stream in and resolve', () async {
    await setUpPool([_meta('a' * 64, '百度贴吧'), _meta('b' * 64, '百度百科')]);
    final sub = container.listen(searchUsersProvider('百度'), (_, _) {});
    addTearDown(sub.close);

    await pollUntil(() {
      final v = container.read(searchUsersProvider('百度')).value;
      return v != null && v.length == 2;
    });
    final users = container.read(searchUsersProvider('百度')).value!;
    expect(users.map((u) => u.metadata?.name), containsAll(['百度贴吧', '百度百科']));
  });

  test(
    'zero post results also resolve (initial FTS yield already covered it)',
    () async {
      await setUpPool(const []);
      final sub = container.listen(searchPostsProvider('百度'), (_, _) {});
      addTearDown(sub.close);
      await pollUntil(() => container.read(searchPostsProvider('百度')).hasValue);
      expect(container.read(searchPostsProvider('百度')).value, isEmpty);
    },
  );
}
