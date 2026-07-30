import 'package:costr/app/providers.dart';
import 'package:costr/features/profile/profile_page.dart';
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
          metadataProvider.overrideWith((ref, pk) async {
            meta = _tallMeta(pk);
            return meta;
          }),
          userGroupedFollowsProvider.overrideWith((ref, pk) async => const []),
          userFollowersProvider.overrideWith((ref, pk) async => const []),
          userPostsProvider.overrideWith((ref, pk) async => const []),
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
}
