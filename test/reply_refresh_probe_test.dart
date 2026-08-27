// Regression probe for 「回复完不立即显示在主贴下方」: compose persists the
// sent reply to SQLite and invalidates repliesProvider, yet users still see
// the reply missing under the parent post. Reproduce the exact persist +
// invalidate flow at the provider level against the REAL repliesProvider.

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCache implements cache.LocalCache {
  final Map<String, List<cache.EventRow>> repliesByParent = {};

  @override
  Future<List<cache.EventRow>> queryReplies(String eventId) async =>
      repliesByParent[eventId] ?? const [];

  @override
  Future<cache.EventRow?> queryEventById(String id) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

cache.EventRow _row(Event e) => cache.EventRow(
      id: e.id,
      pubkey: e.pubkey,
      kind: e.kind,
      createdAt: e.createdAt,
      content: e.content,
      sig: e.sig,
      raw: jsonEncode(e.toWireObject()),
      tagsJson: jsonEncode(e.tags),
      receivedAt: 0,
    );

Future<void> _waitUntil(
  bool Function() cond, {
  required String reason,
  Duration budget = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(budget);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  const root =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const me =
      'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

  Event myReply(String id) => Event(
        id: id,
        pubkey: me,
        createdAt: 1700000000,
        kind: 1,
        tags: [
          ['e', root, '', 'root'],
          ['e', root, '', 'reply'],
          ['p', 'dd' * 32, ''],
        ],
        content: 'my reply',
        sig: 's',
      );

  test('persist + invalidate surfaces the own reply under the parent', () async {
    final fake = _FakeCache();
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith((ref) async => fake),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(
      repliesProvider(root),
      (prev, next) {},
      fireImmediately: true,
    );

    // First visit: resolves to an (empty) reply list.
    await _waitUntil(
      () => sub.read() is AsyncData<List<Event>>,
      reason: 'first visit resolves',
    );
    expect(sub.read().value, isEmpty);

    // Compose send path: persist the reply to SQLite, then invalidate.
    final reply = myReply('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
    fake.repliesByParent[root] = [_row(reply)];
    container.invalidate(repliesProvider(root));

    // The thread page (still listening) must now see the reply.
    await _waitUntil(
      () =>
          sub.read().value?.any((e) => e.id == reply.id) ?? false,
      reason: 'invalidated provider re-yields with the persisted reply',
    );
    expect(sub.read().value!.single.id, reply.id);
  });

  test(
    'invalidate with NO listener (reply sent from the feed, thread closed) '
    'still refetches on the next visit',
    () async {
      final fake = _FakeCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => fake),
        ],
      );
      addTearDown(container.dispose);
      // Resolve the fake DB BEFORE any provider runs — otherwise the
      // providers' SQLite tiers read a still-loading localCacheProvider and
      // fall back to the slow (timeout-bound) relay paths.
      await container.read(localCacheProvider.future);

      // First visit: open the thread, let it resolve, then LEAVE (close the
      // subscription — the page was popped).
      var sub = container.listen(
        repliesProvider(root),
        (prev, next) {},
        fireImmediately: true,
      );
      await _waitUntil(
        () => sub.read() is AsyncData<List<Event>>,
        reason: 'first visit resolves',
      );
      expect(sub.read().value, isEmpty);
      sub.close();

      // Reply sent from the feed card — compose persists + invalidates while
      // NO thread page is listening.
      final reply = myReply(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      fake.repliesByParent[root] = [_row(reply)];
      container.invalidate(repliesProvider(root));

      // The user opens the thread again — must see the reply.
      sub = container.listen(
        repliesProvider(root),
        (prev, next) {},
        fireImmediately: true,
      );
      await _waitUntil(
        () => sub.read().value?.any((e) => e.id == reply.id) ?? false,
        reason: 'revisit after listener-less invalidate sees the reply',
      );
      expect(sub.read().value!.single.id, reply.id);
    },
  );

  test(
    'mis-tagged reply (root tag points at the wrong ancestor) is rescued '
    'by the BFS cache tier',
    () async {
      // The replied-to post X sits mid-chain and correctly tags the true
      // root R. The user's reply to X was signed against X's own (legacy,
      // marker-less) root marker, so its e-tags are {P, X} — it never tags
      // R. A flat queryReplies(R) misses it forever; the BFS tier must walk
      // R → X → reply.
      final fake = _FakeCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => fake),
        ],
      );
      addTearDown(container.dispose);
      // Resolve the fake DB BEFORE any provider runs — otherwise the
      // providers' SQLite tiers read a still-loading localCacheProvider and
      // fall back to the slow (timeout-bound) relay paths.
      await container.read(localCacheProvider.future);

      const parent =
          'pppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppppp';
      final x = Event(
        id: 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
        pubkey: 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
        createdAt: 1699999990,
        kind: 1,
        tags: [
          ['e', root, '', 'root'],
          ['e', parent, '', 'reply'],
        ],
        content: 'mid-chain post',
        sig: 's',
      );
      final reply = Event(
        id: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        pubkey: me,
        createdAt: 1700000000,
        kind: 1,
        tags: [
          ['e', parent, '', 'root'], // WRONG root — the bug shape
          ['e', x.id, '', 'reply'],
        ],
        content: 'my reply',
        sig: 's',
      );
      fake.repliesByParent[root] = [_row(x)];
      fake.repliesByParent[x.id] = [_row(reply)];

      final sub = container.listen(
        repliesProvider(root),
        (prev, next) {},
        fireImmediately: true,
      );
      await _waitUntil(
        () => sub.read().value?.any((e) => e.id == reply.id) ?? false,
        reason: 'BFS cache tier walks R → X → mis-tagged reply',
      );
    },
  );

  test('revisit refetches fresh data without any invalidate (autoDispose)', () async {
    final fake = _FakeCache();
    final container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith((ref) async => fake),
      ],
    );
    addTearDown(container.dispose);

    var sub = container.listen(
      repliesProvider(root),
      (prev, next) {},
      fireImmediately: true,
    );
    await _waitUntil(
      () => sub.read() is AsyncData<List<Event>>,
      reason: 'first visit resolves',
    );
    expect(sub.read().value, isEmpty);
    sub.close();
    // Let autoDispose reclaim the listener-less provider.
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A reply lands in SQLite while no thread page is open.
    final reply = myReply(
      'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    );
    fake.repliesByParent[root] = [_row(reply)];

    // Re-entering the thread must refetch — no invalidate anywhere.
    sub = container.listen(
      repliesProvider(root),
      (prev, next) {},
      fireImmediately: true,
    );
    await _waitUntil(
      () => sub.read().value?.any((e) => e.id == reply.id) ?? false,
      reason: 'autoDispose revisit refetches the new reply',
    );
  });
}
