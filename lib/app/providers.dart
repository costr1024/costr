/// App-wide riverpod providers: identity, relay pool, bootstrap, event store,
/// feed mode, following (NIP-02), feed subscription lifecycle, relay status.
///
/// Notifier/AsyncNotifier usage follows riverpod 3. Non-autoDispose for the
/// long-lived relay pool + event store so they survive navigation.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/event.dart';
import '../nostr/event_store.dart';
import '../nostr/identity.dart';
import '../nostr/relay_pool.dart';
import '../services/secure_storage_service.dart';

/// Default relays (user-specified).
const List<String> defaultRelays = <String>[
  'wss://relay.bostr.online/',
  'wss://relay.ditto.pub/',
];

// Monotonic subId counter, namespaced for relay-log readability.
int _seq = 0;
String nextSubId(String purpose) => 'costr:$purpose:${_seq++}';

/// Build a NIP-01 REQ filter for the given feed mode + follows. Pure function
/// so it can be unit-tested independently of the relay pool.
Map<String, dynamic> buildFeedFilter(FeedMode mode, List<String> follows) {
  final filter = <String, dynamic>{
    'kinds': [Event.kindTextNote],
    'limit': 200,
  };
  if (mode == FeedMode.following && follows.isNotEmpty) {
    filter['authors'] = List<String>.from(follows);
  }
  return filter;
}

// --- Identity ---------------------------------------------------------------

final storageProvider = Provider<SecureStorageService>((ref) {
  final svc = SecureStorageService(const FlutterSecureStorage());
  ref.onDispose(svc.dispose);
  return svc;
});

class IdentityNotifier extends AsyncNotifier<Identity?> {
  @override
  Future<Identity?> build() async {
    final nsec = await ref.read(storageProvider).readNsec();
    if (nsec == null) return null;
    try {
      return Identity.fromNsec(nsec);
    } catch (_) {
      // Stored nsec is invalid — treat as logged out.
      return null;
    }
  }

  Future<void> login(String nsec) async {
    final identity = Identity.fromNsec(nsec); // throws on invalid
    await ref.read(storageProvider).writeNsec(nsec);
    state = AsyncData(identity);
  }

  Future<void> logout() async {
    await ref.read(storageProvider).deleteNsec();
    state = const AsyncData(null);
  }
}

final identityProvider =
    AsyncNotifierProvider<IdentityNotifier, Identity?>(IdentityNotifier.new);

// --- Relay pool --------------------------------------------------------------

final relayPoolProvider = Provider<RelayPool>((ref) {
  final pool = RelayPool.fromUrls(defaultRelays);
  ref.onDispose(pool.dispose);
  return pool;
});

/// Loads identity from secure storage, then opens relay connections. The router
/// waits on this before resolving redirects, avoiding a cold-start race.
final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(identityProvider.future);
  await ref.read(relayPoolProvider).connect();
});

// --- Event store (text notes only) -----------------------------------------

class EventStoreNotifier extends Notifier<List<Event>> {
  final EventStore _store = EventStore();
  StreamSubscription<Event>? _sub;

  @override
  List<Event> build() {
    final pool = ref.watch(relayPoolProvider);
    _sub = pool.events.listen((e) {
      if (e.isTextNote && _store.add(e)) {
        state = _store.events;
      }
    });
    ref.onDispose(() {
      _sub?.cancel();
    });
    return _store.events;
  }

  void clear() {
    _store.clear();
    state = _store.events;
  }
}

final eventStoreProvider =
    NotifierProvider<EventStoreNotifier, List<Event>>(EventStoreNotifier.new);

// --- Feed mode --------------------------------------------------------------

enum FeedMode { global, following }

class FeedModeNotifier extends Notifier<FeedMode> {
  @override
  FeedMode build() => FeedMode.global;

  void set(FeedMode mode) {
    if (mode != state) state = mode;
  }
}

final feedModeProvider =
    NotifierProvider<FeedModeNotifier, FeedMode>(FeedModeNotifier.new);

// --- Following (NIP-02 kind-3) ----------------------------------------------

class FollowingNotifier extends AsyncNotifier<List<String>> {
  StreamSubscription<Event>? _sub;

  @override
  Future<List<String>> build() async {
    final identity = await ref.watch(identityProvider.future);
    if (identity == null) return const <String>[];

    final pool = ref.read(relayPoolProvider);
    final completer = Completer<List<String>>();
    final pubkey = identity.pubkeyHex;
    final subId = nextSubId('kind3');

    _sub = pool.events.listen((e) {
      if (e.isContactList && e.pubkey == pubkey && !completer.isCompleted) {
        completer.complete(e.pTagPubkeys);
      }
    });

    pool.request(subId, {
      'authors': [pubkey],
      'kinds': [Event.kindContactList],
      'limit': 1,
    });

    ref.onDispose(() {
      _sub?.cancel();
      pool.closeSubscription(subId);
    });

    return completer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => const <String>[],
    );
  }
}

final followingStateProvider =
    AsyncNotifierProvider<FollowingNotifier, List<String>>(FollowingNotifier.new);

// --- Feed subscription lifecycle (REQ/CLOSE on mode/follows change) --------

/// A void provider that, when watched, keeps the active feed REQ alive. It
/// rebuilds (closing the old sub via onDispose, opening a new one) whenever
/// feed mode, identity, or the follows list changes.
final feedSubscriptionProvider = Provider<void>((ref) {
  final mode = ref.watch(feedModeProvider);
  final identity = ref.watch(identityProvider).value;
  final follows =
      ref.watch(followingStateProvider).value ?? const <String>[];
  final pool = ref.watch(relayPoolProvider);

  if (identity == null) return;

  // In following mode with no follows yet, there's nothing to fetch — wait for
  // the kind-3 to resolve. onDispose still cleans up when state changes.
  if (mode == FeedMode.following && follows.isEmpty) return;

  final subId = nextSubId('feed');
  pool.request(subId, buildFeedFilter(mode, follows));
  ref.onDispose(() => pool.closeSubscription(subId));
});

// --- Current feed events (derived) -----------------------------------------

final currentFeedEventsProvider = Provider<List<Event>>((ref) {
  // Watching this keeps the feed subscription alive.
  ref.watch(feedSubscriptionProvider);
  final all = ref.watch(eventStoreProvider);
  final mode = ref.watch(feedModeProvider);
  if (mode == FeedMode.global) return all;
  final follows = ref.watch(followingStateProvider).value ?? const <String>[];
  final set = follows.toSet();
  return all.where((e) => set.contains(e.pubkey)).toList();
});

// --- Relay status -----------------------------------------------------------

final relayStatusProvider =
    StreamProvider<List<RelayState>>((ref) => ref.watch(relayPoolProvider).statusStream);

/// ChangeNotifier bridge so GoRouter re-evaluates redirects on login/logout.
class GoRouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
