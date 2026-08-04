/// App-wide riverpod providers: identity, relay pool, bootstrap, event store,
/// feed mode, following (NIP-02), feed subscription lifecycle, relay status.
///
/// Notifier/AsyncNotifier usage follows riverpod 3. Non-autoDispose for the
/// long-lived relay pool + event store so they survive navigation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/bookmark_entry.dart';
import '../models/event.dart';
import '../models/metadata.dart';
import '../models/mute_set.dart';
import '../utils/nip19.dart';
import '../nostr/actions.dart';
import '../nostr/event_store.dart';
import '../nostr/identity.dart';
import '../nostr/outbox_router.dart';
import '../nostr/relay_client.dart';
import '../nostr/relay_pool.dart';
import '../services/local_cache.dart' as cache;
import '../services/blossom_upload.dart';
import '../services/secure_storage_service.dart';
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
  'wss://wheat.happytavern.co/',
  'wss://relay.nostr.net/',
  'wss://relay.0xchat.com/',
  'wss://top.testrelay.top/',
];

/// Order-insensitive equality of two relay-URL lists (compares as sets so a
/// re-order in [defaultRelays] doesn't trigger a needless re-seed).
bool _sameRelaySet(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  final sa = a.map((u) => u.trim()).where((u) => u.isNotEmpty).toSet();
  final sb = b.map((u) => u.trim()).where((u) => u.isNotEmpty).toSet();
  return sa.length == sb.length && sa.containsAll(sb);
}

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

/// Indexer relays: relays that aggregate ALL users' kind-0 metadata (and
/// kind-3 / kind-10002). Used as the cold-miss fallback when a user's
/// metadata isn't on any default relay — they recover the "unknown user shows
/// no name" gap (Amethyst's "widen to indexers when outbox/connected relays
/// are exhausted" pattern; see `filterUserMetadataForKey` / PR #3055).
const List<String> indexerRelays = <String>[
  'wss://indexer.coracle.social/',
  'wss://user.kindpag.es/',
];

// --- Local cache (drift/SQLite) — provider ---

/// Open (and validate) the local cache at [dbPath], quarantining a broken
/// file instead of letting it wedge startup.
///
/// Why the probe: the DB file SURVIVES an overlay upgrade (覆盖升级). A file
/// carried over from an older build can fail to open — corrupt page, broken
/// FTS index, stale WAL — and because drift opens lazily on the first query,
/// that failure surfaces at startup: the first query hangs or throws and the
/// app sits on the splash screen forever ("覆盖升级后打开就卡死，卸载重装才好"
/// bug — uninstall "fixed" it only because it deleted this file). Guard the
/// first query with a timeout; on ANY failure rename the broken file aside
/// (kept on disk for diagnosis) and open a fresh cache — the same outcome as
/// uninstall+reinstall, without losing the login or waiting on a hang.
@visibleForTesting
Future<cache.LocalCache> openLocalCache(String dbPath) async {
  var db = cache.LocalCache.open(dbPath);
  try {
    await db
        .customSelect('SELECT 1 AS ok')
        .getSingle()
        .timeout(const Duration(seconds: 10));
    return db;
  } catch (_) {
    try {
      await db.close().timeout(const Duration(seconds: 3));
    } catch (_) {
      // The background isolate may itself be wedged — leak it; the file is
      // about to be renamed out from under it anyway.
    }
    // Keep at most ONE quarantined backup: delete any stale `*.corrupt-*`
    // files left by earlier failures so repeated corruption can't pile them
    // up forever (only the freshest is kept for diagnosis). Normal launches
    // never reach here, so in practice there is no accumulation at all.
    final dbFile = File(dbPath);
    final base = p.basename(dbPath);
    try {
      await for (final ent in dbFile.parent.list()) {
        if (p.basename(ent.path).startsWith('$base.corrupt-')) {
          try {
            await ent.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (await f.exists()) {
        try {
          await f.rename('$dbPath.corrupt-$stamp$suffix');
        } catch (_) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    }
    return cache.LocalCache.open(dbPath);
  }
}

/// Delete the local SQLite cache files (costr.db + WAL/SHM sidecars). The
/// startup error screen's 「重置本地缓存」 escape hatch when an inherited DB
/// wedges bootstrap even past the [openLocalCache] probe.
Future<void> resetLocalCacheFiles() async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final dbPath = p.join(dir.path, 'costr.db');
    for (final suffix in const ['', '-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (await f.exists()) await f.delete();
    }
  } catch (_) {}
}

final localCacheProvider = FutureProvider<cache.LocalCache>((ref) async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'costr.db');
  final db = await openLocalCache(dbPath);
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
  // The relay set is app-controlled (the defaultRelays const), not user-
  // editable (the settings page is read-only). So when the const changes
  // (an app UPDATE ships a different relay list), re-seed the persisted copy
  // from the const — otherwise a non-uninstall update would keep showing the
  // OLD relays in the settings page (and the connected pool, which is built
  // from the const directly, would diverge from what the page shows).
  if (relays == null ||
      relays.isEmpty ||
      !_sameRelaySet(relays, defaultRelays)) {
    relays = defaultRelays;
    await db.writeServerList('relay_list', relays);
  }
  var blossom = await db.readServerList('blossom_list');
  if (blossom == null ||
      blossom.isEmpty ||
      !_sameRelaySet(blossom, blossomServersConst)) {
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
    'kinds': [
      0,
      1,
      6,
      7,
    ], // metadata + text notes + reposts + reactions (Amethyst pattern)
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
      final marker = (t.length >= 3 && t[2] is String)
          ? (t[2] as String).trim()
          : '';
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

/// Best-effort single relay hint for [pubkey], read SYNCHRONOUSLY from its
/// cached NIP-65 relay list (the 5-min memory TTL, else the SQLite cold-start
/// hydrate that [userRelayListProvider] does on first read). Prefers a write
/// relay (where the author publishes) over a read relay. Returns null when no
/// list is cached yet — callers fall back to an empty relay field (Amethyst's
/// own fallback shape). Deliberately synchronous: repost/reply/quote/reaction
/// are interactive actions and must not block on a network relay-list fetch.
String? relayHintFor(WidgetRef ref, String pubkey) {
  final rl = ref.read(userRelayListProvider(pubkey)).value;
  if (rl == null) return null;
  if (rl.write.isNotEmpty) return rl.write.first;
  if (rl.read.isNotEmpty) return rl.read.first;
  return null;
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

/// A separate, isolated, lazily-connected pool for the [indexerRelays].
/// Queried CONCURRENTLY with the default pool for kind-0 metadata cold
/// misses (see [metadataProvider]) so unknown users resolve fast — the first
/// pool to answer wins, a slow/stuck multiplexer in the default pool can't
/// block the indexer's response. Kept separate from [relayPoolProvider] so
/// the global feed's kind-1 traffic never reaches the indexers (they only
/// serve metadata) and the indexers' traffic never mixes into the feed.
final indexerPoolProvider = Provider<RelayPool>((ref) {
  final pool = RelayPool.fromUrls(indexerRelays);
  pool.identityGetter = () => ref.read(identityProvider).value;
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
  // Cold-start hydrate from SQLite (instant) — kind-10002 is persisted by
  // EventStoreNotifier's main listener, so a relaunch returns the user's
  // relay list without waiting for the relay REQ. The 5-min memory TTL above
  // handles warm restarts; this handles cold restarts (memory cache lost).
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    try {
      final row = await cache.queryReplaceable(pubkey, 10002);
      if (row != null) {
        final list = RelayList.parse(_replaceableToEvent(row));
        if (list != null) {
          _relayListCache[pubkey] = _CachedRelayList(list, DateTime.now());
          return list;
        }
      }
    } catch (_) {}
  }
  final pool = ref.watch(relayPoolProvider);
  // ALSO query the indexer pool concurrently. The default pool only sees a
  // kind-10002 that happens to live on the user's connected relays; indexers
  // (coracle / kindpag.es) aggregate user profile-ish events broadly, so a
  // user whose relay list isn't on any connected relay but IS indexed is
  // recovered here. Without this, the metadata outbox fallback (which calls
  // this provider) gives up on such users and their profile/avatar never
  // loads. First match or first EOSE (whichever pool) wins.
  final indexerPool = ref.read(indexerPoolProvider);
  final completer = Completer<void>();
  Event? newest;
  final seen = <String>{};
  var eosesRemaining = 2; // default pool + indexer pool
  void onListEvent(Event e) {
    if (e.pubkey != pubkey || e.kind != 10002) return;
    if (!seen.add(e.id)) return;
    if (newest == null || e.createdAt > newest!.createdAt) {
      newest = e;
    }
    // Got the user's relay list — resolve immediately rather than waiting
    // for EOSE. (Amethyst streams; we snapshot the newest seen so far.) A
    // stale version on a fast relay is rare and is covered by the broadcast
    // fallback in [userPostsProvider].
    if (!completer.isCompleted) completer.complete();
  }

  // Resolve on the FIRST kind-10002 event (above) OR once BOTH pools have
  // EOSEd — NOT after just one. Waiting for only one pool's EOSE would let a
  // slow/dead pool stall the lookup; racing both and completing on first hit
  // / both-done keeps it fast. [userPostsProvider] blocks on this future, so
  // the 5s timeout is the hard cap.
  void onEose() {
    if (--eosesRemaining <= 0 && !completer.isCompleted) {
      completer.complete();
    }
  }

  late StreamSubscription<Event> defSub, idxSub;
  late StreamSubscription<String> defEose, idxEose;
  defSub = pool.rawEvents.listen(onListEvent);
  final defId = nextSubId('rl');
  defEose = pool.eoseStream.where((s) => s == defId).listen((_) => onEose());
  pool.request(defId, <String, dynamic>{
    'kinds': [10002],
    'authors': [pubkey],
    'limit': 1,
  }, closeOnEose: true);

  idxSub = indexerPool.rawEvents.listen(onListEvent);
  final idxId = nextSubId('rlidx');
  idxEose = indexerPool.eoseStream
      .where((s) => s == idxId)
      .listen((_) => onEose());
  indexerPool.request(idxId, <String, dynamic>{
    'kinds': [10002],
    'authors': [pubkey],
    'limit': 1,
  }, closeOnEose: true);

  ref.onDispose(() {
    defSub.cancel();
    idxSub.cancel();
    defEose.cancel();
    idxEose.cancel();
    pool.closeSubscription(defId);
    indexerPool.closeSubscription(idxId);
  });
  await completer.future.timeout(const Duration(seconds: 5), onTimeout: () {});
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
  try {
    await _runBootstrap(ref).timeout(const Duration(seconds: 30));
  } on TimeoutException {
    // Watchdog: identity read (keystore) and relay connect are individually
    // timeout-guarded, but if startup still wedges for ANY reason the app
    // must not sit on the splash spinner forever — surface an error state
    // with retry / 「重置本地缓存」 escape hatches instead (the permanent-
    // splash half of the overlay-upgrade freeze report).
    throw StateError('启动超时：本地缓存或中继连接卡住。请先重试；若仍失败，点「重置本地缓存并重试」。');
  }
});

Future<void> _runBootstrap(Ref ref) async {
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
  // Cache cleanup 30s after startup (avoids startup jank). Own posts are
  // exempt from the TTL (see cleanupOldEvents): they're notification targets.
  Timer(const Duration(seconds: 30), () async {
    final cache = ref.read(localCacheProvider).value;
    if (cache == null) return;
    try {
      final me = ref.read(identityProvider).value?.pubkeyHex;
      await cache.cleanupOldEvents(ttlDays: 30, ownPubkey: me);
      await cache.enforceSizeCap();
      await cache.vacuum();
    } catch (_) {}
  });
}

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
      final ev = Event.fromJson(jsonDecode(rawJson) as Map<String, dynamic>);
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
  bool _disposed = false;
  cache.LocalCache? _cache;

  @override
  List<Event> build() {
    // Hydrate from SQLite (async — fills store as data arrives).
    _hydrate();
    final pool = ref.watch(relayPoolProvider);
    _sub = pool.events.listen((e) {
      // Immutable feed events (kind 0/1/6/7) → in-memory store + persist
      // (social-graph gated for kind 1/7 inside _persist).
      if (e.kind == 0 || e.isTextNote || e.isRepost || e.kind == 7) {
        if (_store.add(e)) {
          _persist(e);
          _scheduleFlush();
        }
      } else if (_isReplaceableKind(e.kind)) {
        // Replaceable kinds (kind 3 / 10002 / 30000 / 10003 / 30315 / 10063 …)
        // — small, PK-deduped, ALWAYS persisted per CACHE_DESIGN §4 (no
        // social-graph gate). Not held in the feed-only EventStore; downstream
        // providers (follows/groups/bookmarks/relay-list) read them from
        // SQLite directly. Catches kind-3/30000 from the follow providers'
        // targeted REQs too, since they flow through this merged stream.
        final writeFuture = _persist(e);
        // Reactive refresh for the logged-in user's own lists. Read identity
        // per-event (may resolve late). kind-3 sets an in-memory cache from
        // the event itself (no SQLite read) → safe to do now. kind-30000's
        // bump triggers a SQLite re-read of the follow-set rows, so it MUST
        // wait until the background-isolate write lands — otherwise the
        // rebuilt snapshot races the write and stays empty for the session.
        final me = ref.read(identityProvider).value?.pubkeyHex;
        if (e.pubkey == me) {
          if (e.kind == 30000) {
            writeFuture.then((_) {
              if (!_disposed) {
                ref.read(kind30000VersionProvider.notifier).bump();
              }
            });
          } else if (e.kind == 3) {
            // Own contact list changed → refresh the in-memory cache that
            // FollowingNotifier / buildFeedFilter read from.
            ref.read(contactListCacheProvider.notifier).set(e);
          }
        }
      } else if (e.kind == 5) {
        // NIP-09 deletion (kind 5): honor `a` tags (replaceable coordinate
        // delete) + `e` tags (event id delete) ONLY when the deletion's author
        // matches the deleted event's author (you can only delete your own).
        // Best-effort — not all relays honor deletions, and cached rows may
        // linger, but this clears the local SQLite cache + live store when a
        // deletion arrives (e.g. a kind-30000 follow set you deleted from
        // another client, whose row would otherwise persist in cache).
        unawaited(_applyDeletion(e));
      }
    });
    ref.onDispose(() {
      _disposed = true;
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
      final isReplaceable = _isReplaceableKind(e.kind);
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
  /// [RelayPool.fetchFromUrls] (NIP-65 outbox routing) and [OutboxRouter]
  /// (following-feed outbox routing): those events bypass the pool's merged
  /// stream, so the normal [pool.events] listener never sees them — ingest
  /// them here so the rest of the app (feed, detail pages, replies) finds
  /// them, and persist so a later visit is instant. Persists regardless of
  /// social-graph membership, like [cacheThreadEvent] (the user opened the
  /// profile / follows the author, so cache its posts).
  ///
  /// Throttled via [_scheduleFlush] (200ms) instead of emitting `state`
  /// synchronously: the following feed can burst hundreds of outbox events on
  /// load/refresh, and a per-event rebuild would jank the ListView. The main
  /// pool listener already throttles the same way; ingest now matches it.
  Future<void> ingest(Event e) async {
    if (_store.add(e)) {
      _scheduleFlush();
      unawaited(cacheThreadEvent(e));
    }
  }

  /// Remove an event from the in-memory store + SQLite (after a NIP-09 kind-5
  /// deletion). The feed (which watches [eventStoreProvider]) re-renders
  /// without the deleted post.
  Future<void> removeEvent(String id) async {
    if (_store.remove(id)) {
      state = _store.events;
    }
    final db = _cache;
    if (db != null) {
      try {
        await db.deleteEvent(id);
      } catch (_) {}
    }
  }

  /// Apply a NIP-09 kind-5 deletion: clear `a`-coordinate replaceable rows +
  /// `e`-id events from the local cache + live store, but only when the
  /// deletion's author owns what it deletes (you can only delete your own).
  /// Best-effort — relays additionally stop serving the deleted event.
  Future<void> _applyDeletion(Event del) async {
    final db = _cache;
    final me = ref.read(identityProvider).value?.pubkeyHex;
    for (final t in del.tags) {
      if (t.length < 2 || t[0] is! String) continue;
      final tagName = t[0] as String;
      if (tagName == 'a' && t[1] is String) {
        // a-tag = "<kind>:<pubkey>:<d>" (NIP-33 coordinate).
        final parts = (t[1] as String).split(':');
        if (parts.length < 3) continue;
        final kind = int.tryParse(parts[0]);
        final owner = parts[1];
        final d = parts.sublist(2).join(':'); // d may technically contain ':'
        if (kind == null || owner != del.pubkey) continue; // not the author's
        if (db != null) {
          try {
            await db.deleteReplaceableByCoord(owner, kind, d);
          } catch (_) {}
        }
        // Reactive refresh for the logged-in user's own lists.
        if (owner == me && !_disposed) {
          if (kind == 30000) {
            ref.read(kind30000VersionProvider.notifier).bump();
          } else if (kind == 10002) {
            _relayListCache.remove(owner); // evict stale relay-list cache
          }
        }
      } else if (tagName == 'e' && t[1] is String) {
        // e-tag = event id to delete. Validate authorship via the live store
        // (events only held in SQLite but not in memory are dropped on the
        // next relay fetch anyway, since relays stop serving deleted events).
        final id = t[1] as String;
        final existing = _store.byId(id);
        if (existing != null && existing.pubkey == del.pubkey) {
          await removeEvent(id);
        }
      }
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

/// Top-level helper: convert a drift ReplaceableEvent (kind 0/3/10000+/
/// 30000+ row from the replaceable_events table) to our Event model.
Event _replaceableToEvent(cache.ReplaceableEvent row) => Event(
  id: row.id,
  pubkey: row.pubkey,
  createdAt: row.createdAt,
  kind: row.kind,
  tags: (jsonDecode(row.tagsJson) as List).cast<List<dynamic>>(),
  content: row.content,
  sig: row.sig,
);

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

// --- Proxy media (LOCAL-only toggle; never published to a relay) ---------

/// Whether the per-post "代理媒体" affordance is shown at all. This is a
/// client-side fetch preference (how Costr retrieves media), NOT part of the
/// user's Nostr identity, so it lives in the LOCAL SQLite config table and is
/// never signed/published.
///
/// When ON: every post that contains image/video links shows a compact
/// "代理媒体" toggle to the right of the nickname; tapping it routes THAT
/// post's media through `proxy.bostr.online` (forceProxy). When OFF: the
/// toggle never appears — media loads from origin only, and failures show
/// the error placeholder fast (the timed FileService caps fetches at 8s).
final savedProxyMediaProvider = FutureProvider<bool>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  return (await cache.readConfig('proxy_media')) == 'true';
});

class ProxyMediaNotifier extends Notifier<bool> {
  @override
  bool build() {
    // Default OFF until the persisted value loads; rebuilds to the saved
    // choice once [savedProxyMediaProvider] resolves.
    return ref.watch(savedProxyMediaProvider).value ?? false;
  }

  Future<void> set(bool v) async {
    if (v == state) return;
    state = v;
    final cache = await ref.read(localCacheProvider.future);
    await cache.writeConfig('proxy_media', v ? 'true' : 'false');
  }
}

final proxyMediaEnabledProvider =
    NotifierProvider<ProxyMediaNotifier, bool>(ProxyMediaNotifier.new);

// --- Immersive browse (LOCAL-only toggle; never published to a relay) ------

/// Whether the immersive-browsing feature is on (hide the top app bar + bottom
/// nav + FAB when the user scrolls DOWN, restore on scroll UP — Amethyst
/// pattern). LOCAL client preference, NOT part of the Nostr identity → stored
/// in the SQLite config table, never signed/published. Default OFF so the
/// chrome stays put until the user opts in.
final savedImmersiveBrowseProvider = FutureProvider<bool>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  return (await cache.readConfig('immersive_browse')) == 'true';
});

class ImmersiveBrowseNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(savedImmersiveBrowseProvider).value ?? false;

  Future<void> set(bool v) async {
    if (v == state) return;
    state = v;
    final cache = await ref.read(localCacheProvider.future);
    await cache.writeConfig('immersive_browse', v ? 'true' : 'false');
  }
}

final immersiveBrowseProvider =
    NotifierProvider<ImmersiveBrowseNotifier, bool>(ImmersiveBrowseNotifier.new);

/// Global "are the app bars currently visible" state. Scrolled surfaces
/// ([ImmersiveScrollDetector]) drive this DOWN when the user scrolls toward
/// the bottom and UP back to true. Only consulted when
/// [immersiveBrowseProvider] is on; when the toggle is off the bars never
/// hide (each consumer ANDs with the toggle), so default-true is a safe
/// no-op.
class AppBarsVisibleNotifier extends Notifier<bool> {
  @override
  bool build() => true;

  void setVisible(bool v) {
    if (v == state) return;
    state = v;
  }
}

final appBarsVisibleProvider =
    NotifierProvider<AppBarsVisibleNotifier, bool>(AppBarsVisibleNotifier.new);

// --- Text scale (global font size) -----------------------------------------

/// Three discrete global font sizes (设置 → 字号). Each step scales text by
/// 20% multiplicatively: 默认 1.0× → 大 1.2× → 较大 1.44×. Persisted to the
/// config table (`text_scale`) so the choice survives relaunch. Applied app-
/// wide via `MediaQuery.textScaler` in `MaterialApp.router` (app.dart).
enum TextScaleLevel { normal, large, larger }

extension TextScaleLevelFactor on TextScaleLevel {
  double get factor {
    switch (this) {
      case TextScaleLevel.normal:
        return 1.0;
      case TextScaleLevel.large:
        return 1.2;
      case TextScaleLevel.larger:
        return 1.44;
    }
  }

  String get label {
    switch (this) {
      case TextScaleLevel.normal:
        return '默认';
      case TextScaleLevel.large:
        return '大';
      case TextScaleLevel.larger:
        return '较大';
    }
  }
}

final savedTextScaleProvider = FutureProvider<TextScaleLevel>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  final raw = await cache.readConfig('text_scale');
  switch (raw) {
    case 'large':
      return TextScaleLevel.large;
    case 'larger':
      return TextScaleLevel.larger;
    default:
      return TextScaleLevel.normal;
  }
});

class TextScaleNotifier extends Notifier<TextScaleLevel> {
  @override
  TextScaleLevel build() {
    // Default to 默认 until the persisted value loads; rebuilds (snapping to
    // the saved level) once [savedTextScaleProvider] resolves.
    return ref.watch(savedTextScaleProvider).value ?? TextScaleLevel.normal;
  }

  void set(TextScaleLevel level) {
    if (level == state) return;
    state = level;
    final value = switch (level) {
      TextScaleLevel.normal => 'normal',
      TextScaleLevel.large => 'large',
      TextScaleLevel.larger => 'larger',
    };
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('text_scale', value));
  }
}

final textScaleProvider = NotifierProvider<TextScaleNotifier, TextScaleLevel>(
  TextScaleNotifier.new,
);

/// Derived double factor for convenience (1.0 / 1.2 / 1.44).
final textScaleFactorProvider = Provider<double>(
  (ref) => ref.watch(textScaleProvider).factor,
);

/// Filter applied to the 关注 feed (following mode only): `null` = 全部关注;
/// `group:<name>` = only posts from authors in that NIP-51 kind-30000 custom
/// group; `tag:<tag>` = only posts carrying that hashtag. Persisted to config
/// (`following_filter`) so a relaunch keeps the last selection (DESIGN §8
/// follow-list feed switcher, Amethyst PeopleList). Client-side filtering on
/// the already-loaded following feed — no extra relay REQ, instant, robust
/// against relays that don't support `#t`.
final savedFollowingFilterProvider = FutureProvider<String?>((ref) async {
  final cache = await ref.read(localCacheProvider.future);
  final v = await cache.readConfig('following_filter');
  return (v == null || v.isEmpty) ? null : v;
});

class FollowingFilterNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Default to 全部关注 until the persisted value loads; rebuilds (snapping
    // to the saved filter) once [savedFollowingFilterProvider] resolves.
    return ref.watch(savedFollowingFilterProvider).value;
  }

  void set(String? value) {
    final v = (value == null || value.isEmpty) ? null : value;
    if (v == state) return;
    state = v;
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('following_filter', v ?? ''));
  }
}

final followingFilterProvider =
    NotifierProvider<FollowingFilterNotifier, String?>(
      FollowingFilterNotifier.new,
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
/// kind-30015 Interests events (`t` tags = followed hashtags), published to
/// relays. Amethyst publishes hashtags across multiple kind-30015 sets — a
/// default list (d "") plus named sets (d != "") — so Costr UNIONS the `t`
/// tags of ALL the user's kind-30015 events (interop parity with Amethyst).
/// Writes (add/remove) target the default set (d "") so Costr's own follows
/// land in one place. A local SQLite copy hydrates instantly on cold start
/// before the relay responds.
class FollowedTagsNotifier extends AsyncNotifier<List<String>> {
  StreamSubscription<Event>? _sub;
  StreamSubscription<String>? _eoseSub;

  /// Newest kind-10015 Interests event — the user's followed-hashtags list.
  /// Amethyst stores the `t` tags in its NIP-44-encrypted `.content`
  /// (private list, owner-only). This is the WRITE target for add/remove.
  Event? _k10015;

  /// Last-known NAMED kind-30015 interest sets (plain `t` tags, public),
  /// keyed by d. Read-only union — surfaces public interest sets published
  /// by other clients. Kept across the session so an optimistic add/remove
  /// on the kind-10015 preserves their tags until the next refresh.
  final Map<String, Event> _namedSets = {};

  NostrActions? _actions; // set in build() once identity resolves

  @override
  Future<List<String>> build() async {
    final identity = await ref.watch(identityProvider.future);
    if (identity == null) return const <String>[];
    _actions = NostrActions(identity);
    final pubkey = identity.pubkeyHex;
    final cache = await ref.read(localCacheProvider.future);
    _namedSets.clear();
    _k10015 = null;

    // 1. Hydrate from SQLite (instant cold-start): kind-10015 (newest) +
    //    all kind-30015 (newest per d).
    try {
      final rows10015 = await cache.queryReplaceableByAuthor(pubkey, 10015);
      for (final row in rows10015) {
        final e = _replaceableToEvent(row);
        if (_k10015 == null || e.createdAt > _k10015!.createdAt) _k10015 = e;
      }
      final rows30015 = await cache.queryReplaceableByAuthor(pubkey, 30015);
      for (final row in rows30015) {
        final e = _replaceableToEvent(row);
        final d = dOf(e);
        final prev = _namedSets[d];
        if (prev == null || e.createdAt > prev.createdAt) _namedSets[d] = e;
      }
    } catch (_) {}
    if (_k10015 != null) {
      ref.read(followedTagsCacheProvider.notifier).set(_k10015);
    }
    final cachedUnion = _unionAll(_k10015);

    // 2. Fetch from relays: kinds [10015, 30015] (Amethyst's followed
    //    hashtags live in the kind-10015; kind-30015 covers other clients'
    //    public interest sets).
    final pool = ref.read(relayPoolProvider);
    Event? net10015 = _k10015;
    final net30015 = <String, Event>{}; // d -> newest
    _sub = pool.rawEvents.listen((e) {
      if (e.pubkey != pubkey) return;
      if (e.kind == 10015) {
        if (net10015 == null || e.createdAt > net10015!.createdAt) net10015 = e;
      } else if (e.kind == 30015) {
        final d = dOf(e);
        final prev = net30015[d];
        if (prev == null || e.createdAt > prev.createdAt) net30015[d] = e;
      }
    });
    final subId = nextSubId('interests');
    final connectedCount = pool.states
        .where((s) => s.status == RelayStatus.connected)
        .length;
    var eoses = 0;
    final completer = Completer<void>();
    _eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
      eoses++;
      if (eoses >= connectedCount && !completer.isCompleted) {
        completer.complete();
      }
    });
    pool.request(subId, <String, dynamic>{
      'authors': [pubkey],
      'kinds': [10015, 30015],
      'limit': 50,
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

    // 3. Merge relay results: persist + refresh caches (newest per kind/d).
    if (net10015 != null &&
        (_k10015 == null || net10015!.createdAt > _k10015!.createdAt)) {
      await _persist(cache, net10015!);
      _k10015 = net10015;
      ref.read(followedTagsCacheProvider.notifier).set(_k10015);
    }
    if (net30015.isNotEmpty) {
      for (final e in net30015.values) {
        await _persist(cache, e);
        final d = dOf(e);
        final prev = _namedSets[d];
        if (prev == null || e.createdAt > prev.createdAt) _namedSets[d] = e;
      }
    }
    final union = _unionAll(_k10015);
    // Prefer the fresh union; fall back to the cached union only if the relay
    // pass returned nothing new at all (e.g. all relays offline).
    return union.isEmpty ? cachedUnion : union;
  }

  /// The `d` tag value ("" if absent) — identity key for a kind-30015 set.
  static String dOf(Event e) {
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) return t[1] as String;
    }
    return '';
  }

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

  /// Union: decrypted followed hashtags from the kind-10015 (owner-only —
  /// Amethyst stores them NIP-44-encrypted in `.content`) + plain `t` tags
  /// from all kind-30015 named interest sets (other clients' public sets).
  /// Deduped, lowercased.
  List<String> _unionAll(Event? k10015) {
    final out = <String>[];
    final seen = <String>{};
    for (final t in _actions?.followedHashtagTags(k10015) ?? const <String>[]) {
      if (seen.add(t)) out.add(t);
    }
    for (final e in _namedSets.values) {
      for (final t in _tagsOf(e)) {
        if (seen.add(t)) out.add(t);
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
    final actions = _actions ?? NostrActions(identity);
    final current = ref.read(followedTagsCacheProvider); // kind-10015
    // Write to kind-10015 (NIP-44-encrypted content) — Amethyst-compatible.
    final signed = actions.followedHashtags(current, add: add, remove: remove);
    // Optimistic update so the UI reflects the change immediately. Recompute
    // the union with the new kind-10015 + unchanged named 30015 sets.
    state = AsyncData(_unionAll(signed));
    ref.read(followedTagsCacheProvider.notifier).set(signed);

    final pool = ref.read(relayPoolProvider);
    final ok = await pool.publishAndWait(signed);
    if (ok.ok) {
      final cache = await ref.read(localCacheProvider.future);
      await _persist(cache, signed);
      _k10015 = signed;
      return true;
    }
    // Revert on failure.
    state = AsyncData(_unionAll(current));
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
    final pubkey = identity.pubkeyHex;
    final subId = nextSubId('kind3');

    // 1. Hydrate the in-memory contact-list cache. Prefer whichever source is
    //    newest — the in-memory cache (just updated by followUser/
    //    unfollowUser, or by the ingestion listener) or SQLite (cold start,
    //    or a relay refresh that landed while we weren't built). Without this
    //    guard, a rebuild triggered right after followUser reads a STALE
    //    SQLite row (the background-isolate write from EventStoreNotifier.
    //    _persist is still in flight) and clobbers the freshly-signed kind-3
    //    → followingStateProvider returns the OLD follows → the follow
    //    button flips back to "关注" until the relay echoes, looking like the
    //    follow failed entirely.
    final cached = await _newestContactList(pubkey);
    if (cached != null) ref.read(contactListCacheProvider.notifier).set(cached);
    // 2. Background relay refresh — live-update state when a newer kind-3
    //    lands (don't regress to an older one). Completer kept for the
    //    no-cache cold path so the AsyncNotifier resolves instead of hanging.
    final completer = Completer<List<String>>();
    _sub = pool.rawEvents.listen((e) {
      if (!e.isContactList || e.pubkey != pubkey) return;
      final prev = ref.read(contactListCacheProvider);
      if (prev != null && e.createdAt <= prev.createdAt) return;
      ref.read(contactListCacheProvider.notifier).set(e);
      if (!completer.isCompleted) completer.complete(e.pTagPubkeys);
      state = AsyncData(e.pTagPubkeys);
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

    // Cached → return now; the listener above live-updates on a newer kind-3.
    // No cache → wait for the relay (10s timeout → whatever's in the memory
    // cache, or empty).
    if (cached != null) return cached.pTagPubkeys;
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () =>
          ref.read(contactListCacheProvider)?.pTagPubkeys ?? const <String>[],
    );
  }

  /// Resolve the newest known kind-3 (contact list) for [pubkey]: in-memory
  /// cache vs SQLite. Used by [build] so a rebuild right after followUser/
  /// unfollowUser doesn't read a stale SQLite row and clobber the
  /// just-updated in-memory cache (the write is still in flight on the
  /// background isolate). On a tie (same createdAt) prefer the in-memory
  /// value — it's the freshly-signed one.
  Future<Event?> _newestContactList(String pubkey) async {
    final inMem = ref.read(contactListCacheProvider);
    final cache = ref.read(localCacheProvider).value;
    Event? fromDb;
    if (cache != null) {
      try {
        final row = await cache.queryContactList(pubkey);
        if (row != null) fromDb = _replaceableToEvent(row);
      } catch (_) {}
    }
    if (inMem != null &&
        (fromDb == null || inMem.createdAt >= fromDb.createdAt)) {
      return inMem;
    }
    return fromDb;
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
///
/// Owns the **global** feed REQ only. In **following** mode it is a no-op —
/// the following feed is driven by [followingOutboxProvider] (NIP-65 outbox
/// routing per followee), not a default-relay broadcast. Keeping the broadcast
/// out of following mode avoids fetching followee events from relays that may
/// not carry them (a followee who posts only to their own outbox would
/// otherwise never appear).
final feedSubscriptionProvider = Provider<void>((ref) {
  final mode = ref.watch(feedModeProvider);
  final identity = ref.watch(identityProvider).value;
  final follows = ref.watch(followingStateProvider).value ?? const <String>[];
  final pool = ref.watch(relayPoolProvider);

  if (identity == null) return;

  // Following mode → outbox provider owns the feed; nothing to broadcast.
  if (mode == FeedMode.following) return;

  final subId = nextSubId('feed');
  // Keep subscription open (no closeOnEose) so live reactions (kind-7) +
  // metadata (kind-0) continue arriving after the initial snapshot.
  // EventStore cap (5000) bounds memory; throttled emission bounds CPU.
  pool.request(subId, buildFeedFilter(mode, follows), closeOnEose: false);
  ref.onDispose(() => pool.closeSubscription(subId));
});

/// Build the NIP-65 outbox routing map for [follows]: relay URL → the
/// followees whose kind-10002 `read` markers include that relay. Followees
/// with no published relay list (or whose relays were all pushed out by the
/// [maxOutboxConnections] cap) are returned in [defaultBucket] — those are
/// served by a default-relay broadcast (the old path, unchanged behavior for
/// them). Resolves each followee's [userRelayListProvider] in parallel; the
/// 5-min memory TTL + SQLite cold-start hydrate make repeat builds cheap.
class OutboxMap {
  const OutboxMap(this.relayToAuthors, this.defaultBucket);
  final Map<String, List<String>> relayToAuthors;
  final List<String> defaultBucket;
}

Future<OutboxMap> buildOutboxMap(
  Future<RelayList?> Function(String pubkey) resolveRelayList,
  List<String> follows,
) async {
  // Resolve every followee's NIP-65 relay list in parallel.
  final lists = await Future.wait(follows.map(resolveRelayList));
  // Bucket each followee by their outbox relays.
  final relayToAuthors = <String, List<String>>{};
  final defaultBucket = <String>[];
  for (var i = 0; i < follows.length; i++) {
    final pk = follows[i];
    final read = lists[i]?.read ?? const <String>[];
    if (read.isEmpty) {
      defaultBucket.add(pk);
      continue;
    }
    for (final url in read) {
      relayToAuthors.putIfAbsent(url, () => []).add(pk);
    }
  }
  // Cap persistent outbox connections: keep the top-N relays by followee
  // count; followees whose relays ALL fell out of the top-N go to the default
  // bucket (so no followee is silently dropped — they fall back to broadcast).
  if (relayToAuthors.length > maxOutboxConnections) {
    final ranked = relayToAuthors.entries.toList()
      ..sort((a, b) => b.value.length.compareTo(a.value.length));
    final kept = ranked.take(maxOutboxConnections).map((e) => e.key).toSet();
    final dropped = <String>{};
    relayToAuthors.removeWhere((url, authors) {
      if (kept.contains(url)) return false;
      // A followee may be on multiple outbox relays; only move them to the
      // default bucket if ALL their relays were dropped.
      for (final pk in authors) {
        // Is this pk on any kept relay? If not, fall back to broadcast.
        final stillServed = relayToAuthors.entries.any(
          (e) => kept.contains(e.key) && e.value.contains(pk),
        );
        if (!stillServed && !defaultBucket.contains(pk)) {
          defaultBucket.add(pk);
        }
      }
      dropped.add(url);
      return true;
    });
  }
  return OutboxMap(relayToAuthors, defaultBucket);
}

/// Drives the **following** feed via NIP-65 outbox routing. A void provider
/// (kept alive by [currentFeedEventsProvider]); rebuilds — tearing down the
/// old [OutboxRouter] + default-bucket sub via onDispose — when feed mode,
/// identity, or the follows list changes. Events from the outbox tier are
/// ingested into [EventStoreNotifier] (the same store
/// [currentFeedEventsProvider] reads), so the existing following-mode filter
/// (`follows.contains(pubkey)`) surfaces them with no UI change.
final followingOutboxProvider = Provider<void>((ref) {
  final mode = ref.watch(feedModeProvider);
  final identity = ref.watch(identityProvider).value;
  final follows = ref.watch(followingStateProvider).value ?? const <String>[];
  if (identity == null || mode != FeedMode.following || follows.isEmpty) {
    return;
  }

  final pool = ref.watch(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);

  // `since` incremental refresh: only request events newer than the newest
  // followee post we already hold. Cold start (none held) → omit `since`,
  // cold-load limit 200 (OutboxRouter.start raises to 500 when since is set,
  // so a long absence doesn't lose a prolific followee's posts beyond 200).
  final held = ref.read(eventStoreProvider);
  final followsSet = follows.toSet();
  var newest = 0;
  for (final e in held) {
    if (followsSet.contains(e.pubkey) && e.createdAt > newest) {
      newest = e.createdAt;
    }
  }

  final router = OutboxRouter(
    makeClient: RelayClient.new,
    // Capture identity at build; the provider rebuilds on identity change so the
    // router's lifetime always sees the current key. Avoids touching [ref] from
    // a relay's late NIP-42 AUTH callback after the provider may be disposed.
    identityGetter: () => identity,
  );

  // The default-bucket subId isn't known until the async buildOutboxMap
  // resolves, but onDispose must be registered synchronously during build.
  // Capture it in a mutable holder the disposer reads at teardown.
  String? defaultSubId;
  // Own-posts sub: you don't follow yourself, so neither the outbox tier nor
  // the default bucket ever fetches your notes. The publish echo puts a fresh
  // one in the store, but once it's evicted (5000 in-memory cap) nothing would
  // ever re-fetch it — so keep a small live REQ for your own recent posts.
  final meSubId = nextSubId('feed-me');
  ref.onDispose(() {
    router.close();
    final sid = defaultSubId;
    if (sid != null) pool.closeSubscription(sid);
    pool.closeSubscription(meSubId);
  });
  pool.request(meSubId, <String, dynamic>{
    'kinds': [1, 6],
    'authors': [identity.pubkeyHex],
    'limit': 100,
  }, closeOnEose: false);

  // Fire-and-forget the async build+start; the provider stays alive while
  // watched. The onDispose above closes the router + default sub when
  // mode/follows change. Guard every [ref] use after an await with mounted —
  // the provider may be disposed (mode switch) during the network round-trip.
  () async {
    final map = await buildOutboxMap(
      (pk) => ref.read(userRelayListProvider(pk).future),
      follows,
    );
    if (!ref.mounted) return; // disposed during the relay-list lookups
    await router.start(
      map.relayToAuthors,
      since: newest > 0 ? newest : null,
      onEvent: (e) => store.ingest(e),
    );
    if (!ref.mounted) return; // disposed while opening outbox connections
    // Default bucket: followees with no usable outbox → broadcast to the main
    // pool (the old behavior). Live, so new posts/reactions stream in.
    if (map.defaultBucket.isNotEmpty) {
      final subId = nextSubId('feed-follows');
      final filter = <String, dynamic>{
        'kinds': [0, 1, 6, 7],
        'authors': List<String>.from(map.defaultBucket),
        'limit': newest > 0 ? 500 : 200,
      };
      if (newest > 0) filter['since'] = newest;
      pool.request(subId, filter, closeOnEose: false);
      defaultSubId = subId;
    }
  }();
});

// --- Current feed events (derived) -----------------------------------------

final currentFeedEventsProvider = Provider<List<Event>>((ref) {
  // Watching this keeps the feed subscription alive. In following mode the
  // outbox provider drives the fetch; in global mode the subscription provider
  // does. Both are watched unconditionally (each is a no-op when inactive).
  ref.watch(feedSubscriptionProvider);
  ref.watch(followingOutboxProvider);
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
    final me = ref.watch(identityProvider).value?.pubkeyHex;
    // The user's OWN posts always belong in their home feed. You don't follow
    // yourself, so without `|| e.pubkey == me` a just-published note (already
    // echoed into the store by publishAndWait) was silently dropped here —
    // visible in the profile 帖子 tab but never in the feed, and pull-refresh
    // couldn't bring it back either.
    events = events.where((e) => set.contains(e.pubkey) || e.pubkey == me);

    // Following-list filter (DESIGN §8): narrow to a custom group's authors
    // or a hashtag. Client-side on the already-loaded following feed.
    final ff = ref.watch(followingFilterProvider);
    if (ff != null) {
      if (ff.startsWith('group:')) {
        final gname = ff.substring(6);
        final me = ref.watch(identityProvider).value?.pubkeyHex;
        if (me != null) {
          final groups =
              ref.watch(userGroupedFollowsProvider(me)).value ??
              const <FollowGroup>[];
          FollowGroup? grp;
          for (final g in groups) {
            if (g.name == gname) {
              grp = g;
              break;
            }
          }
          if (grp != null) {
            final gset = grp.pubkeys.toSet();
            events = events.where((e) => gset.contains(e.pubkey));
          } else {
            // Group not (yet) known → show nothing rather than the full list.
            events = const <Event>[];
          }
        }
      } else if (ff.startsWith('tag:')) {
        final t = ff.substring(4);
        events = events.where((e) => e.hashtags.contains(t));
      }
    }
  }

  if (lang != LanguageFilter.all) {
    final want = switch (lang) {
      LanguageFilter.zh => 'zh',
      LanguageFilter.en => 'en',
      LanguageFilter.ja => 'ja',
      LanguageFilter.all => '',
    };
    // [Event.language] is memoized per event instance — the store dedupes by
    // id and reuses instances across rebuilds, so each event's content is
    // regex-scanned once, not on every 200ms store flush.
    events = events.where((e) => e.language == want);
  }
  if (tag != null) {
    events = events.where((e) => e.hashtags.contains(tag));
  }

  // Mute list (NIP-51 kind-10000): hide posts from muted authors, posts
  // carrying muted hashtags, posts whose content contains a muted word, and
  // individually muted events. Owner's private (NIP-44) mutes are decrypted
  // in [muteListProvider]. Applies in both global + following modes.
  final mute = ref.watch(myMuteSetProvider);
  if (!mute.isEmpty) {
    events = events.where((e) {
      if (mute.isMutedPubkey(e.pubkey)) return false;
      if (mute.isMutedEvent(e.id)) return false;
      if (e.isTextNote) {
        if (mute.contentHasMutedWord(e.content)) return false;
        if (mute.hasMutedHashtag(e.hashtags)) return false;
      }
      return true;
    });
  }
  return events.toList();
});

/// Find an event by id: hit SQLite first (O(1) PK), then in-memory store,
/// else fetch via REQ {ids:[id]} on the main pool, else a NIP-65 outbox
/// fallback on the user's own write relays (the most common miss is a
/// notification target — one of the user's OWN posts — that the connected
/// relays no longer serve).
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
  // 3. Relay REQ broadcast to the main pool. Capped at 8s; resolves early
  //    (null) once EVERY relay has answered EOSE with nothing, so a fast
  //    all-miss doesn't make the detail page sit out the full timeout.
  final pool = ref.watch(relayPoolProvider);
  final completer = Completer<Event?>();
  final relayCount = pool.states.length;
  var eoses = 0;
  final sub = pool.rawEvents.listen((e) {
    if (e.id == id && !completer.isCompleted) completer.complete(e);
  });
  final subId = nextSubId('note');
  final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (relayCount > 0 && eoses >= relayCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(subId, <String, dynamic>{
    'ids': [id],
  }, closeOnEose: true);
  ref.onDispose(() {
    sub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
  });
  Event? hit;
  try {
    hit = await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
  } finally {
    // Free the listeners + relay sub as soon as the lookup settles — the
    // FutureProvider itself stays cached, and a per-opened-post rawEvents
    // listener left attached would accumulate over a session.
    await sub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
  if (hit != null) return hit;
  // 4. NIP-65 outbox fallback: ask the user's OWN write relays. Reaction/
  //    reply/repost notifications always target the user's own posts, and
  //    those can outlive the connected relay set (relay list edited after
  //    posting, relays pruning old events, or the post made from another
  //    client whose write relays aren't connected here). Harmless one-shot
  //    for non-own ids too (the write relays simply answer EOSE).
  final me = ref.read(identityProvider).value?.pubkeyHex;
  if (me != null) {
    final rl = await ref.read(userRelayListProvider(me).future);
    final urls = rl?.write ?? const <String>[];
    if (urls.isNotEmpty) {
      final fetched = await pool.fetchFromUrls(
        <String, dynamic>{
          'ids': [id],
        },
        urls,
        timeout: const Duration(seconds: 5),
      );
      for (final e in fetched) {
        if (e.id == id) {
          // Cache in store + SQLite so a repeat open is instant.
          unawaited(ref.read(eventStoreProvider.notifier).ingest(e));
          return e;
        }
      }
    }
  }
  return null;
});

/// Parse the note a repost embeds, from the repost's OWN content. NIP-18:
/// a kind-6 repost's content is the stringified-JSON of the reposted event,
/// so a compliant repost carries the full embedded note — no relay fetch
/// needed. Returns null when [repost] isn't a repost, has no embedded JSON,
/// or the embedded event isn't post-like (a repost should only embed a post).
@visibleForTesting
Event? parseEmbeddedRepost(Event repost) {
  if (!repost.isRepost || repost.content.isEmpty) return null;
  try {
    final obj = jsonDecode(repost.content);
    if (obj is Map<String, dynamic>) {
      final e = Event.fromJson(obj);
      return e.isPostLike ? e : null;
    }
  } catch (_) {}
  return null;
}

/// Relay hints (NIP-01 `e` tag t[2]) pointing at where to find [repostedId]
/// on [repost]'s tags. Used to target a fetchFromUrls when the repost didn't
/// embed the JSON and the default-pool broadcast misses.
@visibleForTesting
List<String> repostRelayHints(Event repost, String repostedId) {
  final out = <String>{};
  for (final t in repost.tags) {
    if (t.length >= 3 &&
        t[0] == 'e' &&
        t[1] is String &&
        t[1] == repostedId &&
        t[2] is String) {
      final r = (t[2] as String).trim();
      if (r.startsWith('ws://') || r.startsWith('wss://')) out.add(r);
    }
  }
  return out.toList();
}

/// Distinct pubkeys from [repost]'s `p` tags, capped at [cap]. NIP-18
/// reposts carry the reposted note's author in a `p` tag (Costr and Amethyst
/// both emit it); some clients ALSO copy the original note's own `p` tags
/// onto the repost, so the second candidate is a fallback — but never fan out
/// unboundedly (each candidate costs a relay-list lookup + targeted fetch).
@visibleForTesting
List<String> repostAuthorCandidates(Event repost, {int cap = 2}) {
  final out = <String>[];
  final seen = <String>{};
  for (final t in repost.tags) {
    if (t.length < 2 || t[0] != 'p' || t[1] is! String) continue;
    final pk = t[1] as String;
    if (pk.isEmpty || !seen.add(pk)) continue;
    out.add(pk);
    if (out.length >= cap) break;
  }
  return out;
}

/// The note a repost points at — the embedded content shown under "X 转发".
///
/// Resolution order:
/// 1. **Parse the repost's own content** (NIP-18 embedded JSON) — instant, no
///    network. Most reposts (and Amethyst's, and ours) embed the full note, so
///    this is the common path; it's what makes a repost visible even when the
///    reposted note isn't on any of the user's connected relays.
/// 2. **Cache / in-memory / default-pool broadcast** via [eventByIdProvider] —
///    for non-compliant reposts (empty content) whose target is cached or on a
///    connected relay.
/// 3. **Relay-hint targeted fetchFromUrls** — the repost's `e`-tag t[2] points
///    at where the note lives (e.g. the nevent's relay hint). Recovers notes
///    that live only on the author's / replier's relays.
/// 4. **Reposted-author outbox** (NIP-65) — the repost's `p` tag carries the
///    reposted note's author; the note lives on that author's write relays, so
///    a targeted fetch there recovers notes that aren't on the user's pool and
///    whose repost carries no relay hint (the "经常显示转发内容不可用" case).
///
/// Without (1) and (3)–(4), tapping a repost shows "转发内容不可用" whenever
/// the reposted note isn't on the user's default pool — even though the repost
/// literally embeds it. Keyed by the repost's own id (carries content+tags).
final repostedEventProvider = FutureProvider.family<Event?, String>((
  ref,
  repostId,
) async {
  final repost = await ref.watch(eventByIdProvider(repostId).future);
  if (repost == null) return null;
  // 1. Embedded JSON (instant).
  final embedded = parseEmbeddedRepost(repost);
  if (embedded != null) return embedded;
  // 2. Cache + default-pool broadcast.
  final repostedId = repost.repostedEventId;
  if (repostedId == null) return null;
  final cached = await ref.read(eventByIdProvider(repostedId).future);
  if (cached != null) return cached;
  final pool = ref.read(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);
  // 3. Relay-hint targeted fetch.
  final hints = repostRelayHints(repost, repostedId);
  if (hints.isNotEmpty) {
    final hits = await pool.fetchFromUrls(<String, dynamic>{
      'ids': [repostedId],
    }, hints);
    for (final e in hits) {
      if (e.id == repostedId) {
        unawaited(store.cacheThreadEvent(e));
        return e;
      }
    }
  }
  // 4. Reposted-author outbox (NIP-65). Each candidate costs one relay-list
  //    lookup + one targeted fetch; both are independently capped (6s each)
  //    so a hanging relay can't leave the embed on "加载转发内容…" forever —
  //    worst case ~24s for 2 candidates, then the card settles on the retry-
  //    able "不可用" state instead of spinning.
  for (final pk in repostAuthorCandidates(repost)) {
    RelayList? rl;
    try {
      rl = await ref
          .read(userRelayListProvider(pk).future)
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Relay-list lookup hung or failed — try the next candidate.
    }
    final urls = <String>{
      ...rl?.write ?? const <String>[],
      ...rl?.read ?? const <String>[],
    };
    if (urls.isEmpty) continue;
    final hits = await pool.fetchFromUrls(
      <String, dynamic>{
        'ids': [repostedId],
      },
      urls.toList(),
      timeout: const Duration(seconds: 6),
    );
    for (final e in hits) {
      if (e.id == repostedId) {
        // Cache in SQLite so a repeat scroll-by is instant.
        unawaited(store.cacheThreadEvent(e));
        return e;
      }
    }
  }
  return null;
});

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
  final pool = ref.read(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);
  final byId = <String, Event>{focused.id: focused};
  final seen = <String>{focused.id};
  var frontier = _candidateAncestors(focused);
  for (var depth = 0; depth < 32 && frontier.isNotEmpty; depth++) {
    final fresh = frontier.where((c) => !seen.contains(c.id)).toList();
    if (fresh.isEmpty) break;
    // Tier 1: cache + in-memory + default-pool broadcast (eventByIdProvider,
    // 5s). Resolves instantly when the ancestor is already cached or lives on
    // a connected relay.
    final tier1 = await Future.wait(<Future<Event?>>[
      for (final c in fresh) ref.read(eventByIdProvider(c.id).future),
    ]);
    final newlyResolved = <Event>[];
    for (var i = 0; i < tier1.length; i++) {
      final r = tier1[i];
      if (r == null || !seen.add(r.id)) continue;
      byId[r.id] = r;
      newlyResolved.add(r);
    }
    // Tier 2: for ancestors that missed tier 1, fetch from the relay hint
    // carried on the referencing event's `e` tag (NIP-01 t[2]). The thread
    // often lives on the original author's / replier's relays — NOT the
    // user's connected default pool — so a targeted transient fetch via
    // fetchFromUrls hits where the broadcast missed. Without this, opening a
    // reply from the feed spins forever on the ancestor chain.
    final missing = <_AncestorCandidate>[];
    for (var i = 0; i < tier1.length; i++) {
      if (tier1[i] == null && fresh[i].relays.isNotEmpty) {
        missing.add(fresh[i]);
      }
    }
    if (missing.isNotEmpty) {
      final tier2 = await Future.wait(<Future<Event?>>[
        for (final c in missing)
          _fetchEventByIdFromUrls(pool, c.id, c.relays),
      ]);
      for (final r in tier2) {
        if (r == null || !seen.add(r.id)) continue;
        byId[r.id] = r;
        newlyResolved.add(r);
        unawaited(store.cacheThreadEvent(r));
      }
    }
    frontier = newlyResolved.expand(_candidateAncestors).toList();
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
  for (final e in byId.values) {
    unawaited(store.cacheThreadEvent(e));
  }
  return chain;
});

/// A candidate ancestor id + the relay hints (NIP-01 `e` tag t[2]) that point
/// at where to find it. Used by [threadAncestorsProvider]'s tier-2 targeted
/// fetch.
class _AncestorCandidate {
  const _AncestorCandidate(this.id, this.relays);
  final String id;
  final List<String> relays;
}

/// All non-`mention` `e`-tag referenced ids from [e] (root + reply markers +
/// legacy positional), each paired with the relay hint on its tag. Excludes
/// self-references. Used to walk the ancestor chain AND to know which relays
/// hold each ancestor.
List<_AncestorCandidate> _candidateAncestors(Event e) {
  final byId = <String, List<String>>{};
  for (final t in e.tags) {
    if (t.length < 2 || t[0] != 'e' || t[1] is! String) continue;
    final marker = (t.length >= 4 && t[3] is String) ? (t[3] as String) : '';
    if (marker == 'mention') continue;
    final id = t[1] as String;
    if (id == e.id) continue;
    final relay =
        (t.length >= 3 && t[2] is String) ? (t[2] as String).trim() : '';
    final list = byId.putIfAbsent(id, () => <String>[]);
    if (relay.isNotEmpty &&
        (relay.startsWith('ws://') || relay.startsWith('wss://'))) {
      list.add(relay);
    }
  }
  return byId.entries
      .map((en) => _AncestorCandidate(en.key, en.value))
      .toList();
}

/// Targeted fetch of a single event by id from the given relay URLs
/// (transient connections via [RelayPool.fetchFromUrls]). Returns the first
/// matching event, or null if none of the relays have it / are unreachable.
Future<Event?> _fetchEventByIdFromUrls(
  RelayPool pool,
  String id,
  List<String> urls,
) async {
  if (urls.isEmpty) return null;
  final hits = await pool.fetchFromUrls(<String, dynamic>{
    'ids': [id],
  }, urls);
  return hits.isEmpty ? null : hits.first;
}

/// A user's public kind-1 notes (posts + replies), newest-first. SQLite first
/// (instant), then relay REQ for fresh data. Used by the profile page.
/// A user's text notes (kind 1) — posts + replies together, split client-side
/// by NIP-10 `e`-tag markers (see [Event.isReply]). Amethyst-style loading:
/// emits the SQLite + in-memory EventStore snapshot instantly (their posts
/// already seen via the global feed, or cached from a previous visit), then
/// streams fresh events from the author's NIP-65 outbox relays with a 250ms
/// debounce so the list updates live as relays respond — never blocking the UI
/// on a full network round-trip. Re-visits add a `since` filter (newest
/// createdAt already held) so only new posts are pulled. Mirrors the home
/// [eventStoreProvider] + [userStatusProvider] pattern.
final userPostsProvider = StreamProvider.family<List<Event>, String>((
  ref,
  pubkey,
) async* {
  // 1. In-memory EventStore (sync) — posts already loaded via the global feed
  //    show with zero loading flash. Amethyst LocalCache.notes pattern.
  final merged = <String, Event>{}; // id -> event
  for (final e in ref.read(eventStoreProvider)) {
    if (e.isTextNote && e.pubkey == pubkey) merged[e.id] = e;
  }
  // 2. SQLite cache (posts from previous visits not in current memory).
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    try {
      for (final row in await cache.queryUserPosts(pubkey, limit: 100)) {
        final e = _cacheRowToEvent(row);
        if (e.isTextNote && e.pubkey == pubkey) merged[e.id] = e;
      }
    } catch (_) {}
  }
  // First emission: cached snapshot, newest-first (stable order, no flicker).
  yield _snapshotSorted(merged);

  // 3. Background relay fetch — stream fresh events into [merged], debounced.
  final pool = ref.watch(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);
  final ctrl = StreamController<List<Event>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(_snapshotSorted(merged));
      }
    });
  }

  // Fetch the NEWEST window of the author's notes. Do NOT use a `since`
  // incremental filter anchored on the newest cached post: for users outside
  // the social graph the cache is only a partial glimpse (whatever flowed
  // through the global feed — their posts are never persisted to SQLite), so
  // anchoring `since` there permanently hid the rest of their history
  // ("有的用户只能看到几条帖子/回帖，下拉刷新也刷不出更多"). Always pulling the
  // newest `limit` window is correct regardless of cache completeness; merged
  // dedups against the snapshot already shown.
  final filter = <String, dynamic>{
    'authors': [pubkey],
    'kinds': [1],
    'limit': 100,
  };

  // The broadcast path streams via rawEvents (set up before the await so
  // events arriving during the kind-10002 lookup are captured). The outbox
  // path uses transient clients (don't emit to rawEvents) → fed via onEvent.
  late StreamSubscription<Event> evSub;
  void onFresh(Event e) {
    if (!e.isTextNote || e.pubkey != pubkey || merged.containsKey(e.id)) return;
    merged[e.id] = e;
    unawaited(store.ingest(e)); // persist for next visit + show in main store
    scheduleEmit();
  }

  evSub = pool.rawEvents.listen(onFresh);

  // Relay fetch as a fire-and-forget phase (NOT awaited inline): the
  // generator must reach `yield* ctrl.stream` so relay hits written to `ctrl`
  // (debounced scheduleEmit + final flush) actually reach the UI. The old
  // code awaited the fetch inline and had NO `yield*` — every relay result
  // was buffered in `ctrl` and dropped when the generator returned, so the
  // profile only ever showed the cached snapshot ("有的用户只有几条帖子/回帖，
  // 下拉刷新也刷不出更多"). onFresh still ingests into the store for the next
  // visit regardless.
  Future<void> fetchPhase() async {
    final relays = await ref.read(userRelayListProvider(pubkey).future);
    final outbox = relays?.read ?? const <String>[];
    if (outbox.isNotEmpty) {
      // Outbox routing: per-URL transient clients. onEvent streams each event
      // as its relay responds (debounced), instead of waiting for the batch.
      await pool.fetchFromUrls(filter, outbox, onEvent: onFresh);
    } else {
      // No published relay list — broadcast to the main pool, resolve on first
      // EOSE (closeOnEose waits ALL relays in the pool impl; resolve locally on
      // the first one so a slow relay doesn't stall the snapshot).
      final subId = nextSubId('user');
      final done = Completer<void>();
      final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
        if (!done.isCompleted) done.complete();
      });
      pool.request(subId, filter, closeOnEose: true);
      final t = Timer(const Duration(seconds: 10), () {
        if (!done.isCompleted) done.complete();
      });
      await done.future;
      t.cancel();
      await eoseSub.cancel();
      pool.closeSubscription(subId);
    }
  }

  // When the fetch settles: emit any pending events, then close the controller
  // so `yield* ctrl.stream` completes (subsequent visits re-subscribe via
  // refresh/invalidate). Runs even if the fetch threw (cached snapshot already
  // emitted, so the provider still resolves to data instead of spinning).
  unawaited(
    fetchPhase().catchError((Object _) {}).whenComplete(() {
      flush?.cancel();
      if (!ctrl.isClosed) {
        if (dirty) {
          dirty = false;
          ctrl.add(_snapshotSorted(merged));
        }
        ctrl.close();
      }
    }),
  );
  ref.onDispose(() {
    flush?.cancel();
    evSub.cancel();
    if (!ctrl.isClosed) ctrl.close();
  });
  yield* ctrl.stream;
});

/// Newest-first snapshot of an id→event map, with id-ascending tie-break so
/// the order is stable across rebuilds (no flicker). Used by [userPostsProvider].
List<Event> _snapshotSorted(Map<String, Event> merged) {
  final list = merged.values.toList()
    ..sort((a, b) {
      final c = b.createdAt.compareTo(a.createdAt);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return List<Event>.unmodifiable(list);
}

/// Whether [kind] is a NIP-01 replaceable / parameterized-replaceable kind
/// (0, 3, 10000–19999, 30000–39999). Such events are small and deduped by
/// (pubkey, kind, d) — persisted unconditionally per CACHE_DESIGN §4.
bool _isReplaceableKind(int kind) =>
    kind == 0 ||
    kind == 3 ||
    (kind >= 10000 && kind < 20000) ||
    (kind >= 30000 && kind < 40000);

/// A user's follows (NIP-02 kind-3 p-tags) for the profile 关注 tab. Fetches
/// the user's kind-3 (replace-by-author) and resolves on EOSE / timeout.
final userFollowsProvider = StreamProvider.family<List<String>, String>((
  ref,
  pubkey,
) async* {
  // 1. SQLite cache (instant) — kind-3 is persisted by EventStoreNotifier.
  final cache = ref.read(localCacheProvider).value;
  List<String>? cachedFollows;
  if (cache != null) {
    try {
      final row = await cache.queryContactList(pubkey);
      if (row != null) {
        cachedFollows = _replaceableToEvent(row).pTagPubkeys;
      }
    } catch (_) {}
  }
  // Always emit an initial snapshot (cached, or empty) so the UI never hangs
  // on loading — the relay refresh below appends a newer list when it lands.
  var latest = List<String>.from(cachedFollows ?? const <String>[]);
  yield List<String>.unmodifiable(latest);

  // 2. Relay refresh — first matching event or first EOSE (not all relays),
  //    250ms-debounced so a burst of kind-3 versions doesn't thrash the UI.
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<List<String>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(List<String>.unmodifiable(latest));
      }
    });
  }

  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  evSub = pool.rawEvents.listen((e) {
    if (!e.isContactList || e.pubkey != pubkey) return;
    latest = List<String>.from(e.pTagPubkeys);
    scheduleEmit();
  });
  final subId = nextSubId('follows');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [Event.kindContactList],
    'limit': 1,
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 10), () {
    if (!done.isCompleted) done.complete();
  });
  // Flush pending + close ctrl when the fetch settles so yield* completes.
  done.future.whenComplete(() {
    flush?.cancel();
    if (dirty && !ctrl.isClosed) ctrl.add(List<String>.unmodifiable(latest));
    if (!ctrl.isClosed) ctrl.close();
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    ctrl.close();
  });
  yield* ctrl.stream;
});

/// A user's followers (NIP-12: REQ kind-3 events whose `p` tags reference the
/// user — the AUTHORS of those contact lists are the followers). Resolves on
/// all-relays EOSE / timeout.
final userFollowersProvider = StreamProvider.family<List<String>, String>((
  ref,
  pubkey,
) async* {
  // Followers (NIP-12 #p query across contact lists) aren't a single
  // replaceable event, so no per-user SQLite snapshot — stream results in as
  // they arrive (250ms debounced), resolve on the FIRST relay EOSE (not all)
  // so one dead relay doesn't stall the list for 12s.
  final pool = ref.watch(relayPoolProvider);
  final collected = <String>[];
  final seen = <String>{};
  final ctrl = StreamController<List<String>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(List<String>.unmodifiable(collected));
      }
    });
  }

  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  evSub = pool.rawEvents.listen((e) {
    if (e.isContactList && seen.add(e.pubkey)) {
      collected.add(e.pubkey);
      scheduleEmit();
    }
  });
  final subId = nextSubId('followers');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'kinds': [Event.kindContactList],
    '#p': [pubkey],
    'limit': 500,
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 12), () {
    if (!done.isCompleted) done.complete();
  });
  // Settle: flush + always emit a final snapshot (empty if nothing arrived,
  // so the UI resolves instead of hanging on loading), add to social graph.
  done.future.whenComplete(() {
    flush?.cancel();
    if (!ctrl.isClosed) {
      ctrl.add(List<String>.unmodifiable(collected));
      ctrl.close();
    }
    ref.read(socialGraphProvider.notifier).addFollowers(collected);
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    ctrl.close();
  });
  yield* ctrl.stream;
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
  const FollowGroup(this.name, this.pubkeys, {this.source});
  final String name;
  /// Members of this group that are ALSO in the user's kind-3 follows (what
  /// the people rows render — only people you actually follow show up).
  final List<String> pubkeys;
  /// The backing NIP-51 kind-30000 event (null for 默认分组). Carries the
  /// stable `d` identifier + event id needed for rename/delete.
  final Event? source;

  /// The list's true member count — every `p` tag in [source] — NOT just the
  /// followed members. Amethyst shows this number; previously Costr showed
  /// [pubkeys.length] (followed ∩ group), which read as "too few" when a list
  /// held people the user no longer followed. Defaults to [pubkeys.length]
  /// for 默认分组 (no backing event).
  int get memberCount {
    final s = source;
    if (s == null) return pubkeys.length;
    var n = 0;
    for (final t in s.tags) {
      if (t.length >= 2 && t[0] == 'p' && t[1] is String) n++;
    }
    return n;
  }
}

/// Human-readable name of a NIP-51 kind-30000 follow set. Prefers the
/// `name` tag (Amethyst puts the human name here and a UUID in `d`); falls
/// back to the `d` tag (Costr's own lists use the human name directly as
/// `d` and carry no `name` tag). Returns null for the default list (d="").
String? kind30000DisplayName(Event e) {
  String? name;
  String? d;
  for (final t in e.tags) {
    if (t.length < 2 || t[1] is! String) continue;
    if (t[0] == 'name') {
      name ??= t[1] as String;
    } else if (t[0] == 'd') {
      d ??= t[1] as String;
    }
  }
  final n = (name != null && name.isNotEmpty) ? name : d;
  return (n == null || n.isEmpty) ? null : n;
}

/// The logged-in user's follows grouped by NIP-51 kind-30000 categories.
/// First entry is 默认分组 (follows not in any custom group). Then one entry
/// per custom group (d-tag name) with the pubkeys in that group.
/// pubkeys in custom groups are also kept in 默认分组 only if not in any group.
///
/// Pure builder so the SQLite-cached snapshot and the relay-refreshed
/// snapshot share one code path (Amethyst-style render-from-cache + background
/// refresh).
///
/// Groups are keyed by the kind-30000 **`d` tag** (the stable identifier),
/// NOT by [kind30000DisplayName]: Amethyst keeps a UUID in `d` and puts the
/// human name in the `name` tag, so an older revision (no `name` tag) would
/// otherwise group under the UUID while a newer revision (with `name`) groups
/// under the human name — splitting one logical list into two entries and
/// making the group name flicker between 中文 and UUID as revisions stream
/// in. Keying by `d` collapses all revisions into one group, and the display
/// name is taken from the NEWEST revision's `name` tag (falling back to `d`).
List<FollowGroup> _buildFollowGroups(
  List<String> follows,
  List<Event> k30000Events,
) {
  // 1. group by d → Set<pubkey> + newest backing event.
  final dValues = <String>[]; // first-seen order
  final groupPubkeys = <String, Set<String>>{};
  final groupSource = <String, Event>{}; // d → newest kind-30000 event
  for (final e in k30000Events) {
    final d = _kind30000D(e);
    if (d.isEmpty) continue; // default list (d="") — not a named group
    final pks = <String>{};
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'p' && t[1] is String) {
        pks.add(t[1] as String);
      }
    }
    if (!dValues.contains(d)) dValues.add(d);
    groupPubkeys.putIfAbsent(d, () => <String>{}).addAll(pks);
    final prev = groupSource[d];
    if (prev == null || e.createdAt > prev.createdAt) groupSource[d] = e;
  }

  // 2. Group the follows.
  final result = <FollowGroup>[];
  // Default group: follows not in any custom group.
  final defaultGroup = <String>[];
  for (final pk in follows) {
    var inAnyGroup = false;
    for (final d in dValues) {
      if (groupPubkeys[d]!.contains(pk)) {
        inAnyGroup = true;
        break;
      }
    }
    if (!inAnyGroup) defaultGroup.add(pk);
  }
  result.add(FollowGroup('默认分组', defaultGroup));
  // Custom groups: always surfaced (even with zero followed members) so the
  // user can see + manage (rename/delete) every list they published — matches
  // Amethyst. Rows still only render followed members.
  for (final d in dValues) {
    final inGroup = follows
        .where((pk) => groupPubkeys[d]!.contains(pk))
        .toList();
    // Display name: the NEWEST revision's `name` tag, else `d`. Stable per
    // group now that we key by d (no more 中文↔UUID flicker).
    final display = kind30000DisplayName(groupSource[d]!) ?? d;
    result.add(FollowGroup(display, inGroup, source: groupSource[d]));
  }
  return result;
}

/// The `d` tag value of a kind-30000 event, or '' if absent. The stable
/// identifier a follow set is grouped under (see [_buildFollowGroups]).
String _kind30000D(Event e) {
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == 'd' && t[1] is String) return t[1] as String;
  }
  return '';
}

final userGroupedFollowsProvider =
    StreamProvider.family<List<FollowGroup>, String>((ref, pubkey) async* {
      // Re-run when any kind-30000 set for the user changes (local publish or
      // remote ingestion bumps this counter).
      ref.watch(kind30000VersionProvider);

      // 1. SQLite snapshot (instant) — kind-3 + all kind-30000 are persisted
      //    by EventStoreNotifier's main listener.
      final cache = ref.read(localCacheProvider).value;
      List<FollowGroup>? cached;
      if (cache != null) {
        try {
          final k3row = await cache.queryContactList(pubkey);
          final follows = k3row != null
              ? _replaceableToEvent(k3row).pTagPubkeys
              : const <String>[];
          final sets = await cache.queryFollowSets(pubkey);
          final k30000 = sets.map(_replaceableToEvent).toList();
          cached = _buildFollowGroups(follows, k30000);
        } catch (_) {}
      }
      if (cached != null) yield cached;

      // 2. Relay refresh — kind-3 + kind-30000, each resolves on its FIRST
      //    EOSE (not all relays). Rebuild + yield once both settle.
      final pool = ref.watch(relayPoolProvider);
      final ctrl = StreamController<List<FollowGroup>>();
      // Seed follows from the cached 默认分组 if present (best-effort).
      List<String> follows = const <String>[];
      if (cached != null) {
        for (final g in cached) {
          if (g.name == '默认分组') {
            follows = g.pubkeys;
            break;
          }
        }
      }
      final k30000Events = <Event>[];
      final seen3 = <String>{};
      late StreamSubscription<Event> evSub1;
      late StreamSubscription<Event> evSub2;
      late StreamSubscription<String> eoseSub1;
      late StreamSubscription<String> eoseSub2;
      final done1 = Completer<void>();
      final done2 = Completer<void>();

      evSub1 = pool.rawEvents.listen((e) {
        if (e.isContactList && e.pubkey == pubkey && !done1.isCompleted) {
          follows = e.pTagPubkeys;
          done1.complete();
        }
      });
      final sub1 = nextSubId('grouped-k3');
      eoseSub1 = pool.eoseStream.where((s) => s == sub1).listen((_) {
        if (!done1.isCompleted) done1.complete();
      });
      pool.request(sub1, {
        'authors': [pubkey],
        'kinds': [Event.kindContactList],
        'limit': 1,
      }, closeOnEose: true);

      evSub2 = pool.rawEvents.listen((e) {
        if (e.kind == 30000 && e.pubkey == pubkey && seen3.add(e.id)) {
          k30000Events.add(e);
        }
      });
      final sub2 = nextSubId('grouped-k30k');
      eoseSub2 = pool.eoseStream.where((s) => s == sub2).listen((_) {
        if (!done2.isCompleted) done2.complete();
      });
      pool.request(sub2, {
        'authors': [pubkey],
        'kinds': [30000],
      }, closeOnEose: true);

      final t1 = Timer(const Duration(seconds: 10), () {
        if (!done1.isCompleted) done1.complete();
      });
      final t2 = Timer(const Duration(seconds: 10), () {
        if (!done2.isCompleted) done2.complete();
      });

      // When both settle, rebuild + emit, then close.
      Future<void> both() async {
        await done1.future;
        await done2.future;
      }

      both().whenComplete(() {
        if (!ctrl.isClosed) {
          ctrl.add(_buildFollowGroups(follows, k30000Events));
          ctrl.close();
        }
      });
      ref.onDispose(() {
        t1.cancel();
        t2.cancel();
        evSub1.cancel();
        evSub2.cancel();
        eoseSub1.cancel();
        eoseSub2.cancel();
        pool.closeSubscription(sub1);
        pool.closeSubscription(sub2);
        ctrl.close();
      });
      yield* ctrl.stream;
    });

/// The logged-in user's existing follow-group names (NIP-51 kind-30000 `d`
/// tags). Used by the follow-group picker to show existing + allow new.
final userGroupNamesProvider = StreamProvider.family<List<String>, String>((
  ref,
  pubkey,
) async* {
  // Re-run when any kind-30000 set for the user changes.
  ref.watch(kind30000VersionProvider);

  // 1. SQLite snapshot (instant) — kind-30000 sets are persisted by
  //    EventStoreNotifier. Read d-tags straight from the replaceable rows.
  final cache = ref.read(localCacheProvider).value;
  final collected = <String>[];
  final seen = <String>{};
  if (cache != null) {
    try {
      for (final row in await cache.queryFollowSets(pubkey)) {
        final name = kind30000DisplayName(_replaceableToEvent(row));
        if (name != null && seen.add(name)) collected.add(name);
      }
    } catch (_) {}
  }
  yield List<String>.unmodifiable(collected);

  // 2. Relay refresh — first EOSE (not all relays), append any newer names.
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<List<String>>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  evSub = pool.rawEvents.listen((e) {
    if (e.kind == 30000 && e.pubkey == pubkey) {
      final name = kind30000DisplayName(e);
      if (name != null && seen.add(name)) {
        collected.add(name);
        ctrl.add(List<String>.unmodifiable(collected));
      }
    }
  });
  final subId = nextSubId('groups');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [30000],
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 10), () {
    if (!done.isCompleted) done.complete();
  });
  done.future.whenComplete(() {
    if (!ctrl.isClosed) {
      ctrl.add(List<String>.unmodifiable(collected));
      ctrl.close();
    }
  });
  ref.onDispose(() {
    t.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    ctrl.close();
  });
  yield* ctrl.stream;
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
final searchPostsProvider = StreamProvider.family<List<Event>, String>((
  ref,
  query,
) async* {
  final q = query.trim();
  if (q.isEmpty) {
    yield const <Event>[];
    return;
  }
  // 1. SQLite FTS5 (instant, local cached events) — first emission, no waiting.
  final cache = ref.read(localCacheProvider).value;
  final merged = <String, Event>{}; // id -> event
  if (cache != null) {
    try {
      for (final row in await cache.searchEvents(q, limit: 100)) {
        final e = _cacheRowToEvent(row);
        if (e.isTextNote) merged[e.id] = e;
      }
    } catch (_) {}
  }
  yield _snapshotSorted(merged);

  // 2. NIP-50 relay search via the DEDICATED search pool. Stream results in
  //    with a 250ms debounce instead of a hard 6s wait — local FTS shows
  //    instantly, relay hits append as they arrive. Most relays ignore the
  //    `search` filter; the search pool only connects NIP-50-capable relays.
  final pool = ref.watch(searchPoolProvider);
  final ctrl = StreamController<List<Event>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(_snapshotSorted(merged));
      }
    });
  }

  // rawEvents (not events): re-searching the same term must still return
  // results even though the search pool already saw those event ids.
  final subId = nextSubId('search');
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.isTextNote && !merged.containsKey(e.id)) {
      merged[e.id] = e;
      scheduleEmit();
    }
  });
  // Resolve when ALL search relays EOSE (the search pool is small — 2 NIP-50
  // relays — so "all EOSE" is quick, unlike the main pool), or a 6s cap.
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  final done = Completer<void>();
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'search': q,
    'kinds': [1],
    'limit': 100,
  }, closeOnEose: false);
  final t = Timer(const Duration(seconds: 6), () {
    if (!done.isCompleted) done.complete();
  });
  // When all search relays EOSE (or the 6s cap fires): stop listening, do a
  // final flush, then close the controller so `yield* ctrl.stream` completes
  // and the StreamProvider leaves its loading state. Without piping the
  // controller's stream out, every relay hit (and this final flush) written
  // to `ctrl` was silently dropped and the provider never emitted past the
  // initial local-FTS snapshot — so user search spun forever.
  done.future.whenComplete(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (dirty && !ctrl.isClosed) {
      dirty = false;
      ctrl.add(_snapshotSorted(merged));
    }
    if (!ctrl.isClosed) ctrl.close();
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (!ctrl.isClosed) ctrl.close();
  });
  yield* ctrl.stream;
});

/// Per-post interaction counts the client has OBSERVED so far (replies +
/// reposts), derived client-side from the in-memory [EventStore]. This is a
/// lower bound — only events that have streamed in via the global feed, a
/// targeted #e REQ (e.g. [repliesProvider] when the thread was opened), or a
/// load-more page are counted; relays aren't queried for a total. Matches
/// Amethyst's "what I've seen" approach. The count populates reliably once
/// the user has opened the post's thread; on the feed it stays ~0 until then.
final postCountsProvider = Provider.family<({int replies, int reposts}), String>((
  ref,
  eventId,
) {
  final all = ref.watch(eventStoreProvider);
  var replies = 0;
  var reposts = 0;
  for (final e in all) {
    if (e.kind != 1 && e.kind != 6) continue;
    // Skip the post itself (a kind-1 with a self-referential e tag, rare).
    if (e.id == eventId) continue;
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) {
        if (e.kind == 1) {
          replies++;
        } else {
          reposts++;
        }
        break;
      }
    }
  }
  return (replies: replies, reposts: reposts);
});

/// Global user search (NIP-50 `search` filter, kind 0 metadata) via the
/// dedicated search pool. Streams results in (250ms debounce) instead of a
/// hard 6s wait.
final searchUsersProvider = StreamProvider.family<List<UserResult>, String>((
  ref,
  query,
) async* {
  final q = query.trim();
  if (q.isEmpty) {
    yield const <UserResult>[];
    return;
  }
  final pool = ref.watch(searchPoolProvider);
  final merged = <String, UserResult>{}; // pubkey -> result
  final ctrl = StreamController<List<UserResult>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(merged.values.toList());
      }
    });
  }

  final subId = nextSubId('searchusers');
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  evSub = pool.rawEvents.listen((e) {
    if (e.kind == 0 && !merged.containsKey(e.pubkey)) {
      Metadata? meta;
      try {
        final json = jsonDecode(e.content);
        if (json is Map<String, dynamic>) meta = Metadata.fromJson(json);
      } catch (_) {}
      merged[e.pubkey] = UserResult(e.pubkey, meta);
      scheduleEmit();
    }
  });
  final connectedCount = pool.states
      .where((s) => s.status == RelayStatus.connected)
      .length;
  var eoses = 0;
  final done = Completer<void>();
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (eoses >= connectedCount && !done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'search': q,
    'kinds': [0],
    'limit': 50,
  }, closeOnEose: false);
  final t = Timer(const Duration(seconds: 6), () {
    if (!done.isCompleted) done.complete();
  });
  // Same fix as searchPostsProvider: pipe `ctrl` out via `yield*` so the
  // StreamProvider emits relay results instead of staying in loading forever.
  // AND always emit a final snapshot — EVEN AN EMPTY ONE — before closing:
  // when zero users match, nothing was ever added to `ctrl` (the flush only
  // fires on results), so the stream closed without emitting and Riverpod
  // left the provider stuck in AsyncLoading — the perpetual "用户列表" spinner
  // that even survived leaving and re-entering the search tab. Emitting an
  // empty list resolves it to data (「无用户结果」), same fix as repliesProvider.
  done.future.whenComplete(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (!ctrl.isClosed) {
      dirty = false;
      ctrl.add(merged.values.toList());
      ctrl.close();
    }
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (!ctrl.isClosed) ctrl.close();
  });
  yield* ctrl.stream;
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
            // NIP-25: empty content OR literal "+" = the default "like".
            // Normalize to 👍 so the chip shows a real glyph instead of a bare
            // "+" (which users mistook for an unknown UI control). Clients that
            // send emoji content (🔥 / :shortcode:) keep their own key.
            final raw = e.content;
            final key =
                (raw.isEmpty || raw == '+') ? '👍' : raw;
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

/// The current user's own kind-7 reaction to [eventId], if present in the
/// in-memory store (their just-published reaction is echoed locally by
/// [RelayPool.publish] and stored). Used to highlight the reaction icon + let
/// a second tap cancel (NIP-09 kind-5 delete of the reaction event).
final myReactionProvider = Provider.family<Event?, String>((ref, eventId) {
  final me = ref.watch(identityProvider).value?.pubkeyHex;
  if (me == null) return null;
  final store = ref.watch(eventStoreProvider);
  for (final e in store) {
    if (e.kind != 7 || e.pubkey != me) continue;
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) return e;
    }
  }
  return null;
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

/// A reply in a flattened thread tree: the [event] plus its [depth] (0 =
/// direct reply to the focused post, 1 = reply-to-a-reply, …). Produced by
/// [threadReplies]; the UI indents per [depth] so the reply hierarchy is
/// visible.
class ThreadedReply {
  const ThreadedReply(this.event, this.depth);
  final Event event;
  final int depth;
}

/// Build a flattened, **timeline-ordered + hierarchical** view of [replies]
/// to the post [rootId].
///
/// The flat [repliesProvider] list mixes direct replies and nested
/// sub-replies sorted only by createdAt — reading order is jumbled. This
/// builds a parent→children tree (parent = [Event.replyToId]) and flattens it
/// depth-first, oldest-first within siblings: each reply is followed by its
/// own sub-thread, so a conversation reads top-down and the reply hierarchy is
/// visible via [ThreadedReply.depth] (the UI indents per depth).
///
/// Replies whose parent isn't in the set (and isn't the root) are reparented
/// to the root as depth-0 direct replies — defensive against unknown/missing
/// parents. Cycles are guarded by a seen-set.
List<ThreadedReply> threadReplies(List<Event> replies, String rootId) {
  final byId = {for (final e in replies) e.id: e};
  final children = <String, List<Event>>{};
  final orphans = <Event>[];
  for (final e in replies) {
    final parent = e.replyToId;
    if (parent == null ||
        parent == e.id ||
        (parent != rootId && !byId.containsKey(parent))) {
      orphans.add(e);
    } else {
      children.putIfAbsent(parent, () => <Event>[]).add(e);
    }
  }
  // Roots = direct replies to the focused post + reparented orphans, oldest-first.
  final roots = <Event>[
    ...(children[rootId] ?? const <Event>[]),
    ...orphans,
  ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  final out = <ThreadedReply>[];
  final seen = <String>{};
  void walk(Event e, int depth) {
    if (!seen.add(e.id)) return; // cycle guard
    out.add(ThreadedReply(e, depth));
    final kids = children[e.id];
    if (kids == null) return;
    kids.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final k in kids) {
      walk(k, depth + 1);
    }
  }

  for (final r in roots) {
    walk(r, 0);
  }
  // Fallback: replies unreachable from the roots (pure cycles, or subtrees
  // whose chain never touches the root) would otherwise be silently dropped.
  // Emit them at depth 0, oldest-first, walking their own subtrees.
  final unreached =
      replies.where((e) => !seen.contains(e.id)).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  for (final e in unreached) {
    walk(e, 0);
  }
  return out;
}

/// Replies (kind-1) to an event. REQ {kinds:[1], "#e":[eventId]}.
/// Amethyst-style loading: yields the SQLite-cached replies (persisted when
/// previously viewed via [EventStoreNotifier.cacheThreadEvent]) instantly,
/// then streams fresh relay replies in with a 250ms debounce. Resolves on the
/// FIRST relay EOSE (not all) so a slow relay doesn't stall the list.
final repliesProvider = StreamProvider.family<List<Event>, String>((
  ref,
  eventId,
) async* {
  // 1. SQLite cache (instant). ALWAYS yield — even an empty list — so the
  // provider resolves to AsyncData immediately. Without this, a first-visit
  // post whose replies are still in flight (and whose outbox phase hangs,
  // see outboxPhase timeout below) would leave the provider in AsyncLoading
  // forever → a perpetual spinner under the reply list even when there are
  // zero replies. An empty initial yield shows "暂无回复" for a split second
  // until live replies stream in — a brief flash, far better than an
  // eternal spinner.
  final cache = ref.read(localCacheProvider).value;
  final merged = <String, Event>{}; // id -> event
  if (cache != null) {
    try {
      for (final row in await cache.queryReplies(eventId)) {
        final e = _cacheRowToEvent(row);
        if (isReplyToEvent(e, eventId)) merged[e.id] = e;
      }
    } catch (_) {}
  }
  yield _snapshotSorted(merged);

  // 2. Relay refresh — stream fresh replies, 250ms debounced.
  final pool = ref.watch(relayPoolProvider);
  final store = ref.read(eventStoreProvider.notifier);
  final ctrl = StreamController<List<Event>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(_snapshotSorted(merged));
      }
    });
  }

  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>(); // default-pool phase done (EOSE / 10s).
  evSub = pool.rawEvents.listen((e) {
    // Only kind-1 notes that directly reply to [eventId]. rawEvents is the
    // global un-deduped stream; the feed sub also requests kind-7 reactions,
    // which would otherwise leak in as replies.
    if (!isReplyToEvent(e, eventId) || merged.containsKey(e.id)) return;
    merged[e.id] = e;
    unawaited(store.cacheThreadEvent(e)); // persist for next visit
    scheduleEmit();
  });
  final subId = nextSubId('replies');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'kinds': [1],
    '#e': [eventId],
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 10), () {
    if (!done.isCompleted) done.complete();
  });

  // Author-outbox phase (concurrent with the default pool). The focused
  // post's author publishes on their NIP-65 outbox relays, and thread replies
  // to them typically propagate there too — so querying those relays directly
  // recovers descendants the user's connected default pool hasn't indexed
  // (the "open a reply from the feed, replies never load" case). Transient
  // fetchFromUrls connections; onEvent feeds the same merged map + debounce.
  // Bounded by fetchFromUrls' internal 10s timeout. Runs concurrently with
  // the default-pool REQ; the stream closes only when BOTH phases finish.
  Future<void> outboxPhase() async {
    try {
      final focused = await ref.read(eventByIdProvider(eventId).future);
      if (focused == null) return;
      final rl = await ref.read(userRelayListProvider(focused.pubkey).future);
      final outbox = rl?.read ?? const <String>[];
      if (outbox.isEmpty) return;
      await pool.fetchFromUrls(
        <String, dynamic>{'kinds': [1], '#e': [eventId]},
        outbox,
        onEvent: (e) {
          if (!isReplyToEvent(e, eventId) || merged.containsKey(e.id)) return;
          merged[e.id] = e;
          unawaited(store.cacheThreadEvent(e));
          scheduleEmit();
        },
      );
    } catch (_) {
      // Focused-post or relay-list fetch failed — default-pool path still runs
      // and will resolve the stream on its own.
    }
  }

  // Bound the outbox phase so a hanging userRelayListProvider (or a stuck
  // fetchFromUrls) can't keep the stream open forever — without this the
  // final-snapshot close never fires and the provider stays AsyncLoading for
  // the whole session (perpetual spinner). 10s matches fetchFromUrls' own
  // cap; the default-pool phase is independently bounded by the 10s `done`
  // timer, so the stream resolves within ~10–12s worst case.
  final outboxFuture = outboxPhase().timeout(const Duration(seconds: 10));
  Future.wait<void>([done.future, outboxFuture]).whenComplete(() {
    flush?.cancel();
    // Always emit a final snapshot before closing. Without this, a stream
    // that closes without ever emitting (zero replies: cache empty AND relays
    // return nothing) leaves Riverpod's StreamProvider stuck in AsyncLoading
    // forever — so the reply list shows a perpetual spinner where "暂无回复"
    // should be. Emitting — even an empty list — resolves the provider to
    // data. When replies did arrive this is a harmless re-emit of the same
    // list (scheduleEmit already pushed the live list).
    if (!ctrl.isClosed) {
      ctrl.add(_snapshotSorted(merged));
      ctrl.close();
    }
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    ctrl.close();
  });
  yield* ctrl.stream;
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
  List<String> categories = const [],
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

  // OPTIMISTIC: update the local cache + follows list IMMEDIATELY so the UI
  // (follow button, following tab) reflects the new follow without blocking
  // on relay OKs. publishAndWait can take up to several seconds (5s/round ×
  // retries) waiting for the first relay to ack — that's the "关注要等好几秒"
  // lag. For a follow, optimistic is the right trade (Amethyst does this): if
  // a relay later rejects, the next kind-3 refresh corrects the local state.
  ref.read(contactListCacheProvider.notifier).set(signed);
  ref.invalidate(followingStateProvider);

  // Publish in the background — fire-and-forget. The local echo (handled
  // inside publishAndWait via _merged) + the optimistic cache update above
  // mean the user already sees the follow; the relay round-trip happens off
  // the critical path.
  unawaited(
    pool.publishAndWait(signed).then((ok) {
      if (!ok.ok) {
        // Best-effort: invalidate so a re-fetch can reconcile on failure.
        ref.invalidate(followingStateProvider);
      }
    }),
  );

  // Custom-group lists (NIP-51 kind-30000) — also background; they're
  // secondary and mustn't block the follow action.
  for (final category in categories) {
    if (category.isNotEmpty) {
      unawaited(_addToCategoryList(ref, identity, pubkey, category));
    }
  }
  return RelayOk(signed.id, true, '已关注');
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
  // OPTIMISTIC (same rationale as [followUser]): update the cache + follows
  // list immediately so the button snaps to "unfollowed"; publish in the
  // background so the relay round-trip (up to several seconds) doesn't block.
  ref.read(contactListCacheProvider.notifier).set(signed);
  ref.invalidate(followingStateProvider);
  unawaited(
    pool.publishAndWait(signed).then((ok) {
      if (!ok.ok) ref.invalidate(followingStateProvider);
    }),
  );
  return RelayOk(signed.id, true, '已取消关注');
}

/// updated one with [pubkey] added. Best-effort (category list failure doesn't
/// fail the follow).
///
/// [category] is the group's DISPLAY name. The existing kind-30000 event is
/// resolved BY DISPLAY NAME (not `#d`): Amethyst stores a UUID in `d` and the
/// human name in a `name` tag, so a `#d`=[category] filter would miss their
/// lists and Costr would fork a second list. SQLite cache is checked first
/// (instant); a relay REQ (all the author's kind-30000) covers lists not yet
/// cached. The matched event is passed as `current` so [followCategory]
/// preserves its real `d` + metadata tags.
Future<void> _addToCategoryList(
  WidgetRef ref,
  Identity identity,
  String pubkey,
  String category,
) async {
  final pool = ref.read(relayPoolProvider);

  // 1. SQLite cache first (instant).
  Event? current;
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    try {
      for (final row in await cache.queryFollowSets(identity.pubkeyHex)) {
        final ev = _replaceableToEvent(row);
        if (kind30000DisplayName(ev) == category) {
          current = ev;
          break;
        }
      }
    } catch (_) {}
  }

  // 2. Relay REQ (all author's kind-30000) for lists not yet cached, matched
  //    by display name.
  if (current == null) {
    final completer = Completer<Event?>();
    late StreamSubscription<Event> evSub;
    late StreamSubscription<String> eoseSub;
    evSub = pool.rawEvents.listen((e) {
      if (e.kind == 30000 &&
          e.pubkey == identity.pubkeyHex &&
          !completer.isCompleted &&
          kind30000DisplayName(e) == category) {
        completer.complete(e);
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
      'limit': 100,
    }, closeOnEose: false);
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
  }

  final signed = NostrActions(
    identity,
  ).followCategory(current, pubkey, category);
  await pool.publishAndWait(signed);
  // No explicit bump here: publishAndWait echoes the event to the merged
  // stream, EventStoreNotifier persists it, and (per the H3 fix) bumps
  // kind30000VersionProvider AFTER the SQLite write lands — so the rebuilt
  // snapshot reliably sees the new row. A synchronous bump here would race
  // the background-isolate write and render a stale-empty list.
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
  // 1. SQLite cache first — kind-10003 is persisted by EventStoreNotifier's
  //    replaceable-kinds path. If we have it, sign + publish immediately
  //    WITHOUT the up-to-10s relay fetch below. That fetch (with its strict
  //    "certain or cancel" guard) is what made bookmarking feel broken — a
  //    slow relay would trip "无法确认现有书签列表…已取消". The cache holds
  //    the current list so the new entry is added without wiping the rest.
  Event? current;
  final cache = ref.read(localCacheProvider).value;
  if (cache != null) {
    try {
      final row = await cache.queryReplaceable(identity.pubkeyHex, 10003);
      if (row != null) current = _replaceableToEvent(row);
    } catch (_) {}
  }
  // 2. Cache miss (first-ever bookmark, cold start) → fetch the current
  //    kind-10003 from relays with the don't-wipe safety guard.
  if (current == null) {
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
      return const RelayOk(
        '',
        false,
        '无法确认现有书签列表（中继未及时响应），已取消以防清空。请重试。',
      );
    }
  }
  final signed = NostrActions(
    identity,
  ).bookmark(current, eventId, publicList: publicList);
  // Refresh the bookmarks stream so the new entry appears immediately.
  ref.invalidate(bookmarksProvider(identity.pubkeyHex));
  return pool.publishAndWait(signed);
}

/// Add/remove an entry from the logged-in user's NIP-51 kind-10000 mute list
/// (Amethyst interop: public `p`/`word`/`t`/`e` tags + NIP-44-encrypted
/// private entries). Fetches the current kind-10000 (to preserve existing
/// entries), signs an updated one via [NostrActions.muteList], publishes.
/// [entry] is a Nostr tag pair: `['p', pubkey]` / `['word', str]` /
/// `['t', hashtag]` / `['e', eventId]`. [publicList]: public tag vs
/// NIP-44-private (default private — most users want their mute list hidden).
Future<RelayOk> muteEntry(
  WidgetRef ref,
  MuteEntry entry, {
  required bool add,
  bool publicList = false,
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
    if (e.kind == 10000 &&
        e.pubkey == identity.pubkeyHex &&
        !completer.isCompleted) {
      completer.complete(e);
    }
  });
  final subId = nextSubId('mute');
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
    'kinds': [10000],
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
    return const RelayOk('', false, '无法确认现有屏蔽列表（中继未及时响应），已取消以防清空。请重试。');
  }
  final signed = NostrActions(
    identity,
  ).muteList(current, entry: entry, add: add, publicList: publicList);
  final ok = await pool.publishAndWait(signed);
  // Local cache so the mute takes effect instantly (relay echo re-ingests +
  // bumps muteListProvider, but do it now). Persist the kind-10000 row.
  if (ok.ok) {
    final cache = await ref.read(localCacheProvider.future);
    try {
      await cache.writeEvent(
        id: signed.id,
        pubkey: signed.pubkey,
        kind: signed.kind,
        createdAt: signed.createdAt,
        content: signed.content,
        sig: signed.sig,
        raw: jsonEncode(signed.toWireObject()),
        tagsJson: jsonEncode(signed.tags),
        tags: signed.tags,
      );
    } catch (_) {}
    ref.invalidate(muteListProvider(identity.pubkeyHex));
  }
  return ok;
}

/// A user's bookmarked note ids with origin (public vs private). NIP-51
/// kind-10003 (single global list) AND kind-30003 (labeled bookmark lists,
/// multi-instance — Amethyst uses these for named bookmark groups). Both
/// carry public `e` tags + NIP-44-encrypted private entries; we aggregate
/// across them. Amethyst-style loading: yields the SQLite-cached list
/// instantly (public `e` tags for anyone; plus the NIP-44-decrypted private
/// entries when [pubkey] is the logged-in user), then background-refreshes
/// from relays. Used by the profile's 收藏 section (DESIGN §8) — every
/// user's PUBLIC bookmarks show on their profile; private bookmarks only
/// render for the owner (others can't decrypt them). Entries are
/// origin-tagged so the tab can render 公开书签 / 私人书签 separately.
final bookmarksProvider = StreamProvider.family<List<BookmarkEntry>, String>((
  ref,
  pubkey,
) async* {
  final identity = await ref.watch(identityProvider.future);
  final isSelf = identity != null && identity.pubkeyHex == pubkey;
  // Only the owner can decrypt private entries; for others we pass
  // includePrivate=false (the decrypt would fail anyway, but skip the work).
  List<BookmarkEntry> entriesOf(Event? e) => identity != null
      ? NostrActions(identity).bookmarkEntries(e, includePrivate: isSelf)
      : const <BookmarkEntry>[];

  // Aggregate bookmark entries across the global kind-10003 + every
  // kind-30003 labeled list (deduped by note id; public wins on collision).
  List<BookmarkEntry> aggregate(Event? k10003, Map<String, Event> k30003) {
    final out = <BookmarkEntry>[];
    final seen = <String>{};
    void addAll(List<BookmarkEntry> es) {
      for (final e in es) {
        if (seen.add(e.id)) out.add(e);
      }
    }
    addAll(entriesOf(k10003));
    for (final e in k30003.values) {
      addAll(entriesOf(e));
    }
    return out;
  }

  String dOf(Event e) {
    for (final t in e.tags) {
      if (t.length >= 2 && t[0] == 'd' && t[1] is String) return t[1] as String;
    }
    return '';
  }

  // 1. SQLite cache (instant) — kind-10003 + all kind-30003, persisted by
  //    EventStoreNotifier's replaceable-kinds path.
  final cache = ref.read(localCacheProvider).value;
  Event? cachedK10003;
  final cachedK30003 = <String, Event>{}; // d → newest
  if (cache != null) {
    try {
      final row = await cache.queryReplaceable(pubkey, 10003);
      if (row != null) cachedK10003 = _replaceableToEvent(row);
      final rows30003 = await cache.queryReplaceableByAuthor(pubkey, 30003);
      for (final r in rows30003) {
        final e = _replaceableToEvent(r);
        final d = dOf(e);
        final prev = cachedK30003[d];
        if (prev == null || e.createdAt > prev.createdAt) cachedK30003[d] = e;
      }
    } catch (_) {}
  }
  var latest = aggregate(cachedK10003, cachedK30003);
  if (latest.isNotEmpty) yield List<BookmarkEntry>.unmodifiable(latest);

  // 2. Relay refresh — kinds [10003, 30003], newest per (kind|d).
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<List<BookmarkEntry>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(List<BookmarkEntry>.unmodifiable(latest));
      }
    });
  }

  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  Event? netK10003 = cachedK10003;
  final netK30003 = Map<String, Event>.from(cachedK30003);
  evSub = pool.rawEvents.listen((e) {
    if (e.pubkey != pubkey) return;
    if (e.kind == 10003) {
      if (netK10003 == null || e.createdAt > netK10003!.createdAt) {
        netK10003 = e;
        latest = aggregate(netK10003, netK30003);
        scheduleEmit();
      }
    } else if (e.kind == 30003) {
      final d = dOf(e);
      final prev = netK30003[d];
      if (prev == null || e.createdAt > prev.createdAt) {
        netK30003[d] = e;
        latest = aggregate(netK10003, netK30003);
        scheduleEmit();
      }
    }
  });
  final subId = nextSubId('bookmarks');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [10003, 30003],
    'limit': 50,
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 8), () {
    if (!done.isCompleted) done.complete();
  });
  done.future.whenComplete(() {
    flush?.cancel();
    if (dirty && !ctrl.isClosed) {
      ctrl.add(List<BookmarkEntry>.unmodifiable(latest));
    }
    if (!ctrl.isClosed) ctrl.close();
  });
  ref.onDispose(() {
    t.cancel();
    flush?.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (!ctrl.isClosed) ctrl.close();
  });
  yield* ctrl.stream;
});

/// The logged-in user's mute list (NIP-51 kind-10000). Amethyst stores public
/// mutes as plain tags (`p`/`word`/`t`/`e`) and private mutes as the same shape
/// NIP-44-encrypted in `.content`. Costr decrypts the owner's private entries
/// and unions them with the public tags → a [MuteSet] the feed filter + mute
/// UI consume. Yields the SQLite-cached list instantly, then refreshes from
/// relays. Family by pubkey; only the owner gets private entries.
final muteListProvider =
    StreamProvider.family<MuteSet, String>((ref, pubkey) async* {
  final identity = await ref.watch(identityProvider.future);
  final isSelf = identity != null && identity.pubkeyHex == pubkey;
  MuteSet muteSetOf(Event? e) => identity != null
      ? NostrActions(identity).muteSetOf(e, includePrivate: isSelf)
      : const MuteSet();

  // 1. SQLite cache (instant) — kind-10000 is persisted by EventStoreNotifier.
  final cache = ref.read(localCacheProvider).value;
  Event? cached;
  if (cache != null) {
    try {
      final row = await cache.queryReplaceable(pubkey, 10000);
      if (row != null) cached = _replaceableToEvent(row);
    } catch (_) {}
  }
  var latest = muteSetOf(cached);
  if (!latest.isEmpty) yield latest;

  // 2. Relay refresh — newest kind-10000 by createdAt.
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<MuteSet>();
  Event? newest = cached;
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  evSub = pool.rawEvents.listen((e) {
    if (e.kind != 10000 || e.pubkey != pubkey) return;
    if (newest == null || e.createdAt > newest!.createdAt) {
      newest = e;
      latest = muteSetOf(e);
      if (!ctrl.isClosed) ctrl.add(latest);
    }
  });
  final subId = nextSubId('mute');
  eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    if (!done.isCompleted) done.complete();
  });
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [10000],
    'limit': 1,
  }, closeOnEose: true);
  final t = Timer(const Duration(seconds: 8), () {
    if (!done.isCompleted) done.complete();
  });
  done.future.whenComplete(() {
    if (!ctrl.isClosed) ctrl.add(latest);
    if (!ctrl.isClosed) ctrl.close();
  });
  ref.onDispose(() {
    t.cancel();
    evSub.cancel();
    eoseSub.cancel();
    pool.closeSubscription(subId);
    if (!ctrl.isClosed) ctrl.close();
  });
  yield* ctrl.stream;
});

/// Convenience: the logged-in user's [MuteSet] (empty if logged out). Watches
/// [muteListProvider] for the current identity's pubkey. Used by the feed
/// filter + mute UI to hide muted content.
final myMuteSetProvider = Provider<MuteSet>((ref) {
  final id = ref.watch(identityProvider).value;
  if (id == null) return const MuteSet();
  final async = ref.watch(muteListProvider(id.pubkeyHex));
  return async.value ?? const MuteSet();
});

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

  // 3. Async refresh: query the DEFAULT pool and the INDEXER pool CONCURRENTLY
  //    for kind-0. The default pool catches users whose metadata is on a
  //    connected relay but outside the global-feed window (tier 2); the
  //    indexer relays aggregate ALL users' kind-0 and recover users not on
  //    any default relay (Amethyst's "widen to indexers when connected relays
  //    are exhausted" pattern). Both REQs fire at once so a slow/stuck
  //    multiplexer in the default pool can't block the indexer's response —
  //    the first pool to answer wins. The stream ENDS on the indexer's EOSE
  //    (it's the comprehensive aggregator — if it EOSEs empty, give up fast
  //    rather than wait for a stuck default relay) or an 8s safety cap per
  //    pool, whichever first. So a hit lands in ~1–2s and a confirmed miss
  //    also resolves in ~1–2s, not 8s.
  final defaultPool = ref.read(relayPoolProvider);
  final indexerPool = ref.read(indexerPoolProvider);
  final ctrl = StreamController<Metadata?>();

  var anyHit = false;

  void onMetaEvent(Event e) {
    if (e.kind != 0 || e.pubkey != pubkey) return;
    try {
      final json = jsonDecode(e.content);
      if (json is! Map<String, dynamic>) return;
      if (e.createdAt < cachedCreatedAt) return; // don't regress to older.
      cachedCreatedAt = e.createdAt;
      anyHit = true;
      // Persist the newer kind-0 to SQLite so the NEXT cold start reads it
      // instantly (tier-1) instead of regressing to the stale cache. This
      // matters for metadata that arrives via the INDEXER pool: the
      // EventStoreNotifier only listens to the default pool, so without this
      // an indexer-only kind-0 would never land in SQLite and the avatar
      // would revert to the old cache on every cold start.
      final db = cache;
      if (db != null) {
        unawaited(db.writeEvent(
          id: e.id,
          pubkey: e.pubkey,
          kind: 0,
          createdAt: e.createdAt,
          content: e.content,
          sig: e.sig,
          raw: jsonEncode(e.toWireObject()),
          tagsJson: jsonEncode(e.tags),
          tags: e.tags,
        ));
      }
      ctrl.add(Metadata.fromJson(json));
    } catch (_) {
      // Malformed metadata content — ignore, keep waiting for EOSE.
    }
  }

  StreamSubscription<Event>? defSub, idxSub;
  StreamSubscription<String>? defEose, idxEose;
  Timer? defTimer, idxTimer;
  var closed = false;

  void teardown() {
    defSub?.cancel();
    idxSub?.cancel();
    defEose?.cancel();
    idxEose?.cancel();
    defTimer?.cancel();
    idxTimer?.cancel();
  }

  // Cold-miss fallback: query the user's OWN NIP-65 outbox relays for kind-0.
  // Users whose metadata lives only on their outbox relays — and isn't cached
  // in either the default pool or an indexer — would otherwise resolve null
  // and their avatar would stay on the initial-letter fallback forever
  // (Amethyst's "widen to the author's own relays when indexers are
  // exhausted" pattern). fetchFromUrls opens TRANSIENT connections, so this
  // never pollutes the pool's persistent subscriptions.
  Future<void> tryOutboxFallback() async {
    if (anyHit || cached != null || ctrl.isClosed) {
      if (!ctrl.isClosed) {
        if (!anyHit && cached == null) ctrl.add(null);
        ctrl.close();
      }
      return;
    }
    try {
      final rl = await ref.read(userRelayListProvider(pubkey).future);
      final readUrls = rl?.read ?? const <String>[];
      if (readUrls.isNotEmpty) {
        await defaultPool.fetchFromUrls(
          <String, dynamic>{
            'authors': [pubkey],
            'kinds': [0],
            'limit': 1,
          },
          readUrls,
          onEvent: onMetaEvent,
        );
      }
    } catch (_) {
      // Relay-list fetch or outbox REQ failed — fall through to resolve.
    }
    // Resolve: onMetaEvent already emitted any found metadata (anyHit=true);
    // emit null for a confirmed miss, then close.
    if (!ctrl.isClosed) {
      if (!anyHit && cached == null) ctrl.add(null);
      ctrl.close();
    }
  }

  void closeAll() {
    if (closed) return;
    closed = true;
    teardown();
    if (!anyHit && cached == null) {
      // Cold miss across the default + indexer pools — try the user's own
      // outbox relays before giving up. Async; resolves the stream when done.
      unawaited(tryOutboxFallback());
      return;
    }
    if (!ctrl.isClosed) ctrl.close();
  }

  // Default pool phase.
  defSub = defaultPool.rawEvents.listen(onMetaEvent);
  final defId = nextSubId('meta');
  defaultPool.request(defId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [0],
    'limit': 1,
  }, closeOnEose: true);
  defEose = defaultPool.eoseStream.where((s) => s == defId).listen((_) {
    // Default pool done. Only stop early if it found NEWER metadata
    // (anyHit). Do NOT short-circuit on a stale SQLite cache (`cached !=
    // null`) — that would tear down the indexer REQ before the
    // comprehensive aggregator can return the user's *latest* kind-0 (it
    // often has metadata the default pool lacks). The old short-circuit
    // left the avatar stuck on the stale cache for the whole first cold
    // start of a new app version (the global-feed subscription only
    // persisted the newer kind-0 in the background, so it took a second
    // cold start to appear).
    if (anyHit) closeAll();
  });
  defTimer = Timer(const Duration(seconds: 8), () {
    if (anyHit) closeAll();
  });

  // Indexer phase (concurrent). Its EOSE ends the lookup — it's the
  // comprehensive aggregator, so an empty EOSE means "give up" (modulo the
  // outbox fallback above).
  idxSub = indexerPool.rawEvents.listen(onMetaEvent);
  final idxId = nextSubId('metaidx');
  indexerPool.request(idxId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [0],
    'limit': 1,
  }, closeOnEose: true);
  idxEose = indexerPool.eoseStream
      .where((s) => s == idxId)
      .listen((_) => closeAll());
  idxTimer = Timer(const Duration(seconds: 8), closeAll);

  ref.onDispose(() {
    closed = true;
    teardown();
    if (!ctrl.isClosed) ctrl.close();
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
  pool.request(subId, <String, dynamic>{
    'authors': [pubkey],
    'kinds': [Event.kindUserStatus],
    '#d': ['general'],
    'limit': 1,
  }, closeOnEose: true);
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
