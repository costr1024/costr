// Widget test: the profile page's filter/search boxes (帖子/回帖/关注过滤/
// 粉丝过滤/收藏搜索 — all one shared _SearchBar) expose an Amethyst-style X
// that one-tap clears the keyword AND the filtered results.

import 'package:costr/app/providers.dart';
import 'package:costr/features/profile/profile_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/metadata.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _LoggedInIdentity extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _EmptyFollowing extends FollowingNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
}

Event _post(int i, String pubkey) => Event(
  id: 'ev$i'.padRight(64, '0'),
  pubkey: pubkey,
  createdAt: 1700000000 + i,
  kind: 1,
  tags: const [],
  content: '这是第 $i 条帖子内容。',
  sig: '0'.padRight(128, '0'),
);

Finder _postsSearchField() => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.hintText == '搜索该用户的帖子…',
);

void main() {
  testWidgets('X on the profile post-search clears keyword + filter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.platformDispatcher.onMetricsChanged?.call());

    const pk =
        'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _LoggedInIdentity()),
          followingStateProvider.overrideWith(() => _EmptyFollowing()),
          metadataProvider.overrideWith((ref, k) async* {
            yield Metadata(name: '某人');
          }),
          userGroupedFollowsProvider.overrideWith((ref, k) async* {
            yield const [];
          }),
          userFollowersProvider.overrideWith((ref, k) async* {
            yield const [];
          }),
          userPostsProvider.overrideWith((ref, k) async* {
            yield [for (var i = 0; i < 5; i++) _post(i, pk)];
          }),
        ],
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));

    expect(_postsSearchField(), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    // Filter down to one post.
    await tester.enterText(_postsSearchField(), '第 1 条');
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(find.text('这是第 1 条帖子内容。'), findsOneWidget);
    expect(find.text('这是第 0 条帖子内容。'), findsNothing);
    expect(find.byIcon(Icons.close), findsOneWidget); // X appeared

    // One-tap X → field cleared AND full unfiltered list restored.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle(const Duration(milliseconds: 400));
    expect(
      tester.widget<TextField>(_postsSearchField()).controller!.text,
      isEmpty,
    );
    expect(find.text('这是第 0 条帖子内容。'), findsOneWidget);
    expect(find.text('这是第 1 条帖子内容。'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
