// Regression: after ADDING an account via /login?add=1 (multi-account flow),
// the user must land back on the settings page — not stay on the login page.
// Covers both paths: nsec import and the create-account wizard (which is
// pushed as an imperative MaterialPageRoute on top of the router).

import 'package:costr/app/app.dart';
import 'package:costr/app/providers.dart';
import 'package:costr/app/router.dart';
import 'package:costr/features/auth/login_page.dart';
import 'package:costr/features/settings/settings_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/account_registry.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _privMain =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _privSecond =
    '0000000000000000000000000000000000000000000000000000000000000002';

final Identity _idMain = Identity.fromPrivkeyHex(_privMain);
final Identity _idSecond = Identity.fromPrivkeyHex(_privSecond);

/// Identity the test flips directly. login() is overridden to skip storage +
/// relay-list publishing (pure state change, like the real notifier's
/// synchronous `state = AsyncData(identity)` at the end of a login).
class _ControllableIdentity extends IdentityNotifier {
  Identity? current;

  @override
  Future<Identity?> build() async => current;

  void set(Identity? id) {
    current = id;
    state = AsyncData(id);
  }

  @override
  Future<void> login(String nsec) async {
    final id = Identity.fromNsec(nsec);
    current = id;
    state = AsyncData(id);
  }
}

class _AccountsStub extends AccountsNotifier {
  @override
  Future<AccountSet> build() async => const AccountSet();
}

class _EmptyFollowing extends FollowingNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
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

void main() {
  Future<
    (
      WidgetTester,
      _ControllableIdentity,
      ProviderContainer,
      void Function()
    )
  >
  pumpApp(WidgetTester tester) async {
    final identity = _ControllableIdentity();
    late ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(
          overrides: [
            relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => identity),
            accountsProvider.overrideWith(() => _AccountsStub()),
            followingStateProvider.overrideWith(() => _EmptyFollowing()),
            localCacheProvider.overrideWith((ref) async => _StubCache()),
          ],
        ),
        child: const AppRoot(),
      ),
    );
    var disposed = false;
    addTearDown(() {
      if (!disposed) container.dispose();
    });
    await tester.pump();
    return (tester, identity, container, () {
      disposed = true;
      container.dispose();
    });
  }

  testWidgets('nsec import via /login?add=1 returns to the settings page', (
    tester,
  ) async {
    final (_, identity, container, dispose) = await pumpApp(tester);

    // Already logged in as the main account → shell/feed.
    identity.set(_idMain);
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);

    // Settings → 添加账号.
    container.read(routerProvider).push('/settings');
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);

    container.read(routerProvider).push('/login?add=1');
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    // Import a second account via nsec.
    await tester.tap(find.text('用私钥添加已有账号'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), _idSecond.nsec);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '添加账号'));
    await tester.pumpAndSettle();

    // Must be back on the settings page, NOT stuck on the login page.
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(identity.current?.pubkeyHex, _idSecond.pubkeyHex);
    // Dispose the container (cancels provider-owned timers, e.g. the
    // muteListProvider EOSE watchdog) before the binding's timer audit.
    dispose();
  });

  testWidgets('create-account wizard via /login?add=1 returns to settings', (
    tester,
  ) async {
    final (_, identity, container, dispose) = await pumpApp(tester);

    identity.set(_idMain);
    await tester.pumpAndSettle();
    container.read(routerProvider).push('/settings');
    await tester.pumpAndSettle();
    container.read(routerProvider).push('/login?add=1');
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);

    // Wizard: 创建新账号 → 备份钥匙 → 设置资料 → 完成/开始使用.
    await tester.tap(find.text('创建新账号'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我已抄写并妥善保存私钥'));
    await tester.pump();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始使用'));
    await tester.pumpAndSettle();

    // Must be back on the settings page, NOT stuck on the login page/wizard.
    expect(find.byType(LoginPage), findsNothing);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(identity.current, isNot(equals(_idMain)));
    dispose();
  });
}
