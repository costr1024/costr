/// App-wide riverpod providers: identity, relay pool, bootstrap, event store,
/// feed mode, following (NIP-02), feed subscription lifecycle, relay status.
///
/// Notifier/AsyncNotifier usage follows riverpod 3. Non-autoDispose for the
/// long-lived relay pool + event store so they survive navigation.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/event.dart';
import '../models/metadata.dart';
import '../nostr/actions.dart';
import '../nostr/event_store.dart';
import '../nostr/identity.dart';
import '../nostr/relay_client.dart';
import '../nostr/relay_pool.dart';
import '../services/secure_storage_service.dart';
import '../utils/language.dart';


/// Default relays. bostr requires NIP-42 auth to write (read-only for us);
/// ditto/damus/nos.lol accept writes and are broadly queried, so posts reach
/// other clients. nostr.wine supports NIP-50 full-text search (posts + users).
const List<String> defaultRelays = <String>[
  'wss://relay.damus.io/',
  'wss://nos.lol/',
  'wss://relay.ditto.pub/',
  'wss://relay.bostr.online/',
  'wss://nostr.wine/',
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
  // Lazy identity getter for NIP-42 AUTH responses (works after login).
  pool.identityGetter = () => ref.read(identityProvider).value;
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
  Timer? _flush;
  bool _dirty = false;

  @override
  List<Event> build() {
    final pool = ref.watch(relayPoolProvider);
    _sub = pool.events.listen((e) {
      if (e.isTextNote && _store.add(e)) {
        _scheduleFlush();
      }
    });
    ref.onDispose(() {
      _sub?.cancel();
      _flush?.cancel();
    });
    return _store.events;
  }

  /// Throttle state emission: instead of rebuilding on every single event
  /// (which at firehose rates floods the UI/GC), batch at most once per 200ms.
  void _scheduleFlush() {
    _dirty = true;
    _flush ??= Timer(const Duration(milliseconds: 200), () {
      _flush = null;
      if (_dirty) {
        _dirty = false;
        state = _store.events;
      }
    });
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

// --- Feed filters: language + hashtag ---------------------------------------

enum LanguageFilter { all, zh, en, ja }

class LanguageFilterNotifier extends Notifier<LanguageFilter> {
  @override
  LanguageFilter build() => LanguageFilter.all;
  void set(LanguageFilter f) {
    if (f != state) state = f;
  }
}

final languageFilterProvider =
    NotifierProvider<LanguageFilterNotifier, LanguageFilter>(
        LanguageFilterNotifier.new);

class TagFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String tag) => state = tag.toLowerCase();
  void clear() => state = null;
}

final tagFilterProvider =
    NotifierProvider<TagFilterNotifier, String?>(TagFilterNotifier.new);

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
  // Global feed: bounded snapshot (closeOnEose) to avoid an unbounded live
  // firehose overwhelming small hosts. Following feed: low volume, live.
  pool.request(
    subId,
    buildFeedFilter(mode, follows),
    closeOnEose: mode == FeedMode.global,
  );
  ref.onDispose(() => pool.closeSubscription(subId));
});

// --- Current feed events (derived) -----------------------------------------

final currentFeedEventsProvider = Provider<List<Event>>((ref) {
  // Watching this keeps the feed subscription alive.
  ref.watch(feedSubscriptionProvider);
  final all = ref.watch(eventStoreProvider);
  final mode = ref.watch(feedModeProvider);
  final lang = ref.watch(languageFilterProvider);
  final tag = ref.watch(tagFilterProvider);

  Iterable<Event> events = mode == FeedMode.global
      ? all
      : all.where((e) {
          final follows = ref.watch(followingStateProvider).value ?? const <String>[];
          return follows.contains(e.pubkey);
        });

  if (lang != LanguageFilter.all) {
    final want = switch (lang) {
      LanguageFilter.zh => 'zh',
      LanguageFilter.en => 'en',
      LanguageFilter.ja => 'ja',
      LanguageFilter.all => '',
    };
    events = events.where((e) => detectLanguage(e.content) == want);
  }
  if (tag != null) {
    events = events.where((e) => e.hashtags.contains(tag));
  }
  return events.toList();
});

/// Find an event by id: hit the store first, else fetch via REQ {ids:[id]}.
/// Used by the post detail page.
final eventByIdProvider =
    FutureProvider.family<Event?, String>((ref, id) async {
  final store = ref.watch(eventStoreProvider);
  for (final e in store) {
    if (e.id == id) return e;
  }
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> sub;
  sub = pool.events.listen((e) {
    if (e.id == id && !completer.isCompleted) completer.complete(e);
  });
  final subId = nextSubId('note');
  pool.request(subId, <String, dynamic>{'ids': [id]}, closeOnEose: true);
  ref.onDispose(() {
    sub.cancel();
    pool.closeSubscription(subId);
  });
  return completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => null,
  );
});

/// A user's public kind-1 notes (posts + replies), newest-first. Resolves on
/// the first relay's EOSE (or a 10s timeout). Used by the profile page.
final userPostsProvider =
    FutureProvider.family<List<Event>, String>((ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <Event>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.isTextNote && e.pubkey == pubkey && seen.add(e.id)) {
      collected.add(e);
    }
  });
  final subId = nextSubId('user');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!completer.isCompleted) completer.complete();
  });
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [pubkey],
      'kinds': [1],
      'limit': 100,
    },
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () {},
  );
  collected.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return collected;
});

/// A user's follows (NIP-02 kind-3 p-tags) for the profile 关注 tab. Fetches
/// the user's kind-3 (replace-by-author) and resolves on EOSE / timeout.
final userFollowsProvider =
    FutureProvider.family<List<String>, String>((ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<List<String>>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.isContactList && e.pubkey == pubkey && !completer.isCompleted) {
      completer.complete(e.pTagPubkeys);
    }
  });
  final subId = nextSubId('follows');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!completer.isCompleted) completer.complete(const <String>[]);
  });
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [pubkey],
      'kinds': [Event.kindContactList],
      'limit': 1,
    },
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  return completer.future.timeout(
    const Duration(seconds: 10),
    onTimeout: () => const <String>[],
  );
});

/// A user's followers (NIP-12: REQ kind-3 events whose `p` tags reference the
/// user — the AUTHORS of those contact lists are the followers). Resolves on
/// all-relays EOSE / timeout.
final userFollowersProvider =
    FutureProvider.family<List<String>, String>((ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <String>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.isContactList && seen.add(e.pubkey)) {
      collected.add(e.pubkey);
    }
  });
  final subId = nextSubId('followers');
  final connectedCount =
      pool.states.where((s) => s.status == RelayStatus.connected).length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(
    subId,
    <String, dynamic>{
      'kinds': [Event.kindContactList],
      '#p': [pubkey],
      'limit': 500,
    },
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(
    const Duration(seconds: 12),
    onTimeout: () {},
  );
  return collected;
});

// --- Search (NIP-50, via nostr.wine) --------------------------------------

/// A user found by global search (pubkey + parsed kind-0 metadata).
class UserResult {
  const UserResult(this.pubkey, this.metadata);
  final String pubkey;
  final Metadata? metadata;
}

/// Global post search (NIP-50 `search` filter, kind 1). Collects results for a
/// fixed 6s window (non-search relays may EOSE-empty quickly, so we don't
/// resolve on first EOSE — that would miss nostr.wine's results arriving
/// after a fast empty EOSE).
final searchPostsProvider =
    FutureProvider.family<List<Event>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const <Event>[];
  final pool = ref.watch(relayPoolProvider);
  final collected = <Event>[];
  final seen = <String>{};
  late StreamSubscription<Event> evSub;
  evSub = pool.events.listen((e) {
    if (e.isTextNote && seen.add(e.id)) collected.add(e);
  });
  final subId = nextSubId('search');
  pool.request(
    subId,
    <String, dynamic>{'search': q, 'kinds': [1], 'limit': 100},
    closeOnEose: false,
  );
  ref.onDispose(() {
    evSub.cancel();
    pool.closeSubscription(subId);
  });
  // Fixed 6s collect window — don't resolve on first EOSE (a non-search relay
  // may EOSE-empty before nostr.wine delivers results).
  await Future<void>.delayed(const Duration(seconds: 6));
  collected.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return collected;
});

/// Global user search (NIP-50 `search` filter, kind 0 metadata).
final searchUsersProvider =
    FutureProvider.family<List<UserResult>, String>((ref, query) async {
  final q = query.trim();
  if (q.isEmpty) return const <UserResult>[];
  final pool = ref.watch(relayPoolProvider);
  final collected = <UserResult>[];
  final seen = <String>{};
  late StreamSubscription<Event> evSub;
  evSub = pool.events.listen((e) {
    if (e.kind == 0 && seen.add(e.pubkey)) {
      Metadata? meta;
      try {
        final json = jsonDecode(e.content);
        if (json is Map<String, dynamic>) meta = Metadata.fromJson(json);
      } catch (_) {}
      collected.add(UserResult(e.pubkey, meta));
    }
  });
  final subId = nextSubId('searchusers');
  pool.request(
    subId,
    <String, dynamic>{'search': q, 'kinds': [0], 'limit': 50},
    closeOnEose: false,
  );
  ref.onDispose(() {
    evSub.cancel();
    pool.closeSubscription(subId);
  });
  await Future<void>.delayed(const Duration(seconds: 6));
  return collected;
});

/// Follow [pubkey] (NIP-02). Fetches the current user's kind-3 event (to
/// preserve existing entries' relay/petname), signs an updated kind-3 with the
/// new pubkey added, publishes, and refreshes [followingStateProvider].
/// Returns the relay verdict.
///
/// Safety: if the existing kind-3 can't be confirmed (timeout before all relays
/// EOSE), ABORTS without publishing — never publishes a kind-3 with only the
/// new pubkey, which would wipe the user's existing follows.
Future<RelayOk> followUser(WidgetRef ref, String pubkey, {String? category}) async {
  final identity = ref.read(identityProvider).value;
  if (identity == null) {
    return const RelayOk('', false, '未登录');
  }
  final pool = ref.read(relayPoolProvider);
  // Fetch the current kind-3 event (full, to preserve relay/petname). Wait for
  // the event OR all relays' EOSE (genuine first-follow = no kind-3 anywhere);
  // do NOT closeOnEose (which now waits for all anyway) — manage the wait here
  // so we can abort on timeout.
  final completer = Completer<Event?>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.isContactList &&
        e.pubkey == identity.pubkeyHex &&
        !completer.isCompleted) {
      completer.complete(e);
    }
  });
  final subId = nextSubId('kind3-now');
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    // All connected relays EOSE'd without delivering the kind-3 → genuine
    // first-follow (no existing list to preserve).
    if (eoses >= connectedCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [identity.pubkeyHex],
      'kinds': [Event.kindContactList],
      'limit': 1,
    },
    closeOnEose: false,
  );
  Event? current;
  bool certain = false;
  try {
    current = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        certain = false;
        return null;
      },
    );
    certain = true; // resolved by event or all-EOSE
  } finally {
    await evSub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
  if (!certain) {
    return const RelayOk('', false, '无法确认现有关注列表（中继未及时响应），已取消关注以防清空。请重试。');
  }

  final signed = NostrActions(identity).follow(current, pubkey);
  final ok = await pool.publishAndWait(signed);
  if (ok.ok) ref.invalidate(followingStateProvider);

  // If a category is set, also add to the NIP-51 kind-30000 categorized list.
  if (category != null && category.isNotEmpty && ok.ok) {
    await _addToCategoryList(ref, identity, pubkey, category);
  }
  return ok;
}

/// Fetch the current kind-30000 list for [category] (d-tag) and publish an
/// updated one with [pubkey] added. Best-effort (category list failure doesn't
/// fail the follow).
Future<void> _addToCategoryList(
    WidgetRef ref, Identity identity, String pubkey, String category) async {
  final pool = ref.read(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.kind == 30000 && e.pubkey == identity.pubkeyHex && !completer.isCompleted) {
      // Check d-tag matches category.
      for (final t in e.tags) {
        if (t.length >= 2 && t[0] == 'd' && t[1] == category) {
          completer.complete(e);
          break;
        }
      }
    }
  });
  final subId = nextSubId('cat-$category');
  final connectedCount =
      pool.states.where((s) => s.status == RelayStatus.connected).length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [identity.pubkeyHex],
      'kinds': [30000],
      '#d': [category],
      'limit': 1,
    },
    closeOnEose: false,
  );
  Event? current;
  try {
    current = await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
  } finally {
    await evSub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
  final signed =
      NostrActions(identity).followCategory(current, pubkey, category);
  await pool.publishAndWait(signed);
}

/// Bookmark [eventId] (NIP-51 kind-10003). Fetches the current kind-10003 (to
/// preserve existing entries), signs an updated one via NostrActions.bookmark,
/// publishes. [publicList]: public `e` tag (plain) vs private (NIP-44-encrypted
/// to self in content). Same safety as [followUser]: aborts if the current
/// list can't be confirmed (never wipes bookmarks).
Future<RelayOk> bookmarkEvent(
    WidgetRef ref, String eventId, {required bool publicList}) async {
  final identity = ref.read(identityProvider).value;
  if (identity == null) {
    return const RelayOk('', false, '未登录');
  }
  final pool = ref.read(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.kind == 10003 && e.pubkey == identity.pubkeyHex && !completer.isCompleted) {
      completer.complete(e);
    }
  });
  final subId = nextSubId('bookmarks');
  final connectedCount =
      pool.states.where((s) => s.status == RelayStatus.connected).length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [identity.pubkeyHex],
      'kinds': [10003],
      'limit': 1,
    },
    closeOnEose: false,
  );
  Event? current;
  bool certain = false;
  try {
    current = await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        certain = false;
        return null;
      },
    );
    certain = true;
  } finally {
    await evSub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
  if (!certain) {
    return const RelayOk('', false, '无法确认现有书签列表（中继未及时响应），已取消以防清空。请重试。');
  }
  final signed =
      NostrActions(identity).bookmark(current, eventId, publicList: publicList);
  return pool.publishAndWait(signed);
}

// --- Relay status -----------------------------------------------------------

final relayStatusProvider =
    StreamProvider<List<RelayState>>((ref) => ref.watch(relayPoolProvider).statusStream);

// --- User metadata (NIP-01 kind 0) ----------------------------------------

/// Per-pubkey metadata cache. Issues a kind-0 REQ with closeOnEose (one-shot
/// snapshot — kind 0 is replace-by-author), cached by the family key so each
/// pubkey is fetched at most once per session. Used by avatars + profile page.
final metadataProvider =
    FutureProvider.family<Metadata?, String>((ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<Metadata?>();
  late StreamSubscription<Event> sub;
  sub = pool.events.listen((e) {
    if (e.kind == 0 && e.pubkey == pubkey && !completer.isCompleted) {
      try {
        final json = jsonDecode(e.content);
        if (json is Map<String, dynamic>) {
          completer.complete(Metadata.fromJson(json));
        }
      } catch (_) {
        // Malformed metadata content — leave unresolved; timeout returns null.
      }
    }
  });

  final subId = nextSubId('meta');
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [pubkey],
      'kinds': [0],
      'limit': 1,
    },
    closeOnEose: true,
  );
  ref.onDispose(() {
    sub.cancel();
    pool.closeSubscription(subId);
  });

  return completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => null,
  );
});

/// ChangeNotifier bridge so GoRouter re-evaluates redirects on login/logout.
class GoRouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
