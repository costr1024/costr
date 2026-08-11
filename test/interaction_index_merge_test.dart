// Regression: the interaction display (like tallies, reaction chips, the
// user's own filled heart, the 「谁点赞/转发了」chevron) must survive the
// capped store's kind-7 eviction. On a saturated global firehose every
// incoming event evicts the oldest kind-7 — a fetched or self-published
// reaction lives ~25ms in the store, which left all of the above invisible
// ("点赞不显示、点了几次都没用": the user's own likes reached the relays but
// never rendered). The merge in InteractionIndexNotifier must therefore
// combine the store with the eviction-proof InteractionCache.
//
// Simulates saturation directly: a store that holds no kind-7 at all (its
// steady state on a busy firehose) + the interactions living only in the
// cache tier.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
final String _postId = 'p' * 64;
final String _author = 'a' * 64;

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Fixed in-memory store (no SQLite / relay wiring in this test). Passing a
/// list WITHOUT any kind-7 mirrors a saturated firehose store, where kind-7
/// retention is ~25ms.
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _post() => Event(
  id: _postId,
  pubkey: _author,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: 'the post',
  sig: 's' * 128,
);

Event _reaction({
  required String id,
  String pubkey = 'b',
  String content = '+',
  int at = 1700000100,
  int kind = 7,
}) => Event(
  id: id.padRight(64, '0'),
  pubkey: pubkey.padRight(64, '0'),
  createdAt: at,
  kind: kind,
  tags: [
    ['e', _postId],
    ['p', _author],
  ],
  content: content,
  sig: 's' * 128,
);

void main() {
  Future<ProviderContainer> makeContainer({
    List<Event> store = const [],
  }) async {
    final container = ProviderContainer(
      overrides: [
        eventStoreProvider.overrideWith(() => _FixedStore(store)),
        identityProvider.overrideWith(() => _Id()),
      ],
    );
    // Let the identity resolve so myReaction detection works.
    await container.read(identityProvider.future);
    return container;
  }

  test('cache-only reaction is tallied when the store holds none', () async {
    // Saturated-store steady state: the post is held, its reactions are not.
    final container = await makeContainer(store: [_post()]);
    addTearDown(container.dispose);

    final statsBefore = container.read(interactionIndexProvider)[_postId];
    expect(statsBefore?.reactions ?? const {}, isEmpty);

    container.read(interactionCacheProvider.notifier).ingest([
      _reaction(id: 'like1'),
    ]);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.reactions['👍']?.count, 1);
    // Chevron gate (PostActions): reposts + reaction total > 0.
    final total = stats.reactions.values.fold(0, (int s, t) => s + t.count);
    expect(stats.reposts + total, greaterThan(0));
  });

  test('own published reaction fills the heart + tallies', () async {
    final container = await makeContainer(store: [_post()]);
    addTearDown(container.dispose);
    final me = container.read(identityProvider).value!.pubkeyHex;

    container.read(interactionCacheProvider.notifier).ingest([
      _reaction(id: 'mine', pubkey: me, content: '❤️'),
    ]);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.myReaction, isNotNull);
    expect(stats.myReaction!.content, '❤️');
    expect(stats.reactions['❤️']?.count, 1);
  });

  test('an event held in BOTH tiers counts exactly once', () async {
    final like = _reaction(id: 'dup');
    final container = await makeContainer(store: [_post(), like]);
    addTearDown(container.dispose);

    container.read(interactionCacheProvider.notifier).ingest([like]);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.reactions['👍']?.count, 1);
  });

  test('store-only reactions still count (quiet-feed path intact)', () async {
    final container = await makeContainer(
      store: [
        _post(),
        _reaction(id: 'seen'),
      ],
    );
    addTearDown(container.dispose);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.reactions['👍']?.count, 1);
  });

  test('cancel-reaction removes it from the cache tier', () async {
    final container = await makeContainer(store: [_post()]);
    addTearDown(container.dispose);
    final me = container.read(identityProvider).value!.pubkeyHex;
    final mine = _reaction(id: 'mine', pubkey: me, content: '❤️');

    final cache = container.read(interactionCacheProvider.notifier);
    cache.ingest([mine]);
    expect(
      container.read(interactionIndexProvider)[_postId]!.myReaction,
      isNotNull,
    );

    cache.removeEvent(mine.id);
    final stats = container.read(interactionIndexProvider)[_postId];
    expect(stats?.myReaction, isNull);
    expect(stats?.reactions ?? const {}, isEmpty);
  });

  test('cache kind-6 repost bumps the repost count', () async {
    final container = await makeContainer(store: [_post()]);
    addTearDown(container.dispose);

    container.read(interactionCacheProvider.notifier).ingest([
      _reaction(id: 'rp', kind: 6, content: ''),
    ]);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.reposts, 1);
  });

  test('newest own reaction wins across tiers', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    final older = _reaction(id: 'old', pubkey: me, content: '👍', at: 100);
    final container = await makeContainer(store: [_post(), older]);
    addTearDown(container.dispose);

    container.read(interactionCacheProvider.notifier).ingest([
      _reaction(id: 'new', pubkey: me, content: '🔥', at: 200),
    ]);

    final stats = container.read(interactionIndexProvider)[_postId]!;
    expect(stats.myReaction!.id, 'new'.padRight(64, '0'));
  });
}
