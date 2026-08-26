// Provider-level multi-account behavior: legacy-nsec migration, add/switch/
// remove flows through IdentityNotifier + AccountsNotifier, secure-storage
// persistence, and the event-store reset on account switch.
//
// Storage runs against a temp-dir FileSecretStore fallback (secure storage
// is unavailable in tests — the fallback is the same code path the app uses
// when the OS keystore is locked).

import 'dart:async';
import 'dart:io';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/account_registry.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:costr/services/secure_storage_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Secure storage that always fails — simulates a locked/unavailable OS
/// keystore and exercises the SAME file-fallback path the app uses there
/// (without depending on platform channels, which hang in flutter_test).
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

/// Storage whose accounts-blob writes can be stalled on demand — simulates a
/// slow Android Keystore so the optimistic switch can be proven to flip state
/// BEFORE persistence completes. Reads are unaffected.
class _GatedStorage extends SecureStorageService {
  _GatedStorage(super.secure, {required super.fileDir});

  Completer<void>? _gate;

  void closeGate() => _gate ??= Completer<void>();

  Future<void> openGate() async {
    final g = _gate;
    _gate = null;
    if (g != null && !g.isCompleted) g.complete();
  }

  @override
  Future<void> writeAccounts(AccountSet set) async {
    final g = _gate;
    if (g != null) await g.future;
    return super.writeAccounts(set);
  }
}

const _privA =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _privB =
    '0000000000000000000000000000000000000000000000000000000000000002';

final Identity _idA = Identity.fromPrivkeyHex(_privA);
final Identity _idB = Identity.fromPrivkeyHex(_privB);

/// No-op cache stub: hydration queries fail fast (caught inside the store),
/// config reads return null.
class _StubCache implements cache.LocalCache {
  @override
  Future<String?> readConfig(String key) async => null;

  @override
  Future<void> writeConfig(String key, String value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Identity notifier the test can flip between identities directly.
class _ControllableIdentity extends IdentityNotifier {
  Identity? current;

  @override
  Future<Identity?> build() async => current;

  void set(Identity? id) {
    current = id;
    state = AsyncData(id);
  }
}

Future<({ProviderContainer container, SecureStorageService storage})>
_container(Directory dir) async {
  final storage = SecureStorageService(
    _BrokenSecureStorage(),
    fileDir: dir.path,
  );
  final container = ProviderContainer(
    overrides: [
      storageProvider.overrideWith((ref) => storage),
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
    ],
  );
  return (container: container, storage: storage);
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('costr_accounts_test');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  group('registry flows', () {
    test('fresh install: empty registry, logged-out identity', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);

      final set = await container.read(accountsProvider.future);
      expect(set.isEmpty, isTrue);
      expect(await container.read(identityProvider.future), isNull);
      expect(await storage.readAccounts(), isNull); // nothing written yet
    });

    test('legacy single-nsec key migrates into the registry', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);

      // Pre-multi-account installs stored exactly one nsec.
      await storage.writeNsec(_idA.nsec);

      final set = await container.read(accountsProvider.future);
      expect(set.accounts.length, 1);
      expect(set.activePubkey, _idA.pubkeyHex);

      final identity = await container.read(identityProvider.future);
      expect(identity?.pubkeyHex, _idA.pubkeyHex);

      // Legacy key consumed; new blob persisted.
      expect(await storage.readNsec(), isNull);
      final reread = await storage.readAccounts();
      expect(reread?.activePubkey, _idA.pubkeyHex);
    });

    test('an invalid legacy nsec is dropped, ending logged out', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);

      await storage.writeNsec('nsec1invalid');

      final set = await container.read(accountsProvider.future);
      expect(set.isEmpty, isTrue);
      expect(await container.read(identityProvider.future), isNull);
      expect(await storage.readNsec(), isNull);
    });

    test('login adds + activates; second login switches active', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);
      await container.read(accountsProvider.future); // prime (empty)

      await container.read(identityProvider.notifier).login(_idA.nsec);
      expect(container.read(identityProvider).value?.pubkeyHex, _idA.pubkeyHex);

      await container.read(identityProvider.notifier).login(_idB.nsec);
      expect(container.read(identityProvider).value?.pubkeyHex, _idB.pubkeyHex);
      expect(container.read(accountsProvider).value?.accounts.length, 2);

      // Both accounts persisted, B active.
      final reread = await storage.readAccounts();
      expect(reread?.accounts.length, 2);
      expect(reread?.activePubkey, _idB.pubkeyHex);
    });

    test('re-login with a stored key does not duplicate it', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);
      await container.read(accountsProvider.future);

      await container.read(identityProvider.notifier).login(_idA.nsec);
      await container.read(identityProvider.notifier).login(_idB.nsec);
      await container.read(identityProvider.notifier).login(_idA.nsec);

      final set = container.read(accountsProvider).value;
      expect(set?.accounts.length, 2);
      expect(set?.activePubkey, _idA.pubkeyHex);
    });

    test('switchTo changes the active identity', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);
      await container.read(accountsProvider.future);

      await container.read(identityProvider.notifier).login(_idA.nsec);
      await container.read(identityProvider.notifier).login(_idB.nsec);
      expect(container.read(identityProvider).value?.pubkeyHex, _idB.pubkeyHex);

      await container.read(identityProvider.notifier).switchTo(_idA.pubkeyHex);
      expect(container.read(identityProvider).value?.pubkeyHex, _idA.pubkeyHex);
      // Persistence is optimistic-background now — drain it before asserting.
      await container.read(accountsProvider.notifier).writesDrained;
      expect((await storage.readAccounts())?.activePubkey, _idA.pubkeyHex);
    });

    test('switchTo flips state instantly even while the keystore write stalls', () async {
        // The optimistic switch: identity/account state must move the MOMENT
        // the user taps, not after the (seconds-slow on some Android devices)
        // secure-storage blob write completes.
        final storage = _GatedStorage(_BrokenSecureStorage(), fileDir: dir.path);
        final container = ProviderContainer(
          overrides: [
            storageProvider.overrideWith((ref) => storage),
            relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          ],
        );
        addTearDown(container.dispose);
        await container.read(accountsProvider.future);
        await container.read(identityProvider.notifier).login(_idA.nsec);
        await container.read(identityProvider.notifier).login(_idB.nsec);
        expect(container.read(identityProvider).value?.pubkeyHex, _idB.pubkeyHex);

        // Stall all further writes (simulates a slow Keystore)…
        storage.closeGate();
        await container
            .read(identityProvider.notifier)
            .switchTo(_idA.pubkeyHex);
        // …yet the switch is already fully applied in-memory.
        expect(container.read(identityProvider).value?.pubkeyHex, _idA.pubkeyHex);
        expect(
          container.read(accountsProvider).value?.activePubkey,
          _idA.pubkeyHex,
        );

        // The background persist lands once the keystore unblocks.
        await storage.openGate();
        await container.read(accountsProvider.notifier).writesDrained;
        expect((await storage.readAccounts())?.activePubkey, _idA.pubkeyHex);
      },
    );

    test('removing the active account activates the next one', () async {
      final (:container, :storage) = await _container(dir);
      addTearDown(container.dispose);
      await container.read(accountsProvider.future);

      await container.read(identityProvider.notifier).login(_idA.nsec);
      await container.read(identityProvider.notifier).login(_idB.nsec);

      // B is active; removing B activates A.
      await container
          .read(identityProvider.notifier)
          .removeAccount(_idB.pubkeyHex);
      expect(container.read(identityProvider).value?.pubkeyHex, _idA.pubkeyHex);
      expect(container.read(accountsProvider).value?.accounts.length, 1);

      // Removing the last account logs out entirely.
      await container.read(identityProvider.notifier).logout();
      expect(container.read(identityProvider).value, isNull);
      expect(container.read(accountsProvider).value?.isEmpty, isTrue);
      expect((await storage.readAccounts())?.isEmpty, isTrue);
    });
  });

  group('event store on switch', () {
    testWidgets('in-memory feed resets when the active account changes', (
      tester,
    ) async {
      final identity = _ControllableIdentity();
      final container = ProviderContainer(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          localCacheProvider.overrideWith((ref) async => _StubCache()),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => identity),
        ],
      );
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
      });

      container.read(eventStoreProvider); // build while logged out
      final notifier = container.read(eventStoreProvider.notifier);

      // Log in as A; ingest an event into the live store.
      identity.set(_idA);
      await tester.pump();
      container.read(eventStoreProvider); // rebuild for account A
      await notifier.ingest(
        Event(
          id: 'e1',
          pubkey: 'pkX',
          createdAt: 1,
          kind: 1,
          tags: const [],
          content: 'hello',
          sig: 'sig',
        ),
      );
      notifier.flushNow();
      expect(container.read(eventStoreProvider), hasLength(1));

      // Switch to B: the store is wiped before re-hydration — A's feed
      // residue must not leak into B's session.
      identity.set(_idB);
      await tester.pump();
      expect(container.read(eventStoreProvider), isEmpty);

      // Drain any pending debounce timers, then dispose BEFORE the binding's
      // end-of-test timer audit runs.
      await tester.pump(const Duration(milliseconds: 300));
      disposed = true;
      container.dispose();
    });
  });
}
