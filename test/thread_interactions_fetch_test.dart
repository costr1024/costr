// Regression: opening a post's thread must actively fetch its reactions /
// reposts (kinds [6,16,7], #e [id]) instead of relying on the capped
// in-memory store having happened to see them on the firehose. The store
// evicts kind-7 FIRST, so on a busy global feed reactions to anything but
// the newest posts are usually absent — pre-fix the like tally / reaction
// chips / 「谁点赞/转发了」chevron (all store-derived) stayed invisible even
// though the relays held the reactions ("看不到帖子的点赞列表" report). The
// thread page now watches interactorsProvider; its REQ answer flows through
// the pool's merged stream into the store, so the chevron lights up. This
// test drives the REAL store + pool ingestion path against a scripted fake
// relay and asserts the entry appears and opens the interactor list.

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
  content: 'the post',
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

/// Scripted relay: answers the note lookup with the post, the interactions
/// REQ (#e with kinds incl. 7) with one reaction, everything else with EOSE.
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

  final List<Map<String, dynamic>> reqs = [];
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
    reqs.add(filter);
    final kinds = (filter['kinds'] as List<dynamic>?)?.cast<int>() ??
        const <int>[];
    if (filter['ids'] != null) {
      _events.add(_post());
    } else if (kinds.contains(7)) {
      _events.add(_like());
    }
    _eose.add(subId);
  }

  @override
  void closeSubscription(String subId) {}

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
    'thread open fetches reactions; like chevron + list appear',
    (tester) async {
      final relay = _FakeRelay('wss://a');
      final pool = RelayPool([relay]);
      await pool.connect();
      addTearDown(pool.dispose);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              relayPoolProvider.overrideWith((ref) => pool),
              localCacheProvider.overrideWith((ref) async => _StubCache()),
              identityProvider.overrideWith(() => _NullId()),
              // Peripheral render stubs — the store/pool ingestion path under
              // test stays REAL (eventStoreProvider, interactionIndexProvider,
              // reactionsProvider, postCountsProvider, interactorsProvider).
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
        // Let the lookups + the interactions REQ answer, then the store's
        // 200ms flush (real timers — runAsync zone).
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 350));
        await tester.pump();
      });

      // The thread issued the interactions REQ: kinds [6,16,7] #e [post].
      expect(
        relay.reqs.any(
          (f) =>
              (f['kinds'] as List<dynamic>?)?.contains(7) == true &&
              (f['#e'] as List<dynamic>?)?.contains(_postId) == true,
        ),
        isTrue,
        reason: 'opening the thread must query reactions/reposts by #e',
      );

      // The fetched reaction reached the store-derived tallies: the
      // down-chevron entry is offered on the focused card.
      expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);

      // And it opens the 「点赞与转发」list with the liker's row.
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await tester.pumpAndSettle();
      expect(find.text('点赞与转发'), findsOneWidget);
      expect(find.text('点赞了这条帖子'), findsOneWidget);
    },
  );
}
