// Tests for [eventByIdProvider]: the lookup chain (SQLite → store → pool REQ
// → NIP-65 fallback) and its fast-exit — when every relay answers EOSE with
// nothing, resolve null promptly instead of sitting out the 8s timeout.

import 'dart:async';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake relay connection (same shape as relay_pool_test.dart).
class _FakeRelay implements RelayConnection {
  _FakeRelay(this.url);

  @override
  final String url;
  final StreamController<Event> _events = StreamController<Event>.broadcast();
  final StreamController<String> _eose = StreamController<String>.broadcast();
  final StreamController<String> _notices =
      StreamController<String>.broadcast();
  final StreamController<RelayOk> _oks = StreamController<RelayOk>.broadcast();
  final StreamController<String> _auths = StreamController<String>.broadcast();

  final List<List<dynamic>> sent = [];
  bool _connected = false;
  void Function()? _onConnected;

  @override
  bool get isConnected => _connected;

  @override
  Stream<Event> get events => _events.stream;
  @override
  Stream<String> get eose => _eose.stream;
  @override
  Stream<String> get notices => _notices.stream;
  @override
  Stream<RelayOk> get oks => _oks.stream;
  @override
  Stream<String> get auths => _auths.stream;

  @override
  Future<void> connect() async {
    _connected = true;
    _onConnected?.call();
  }

  @override
  void request(String subId, Map<String, dynamic> filter) =>
      sent.add(['REQ', subId, filter]);

  @override
  void closeSubscription(String subId) => sent.add(['CLOSE', subId]);

  @override
  void publish(Event event) => sent.add(['EVENT', event.toWireObject()]);

  @override
  void sendAuth(Event event) => sent.add(['AUTH', event.toWireObject()]);

  @override
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

  @override
  Future<void> dispose() async {
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emit(Event e) => _events.add(e);
  void emitEose(String subId) => _eose.add(subId);
}

/// Stub cache: empty everything; records nothing. queryEventById misses so
/// the lookup falls through to the store/pool.
class _StubCache implements cache.LocalCache {
  @override
  Future<cache.EventRow?> queryEventById(String id) async => null;

  @override
  Future<List<cache.EventRow>> queryFeed({int limit = 200}) async => const [];
  @override
  Future<List<cache.EventRow>> queryRecentReactions({int limit = 500}) async =>
      const [];
  @override
  Future<List<cache.ReplaceableEvent>> queryAllMetadata() async => const [];

  @override
  Future<void> writeEvent({
    required String id,
    required String pubkey,
    required int kind,
    required int createdAt,
    required String content,
    required String sig,
    required String raw,
    required String tagsJson,
    required List tags,
  }) async {}

  @override
  Future<String?> readConfig(String key) async => null;
  @override
  Future<void> writeConfig(String key, String value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

Event _event(String id) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: 'hello',
  sig: 's' * 128,
);

void main() {
  late ProviderContainer container;
  late RelayPool pool;
  late List<_FakeRelay> relays;

  Future<void> setUpPool(List<_FakeRelay> rs) async {
    relays = rs;
    pool = RelayPool(rs);
    await pool.connect();
    container = ProviderContainer(
      overrides: [
        relayPoolProvider.overrideWith((ref) => pool),
        localCacheProvider.overrideWith((ref) async => _StubCache()),
        identityProvider.overrideWith(() => _NullId()),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(pool.dispose);
    // Build the store (wires hydrate against the stub) and let the async
    // localCacheProvider resolve so eventByIdProvider's SQLite step sees it.
    container.read(eventStoreProvider.notifier);
    await container.read(localCacheProvider.future);
  }

  /// Wait until every relay has received the lookup REQ, return its subId.
  Future<String> awaitReq() async {
    for (var i = 0; i < 200; i++) {
      if (relays.every((r) => r.sent.any((m) => m[0] == 'REQ'))) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    for (final r in relays) {
      final req = r.sent.firstWhere((m) => m[0] == 'REQ');
      expect((req[2] as Map<String, dynamic>)['ids'], isNotNull);
    }
    return relays.first.sent.firstWhere((m) => m[0] == 'REQ')[1] as String;
  }

  group('eventByIdProvider', () {
    test('store hit short-circuits: no relay REQ is issued', () async {
      await setUpPool([_FakeRelay('wss://a')]);
      await container.read(eventStoreProvider.notifier).ingest(_event('in-store'));
      // Let the store's 200ms throttle flush state.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      final e = await container.read(eventByIdProvider('in-store').future);
      expect(e?.id, 'in-store');
      expect(relays.first.sent.where((m) => m[0] == 'REQ'), isEmpty);
    });

    test('pool REQ hit resolves with the event', () async {
      await setUpPool([_FakeRelay('wss://a'), _FakeRelay('wss://b')]);
      final fut = container.read(eventByIdProvider('target').future);
      final subId = await awaitReq();
      relays.first.emit(_event('target'));
      final e = await fut;
      expect(e?.id, 'target');
      // The lookup cleans up after itself: CLOSE sent once it settles.
      expect(
        relays.first.sent.where((m) => m[0] == 'CLOSE' && m[1] == subId),
        isNotEmpty,
      );
    });

    test('all-relay EOSE with no event resolves null fast (no 8s wait)',
        () async {
      await setUpPool([_FakeRelay('wss://a'), _FakeRelay('wss://b')]);
      final fut = container.read(eventByIdProvider('missing').future);
      final subId = await awaitReq();
      final sw = Stopwatch()..start();
      for (final r in relays) {
        r.emitEose(subId);
      }
      final e = await fut;
      sw.stop();
      expect(e, isNull);
      // Fast-exit: well under the 8s timeout once all relays EOSE.
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('provider churn mid-lookup joins the in-flight broadcast (one REQ)',
        () async {
      await setUpPool([_FakeRelay('wss://a'), _FakeRelay('wss://b')]);
      final stale = container.read(eventByIdProvider('churned').future);
      // The churned-away instance's future may either resolve (shared future)
      // or error (disposed) — neither should fail the test.
      unawaited(stale.catchError((Object _) => null));
      final subId = await awaitReq();
      // Simulate page-rebuild churn: the provider instance is disposed while
      // the relay hasn't answered yet, then a fresh instance starts.
      container.invalidate(eventByIdProvider('churned'));
      final fresh = container.read(eventByIdProvider('churned').future);
      // The relay answers AFTER the churn — the shared in-flight lookup must
      // still deliver it (its listener survives the old provider's dispose).
      relays.first.emit(_event('churned'));
      final e = await fresh;
      expect(e?.id, 'churned');
      // No second broadcast REQ: the recreated provider joined the in-flight
      // lookup instead of restarting from scratch (which would drop the late
      // answer and could miss again — the lost thread-parent failure mode).
      final reqs = relays.first.sent.where((m) => m[0] == 'REQ').length;
      expect(reqs, 1);
      // Cleanup still happens once the shared lookup settles.
      expect(
        relays.first.sent.where((m) => m[0] == 'CLOSE' && m[1] == subId),
        isNotEmpty,
      );
    });
  });
}
