// Regression test: opening a post detail page (e.g. from a reply
// notification) must POSITION at the focused post — auto-scrolling to it and
// flashing a highlight — instead of leaving the user at the top of the
// ancestor chain staring at the thread root ("回帖通知没定位到那条回帖，而是
// root 主贴" bug).

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/post_detail_page.dart';
import 'package:costr/models/event.dart';
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

class _NsfwOff extends NsfwSettingsNotifier {
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

/// Fixed in-memory store (no SQLite / relay wiring in widget tests).
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _ev(String id, {String content = '', int at = 1700000000}) => Event(
  id: id,
  pubkey: 'c' * 64,
  createdAt: at,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's' * 128,
);

void main() {
  testWidgets(
    'detail page auto-scrolls to the focused reply deep in a chain',
    (tester) async {
      // 30 ancestors — far more than fits the 800x600 test viewport — so
      // WITHOUT auto-positioning the focused reply would be off-screen below
      // and the user would land on the thread root.
      final ancestors = [
        for (var i = 0; i < 30; i++)
          _ev('anc$i', content: 'ANCESTOR CONTENT $i', at: 1700000000 + i),
      ];
      final focused = _ev(
        'the_reply',
        content: 'FOCUSED REPLY CONTENT',
        at: 1700000099,
      );
      final chain = [...ancestors, focused];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => _Id()),
            nsfwSettingsProvider.overrideWith(() => _NsfwOff()),
            metadataProvider.overrideWith((ref, pk) async* { yield null; }),
            reactionsProvider.overrideWith((ref, id) => const {}),
            followedTagsProvider.overrideWith(() => _EmptyTags()),
            userStatusProvider.overrideWith((ref, pk) async* { yield null; }),
            proxyMediaEnabledProvider.overrideWith(() => _ProxyOff()),
            eventStoreProvider.overrideWith(() => _FixedStore(chain)),
            localCacheProvider.overrideWith(
              (ref) => Completer<cache.LocalCache>().future,
            ),
            eventByIdProvider.overrideWith((ref, id) async {
              return chain.where((e) => e.id == id).cast<Event?>().firstWhere(
                (e) => true,
                orElse: () => null,
              );
            }),
            threadAncestorsProvider.overrideWith((ref, id) async => chain),
            repliesProvider.overrideWith((ref, id) async* {
              yield const <Event>[];
            }),
          ],
          child: const MaterialApp(
            home: PostDetailPage(id: 'the_reply'),
          ),
        ),
      );
      // The ensureVisible animation (300ms) + highlight flash timer (1.8s).
      await tester.pumpAndSettle(const Duration(milliseconds: 500));

      // The focused reply's card is laid out and scrolled INTO the viewport.
      final focusedFinder = find.textContaining('FOCUSED REPLY CONTENT');
      expect(focusedFinder, findsWidgets);
      final dy = tester.getTopLeft(focusedFinder.first).dy;
      expect(
        dy,
        inInclusiveRange(0, 600),
        reason: 'the focused reply must be scrolled into view, '
            'not left below the fold at the thread root',
      );

      // The scrollable actually scrolled (a top-aligned render would be 0).
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.pixels, greaterThan(0));

      // The root of the chain is still rendered (context preserved) — just
      // scrolled up above the viewport.
      expect(find.textContaining('ANCESTOR CONTENT 0'), findsWidgets);
    },
  );
}
