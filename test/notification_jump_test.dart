// Widget tests for the double-tap-bottom-nav-bell jump: the notifications
// page scrolls to the TOPMOST UNREAD item and flashes it; with nothing
// unread it falls back to scroll-to-top.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/app/theme.dart';
import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _StubCache implements cache.LocalCache {
  @override
  Future<String?> readConfig(String key) async => null;

  @override
  Future<void> writeConfig(String key, String value) async {}

  @override
  Future<List<cache.EventRow>> queryUserPosts(
    String pubkey, {
    int limit = 100,
  }) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

NotificationItem _item({
  required String id,
  required int time,
  String? preview,
}) => NotificationItem(
  type: NotificationType.reply,
  pubkeys: ['p' * 64],
  extraCount: 0,
  time: time,
  preview: preview,
  id: id,
  unread: true,
);

Future<(WidgetTester, ProviderContainer, String)> _pump(
  WidgetTester tester,
  List<NotificationItem> items,
) async {
  final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        localCacheProvider.overrideWith((ref) async => _StubCache()),
        identityProvider.overrideWith(() => _Id()),
        metadataProvider.overrideWith((ref, pk) async* {}),
        notificationsProvider.overrideWith((ref, arg) => Stream.value(items)),
      ],
      child: const MaterialApp(home: NotificationsPage()),
    ),
  );
  // Let identity + the stream provider resolve and the list render.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  final container = ProviderScope.containerOf(
    tester.element(find.byType(NotificationsPage)),
  );
  return (tester, container, me);
}

/// The tile Container carrying the read/unread/highlight tint.
Finder _tintedTileOf(String previewText) => find.ancestor(
  of: find.textContaining(previewText),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color != null,
  ),
);

void main() {
  testWidgets('jump locates the topmost unread item and flashes it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 25 items newest-first; ALL read except one deep down (index 15).
    final items = [
      for (var i = 0; i < 25; i++)
        _item(
          id: 'n$i',
          time: 100000 - i,
          preview: i == 15 ? 'TARGET-UNREAD' : 'ITEM-$i',
        ),
    ];
    final (_, container, me) = await _pump(tester, items);

    final read = container.read(notificationReadProvider(me).notifier);
    read.markRead([
      for (var i = 0; i < 25; i++)
        if (i != 15) 'n$i',
    ]);
    await tester.pump();
    expect(container.read(unreadNotificationCountProvider(me)), 1);

    // Target starts offscreen (index 15 of a ~5-tiles-high viewport).
    expect(find.textContaining('TARGET-UNREAD'), findsNothing);

    container.read(notificationJumpProvider.notifier).request();
    // Post-frame retry chain + ensureVisible animation.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    final target = find.textContaining('TARGET-UNREAD');
    expect(
      target,
      findsOneWidget,
      reason: 'scrolled the unread tile into view',
    );
    final dy = tester.getTopLeft(target).dy;
    expect(dy, greaterThan(0));
    expect(dy, lessThan(600), reason: 'landed near the top, alignment 0.15');

    // The located tile flashes the brand tint (not the plain unread bg2).
    final ctx = tester.element(find.byType(NotificationsPage));
    final flash = CostrColors.of(ctx).brand.withValues(alpha: 0.12);
    final tile = tester.widget<Container>(_tintedTileOf('TARGET-UNREAD'));
    expect((tile.decoration as BoxDecoration).color, flash);

    // Flash clears after ~1.6s; tile falls back to the unread tint.
    await tester.pump(const Duration(milliseconds: 1700));
    final after = tester.widget<Container>(_tintedTileOf('TARGET-UNREAD'));
    expect((after.decoration as BoxDecoration).color, isNot(flash));
  });

  testWidgets('no unread anywhere: falls back to scroll-to-top', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final items = [
      for (var i = 0; i < 25; i++)
        _item(id: 'n$i', time: 100000 - i, preview: 'ITEM-$i'),
    ];
    final (_, container, me) = await _pump(tester, items);

    // Everything read; scroll deep down manually first.
    container.read(notificationReadProvider(me).notifier).markRead([
      for (var i = 0; i < 25; i++) 'n$i',
    ]);
    await tester.pump();
    await tester.fling(find.byType(ListView), const Offset(0, -800), 1200);
    await tester.pumpAndSettle();
    expect(find.textContaining('ITEM-0'), findsNothing);

    container.read(notificationJumpProvider.notifier).request();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(
      find.textContaining('ITEM-0'),
      findsOneWidget,
      reason: 'nothing unread → back to the newest (top)',
    );
  });

  testWidgets('unread only on the other tab: switches tab, then jumps', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Replies (shown on both tabs, all read) + one UNREAD reaction (only on
    // the 全部 tab), deep in the list.
    final items = <NotificationItem>[
      for (var i = 0; i < 10; i++)
        _item(id: 'r$i', time: 100000 - i, preview: 'REPLY-$i'),
      NotificationItem(
        type: NotificationType.reaction,
        pubkeys: ['q' * 64],
        extraCount: 0,
        time: 99980,
        reactionEmoji: '👍',
        id: 'react0',
        unread: true,
      ),
      for (var i = 10; i < 20; i++)
        _item(id: 'r$i', time: 99900 - i, preview: 'REPLY-$i'),
    ];
    final (_, container, me) = await _pump(tester, items);
    container.read(notificationReadProvider(me).notifier).markRead([
      for (var i = 0; i < 20; i++) 'r$i',
    ]);
    await tester.pump();

    // Switch to the 提及 tab, where nothing unread is visible.
    await tester.tap(find.text('提及'));
    await tester.pumpAndSettle();

    container.read(notificationJumpProvider.notifier).request();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();

    // The page switched back to 全部 and located the reaction tile (its
    // heart icon only exists on the 全部 tab list).
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    final dy = tester.getTopLeft(find.byIcon(Icons.favorite)).dy;
    expect(dy, greaterThan(0));
    expect(dy, lessThan(1100), reason: 'unread reaction scrolled into view');
  });
}
