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
import 'package:http/http.dart' as http;

import '../models/event.dart';
import '../models/metadata.dart';
import '../utils/nip19.dart';
import '../nostr/actions.dart';
import '../nostr/event_store.dart';
import '../nostr/identity.dart';
import '../nostr/relay_client.dart';
import '../nostr/relay_pool.dart';
import '../services/local_cache.dart' as cache;
import '../services/blossom_upload.dart';
import '../services/secure_storage_service.dart';
import '../utils/language.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Default relays. bostr requires NIP-42 auth to write (read-only for us);
/// ditto/damus/gulugulu accept writes and are broadly queried, so posts reach
/// other clients.
const List<String> defaultRelays = <String>[
  'wss://damus.bostr.online/',
  'wss://relay.gulugulu.moe/',
  'wss://relay.ditto.pub/',
  'wss://relay.bostr.online/',
  'wss://multiplexer.huszonegy.world/',
  'wss://relay.nostr.net/',
  'wss://relay.0xchat.com/',
  'wss://top.testrelay.top/',
];

/// Dedicated NIP-50 search relays. Global search (searchPostsProvider /
/// searchUsersProvider) is routed ONLY to these, NOT [defaultRelays], because
/// most relays don't support the NIP-50 `search` filter and silently ignore
/// it — returning a firehose of recent kind-1/kind-0 events unrelated to the
/// query (the "irrelevant results" bug). search.nos.today + relay.ditto.pub
/// both implement NIP-50 full-text search.
const List<String> searchRelays = <String>[
  'wss://relay.ditto.pub/',
  'wss://search.nos.today/',
];

// --- Local cache (drift/SQLite) — provider ---

final localCacheProvider = FutureProvider<cache.LocalCache>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'costr.db');
  final db = cache.LocalCache.open(dbPath);
  ref.onDispose(db.close);
  return db;
});

/// The user's configured server lists (relays + Blossom), sourced from the
/// local SQLite cache (the editable source of truth, seeded from the code
/// constants on first run) and published to Nostr (kind 10002 relays /
/// kind 10063 Blossom). The 服务器节点 page reads from here. Edit UI is
/// future work; for now the lists equal the seeded constants.
class ServerLists {
  const ServerLists(this.relays, this.blossom);
  final List<String> relays;
  final List<String> blossom;
}

final serverListsProvider = FutureProvider<ServerLists>((ref) async {
  final db = await ref.read(localCacheProvider.future);
  var relays = await db.readServerList('relay_list');
  if (relays == null || relays.isEmpty) {
    relays = defaultRelays;
    await db.writeServerList('relay_list', relays);
  }
  var blossom = await db.readServerList('blossom_list');
  if (blossom == null || blossom.isEmpty) {
    blossom = blossomServersConst;
    await db.writeServerList('blossom_list', blossom);
  }
  return ServerLists(relays, blossom);
});

// Re-export the Blossom server list constant (defined in
// services/blossom_upload.dart) so serverListsProvider can seed the local
// cache without callers needing to import the upload module directly.
const List<String> blossomServersConst = blossomServers;

// Monotonic subId counter, namespaced for relay-log readability.
int _seq = 0;
String nextSubId(String purpose) => 'costr:$purpose:${_seq++}';

/// Build a NIP-01 REQ filter for the given feed mode + follows. Pure function
/// so it can be unit-tested independently of the relay pool.
Map<String, dynamic> buildFeedFilter(FeedMode mode, List<String> follows) {
  final filter = <String, dynamic>{
    'kinds': [0, 1, 6, 7], // metadata + text notes + reposts + reactions (Amethyst pattern)
    'limit': 200,
  };
  if (mode == FeedMode.following && follows.isNotEmpty) {
    filter['authors'] = List<String>.from(follows);
  }
  return filter;
}

/// A user's NIP-65 relay list (kind 10002): outbox (read) + inbox (write)
/// relays. Parsed from the `["r", url, marker?]` tags. A tag with no marker
/// means the relay is used for both read + write; `marker == "read"` →
/// read-only, `"write"` → write-only.
@visibleForTesting
class RelayList {
  const RelayList({this.read = const [], this.write = const []});
  final List<String> read;
  final List<String> write;

  /// Parse a kind-10002 event. Returns null if [e] isn't kind 10002. Dedupes
  /// by URL, preserving first-seen order.
  static RelayList? parse(Event e) {
    if (e.kind != 10002) return null;
    final read = <String>{};
    final write = <String>{};
    for (final t in e.tags) {
      if (t.length < 2 || t[0] != 'r' || t[1] is! String) continue;
      final url = (t[1] as String).trim();
      if (url.isEmpty) continue;
      final marker =
          (t.length >= 3 && t[2] is String) ? (t[2] as String).trim() : '';
      if (marker == 'read') {
        read.add(url);
      } else if (marker == 'write') {
        write.add(url);
      } else {
        read.add(url);
        write.add(url);
      }
    }
    return RelayList(read: read.toList(), write: write.toList());
  }
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
    // NIP-65: publish relay list right after first login (cold-start publish
    // only fires if an identity was already stored). Fire-and-forget.
    publishRelayList(ref.read(relayPoolProvider), identity);
  }

  Future<void> logout() async {
    await ref.read(storageProvider).deleteNsec();
    state = const AsyncData(null);
  }
}

final identityProvider = AsyncNotifierProvider<IdentityNotifier, Identity?>(
  IdentityNotifier.new,
);

// --- Relay pool --------------------------------------------------------------

final relayPoolProvider = Provider<RelayPool>((ref) {
  final pool = RelayPool.fromUrls(defaultRelays);
  // Lazy identity getter for NIP-42 AUTH responses (works after login).
  pool.identityGetter = () => ref.read(identityProvider).value;
  ref.onDispose(pool.dispose);
  return pool;
});

/// A separate, isolated relay pool for NIP-50 full-text search. Connected
/// lazily on first read (first search). Kept separate from [relayPoolProvider]
/// so (a) search REQs only reach NIP-50-capable relays and (b) search
/// results don't mix with the live global feed on a shared merged stream.
final searchPoolProvider = Provider<RelayPool>((ref) {
  final pool = RelayPool.fromUrls(searchRelays);
  pool.identityGetter = () => ref.read(identityProvider).value;
  // Connect lazily; RelayClient reconnects with backoff on failure.
  pool.connect();
  ref.onDispose(pool.dispose);
  return pool;
});

/// A user's NIP-65 relay list (kind 10002) — their outbox/inbox relays.
/// Fetched by broadcasting a REQ to the main pool (we don't know the user's
/// relays yet, so we can't target them), parsing the newest matching kind-10002
/// event via [RelayList.parse]. In-memory TTL cache (5 min) per pubkey so
/// repeated profile views don't re-fetch. Returns null if the user has no
/// published relay list. Used to DIRECT profile/posts REQs at the author's
/// own relays ([RelayPool.fetchFromUrls]) instead of broadcasting — much
/// higher hit rate for users whose events live only on their outbox relays.
final userRelayListProvider = FutureProvider.family<RelayList?, String>((
  ref,
  pubkey,
) async {
  final cached = _relayListCache[pubkey];
  if (cached != null) {
    final age = DateTime.now().difference(cached.fetchedAt);
    if (age < const Duration(minutes: 5)) return cached.list;
  }
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<void>();
  Event? newest;
  final seen = <String>{};
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final subId = nextSubId('rl');
  evSub = pool.rawEvents.listen((e) {
    if (e.pubkey != pubkey || e.kind != 10002) return;
    if (!seen.add(e.id)) return;
    if (newest == null || e.createdAt > newest!.createdAt) {
      newest = e;
    }
  });
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(
    subId,
    <String, dynamic>{
      'kinds': [10002],
      'authors': [pubkey],
      'limit': 1,
    },
    closeOnEose: true,
  );
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 8), onTimeout: () {});
  final list = newest == null ? null : RelayList.parse(newest!);
  if (list != null) {
    _relayListCache[pubkey] = _CachedRelayList(list, DateTime.now());
  }
  return list;
});

class _CachedRelayList {
  const _CachedRelayList(this.list, this.fetchedAt);
  final RelayList list;
  final DateTime fetchedAt;
}

final Map<String, _CachedRelayList> _relayListCache = {};

/// Loads identity from secure storage, then opens relay connections. The router
/// waits on this before resolving redirects, avoiding a cold-start race.
/// Also triggers cache cleanup 30s after startup (Jumble pattern).
final bootstrapProvider = FutureProvider<void>((ref) async {
  await ref.watch(identityProvider.future);
  final pool = ref.read(relayPoolProvider);
  await pool.connect();
  // Per-relay publish retry: when a publish succeeds on some relays but
  // background retries to the rest are exhausted (event published, but not
  // everywhere), save it to the drafts table so a later session retries the
  // missing relays — "尽量保证所有中继都发布成功".
  pool.onPublishExhausted = (event) {
    final db = ref.read(localCacheProvider).value;
    if (db != null) {
      unawaited(db.saveDraft(jsonEncode(event.toWireObject())));
    }
  };
  // NIP-65: publish our relay list (kind 10002) in the background so other
  // clients can discover the author's relays (outbox/inbox model). Fire-and-
  // forget — must not block the router. kind 10002 is replaceable, so
  // re-publishing on every cold start just replaces the prior list.
  final identity = ref.read(identityProvider).value;
  if (identity != null) {
    publishRelayList(pool, identity);
    // Retry drafts (failed publishes from a prior session). publishAndWait
    // already does in-session per-relay retry; this covers cross-session.
    unawaited(
      ref.read(localCacheProvider.future).then((db) => retryDrafts(pool, db)),
    );
    // Bulk-prefetch metadata (kind 0) for the whole social graph (follows +
    // followers + self) so avatars/profiles resolve instantly. Deferred 5s
    // so the feed renders first; fire-and-forget.
    Timer(const Duration(seconds: 5), () {
      if (ref.read(identityProvider).value != null) {
        unawaited(ref.read(socialGraphMetadataPrefetchProvider.future));
      }
    });
  }
  // Cache cleanup 30s after startup (avoids startup jank).
  Timer(const Duration(seconds: 30), () async {
    final cache = ref.read(localCacheProvider).value;
    if (cache == null) return;
    try {
      await cache.cleanupOldEvents(ttlDays: 30);
      await cache.enforceSizeCap();
      await cache.vacuum();
    } catch (_) {}
  });
});

/// Sign + publish the NIP-65 relay list (kind 10002) for [identity] to
/// [pool]. Fire-and-forget; safe to call on every cold start (replaceable).
void publishRelayList(RelayPool pool, Identity identity) {
  final signed = NostrActions(identity).relayList(defaultRelays);
  unawaited(pool.publishAndWait(signed));
}

/// Retry publishing drafts — events that failed to publish in a prior
/// session (saved via [RelayPool]'s `onPublishExhausted` hook or compose's
/// all-failed path). Loads all drafts, re-publishes each via
/// [RelayPool.publishAndWait] (which itself does the per-relay 1s/2s/3s
/// retry), deletes on success or bumps the attempt count. Fire-and-forget
/// on cold start so previously-dropped publishes eventually land.
Future<void> retryDrafts(RelayPool pool, cache.LocalCache db) async {
  final drafts = await db.getDraftsWithRowid();
  for (final (rowid, rawJson) in drafts) {
    try {
      final ev = Event.fromJson(
        jsonDecode(rawJson) as Map<String, dynamic>,
      );
      final ok = await pool.publishAndWait(ev);
      if (ok.ok) {
        await db.deleteDraft(rowid);
      } else {
        await db.incrementDraftAttempts(rowid);
      }
    } catch (_) {
      await db.incrementDraftAttempts(rowid);
    }
  }
}

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
      if ((e.kind == 0 || e.isTextNote || e.isRepost || e.kind == 7) &&
          _store.add(e)) {
        _persist(e);
        _scheduleFlush();
      }
      // A kind-30000 Follow Set authored by the logged-in user changed the
      // categorization overlay — bump so grouped-follows/group-names refresh.
      // Read identity per-event: it may resolve after this build ran.
      if (e.kind == 30000 &&
          e.pubkey == ref.read(identityProvider).value?.pubkeyHex) {
        ref.read(kind30000VersionProvider.notifier).bump();
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
      final isReplaceable =
          e.kind == 0 ||
          e.kind == 3 ||
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

  /// Force-persist a thread event to SQLite **regardless of social-graph
  /// membership**. Called for posts on a reply chain the user opened (root +
  /// ancestors + the focused post + its visible replies) — the user may want
  /// to reply to them later, so the chain is cached even when the authors
  /// aren't followed. Only invoked for actually-viewed thread posts, so we
  /// do NOT cache these users' other posts.
  Future<void> cacheThreadEvent(Event e) async {
    final db = _cache;
    if (db == null) return;
    try {
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

  /// Add an externally-fetched event to the in-memory store + SQLite. Used by
  /// [RelayPool.fetchFromUrls] (NIP-65 outbox routing): those events bypass
  /// the pool's merged stream, so the normal [pool.events] listener never
  /// sees them — ingest them here so the rest of the app (feed, detail pages,
  /// replies) finds them, and persist so a later visit is instant. Persists
  /// regardless of social-graph membership, like [cacheThreadEvent] (the user
  /// opened the profile, so cache its posts).
  Future<void> ingest(Event e) async {
    if (_store.add(e)) {
      state = _store.events;
      unawaited(cacheThreadEvent(e));
    }
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

/// Top-level helper: convert a drift EventRow to our Event model.
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

final eventStoreProvider = NotifierProvider<EventStoreNotifier, List<Event>>(
  EventStoreNotifier.new,
);

// --- Feed mode --------------------------------------------------------------

enum FeedMode { global, following }

/// Last-used feed mode, persisted in the config table (key `feed_mode`).
/// Restored into [FeedModeNotifier] on startup so the app reopens on the
/// tab (全球 / 关注) the user last selected.
final savedFeedModeProvider = FutureProvider<FeedMode>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  final raw = await cache.readConfig('feed_mode');
  return raw == 'following' ? FeedMode.following : FeedMode.global;
});

class FeedModeNotifier extends Notifier<FeedMode> {
  @override
  FeedMode build() {
    // Default to 全球 until the persisted value loads; the Notifier rebuilds
    // (snapping to the saved mode) once [savedFeedModeProvider] resolves.
    return ref.watch(savedFeedModeProvider).value ?? FeedMode.global;
  }

  void set(FeedMode mode) {
    if (mode == state) return;
    state = mode;
    // Persist (fire-and-forget; SQLite write is ms-fast).
    final value = mode == FeedMode.following ? 'following' : 'global';
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('feed_mode', value));
  }
}

final feedModeProvider = NotifierProvider<FeedModeNotifier, FeedMode>(
  FeedModeNotifier.new,
);

// --- Feed filters: language + hashtag ---------------------------------------

enum LanguageFilter { all, zh, en, ja }

/// Last-used language filter, persisted in the config table (key
/// `language_filter`). Restored into [LanguageFilterNotifier] on startup.
final savedLanguageFilterProvider = FutureProvider<LanguageFilter>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  final raw = await cache.readConfig('language_filter');
  switch (raw) {
    case 'zh':
      return LanguageFilter.zh;
    case 'en':
      return LanguageFilter.en;
    case 'ja':
      return LanguageFilter.ja;
    default:
      return LanguageFilter.all;
  }
});

class LanguageFilterNotifier extends Notifier<LanguageFilter> {
  @override
  LanguageFilter build() =>
      ref.watch(savedLanguageFilterProvider).value ?? LanguageFilter.all;

  void set(LanguageFilter f) {
    if (f == state) return;
    state = f;
    final value = switch (f) {
      LanguageFilter.zh => 'zh',
      LanguageFilter.en => 'en',
      LanguageFilter.ja => 'ja',
      LanguageFilter.all => 'all',
    };
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('language_filter', value));
  }
}

final languageFilterProvider =
    NotifierProvider<LanguageFilterNotifier, LanguageFilter>(
      LanguageFilterNotifier.new,
    );

class TagFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;
  void set(String tag) => state = tag.toLowerCase();
  void clear() => state = null;
}

final tagFilterProvider = NotifierProvider<TagFilterNotifier, String?>(
  TagFilterNotifier.new,
);

// --- Followed hashtags (NIP-51 kind-30015 Interests, relay-synced + cached) --

/// In-memory cache of the user's kind-30015 default Interests event, held for
/// the session so add/remove can read the current list without a relay
/// round-trip (same pattern as [contactListCacheProvider] for kind-3).
class FollowedTagsCacheNotifier extends Notifier<Event?> {
  @override
  Event? build() => null;
  void set(Event? e) => state = e;
}

final followedTagsCacheProvider =
    NotifierProvider<FollowedTagsCacheNotifier, Event?>(
      FollowedTagsCacheNotifier.new,
    );

/// The user's followed hashtags. Source of truth is the user's NIP-51
/// kind-30015 default Interests list (d-tag "", `t` tags = followed hashtags),
/// published to relays. A local SQLite copy ([LocalCache.queryInterests])
/// hydrates instantly on cold start before the relay responds. add/remove
/// sign an updated kind-30015 via [NostrActions.interests], publish, and
/// optimistically update the in-memory + SQLite cache.
class FollowedTagsNotifier extends AsyncNotifier<List<String>> {
  StreamSubscription<Event>? _sub;
  StreamSubscription<String>? _eoseSub;

  @override
  Future<List<String>> build() async {
    final identity = await ref.watch(identityProvider.future);
    if (identity == null) return const <String>[];

    final pubkey = identity.pubkeyHex;
    final cache = await ref.read(localCacheProvider.future);

    // 1. Hydrate from SQLite (instant cold-start, before relay responds).
    Event? cached;
    try {
      final row = await cache.queryInterests(pubkey);
      if (row != null) cached = _replaceableToEvent(row);
    } catch (_) {}
    if (cached != null) {
      ref.read(followedTagsCacheProvider.notifier).set(cached);
    }

    // 2. Fetch the newest kind-30015 (default list, d "") from relays.
    final pool = ref.read(relayPoolProvider);
    Event? newest;
    final completer = Completer<void>();
    _sub = pool.rawEvents.listen((e) {
      if (e.kind != 30015 || e.pubkey != pubkey) return;
      if (!_isDefaultInterests(e)) return; // ignore named interest sets
      if (newest == null || e.createdAt > newest!.createdAt) newest = e;
    });
    final subId = nextSubId('interests');
    final connectedCount = pool.states
        .where((s) => s.status == RelayStatus.connected)
        .length;
    var eoses = 0;
    _eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
      eoses++;
      if (eoses >= connectedCount && !completer.isCompleted) {
        completer.complete();
      }
    });
    pool.request(subId, <String, dynamic>{
      'authors': [pubkey],
      'kinds': [30015],
      'limit': 5,
    }, closeOnEose: true);
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {},
    );
    _sub?.cancel();
    _sub = null;
    _eoseSub?.cancel();
    _eoseSub = null;
    pool.closeSubscription(subId);

    // 3. If the relay returned a newer list, persist + update the cache.
    if (newest != null &&
        (cached == null || newest!.createdAt > cached.createdAt)) {
      await _persist(cache, newest!);
      ref.read(followedTagsCacheProvider.notifier).set(newest);
      return _tagsOf(newest);
    }
    return _tagsOf(cached);
  }

  /// Default list = d tag is "" or absent (named interest sets are ignored).
  static bool _isDefaultInterests(Event e) {
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
        return (t[1] as String).isEmpty;
      }
    }
    return true;
  }

  static Event _replaceableToEvent(cache.ReplaceableEvent row) => Event(
    id: row.id,
    pubkey: row.pubkey,
    createdAt: row.createdAt,
    kind: row.kind,
    tags: (jsonDecode(row.tagsJson) as List).cast<List<dynamic>>(),
    content: row.content,
    sig: row.sig,
  );

  static List<String> _tagsOf(Event? e) {
    if (e == null) return const <String>[];
    final out = <String>[];
    final seen = <String>{};
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 't' && t[1] is String) {
        final v = (t[1] as String).toLowerCase();
        if (v.isNotEmpty && seen.add(v)) out.add(v);
      }
    }
    return out;
  }

  Future<void> _persist(cache.LocalCache db, Event e) async {
    try {
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

  Future<bool> _mutate({String? add, String? remove}) async {
    final identity = ref.read(identityProvider).value;
    if (identity == null) return false;
    final current = ref.read(followedTagsCacheProvider);
    final signed = NostrActions(
      identity,
    ).interests(current, add: add, remove: remove);
    final next = _tagsOf(signed);
    // Optimistic update so the UI reflects the change immediately.
    state = AsyncData(next);
    ref.read(followedTagsCacheProvider.notifier).set(signed);

    final pool = ref.read(relayPoolProvider);
    final ok = await pool.publishAndWait(signed);
    if (ok.ok) {
      final cache = await ref.read(localCacheProvider.future);
      await _persist(cache, signed);
      return true;
    }
    // Revert on failure.
    state = AsyncData(_tagsOf(current));
    ref.read(followedTagsCacheProvider.notifier).set(current);
    return false;
  }

  Future<bool> add(String tag) async {
    final t = tag.toLowerCase().replaceAll('#', '').trim();
    if (t.isEmpty) return false;
    if ((state.value ?? const <String>[]).contains(t)) return true;
    return _mutate(add: t);
  }

  Future<bool> remove(String tag) async {
    final t = tag.toLowerCase().replaceAll('#', '').trim();
    if (t.isEmpty) return false;
    if (!(state.value ?? const <String>[]).contains(t)) return true;
    return _mutate(remove: t);
  }
}

final followedTagsProvider =
    AsyncNotifierProvider<FollowedTagsNotifier, List<String>>(
      FollowedTagsNotifier.new,
    );

/// Approximate post count for a hashtag from the in-memory store (global
/// firehose, capped). Shown on followed-tag chips (DESIGN §8 "#tag + 帖子数").
/// Not a precise global tally — a sample of what's currently cached locally.
final tagPostCountProvider = Provider.family<int, String>((ref, tag) {
  final store = ref.watch(eventStoreProvider);
  var n = 0;
  for (final e in store) {
    if (e.isTextNote && e.hashtags.contains(tag)) n++;
  }
  return n;
});

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
    NotifierProvider<ContactListCacheNotifier, Event?>(
      ContactListCacheNotifier.new,
    );

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

final socialGraphProvider = NotifierProvider<SocialGraphNotifier, Set<String>>(
  SocialGraphNotifier.new,
);

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

    _sub = pool.rawEvents.listen((e) {
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
      onTimeout: () =>
          ref.read(contactListCacheProvider)?.pTagPubkeys ?? const <String>[],
    );
  }
}

final followingStateProvider =
    AsyncNotifierProvider<FollowingNotifier, List<String>>(
      FollowingNotifier.new,
    );

// --- Feed subscription lifecycle (REQ/CLOSE on mode/follows change) --------

/// A void provider that, when watched, keeps the active feed REQ alive. It
/// rebuilds (closing the old sub via onDispose, opening a new one) whenever
/// feed mode, identity, or the follows list changes.
final feedSubscriptionProvider = Provider<void>((ref) {
  final mode = ref.watch(feedModeProvider);
  final identity = ref.watch(identityProvider).value;
  final follows = ref.watch(followingStateProvider).value ?? const <String>[];
  final pool = ref.watch(relayPoolProvider);

  if (identity == null) return;

  // In following mode with no follows yet, there's nothing to fetch — wait for
  // the kind-3 to resolve. onDispose still cleans up when state changes.
  if (mode == FeedMode.following && follows.isEmpty) return;

  final subId = nextSubId('feed');
  // Keep subscription open (no closeOnEose) so live reactions (kind-7) +
  // metadata (kind-0) continue arriving after the initial snapshot.
  // EventStore cap (5000) bounds memory; throttled emission bounds CPU.
  pool.request(subId, buildFeedFilter(mode, follows), closeOnEose: false);
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

  // Only kind-1 text notes and kind-6/16 reposts appear in the feed.
  // Kind-0 (metadata) and kind-7 (reactions) are stored for lookups but NOT
  // rendered as posts.
  Iterable<Event> events = all.where((e) => e.isTextNote || e.isRepost);

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

/// Find an event by id: hit SQLite first (O(1) PK), then in-memory store,
/// else fetch via REQ {ids:[id]}.
final eventByIdProvider = FutureProvider.family<Event?, String>((
  ref,
  id,
) async {
  // 1. SQLite (O(1) PK lookup).
  final cache = ref.watch(localCacheProvider).value;
  if (cache != null) {
    final row = await cache.queryEventById(id);
    if (row != null) {
      return _cacheRowToEvent(row);
    }
  }
  // 2. In-memory store.
  final store = ref.watch(eventStoreProvider);
  for (final e in store) {
    if (e.id == id) return e;
  }
  // 3. Relay REQ.
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> sub;
  sub = pool.rawEvents.listen((e) {
    if (e.id == id && !completer.isCompleted) completer.complete(e);
  });
  final subId = nextSubId('note');
  pool.request(subId, <String, dynamic>{
    'ids': [id],
  }, closeOnEose: true);
  ref.onDispose(() {
    sub.cancel();
    pool.closeSubscription(subId);
  });
  return completer.future.timeout(
    const Duration(seconds: 5),
    onTimeout: () => null,
  );
});

/// Candidate ancestor ids referenced by a kind-1 note's `e` tags — excludes
/// `mention` markers (those aren't replies). Used to seed the parallel walk.
List<String> _candidateAncestorIds(Event e) {
  final ids = <String>{};
  for (final t in e.tags) {
    if (t.length < 2 || t[0] != 'e' || t[1] is! String) continue;
    final marker = (t.length >= 4 && t[3] is String) ? (t[3] as String) : '';
    if (marker == 'mention') continue;
    final id = t[1] as String;
    if (id != e.id) ids.add(id);
  }
  return ids.toList();
}

/// Ancestor chain of a kind-1 note, **root-first**: `[root, …, focused]`.
///
/// Walks up via NIP-10 `e` tags using a **parallel BFS**: from each event it
/// takes all candidate ancestor ids (root + reply markers — usually both
/// live in the focused event's tags already) and fetches them concurrently
/// via [eventByIdProvider]'s 3-tier lookup (SQLite → in-memory → relay REQ).
/// This turns a deep *sequential* walk (5s × depth) into ~one round-trip for
/// the typical 2-level thread. Best-effort: if an ancestor can't be loaded
/// the chain stops there; cycles are guarded by a seen-set + depth cap.
///
/// This is what lets the post-detail page show the *root* post above a reply
/// the user opened (e.g. from a notification) — previously the page only
/// showed the focused event itself, so the replied-to main post was missing.
final threadAncestorsProvider = FutureProvider.family<List<Event>, String>((
  ref,
  id,
) async {
  final focused = await ref.watch(eventByIdProvider(id).future);
  if (focused == null) return const <Event>[];
  final byId = <String, Event>{focused.id: focused};
  final seen = <String>{focused.id};
  var frontier = _candidateAncestorIds(focused);
  for (var depth = 0; depth < 32 && frontier.isNotEmpty; depth++) {
    final fresh = frontier.where((cid) => !seen.contains(cid)).toList();
    if (fresh.isEmpty) break;
    final results = await Future.wait(<Future<Event?>>[
      for (final cid in fresh) ref.read(eventByIdProvider(cid).future),
    ]);
    frontier = <String>[];
    for (final r in results) {
      if (r == null || !seen.add(r.id)) continue;
      byId[r.id] = r;
      frontier = <String>[...frontier, ..._candidateAncestorIds(r)];
    }
  }
  // Build the ordered chain from focused up via immediate-parent pointers.
  final chain = <Event>[focused];
  var cur = focused;
  for (var i = 0; i < 32; i++) {
    final pid = cur.replyToId;
    if (pid == null || pid == cur.id) break;
    final parent = byId[pid];
    if (parent == null) break; // ancestor didn't resolve — stop here
    chain.insert(0, parent);
    cur = parent;
  }
  // Persist the whole chain to SQLite (regardless of author) so the user can
  // reply to any of these posts later. Fire-and-forget — must not delay the
  // chain display; the events are already in memory here.
  final store = ref.read(eventStoreProvider.notifier);
  for (final e in byId.values) {
    unawaited(store.cacheThreadEvent(e));
  }
  return chain;
});

/// A user's public kind-1 notes (posts + replies), newest-first. SQLite first
/// (instant), then relay REQ for fresh data. Used by the profile page.
final userPostsProvider = FutureProvider.family<List<Event>, String>((
  ref,
  pubkey,
) async {
  // 1. SQLite cache (instant).
  final cache = ref.watch(localCacheProvider).value;
  final cached = <Event>[];
  if (cache != null) {
    for (final row in await cache.queryUserPosts(pubkey, limit: 100)) {
      cached.add(_cacheRowToEvent(row));
    }
  }
  // 2. Relay REQ (fresh data, merges into cache via ingest). Try NIP-65
  //    outbox routing first: fetch the user's kind-10002 relays and direct the
  //    REQ at them (much higher hit rate — their posts live on their outbox
  //    relays). Falls back to a broadcast REQ if the user has no published
  //    relay list. Relay list is TTL-cached so repeat visits skip the lookup.
  final pool = ref.watch(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);
  final filter = <String, dynamic>{
    'authors': [pubkey],
    'kinds': [1],
    'limit': 100,
  };
  final collected = <Event>[];
  final seen = <String>{};
  final relays = await ref.watch(userRelayListProvider(pubkey).future);
  final outbox = relays?.read ?? const <String>[];
  if (outbox.isNotEmpty) {
    for (final e in await pool.fetchFromUrls(filter, outbox)) {
      if (e.isTextNote && e.pubkey == pubkey && seen.add(e.id)) {
        collected.add(e);
        unawaited(store.ingest(e));
      }
    }
  } else {
    // No published relay list — broadcast to the main pool.
    final completer = Completer<void>();
    late StreamSubscription<Event> evSub;
    late StreamSubscription<String> eoseSub;
    evSub = pool.rawEvents.listen((e) {
      if (e.isTextNote && e.pubkey == pubkey && seen.add(e.id)) {
        collected.add(e);
      }
    });
    final subId = nextSubId('user');
    eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
      if (!completer.isCompleted) completer.complete();
    });
    pool.request(subId, filter, closeOnEose: true);
    ref.onDispose(() {
      evSub.cancel();
      eoseSub.cancel();
      pool.closeSubscription(subId);
    });
    await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  }
  // Merge cached + fresh, dedup by id, newest-first.
  final all = <Event>[...collected, ...cached];
  final seenMerge = <String>{};
  final merged = <Event>[];
  for (final e in all) {
    if (seenMerge.add(e.id)) merged.add(e);
  }
  merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return merged;
});

/// A user's follows (NIP-02 kind-3 p-tags) for the profile 关注 tab. Fetches
/// the user's kind-3 (replace-by-author) and resolves on EOSE / timeout.
final userFollowsProvider = FutureProvider.family<List<String>, String>((
  ref,
  pubkey,
) async {
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<List<String>>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.isContactList && e.pubkey == pubkey && !completer.isCompleted) {
      completer.complete(e.pTagPubkeys);
    }
  });
  final subId = nextSubId('follows');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!completer.isCompleted) completer.complete(const <String>[]);
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [Event.kindContactList],
    'limit': 1,
  }, closeOnEose: true);
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
final userFollowersProvider = FutureProvider.family<List<String>, String>((
  ref,
  pubkey,
) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <String>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.isContactList && seen.add(e.pubkey)) {
      collected.add(e.pubkey);
    }
  });
  final subId = nextSubId('followers');
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(subId, <String, dynamic>{
    'kinds': [Event.kindContactList],
    '#p': [pubkey],
    'limit': 500,
  }, closeOnEose: true);
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 12), onTimeout: () {});
  // Add followers to the social graph so their events get cached too.
  ref.read(socialGraphProvider.notifier).addFollowers(collected);
  return collected;
});

// --- Search (NIP-50, via the dedicated search pool) --------------------------------------

/// Version counter that bumps whenever a kind-30000 (NIP-51 Follow Set) event
/// for the logged-in user is ingested or published — mirrors Amethyst's
/// `peopleListVersions` reactive pattern. The grouped-follows and group-name
/// providers watch this so a category add/remove (local or remote) re-fetches
/// without needing manual invalidation at every call site.
class Kind30000VersionNotifier extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

final kind30000VersionProvider =
    NotifierProvider<Kind30000VersionNotifier, int>(
      Kind30000VersionNotifier.new,
    );

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
    FutureProvider.family<List<FollowGroup>, String>((ref, pubkey) async {
      // Re-run when any kind-30000 set for the user changes (local publish or
      // remote ingestion bumps this counter).
      ref.watch(kind30000VersionProvider);
      final pool = ref.watch(relayPoolProvider);

      // 1. Fetch kind-3 (master follow list) p-tags.
      final kind3Completer = Completer<List<String>>();
      late StreamSubscription<Event> evSub1;
      late StreamSubscription<String> eoseSub1;
      evSub1 = pool.rawEvents.listen((e) {
        if (e.isContactList &&
            e.pubkey == pubkey &&
            !kind3Completer.isCompleted) {
          kind3Completer.complete(e.pTagPubkeys);
        }
      });
      final sub1 = nextSubId('grouped-k3');
      final conn1 = pool.states
          .where((s) => s.status == RelayStatus.connected)
          .length;
      var e1 = 0;
      eoseSub1 = pool.eoseStream.where((s) => s == sub1).listen((_) {
        e1++;
        if (e1 >= conn1 && !kind3Completer.isCompleted) {
          kind3Completer.complete(const <String>[]);
        }
      });
      pool.request(sub1, {
        'authors': [pubkey],
        'kinds': [Event.kindContactList],
        'limit': 1,
      }, closeOnEose: true);
      ref.onDispose(() {
        evSub1.cancel();
        eoseSub1.cancel();
        pool.closeSubscription(sub1);
      });

      // 2. Fetch all kind-30000 events (follow sets).
      final k30000Events = <Event>[];
      final k30000Completer = Completer<void>();
      late StreamSubscription<Event> evSub2;
      late StreamSubscription<String> eoseSub2;
      evSub2 = pool.rawEvents.listen((e) {
        if (e.kind == 30000 && e.pubkey == pubkey) k30000Events.add(e);
      });
      final sub2 = nextSubId('grouped-k30k');
      var e2 = 0;
      eoseSub2 = pool.eoseStream.where((s) => s == sub2).listen((_) {
        e2++;
        if (e2 >= conn1 && !k30000Completer.isCompleted) {
          k30000Completer.complete();
        }
      });
      pool.request(sub2, {
        'authors': [pubkey],
        'kinds': [30000],
      }, closeOnEose: true);
      ref.onDispose(() {
        evSub2.cancel();
        eoseSub2.cancel();
        pool.closeSubscription(sub2);
      });

      // Wait for both.
      final follows = await kind3Completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => const <String>[],
      );
      await k30000Completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {},
      );

      // 3. Build group → Set<pubkey> from kind-30000 events.
      final groupNames = <String>[];
      final groupPubkeys = <String, Set<String>>{};
      for (final e in k30000Events) {
        String? name;
        final pks = <String>{};
        for (final t in e.tags) {
          if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
            name = t[1] as String;
          }
          if (t.length >= 2 && t[0] == 'p' && t[1] is String) {
            pks.add(t[1] as String);
          }
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
        final inGroup = follows
            .where((pk) => groupPubkeys[name]!.contains(pk))
            .toList();
        if (inGroup.isNotEmpty) result.add(FollowGroup(name, inGroup));
      }
      return result;
    });

/// The logged-in user's existing follow-group names (NIP-51 kind-30000 `d`
/// tags). Used by the follow-group picker to show existing + allow new.
final userGroupNamesProvider = FutureProvider.family<List<String>, String>((
  ref,
  pubkey,
) async {
  // Re-run when any kind-30000 set for the user changes.
  ref.watch(kind30000VersionProvider);
  final pool = ref.watch(relayPoolProvider);
  final collected = <String>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
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
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [30000],
  }, closeOnEose: true);
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  return collected;
});

/// A user known locally (pubkey + parsed kind-0 metadata) — a candidate for
/// @-mention autocomplete in the composer. Sourced from the in-memory
/// EventStore's kind-0 events + the user's follows + self, so it needs no
/// relay round-trip and updates as metadata streams in.
class KnownUser {
  const KnownUser(this.pubkey, this.meta);
  final String pubkey;
  final Metadata? meta;
  String get label => meta?.bestName ?? shortenEntity(hexToNpub(pubkey));
}

/// All locally-known users for @-mention autocomplete. Derived from the
/// EventStore (kind-0 metadata seen via the global feed) + the logged-in
/// user's follows + self. No relay round-trip.
final knownUsersProvider = Provider<List<KnownUser>>((ref) {
  final store = ref.watch(eventStoreProvider);
  final map = <String, KnownUser>{};
  void add(String pk) {
    if (pk.isEmpty) return;
    map.putIfAbsent(pk, () => KnownUser(pk, _metaFromStore(store, pk)));
  }

  for (final e in store) {
    if (e.kind == 0) add(e.pubkey);
  }
  for (final pk
      in ref.watch(followingStateProvider).value ?? const <String>[]) {
    add(pk);
  }
  final self = ref.watch(identityProvider).value?.pubkeyHex;
  if (self != null) add(self);
  return map.values.toList();
});

Metadata? _metaFromStore(List<Event> store, String pubkey) {
  for (final e in store) {
    if (e.kind == 0 && e.pubkey == pubkey) {
      try {
        final j = jsonDecode(e.content);
        if (j is Map<String, dynamic>) return Metadata.fromJson(j);
      } catch (_) {}
    }
  }
  return null;
}

/// A user found by global search (NIP-50 `search` filter, kind 0 metadata).
class UserResult {
  const UserResult(this.pubkey, this.metadata);
  final String pubkey;
  final Metadata? metadata;
}

/// Global post search: SQLite FTS5 (instant local results) + NIP-50 relay
/// search (fresh results from the dedicated search pool, 6s window). Merged +
/// deduped.
final searchPostsProvider = FutureProvider.family<List<Event>, String>((
  ref,
  query,
) async {
  final q = query.trim();
  if (q.isEmpty) return const <Event>[];
  // 1. SQLite FTS5 (instant, local cached events).
  final cache = ref.watch(localCacheProvider).value;
  final cached = <Event>[];
  if (cache != null) {
    try {
      for (final row in await cache.searchEvents(q, limit: 100)) {
        cached.add(_cacheRowToEvent(row));
      }
    } catch (_) {}
  }
  // 2. NIP-50 relay search via the DEDICATED search pool (not the main pool):
  // most relays ignore the `search` filter and would return a firehose of
  // unrelated kind-1 events. The search pool only connects NIP-50 relays.
  final pool = ref.watch(searchPoolProvider);
  final collected = <Event>[];
  final seen = <String>{};
  late StreamSubscription<Event> evSub;
  // rawEvents (not events): re-searching the same term must still return
  // results even though the search pool already saw those event ids.
  evSub = pool.rawEvents.listen((e) {
    if (e.isTextNote && seen.add(e.id)) collected.add(e);
  });
  final subId = nextSubId('search');
  pool.request(subId, <String, dynamic>{
    'search': q,
    'kinds': [1],
    'limit': 100,
  }, closeOnEose: false);
  ref.onDispose(() {
    evSub.cancel();
    pool.closeSubscription(subId);
  });
  await Future<void>.delayed(const Duration(seconds: 6));
  // Merge cached + fresh, dedup by id.
  final all = <Event>[...collected, ...cached];
  final seenMerge = <String>{};
  final merged = <Event>[];
  for (final e in all) {
    if (seenMerge.add(e.id)) merged.add(e);
  }
  merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return merged;
});

/// Global user search (NIP-50 `search` filter, kind 0 metadata) via the
/// dedicated search pool.
final searchUsersProvider = FutureProvider.family<List<UserResult>, String>((
  ref,
  query,
) async {
  final q = query.trim();
  if (q.isEmpty) return const <UserResult>[];
  final pool = ref.watch(searchPoolProvider);
  final collected = <UserResult>[];
  final seen = <String>{};
  late StreamSubscription<Event> evSub;
  evSub = pool.rawEvents.listen((e) {
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
  pool.request(subId, <String, dynamic>{
    'search': q,
    'kinds': [0],
    'limit': 50,
  }, closeOnEose: false);
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
    Provider.family<Map<String, ({int count, String? emojiUrl})>, String>((
      ref,
      eventId,
    ) {
      final store = ref.watch(eventStoreProvider);
      final tallies = <String, ({int count, String? emojiUrl})>{};
      for (final e in store) {
        if (e.kind != 7) continue;
        for (final t in e.tags) {
          if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) {
            final key = e.content.isEmpty ? '+' : e.content;
            final prev = tallies[key];
            // For NIP-30 custom-emoji reactions (content `:shortcode:`), surface
            // the image URL from the kind-7 `["emoji", shortcode, url]` tag so the
            // chip can render the image instead of the raw `:shortcode:` text.
            var url = prev?.emojiUrl;
            if (url == null) {
              for (final et in e.tags) {
                if (et.length >= 3 && et[0] == 'emoji' && et[2] is String) {
                  url = et[2] as String;
                  break;
                }
              }
            }
            tallies[key] = (count: (prev?.count ?? 0) + 1, emojiUrl: url);
            break;
          }
        }
      }
      return tallies;
    });

/// True if [e] is a kind-1 text note that directly references [eventId] via an
/// `e` tag — i.e. a genuine reply. Used by [repliesProvider]'s global-stream
/// listener, which receives the un-deduped `rawEvents` stream shared with
/// every subscription. The feed sub also requests kind-7 reactions, and a
/// reaction that #e-references the focused post would otherwise be collected
/// as a reply and rendered as a post — only kind-1 notes are replies.
@visibleForTesting
bool isReplyToEvent(Event e, String eventId) {
  if (!e.isTextNote) return false;
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) return true;
  }
  return false;
}

/// Replies (kind-1) to an event. REQ {kinds:[1], "#e":[eventId]}.
/// Returns `List<Event>` sorted newest-first.
final repliesProvider = FutureProvider.family<List<Event>, String>((
  ref,
  eventId,
) async {
  final pool = ref.watch(relayPoolProvider);
  final collected = <Event>[];
  final seen = <String>{};
  final completer = Completer<void>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    // Only collect kind-1 text notes that directly reply to [eventId]. The
    // REQ filter restricts to kinds:[1], but `rawEvents` is the GLOBAL
    // (un-deduped) stream shared with every subscription — the feed sub
    // requests kind-7 reactions, and a reaction that #e-references this
    // post would otherwise leak in and be rendered as a post.
    if (!isReplyToEvent(e, eventId) || !seen.add(e.id)) return;
    collected.add(e);
  });
  final subId = nextSubId('replies');
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) completer.complete();
  });
  pool.request(subId, <String, dynamic>{
    'kinds': [1],
    '#e': [eventId],
  }, closeOnEose: true);
  ref.onDispose(() {
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  await completer.future.timeout(const Duration(seconds: 10), onTimeout: () {});
  collected.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  // Persist visible thread replies to SQLite (regardless of author) so the
  // user can reply to them later. Fire-and-forget — don't block the list.
  final store = ref.read(eventStoreProvider.notifier);
  for (final e in collected) {
    unawaited(store.cacheThreadEvent(e));
  }
  return collected;
});

/// Follow [pubkey] (NIP-02). Fetches the current user's kind-3 event (to
/// preserve existing entries' relay/petname), signs an updated kind-3 with the
/// new pubkey added, publishes, and refreshes [followingStateProvider].
/// Follow [pubkey] (NIP-02). Uses the LOCALLY CACHED kind-3 (Amethyst pattern)
/// — NOT a relay re-fetch — so that following B after A doesn't wipe A.
/// The cache is populated by [FollowingNotifier] on initial load and updated
/// here after each follow (optimistic update).
Future<RelayOk> followUser(
  WidgetRef ref,
  String pubkey, {
  String? category,
}) async {
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

/// Unfollow [pubkey] (NIP-02). Reads the LOCALLY CACHED kind-3 (same safety as
/// [followUser]), signs an updated kind-3 with the pubkey removed, publishes,
/// and refreshes [followingStateProvider]. Aborts (no-op) if there's no cached
/// kind-3 to read from.
Future<RelayOk> unfollowUser(WidgetRef ref, String pubkey) async {
  final identity = ref.read(identityProvider).value;
  if (identity == null) {
    return const RelayOk('', false, '未登录');
  }
  final current = ref.read(contactListCacheProvider);
  if (current == null) {
    return const RelayOk('', false, '未加载到关注列表，无法取消关注');
  }
  // No-op if not following anyway.
  if (!current.pTagPubkeys.contains(pubkey)) {
    return const RelayOk('', true, '未关注');
  }
  final pool = ref.read(relayPoolProvider);
  final signed = NostrActions(identity).unfollow(current, pubkey);
  final ok = await pool.publishAndWait(signed);
  if (ok.ok) {
    ref.read(contactListCacheProvider.notifier).set(signed);
    ref.invalidate(followingStateProvider);
  }
  return ok;
}

/// updated one with [pubkey] added. Best-effort (category list failure doesn't
/// fail the follow).
Future<void> _addToCategoryList(
  WidgetRef ref,
  Identity identity,
  String pubkey,
  String category,
) async {
  final pool = ref.read(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.kind == 30000 &&
        e.pubkey == identity.pubkeyHex &&
        !completer.isCompleted) {
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
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(subId, <String, dynamic>{
    'authors': [identity.pubkeyHex],
    'kinds': [30000],
    '#d': [category],
    'limit': 1,
  }, closeOnEose: false);
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
  final signed = NostrActions(
    identity,
  ).followCategory(current, pubkey, category);
  await pool.publishAndWait(signed);
  // Optimistic local refresh — don't wait for the relay to round-trip the
  // kind-30000 back; the ingestion listener will bump again when it lands.
  ref.read(kind30000VersionProvider.notifier).bump();
}

/// Bookmark [eventId] (NIP-51 kind-10003). Fetches the current kind-10003 (to
/// preserve existing entries), signs an updated one via NostrActions.bookmark,
/// publishes. [publicList]: public `e` tag (plain) vs private (NIP-44-encrypted
/// to self in content). Same safety as [followUser]: aborts if the current
/// list can't be confirmed (never wipes bookmarks).
Future<RelayOk> bookmarkEvent(
  WidgetRef ref,
  String eventId, {
  required bool publicList,
}) async {
  final identity = ref.read(identityProvider).value;
  if (identity == null) {
    return const RelayOk('', false, '未登录');
  }
  final pool = ref.read(relayPoolProvider);
  final completer = Completer<Event?>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.kind == 10003 &&
        e.pubkey == identity.pubkeyHex &&
        !completer.isCompleted) {
      completer.complete(e);
    }
  });
  final subId = nextSubId('bookmarks');
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(subId, <String, dynamic>{
    'authors': [identity.pubkeyHex],
    'kinds': [10003],
    'limit': 1,
  }, closeOnEose: false);
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
  final signed = NostrActions(
    identity,
  ).bookmark(current, eventId, publicList: publicList);
  return pool.publishAndWait(signed);
}

// --- NSFW settings (local, not synced to relays) ---------------------------

class NsfwSettings {
  const NsfwSettings({
    this.autoReveal = false,
    this.defaultComposeNsfw = false,
  });
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
    NotifierProvider<NsfwSettingsNotifier, NsfwSettings>(
      NsfwSettingsNotifier.new,
    );

// --- Relay status -----------------------------------------------------------

final relayStatusProvider = StreamProvider<List<RelayState>>(
  (ref) => ref.watch(relayPoolProvider).statusStream,
);

// --- User metadata (NIP-01 kind 0) ----------------------------------------

/// Per-pubkey metadata. A **StreamProvider** so it can emit the cached value
/// instantly, then async-refresh from relay when newer metadata arrives —
/// callers (`Avatar`, profile header, …) use `.value` and rebuild on the
/// second emission automatically, so the profile page shows cached data
/// first and updates in place.
///
/// Flow: yield SQLite/in-memory cache (if any) → open a kind-0 REQ → yield
/// any newer event (compares `created_at` to avoid regressing to older
/// metadata) → close on EOSE / timeout. On a cold miss with no relay hit the
/// stream closes after yielding null, so callers see "no metadata" rather
/// than a perpetual spinner.
final metadataProvider = StreamProvider.family<Metadata?, String>((
  ref,
  pubkey,
) async* {
  // 1. SQLite (O(1) PK lookup — fastest, persisted).
  Metadata? cached;
  var cachedCreatedAt = -1;
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    final row = await cache.queryMetadata(pubkey);
    if (row != null) {
      try {
        final json = jsonDecode(row.content);
        if (json is Map<String, dynamic>) {
          cached = Metadata.fromJson(json);
          cachedCreatedAt = row.createdAt;
        }
      } catch (_) {}
    }
  }
  // 2. In-memory EventStore (kind-0 may have arrived via global feed).
  if (cached == null) {
    for (final e in ref.read(eventStoreProvider)) {
      if (e.kind == 0 && e.pubkey == pubkey) {
        try {
          final json = jsonDecode(e.content);
          if (json is Map<String, dynamic>) {
            cached = Metadata.fromJson(json);
            cachedCreatedAt = e.createdAt;
          }
        } catch (_) {}
        break;
      }
    }
  }
  if (cached != null) yield cached;

  // 3. Async refresh from relay (also fills cold misses).
  final pool = ref.read(relayPoolProvider);
  final ctrl = StreamController<Metadata?>();
  late StreamSubscription<Event> sub;
  late StreamSubscription<String> eoseSub;
  var relayHit = false;
  sub = pool.rawEvents.listen((e) {
    if (e.kind != 0 || e.pubkey != pubkey) return;
    try {
      final json = jsonDecode(e.content);
      if (json is! Map<String, dynamic>) return;
      // Don't regress to older metadata.
      if (e.createdAt < cachedCreatedAt) return;
      cachedCreatedAt = e.createdAt;
      relayHit = true;
      ctrl.add(Metadata.fromJson(json));
    } catch (_) {
      // Malformed metadata content — ignore, keep waiting for EOSE.
    }
  });
  final subId = nextSubId('meta');
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [0],
    'limit': 1,
  }, closeOnEose: true);
  void finish() {
    if (ctrl.isClosed) return;
    // Cold miss: resolve to null so callers don't spin forever.
    if (!relayHit && cached == null) ctrl.add(null);
    ctrl.close();
  }

  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) => finish());
  final timer = Timer(const Duration(seconds: 8), finish);
  ref.onDispose(() {
    sub.cancel();
    eoseSub.cancel();
    timer.cancel();
    ctrl.close();
  });
  yield* ctrl.stream;
});

/// Per-pubkey NIP-38 user status (kind 30315, `d`="general") — the short text
/// shown under a user's name in the feed / profile (Amethyst pattern). A
/// StreamProvider so it yields the SQLite-cached value instantly then
/// async-refreshes from relays (like [metadataProvider]). Cached to the
/// replaceable-events table (pubkey+kind+d). Returns null when the user has
/// no status. Editable from the profile page (signs kind 30315 + publishes).
final userStatusProvider = StreamProvider.family<String?, String>((
  ref,
  pubkey,
) async* {
  String? cached;
  var cachedCreatedAt = -1;
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    final row = await cache.queryReplaceable(
      pubkey,
      Event.kindUserStatus,
      dTag: 'general',
    );
    if (row != null) {
      cached = row.content.isEmpty ? null : row.content;
      cachedCreatedAt = row.createdAt;
    }
  }
  if (cached != null) yield cached;

  final pool = ref.read(relayPoolProvider);
  final ctrl = StreamController<String?>();
  late StreamSubscription<Event> sub;
  late StreamSubscription<String> eoseSub;
  var relayHit = false;
  sub = pool.rawEvents.listen((e) {
    if (e.pubkey != pubkey || e.kind != Event.kindUserStatus) return;
    if (e.createdAt < cachedCreatedAt) return;
    // Only the "general" d-tag status.
    final d = e.tags.firstWhere(
      (t) => t.length >= 2 && t[0] == 'd' && t[1] is String,
      orElse: () => const ['d', ''],
    );
    if ((d[1] as String) != 'general') return;
    cachedCreatedAt = e.createdAt;
    relayHit = true;
    final text = e.content.isEmpty ? null : e.content;
    final db = ref.read(localCacheProvider).value;
    if (db != null) {
      unawaited(
        db.writeEvent(
          id: e.id,
          pubkey: e.pubkey,
          kind: e.kind,
          createdAt: e.createdAt,
          content: e.content,
          sig: e.sig,
          raw: jsonEncode(e.toWireObject()),
          tagsJson: jsonEncode(e.tags),
          tags: e.tags,
        ),
      );
    }
    ctrl.add(text);
  });
  final subId = nextSubId('status');
  pool.request(
    subId,
    <String, dynamic>{
      'authors': [pubkey],
      'kinds': [Event.kindUserStatus],
      '#d': ['general'],
      'limit': 1,
    },
    closeOnEose: true,
  );
  void finish() {
    if (ctrl.isClosed) return;
    if (!relayHit && cached == null) ctrl.add(null);
    ctrl.close();
  }

  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) => finish());
  final timer = Timer(const Duration(seconds: 8), finish);
  ref.onDispose(() {
    sub.cancel();
    eoseSub.cancel();
    timer.cancel();
    ctrl.close();
  });
  yield* ctrl.stream;
});

/// Bulk-prefetch profile metadata (kind 0) for the whole social graph
/// (follows + followers + self) so avatars/profiles resolve instantly on
/// first paint. One REQ per ~200-author chunk (relay author-list limit).
/// Received kind-0 events flow through [pool.rawEvents] →
/// [EventStoreNotifier._persist] (kind 0 is always cached to SQLite) and warm
/// each per-pubkey [metadataProvider] via its tier-1/tier-2 lookup.
final socialGraphMetadataPrefetchProvider = FutureProvider<void>((ref) async {
  final id = ref.watch(identityProvider).value;
  if (id == null) return;
  // Ensure followers have been merged into the graph before bulk-fetching.
  await ref
      .watch(userFollowersProvider(id.pubkeyHex).future)
      .catchError((_) => <String>[]);
  final graph = ref.read(socialGraphProvider);
  if (graph.isEmpty) return;
  final pool = ref.read(relayPoolProvider);
  const chunkSize = 200;
  final pubkeys = graph.toList();
  final subIds = <String>[];
  for (var i = 0; i < pubkeys.length; i += chunkSize) {
    final end = (i + chunkSize).clamp(0, pubkeys.length);
    final subId = nextSubId('meta-bulk');
    subIds.add(subId);
    pool.request(subId, <String, dynamic>{
      'authors': pubkeys.sublist(i, end),
      'kinds': [0],
    }, closeOnEose: true);
  }
  ref.onDispose(() {
    for (final s in subIds) {
      pool.closeSubscription(s);
    }
  });
});

// --- NIP-05 verification ----------------------------------------------------

/// Outcome of verifying a user's NIP-05 identifier against its domain's
/// `.well-known/nostr.json` endpoint.
enum Nip05Status {
  /// The pubkey has no nip05 field — nothing to badge.
  none,

  /// The domain's nostr.json maps the local-part to this pubkey. Verified ✓.
  verified,

  /// The domain responded but does NOT map the local-part to this pubkey
  /// (or the response was malformed) — the handle is a claim that doesn't
  /// hold up. Show a different marker than verified.
  failed,

  /// Couldn't reach the domain (network error / timeout) — verification
  /// inconclusive. Treat like `failed` visually (not confirmed).
  unknown,
}

/// Verifies a NIP-05 identifier against a domain's nostr.json. Pure function
/// (takes a [fetch] callback returning the decoded JSON or throwing) so it
/// can be unit-tested with a fake fetcher. Public for testing.
@visibleForTesting
Future<Nip05Status> verifyNip05(
  String nip05,
  String pubkey,
  Future<Object?> Function(Uri) fetch,
) async {
  if (nip05.isEmpty) return Nip05Status.none;
  final at = nip05.lastIndexOf('@');
  if (at <= 0 || at >= nip05.length - 1) {
    return Nip05Status.failed; // malformed — no domain
  }
  final local = nip05.substring(0, at);
  final domain = nip05.substring(at + 1);
  try {
    final decoded = await fetch(
      Uri.parse('https://$domain/.well-known/nostr.json?name=$local'),
    );
    if (decoded is! Map<String, dynamic>) return Nip05Status.failed;
    final names = decoded['names'];
    String? claimed;
    if (names is Map<String, dynamic>) {
      claimed = names[local]?.toString();
    }
    // "_" local-part conventionally refers to the domain owner, which may be
    // declared via the root `pubkey` field.
    if (claimed == null && local == '_') {
      claimed = decoded['pubkey']?.toString();
    }
    final pk = pubkey.toLowerCase();
    if (claimed != null && claimed.toLowerCase() == pk) {
      return Nip05Status.verified;
    }
    return Nip05Status.failed;
  } catch (_) {
    return Nip05Status.unknown;
  }
}

/// Verifies a user's NIP-05 identifier. Fetches
/// `https://<domain>/.well-known/nostr.json?name=<localpart>` and checks the
/// `names` map (or the root `pubkey` field when the local-part is `_`) maps
/// to [pubkey]. Cached per pubkey for the session (FutureProvider.family).
///
/// NIP-05: https://github.com/nostr-protocol/nips/blob/master/05.md
final nip05VerifiedProvider = FutureProvider.family<Nip05Status, String>((
  ref,
  pubkey,
) async {
  final meta = await ref.watch(metadataProvider(pubkey).future);
  final nip05 = meta?.nip05 ?? '';
  return verifyNip05(nip05, pubkey, (uri) async {
    final res = await http
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception('status ${res.statusCode}');
    }
    return jsonDecode(res.body);
  });
});

/// ChangeNotifier bridge so GoRouter re-evaluates redirects on login/logout.
class GoRouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
