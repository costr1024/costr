// Regression: "通知里有点赞提醒，点进帖子却看不到" (v1.0.7 follow-up).
//
// Two compounding gaps left likes invisible on the post itself even though
// the notification center displayed them:
//
// GAP A — live deliveries never reached the eviction-proof cache. A like
// arriving on a long-lived unrouted sub (the notifications #e REQ, the
// following feed) flowed only into the capped EventStore, which evicts
// kind-7 FIRST (~25ms on a saturated feed). The InteractionCache — the tier
// the like tally / chevron survive on — was fed only by thread-open fetches
// and the user's own publishes. Fix: the EventStore merged-stream listener
// now ingests every arriving kind-6/7/16 into the cache too.
//
// GAP B — the thread-open #e fetch resolved on the FIRST relay's EOSE and
// then closed the subscription on ALL relays. A relay WITHOUT the like
// answers empty-EOSE fastest, cancelling the fetch before the relay that HAS
// it could respond — empty result, nothing ingested, chevron hidden. This is
// why "有些点赞可以看到有些不行": pure relay-response lottery. Fix: resolve
// early only when something was collected, else wait for all connected
// relays (bounded by 8s), keep the REQ open until both pages dispose, and
// ingest each matching event into the cache the moment it arrives.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/post_detail_page.dart';
import 'package:costr/features/feed/interactions_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

final String _postId = 'p' * 64;

Event _post() => Event(
  id: _postId,
  pubkey: 'a' * 64,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: '你还年轻',
  sig: 's' * 128,
);

Event _like() => Event(
  id: 'r' * 64,
  pubkey: 'b' * 64,
  createdAt: 1700000100,
  kind: 7,
  tags: [
    ['e', _postId],
    ['p', 'a' * 64],
  ],
  content: '+',
  sig: 's' * 128,
);

/// A kind-1 REPLY to the post (e-tag with a reply marker), from a third user.
Event _reply() => Event(
  id: 'c' * 64,
  pubkey: 'd' * 64,
  createdAt: 1700000200,
  kind: 1,
  tags: [
    ['e', _postId, '', 'reply'],
    ['p', 'a' * 64],
  ],
  content: '说得对',
  sig: 's' * 128,
);

/// Scripted relay. [hasLike] relays answer the interactions #e REQ with the
/// reaction (optionally after [likeDelay]); the others answer empty-EOSE.
///
/// closeSubscription is HONORED: a real relay stops emitting for a sub the
/// client CLOSEd, so the scripted late answer checks the closed set. This is
/// what makes the first-EOSE race reproducible — pre-fix, the provider
/// closed ALL relays the instant the first (empty) EOSE arrived, silencing
/// the relay that had the like.
class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url, {this.hasLike = false, this.likeDelay = Duration.zero});

  @override
  final String url;
  final bool hasLike;
  final Duration likeDelay;

  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<Map<String, dynamic>> reqs = [];
  final Set<String> _closedSubs = {};
  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;

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

  /// Deliver an event the way a long-lived unrouted sub (the notifications
  /// #e REQ) would — no REQ of our own involved.
  void push(Event e) => _events.add(e);

  @override
  Future<void> connect() async {
    _connected = true;
    _onConnected?.call();
  }

  @override
  void request(String subId, Map<String, dynamic> filter) {
    reqs.add(filter);
    final kinds =
        (filter['kinds'] as List<dynamic>?)?.cast<int>() ?? const <int>[];
    if (filter['ids'] != null) {
      _events.add(_post());
      _eose.add(subId);
      return;
    }
    if (kinds.contains(7) && filter['#e'] != null) {
      if (!hasLike) {
        // Fast empty answer — the relay that wins the first-EOSE race.
        _eose.add(subId);
      } else if (likeDelay == Duration.zero) {
        _events.add(_like());
        _eose.add(subId);
      } else {
        Timer(likeDelay, () {
          if (_closedSubs.contains(subId)) return; // CLOSEd by the client
          _events.add(_like());
          _eose.add(subId);
        });
      }
      return;
    }
    _eose.add(subId);
  }

  @override
  void closeSubscription(String subId) => _closedSubs.add(subId);

  @override
  void publish(Event event) {}

  @override
  void sendAuth(Event event) {}

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
}

/// Stub cache: empty everything so every lookup falls through to the relay.
class _StubCache implements cache.LocalCache {
  @override
  Future<cache.EventRow?> queryEventById(String id) async => null;

  @override
  Future<List<cache.EventRow>> queryFeed({int limit = 200}) async => const [];
  @override
  Future<List<cache.EventRow>> queryRecentReactions({int limit = 500}) async =>
      const [];
  @override
  Future<List<cache.ReplaceableEvent>> queryAllMetadata() async => const [];

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
  }) async {}

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

class _Nsfw extends NsfwSettingsNotifier {
  @override
  NsfwSettings build() => const NsfwSettings();
}

class _EmptyTags extends FollowedTagsNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
}

class _ProxyOff extends ProxyMediaNotifier {
  @override
  bool build() => false;
}

void main() {
  testWidgets(
    'GAP B: a like held only by a SLOW relay still lights the chevron '
    '(no first-EOSE stampede)',
    (tester) async {
      // Relay A answers every interactions REQ with an immediate EMPTY EOSE;
      // relay B has the like but answers 400ms later. Pre-fix the provider
      // resolved on A's first EOSE and closed B's sub before it answered —
      // the like never arrived and the chevron stayed hidden even though the
      // notification center (long-lived sub) had shown it.
      final fast = _FakeRelay('wss://fast');
      final slow = _FakeRelay(
        'wss://slow',
        hasLike: true,
        likeDelay: const Duration(milliseconds: 400),
      );
      final pool = RelayPool([fast, slow]);
      await pool.connect();
      addTearDown(pool.dispose);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              relayPoolProvider.overrideWith((ref) => pool),
              localCacheProvider.overrideWith((ref) async => _StubCache()),
              identityProvider.overrideWith(() => _NullId()),
              nsfwSettingsProvider.overrideWith(() => _Nsfw()),
              metadataProvider.overrideWith((ref, pk) async* {
                yield null;
              }),
              userStatusProvider.overrideWith((ref, pk) async* {
                yield null;
              }),
              followedTagsProvider.overrideWith(() => _EmptyTags()),
              proxyMediaEnabledProvider.overrideWith(() => _ProxyOff()),
            ],
            child: MaterialApp.router(
              routerConfig: GoRouter(
                initialLocation: '/post/$_postId',
                routes: [
                  GoRoute(
                    path: '/post/:id',
                    builder: (_, s) =>
                        PostDetailPage(id: s.pathParameters['id']!),
                  ),
                  GoRoute(
                    path: '/interactions/:id',
                    builder: (_, s) =>
                        InteractionsPage(id: s.pathParameters['id']!),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();
        // Pre-create the interaction index + this post's reactions provider
        // BEFORE the slow like lands. In the real app both are created on the
        // first feed render — a clean window with nothing mid-flush. If they
        // were first MOUNTED lazily by a build that coincides with the like's
        // provider flush, the mount's ref.watch of the (dirty) cache provider
        // would schedule a refresh mid-build (setState-during-build flake).
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PostDetailPage)),
        );
        container.read(interactionIndexProvider);
        container.read(reactionsProvider(_postId));
        // Post lookup resolves, the #e REQ goes out, fast relay empty-EOSEs.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
        // Pre-fix the sub was already closed on the slow relay by now.
        // Post-fix the slow relay's late answer still lands.
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
      });

      expect(
        find.byIcon(Icons.expand_more_rounded),
        findsOneWidget,
        reason: 'the slow relay like must reach the interaction index',
      );

      // And the 「点赞与转发」list shows the liker row.
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pumpAndSettle();
      expect(find.text('点赞与转发'), findsOneWidget);
      expect(find.text('点赞了这条帖子'), findsOneWidget);
    },
  );

  test(
    'GAP A: a live-delivered like (notification-style unrouted sub) reaches '
    'the eviction-proof cache and the index without any thread-open fetch',
    () async {
      final relay = _FakeRelay('wss://a');
      final pool = RelayPool([relay]);
      await pool.connect();
      addTearDown(pool.dispose);

      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => pool),
          localCacheProvider.overrideWith((ref) async => _StubCache()),
          identityProvider.overrideWith(() => _NullId()),
        ],
      );
      addTearDown(container.dispose);
      // Build the store notifier so its merged-stream listener is wired.
      container.read(eventStoreProvider);
      await container.read(eventStoreProvider.notifier).hydrated;

      // A like arrives exactly the way the notifications #e sub delivers it:
      // under a long-lived unrouted sub, no #e fetch of our own involved.
      relay.push(_like());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Pre-fix this copy landed ONLY in the capped store (evicted kind-7
      // first on a busy feed) — the cache never saw it. Post-fix the merged-
      // stream listener ingests it into the eviction-proof cache.
      final held = container.read(interactionCacheProvider.notifier).cache;
      expect(held.events.map((e) => e.id), contains(_like().id));

      // …and the store-derived index (tallies / chevron source) shows it.
      final stats = container.read(interactionIndexProvider)[_postId];
      expect(stats, isNotNull);
      expect(stats!.reactions['👍']?.count, 1);
    },
  );

  test(
    'REPLY COUNT: a live-delivered reply reaches the cache and the feed reply '
    'count without opening the thread',
    () async {
      final relay = _FakeRelay('wss://a');
      final pool = RelayPool([relay]);
      await pool.connect();
      addTearDown(pool.dispose);

      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => pool),
          localCacheProvider.overrideWith((ref) async => _StubCache()),
          identityProvider.overrideWith(() => _NullId()),
        ],
      );
      addTearDown(container.dispose);
      // Build the store notifier so its merged-stream listener is wired.
      container.read(eventStoreProvider);
      await container.read(eventStoreProvider.notifier).hydrated;

      // A reply arrives the way the following feed / a long-lived sub delivers
      // it (unrouted) — no thread open involved.
      relay.push(_reply());
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Pre-fix a reply landed ONLY in the capped store (kind-1 evicts last,
      // but still evicts on a long-lived busy feed) — the eviction-proof cache
      // never saw it, so the feed reply COUNT could drop to 0. Post-fix the
      // merged-stream listener ingests the reply into the cache too.
      final held = container.read(interactionCacheProvider.notifier).cache;
      expect(held.events.map((e) => e.id), contains(_reply().id));

      // …and the index's feed reply count reflects it (the post shows ≥1 reply).
      final stats = container.read(interactionIndexProvider)[_postId];
      expect(stats, isNotNull);
      expect(stats!.replies, 1);
    },
  );
}
