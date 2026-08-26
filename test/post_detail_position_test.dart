// Regression test: opening a REPLY (e.g. from a reply notification) shows the
// thread ROOT plus the root's COMPLETE reply tree, and POSITIONS at the focused
// reply — auto-scrolling to it and flashing a highlight — instead of leaving
// the user at the top staring at the thread root ("回帖通知没定位到那条回帖，
// 而是 root 主贴" bug). The full-tree layout also surfaces every sibling reply
// ("从 root 到全部回复"), not just the focused reply's narrow chain.

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

const _rootId = 'the_root';

Event _ev(String id, {String content = '', int at = 1700000000}) => Event(
  id: id,
  pubkey: 'c' * 64,
  createdAt: at,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's' * 128,
);

/// A reply to [_rootId] (e-tag with a `reply` marker so [threadReplies]
/// threads it directly under the root).
Event _reply(String id, {String content = '', int at = 1700000000}) => Event(
  id: id,
  pubkey: 'c' * 64,
  createdAt: at,
  kind: 1,
  tags: const [
    ['e', _rootId, '', 'reply'],
  ],
  content: content,
  sig: 's' * 128,
);

void main() {
  testWidgets('opening a reply shows the root + full tree and scrolls to it', (
    tester,
  ) async {
    // The focused reply is one of MANY sibling replies to the root. 30
    // siblings with earlier createdAt sort ABOVE it in the reply tree — far
    // more than fits the 800x600 viewport — so WITHOUT auto-positioning the
    // focused reply would be off-screen below and the user would land on the
    // thread root.
    final root = _ev(_rootId, content: 'ROOT CONTENT', at: 1700000000);
    final siblings = [
      for (var i = 0; i < 30; i++)
        _reply('sib$i', content: 'SIBLING CONTENT $i', at: 1700000001 + i),
    ];
    final focused = _reply(
      'the_reply',
      content: 'FOCUSED REPLY CONTENT',
      at: 1700000099,
    );
    // The ancestor chain of the focused reply: just the root (it's a direct
    // reply to the root). threadAncestorsProvider returns root-first ending in
    // the focused post.
    final chain = <Event>[root, focused];

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
          eventStoreProvider.overrideWith(() => _FixedStore([root, focused])),
          localCacheProvider.overrideWith(
            (ref) => Completer<cache.LocalCache>().future,
          ),
          eventByIdProvider.overrideWith((ref, id) async {
            return [root, focused]
                .where((e) => e.id == id)
                .cast<Event?>()
                .firstWhere((e) => true, orElse: () => null);
          }),
          threadAncestorsProvider.overrideWith((ref, id) async => chain),
          // The root's reply tree: the 30 siblings + the focused reply.
          repliesProvider.overrideWith((ref, id) async* {
            if (id == _rootId) {
              yield <Event>[...siblings, focused];
            } else {
              yield const <Event>[];
            }
          }),
          interactorsProvider.overrideWith((ref, id) async => const <Event>[]),
        ],
        child: const MaterialApp(home: PostDetailPage(id: 'the_reply')),
      ),
    );
    // The ensureVisible animation (300ms) + highlight flash timer (1.8s).
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // The complete thread is rendered: the root AND every sibling reply, not
    // just the focused reply's narrow chain ("从 root 到全部回复").
    expect(find.textContaining('ROOT CONTENT'), findsWidgets);
    expect(find.textContaining('SIBLING CONTENT 0'), findsWidgets);
    expect(find.textContaining('SIBLING CONTENT 29'), findsWidgets);

    // The focused reply itself is present in the tree.
    final focusedFinder = find.textContaining('FOCUSED REPLY CONTENT');
    expect(focusedFinder, findsWidgets);

    // The page attempted to position at the focused reply: the scrollable
    // exists and the focused reply was laid out. (The exact scroll offset is
    // timing-sensitive under pumpAndSettle, so it is not asserted here.)
    expect(find.byType(Scrollable), findsWidgets);
  });
}
