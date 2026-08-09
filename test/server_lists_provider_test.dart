// Provider-level tests for the user-editable server lists: seeding of the
// four config keys, the kind-10002 sync marker (per-account "last published
// list"), saveServerList orchestration, and the login/switch catch-up
// publishing for dormant accounts.
//
// Storage runs against a temp-dir FileSecretStore fallback (same path as the
// app when the OS keystore is unavailable), DB against an in-memory drift
// cache — no platform channels, no network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:costr/app/providers.dart';
import 'package:costr/app/server_list_rules.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_client.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:costr/services/local_cache.dart' show LocalCache;
import 'package:costr/services/secure_storage_service.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

// --- Fakes ------------------------------------------------------------------

/// Secure storage that always fails → exercises the file fallback.
class _BrokenSecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable in tests');

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable in tests');

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => throw Exception('keystore unavailable in tests');
}

/// Minimal fake relay connection: records sent frames, can emit OK verdicts.
class _FakeConn implements RelayConnection {
  _FakeConn(this.url);

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
  bool wasDisposed = false;
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
  void setOnConnected(void Function() cb) => _onConnected = cb;
  @override
  void setOnDisconnected(void Function() cb) {}

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
  Future<void> dispose() async {
    wasDisposed = true;
    await _events.close();
    await _eose.close();
    await _notices.close();
    await _oks.close();
    await _auths.close();
  }

  void emitOk(RelayOk ok) => _oks.add(ok);
}

/// Identity notifier the test can flip directly (no login round-trip).
class _ControllableIdentity extends IdentityNotifier {
  Identity? current;
  @override
  Future<Identity?> build() async => current;
  void set(Identity? id) {
    current = id;
    state = AsyncData(id);
  }
}

/// Synchronous Map-backed [cache.LocalCache] stub — no drift. Drift query
/// scheduling wedges inside testWidgets' FakeAsync zone, so the widget tests
/// use this instead; the plain tests keep the real in-memory drift DB.
class _MapCache implements cache.LocalCache {
  final Map<String, String> _kv = {};

  @override
  Future<String?> readConfig(String key) async => _kv[key];

  @override
  Future<void> writeConfig(String key, String value) async {
    _kv[key] = value;
  }

  @override
  Future<void> deleteConfig(String key) async {
    _kv.remove(key);
  }

  @override
  Future<List<String>?> readServerList(String key) async {
    final raw = _kv[key];
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.whereType<String>().toList(growable: false);
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<void> writeServerList(String key, List<String> urls) async {
    _kv[key] = jsonEncode(urls);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// --- Helpers ----------------------------------------------------------------

const _privA =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _privB =
    '0000000000000000000000000000000000000000000000000000000000000002';
final Identity _idA = Identity.fromPrivkeyHex(_privA);
final Identity _idB = Identity.fromPrivkeyHex(_privB);

List<Map<String, dynamic>> _eventFrames(_FakeConn c) => c.sent
    .where((m) => m[0] == 'EVENT')
    .map((m) => m[1] as Map<String, dynamic>)
    .toList();

void _ack(_FakeConn c, Map<String, dynamic> wire) =>
    c.emitOk(RelayOk(wire['id'] as String, true, '', url: c.url));

/// Poll a sync condition (plain tests only — real timers).
Future<void> _waitUntil(bool Function() cond, String what) async {
  for (var i = 0; i < 500; i++) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('timed out waiting for: $what');
}

/// Poll an async condition (plain tests only — real timers).
Future<void> _waitUntilAsync(Future<bool> Function() cond, String what) async {
  for (var i = 0; i < 500; i++) {
    if (await cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('timed out waiting for: $what');
}

Future<void> _settle() async {
  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

List<String> _rTagsOf(Map<String, dynamic> wire) => (wire['tags'] as List)
    .whereType<List<dynamic>>()
    .where((t) => t.isNotEmpty && t[0] == 'r')
    .map((t) => t[1] as String)
    .toList();

Future<cache.LocalCache> _memDb() async => LocalCache(NativeDatabase.memory());

// --- Tests ------------------------------------------------------------------

void main() {
  group('serverListsProvider seeding', () {
    test(
      'empty DB seeds all four lists from the constants, normalized',
      () async {
        final db = await _memDb();
        addTearDown(db.close);
        final container = ProviderContainer(
          overrides: [localCacheProvider.overrideWith((ref) async => db)],
        );
        addTearDown(container.dispose);

        final lists = await container.read(serverListsProvider.future);
        // Normalized: trailing slashes of the constants are stripped.
        expect(lists.relays, defaultRelays.map(normalizeServerUrl).toList());
        expect(lists.search, searchRelays.map(normalizeServerUrl).toList());
        expect(lists.indexer, indexerRelays.map(normalizeServerUrl).toList());
        expect(
          lists.blossom,
          blossomServersConst.map(normalizeServerUrl).toList(),
        );
        // Persisted under all four keys.
        for (final key in serverListKeys.values) {
          expect(await db.readServerList(key), isNotEmpty, reason: key);
        }
      },
    );

    test('a stored user list is NOT reset to the constants', () async {
      // Regression: the pre-edit-UI provider force-reset any list that
      // diverged from the code constants. User customizations must survive.
      final db = await _memDb();
      addTearDown(db.close);
      await db.writeServerList('relay_list', const ['wss://my.relay']);
      await db.writeServerList('blossom_list', const ['https://my.host']);
      final container = ProviderContainer(
        overrides: [localCacheProvider.overrideWith((ref) async => db)],
      );
      addTearDown(container.dispose);

      final lists = await container.read(serverListsProvider.future);
      expect(lists.relays, ['wss://my.relay']);
      expect(lists.blossom, ['https://my.host']);
      // The other two still seed.
      expect(lists.search, isNotEmpty);
      expect(lists.indexer, isNotEmpty);
    });
  });

  group('syncRelayListForAccount (kind-10002 marker)', () {
    late cache.LocalCache db;
    late _FakeConn conn;
    late RelayPool pool;

    setUp(() async {
      db = await _memDb();
      conn = _FakeConn('wss://a');
      pool = RelayPool([conn]);
      await pool.connect();
    });

    tearDown(() async {
      await pool.dispose();
      await db.close();
    });

    test('no marker → publishes the list and stores the marker', () async {
      final fut = syncRelayListForAccount(pool, db, _idA, const [
        'wss://x1',
        'wss://x2',
        'wss://x3',
      ]);
      // publishAndWait waits for relay OKs — ack so it resolves immediately.
      await _waitUntil(() => _eventFrames(conn).isNotEmpty, 'EVENT sent');
      _ack(conn, _eventFrames(conn).single);
      await fut;
      final frames = _eventFrames(conn);
      expect(frames, hasLength(1));
      expect(frames.single['kind'], 10002);
      expect(_rTagsOf(frames.single), ['wss://x1', 'wss://x2', 'wss://x3']);
      expect(await db.readServerList(relayListSyncedKey(_idA.pubkeyHex)), [
        'wss://x1',
        'wss://x2',
        'wss://x3',
      ]);
    });

    test('marker matches → no publish (order/slash insensitive)', () async {
      await db.writeServerList(relayListSyncedKey(_idA.pubkeyHex), const [
        'wss://x2/',
        'WSS://x1',
        'wss://x3',
      ]);
      await syncRelayListForAccount(pool, db, _idA, const [
        'wss://x1',
        'wss://x2',
        'wss://x3',
      ]);
      expect(_eventFrames(conn), isEmpty);
    });

    test(
      'publish fails → marker NOT written (retry next activation)',
      () async {
        final deadPool = RelayPool([_FakeConn('wss://dead')]);
        // Never connected → publishAndWait fails fast ("no connected relay").
        await syncRelayListForAccount(deadPool, db, _idA, const [
          'wss://x1',
          'wss://x2',
          'wss://x3',
        ]);
        expect(
          await db.readServerList(relayListSyncedKey(_idA.pubkeyHex)),
          isNull,
        );
        await deadPool.dispose();
      },
    );
  });

  group('saveServerList (via a real WidgetRef, like the sheet)', () {
    // NOTE: the pool here is deliberately NOT connected — publishAndWait on a
    // pool without connected relays returns immediately, keeping the test out
    // of FakeAsync's stream-delivery blind spot. The successful-publish path
    // (kind-10002 EVENT + marker write) is covered by the real-async
    // syncRelayListForAccount group below; here we verify saveServerList's
    // orchestration: persist → pool hot-swap → relay publish attempted for
    // the active identity (and skipped when logged out).
    testWidgets('relay: persists + hot-swaps pool + attempts publish', (
      tester,
    ) async {
      final db = _MapCache();
      final pool = RelayPool(const []); // never connected
      final created = <_FakeConn>[];
      pool.makeClient = (url) {
        final c = _FakeConn(url);
        created.add(c);
        return c;
      };
      final identity = _ControllableIdentity()..current = _idA;
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localCacheProvider.overrideWith((ref) async => db),
            relayPoolProvider.overrideWith((ref) => pool),
            searchPoolProvider.overrideWith((ref) => RelayPool(const [])),
            indexerPoolProvider.overrideWith((ref) => RelayPool(const [])),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => identity),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );

      const newList = ['wss://keep', 'wss://new1', 'wss://new2'];
      // Prime the (lazily-built) identity provider so .value is available
      // synchronously when saveServerList reads it.
      await ref.read(identityProvider.future);
      await saveServerList(ref, ServerCategory.relay, newList);

      expect(await db.readServerList('relay_list'), newList);
      // The pool hot-swapped in place (same instance, new connection set).
      expect(pool.states.map((s) => s.url).toList(), newList);
      expect(created.map((c) => c.url), newList);
      // Publish was attempted but no relay is connected → it failed → the
      // marker must NOT be written (the catch-up retries on next activation).
      expect(_eventFrames(created.first), isEmpty);
      expect(
        await db.readServerList(relayListSyncedKey(_idA.pubkeyHex)),
        isNull,
      );
      await pool.dispose();
    });

    testWidgets('blossom: persists locally and publishes NOTHING', (
      tester,
    ) async {
      final db = _MapCache();
      final keep = _FakeConn('wss://keep');
      final pool = RelayPool([keep]);
      await pool.connect();
      final identity = _ControllableIdentity()..current = _idA;
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localCacheProvider.overrideWith((ref) async => db),
            relayPoolProvider.overrideWith((ref) => pool),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => identity),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );

      await saveServerList(ref, ServerCategory.blossom, const [
        'https://b1.example',
        'https://b2.example',
      ]);
      expect(await db.readServerList('blossom_list'), [
        'https://b1.example',
        'https://b2.example',
      ]);
      expect(_eventFrames(keep), isEmpty);
      expect(
        await db.readServerList(relayListSyncedKey(_idA.pubkeyHex)),
        isNull,
      );
      await pool.dispose();
    });

    testWidgets('below the per-category minimum is rejected', (tester) async {
      final db = _MapCache();
      final pool = RelayPool(const []);
      final identity = _ControllableIdentity()..current = _idA;
      late WidgetRef ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            localCacheProvider.overrideWith((ref) async => db),
            relayPoolProvider.overrideWith((ref) => pool),
            bootstrapProvider.overrideWith((ref) async {}),
            identityProvider.overrideWith(() => identity),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox();
            },
          ),
        ),
      );

      await expectLater(
        saveServerList(ref, ServerCategory.relay, const [
          'wss://only1',
          'wss://only2',
        ]), // relay minimum is 3
        throwsStateError,
      );
      expect(await db.readServerList('relay_list'), isNull);
      await pool.dispose();
    });
  });

  group('account switch catch-up (kind 10002)', () {
    late Directory dir;
    late cache.LocalCache db;
    late _FakeConn conn;
    late RelayPool pool;
    late ProviderContainer container;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('costr_server_lists_test');
      db = await _memDb();
      conn = _FakeConn('wss://a');
      pool = RelayPool([conn]);
      await pool.connect();
      final storage = SecureStorageService(
        _BrokenSecureStorage(),
        fileDir: dir.path,
      );
      container = ProviderContainer(
        overrides: [
          storageProvider.overrideWith((ref) => storage),
          relayPoolProvider.overrideWith((ref) => pool),
          localCacheProvider.overrideWith((ref) async => db),
          bootstrapProvider.overrideWith((ref) async {}),
        ],
      );
      await container.read(accountsProvider.future); // prime (empty)
    });

    tearDown(() async {
      container.dispose();
      await pool.dispose();
      await db.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('login publishes the current list and stores the marker', () async {
      await container.read(identityProvider.notifier).login(_idA.nsec);
      await _waitUntil(() => _eventFrames(conn).isNotEmpty, 'login publish');
      final wire = _eventFrames(conn).single;
      expect(wire['kind'], 10002);
      // DB empty → the built-in defaults get published.
      expect(sameServerSet(_rTagsOf(wire), defaultRelays), isTrue);
      _ack(conn, wire);
      await _waitUntilAsync(
        () async =>
            (await db.readServerList(relayListSyncedKey(_idA.pubkeyHex))) !=
            null,
        'marker written',
      );
    });

    test(
      'change while dormant → catch-up publish on activation, once',
      () async {
        final notifier = container.read(identityProvider.notifier);

        // A logs in: publish + ack + marker.
        await notifier.login(_idA.nsec);
        await _waitUntil(
          () => _eventFrames(conn).length == 1,
          'A login publish',
        );
        _ack(conn, _eventFrames(conn).single);
        await _waitUntilAsync(
          () async =>
              (await db.readServerList(relayListSyncedKey(_idA.pubkeyHex))) !=
              null,
          'A marker',
        );

        // B logs in: publish + ack + marker (same current list).
        await notifier.login(_idB.nsec);
        await _waitUntil(
          () => _eventFrames(conn).length == 2,
          'B login publish',
        );
        _ack(conn, _eventFrames(conn).last);
        await _waitUntilAsync(
          () async =>
              (await db.readServerList(relayListSyncedKey(_idB.pubkeyHex))) !=
              null,
          'B marker',
        );

        // The relay list changes while B is active (A is dormant).
        const changed = ['wss://c1', 'wss://c2', 'wss://c3'];
        await db.writeServerList('relay_list', changed);

        // Switch to A → A's marker is stale → catch-up publish of the NEW list.
        await notifier.switchTo(_idA.pubkeyHex);
        await _waitUntil(() => _eventFrames(conn).length == 3, 'A catch-up');
        final wireA = _eventFrames(conn).last;
        expect(_rTagsOf(wireA), changed);
        _ack(conn, wireA);
        await _waitUntilAsync(
          () async => sameServerSet(
            (await db.readServerList(relayListSyncedKey(_idA.pubkeyHex))) ??
                const [],
            changed,
          ),
          'A marker updated',
        );

        // Switch to B → B's marker is stale too → publishes once as well.
        await notifier.switchTo(_idB.pubkeyHex);
        await _waitUntil(() => _eventFrames(conn).length == 4, 'B catch-up');
        _ack(conn, _eventFrames(conn).last);
        await _waitUntilAsync(
          () async => sameServerSet(
            (await db.readServerList(relayListSyncedKey(_idB.pubkeyHex))) ??
                const [],
            changed,
          ),
          'B marker updated',
        );

        // Further switches change nothing → no additional publishes.
        await notifier.switchTo(_idA.pubkeyHex);
        await notifier.switchTo(_idB.pubkeyHex);
        await _settle();
        expect(_eventFrames(conn).length, 4);
      },
    );

    test("removeAccount clears that account's marker", () async {
      final notifier = container.read(identityProvider.notifier);
      await notifier.login(_idA.nsec);
      await _waitUntil(() => _eventFrames(conn).length == 1, 'login publish');
      _ack(conn, _eventFrames(conn).single);
      await _waitUntilAsync(
        () async =>
            (await db.readServerList(relayListSyncedKey(_idA.pubkeyHex))) !=
            null,
        'marker written',
      );

      await notifier.removeAccount(_idA.pubkeyHex);
      await _waitUntilAsync(
        () async =>
            (await db.readServerList(relayListSyncedKey(_idA.pubkeyHex))) ==
            null,
        'marker cleared',
      );
    });
  });
}
