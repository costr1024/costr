// Tests for the persisted notification read-state (per-account read set +
// read watermark) + unread count. Uses a ProviderContainer with the SQLite
// config stubbed via an in-memory stand-in that implements just
// readConfig/writeConfig/queryUserPosts (the only methods the notifiers and
// the notification generator touch).

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal LocalCache stand-in. Stored in-memory so tests need no SQLite
/// native lib. queryUserPosts must be overridden explicitly: the notification
/// generator awaits it for the stable own-post snapshot (noSuchMethod would
/// throw — the generator catches that, but tests want it deterministic).
class _StubCache implements cache.LocalCache {
  final Map<String, String> _cfg = {};
  List<cache.EventRow> ownPosts = const [];

  @override
  Future<String?> readConfig(String key) async => _cfg[key];

  @override
  Future<void> writeConfig(String key, String value) async {
    _cfg[key] = value;
  }

  @override
  Future<List<cache.EventRow>> queryUserPosts(
    String pubkey, {
    int limit = 100,
  }) async => ownPosts;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(_StubCache stub) {
  final container = ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      localCacheProvider.overrideWith((ref) async => stub),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

NotificationItem _item({
  required String id,
  required int time,
  NotificationType type = NotificationType.reply,
}) => NotificationItem(
  type: type,
  pubkeys: const ['p'],
  extraCount: 0,
  time: time,
  id: id,
  unread: true,
);

void main() {
  group('NotificationReadNotifier (per-account family)', () {
    test('markRead makes ids read + persists to per-account config', () async {
      final stub = _StubCache();
      final container = _container(stub);

      // Wait for the async hydrate (localCacheProvider resolves → _hydrate).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(notificationReadProvider('pk')), isEmpty);

      final notifier = container.read(notificationReadProvider('pk').notifier);
      notifier.markRead(['reply:a1', 'reaction:b2']);
      expect(notifier.isUnread('reply:a1'), isFalse);
      expect(notifier.isUnread('reaction:b2'), isFalse);
      expect(notifier.isUnread('mention:c3'), isTrue);

      // Debounced write fires after 500ms under the PER-ACCOUNT key.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final raw = stub._cfg['read_notifications:pk'];
      expect(raw, isNotNull);
      final list = (jsonDecode(raw!) as List).cast<String>();
      expect(list.toSet(), {'reply:a1', 'reaction:b2'});
      expect(stub._cfg.containsKey('read_notifications'), isFalse);
    });

    test('read-set hydrates from per-account config on cold start', () async {
      final stub = _StubCache()
        .._cfg['read_notifications:pk'] = jsonEncode([
          'mention:x',
          'follow:y',
        ]);
      final container = _container(stub);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      container.read(notificationReadProvider('pk'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final read = container.read(notificationReadProvider('pk'));
      expect(read.contains('mention:x'), isTrue);
      expect(read.contains('follow:y'), isTrue);
      expect(read.contains('reply:z'), isFalse);
    });

    test('legacy global key seeds the per-account set (migration)', () async {
      // Pre-per-account builds wrote one GLOBAL 'read_notifications' key. The
      // first family hydrate seeds from it AND persists the per-account copy.
      final stub = _StubCache()
        .._cfg['read_notifications'] = jsonEncode(['legacy:a', 'legacy:b']);
      final container = _container(stub);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      container.read(notificationReadProvider('pk'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final read = container.read(notificationReadProvider('pk'));
      expect(read.contains('legacy:a'), isTrue);
      expect(read.contains('legacy:b'), isTrue);
      // Migrated copy persisted per-account; legacy key kept for the device's
      // second account.
      expect(stub._cfg['read_notifications:pk'], isNotNull);
      expect(
        (jsonDecode(stub._cfg['read_notifications:pk']!) as List).toSet(),
        containsAll(['legacy:a', 'legacy:b']),
      );
      expect(stub._cfg.containsKey('read_notifications'), isTrue);
    });

    test('two accounts on one device keep isolated read sets', () async {
      final stub = _StubCache();
      final container = _container(stub);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      container.read(notificationReadProvider('a').notifier).markRead(['x']);
      expect(container.read(notificationReadProvider('a')).contains('x'), isTrue);
      expect(container.read(notificationReadProvider('b')).contains('x'), isFalse);
    });

    test('markRead is idempotent (no spurious dirty / state churn)', () async {
      final stub = _StubCache();
      final container = _container(stub);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final notifier = container.read(notificationReadProvider('pk').notifier);
      notifier.markRead(['a']);
      final firstState = container.read(notificationReadProvider('pk'));
      // Marking the same id again must not dirty (state identical).
      notifier.markRead(['a']);
      expect(container.read(notificationReadProvider('pk')), same(firstState));
    });

    test('read-set caps at 5000 (evicts oldest-inserted)', () async {
      final stub = _StubCache();
      final container = _container(stub);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final notifier = container.read(notificationReadProvider('pk').notifier);
      final ids = [for (var i = 0; i < 5100; i++) 'item:$i'];
      notifier.markRead(ids);
      final read =
          container.read(notificationReadProvider('pk')) as LinkedHashSet;
      expect(read.length, 5000);
      // Oldest (item:0) evicted, newest (item:5099) kept.
      expect(read.contains('item:0'), isFalse);
      expect(read.contains('item:5099'), isTrue);
    });

    test('markRead before hydration completes survives hydration (union)',
        () async {
      // Cold start: the user taps 全部已读 while SQLite still opens. Hydration
      // must UNION the persisted set with the fresh in-memory marks —
      // replacing the set would clobber them and resurrect unread dots.
      final stub = _StubCache()
        .._cfg['read_notifications:pk'] = jsonEncode(['old:x']);
      final container = _container(stub);

      // Mark read synchronously — before the async _hydrate reads the config.
      container.read(notificationReadProvider('pk').notifier).markRead([
        'new:y',
      ]);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final read = container.read(notificationReadProvider('pk'));
      expect(
        read.contains('new:y'),
        isTrue,
        reason: 'fresh mark made before hydration must survive it',
      );
      expect(
        read.contains('old:x'),
        isTrue,
        reason: 'persisted set must still hydrate',
      );
    });

    test('markRead while the DB is STILL opening persists (no dropped write)',
        () async {
      // The debounced write fires at 500ms but the DB only opens at 600ms —
      // the old `.value == null` path silently dropped the write.
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async {
            await Future<void>.delayed(const Duration(milliseconds: 600));
            return stub;
          }),
        ],
      );
      addTearDown(container.dispose);

      container.read(notificationReadProvider('pk').notifier).markRead(['a1']);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final raw = stub._cfg['read_notifications:pk'];
      expect(raw, isNotNull, reason: 'write must await the DB open');
      expect((jsonDecode(raw!) as List).cast<String>(), contains('a1'));
    });

    test('pending debounced write flushes on dispose', () async {
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      container.read(notificationReadProvider('pk').notifier).markRead(['z9']);
      // Dispose INSIDE the 500ms debounce window — the pending write must
      // flush instead of being cancelled (kill-the-app-after-全部已读).
      container.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final raw = stub._cfg['read_notifications:pk'];
      expect(raw, isNotNull);
      expect((jsonDecode(raw!) as List).cast<String>(), contains('z9'));
    });
  });

  group('notificationIsUnread', () {
    test('truth table across watermark + read set', () {
      final read = {'a', 'b'};
      // Newer than watermark, id not read → unread.
      expect(
        notificationIsUnread(_item(id: 'c', time: 200), read, 100),
        isTrue,
      );
      // Newer than watermark but id read → read.
      expect(
        notificationIsUnread(_item(id: 'a', time: 200), read, 100),
        isFalse,
      );
      // At/below watermark → read EVEN IF the id is absent from the set
      // (eviction / key churn can no longer resurrect it).
      expect(
        notificationIsUnread(_item(id: 'zz', time: 100), read, 100),
        isFalse,
      );
      expect(
        notificationIsUnread(_item(id: 'zz', time: 50), read, 100),
        isFalse,
      );
    });
  });

  group('NotificationWatermarkNotifier', () {
    test('advance is monotonic, capped at now, write-through', () async {
      final stub = _StubCache();
      final container = _container(stub);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final notifier = container.read(
        notificationWatermarkProvider('pk').notifier,
      );
      notifier.advance(1000);
      expect(container.read(notificationWatermarkProvider('pk')), 1000);
      // Monotonic: smaller values are ignored.
      notifier.advance(500);
      expect(container.read(notificationWatermarkProvider('pk')), 1000);
      // Write-through (no debounce): persisted immediately.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(stub._cfg['read_notifications_watermark:pk'], '1000');
      // Future-dated events are capped at wall-clock now.
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      notifier.advance(now + 100000);
      final wm = container.read(notificationWatermarkProvider('pk'));
      expect(wm, greaterThan(1000));
      expect(wm, lessThanOrEqualTo(now));
    });

    test('hydrate merges max (no rollback of a pre-hydration advance)',
        () async {
      final stub = _StubCache()
        .._cfg['read_notifications_watermark:pk'] = '9000';
      final container = _container(stub);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // First read builds the notifier and kicks the async hydrate.
      container.read(notificationWatermarkProvider('pk'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(notificationWatermarkProvider('pk')), 9000);

      // A SMALLER persisted value must not roll back a larger in-memory one.
      final stub2 = _StubCache()
        .._cfg['read_notifications_watermark:pk'] = '50';
      final container2 = _container(stub2);
      container2.read(notificationWatermarkProvider('pk').notifier).advance(
        1000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container2.read(notificationWatermarkProvider('pk')), 1000);
    });

    test('fully-reading the list collapses it into the watermark (widget flow)',
        () async {
      // Mirrors what the tile does via compactNotificationWatermarkIfFullyRead
      // (that helper needs a WidgetRef; at the container level the same
      // sequence is: check count == 0, then advance to the max item time).
      final stub = _StubCache();
      final items = [
        _item(id: 'a', time: 1000),
        _item(id: 'b', time: 2000),
        _item(id: 'c', time: 1500),
      ];
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
          notificationsProvider.overrideWith(
            (ref, arg) => Stream.value(items),
          ),
        ],
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sub = container.listen(notificationsProvider('pk'), (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final readNotifier = container.read(
        notificationReadProvider('pk').notifier,
      );
      final wmNotifier = container.read(
        notificationWatermarkProvider('pk').notifier,
      );

      // While something is still unread, no compaction happens.
      readNotifier.markRead(['a', 'b']);
      expect(container.read(unreadNotificationCountProvider('pk')), 1);
      expect(container.read(notificationWatermarkProvider('pk')), 0);

      // Reading the last unread item → count hits 0 → the whole list folds
      // under the watermark (max item time), so later read-set evictions
      // cannot resurrect any of it.
      readNotifier.markRead(['c']);
      expect(container.read(unreadNotificationCountProvider('pk')), 0);
      wmNotifier.advance(2000);
      expect(container.read(notificationWatermarkProvider('pk')), 2000);
      expect(container.read(unreadNotificationCountProvider('pk')), 0);
      // An item whose id is NOT in the read set but sits at/below the
      // watermark stays read — eviction-proof.
      final read = container.read(notificationReadProvider('pk'));
      expect(read.contains('a'), isTrue);
      expect(
        notificationIsUnread(_item(id: 'ghost', time: 1900), read, 2000),
        isFalse,
      );
    });
  });

  group('unreadNotificationCountProvider', () {
    test('returns 0 when there are no notifications', () {
      final stub = _StubCache();
      final container = _container(stub);
      // notificationsProvider(pk) with an empty pool → no events → empty list.
      expect(container.read(unreadNotificationCountProvider('pk')), 0);
    });

    test('watermark suppresses items regardless of the read set', () async {
      final stub = _StubCache();
      final items = [
        _item(id: 'old', time: 1000), // covered by watermark, NOT in read set
        _item(id: 'new', time: 3000), // unread
        _item(id: 'readNew', time: 3000), // read via the set
      ];
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
          notificationsProvider.overrideWith(
            (ref, arg) => Stream.value(items),
          ),
        ],
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sub = container.listen(notificationsProvider('pk'), (_, _) {});
      addTearDown(sub.close);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      container.read(notificationReadProvider('pk').notifier).markRead([
        'readNew',
      ]);
      container
          .read(notificationWatermarkProvider('pk').notifier)
          .advance(2000);
      expect(container.read(unreadNotificationCountProvider('pk')), 1);
    });
  });
}
