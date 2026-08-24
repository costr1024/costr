// Tests for the followed-hashtag feed (关注 dropdown `tag:` filter).
//
// The tag filter switches the following feed's SOURCE: instead of narrowing
// the already-loaded followee posts client-side (which only ever held a few
// days of history), `followingTagFeedProvider` broadcasts a live `#t` REQ to
// the relay pool and the feed shows matching posts from ANY author.
//
// Covers:
// 1. `hashtagAlts` case-variant expansion (relays match `t` values
//    case-sensitively — Amethyst pattern).
// 2. `followingTagFeedProvider` issues the `#t` REQ (kinds [1,6], limit 100,
//    `since` only when a tagged post is already held), closes it on teardown.
// 3. `currentFeedEventsProvider` with a tag filter shows tagged posts from
//    UNFOLLOWED authors and hides untagged followee posts.
// 4. `followingOutboxProvider` pauses (never touches the relay pool) while a
//    tag filter is active.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

// --- Fakes / overrides ------------------------------------------------------

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _FollowingMode extends FeedModeNotifier {
  @override
  FeedMode build() => FeedMode.following;
}

class _NoLangFilter extends LanguageFilterNotifier {
  @override
  LanguageFilter build() => LanguageFilter.all;
}

class _NoTagFilter extends TagFilterNotifier {
  @override
  String? build() => null;
}

class _FixedFollowingFilter extends FollowingFilterNotifier {
  _FixedFollowingFilter(this.value);
  final String? value;

  @override
  String? build() => value;
}

class _Follows extends FollowingNotifier {
  _Follows(this.list);
  final List<String> list;

  @override
  Future<List<String>> build() async => list;
}

/// Fixed in-memory store (no SQLite / relay wiring in unit tests).
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

/// Fake relay connection (same shape as relay_pool_test.dart) — records
/// frames sent, no network.
class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
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
  void request(String subId, Map<String, dynamic> filter) =>
      sent.add(['REQ', subId, filter]);

  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);

  @override
  void publish(Event event) => sent.add(['EVENT', event.toWireObject()]);

  @override
  void sendAuth(Event event) => sent.add(['AUTH', event.toWireObject()]);

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

// --- Helpers ----------------------------------------------------------------

Event _post(
  String id,
  String pubkey,
  int createdAt, {
  List<List<String>> tags = const [],
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 1,
  tags: tags,
  content: 'post $id',
  sig: 's' * 128,
);

/// Wait for async providers (identity / follows) to resolve + dependents to
/// rebuild (same pattern as feed_own_post_test.dart).
Future<void> pollUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > timeout) fail('condition not met within $timeout');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('hashtagAlts', () {
    test('mixed-case tag expands to original + lower + UPPER', () {
      // Capitalized == original here → deduped.
      expect(hashtagAlts('Flutter'), ['Flutter', 'flutter', 'FLUTTER']);
    });

    test('lowercase tag expands to lower + UPPER + Capitalized', () {
      expect(hashtagAlts('nostr'), ['nostr', 'NOSTR', 'Nostr']);
    });

    test('caseless tag (CJK) yields a single variant', () {
      expect(hashtagAlts('中文'), ['中文']);
    });

    test('empty tag yields nothing', () {
      expect(hashtagAlts(''), isEmpty);
    });
  });

  group('followingTagFeedProvider', () {
    late _FakeRelay relay;
    late RelayPool pool;
    late ProviderContainer container;

    ProviderContainer buildContainer(
      String? filter,
      List<Event> store, {
      RelayPool? poolOverride,
    }) {
      return ProviderContainer(
        overrides: [
          feedModeProvider.overrideWith(() => _FollowingMode()),
          languageFilterProvider.overrideWith(() => _NoLangFilter()),
          tagFilterProvider.overrideWith(() => _NoTagFilter()),
          followingFilterProvider.overrideWith(
            () => _FixedFollowingFilter(filter),
          ),
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows(['a' * 64])),
          eventStoreProvider.overrideWith(() => _FixedStore(store)),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
          feedSubscriptionProvider.overrideWith((ref) {}),
          followingOutboxProvider.overrideWith((ref) {}),
          if (poolOverride != null)
            relayPoolProvider.overrideWith((ref) => poolOverride),
        ],
      );
    }

    setUp(() async {
      relay = _FakeRelay('wss://a');
      await relay.connect();
      pool = RelayPool([relay]);
    });

    tearDown(() async {
      container.dispose();
      await pool.dispose();
    });

    test(
      'cold start: #t REQ with alts, kinds [1,6], limit 100, no since',
      () async {
        container = buildContainer('tag:flutter', const [], poolOverride: pool);
        // Listen (not read): keeps the provider alive while its async dep
        // (identity) resolves and the rebuild issues the REQ.
        final sub = container.listen(followingTagFeedProvider, (_, _) {});
        addTearDown(sub.close);
        await pollUntil(() => relay.sent.any((f) => f[0] == 'REQ'));

        final reqs = relay.sent.where((f) => f[0] == 'REQ').toList();
        expect(reqs, hasLength(1));
        final filter = reqs.single[2] as Map<String, dynamic>;
        expect(filter['#t'], ['flutter', 'FLUTTER', 'Flutter']);
        expect(filter['kinds'], [1, 6]);
        expect(filter['limit'], 100);
        expect(filter.containsKey('since'), isFalse);
      },
    );

    test(
      'held tagged posts do NOT set a since cursor (v1.1.1 regression)',
      () async {
        // Tagged posts are SPARSE: already holding a few recent ones (e.g.
        // followees' tagged posts in the store) says nothing about older
        // history. v1.1.1 anchored `since` at the newest held tagged post,
        // which made relays serve only NEWER posts — permanently cutting off
        // all history ("还是只有最近几个帖子，刷新也没有"). The REQ must
        // carry NO `since` even when tagged posts are already held.
        final store = [
          _post(
            '1',
            'x' * 64,
            100,
            tags: const [
              ['t', 'flutter'],
            ],
          ),
          _post(
            '2',
            'y' * 64,
            500,
            tags: const [
              ['t', 'flutter'],
            ],
          ),
          _post('3', 'z' * 64, 900),
        ];
        container = buildContainer('tag:flutter', store, poolOverride: pool);
        final sub = container.listen(followingTagFeedProvider, (_, _) {});
        addTearDown(sub.close);
        await pollUntil(() => relay.sent.any((f) => f[0] == 'REQ'));

        final filter =
            relay.sent.where((f) => f[0] == 'REQ').single[2]
                as Map<String, dynamic>;
        expect(filter.containsKey('since'), isFalse);
        expect(filter['limit'], 100);
      },
    );

    test('teardown closes the subscription', () async {
      container = buildContainer('tag:flutter', const [], poolOverride: pool);
      final sub = container.listen(followingTagFeedProvider, (_, _) {});
      await pollUntil(() => relay.sent.any((f) => f[0] == 'REQ'));
      final reqFrame = relay.sent.firstWhere((f) => f[0] == 'REQ');
      final subId = reqFrame[1] as String;
      sub.close();
      container.dispose();
      expect(relay.sent.last, ['CLOSE', subId]);
      // Re-create for tearDown (it disposes again — harmless).
      container = buildContainer(null, const [], poolOverride: pool);
    });

    test('non-tag filter issues no REQ', () async {
      container = buildContainer('group:friends', const [], poolOverride: pool);
      final sub = container.listen(followingTagFeedProvider, (_, _) {});
      addTearDown(sub.close);
      // Give the provider a resolved identity + rebuild cycles; a tag REQ
      // would have fired by now.
      await container.read(identityProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(relay.sent.where((f) => f[0] == 'REQ'), isEmpty);
    });
  });

  group('currentFeedEventsProvider with a tag filter', () {
    late String me;

    setUp(() {
      me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    });

    ProviderContainer buildContainer(String? filter, List<Event> store) {
      return ProviderContainer(
        overrides: [
          feedModeProvider.overrideWith(() => _FollowingMode()),
          languageFilterProvider.overrideWith(() => _NoLangFilter()),
          tagFilterProvider.overrideWith(() => _NoTagFilter()),
          followingFilterProvider.overrideWith(
            () => _FixedFollowingFilter(filter),
          ),
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows(['f' * 64])),
          eventStoreProvider.overrideWith(() => _FixedStore(store)),
          myMuteSetProvider.overrideWith((ref) => const MuteSet()),
          feedSubscriptionProvider.overrideWith((ref) {}),
          followingOutboxProvider.overrideWith((ref) {}),
          followingTagFeedProvider.overrideWith((ref) {}),
        ],
      );
    }

    test('tag feed shows tagged posts from ANY author, hides untagged', () {
      final store = [
        // Tagged, author NOT followed → must appear (old code dropped it via
        // the followee-author restriction).
        _post(
          'tagged-stranger',
          's' * 64,
          300,
          tags: const [
            ['t', 'flutter'],
          ],
        ),
        // Tagged + followed → appears.
        _post(
          'tagged-followee',
          'f' * 64,
          200,
          tags: const [
            ['t', 'flutter'],
          ],
        ),
        // Followed but UNTAGGED → hidden while the tag filter is active.
        _post('plain-followee', 'f' * 64, 100),
      ];
      final container = buildContainer('tag:flutter', store);
      addTearDown(container.dispose);

      final feed = container.read(currentFeedEventsProvider);
      expect(feed.map((e) => e.id), ['tagged-stranger', 'tagged-followee']);
    });

    test('inline #hashtag in content also matches', () {
      final inline = Event(
        id: 'inline',
        pubkey: 's' * 64,
        createdAt: 100,
        kind: 1,
        tags: const [],
        content: 'hello #Flutter world',
        sig: 's' * 128,
      );
      final container = buildContainer('tag:flutter', [inline]);
      addTearDown(container.dispose);

      final feed = container.read(currentFeedEventsProvider);
      expect(feed.map((e) => e.id), ['inline']);
    });

    test(
      'no filter: followee restriction still applies (no regression)',
      () async {
        final store = [
          _post(
            'tagged-stranger',
            's' * 64,
            300,
            tags: const [
              ['t', 'flutter'],
            ],
          ),
          _post('plain-followee', 'f' * 64, 100),
          _post('own', me, 50),
        ];
        final container = buildContainer(null, store);
        addTearDown(container.dispose);
        final sub = container.listen(currentFeedEventsProvider, (_, _) {});
        addTearDown(sub.close);
        // Async deps (identity / follows) resolve after the first build:
        // 'own' passes via the identity check, 'plain-followee' only once
        // the follows list lands — wait for BOTH.
        await pollUntil(() {
          final ids = container
              .read(currentFeedEventsProvider)
              .map((e) => e.id)
              .toSet();
          return ids.contains('own') && ids.contains('plain-followee');
        });

        final feed = container
            .read(currentFeedEventsProvider)
            .map((e) => e.id)
            .toList();
        expect(feed, ['plain-followee', 'own']);
      },
    );
  });

  group('followingOutboxProvider', () {
    test('tag filter active → paused, never touches the relay pool', () {
      final container = ProviderContainer(
        overrides: [
          feedModeProvider.overrideWith(() => _FollowingMode()),
          identityProvider.overrideWith(() => _Id()),
          followingStateProvider.overrideWith(() => _Follows(['a' * 64])),
          followingFilterProvider.overrideWith(
            () => _FixedFollowingFilter('tag:flutter'),
          ),
          eventStoreProvider.overrideWith(() => _FixedStore(const [])),
          // If the provider ran (built the outbox router / me-sub), it would
          // watch the pool and this override would throw.
          relayPoolProvider.overrideWith(
            (ref) => throw StateError('pool must not be touched'),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(() => container.read(followingOutboxProvider), returnsNormally);
    });
  });
}
