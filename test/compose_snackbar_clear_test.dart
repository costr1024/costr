// Regression: the 「已发布」 SnackBar outlives the popped compose route by its
// ~4s display window. ScaffoldMessenger renders the SnackBar on every
// registered root Scaffold — after the compose route pops, the FEED's
// Scaffold keeps it alive, and reopening compose shows it again, floating
// over the bottom image/video upload buttons (rapid-repost flow).
// ComposePage now clears lingering SnackBars the moment compose opens.

import 'package:costr/app/providers.dart';
import 'package:costr/features/compose/compose_page.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:extended_text_field/extended_text_field.dart';
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

class _FakeCache implements cache.LocalCache {
  final Map<String, String> config = {};

  @override
  Future<String?> readConfig(String key) async => config[key];

  @override
  Future<void> writeConfig(String key, String value) async {
    config[key] = value;
  }

  @override
  Future<int> saveDraft(String rawJson) async => 0;

  @override
  Future<void> deleteDraft(int rowid) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Pool whose publish always succeeds immediately.
class _SuccessPool extends RelayPool {
  _SuccessPool() : super(const []);

  @override
  Future<RelayOk> publishAndWait(
    Event event, {
    Duration timeout = const Duration(seconds: 15),
    List<Duration> retryDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
    ],
    Duration perRoundTimeout = const Duration(seconds: 5),
    Duration noProgressTimeout = const Duration(milliseconds: 1500),
  }) async => RelayOk(event.id, true, '');
}

void main() {
  testWidgets('reopening compose clears the lingering 已发布 SnackBar', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        // A Scaffold on the home route — like the real feed page. The
        // ScaffoldMessenger renders the SnackBar on every registered root
        // Scaffold, so this one keeps 「已发布」 alive after compose pops.
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: SizedBox()),
        ),
        GoRoute(path: '/compose', builder: (_, _) => const ComposePage()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => _SuccessPool()),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _Nsfw()),
          metadataProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
          knownUsersProvider.overrideWith((ref) => const <KnownUser>[]),
          userPostsProvider.overrideWith((ref, pk) async* {
            yield const <Event>[];
          }),
          localCacheProvider.overrideWith((ref) async => _FakeCache()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
    );
    container.read(identityProvider);
    await tester.pump();

    // First post: open compose, type, send.
    router.push('/compose');
    await tester.pumpAndSettle();
    final field = tester.widget<ExtendedTextField>(
      find.byType(ExtendedTextField),
    );
    field.controller!.text = '第一条';
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('发送'));
    await tester.pump();
    // Publish resolves, 「已发布」 snack fires, compose pops. Pump the
    // transitions explicitly (pumpAndSettle can settle between the async
    // publish steps before the snack is scheduled).
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // Back on '/' now — the home Scaffold keeps the success SnackBar on
    // screen (its ~4s display window outlives the popped compose route).
    expect(find.text('已发布'), findsOneWidget);

    // Rapid-repost: open compose again while the SnackBar is showing.
    router.push('/compose');
    await tester.pump(); // route entry: didChangeDependencies clears the snack
    // The cleared SnackBar runs its exit animation (~250ms) and is removed.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The stale SnackBar must be gone — it used to cover the bottom
    // image/video upload buttons here.
    expect(find.text('已发布'), findsNothing);
    expect(find.byType(ComposePage), findsOneWidget);
  });
}
