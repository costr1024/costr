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
import '../services/local_cache.dart' as cache;
import '../services/secure_storage_service.dart';
import '../utils/language.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;


/// Default relays. bostr requires NIP-42 auth to write (read-only for us);
/// ditto/damus/nos.lol accept writes and are broadly queried, so posts reach
/// other clients. nostr.wine supports NIP-50 full-text search (posts + users).
const List<String> defaultRelays = <String>[
  'wss://relay.damus.io/',
  'wss://nos.lol/',
  'wss://relay.ditto.pub/',
  'wss://relay.bostr.online/',
  'wss://nostr.wine/',
  'wss://relay.nostr.net/',
  'wss://relay.0xchat.com/',
];

// --- Local cache (drift/SQLite) — provider ---

final localCacheProvider = FutureProvider<cache.LocalCache>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'costr.db');
  final db = cache.LocalCache.open(dbPath);
  ref.onDispose(db.close);
  return db;
});

// Monotonic subId counter, namespaced for relay-log readability.
int _seq = 0;
String nextSubId(String purpose) => 'costr:$purpose:${_seq++}';

/// Build a NIP-01 REQ filter for the given feed mode + follows. Pure function
/// so it can be unit-tested independently of the relay pool.
Map<String, dynamic> buildFeedFilter(FeedMode mode, List<String> follows) {
  final filter = <String, dynamic>{
    'kinds': [0, 1, 7], // metadata + text notes + reactions (Amethyst pattern)
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
  cache.LocalCache? _cache;

  @override
  List<Event> build() {
    // Hydrate from SQLite (async — fills store as data arrives).
    _hydrate();
    final pool = ref.watch(relayPoolProvider);
    _sub = pool.events.listen((e) {
      if ((e.kind == 0 || e.isTextNote || e.kind == 7) && _store.add(e)) {
        _persist(e);
        _scheduleFlush();
      }
    });
    ref.onDispose(() {
      _sub?.cancel();
      _flush?.cancel();
    });
    return _store.events;
  }

  /// Hydrate from SQLite on cold start — fills the in-memory store before
  /// the first relay EOSE, so the UI shows cached content instantly.
  Future<void> _hydrate() async {
    _cache = ref.read(localCacheProvider).value;
    if (_cache == null) {
      ref.listen(localCacheProvider, (_, next) {
        if (next.hasValue && _cache == null) {
          _cache = next.value;
          _doHydrate();
        }
      });
      return;
    }
    await _doHydrate();
  }

  Future<void> _doHydrate() async {
    final db = _cache;
    if (db == null) return;
    try {
      // Kind-1 feed (200 newest)
      for (final row in await db.queryFeed(limit: 200)) {
        _store.add(_cacheRowToEvent(row));
      }
      // Kind-7 reactions (500 newest)
      for (final row in await db.queryRecentReactions(limit: 500)) {
        _store.add(_cacheRowToEvent(row));
      }
      // Kind-0 metadata (all cached)
      for (final row in await db.queryAllMetadata()) {
        _store.add(_replaceableRowToEvent(row));
      }
      if (_store.length > 0) {
        _dirty = true;
        _scheduleFlush();
      }
    } catch (_) {
      // Hydration failure — continue with empty store, relays will fill it.
    }
  }

  /// Persist an event to SQLite. Only persists events related to the user's
  /// social graph (follows + self):
  /// - Replaceable events (kind 0/3/10000+/30000+): ALWAYS cached (tiny,
  ///   deduped by pubkey+kind, used for avatars/follows/bookmarks).
  /// - Immutable events (kind 1/7): ONLY if author is in the follows set or
  ///   is the user themselves. Global firehose events from random users are
  ///   NOT persisted (in-memory only for browsing).
  Future<void> _persist(Event e) async {
    final db = _cache;
    if (db == null) return;
    try {
      final isReplaceable = e.kind == 0 || e.kind == 3 ||
          (e.kind >= 10000 && e.kind < 20000) ||
          (e.kind >= 30000 && e.kind < 40000);
      if (!isReplaceable) {
        // Immutable events: only cache from social graph (follows + followers + self).
        final graph = ref.read(socialGraphProvider);
        if (!graph.contains(e.pubkey)) {
          return; // global firehose from non-social-graph users — in-memory only
        }
      }
      await db.writeEvent(
        id: e.id,
        pubkey: e.pubkey,
        kind: e.kind,
        createdAt: e.createdAt,
        content: e.content,
        sig: e.sig,
        raw: jsonEncode(e.toWireObject()),
        tagsJson: jsonEncode(e.tags),
        tags: e.tags,
      );
    } catch (_) {}
  }

  Event _cacheRowToEvent(cache.EventRow row) {
    return Event(
      id: row.id,
      pubkey: row.pubkey,
      createdAt: row.createdAt,
      kind: row.kind,
      tags: (jsonDecode(row.tagsJson) as List).cast<List<dynamic>>(),
      content: row.content,
      sig: row.sig,
    );
  }

  Event _replaceableRowToEvent(cache.ReplaceableEvent row) {
    return Event(
      id: row.id,
      pubkey: row.pubkey,
      createdAt: row.createdAt,
      kind: row.kind,
      tags: (jsonDecode(row.tagsJson) as List).cast<List<dynamic>>(),
      content: row.content,
      sig: row.sig,
    );
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

// --- Following (NIP-02 kind-3) with local cache (Amethyst pattern) --------

/// Locally cached kind-3 event (the user's contact list). Follow operations
/// read from this cache — NOT from a relay re-fetch — to guarantee that
/// following user B doesn't wipe user A (who was followed moments ago but
/// the relay hasn't synced yet). Populated by [FollowingNotifier] on initial
/// fetch; updated by [followUser] after each follow.
class ContactListCacheNotifier extends Notifier<Event?> {
  @override
  Event? build() => null;
  void set(Event? e) => state = e;
}

final contactListCacheProvider =
    NotifierProvider<ContactListCacheNotifier, Event?>(ContactListCacheNotifier.new);

/// The user's social graph: follows + followers + self. Used by
/// EventStoreNotifier._persist to decide which events to cache to SQLite
/// (only events from the social graph are persisted — global firehose is
/// in-memory only). Updated by FollowingNotifier (follows) +
/// userFollowersProvider (followers) + identityProvider (self).
class SocialGraphNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Watch identity for self pubkey.
    final id = ref.watch(identityProvider).value;
    final self = id?.pubkeyHex;
    // Watch follows.
    final follows = ref.watch(followingStateProvider).value ?? const <String>[];
    final set = <String>{...follows};
    if (self != null) set.add(self);
    return set;
  }

  /// Add follower pubkeys (called when userFollowersProvider resolves).
  void addFollowers(List<String> pubkeys) {
    state = {...state, ...pubkeys};
  }
}

final socialGraphProvider =
    NotifierProvider<SocialGraphNotifier, Set<String>>(SocialGraphNotifier.new);

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
        // Cache the full kind-3 event for followUser to use.
        ref.read(contactListCacheProvider.notifier).set(e);
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
      const Duration(seconds: 10),
      onTimeout: () => ref.read(contactListCacheProvider)?.pTagPubkeys ?? const <String>[],
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
  // Keep subscription open (no closeOnEose) so live reactions (kind-7) +
  // metadata (kind-0) continue arriving after the initial snapshot.
  // EventStore cap (5000) bounds memory; throttled emission bounds CPU.
  pool.request(
    subId,
    buildFeedFilter(mode, follows),
    closeOnEose: false,
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

  // Only kind-1 text notes appear in the feed. Kind-0 (metadata) and
  // kind-7 (reactions) are stored for lookups but NOT rendered as posts.
  Iterable<Event> events = all.where((e) => e.isTextNote);

  if (mode == FeedMode.following) {
    final follows = ref.watch(followingStateProvider).value ?? const <String>[];
    final set = follows.toSet();
    events = events.where((e) => set.contains(e.pubkey));
  }

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
  // Add followers to the social graph so their events get cached too.
  ref.read(socialGraphProvider.notifier).addFollowers(collected);
  return collected;
});

// --- Search (NIP-50, via nostr.wine) --------------------------------------

/// A follow group: name + the pubkeys in it.
class FollowGroup {
  const FollowGroup(this.name, this.pubkeys);
  final String name;
  final List<String> pubkeys;
}

/// The logged-in user's follows grouped by NIP-51 kind-30000 categories.
/// First entry is 默认分组 (follows not in any custom group). Then one entry
/// per custom group (d-tag name) with the pubkeys in that group.
/// pubkeys in custom groups are also kept in 默认分组 only if not in any group.
final userGroupedFollowsProvider =
    FutureProvider.family<List<FollowGroup>, String>(
        (ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);

  // 1. Fetch kind-3 (master follow list) p-tags.
  final kind3Completer = Completer<List<String>>();
  late StreamSubscription<Event> evSub1;
  late StreamSubscription<String> eoseSub1;
  evSub1 = pool.events.listen((e) {
    if (e.isContactList && e.pubkey == pubkey && !kind3Completer.isCompleted) {
      kind3Completer.complete(e.pTagPubkeys);
    }
  });
  final sub1 = nextSubId('grouped-k3');
  final conn1 = pool.states.where((s) => s.status == RelayStatus.connected).length;
  var e1 = 0;
  eoseSub1 = pool.eoseStream.where((s) => s == sub1).listen((_) {
    e1++;
    if (e1 >= conn1 && !kind3Completer.isCompleted) {
      kind3Completer.complete(const <String>[]);
    }
  });
  pool.request(sub1, {
    'authors': [pubkey], 'kinds': [Event.kindContactList], 'limit': 1,
  }, closeOnEose: true);
  ref.onDispose(() { evSub1.cancel(); eoseSub1.cancel(); pool.closeSubscription(sub1); });

  // 2. Fetch all kind-30000 events (follow sets).
  final k30000Events = <Event>[];
  final k30000Completer = Completer<void>();
  late StreamSubscription<Event> evSub2;
  late StreamSubscription<String> eoseSub2;
  evSub2 = pool.events.listen((e) {
    if (e.kind == 30000 && e.pubkey == pubkey) k30000Events.add(e);
  });
  final sub2 = nextSubId('grouped-k30k');
  var e2 = 0;
  eoseSub2 = pool.eoseStream.where((s) => s == sub2).listen((_) {
    e2++;
    if (e2 >= conn1 && !k30000Completer.isCompleted) k30000Completer.complete();
  });
  pool.request(sub2, {
    'authors': [pubkey], 'kinds': [30000],
  }, closeOnEose: true);
  ref.onDispose(() { evSub2.cancel(); eoseSub2.cancel(); pool.closeSubscription(sub2); });

  // Wait for both.
  final follows = await kind3Completer.future
      .timeout(const Duration(seconds: 10), onTimeout: () => const <String>[]);
  await k30000Completer.future
      .timeout(const Duration(seconds: 10), onTimeout: () {});

  // 3. Build group → Set<pubkey> from kind-30000 events.
  final groupNames = <String>[];
  final groupPubkeys = <String, Set<String>>{};
  for (final e in k30000Events) {
    String? name;
    final pks = <String>{};
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) name = t[1] as String;
      if (t.length >= 2 && t[0] == 'p' && t[1] is String) pks.add(t[1] as String);
    }
    if (name != null && name.isNotEmpty) {
      if (!groupNames.contains(name)) groupNames.add(name);
      groupPubkeys.putIfAbsent(name, () => <String>{}).addAll(pks);
    }
  }

  // 4. Group the follows.
  final allGrouped = <String, bool>{};
  final result = <FollowGroup>[];
  // Default group: follows not in any custom group.
  final defaultGroup = <String>[];
  for (final pk in follows) {
    var inAnyGroup = false;
    for (final name in groupNames) {
      if (groupPubkeys[name]!.contains(pk)) {
        inAnyGroup = true;
        break;
      }
    }
    if (!inAnyGroup) defaultGroup.add(pk);
    allGrouped[pk] = inAnyGroup;
  }
  result.add(FollowGroup('默认分组', defaultGroup));
  // Custom groups: follows that are in this group.
  for (final name in groupNames) {
    final inGroup = follows.where((pk) => groupPubkeys[name]!.contains(pk)).toList();
    if (inGroup.isNotEmpty) result.add(FollowGroup(name, inGroup));
  }
  return result;
});

/// The logged-in user's existing follow-group names (NIP-51 kind-30000 `d`
/// tags). Used by the follow-group picker to show existing + allow new.
final userGroupNamesProvider = FutureProvider.family<List<String>, String>(
    (ref, pubkey) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <String>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.kind == 30000 && e.pubkey == pubkey) {
      for (final t in e.tags) {
        if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
          final name = t[1] as String;
          if (name.isNotEmpty && seen.add(name)) collected.add(name);
        }
      }
    }
  });
  final subId = nextSubId('groups');
  final connectedCount =
      pool.states.where((s) => s.status == RelayStatus.connected).length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(
    subId,
    <String, dynamic>{'authors': [pubkey], 'kinds': [30000]},
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  return collected;
});

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

/// Reactions (NIP-25 kind-7) for an event. Reads from the EventStore (kind-7
/// events arrive as part of the global feed REQ {kinds:[1,7]}). No separate
/// #e parameterized query needed (most relays don't support #e anyway).
final reactionsProvider =
    Provider.family<Map<String, int>, String>((ref, eventId) {
  final store = ref.watch(eventStoreProvider);
  final counts = <String, int>{};
  for (final e in store) {
    if (e.kind != 7) continue;
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) {
        final key = e.content.isEmpty ? '+' : e.content;
        counts[key] = (counts[key] ?? 0) + 1;
        break;
      }
    }
  }
  return counts;
});

/// Replies (kind-1) to an event. REQ {kinds:[1], "#e":[eventId]}.
/// Returns List<Event> sorted newest-first.
final repliesProvider =
    FutureProvider.family<List<Event>, String>((ref, eventId) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <Event>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.events.listen((e) {
    if (e.isTextNote && !seen.add(e.id)) return;
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) {
        collected.add(e);
        break;
      }
    }
  });
  final subId = nextSubId('replies');
  final connectedCount =
      pool.states.where((s) => s.status == RelayStatus.connected).length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(
    subId,
    <String, dynamic>{'kinds': [1], '#e': [eventId]},
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  collected.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return collected;
});

/// Follow [pubkey] (NIP-02). Fetches the current user's kind-3 event (to
/// preserve existing entries' relay/petname), signs an updated kind-3 with the
/// new pubkey added, publishes, and refreshes [followingStateProvider].
/// Follow [pubkey] (NIP-02). Uses the LOCALLY CACHED kind-3 (Amethyst pattern)
/// — NOT a relay re-fetch — so that following B after A doesn't wipe A.
/// The cache is populated by [FollowingNotifier] on initial load and updated
/// here after each follow (optimistic update).
Future<RelayOk> followUser(WidgetRef ref, String pubkey, {String? category}) async {
  final identity = ref.read(identityProvider).value;
  if (identity == null) {
    return const RelayOk('', false, '未登录');
  }
  final pool = ref.read(relayPoolProvider);

  // Read the cached kind-3 — NOT a relay re-fetch. If null (first-ever follow
  // with no existing list on any relay), NostrActions.follow handles null
  // gracefully (publishes a kind-3 with only the new pubkey).
  final current = ref.read(contactListCacheProvider);
  final signed = NostrActions(identity).follow(current, pubkey);
  final ok = await pool.publishAndWait(signed);

  if (ok.ok) {
    // Optimistically update the local cache + follows list.
    ref.read(contactListCacheProvider.notifier).set(signed);
    ref.invalidate(followingStateProvider);

    // If a category is set, also add to the NIP-51 kind-30000 categorized list.
    if (category != null && category.isNotEmpty) {
      await _addToCategoryList(ref, identity, pubkey, category);
    }
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

// --- NSFW settings (local, not synced to relays) ---------------------------

class NsfwSettings {
  const NsfwSettings({this.autoReveal = false, this.defaultComposeNsfw = false});
  final bool autoReveal;
  final bool defaultComposeNsfw;
  NsfwSettings copyWith({bool? autoReveal, bool? defaultComposeNsfw}) =>
      NsfwSettings(
        autoReveal: autoReveal ?? this.autoReveal,
        defaultComposeNsfw: defaultComposeNsfw ?? this.defaultComposeNsfw,
      );
}

class NsfwSettingsNotifier extends Notifier<NsfwSettings> {
  static const _kAutoReveal = 'costr.nsfw.autoReveal';
  static const _kDefault = 'costr.nsfw.defaultCompose';

  @override
  NsfwSettings build() {
    _load();
    return const NsfwSettings();
  }

  Future<void> _load() async {
    final s = ref.read(storageProvider);
    final ar = await s.readValue(_kAutoReveal);
    final dc = await s.readValue(_kDefault);
    if (ar != null || dc != null) {
      state = NsfwSettings(
        autoReveal: ar == 'true',
        defaultComposeNsfw: dc == 'true',
      );
    }
  }

  Future<void> setAutoReveal(bool v) async {
    state = state.copyWith(autoReveal: v);
    await ref.read(storageProvider).writeValue(_kAutoReveal, v.toString());
  }

  Future<void> setDefaultComposeNsfw(bool v) async {
    state = state.copyWith(defaultComposeNsfw: v);
    await ref.read(storageProvider).writeValue(_kDefault, v.toString());
  }
}

final nsfwSettingsProvider =
    NotifierProvider<NsfwSettingsNotifier, NsfwSettings>(NsfwSettingsNotifier.new);

// --- Relay status -----------------------------------------------------------

final relayStatusProvider =
    StreamProvider<List<RelayState>>((ref) => ref.watch(relayPoolProvider).statusStream);

// --- User metadata (NIP-01 kind 0) ----------------------------------------

/// Per-pubkey metadata cache. Checks the EventStore first (kind-0 events
/// arrive via the global feed REQ {kinds:[0,1,7]}). Falls back to a
/// dedicated REQ if not cached. Cached for the session.
final metadataProvider =
    FutureProvider.family<Metadata?, String>((ref, pubkey) async {
  // 1. Check EventStore first (kind-0 may have arrived via global feed).
  final store = ref.watch(eventStoreProvider);
  for (final e in store) {
    if (e.kind == 0 && e.pubkey == pubkey) {
      try {
        final json = jsonDecode(e.content);
        if (json is Map<String, dynamic>) return Metadata.fromJson(json);
      } catch (_) {}
    }
  }
  // 2. Fall back to a dedicated REQ.
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
