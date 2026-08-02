// Tests for NIP-09 kind-5 deletion handling in EventStoreNotifier:
// `a`-coordinate replaceable deletes (author-validated) + `e`-id event
// deletes (author-validated). Driven by pool.publish (echoes to the merged
// stream the notifier listens to).

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _p =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; // 'a'*64
const _q =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; // 'b'*64

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

/// Stub cache: records deletions, no-ops writes, returns empty for hydrate
/// queries. Only the methods EventStoreNotifier touches are implemented.
class _StubCache implements cache.LocalCache {
  final List<({String pubkey, int kind, String d})> coordDeletes = [];
  final List<String> eventDeletes = [];

  @override
  Future<void> deleteReplaceableByCoord(
    String pubkey,
    int kind,
    String d,
  ) async {
    coordDeletes.add((pubkey: pubkey, kind: kind, d: d));
  }

  @override
  Future<void> deleteEvent(String id) async => eventDeletes.add(id);

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

Event _post(String id, String pubkey) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: 'hi',
  sig: 's' * 128,
);

Event _del5(String pubkey, List<List<String>> tags) => Event(
  id: 'del-${pubkey.substring(0, 4)}',
  pubkey: pubkey,
  createdAt: 1700000001,
  kind: 5,
  tags: tags,
  content: '',
  sig: 's' * 128,
);

void main() {
  late ProviderContainer container;
  late _StubCache stub;

  setUp(() async {
    stub = _StubCache();
    container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith((ref) async => stub),
        identityProvider.overrideWith(() => _NullId()),
      ],
    );
    addTearDown(container.dispose);
    // Build the store (wires the pool.events listener + hydrate).
    container.read(eventStoreProvider.notifier);
    await Future<void>.delayed(const Duration(milliseconds: 30));
  });

  group('NIP-09 kind-5 _applyDeletion', () {
    test('a-tag: deletes own replaceable coordinate, ignores others', () async {
      final pool = container.read(relayPoolProvider);
      // Deletion by P: deletes P's 30000:groupX (own) and Q's 30000:groupY (not own → ignored).
      pool.publish(
        _del5(_p, const [
          ['a', '30000:$_p:groupX'],
          ['a', '30000:$_q:groupY'],
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(stub.coordDeletes, [(pubkey: _p, kind: 30000, d: 'groupX')]);
      expect(stub.coordDeletes.any((c) => c.pubkey == _q), isFalse);
    });

    test('e-tag: removes own post from store + cache, ignores others', () async {
      final pool = container.read(relayPoolProvider);
      final store = container.read(eventStoreProvider.notifier);
      // Two posts: post1 by P, post2 by Q.
      await store.ingest(_post('post1', _p));
      await store.ingest(_post('post2', _q));
      // ingest batches state via _scheduleFlush (200ms); let it flush before
      // asserting so the public state reflects the store.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(
        container.read(eventStoreProvider).map((e) => e.id),
        containsAll(['post1', 'post2']),
      );

      // Deletion by P targeting post1 (own → removed) and post2 (not own → kept).
      pool.publish(
        _del5(_p, const [
          ['e', 'post1'],
          ['e', 'post2'],
        ]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final ids = container.read(eventStoreProvider).map((e) => e.id).toSet();
      expect(ids.contains('post1'), isFalse); // removed (own)
      expect(ids.contains('post2'), isTrue); // kept (not the deleter's)
      expect(stub.eventDeletes, ['post1']);
      expect(stub.eventDeletes.contains('post2'), isFalse);
    });
  });
}
