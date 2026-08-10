// Widget test: a reply card in the feed shows the replied-to post's content
// (one level up) as a preview box under the "回复 @user" header — not just
// the author name. Before this, reply cards had no context at all.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/event_card.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/metadata.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/proxied_network_image.dart';
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
  String pubkey =
      'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
  List<List<dynamic>> tags = const [],
  String content = '',
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: 1,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

void main() {
  testWidgets('reply card shows the replied-to post content preview', (
    tester,
  ) async {
    final parent = _ev(
      'parent1',
      pubkey: 'c' * 64,
      content: '这是被回复的原帖内容，提供上下文',
    );
    final reply = _ev(
      'reply1',
      tags: [
        ['e', 'parent1', '', 'root'],
        ['e', 'parent1', '', 'reply'],
        ['p', 'c' * 64],
      ],
      content: '这是我的回复',
    );

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
          eventStoreProvider.overrideWith(() => _FixedStore([parent])),
          localCacheProvider.overrideWith(
            (ref) => Completer<cache.LocalCache>().future,
          ),
          // The parent resolves via the 3-tier lookup; in the widget test the
          // tiers are short-circuited to return it directly.
          eventByIdProvider.overrideWith((ref, id) async {
            return id == 'parent1' ? parent : null;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [EventCard(event: reply)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // The reply's own content.
    expect(find.text('这是我的回复'), findsOneWidget);
    // The "回复 @user" header (metadata null → npub fallback).
    expect(find.textContaining('回复 @'), findsOneWidget);
    // The replied-to post's content is shown as context (truncated plain
    // text), which was entirely missing before.
    expect(find.textContaining('这是被回复的原帖内容，提供上下文'), findsOneWidget);
  });

  testWidgets('reply preview respects NSFW concealment for the parent', (
    tester,
  ) async {
    final parent = _ev(
      'parent2',
      pubkey: 'd' * 64,
      tags: const [
        ['t', 'nsfw'],
      ],
      content: '敏感原帖内容不应直接泄露',
    );
    final reply = _ev(
      'reply2',
      tags: [
        ['e', 'parent2', '', 'reply'],
      ],
      content: '回复敏感帖',
    );

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
          eventStoreProvider.overrideWith(() => _FixedStore([parent])),
          localCacheProvider.overrideWith(
            (ref) => Completer<cache.LocalCache>().future,
          ),
          eventByIdProvider.overrideWith((ref, id) async {
            return id == 'parent2' ? parent : null;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [EventCard(event: reply)]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    // NSFW parent (autoReveal off) → placeholder instead of the raw text.
    expect(find.textContaining('敏感原帖内容不应直接泄露'), findsNothing);
    expect(find.textContaining('此帖可能包含敏感内容'), findsOneWidget);
  });

  testWidgets('reply line renders NIP-30 emoji in the parent author name', (
    tester,
  ) async {
    // Real-world shape (Mostr/ActivityPub bridge accounts): the kind-0 name
    // carries a ":shortcode:" whose image is declared in the kind-0 event's
    // emoji tags. Every other name slot renders it inline; the "回复 @name"
    // line used to show the raw ":verified:" text.
    final parent = _ev(
      'parent3',
      pubkey: 'e' * 64,
      content: '小红书的氛围特别像是商场的一层。',
    );
    final reply = _ev(
      'reply3',
      tags: [
        ['e', 'parent3', '', 'root'],
        ['p', 'e' * 64],
      ],
      content: '什么氛围？',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _NsfwOff()),
          metadataProvider.overrideWith((ref, pk) async* {
            if (pk == 'e' * 64) {
              yield Metadata.fromJson(
                <String, dynamic>{'name': '小哑。 :verified:'},
                tags: [
                  ['emoji', 'verified', 'https://example.com/v.png'],
                ],
              );
            } else {
              yield null;
            }
          }),
          reactionsProvider.overrideWith((ref, id) => const {}),
          followedTagsProvider.overrideWith(() => _EmptyTags()),
          userStatusProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
          proxyMediaEnabledProvider.overrideWith(() => _ProxyOff()),
          eventStoreProvider.overrideWith(() => _FixedStore([parent])),
          localCacheProvider.overrideWith(
            (ref) => Completer<cache.LocalCache>().future,
          ),
          eventByIdProvider.overrideWith((ref, id) async {
            return id == 'parent3' ? parent : null;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(children: [EventCard(event: reply)]),
          ),
        ),
      ),
    );
    // Two frames: metadata stream yields, then the card rebuilds with the
    // name spans. Not pumpAndSettle — once the emoji image load errors in
    // the test env its designed fallback shows ":verified:" again.
    await tester.pump();
    await tester.pump();

    // The "回复 @" line carries the name with the shortcode replaced by an
    // inline image (same for the preview box's name line below it).
    expect(find.textContaining('回复 @小哑。'), findsOneWidget);
    expect(find.byType(CostrNetworkImage), findsWidgets);
    expect(
      find.textContaining(':verified:'),
      findsNothing,
      reason: 'the raw shortcode text must not be shown',
    );
  });
}
