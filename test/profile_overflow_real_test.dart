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

/// A tall metadata: every field filled + a very long multi-line about.
Metadata _tallMeta(String pubkey) => Metadata(
  name: 'costr用户',
  displayName: '一个名字很长的 costr 用户用来测试溢出',
  about: List<String>.generate(60, (i) => '这是第 $i 行个人简介，用来模拟很长的资料。').join('\n'),
  nip05: 'a-very-long-nip05-verification-handle@some-domain.example.com',
  lud16: 'a-rather-long-lightning-address@wallethost.domain.example.com',
  website: 'https://example.com/very/long/website/path/that/might/wrap',
);

void main() {
  testWidgets('ProfilePage with a very long profile: no bottom overflow', (
    tester,
  ) async {
    late Metadata meta;
    final details = <FlutterErrorDetails>[];
    final oldOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails d) {
      details.add(d);
      FlutterError.presentError(d);
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _LoggedInIdentity()),
          followingStateProvider.overrideWith(() => _EmptyFollowing()),
          metadataProvider.overrideWith((ref, pk) async* {
            meta = _tallMeta(pk);
            yield meta;
          }),
          userGroupedFollowsProvider.overrideWith((ref, pk) async* {
            yield const [];
          }),
          userFollowersProvider.overrideWith((ref, pk) async* {
            yield const [];
          }),
          userPostsProvider.overrideWith((ref, pk) async* {
            yield const [];
          }),
        ],
        child: const MaterialApp(home: ProfilePage()),
      ),
    );
    // Let the async providers resolve (no relay timeouts: all overridden).
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    // Scroll the long header fully away so the pinned TabBar + search bar are
    // visible — this is where the user reports the overflow.
    await tester.drag(find.byType(NestedScrollView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    FlutterError.onError = oldOnError;
    for (final d in details) {
      debugPrint('=== OVERFLOW DETAIL ===\n${d.toString()}\n=== END ===');
    }
    expect(
      details,
      isEmpty,
      reason: 'tall profile must not overflow on scroll',
    );
  });

  // Regression for the user-reported scenario: long bio EXPANDED + posts in
  // the list + a small screen. The body's Column[SearchBar, Expanded(ListView)]
  // used to overflow ("bottom overflowed by N pixels") when the NestedScrollView
  // body was given a bounded height smaller than the fixed search bar — at the
  // initial render and while scrolling toward the search bar.
  testWidgets(
    'ProfilePage: expanded long about + posts + small screen, no overflow',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.platformDispatcher.onMetricsChanged?.call());
      final details = <FlutterErrorDetails>[];
      final oldOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails d) {
        details.add(d);
        FlutterError.presentError(d);
      };
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => _LoggedInIdentity()),
            followingStateProvider.overrideWith(() => _EmptyFollowing()),
            metadataProvider.overrideWith((ref, pk) async* { yield _tallMeta(pk); }),
            userGroupedFollowsProvider.overrideWith(
              (ref, pk) async* {
                yield const [];
              },
            ),
            userFollowersProvider.overrideWith((ref, pk) async* {
              yield const [];
            }),
            userPostsProvider.overrideWith((ref, pk) async* {
              final posts = <Event>[];
              for (int i = 0; i < 30; i++) {
                posts.add(
                  Event(
                    id: 'ev$i'.padRight(64, '0'),
                    pubkey: pk,
                    createdAt: 1700000000 + i,
                    kind: 1,
                    tags: const [],
                    content: '这是第 $i 条帖子内容。',
                    sig: '0'.padRight(128, '0'),
                  ),
                );
              }
              yield posts;
            }),
          ],
          child: const MaterialApp(home: ProfilePage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(seconds: 1));
      // Expand the long about (makes the header taller than the viewport).
      final expandButton = find.text('展开');
      if (expandButton.evaluate().isNotEmpty) {
        await tester.tap(expandButton);
        await tester.pumpAndSettle();
      }
      // 1. No overflow at the initial render (top).
      await tester.pump(const Duration(milliseconds: 100));
      // 2. No overflow while scrolling toward the post search bar.
      await tester.drag(find.byType(NestedScrollView), const Offset(0, -2500));
      await tester.pumpAndSettle();
      FlutterError.onError = oldOnError;
      for (final d in details) {
        debugPrint('=== OVERFLOW DETAIL ===\n${d.toString()}\n=== END ===');
      }
      expect(
        details,
        isEmpty,
        reason:
            'expanded about + posts + small screen must not overflow at top or '
            'while scrolling to the search bar',
      );
    },
  );
}
