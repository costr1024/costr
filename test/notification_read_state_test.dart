// Tests for the persisted notification read-state notifier + unread count.
// Uses a ProviderContainer with the SQLite config stubbed via an in-memory
// stand-in that implements just readConfig/writeConfig (the only methods
// NotificationReadNotifier touches).

import 'dart:collection';
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal LocalCache stand-in: only readConfig/writeConfig are used by the
/// notifier. Stored in-memory so tests need no SQLite native lib.
class _StubCache implements cache.LocalCache {
  final Map<String, String> _cfg = {};

  @override
  Future<String?> readConfig(String key) async => _cfg[key];

  @override
  Future<void> writeConfig(String key, String value) async {
    _cfg[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('NotificationReadNotifier', () {
    test('markRead makes ids read + persists to config (debounced)', () async {
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);

      // Wait for the async hydrate (localCacheProvider resolves → _hydrate).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(notificationReadProvider), isEmpty);

      final notifier = container.read(notificationReadProvider.notifier);
      notifier.markRead(['reply:a1', 'reaction:b2']);
      expect(notifier.isUnread('reply:a1'), isFalse);
      expect(notifier.isUnread('reaction:b2'), isFalse);
      expect(notifier.isUnread('mention:c3'), isTrue);

      // Debounced write fires after 500ms.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final raw = stub._cfg['read_notifications'];
      expect(raw, isNotNull);
      final list = (jsonDecode(raw!) as List).cast<String>();
      expect(list.toSet(), {'reply:a1', 'reaction:b2'});
    });

    test('read-set hydrates from config on cold start', () async {
      final stub = _StubCache()
        .._cfg['read_notifications'] = jsonEncode(['mention:x', 'follow:y']);
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Trigger build (localCacheProvider is already resolved → _hydrate(db)
      // is kicked off synchronously inside build, but runs async).
      container.read(notificationReadProvider);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final read = container.read(notificationReadProvider);
      expect(read.contains('mention:x'), isTrue);
      expect(read.contains('follow:y'), isTrue);
      expect(read.contains('reply:z'), isFalse);
    });

    test('markRead is idempotent (no spurious dirty / state churn)', () async {
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final notifier = container.read(notificationReadProvider.notifier);
      notifier.markRead(['a']);
      final firstState = container.read(notificationReadProvider);
      // Marking the same id again must not dirty (state identical).
      notifier.markRead(['a']);
      expect(container.read(notificationReadProvider), same(firstState));
    });

    test('read-set caps at 1500 (evicts oldest-inserted)', () async {
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final notifier = container.read(notificationReadProvider.notifier);
      final ids = [for (var i = 0; i < 1600; i++) 'item:$i'];
      notifier.markRead(ids);
      final read = container.read(notificationReadProvider) as LinkedHashSet;
      expect(read.length, 1500);
      // Oldest (item:0) evicted, newest (item:1599) kept.
      expect(read.contains('item:0'), isFalse);
      expect(read.contains('item:1599'), isTrue);
    });
  });

  group('unreadNotificationCountProvider', () {
    test('returns 0 when there are no notifications', () {
      final stub = _StubCache();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => stub),
        ],
      );
      addTearDown(container.dispose);
      // notificationsProvider(pk) with an empty pool → no events → empty list.
      expect(container.read(unreadNotificationCountProvider('pk')), 0);
    });
  });
}
