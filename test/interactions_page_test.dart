// 「谁点赞/转发了」list: the action row shows a down-chevron indicator (no
// text) when the post has reactions or reposts; tapping it pushes the
// interactions page listing each interactor (avatar + nickname + what they
// did — reaction glyph / 「转发了这条帖子」/ quote text).

import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/interactions_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/metadata.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/post_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Nsfw extends NsfwSettingsNotifier {
  @override
  NsfwSettings build() => const NsfwSettings();
}

class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _ev(
  String id, {
  required String pubkey,
  int kind = 1,
  String content = '',
  List<List<dynamic>> tags = const [],
}) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: 1700000000,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

final _post = _ev('p' * 64, pubkey: 'a' * 64, content: 'the post');
final _liker = _ev(
  'r' * 64,
  pubkey: 'b' * 64,
  kind: 7,
  content: '🔥',
  tags: [
    ['e', 'p' * 64],
    ['p', 'a' * 64],
  ],
);
final _reposter = _ev(
  't' * 64,
  pubkey: 'c' * 64,
  kind: 6,
  tags: [
    ['e', 'p' * 64],
    ['p', 'a' * 64],
  ],
);

Future<void> pumpActions(WidgetTester tester, List<Event> store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        identityProvider.overrideWith(() => _Id()),
        nsfwSettingsProvider.overrideWith(() => _Nsfw()),
        eventStoreProvider.overrideWith(() => _FixedStore(store)),
        metadataProvider.overrideWith((ref, pk) async* {
          yield const Metadata(displayName: '小明');
        }),
        interactorsProvider.overrideWith((ref, id) async => [
          _reposter,
          _liker,
        ]),
      ],
      child: MaterialApp.router(
        routerConfig: GoRouter(
          initialLocation: '/',
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(body: PostActions(event: _post)),
              routes: [
                GoRoute(
                  path: '/interactions/:id',
                  builder: (_, s) => InteractionsPage(
                    id: s.pathParameters['id']!,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('no chevron without interactions', (tester) async {
    await pumpActions(tester, [_post]);
    expect(find.byIcon(Icons.expand_more_rounded), findsNothing);
  });

  testWidgets('chevron appears with interactions and opens the list', (
    tester,
  ) async {
    await pumpActions(tester, [_post, _liker, _reposter]);

    // The down-chevron indicator (no text label) is offered.
    expect(find.byIcon(Icons.expand_more_rounded), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more_rounded));
    await tester.pumpAndSettle();

    expect(find.text('点赞与转发'), findsOneWidget);
    // Both interactors listed with their nickname and what they did.
    expect(find.text('小明'), findsNWidgets(2));
    expect(find.text('回应了这条帖子 🔥'), findsOneWidget);
    expect(find.text('转发了这条帖子'), findsOneWidget);
  });
}
