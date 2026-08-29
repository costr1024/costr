// Tests for backward pagination of a profile's posts/replies.
//
// [userPostsProvider] only pulls the NEWEST window (limit 100). Reaching older
// history is the job of [userPostsPagerNotifier]: each loadMore(oldestCreatedAt:)
// fetches one strictly-older page (`until = oldestCreatedAt - 1`) from the
// author's outbox relays (or the main pool as a broadcast) and appends it to
// [UserPostsPage.older]. An empty page flips [UserPostsPage.hasMore] off so the
// tabs show 「没有更多了」 and stop triggering.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay honoring `authors` / `kinds` / `until` / `limit` like a real
/// relay, and tagging each event with the subId it answers (so the pool's
/// routed-subscription path — the pager's broadcast fetch — delivers them).
class _PagingRelay implements RelayConnection {
  _PagingRelay(this.url, this.seeded);

  @override
  final String url;
  final List<Event> seeded;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<(String, Event)> _tagged =
      StreamController<(String, Event)>.broadcast();
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
  Stream<Event> get events => _events.stream;
  @override
  Stream<(String, Event)> get taggedEvents => _tagged.stream;
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
    final until = filter['until'];
    final limit = filter['limit'];
    final matches = seeded.where((e) {
      if (authors is List && !authors.contains(e.pubkey)) return false;
      if (kinds is List && !kinds.contains(e.kind)) return false;
      // Real-relay semantics: `until` is an inclusive upper bound
      // (created_at <= until). The pager passes `oldest - 1`, so this page
      // is exactly the notes strictly older than the current oldest.
      if (until is int && e.createdAt > until) return false;
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final page = (limit is int && matches.length > limit)
        ? matches.sublist(0, limit)
        : matches;
    scheduleMicrotask(() {
      for (final e in page) {
        if (!_tagged.isClosed) _tagged.add((subId, e));
      }
    });
    // EOSE arrives after the events (a real relay sends it as a later frame).
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
    await _tagged.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }
}

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

class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;

  // The pager + newest-window fetch persist via these side-effect paths. In
  // the test they'd schedule the store's 200ms flush timer, which races
  // container disposal at teardown ("Ref used after disposed"). Persistence
  // isn't what's under test here, so both are no-ops.
  @override
  Future<void> ingest(Event e) async {}

  @override
  Future<void> cacheThreadEvent(Event e) async {}
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
  const author =
      'a111111111111111111111111111111111111111111111111111111111111111';

  // 300 notes, created_at 1000 (newest) .. 701 (oldest).
  final seeded = <Event>[
    for (var t = 1000; t >= 701; t--) _note('n$t', author, t),
  ];

  late RelayPool pool;
  late ProviderContainer container;

  setUp(() async {
    final relay = _PagingRelay('wss://a', seeded);
    final indexer = _PagingRelay('wss://idx', const []);
    pool = RelayPool([relay]);
    final indexerPool = RelayPool([indexer]);
    await pool.connect();
    await indexerPool.connect();

    container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        indexerPoolProvider.overrideWith((ref) => indexerPool),
        localCacheProvider.overrideWith((ref) async => _EmptyCache()),
        identityProvider.overrideWith(() => _NullId()),
        eventStoreProvider.overrideWith(() => _FixedStore(const [])),
        // No published relay list → the pager falls back to the broadcast path.
        userRelayListProvider.overrideWith((ref, pk) async => null),
      ],
    );
    await container.read(localCacheProvider.future);
    // LIFO teardown: registered last runs first → the pools stop delivering
    // events before the container (and its providers) is torn down.
    addTearDown(container.dispose);
    addTearDown(indexerPool.dispose);
    addTearDown(pool.dispose);
  });

  Future<void> waitForPage() async {
    final sw = Stopwatch()..start();
    while (container.read(userPostsPagerProvider(author)).loadingMore) {
      if (sw.elapsed > const Duration(seconds: 5)) {
        fail('loadMore never settled');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('newest window is 100 notes, not the full history', () async {
    final sub = container.listen(userPostsProvider(author), (_, _) {});
    addTearDown(sub.close);
    final sw = Stopwatch()..start();
    while (true) {
      final v = container.read(userPostsProvider(author)).value;
      if (v != null && v.length >= 100) break;
      if (sw.elapsed > const Duration(seconds: 5)) {
        fail('newest window never loaded');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final list = container.read(userPostsProvider(author)).value!;
    // Exactly the 100 newest (created_at 1000..901), not all 300.
    expect(list.length, 100);
    expect(list.first.createdAt, 1000);
    expect(list.last.createdAt, 901);
  });

  test('loadMore walks backward page by page, then reports no more', () async {
    final pager = container.read(userPostsPagerProvider(author).notifier);

    // Page 1: older than created_at 901 (the newest window's oldest).
    await pager.loadMore(oldestCreatedAt: 901);
    await waitForPage();
    var page = container.read(userPostsPagerProvider(author));
    expect(page.loadingMore, isFalse);
    expect(page.hasMore, isTrue);
    expect(page.older.length, 100); // 900..801
    expect(page.older.first.createdAt, 900);
    expect(page.older.last.createdAt, 801);

    // Page 2: older than created_at 801.
    await pager.loadMore(oldestCreatedAt: 801);
    await waitForPage();
    page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isTrue);
    expect(page.older.length, 200); // accumulated 900..701
    expect(page.older.last.createdAt, 701);

    // Page 3: nothing older than created_at 701 → hasMore flips off.
    await pager.loadMore(oldestCreatedAt: 701);
    await waitForPage();
    page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isFalse);
    expect(page.older.length, 200); // unchanged

    // Further loadMore is a no-op while hasMore is false.
    await pager.loadMore(oldestCreatedAt: 701);
    page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isFalse);
  });

  test('retry re-arms hasMore after a refresh, keeping loaded pages', () async {
    final pager = container.read(userPostsPagerProvider(author).notifier);
    // Load page 1 (900..801) so there is loaded history to preserve.
    await pager.loadMore(oldestCreatedAt: 901);
    await waitForPage();
    expect(container.read(userPostsPagerProvider(author)).older.length, 100);

    // Drive to the dead end: nothing older than created_at 701.
    await pager.loadMore(oldestCreatedAt: 701);
    await waitForPage();
    var page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isFalse);
    // The empty page did NOT clear the already-loaded history.
    expect(page.older.length, 100);

    // Pull-to-refresh re-arms digging (relay may have recovered)…
    pager.retry();
    page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isTrue);
    expect(page.loadingMore, isFalse);
    expect(page.older.length, 100); // …while preserving loaded pages.

    // retry() is a no-op when already armed and idle.
    pager.retry();
    page = container.read(userPostsPagerProvider(author));
    expect(page.hasMore, isTrue);
    expect(page.older.length, 100);
  });
}
