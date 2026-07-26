// Smoke + routing tests for the auth redirect.

import 'package:costr/app/app.dart';
import 'package:costr/app/providers.dart';
import 'package:costr/features/auth/login_page.dart';
import 'package:costr/features/feed/feed_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

/// Identity notifier that resolves to "logged out" without touching storage.
class _LoggedOutIdentity extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

/// Identity notifier that resolves to a known identity without touching storage.
class _LoggedInIdentity extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Following notifier that returns empty follows instantly (no kind-3 fetch /
/// 5s timeout in tests).
class _EmptyFollowing extends FollowingNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
}

void main() {
  testWidgets('logged out → redirected to LoginPage', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _LoggedOutIdentity()),
          followingStateProvider.overrideWith(() => _EmptyFollowing()),
        ],
        child: const AppRoot(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.text('登录'), findsWidgets);
  });

  testWidgets('logged in → redirected to FeedPage', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _LoggedInIdentity()),
          followingStateProvider.overrideWith(() => _EmptyFollowing()),
        ],
        child: const AppRoot(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(FeedPage), findsOneWidget);
    expect(find.text('全球'), findsOneWidget);
  });
}
