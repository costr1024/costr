// Regression: after a SUCCESSFUL publish the draft must be deleted AND must
// not be re-saved by the dispose-time flush. Before the fix the flush ran
// unconditionally in dispose and re-persisted the just-sent editor text, so the
// next time the user opened compose they found their already-published post
// waiting in the editor. The `_justSent` flag gates the flush.
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

/// In-memory stand-in for the drift cache: only the config/draft methods the
/// composer touches are real; everything else noSuchMethod's.
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

/// Pool whose publish always succeeds immediately — sidesteps the relay
/// OK-stream round trip (which fights FakeAsync timers) so the test can focus
/// on the draft lifecycle.
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
  }) async => RelayOk(event.id, true, '');
}

void main() {
  testWidgets(
    'successful send deletes the draft and dispose does not re-save it',
    (tester) async {
      final cacheDb = _FakeCache();

      // `/compose` is PUSHED on top of `/` (not the initial location) so the
      // post-send `context.pop()` actually has a route to go back to — which
      // disposes the page and runs the (gated) draft flush.
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
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
            localCacheProvider.overrideWith((ref) async => cacheDb),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pump();

      // Open compose.
      router.push('/compose');
      await tester.pumpAndSettle();

      // Prime the (lazy) identity provider and wait for it to resolve — in
      // the real app bootstrap resolves it long before compose opens; here
      // nothing else reads it, so without priming `_send` sees a still-loading
      // AsyncValue and bails with 未登录.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ComposePage)),
      );
      container.read(identityProvider);
      await tester.pump();

      // Type some text; the debounce persists it as a draft.
      final field = tester.widget<ExtendedTextField>(
        find.byType(ExtendedTextField),
      );
      field.controller!.text = 'hello world';
      await tester.pump(const Duration(milliseconds: 400)); // fire the debounce
      expect(cacheDb.config['compose_draft'], isNotNull);

      // Publish — _SuccessPool makes it succeed, then pop back to '/' disposes
      // the page.
      await tester.tap(find.text('发送'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      // The draft was deleted on success…
      expect(cacheDb.config['compose_draft'] ?? '', isEmpty);

      // …and the pop→dispose flush did NOT re-save it. Reopen compose: the
      // editor must be empty (the sent post must not come back as a draft).
      router.push('/compose');
      await tester.pumpAndSettle();
      final field2 = tester.widget<ExtendedTextField>(
        find.byType(ExtendedTextField),
      );
      expect(field2.controller!.text, isEmpty);
    },
  );
}
