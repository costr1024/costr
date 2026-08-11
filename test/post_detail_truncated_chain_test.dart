// Regression test: when the ancestor chain resolves TRUNCATED (the topmost
// post is itself a reply whose parent couldn't be fetched — parent lives only
// on a relay that was down / rate-limiting at lookup time, or was deleted),
// the detail page shows a retry row. Before this, the one-shot lookups
// cached their miss and nothing retried, so a thread parent on a bridge
// relay stayed invisible for the whole session even after the relay
// recovered ("桥接 relay 上的帖子看不到父帖" bug).

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

Event _ev(
  String id, {
  String content = '',
  int at = 1700000000,
  List<List<dynamic>> tags = const [],
}) => Event(
  id: id,
  pubkey: 'c' * 64,
  createdAt: at,
  kind: 1,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

void main() {
  Future<void> pumpPage(
    WidgetTester tester, {
    required List<Event> chain,
    required List<Event> known,
    void Function()? onAncestorsRun,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _NsfwOff()),
          metadataProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
          reactionsProvider.overrideWith((ref, id) => const {}),
          followedTagsProvider.overrideWith(() => _EmptyTags()),
          userStatusProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
          proxyMediaEnabledProvider.overrideWith(() => _ProxyOff()),
          eventStoreProvider.overrideWith(() => _FixedStore(known)),
          localCacheProvider.overrideWith(
            (ref) => Completer<cache.LocalCache>().future,
          ),
          eventByIdProvider.overrideWith((ref, id) async {
            for (final e in known) {
              if (e.id == id) return e;
            }
            return null;
          }),
          threadAncestorsProvider.overrideWith((ref, id) async {
            onAncestorsRun?.call();
            return chain;
          }),
          repliesProvider.overrideWith((ref, id) async* {
            yield const <Event>[];
          }),
          interactorsProvider.overrideWith((ref, id) async => const <Event>[]),
        ],
        child: const MaterialApp(home: PostDetailPage(id: 'the_reply')),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('truncated chain shows the retry row; tapping retries', (
    tester,
  ) async {
    final focused = _ev(
      'the_reply',
      content: 'FOCUSED REPLY CONTENT',
      tags: [
        ['e', 'parent_missing', '', 'reply'],
        ['p', 'c' * 64],
      ],
    );
    var ancestorsRuns = 0;
    await pumpPage(
      tester,
      chain: [focused], // parent did NOT resolve — chain truncated
      known: [focused],
      onAncestorsRun: () => ancestorsRuns++,
    );

    expect(find.textContaining('上面的对话没加载出来'), findsOneWidget);
    expect(ancestorsRuns, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    // Retry invalidates the cached lookups → the chain walk re-runs.
    expect(ancestorsRuns, 2);
  });

  testWidgets('a fully-resolved chain shows NO retry row', (tester) async {
    final root = _ev('the_root', content: 'ROOT CONTENT');
    final focused = _ev(
      'the_reply',
      content: 'FOCUSED REPLY CONTENT',
      at: 1700000099,
      tags: [
        ['e', 'the_root', '', 'root'],
        ['e', 'the_root', '', 'reply'],
        ['p', 'c' * 64],
      ],
    );
    await pumpPage(tester, chain: [root, focused], known: [root, focused]);

    expect(find.textContaining('上面的对话没加载出来'), findsNothing);
  });

  testWidgets('a top-level post shows NO retry row', (tester) async {
    final top = _ev('the_reply', content: 'TOP LEVEL CONTENT');
    await pumpPage(tester, chain: [top], known: [top]);

    expect(find.textContaining('上面的对话没加载出来'), findsNothing);
  });
}
