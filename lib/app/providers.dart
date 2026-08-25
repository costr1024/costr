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
import '../nostr/global_feed_window.dart';
import '../nostr/identity.dart';
import '../nostr/interaction_cache.dart';
import '../nostr/outbox_router.dart';
import '../nostr/relay_client.dart';
import '../nostr/relay_pool.dart';
import '../services/account_registry.dart';
import '../services/local_cache.dart' as cache;
import '../services/blossom_upload.dart';
import '../services/link_preview.dart';
import '../services/secure_storage_service.dart';
import '../services/server_discovery.dart';
import 'server_list_rules.dart';
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
  'wss://nostr.data.haus/',
  'wss://relay.momostr.pink/',
  'wss://relay.nostr.net/',
  'wss://relay.0xchat.com/',
  'wss://top.testrelay.top/',
];

// Order-insensitive server-list equality lives in server_list_rules.dart
// ([sameServerSet]) so the save path and the kind-10002 sync-marker compare
// share ONE normalization.

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

/// The user's configured server lists — the editable source of truth, seeded
/// from the code constants on first run and persisted in the SQLite config
/// table (device-level keys: ALL accounts on this device share the same
/// lists). Relay changes are published to Nostr as kind 10002 (per account);
/// Blossom changes stay purely local (kind 10063 deliberately not
/// implemented). The 服务器节点 page, the relay/search/indexer pools and the
/// blossom upload path all read from here.
class ServerLists {
  const ServerLists({
    required this.relays,
    required this.search,
    required this.indexer,
    required this.blossom,
  });
  final List<String> relays;
  final List<String> search;
  final List<String> indexer;
  final List<String> blossom;

  List<String> of(ServerCategory category) {
    switch (category) {
      case ServerCategory.relay:
        return relays;
      case ServerCategory.search:
        return search;
      case ServerCategory.indexer:
        return indexer;
      case ServerCategory.blossom:
        return blossom;
    }
  }
}

final serverListsProvider = FutureProvider<ServerLists>((ref) async {
  final db = await ref.read(localCacheProvider.future);
  Future<List<String>> load(
    ServerCategory category,
    List<String> defaults,
  ) async {
    final stored = await db.readServerList(serverListKeys[category]!);
    if (stored != null && stored.isNotEmpty) return stored;
    // Seed ONLY when absent. Deliberately NOT resetting when the stored list
    // diverges from the constants (the pre-edit-UI behavior): the lists are
    // user-editable now, and silently overwriting a customization on every
    // launch would defeat the feature. Accepted tradeoff: default-list
    // changes shipped in an app update no longer reach existing users — a
    // permanently-dead default server shows a red 离线 on the node page and
    // the user can swap it via the 自定义 sheet.
    final seeded = normalizeServerList(defaults);
    await db.writeServerList(serverListKeys[category]!, seeded);
    return seeded;
  }

  return ServerLists(
    relays: await load(ServerCategory.relay, defaultRelays),
    search: await load(ServerCategory.search, searchRelays),
    indexer: await load(ServerCategory.indexer, indexerRelays),
    blossom: await load(ServerCategory.blossom, blossomServersConst),
  );
});

// Re-export the Blossom server list constant (defined in
// services/blossom_upload.dart) so serverListsProvider can seed the local
// cache without callers needing to import the upload module directly.
const List<String> blossomServersConst = blossomServers;

/// The built-in server list for [category] — what the customize sheet's
/// 「恢复默认」 restores. Kept here (not in server_list_rules.dart) because
/// the constants live in this layer.
List<String> defaultServerListFor(ServerCategory category) {
  switch (category) {
    case ServerCategory.relay:
      return defaultRelays;
    case ServerCategory.search:
      return searchRelays;
    case ServerCategory.indexer:
      return indexerRelays;
    case ServerCategory.blossom:
      return blossomServersConst;
  }
}

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

/// Case variants of a hashtag for a `#t` relay REQ. Relays match `t`-tag
/// values CASE-SENSITIVELY (NIP-12 only RECOMMENDS lowercase), and real posts
/// tag inconsistently (`#Nostr` / `#nostr` / `#NOSTR`). Querying all variants
/// (Amethyst `hashtagAlts` pattern) avoids silently missing posts. Deduped,
/// order-stable: original, lowercase, UPPERCASE, Capitalized.
List<String> hashtagAlts(String tag) {
  final capitalized = tag.isEmpty
      ? tag
      : tag[0].toUpperCase() + tag.substring(1);
  final out = <String>[];
  final seen = <String>{};
  for (final v in [tag, tag.toLowerCase(), tag.toUpperCase(), capitalized]) {
    if (v.isNotEmpty && seen.add(v)) out.add(v);
  }
  return out;
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

// --- Accounts + Identity -----------------------------------------------------

final storageProvider = Provider<SecureStorageService>((ref) {
  final svc = SecureStorageService(const FlutterSecureStorage());
  ref.onDispose(svc.dispose);
  return svc;
});

/// The device's logged-in account set (multi-account registry). Many accounts
/// stored, ONE active — only the active account drives connections, feeds and
/// notifications (switching rebuilds the reactive identity chain; it does NOT
/// add parallel per-account connections). Persisted as a single secure-storage
/// blob (`costr.accounts.v1`); the legacy single-nsec key is migrated on first
/// run.
class AccountsNotifier extends AsyncNotifier<AccountSet> {
  @override
  Future<AccountSet> build() async {
    final s = ref.read(storageProvider);
    try {
      final stored = await s.readAccounts();
      if (stored != null) return stored;
      // One-time migration from the legacy single-nsec storage (pre-multi-
      // account builds kept exactly one nsec under `costr.identity.nsec`).
      final legacy = await s.readNsec();
      if (legacy != null) {
        await s.deleteNsec();
        try {
          final id = Identity.fromNsec(legacy);
          final migrated = const AccountSet().upsert(
            AccountEntry.fromIdentity(id),
            activate: true,
          );
          await s.writeAccounts(migrated);
          return migrated;
        } catch (_) {
          // Invalid legacy nsec — drop it, end up logged out.
        }
      }
      return const AccountSet();
    } catch (_) {
      // Storage unavailable — never wedge startup; behave as logged out.
      return const AccountSet();
    }
  }

  /// Add (or re-add) an account and make it active.
  Future<AccountSet> addAccount(Identity identity) => _commit(
    (cur) => cur.upsert(AccountEntry.fromIdentity(identity), activate: true),
  );

  /// Switch the active account to an already-stored pubkey.
  Future<AccountSet> setActive(String pubkeyHex) =>
      _commit((cur) => cur.withActive(pubkeyHex));

  /// Remove an account from the device. Removing the active account activates
  /// the next remaining one (or logs out entirely).
  Future<AccountSet> removeAccount(String pubkeyHex) =>
      _commit((cur) => cur.remove(pubkeyHex));

  Future<AccountSet> _commit(AccountSet Function(AccountSet) op) async {
    final cur = state.value ?? const AccountSet();
    final next = op(cur);
    if (next == cur) return next;
    await ref.read(storageProvider).writeAccounts(next);
    state = AsyncData(next);
    return next;
  }
}

final accountsProvider = AsyncNotifierProvider<AccountsNotifier, AccountSet>(
  AccountsNotifier.new,
);

/// The ACTIVE identity, derived from [accountsProvider]. All writes to
/// identity state go through the account registry so storage and state can't
/// diverge. Downstream the app reacts to identity changes reactively (feed
/// subscriptions, follows, notifications are all keyed/watched on this), so
/// switching accounts = updating this one provider.
class IdentityNotifier extends AsyncNotifier<Identity?> {
  @override
  Future<Identity?> build() async {
    final set = await ref.watch(accountsProvider.future);
    return _identityOf(set);
  }

  Identity? _identityOf(AccountSet set) {
    final active = set.active;
    if (active == null) return null;
    try {
      return Identity.fromNsec(active.nsec);
    } catch (_) {
      // Stored nsec invalid — treat as logged out.
      return null;
    }
  }

  /// Log in with an nsec: adds the account to the registry (or re-activates
  /// it when already stored) and makes it active. Throws [FormatException]
  /// on an invalid key.
  Future<void> login(String nsec) async {
    final identity = Identity.fromNsec(nsec); // throws on invalid
    await ref.read(accountsProvider.notifier).addAccount(identity);
    // Set state synchronously so navigation right after login sees the new
    // identity (the watch-driven rebuild lands on the same value and is a
    // no-op).
    state = AsyncData(identity);
    // NIP-65: publish this account's relay list right after login (the
    // cold-start publish only fires for an already-stored identity). A fresh
    // account has no sync marker, so this publishes the device's current
    // (user-editable) list and records the marker on success.
    _syncRelayListBg(identity);
  }

  /// Switch to another stored account.
  Future<void> switchTo(String pubkeyHex) async {
    final set = await ref.read(accountsProvider.notifier).setActive(pubkeyHex);
    state = AsyncData(_identityOf(set));
    // The relay list is device-global but kind 10002 is per-account: if the
    // list changed while this account was dormant, catch up now — the marker
    // compare publishes only when something actually differs.
    final switched = state.value;
    if (switched != null) _syncRelayListBg(switched);
  }

  /// Remove an account (its nsec leaves this device). When it was the active
  /// one, the next stored account becomes active — or identity becomes null.
  Future<void> removeAccount(String pubkeyHex) async {
    final set = await ref
        .read(accountsProvider.notifier)
        .removeAccount(pubkeyHex);
    state = AsyncData(_identityOf(set));
    // Best-effort cleanup of the removed account's kind-10002 sync marker.
    // Fire-and-forget; never block removal on the DB.
    () async {
      try {
        final db = await ref.read(localCacheProvider.future);
        await db.deleteConfig(relayListSyncedKey(pubkeyHex));
      } catch (_) {}
    }();
  }

  /// Fire-and-forget kind-10002 catch-up for [identity]: publishes the
  /// device's current relay list under this account when it differs from the
  /// account's last-published list (the sync marker). ALL DB access is
  /// unawaited + guarded — login/switchTo/removeAccount stay callable in test
  /// containers that don't override [localCacheProvider] (which would throw
  /// MissingPluginException from path_provider). The list is read from the DB
  /// (the source of truth), NOT from serverListsProvider's cached value —
  /// after a save the provider may still be mid-rebuild with a stale value.
  void _syncRelayListBg(Identity identity) {
    () async {
      try {
        final db = await ref.read(localCacheProvider.future);
        final relays =
            (await db.readServerList(serverListKeys[ServerCategory.relay]!)) ??
            defaultRelays;
        await syncRelayListForAccount(
          ref.read(relayPoolProvider),
          db,
          identity,
          relays,
        );
      } catch (_) {
        // No DB (tests) or a transient error — the marker is only written on
        // success, so the next switch/login/cold-start retries automatically.
      }
    }();
  }

  /// Log out of the active account (removes its nsec from this device); the
  /// next stored account becomes active when there is one. Local cache data
  /// (posts, metadata) is kept.
  Future<void> logout() async {
    final me = state.value?.pubkeyHex;
    if (me == null) return;
    await removeAccount(me);
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

/// Pure list transform behind [_migrateWheatRelayOnce]: returns [stored]
/// UNCHANGED (same instance) when it has no wheat, else a repaired copy with
/// wheat swapped for nostr.data.haus in place and relay.momostr.pink appended
/// when there is room. Kept pure + `@visibleForTesting` so the swap is
/// unit-testable without a DB/Riverpod container.
@visibleForTesting
List<String> migrateWheatRelayList(List<String> stored) {
  const wheat = 'wss://wheat.happytavern.co';
  const dataHaus = 'wss://nostr.data.haus';
  const momostr = 'wss://relay.momostr.pink';
  final relays = stored.map(normalizeServerUrl).toList();
  final i = relays.indexOf(wheat);
  if (i < 0) return stored; // nothing to repair
  relays[i] = dataHaus;
  if (!relays.contains(momostr) && relays.length < maxServersPerCategory) {
    relays.add(momostr);
  }
  return relays;
}

/// One-shot repair of a stored relay list that still contains the dead relay
/// `wss://wheat.happytavern.co` (it now rejects this device's writes with
/// "blocked: pubkey is blacklisted"). Applies [migrateWheatRelayList]. Every
/// other entry is preserved — a list the user customized (that no longer has
/// wheat) is left untouched. Must run BEFORE [serverListsProvider] is first
/// read so the pool connects to the repaired list; guarded so a failure can
/// never wedge startup.
Future<void> _migrateWheatRelayOnce(Ref ref) async {
  const marker = 'relay_list_wheat_migrated_v1';
  try {
    final db = await ref.read(localCacheProvider.future);
    if (await db.readConfig(marker) == '1') return;
    final key = serverListKeys[ServerCategory.relay]!;
    final stored = await db.readServerList(key);
    if (stored != null) {
      final migrated = migrateWheatRelayList(stored);
      if (!identical(migrated, stored)) {
        await db.writeServerList(key, migrated);
        // Drop the cached value (if any) so the next read sees the repair.
        ref.invalidate(serverListsProvider);
      }
    }
    await db.writeConfig(marker, '1');
  } catch (_) {
    // Best-effort: never block startup on the migration.
  }
}

Future<void> _runBootstrap(Ref ref) async {
  await ref.watch(identityProvider.future);
  final pool = ref.read(relayPoolProvider);
  // One-shot relay-list repair, BEFORE the persisted list is read below:
  // wheat.happytavern.co started rejecting this device's writes
  // ("blocked: pubkey is blacklisted"), so swap it for nostr.data.haus and
  // add relay.momostr.pink (both verified read+write). Existing installs keep
  // their stored list otherwise — this only touches the dead relay.
  await _migrateWheatRelayOnce(ref);
  // Apply the user's persisted server lists BEFORE the first connect:
  // updateUrls on a never-connected pool is a pure list swap, so the pool
  // then connects to exactly what the user configured. Reading the pools here
  // also force-builds the lazy search/indexer pools so their updateUrls lands
  // now — a pool first built later would be built from the constants and miss
  // the user's list entirely.
  final lists = await ref.read(serverListsProvider.future);
  await pool.updateUrls(lists.relays);
  await ref.read(searchPoolProvider).updateUrls(lists.search);
  await ref.read(indexerPoolProvider).updateUrls(lists.indexer);
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
  // Per-relay WRITE success-rate statistics (服务器节点 page flags relays
  // whose writes keep failing and suggests replacing them): persist every
  // explicit publish verdict. `ok` is the EFFECTIVE outcome (accepted, or a
  // NIP-20 duplicate — the event is stored either way); NIP-42 auth-required
  // rejections never arrive here (transient handshake, retried automatically).
  // Reads are deliberately never measured — a relay that accepts writes can
  // almost always be read from. Only the main pool publishes (search/indexer
  // pools are REQ-only). The raw rejection reason is also kept so the node
  // page can show WHY a relay keeps failing (blocked / rate-limited / …).
  pool.onWriteVerdict = (url, ok, reason) {
    final db = ref.read(localCacheProvider).value;
    if (db != null) {
      unawaited(db.pushWriteSample(url, ok).catchError((Object _) {}));
      // Keep the freshest rejection reason for diagnostics; an accepted
      // write clears it so a recovered relay isn't shown a stale «why».
      unawaited(
        db
            .setWriteRejectReason(url, ok ? '' : (reason ?? ''))
            .catchError((Object _) {}),
      );
    }
  };
  // One-shot upgrade cleanup: write samples recorded before the NIP-42 /
  // duplicate normalization fix counted auth handshakes as failures
  // (healthy auth-gated relays showed a falsely-low 发帖成功率). Clear them
  // once so the stale false alarm doesn't survive into the fixed build.
  try {
    final db = await ref.read(localCacheProvider.future);
    if (await db.readConfig('write_stats_v2_cleared') != '1') {
      await db.clearWriteStats();
      await db.writeConfig('write_stats_v2_cleared', '1');
    }
  } catch (_) {
    // No DB → nothing to migrate.
  }
  // NIP-65: publish our relay list (kind 10002) in the background so other
  // clients can discover the author's relays (outbox/inbox model). Fire-and-
  // forget — must not block the router. kind 10002 is replaceable, so
  // re-publishing on every cold start just replaces the prior list; the
  // unconditional resend also repairs relays that lost the event. The sync
  // marker is updated on success so account switches don't re-publish
  // needlessly. Publishes the USER's persisted list (not the code constant).
  final identity = ref.read(identityProvider).value;
  if (identity != null) {
    unawaited(
      publishRelayList(pool, identity, lists.relays).then((ok) async {
        if (!ok) return;
        try {
          final db = await ref.read(localCacheProvider.future);
          await db.writeServerList(
            relayListSyncedKey(identity.pubkeyHex),
            lists.relays,
          );
        } catch (_) {}
      }),
    );
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
  // ALL logged-in accounts' posts are exempt — not just the active one — so
  // switching to a dormant account doesn't surface dead notification links.
  Timer(const Duration(seconds: 30), () async {
    final cache = ref.read(localCacheProvider).value;
    if (cache == null) return;
    try {
      final accounts = ref.read(accountsProvider).value;
      final ownPubkeys = <String>{
        for (final a in accounts?.accounts ?? const <AccountEntry>[])
          a.pubkeyHex,
      };
      await cache.cleanupOldEvents(ttlDays: 30, ownPubkeys: ownPubkeys);
      await cache.enforceSizeCap();
      await cache.vacuum();
    } catch (_) {}
  });
}

/// Sign + publish [identity]'s NIP-65 relay list (kind 10002) with [relays]
/// to [pool]. Returns whether any relay accepted the event. Callers that
/// don't care may still treat it as fire-and-forget; kind 10002 is
/// replaceable, so a failed publish is harmless (retried on the next
/// switch/login/cold start via the sync marker).
Future<bool> publishRelayList(
  RelayPool pool,
  Identity identity,
  List<String> relays,
) async {
  final signed = NostrActions(identity).relayList(relays);
  final ok = await pool.publishAndWait(signed);
  return ok.ok;
}

/// Config key of an account's kind-10002 sync marker: the relay list that
/// account last SUCCESSFULLY published. Device-global relay lists + per-
/// account kind-10002 events need this bridge so accounts activated later
/// catch up exactly once.
String relayListSyncedKey(String pubkeyHex) => 'relay_list_synced:$pubkeyHex';

/// Publish a fresh kind 10002 for [identity] when the device's current relay
/// list [relays] differs from what this account last published (its sync
/// marker). The marker is written ONLY after a successful publish, so a
/// failure retries automatically on the next activation.
Future<void> syncRelayListForAccount(
  RelayPool pool,
  cache.LocalCache db,
  Identity identity,
  List<String> relays,
) async {
  final markerKey = relayListSyncedKey(identity.pubkeyHex);
  final synced = await db.readServerList(markerKey);
  if (synced != null && sameServerSet(synced, relays)) return;
  final ok = await publishRelayList(pool, identity, relays);
  if (ok) {
    await db.writeServerList(markerKey, relays);
  }
}

/// Persist a user-edited server list for [category], apply it to the matching
/// live pool (relay/search/indexer — blossom has none), and for the relay
/// category publish a fresh kind 10002 under the active account (other stored
/// accounts catch up when they are activated). UI entry point only: assumes
/// bootstrap already ran (DB + pools ready).
Future<void> saveServerList(
  WidgetRef ref,
  ServerCategory category,
  List<String> urls,
) async {
  final clean = normalizeServerList(urls);
  if (clean.length < minServersFor(category) ||
      clean.length > maxServersPerCategory) {
    throw StateError('服务器数量超出允许范围');
  }
  final db = await ref.read(localCacheProvider.future);
  await db.writeServerList(serverListKeys[category]!, clean);
  switch (category) {
    case ServerCategory.relay:
      await ref.read(relayPoolProvider).updateUrls(clean);
    case ServerCategory.search:
      await ref.read(searchPoolProvider).updateUrls(clean);
    case ServerCategory.indexer:
      await ref.read(indexerPoolProvider).updateUrls(clean);
    case ServerCategory.blossom:
      break; // No pool; the upload path reads the list on demand.
  }
  ref.invalidate(serverListsProvider);
  if (category == ServerCategory.relay) {
    final identity = ref.read(identityProvider).value;
    if (identity != null) {
      try {
        await syncRelayListForAccount(
          ref.read(relayPoolProvider),
          db,
          identity,
          clean,
        );
      } catch (_) {
        // The list is already persisted + applied locally; the kind-10002
        // catch-up retries on the next activation/cold start.
      }
    }
  }
}

/// The Blossom servers to upload to: the user's persisted list, falling back
/// to the built-in constant when the cache is unreadable — a broken DB must
/// not break posting.
Future<List<String>> currentBlossomServers(WidgetRef ref) async {
  try {
    final lists = await ref.read(serverListsProvider.future);
    return lists.blossom.isEmpty ? blossomServersConst : lists.blossom;
  } catch (_) {
    return blossomServersConst;
  }
}

/// Decentralized server recommendations for the customize sheet — candidates
/// come from the user's own view of the network (cached/live kind-10002 +
/// kind-10063 lists) and every candidate is probed before being recommended
/// (see services/server_discovery.dart). Empty = nothing recommendable; the
/// sheet hides the block. Indexer has no recommendations this iteration.
Future<List<String>> recommendServers(
  WidgetRef ref,
  ServerCategory category, {
  bool force = false,
}) async {
  final db = await ref.read(localCacheProvider.future);
  final pool = ref.read(relayPoolProvider);
  final identity = ref.read(identityProvider).value;
  final discovery = ServerDiscovery(
    db: db,
    pool: pool,
    identity: identity,
    makeClient: pool.makeClient,
  );
  return discovery.recommend(category, force: force);
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
  // Resolved-until-build replaces it: notifiers whose build() skips _hydrate
  // (test stubs) never block awaiters of [hydrated].
  Completer<void> _hydrated = Completer<void>()..complete();

  /// Active-account pubkey at the last [build]. A change (account switch /
  /// login / logout) forces a store reset so the previous account's feed
  /// residue (esp. following-mode events) never leaks into the new feed.
  String? _builtForAccount;

  /// Hydration generation: a rebuild (account switch) invalidates any
  /// in-flight hydration so a stale one can't complete the NEW [hydrated]
  /// early or add rows after the reset.
  int _hydrateGen = 0;

  /// The backing store. Test stubs that drive [build] from their own
  /// store/list override this so the revision getters + [byId] see the same
  /// events the UI does.
  @visibleForTesting
  EventStore get store => _store;

  /// kind-1/6 content revision of the held set — see
  /// [EventStore.contentRevision]. The revision providers below re-read it on
  /// every flush but only NOTIFY dependents when it actually changed, so
  /// kind-7 firehose churn stops rebuilding the feed.
  int get contentRevision => store.contentRevision;

  /// kind-1/6/7 interaction revision — see [EventStore.interactionRevision].
  int get interactionRevision => store.interactionRevision;

  /// O(1) live-store lookup (delegates to [EventStore.byId]). Replaces the
  /// O(n) list scans call sites used to fall back on while an async
  /// event-by-id lookup was still in flight (feed reply-context headers).
  Event? byId(String id) => store.byId(id);

  /// Newest-known kind-0 per pubkey — the store's EVICTION-PROOF metadata
  /// index (see [EventStore.metadataByPubkey]). Over-cap eviction drops a
  /// kind-0 from the capped list but never from this index, so @-mention
  /// candidates keep resolving names for the whole session.
  Map<String, Event> get metadataByPubkey => store.metadataByPubkey;

  /// Resolves when the cold-start SQLite hydration has finished (or failed).
  /// Awaiters (notification classification) must not judge events before the
  /// own-post snapshot lands — judging against an empty store yields different
  /// notification ids per launch ("已读通知复活" bug).
  Future<void> get hydrated => _hydrated.future;

  @override
  List<Event> build() {
    _disposed = false;
    // Account switch (or login/logout) → wipe the in-memory feed BEFORE
    // re-hydrating: the store holds per-account content (following feed,
    // own reactions) that must not carry over between accounts.
    final accountKey = ref.watch(
      identityProvider.select((v) => v.value?.pubkeyHex),
    );
    if (_builtForAccount != accountKey) {
      _builtForAccount = accountKey;
      _store.clear();
      // Never leave awaiters of the previous [hydrated] hanging.
      if (!_hydrated.isCompleted) _hydrated.complete();
    }
    // Hydrate from SQLite (async — fills store as data arrives).
    _hydrateGen++;
    _hydrated = Completer<void>();
    _hydrate(_hydrated, _hydrateGen);
    final pool = ref.watch(relayPoolProvider);
    _sub = pool.events.listen((e) {
      // Immutable feed events (kind 0/1/6/7) → in-memory store + persist
      // (social-graph gated for kind 1/7 inside _persist).
      if (e.kind == 0 || e.isTextNote || e.isRepost || e.kind == 7) {
        if (_store.add(e)) {
          _persist(e);
          _scheduleFlush();
        }
        // Eviction-PROOF copy of interactions (kind 6/16 reposts, kind 7
        // reactions) AND replies (kind 1): the capped store evicts kind-7
        // FIRST (then 0, 6, and finally 1), so a like delivered by a
        // long-lived sub (the notifications #e REQ, the following feed) dies
        // ~25ms after arrival on a saturated feed — the notification center
        // showed it, but the post's detail page / chevron found nothing
        // ("通知里有点赞提醒，点进去看不到"). Replies evict last but still go
        // on a long-lived busy feed, which dropped the feed reply COUNT
        // ("信息流回复计数"). Ingest every arriving interaction/reply into the
        // cache too, regardless of which subscription carried it. The merged
        // stream never contains the routed global firehose, so the cache's
        // "never the firehose" invariant holds; its LRU caps (200 targets ×
        // 500) bound memory. Top-level kind-1 posts (no e tags) are skipped
        // inside ingest — only replies key onto a target.
        if (e.kind == 1 ||
            e.kind == 6 ||
            e.kind == 7 ||
            e.kind == Event.kindGenericRepost) {
          if (!_disposed) {
            ref.read(interactionCacheProvider.notifier).ingest([e]);
          }
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
            // FollowingNotifier / buildFeedFilter read from. Newest-wins:
            // different relays serve different kind-3 revisions and deliver
            // them out of order — a stale revision arriving after a newer
            // one must not revert the follows list.
            final prevContact = ref.read(contactListCacheProvider);
            if (prevContact == null || e.createdAt > prevContact.createdAt) {
              ref.read(contactListCacheProvider.notifier).set(e);
            }
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
  Future<void> _hydrate(Completer<void> hydrated, int gen) async {
    _cache = ref.read(localCacheProvider).value;
    if (_cache == null) {
      ref.listen(localCacheProvider, (_, next) {
        if (gen != _hydrateGen) return; // superseded by an account switch
        if (next.hasValue && _cache == null) {
          _cache = next.value;
          _doHydrate(hydrated, gen);
        } else if (next.hasError) {
          // DB open failed — never leave awaiters of [hydrated] hanging.
          if (!hydrated.isCompleted) hydrated.complete();
        }
      });
      return;
    }
    await _doHydrate(hydrated, gen);
  }

  Future<void> _doHydrate(Completer<void> hydrated, int gen) async {
    final db = _cache;
    if (db == null) {
      if (!hydrated.isCompleted) hydrated.complete();
      return;
    }
    try {
      // Kind-1 feed (1000 newest — deep enough that a relaunch restores the
      // depth the user had scrolled to (load-more pages are persisted by
      // _persist), instead of dumping them back at the newest 200)
      final feedRows = await db.queryFeed(limit: 1000);
      if (gen != _hydrateGen || _disposed) return;
      for (final row in feedRows) {
        _store.add(_cacheRowToEvent(row));
      }
      // Kind-7 reactions (500 newest)
      final reactionRows = await db.queryRecentReactions(limit: 500);
      if (gen != _hydrateGen || _disposed) return;
      for (final row in reactionRows) {
        _store.add(_cacheRowToEvent(row));
      }
      // Kind-0 metadata (all cached)
      final metaRows = await db.queryAllMetadata();
      if (gen != _hydrateGen || _disposed) return;
      for (final row in metaRows) {
        _store.add(_replaceableRowToEvent(row));
      }
      if (_store.length > 0) {
        // Emit the hydrated snapshot NOW (not via the 200ms debounce): the
        // feed shows cached content instantly, and awaiters of [hydrated]
        // read a state that already carries the own-post snapshot.
        _dirty = true;
        flushNow();
      }
    } catch (_) {
      // Hydration failure — continue with empty store, relays will fill it.
    } finally {
      if (gen == _hydrateGen && !hydrated.isCompleted) hydrated.complete();
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
        // The interaction cache may still hold what the store already evicted
        // (kind-7 evicts first on a saturated firehose) — drop it there too,
        // with the same authorship gate checked against the cached copy.
        if (!_disposed) {
          ref
              .read(interactionCacheProvider.notifier)
              .removeEvent(id, where: (e) => e.pubkey == del.pubkey);
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

  /// Flush any pending batched emission NOW. Callers that compare `state`
  /// against what was just ingested (feed load-more's did-the-feed-grow
  /// check) would otherwise race the 200ms debounce and read a stale list.
  void flushNow() {
    _flush?.cancel();
    _flush = null;
    if (_dirty) {
      _dirty = false;
      state = _store.events;
    }
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

final proxyMediaEnabledProvider = NotifierProvider<ProxyMediaNotifier, bool>(
  ProxyMediaNotifier.new,
);

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

final immersiveBrowseProvider = NotifierProvider<ImmersiveBrowseNotifier, bool>(
  ImmersiveBrowseNotifier.new,
);

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

final appBarsVisibleProvider = NotifierProvider<AppBarsVisibleNotifier, bool>(
  AppBarsVisibleNotifier.new,
);

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
/// group (client-side narrowing of the already-loaded following feed — no
/// extra relay REQ, instant); `tag:<tag>` = the hashtag's OWN timeline:
/// [tagTimelineFeedProvider] broadcasts a live `#t` REQ and the feed shows
/// matching posts from ANY author (Amethyst pattern; relays without `#t`
/// support simply return nothing). Persisted to config
/// (`following_filter:<pubkey>`, PER-ACCOUNT — each account keeps its own
/// selection) so a relaunch keeps the last selection (DESIGN §8
/// follow-list feed switcher, Amethyst PeopleList).
final savedFollowingFilterProvider = FutureProvider<String?>((ref) async {
  final me = ref.watch(identityProvider.select((v) => v.value?.pubkeyHex));
  if (me == null) return null;
  final cache = await ref.read(localCacheProvider.future);
  final v = await cache.readConfig('following_filter:$me');
  return (v == null || v.isEmpty) ? null : v;
});

class FollowingFilterNotifier extends Notifier<String?> {
  @override
  String? build() {
    // Default to 全部关注 until the persisted value loads; rebuilds (snapping
    // to the saved filter) once [savedFollowingFilterProvider] resolves.
    // asData (not .value): during the per-account reload after a switch the
    // previous account's filter must not leak through.
    return ref.watch(savedFollowingFilterProvider).asData?.value;
  }

  void set(String? value) {
    final v = (value == null || value.isEmpty) ? null : value;
    if (v == state) return;
    state = v;
    final me = ref.read(identityProvider).value?.pubkeyHex;
    if (me == null) return;
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('following_filter:$me', v ?? ''));
  }
}

final followingFilterProvider =
    NotifierProvider<FollowingFilterNotifier, String?>(
      FollowingFilterNotifier.new,
    );

// --- Feed filters: language + hashtag ---------------------------------------

enum LanguageFilter { all, zh, en, ja }

/// The language code ('zh'/'en'/'ja') a [LanguageFilter] selects, or null for
/// [LanguageFilter.all]. The ONE mapping used wherever the filter choice is
/// compared against [Event.matchesLanguage] — the feed filter, the global
/// window's language-aware retention, and load-more's backward pre-paging —
/// so all three always agree about which posts a filter owns.
String? languageFilterCode(LanguageFilter f) => switch (f) {
  LanguageFilter.zh => 'zh',
  LanguageFilter.en => 'en',
  LanguageFilter.ja => 'ja',
  LanguageFilter.all => null,
};

/// Last-used language filter, persisted in the config table (key
/// `language_filter:<pubkey>`, PER-ACCOUNT). Restored into
/// [LanguageFilterNotifier] on startup.
final savedLanguageFilterProvider = FutureProvider<LanguageFilter>((ref) async {
  final me = ref.watch(identityProvider.select((v) => v.value?.pubkeyHex));
  if (me == null) return LanguageFilter.all;
  final cache = await ref.read(localCacheProvider.future);
  final raw = await cache.readConfig('language_filter:$me');
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
      // asData (not .value): during the per-account reload after a switch the
      // previous account's filter must not leak through.
      ref.watch(savedLanguageFilterProvider).asData?.value ??
      LanguageFilter.all;

  void set(LanguageFilter f) {
    if (f == state) return;
    state = f;
    final me = ref.read(identityProvider).value?.pubkeyHex;
    if (me == null) return;
    final value = switch (f) {
      LanguageFilter.zh => 'zh',
      LanguageFilter.en => 'en',
      LanguageFilter.ja => 'ja',
      LanguageFilter.all => 'all',
    };
    ref
        .read(localCacheProvider.future)
        .then((cache) => cache.writeConfig('language_filter:$me', value));
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
  Event? build() {
    // The cached kind-10015 belongs to ONE account — reset on account switch
    // so a late add/remove never appends to the previous account's list.
    ref.watch(identityProvider.select((v) => v.value?.pubkeyHex));
    return null;
  }

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
  Event? build() {
    // The cached kind-3 belongs to ONE account — reset on account switch so
    // follow/unfollow never mutates the previous account's contact list.
    ref.watch(identityProvider.select((v) => v.value?.pubkeyHex));
    return null;
  }

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
    // inMem must belong to THIS pubkey: right after an account switch the
    // cache reset and this rebuild race, and a stale in-memory kind-3 from
    // the previous account must never win over the new account's SQLite row.
    if (inMem != null &&
        inMem.pubkey == pubkey &&
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

  // Tapped-tag filter active → the feed source is the tag's own `#t` REQ
  // ([tagTimelineFeedProvider], routed into the window); pause the firehose —
  // its ~40 events/s would crowd the ~1000-post window and evict the tag's
  // backward pages before the user can scroll them. Rebuilds restart the
  // firehose when the filter clears (onDispose below wipes the window, so it
  // resumes clean).
  if (ref.watch(tagFilterProvider) != null) return;

  final subId = nextSubId('feed');
  // Keep subscription open (no closeOnEose) so live reactions (kind-7) +
  // metadata (kind-0) continue arriving after the initial snapshot.
  // ROUTED into the ephemeral [GlobalFeedWindow] via onEvent: firehose
  // events never enter the capped EventStore (reserved for the following
  // feed + related events), so the firehose can no longer saturate the
  // store and evict following-feed reactions. The window bounds memory;
  // the notifier throttles emission (200ms) so the UI rebuilds ≤5×/s.
  final window = ref.read(globalFeedWindowProvider.notifier);
  pool.request(
    subId,
    buildFeedFilter(mode, follows),
    closeOnEose: false,
    onEvent: window.ingest,
  );
  ref.onDispose(() {
    pool.closeSubscription(subId);
    // Ephemeral by decision: leaving the global tab (mode switch, leaving
    // the feed page, logout) drops everything the firehose brought in.
    window.clear();
  });
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
  // Tag filter active → the feed source is the hashtag's `#t` REQ
  // ([tagTimelineFeedProvider]), not the followees' posts: pause the outbox
  // router + default-bucket sub while the tag feed is shown (user confirmed
  // the source switch). Two triggers: the dropdown `tag:<tag>` and a tapped
  // hashtag ([tagFilterProvider]). Rebuilds restart them when the filter
  // clears.
  final ff = ref.watch(followingFilterProvider);
  if (identity == null ||
      mode != FeedMode.following ||
      follows.isEmpty ||
      (ff != null && ff.startsWith('tag:')) ||
      ref.watch(tagFilterProvider) != null) {
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
        'limit': 500,
      };
      if (newest > 0) filter['since'] = newest;
      pool.request(subId, filter, closeOnEose: false);
      defaultSubId = subId;
    }
  }();
});

/// Drives the feed whenever a HASHTAG filter is active — two triggers:
/// 1. TAPPED tag ([tagFilterProvider], any mode): tapping a #hashtag on a
///    post card / profile jumps to the feed filtered by it.
/// 2. Following dropdown `tag:<tag>` (following mode only).
///
/// Unlike the group filter (client-side narrowing of the already-loaded
/// following feed), a hashtag spans authors the user does NOT follow — so the
/// tag feed issues a REAL live `#t` REQ broadcast to the main pool (Amethyst
/// pattern), instead of client-filtering whatever the feed happened to hold
/// (a few days at most — "切到/点 tag 只能看到最近几天"). The destination
/// follows the mode's feed source: GLOBAL → ROUTED into the ephemeral window
/// (the firehose pauses, see [feedSubscriptionProvider]); FOLLOWING → unrouted
/// into the [EventStoreNotifier] via the merged stream (the outbox pauses, see
/// [followingOutboxProvider]). [currentFeedEventsProvider] narrows to the
/// hashtag client-side. Rebuilds — closing the sub — when the
/// filter/mode/identity changes.
///
/// NO `since`: tagged posts are SPARSE, so holding a few recent ones (e.g.
/// followees' tagged posts already in the store) says nothing about older
/// history — a `since` anchored at the newest held tagged post permanently
/// cut off everything older (v1.1.1 bug: "还是只有最近几个帖子，刷新也没有").
/// Each relay serves its newest [100]-post window of the tag; the open sub
/// streams newer posts live, and `_loadMoreTag` pages backward via `until`.
final tagTimelineFeedProvider = Provider<void>((ref) {
  final mode = ref.watch(feedModeProvider);
  final identity = ref.watch(identityProvider).value;
  final tapped = ref.watch(tagFilterProvider);
  final ff = ref.watch(followingFilterProvider);
  if (identity == null) return;
  // Tapped tag wins (most recent user intent) over the dropdown selection.
  String? tag;
  if (tapped != null && tapped.isNotEmpty) {
    tag = tapped;
  } else if (mode == FeedMode.following &&
      ff != null &&
      ff.startsWith('tag:')) {
    tag = ff.substring(4);
  }
  if (tag == null) return;
  tag = tag.toLowerCase();
  if (tag.isEmpty) return;

  final pool = ref.watch(relayPoolProvider);

  final subId = nextSubId('feed-tag');
  ref.onDispose(() => pool.closeSubscription(subId));
  final filter = <String, dynamic>{
    '#t': hashtagAlts(tag),
    // kinds [1,6]: the feed renders text notes + reposts (same backward-page
    // choice as _loadMoreGlobal/_loadMoreFollowing — reactions would eat the
    // `limit` without rendering).
    'kinds': [1, 6],
    'limit': 100,
  };
  if (mode == FeedMode.global) {
    // Global feed reads the window — route the tag REQ into it (keeps the
    // firehose's "never the capped store" invariant).
    final window = ref.read(globalFeedWindowProvider.notifier);
    pool.request(subId, filter, closeOnEose: false, onEvent: window.ingest);
  } else {
    // Following mode reads the store — unrouted, so the page flows through
    // the pool's merged stream into the EventStore automatically.
    // Live sub (closeOnEose: false): after the initial window + EOSE, new
    // matching posts stream in on the same REQ.
    pool.request(subId, filter, closeOnEose: false);
  }
});

// --- Current feed events (derived) -----------------------------------------

final currentFeedEventsProvider = Provider<List<Event>>((ref) {
  // Watching this keeps the feed subscriptions alive. In following mode the
  // outbox provider (or the tag provider, when a hashtag filter is active)
  // drives the fetch; in global mode the subscription provider does. All are
  // watched unconditionally (each is a no-op when inactive).
  ref.watch(feedSubscriptionProvider);
  ref.watch(followingOutboxProvider);
  ref.watch(tagTimelineFeedProvider);
  // GATE: rebuild only when the kind-1/6 feed content actually changes — the
  // revision provider re-emits on every store flush but only notifies when the
  // int changed. On 全球 (a live firehose) the store flushes every 200ms, but
  // reaction (kind-7) churn does NOT bump the content revision, so the feed
  // list + every visible card stop rebuilding on reaction churn ("全球 tab
  // 下滑卡顿" fix). The store is then READ (not watched) — the revision
  // dependency already arranges a rebuild whenever its content changed.
  final mode = ref.watch(feedModeProvider);
  // Feed content source. FOLLOWING: the shared capped store. GLOBAL: the
  // ephemeral firehose window — the store no longer holds firehose events,
  // so 全球 is read straight from the window (scan target drops from up to
  // 20000 store events to ≤ ~1000 window posts; the language/tag/mute
  // filters below are memo-per-event and unchanged). Same revision gating:
  // the window's `content` revision bumps only on kind-1/6 arrivals.
  final List<Event> all;
  if (mode == FeedMode.global) {
    ref.watch(globalFeedWindowProvider.select((s) => s.content));
    all = ref.read(globalFeedWindowProvider.notifier).window.posts;
  } else {
    ref.watch(feedContentRevisionProvider);
    all = ref.read(eventStoreProvider);
  }
  final lang = ref.watch(languageFilterProvider);
  final tag = ref.watch(tagFilterProvider);

  // Only kind-1 text notes and kind-6/16 reposts appear in the feed.
  // Kind-0 (metadata) and kind-7 (reactions) are stored for lookups but NOT
  // rendered as posts.
  Iterable<Event> events = all.where((e) => e.isTextNote || e.isRepost);

  if (mode == FeedMode.following) {
    // Following-list filter (DESIGN §8). `group:` narrows the already-loaded
    // following feed client-side. A hashtag — either the dropdown `tag:` or a
    // TAPPED hashtag ([tagFilterProvider]) — SWITCHES THE SOURCE: posts arrive
    // via [tagTimelineFeedProvider]'s live `#t` REQ and come from ANY author
    // (a hashtag spans people the user doesn't follow), so the followee-author
    // restriction below must NOT apply — the hashtag itself is the filter (for
    // the tapped case the common tag narrowing further down does it).
    final ff = ref.watch(followingFilterProvider);
    final tappedTag = ref.watch(tagFilterProvider);
    final tagSourceActive = tappedTag != null && tappedTag.isNotEmpty;
    if (!tagSourceActive && ff != null && ff.startsWith('tag:')) {
      final t = ff.substring(4).toLowerCase();
      events = events.where((e) => e.hashtags.contains(t));
    } else if (!tagSourceActive) {
      final follows =
          ref.watch(followingStateProvider).value ?? const <String>[];
      final set = follows.toSet();
      final me = ref.watch(identityProvider).value?.pubkeyHex;
      // The user's OWN posts always belong in their home feed. You don't follow
      // yourself, so without `|| e.pubkey == me` a just-published note (already
      // echoed into the store by publishAndWait) was silently dropped here —
      // visible in the profile 帖子 tab but never in the feed, and pull-refresh
      // couldn't bring it back either.
      events = events.where((e) => set.contains(e.pubkey) || e.pubkey == me);

      if (ff != null && ff.startsWith('group:')) {
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
      }
    }
  }

  final want = languageFilterCode(lang);
  if (want != null) {
    // Reposts (kind-6/16) are judged by the note the user ACTUALLY SEES —
    // the reposted note — not the repost wrapper, whose own content is empty
    // (or the stringified-JSON of the target). Pre-fix, an empty wrapper
    // read as "no language" and leaked into EVERY filter, so English
    // reposts flooded the 中文 feed ("转发贴混进中文过滤" bug). Resolution
    // (embedded NIP-18 JSON → feed-source lookup → wrapper) + the
    // null-language split (foreign script dropped, pure-link kept) live in
    // [Event.matchesLanguage]; the SAME predicate drives the global window's
    // language-aware retention, so what the filter shows is what the window
    // keeps. The index is built lazily + memoized: most pages never need it
    // (plain notes), and when they do it is one scan of the feed source.
    Map<String, Event>? byId;
    Map<String, Event> storeIndex() =>
        byId ??= <String, Event>{for (final ev in all) ev.id: ev};
    events = events.where(
      (e) => e.matchesLanguage(want, (id) => storeIndex()[id]),
    );
  }
  if (tag != null) {
    events = events.where((e) => e.hashtags.contains(tag));
  }

  // Mute list (NIP-51 kind-10000): hide posts from muted authors, posts
  // carrying muted hashtags, posts whose content contains a muted word, and
  // individually muted events. Owner's private (NIP-44) mutes are decrypted
  // in [muteListProvider]. Applies in both global + following modes.
  //
  // Repost wrappers ARE dropped when the REPOSTER is muted; a repost of a
  // muted author's note is NOT dropped here — the card stays on the timeline
  // but its embed renders only a 「该账号已被屏蔽」hint until the user taps it
  // open (see _RepostedEmbed), matching how reply-context previews of muted
  // posts behave ("被屏蔽的账号在时间线上不可见" requirement).
  final mute = ref.watch(myMuteSetProvider);
  if (!mute.isEmpty) {
    events = events.where((e) => !mute.hidesEvent(e));
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
  // 2. In-memory store. READ, not watch: the live store flushes a new list
  //    every ~200ms while events arrive, and a watch made this provider (and
  //    everything awaiting its `.future` — quote/repost/ancestor lookups)
  //    RESTART the whole lookup on every flush. On a busy feed the restart
  //    loop never let a relay fetch run to completion, so quote cards sat on
  //    「加载引用…」 forever. The lookup is one-shot by design; the SQLite
  //    tier + relay tiers + the card's tap-to-retry cover late arrivals.
  final store = ref.read(eventStoreProvider);
  for (final e in store) {
    if (e.id == id) return e;
  }
  // 2.5 Ephemeral global window: firehose posts live ONLY here while the
  // 全球 tab is open (quote/reply/ancestor lookups from global cards).
  final windowPost = ref
      .read(globalFeedWindowProvider.notifier)
      .window
      .postById(id);
  if (windowPost != null) return windowPost;
  // 3. Relay REQ broadcast to the main pool. Capped at 8s; resolves early
  //    (null) once EVERY relay has answered EOSE/CLOSED with nothing, so a
  //    fast all-miss doesn't make the detail page sit out the full timeout.
  //    The broadcast runs in a per-id SHARED in-flight future (not tied to
  //    this provider's lifetime): page rebuilds dispose + recreate this
  //    provider mid-lookup (router-redirect refreshes at startup, back/forward
  //    churn), and tearing down the rawEvents listener + relay REQ on dispose
  //    dropped responses the relay delivered seconds later — the recreated
  //    lookup started over and could miss again, leaving e.g. a thread parent
  //    unloaded even though the relay HAD it. With a shared future a
  //    recreated provider joins the in-flight lookup instead of restarting.
  final pool = ref.watch(relayPoolProvider);
  final hit = await _broadcastNoteLookup(pool, id);
  if (hit != null) return hit;
  // The shared lookup can outlive this provider instance (page churn): if it
  // was disposed while the broadcast was in flight, stop here — the ref is
  // dead and nobody is listening for the outbox tier anyway.
  if (!ref.mounted) return null;
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

/// In-flight pool-broadcast note lookups, keyed by pool+id. Concurrent
/// lookups for the same id (a thread's ancestor BFS + its quote/repost cards
/// + the detail page all resolve the same parent) share ONE relay REQ, and —
/// crucially — the lookup survives its originating provider being disposed
/// (see [eventByIdProvider] tier 3): the listener + REQ stay alive until the
/// lookup settles, so a late relay response still completes the shared future
/// for whoever re-asks. Entries are removed the moment the future settles —
/// this dedupes IN-FLIGHT work only; it never caches results (a miss must
/// stay retryable).
final Map<String, Future<Event?>> _noteLookupsInFlight =
    <String, Future<Event?>>{};

Future<Event?> _broadcastNoteLookup(RelayPool pool, String id) {
  final key = '${identityHashCode(pool)}\x1f$id';
  final existing = _noteLookupsInFlight[key];
  if (existing != null) return existing;
  final fut = _runBroadcastNoteLookup(pool, id);
  _noteLookupsInFlight[key] = fut;
  unawaited(fut.whenComplete(() => _noteLookupsInFlight.remove(key)));
  return fut;
}

Future<Event?> _runBroadcastNoteLookup(RelayPool pool, String id) async {
  final completer = Completer<Event?>();
  final relayCount = pool.states.length;
  var eoses = 0;
  final sub = pool.rawEvents.listen((e) {
    if (e.id == id && !completer.isCompleted) completer.complete(e);
  });
  final subId = nextSubId('note');
  // EOSE AND relay-CLOSED frames both count as "this relay has answered":
  // RelayClient emits a synthesized EOSE when a relay CLOSEDs the sub (e.g.
  // "rate-limited: too many subscriptions"), so a relay that rejects the REQ
  // can't hold the all-miss fast-exit hostage until the timeout.
  final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
    eoses++;
    if (relayCount > 0 && eoses >= relayCount && !completer.isCompleted) {
      completer.complete(null);
    }
  });
  pool.request(subId, <String, dynamic>{
    'ids': [id],
  }, closeOnEose: true);
  try {
    return await completer.future.timeout(
      const Duration(seconds: 8),
      onTimeout: () => null,
    );
  } finally {
    // Free the listeners + relay sub as soon as the lookup settles — the
    // shared future may outlive any particular provider watching it, so the
    // cleanup lives HERE, not in a provider onDispose.
    await sub.cancel();
    await eoseSub.cancel();
    pool.closeSubscription(subId);
  }
}

/// Quote-card resolution for NIP-27 references: [eventByIdProvider]'s 3-tier
/// lookup first, then — on miss — a one-shot fetch on the relay hints carried
/// inside the `nostr:nevent1…` entity itself. Quoted notes often live ONLY on
/// the author's own relays (e.g. nostr.data.haus) which are not in the default
/// pool, so the broadcast always misses and the card sat on "加载引用…" /
/// "引用内容不可用"; Amethyst fetches the nevent's relay hint, we do the same.
/// Key = `id` or `id\x1frelay1\x1frelay2` (hints baked into the family key so
/// the widget stays a plain ConsumerWidget).
final quotedEventProvider = FutureProvider.family<Event?, String>((
  ref,
  key,
) async {
  final parts = key.split('\x1f');
  final id = parts.first;
  final hints = parts.skip(1).where((r) => r.isNotEmpty).toList();
  final base = await ref.watch(eventByIdProvider(id).future);
  if (base != null) return base;
  if (hints.isEmpty) return null;
  final pool = ref.read(relayPoolProvider);
  final hits = await pool.fetchFromUrls(
    <String, dynamic>{
      'ids': [id],
    },
    hints,
    timeout: const Duration(seconds: 6),
  );
  for (final e in hits) {
    if (e.id == id) {
      // Cache in SQLite so a repeat scroll-by is instant.
      unawaited(ref.read(eventStoreProvider.notifier).cacheThreadEvent(e));
      return e;
    }
  }
  return null;
});

/// Parse the note a repost embeds, from the repost's OWN content. NIP-18:
/// a kind-6 repost's content is the stringified-JSON of the reposted event,
/// so a compliant repost carries the full embedded note — no relay fetch
/// needed. Returns null when [repost] isn't a repost, has no embedded JSON,
/// or the embedded event isn't post-like (a repost should only embed a post).
/// Delegates to the memoized [Event.embeddedRepost] so the feed language
/// filter (which resolves every visible repost on each 200ms flush) doesn't
/// re-run `jsonDecode` + `Event.fromJson` repeatedly.
Event? parseEmbeddedRepost(Event repost) => repost.embeddedRepost;

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
        for (final c in missing) _fetchEventByIdFromUrls(pool, c.id, c.relays),
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
    final relay = (t.length >= 3 && t[2] is String)
        ? (t[2] as String).trim()
        : '';
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

/// Human-readable name of a NIP-51 parameterized replaceable list (kind-30000
/// follow sets, kind-30003 bookmark sets, …). Prefers the `name` tag
/// (Amethyst puts the human name here and a UUID in `d`); falls back to the
/// `d` tag (Costr's own lists use the human name directly as `d` and carry no
/// `name` tag). Returns null for the default list (d="").
String? listDisplayName(Event e) {
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
/// NOT by [listDisplayName]: Amethyst keeps a UUID in `d` and puts the
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
    final display = listDisplayName(groupSource[d]!) ?? d;
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

/// Test seam for [_buildFollowGroups] (regression tests for the
/// stale-revision UUID-name bug).
@visibleForTesting
List<FollowGroup> buildFollowGroupsForTest(
  List<String> follows,
  List<Event> k30000Events,
) => _buildFollowGroups(follows, k30000Events);

final userGroupedFollowsProvider =
    StreamProvider.family<List<FollowGroup>, String>((ref, pubkey) async* {
      // Re-run when any kind-30000 set for the user changes (local publish or
      // remote ingestion bumps this counter).
      ref.watch(kind30000VersionProvider);

      // 1. SQLite snapshot (instant) — kind-3 + all kind-30000 are persisted
      //    by EventStoreNotifier's main listener. The same rows seed the
      //    relay refresh below, so a stale relay revision can never beat the
      //    newest persisted one.
      final cache = ref.read(localCacheProvider).value;
      List<FollowGroup>? cached;
      Event? cachedK3;
      final cachedSets = <Event>[];
      if (cache != null) {
        try {
          final k3row = await cache.queryContactList(pubkey);
          if (k3row != null) cachedK3 = _replaceableToEvent(k3row);
          cachedSets.addAll(
            (await cache.queryFollowSets(pubkey)).map(_replaceableToEvent),
          );
          cached = _buildFollowGroups(
            cachedK3?.pTagPubkeys ?? const <String>[],
            cachedSets,
          );
        } catch (_) {}
      }
      if (cached != null) yield cached;

      // 2. Relay refresh — kind-3 + kind-30000. Each settles only after EOSE
      //    from ALL relays connected at request time (10s timeout backstop),
      //    NOT on the first EOSE: different relays serve different revisions
      //    of a replaceable list, and finalizing on the fastest relay loses
      //    the slower relays' events. When the fastest relay's kind-30000
      //    copy is a stale revision without a `name` tag (e.g. a relay that
      //    missed a rename), the group name falls back to the UUID `d`
      //    identifier — and since nothing re-triggers this provider until
      //    the next list publish, the UUID name sticks for the whole session
      //    (the "列表名偶尔变 UUID、强制退出重开恢复" bug). An intermediate
      //    snapshot is emitted after each relay EOSE, so the fast relay's
      //    view shows instantly and slower relays correct it as they land.
      final pool = ref.watch(relayPoolProvider);
      final ctrl = StreamController<List<FollowGroup>>();
      List<String> follows = cachedK3?.pTagPubkeys ?? const <String>[];
      Event? newestK3 = cachedK3;
      final k30000Events = <Event>[...cachedSets];
      final seen3 = <String>{for (final e in cachedSets) e.id};
      late StreamSubscription<Event> evSub1;
      late StreamSubscription<Event> evSub2;
      late StreamSubscription<String> eoseSub1;
      late StreamSubscription<String> eoseSub2;
      final done1 = Completer<void>();
      final done2 = Completer<void>();
      final connectedCount = pool.states
          .where((s) => s.status == RelayStatus.connected)
          .length;

      evSub1 = pool.rawEvents.listen((e) {
        if (e.isContactList && e.pubkey == pubkey && !done1.isCompleted) {
          // Replaceable — newest createdAt wins (a stale kind-3 arriving
          // after a newer one must not revert the follows list).
          if (newestK3 == null || e.createdAt > newestK3!.createdAt) {
            newestK3 = e;
            follows = e.pTagPubkeys;
          }
        }
      });
      final sub1 = nextSubId('grouped-k3');
      var eoses1 = 0;
      eoseSub1 = pool.eoseStream.where((s) => s == sub1).listen((_) {
        eoses1++;
        if (eoses1 >= connectedCount && !done1.isCompleted) done1.complete();
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
      var eoses2 = 0;
      eoseSub2 = pool.eoseStream.where((s) => s == sub2).listen((_) {
        eoses2++;
        // Intermediate snapshot: _buildFollowGroups picks the newest
        // revision per `d`, so each relay's corrections surface as they
        // land instead of waiting for the slowest relay.
        if (!ctrl.isClosed) {
          ctrl.add(_buildFollowGroups(follows, k30000Events));
        }
        if (eoses2 >= connectedCount && !done2.isCompleted) done2.complete();
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

/// The logged-in user's existing follow-group names (NIP-51 kind-30000
/// display names: `name` tag else `d`). Used by the follow-group picker to
/// show existing + allow new.
///
/// Names are derived from the NEWEST known revision per `d` (SQLite rows
/// seed, relay events update newest-by-createdAt), never appended blindly:
/// a stale relay revision without a `name` tag would otherwise contribute
/// the raw UUID `d` as a "group name", and a later newer revision could not
/// retract it (the "新建分组弹窗里出现 UUID 组名" variant of the same bug).
/// Settles on EOSE from ALL connected relays (10s timeout backstop) with an
/// emission after each EOSE — same rationale as [userGroupedFollowsProvider].
final userGroupNamesProvider = StreamProvider.family<List<String>, String>((
  ref,
  pubkey,
) async* {
  // Re-run when any kind-30000 set for the user changes.
  ref.watch(kind30000VersionProvider);

  List<String> namesOf(Map<String, Event> byD) {
    final out = <String>[];
    final seen = <String>{};
    for (final e in byD.values) {
      final n = listDisplayName(e);
      if (n != null && seen.add(n)) out.add(n);
    }
    return List<String>.unmodifiable(out);
  }

  // 1. SQLite snapshot (instant) — kind-30000 sets are persisted by
  //    EventStoreNotifier. Newest persisted revision per `d` (the table is
  //    PK-deduped by pubkey+kind+d, one row per list).
  final cache = ref.read(localCacheProvider).value;
  final byD = <String, Event>{}; // d → newest known revision
  if (cache != null) {
    try {
      for (final row in await cache.queryFollowSets(pubkey)) {
        final e = _replaceableToEvent(row);
        final d = _kind30000D(e);
        if (d.isEmpty) continue;
        final prev = byD[d];
        if (prev == null || e.createdAt > prev.createdAt) byD[d] = e;
      }
    } catch (_) {}
  }
  yield namesOf(byD);

  // 2. Relay refresh — newest revision per `d` across relays.
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<List<String>>();
  late StreamSubscription<Event> evSub;
  late StreamSubscription<String> eoseSub;
  final done = Completer<void>();
  evSub = pool.rawEvents.listen((e) {
    if (e.kind == 30000 && e.pubkey == pubkey) {
      final d = _kind30000D(e);
      if (d.isEmpty) return;
      final prev = byD[d];
      if (prev == null || e.createdAt > prev.createdAt) {
        byD[d] = e;
        if (!ctrl.isClosed) ctrl.add(namesOf(byD));
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
    if (!ctrl.isClosed) ctrl.add(namesOf(byD));
    if (eoses >= connectedCount && !done.isCompleted) done.complete();
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
      ctrl.add(namesOf(byD));
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
/// @-mention autocomplete in the composer. Sourced from the store's
/// eviction-proof metadata index + the user's follows + self, so it needs no
/// relay round-trip and updates as metadata streams in.
class KnownUser {
  const KnownUser(this.pubkey, this.meta);
  final String pubkey;
  final Metadata? meta;
  String get label => meta?.bestName ?? shortenEntity(hexToNpub(pubkey));
}

/// All locally-known users for @-mention autocomplete. Derived from the
/// store's EVICTION-PROOF metadata index (newest kind-0 of EVERY user seen
/// this session — capped-list eviction no longer hides them mid-session,
/// which used to empty the autocomplete until a restart re-hydrated all
/// cached metadata: "偶尔 @ 不到人，重启才好") + the logged-in user's
/// follows + self. No relay round-trip.
final knownUsersProvider = Provider<List<KnownUser>>((ref) {
  // Watched (not read) so a store flush re-derives the list when new
  // metadata arrives; the index itself is read off the notifier.
  ref.watch(eventStoreProvider);
  final metaIndex = ref.read(eventStoreProvider.notifier).metadataByPubkey;
  final map = <String, KnownUser>{};
  void add(String pk) {
    if (pk.isEmpty) return;
    map.putIfAbsent(pk, () => KnownUser(pk, _metaOf(metaIndex[pk])));
  }

  // Recently-active users first (the empty-query panel shows the first 8 —
  // same newest-first order the old store scan produced).
  final metas = metaIndex.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  for (final e in metas) {
    add(e.pubkey);
  }
  for (final pk
      in ref.watch(followingStateProvider).value ?? const <String>[]) {
    add(pk);
  }
  final self = ref.watch(identityProvider).value?.pubkeyHex;
  if (self != null) add(self);
  return map.values.toList();
});

/// Parse a kind-0 event's `.content` JSON into [Metadata] (null on
/// absent/malformed).
Metadata? _metaOf(Event? e) {
  if (e == null) return null;
  try {
    final j = jsonDecode(e.content);
    if (j is Map<String, dynamic>) {
      return Metadata.fromJson(j, tags: e.tags);
    }
  } catch (_) {}
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

/// The event store's [EventStore.contentRevision] re-emitted as a provider
/// value: recomputed on every store flush but dependents are only NOTIFIED
/// when the int actually changed — i.e. when the kind-1/6 feed content
/// changed. kind-7 (reaction) firehose churn flushes the store every 200ms
/// but does not bump this revision, so providers gated on it (the feed list)
/// stop rebuilding on reaction churn ("全球 tab 下滑卡顿" fix).
final feedContentRevisionProvider = Provider<int>((ref) {
  ref.watch(eventStoreProvider); // subscribe to flushes
  return ref.read(eventStoreProvider.notifier).contentRevision;
});

/// Same gate for the kind-1/6/7 interaction set (replies + reposts +
/// reactions) — bumps on reaction arrivals too, since counts must update
/// live, but NOT on kind-0 metadata bursts.
final interactionRevisionProvider = Provider<int>((ref) {
  ref.watch(eventStoreProvider);
  return ref.read(eventStoreProvider.notifier).interactionRevision;
});

/// Eviction-proof interaction cache — see [InteractionCache] for why the
/// capped store alone cannot hold reactions on a saturated firehose. The
/// exposed int is the cache's revision counter, the reactive handle:
/// [InteractionIndexNotifier] watches it and re-reads
/// [InteractionCacheNotifier.cache] (same bump-pattern as
/// [kind30000VersionProvider]). Fed from three places: the merged relay
/// stream (every interaction delivered by ANY unrouted sub — following feed,
/// notifications #e REQ, targeted fetches — ingested by the EventStore stream
/// listener), [interactorsProvider] (thread-open #e fetch), and the user's own
/// publishes (post_actions.dart) — never the routed global firehose.
class InteractionCacheNotifier extends Notifier<int> {
  InteractionCache _cache = InteractionCache();
  InteractionCache get cache => _cache;

  /// Account the cache was (re)built for — same leak guard as
  /// EventStoreNotifier: on account switch / login / logout the previous
  /// account's residue (own reactions, viewed threads) is dropped.
  String? _builtForAccount;

  @override
  int build() {
    final accountKey = ref.watch(
      identityProvider.select((v) => v.value?.pubkeyHex),
    );
    if (_builtForAccount != accountKey) {
      _builtForAccount = accountKey;
      // Fresh instance — mutating the old one mid-build would notify nothing;
      // replacing it and returning its revision does.
      _cache = InteractionCache();
    }
    return _cache.revision;
  }

  /// Ingest fetched/published interaction events; notifies on real change.
  void ingest(Iterable<Event> events) {
    if (_cache.ingest(events)) state = _cache.revision;
  }

  /// Drop one interaction event (reaction cancel / NIP-09 deletion). [where]
  /// gates on the held copy (remote deletions must match the author).
  void removeEvent(String eventId, {bool Function(Event)? where}) {
    if (_cache.removeEvent(eventId, where: where)) state = _cache.revision;
  }

  void clear() {
    _cache.clear();
    state = _cache.revision;
  }
}

final interactionCacheProvider =
    NotifierProvider<InteractionCacheNotifier, int>(
      InteractionCacheNotifier.new,
    );

/// Reactive view of [GlobalFeedWindow]: three revision counters, selected
/// individually by consumers so kind-7 churn never rebuilds the post list
/// (same gating [feedContentRevisionProvider] applies to the store).
class GlobalFeedWindowState {
  const GlobalFeedWindowState({
    this.content = 0,
    this.interactions = 0,
    this.metadata = 0,
  });
  final int content;
  final int interactions;
  final int metadata;

  @override
  bool operator ==(Object other) =>
      other is GlobalFeedWindowState &&
      other.content == content &&
      other.interactions == interactions &&
      other.metadata == metadata;

  @override
  int get hashCode => Object.hash(content, interactions, metadata);
}

/// Ephemeral firehose window for the 全球 tab — see [GlobalFeedWindow]. The
/// capped [EventStore] is reserved for the following feed + related events;
/// the routed global subscription feeds this window instead, so the
/// firehose can no longer saturate the store and evict following-feed
/// reactions. Memory-only, never persisted, cleared on leaving the tab.
///
/// Firehose events arrive ~40/s; the state emission is THROTTLED to the
/// same 200ms cadence the store flush uses, so dependents rebuild ≤5×/s
/// regardless of firehose rate (per-event emission would be a rebuild storm
/// = the 全球 tab scroll jank all over again).
class GlobalFeedWindowNotifier extends Notifier<GlobalFeedWindowState> {
  GlobalFeedWindow _window = GlobalFeedWindow();
  GlobalFeedWindow get window => _window;
  Timer? _flush;
  bool _dirty = false;

  /// Monotonic counter bumped on EVERY window wipe (account-switch recreation,
  /// [clear]). The feed's backward-paging depth cursor lives in page state
  /// and must die with the window it paged into — comparing generations is
  /// the staleness check, and it covers every wipe path (refresh, mode
  /// switch, account switch, tag filter on/off, follows change) without
  /// enumerating them.
  int _generation = 0;
  int get generation => _generation;

  /// Same leak guard as EventStoreNotifier / InteractionCacheNotifier: an
  /// account switch drops the previous account's window.
  String? _builtForAccount;

  @override
  GlobalFeedWindowState build() {
    final accountKey = ref.watch(
      identityProvider.select((v) => v.value?.pubkeyHex),
    );
    if (_builtForAccount != accountKey) {
      _builtForAccount = accountKey;
      _window = GlobalFeedWindow();
      _generation++;
    }
    // Language-aware retention: the window must know the ACTIVE filter so
    // cap eviction can protect matching posts from firehose churn (the 1000
    // cap counts BY LANGUAGE — "开启语言过滤后总条目数应该按语言统计").
    // Rebuilds on every filter change keep this current without touching the
    // revisions, so nothing re-emits: retention is about WHICH posts survive
    // future ingests, not about the snapshot held right now.
    _window.languageFilter = languageFilterCode(
      ref.watch(languageFilterProvider),
    );
    ref.onDispose(() {
      _flush?.cancel();
      _flush = null;
    });
    return _snapshot();
  }

  GlobalFeedWindowState _snapshot() => GlobalFeedWindowState(
    content: _window.contentRevision,
    interactions: _window.interactionRevision,
    metadata: _window.metadataRevision,
  );

  /// Routed firehose events land here (feedSubscriptionProvider live sub +
  /// feed_page's global load-more). Mutation is immediate; notification is
  /// throttled.
  void ingest(Event e) {
    if (!_window.ingest(e)) return;
    _dirty = true;
    _flush ??= Timer(const Duration(milliseconds: 200), () {
      _flush = null;
      if (_dirty) {
        _dirty = false;
        state = _snapshot();
      }
    });
  }

  /// Force the pending state emit NOW (mirrors [EventStoreNotifier.flushNow]).
  /// Feed's load-more calls this after a backward page lands so the
  /// "did the feed actually extend?" check reads the new revision instead of
  /// a stale pre-flush snapshot (which would falsely trigger the empty-page
  /// cooldown).
  void flushNow() {
    _flush?.cancel();
    _flush = null;
    if (_dirty) {
      _dirty = false;
      state = _snapshot();
    }
  }

  /// Drop the whole window: leaving the global tab (user decision: 全球信息
  /// 流不需要任何缓存，包括 sqlite 和内存). Bumps [generation] EVEN when the
  /// window is already empty — the paging depth cursor points at the
  /// subscription lifetime that just ended, not merely at held posts.
  void clear() {
    _flush?.cancel();
    _flush = null;
    _dirty = false;
    _generation++;
    if (_window.isEmpty) return;
    _window.clear();
    state = _snapshot();
  }
}

final globalFeedWindowProvider =
    NotifierProvider<GlobalFeedWindowNotifier, GlobalFeedWindowState>(
      GlobalFeedWindowNotifier.new,
    );

/// Per-target interaction stats over the held store: reply/repost counts,
/// reaction tallies and the user's own reaction, keyed by the referenced
/// e-tag target id.
class PostInteractionStats {
  const PostInteractionStats({
    this.replies = 0,
    this.reposts = 0,
    this.reactions = const {},
    this.myReaction,
  });
  final int replies;
  final int reposts;
  final Map<String, ({int count, String? emojiUrl})> reactions;
  final Event? myReaction;
}

/// ONE store-wide pass over kind-1/6/7 events, shared by every per-post
/// provider below ([postCountsProvider] / [reactionsProvider] /
/// [myReactionProvider]). Previously each of those family providers re-scanned
/// the ENTIRE store (up to 20000 events × tag loops) for EVERY visible card
/// on EVERY 200ms firehose flush — the dominant cost of the 全球 scroll jank
/// (≈ 3 × visible-cards × O(store) per flush, plus once per newly-built card
/// mid-fling). Now: one O(store) pass per interaction-relevant change, then
/// O(1) lookups per card.
///
/// Unchanged per-target [PostInteractionStats] are carried over BY IDENTITY
/// from the previous index, so the per-card family providers return the same
/// object and Riverpod skips their dependents entirely when "their" post's
/// interactions didn't change.
final interactionIndexProvider =
    NotifierProvider<
      InteractionIndexNotifier,
      Map<String, PostInteractionStats>
    >(InteractionIndexNotifier.new);

class InteractionIndexNotifier
    extends Notifier<Map<String, PostInteractionStats>> {
  /// Previous index, for instance-reuse of unchanged entries.
  Map<String, PostInteractionStats> _prev = const {};

  @override
  Map<String, PostInteractionStats> build() {
    // Rebuild only when the interaction-relevant store content changes…
    ref.watch(interactionRevisionProvider);
    // …or when the eviction-proof interaction cache changes (thread-open
    // fetches, the user's own publishes). The merge below is what keeps
    // tallies visible on a saturated firehose, where the store evicts its
    // kind-7 copies ~25ms after arrival.
    ref.watch(interactionCacheProvider);
    // …or when the ephemeral global window's interactions change (live
    // firehose reactions/reposts on the 全球 tab's own posts — those never
    // enter the store either). Selects ONLY the interactions revision, so
    // post/metadata arrivals don't rebuild the index.
    ref.watch(globalFeedWindowProvider.select((s) => s.interactions));
    final store = ref.read(eventStoreProvider); // read: no extra subscription
    final interactionCache = ref.read(interactionCacheProvider.notifier).cache;
    final globalWindow = ref.read(globalFeedWindowProvider.notifier).window;
    final me = ref.watch(identityProvider).value?.pubkeyHex;

    final replies = <String, int>{};
    final reposts = <String, int>{};
    final reactions = <String, Map<String, ({int count, String? emojiUrl})>>{};
    final myReactions = <String, Event>{};
    final targets = <String>{}; // per-event distinct e-tag targets (buffer)
    // One id-deduped view over all three tiers, tallied exactly once. A
    // misbehaving relay can serve a MUTATED variant under an existing event
    // id (observed in the wild: top.testrelay.top truncates tag NAMES —
    // `["emoji", …]`→`["e", …]`, `["client", …]`→`["c", …]` — same id, SAME
    // tag count, so a length tie-break is not enough; the id commits to the
    // tags, so the variant is technically invalid, but it still arrives).
    // On an id collision keep the copy that can actually RENDER
    // ([_betterVariant]): the old store-first/seenIds-shortcut order made the
    // chip flip from the emoji image to the raw `:shortcode:` the moment a
    // mutated copy landed in the store ("表情图一闪而过变回 shortcode"), and
    // v1.0.9's tags.length rule still let the mutated copy win on ties —
    // both surfaces then showed raw text.
    final merged = <String, Event>{};
    void mergeEvent(Event e) {
      final prev = merged[e.id];
      if (prev == null || _betterVariant(e, prev)) merged[e.id] = e;
    }

    // Shared aggregation for one kind-6/7/16 event over [targets] (filled
    // by the caller before invoking).
    void tallyInteraction(Event e) {
      if (e.kind == 7) {
        // kind-7 reaction. NIP-25: empty content OR literal "+" = default
        // like → normalized to 👍 (the old reactionsProvider did the same).
        final raw = e.content;
        final key = (raw.isEmpty || raw == '+') ? '👍' : raw;
        String? emojiUrl;
        for (final et in e.tags) {
          if (et.length >= 3 && et[0] == 'emoji' && et[2] is String) {
            emojiUrl = et[2] as String;
            break;
          }
        }
        final isMine = me != null && e.pubkey == me;
        for (final t in targets) {
          final tallies = reactions.putIfAbsent(t, () => {});
          final prevTally = tallies[key];
          // First event for an emoji key supplies the NIP-30 url (matches
          // the old `prev?.emojiUrl` behavior).
          tallies[key] = (
            count: (prevTally?.count ?? 0) + 1,
            emojiUrl: prevTally?.emojiUrl ?? emojiUrl,
          );
          // Newest own reaction wins, across BOTH tiers (the old store-scan
          // relied on newest-first store order; the cache merge needs the
          // explicit comparison).
          if (isMine) {
            final prevMine = myReactions[t];
            if (prevMine == null || e.createdAt > prevMine.createdAt) {
              myReactions[t] = e;
            }
          }
        }
      } else {
        // kind-6 repost (kind-16 generic repost only reaches here from the
        // cache tier — the store doesn't hold kind-16). The self-reference
        // guard matches the old store scan (cache ingestion applies it too,
        // so it's a no-op for cache-tier events).
        for (final t in targets) {
          if (t == e.id) continue;
          reposts[t] = (reposts[t] ?? 0) + 1;
        }
      }
    }

    bool fillTargets(Event e) {
      targets.clear();
      for (final t in e.tags) {
        if (t.length >= 2 && t[0] == 'e' && t[1] is String) {
          targets.add(t[1] as String);
        }
      }
      return targets.isNotEmpty;
    }

    // Shared per-event aggregation over the filled [targets]: a kind-1 counts
    // a reply on each target; kind-6/7/16 delegate to [tallyInteraction]. Used
    // IDENTICALLY by the store / cache / window tiers so a reply, repost or
    // reaction is tallied the same way whichever tier holds it. (The cache
    // tier gained kind-1 reply tallying to keep the feed reply COUNT
    // eviction-proof — "信息流回复计数" fix.)
    void tallyEvent(Event e) {
      if (e.kind == 1) {
        for (final t in targets) {
          // Skip the post itself (a kind-1 with a self-referential e tag,
          // rare) — same guard the old per-provider scan had.
          if (t == e.id) continue;
          replies[t] = (replies[t] ?? 0) + 1;
        }
      } else {
        tallyInteraction(e);
      }
    }

    for (final e in store) {
      if (e.kind != 1 && e.kind != 6 && e.kind != 7) continue;
      mergeEvent(e);
    }

    // Cache tier: interactions + replies that survived store eviction (or
    // never entered the store — own publishes on a quiet feed do, but evicted
    // fetch results don't). kind-1 replies are merged here too so the feed
    // reply count survives saturation (kind-1 evicts LAST but still evicts on
    // a long-lived, busy feed).
    for (final e in interactionCache.events) {
      mergeEvent(e);
    }

    // Global-window tier: live firehose interactions on 全球-tab posts. The
    // window also holds kind-1 posts (potential replies). Empty unless the
    // global tab is/was open this session (the window is cleared on leaving).
    for (final e in globalWindow.events) {
      mergeEvent(e);
    }

    for (final e in merged.values) {
      if (!fillTargets(e)) continue;
      tallyEvent(e);
    }

    final next = <String, PostInteractionStats>{};
    final ids = <String>{
      ...replies.keys,
      ...reposts.keys,
      ...reactions.keys,
      ...myReactions.keys,
    };
    for (final id in ids) {
      final candidate = PostInteractionStats(
        replies: replies[id] ?? 0,
        reposts: reposts[id] ?? 0,
        reactions: reactions[id] ?? const {},
        myReaction: myReactions[id],
      );
      final prevStats = _prev[id];
      // Carry over the OLD instance when content is unchanged so downstream
      // providers hand Riverpod an identical object (no rebuild).
      next[id] = (prevStats != null && _statsEqual(prevStats, candidate))
          ? prevStats
          : candidate;
    }
    _prev = next;
    return next;
  }

  static bool _statsEqual(PostInteractionStats a, PostInteractionStats b) {
    if (a.replies != b.replies || a.reposts != b.reposts) return false;
    if (!identical(a.myReaction, b.myReaction)) return false;
    if (a.reactions.length != b.reactions.length) return false;
    for (final entry in a.reactions.entries) {
      final other = b.reactions[entry.key];
      if (other == null ||
          other.count != entry.value.count ||
          other.emojiUrl != entry.value.emojiUrl) {
        return false;
      }
    }
    return true;
  }
}

/// Per-post interaction counts the client has OBSERVED so far (replies +
/// reposts), derived client-side from the in-memory [EventStore]. This is a
/// lower bound — only events that have streamed in via the global feed, a
/// targeted #e REQ (e.g. [repliesProvider] when the thread was opened), or a
/// load-more page are counted; relays aren't queried for a total. Matches
/// Amethyst's "what I've seen" approach. The count populates reliably once
/// the user has opened the post's thread; on the feed it stays ~0 until then.
/// O(1) lookup into [interactionIndexProvider] (was: full-store scan per
/// card per flush).
final postCountsProvider =
    Provider.family<({int replies, int reposts}), String>((ref, eventId) {
      final stats = ref.watch(interactionIndexProvider)[eventId];
      return (replies: stats?.replies ?? 0, reposts: stats?.reposts ?? 0);
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
        if (json is Map<String, dynamic>) {
          meta = Metadata.fromJson(json, tags: e.tags);
        }
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
/// O(1) lookup into [interactionIndexProvider] (was: full-store scan per card
/// per flush). The map instance is carried over unchanged from the previous
/// index, so cards whose reactions didn't change skip their rebuild.
final reactionsProvider =
    Provider.family<Map<String, ({int count, String? emojiUrl})>, String>((
      ref,
      eventId,
    ) {
      final stats = ref.watch(interactionIndexProvider)[eventId];
      return stats?.reactions ?? const {};
    });

/// True if [e] is a kind-7 reaction or kind-6/16 repost that references
/// [eventId] via an `e` tag — i.e. an interaction ON that post. Shared by
/// [interactorsProvider] (fetch + seed) and [interactorEventsProvider]
/// (the live list).
@visibleForTesting
bool isInteractorOf(Event e, String eventId) {
  if (e.kind != 7 && !e.isRepost) return false;
  for (final t in e.tags) {
    if (t.length >= 2 && t[0] == 'e' && t[1] == eventId) return true;
  }
  return false;
}

/// How well a same-id variant can render its reaction glyph: 2 = carries the
/// well-formed NIP-30 `["emoji", shortcode, url]` tag matching the content's
/// `:shortcode:`; 0 = content is a shortcode but no renderable tag (mutated
/// variants, e.g. top.testrelay.top's `["e", code, url]` truncation); 1 =
/// content isn't a shortcode (unicode/like) so variants are indistinguishable
/// on this axis.
int _emojiFidelity(Event e) {
  final m = RegExp(r'^:([a-zA-Z0-9_+-]+):$').firstMatch(e.content);
  final code = m?.group(1);
  if (code == null) return 1;
  for (final t in e.tags) {
    if (t.length >= 3 && t[0] == 'emoji' && t[1] == code && t[2] is String) {
      return 2;
    }
  }
  return 0;
}

/// Same-id collision preference (misbehaving relays serve mutated copies
/// under an existing id): the renderable copy beats the mutated one; within
/// equal fidelity the fuller copy wins. NEVER tags.length alone — the
/// observed truncation keeps the tag COUNT identical.
bool _betterVariant(Event candidate, Event held) {
  final cf = _emojiFidelity(candidate);
  final hf = _emojiFidelity(held);
  if (cf != hf) return cf > hf;
  return candidate.tags.length > held.tags.length;
}

/// Live "who liked / reposted [eventId]" event list: the capped store (what
/// the feed saw) merged with the eviction-proof interaction cache (thread-open
/// fetches, live relay deliveries, own publishes), newest-first. Rebuilds on
/// EITHER source's revision bump, so late relay answers and likes arriving
/// while the page is open keep growing the list after the initial fetch
/// resolves — the page must never be stuck on its first (possibly empty)
/// snapshot.
///
/// Same-id collisions (a relay serving a mutated variant of an event,
/// see [InteractionIndexNotifier]) use [_betterVariant] — the SAME rule the
/// index uses, so the chip row and this list never disagree on a glyph.
final interactorEventsProvider = Provider.family<List<Event>, String>((
  ref,
  eventId,
) {
  ref.watch(interactionRevisionProvider);
  ref.watch(interactionCacheProvider);
  final merged = <String, Event>{};
  void merge(Event e) {
    if (!isInteractorOf(e, eventId)) return;
    final prev = merged[e.id];
    if (prev == null || _betterVariant(e, prev)) merged[e.id] = e;
  }

  for (final e in ref.read(eventStoreProvider)) {
    merge(e);
  }
  for (final e in ref.read(interactionCacheProvider.notifier).cache.events) {
    merge(e);
  }
  return merged.values.toList()
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
});

/// Fetches [eventId]'s kind-7 reactions + kind-6/16 reposts with a pool REQ
/// {kinds:[6,16,7], "#e":[id]} and seeds them into the eviction-proof
/// [interactionCacheProvider] (the capped store evicts kind-7 FIRST — on a
/// saturated firehose a fetched reaction lives ~25ms there, which dead-locked
/// the like tally / chips / chevron invisible: "看不到帖子的点赞列表" + the
/// v1.0.6 follow-up "点赞不显示、点了几次都没用" reports).
///
/// autoDispose + watched by BOTH the thread page and [InteractionsPage]:
/// the thread page opens → this runs the fetch. The seed reads store + cache,
/// so revisiting a thread shows its previously-fetched interactions
/// instantly, before the fresh REQ answers. Disposing when the pages close
/// re-queries on every later visit (a session-cached non-autoDispose instance
/// would serve a stale first-fetch forever).
///
/// Resolution + lifetime rules (the "通知里有点赞提醒，点进去看不到" fix):
/// the old code resolved on the FIRST relay's EOSE and then closed the sub on
/// ALL relays. A relay WITHOUT the like answers empty-EOSE fastest — the
/// fetch got cancelled before the relay that HAS the like could respond,
/// resolved empty, ingested nothing, and the chevron stayed hidden (why some
/// likes showed and some didn't: pure relay-response lottery). Now:
///  * every matching event is ingested into the cache THE MOMENT it arrives
///    (incrementally, not just at resolution), so tallies/chips/chevron
///    populate live regardless of when the future settles;
///  * the future resolves on the first EOSE only when something was already
///    collected, else it waits until every relay connected at request time
///    has EOSE'd (a genuinely empty answer set) or the 8s deadline;
///  * the REQ stays open (closeOnEose: false) until BOTH pages dispose it,
///    so late relay answers AND live new likes keep flowing into the cache
///    the whole time the post is on screen.
final interactorsProvider = FutureProvider.autoDispose
    .family<List<Event>, String>((ref, eventId) async {
      final merged = <String, Event>{
        for (final e in ref.read(interactorEventsProvider(eventId))) e.id: e,
      };
      final pool = ref.watch(relayPoolProvider);
      final cacheNotifier = ref.read(interactionCacheProvider.notifier);
      final sub = pool.rawEvents.listen((e) {
        if (!isInteractorOf(e, eventId)) return;
        merged[e.id] = e;
        // Incremental ingest: survives early disposal AND populates the
        // tallies live (the merged stream ALSO feeds the cache via the store
        // listener, but a like delivered under THIS sub must not depend on
        // that path being alive).
        cacheNotifier.ingest([e]);
      });
      final subId = nextSubId('interactors');
      final connectedAtRequest = pool.states
          .where((s) => s.status == RelayStatus.connected)
          .length;
      var eoseCount = 0;
      final completer = Completer<void>();
      final eoseSub = pool.eoseStream.where((s) => s == subId).listen((_) {
        eoseCount++;
        // No first-EOSE stampede: an empty first EOSE means nothing more than
        // "this relay was fast/empty" — keep waiting for the rest (bounded
        // by the timeout below).
        if (!completer.isCompleted &&
            (merged.isNotEmpty || eoseCount >= connectedAtRequest)) {
          completer.complete();
        }
      });
      pool.request(subId, <String, dynamic>{
        'kinds': [Event.kindRepost, Event.kindGenericRepost, 7],
        '#e': [eventId],
      });
      ref.onDispose(() {
        sub.cancel();
        eoseSub.cancel();
        pool.closeSubscription(subId);
      });
      try {
        await completer.future.timeout(
          const Duration(seconds: 8),
          onTimeout: () {},
        );
      } finally {
        // NOTE: the REQ + rawEvents listener intentionally stay open until
        // dispose (see class doc) — only the resolution plumbing is torn
        // down here.
        await eoseSub.cancel();
      }
      final list = merged.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      cacheNotifier.ingest(list);
      return list;
    });

/// The current user's own kind-7 reaction to [eventId], if known. Sources:
/// the eviction-proof interaction cache (the just-published reaction is
/// ingested there by post_actions right after the relay accepts it — the
/// store's publish echo alone survives only ~25ms on a saturated firehose,
/// which left the heart un-filled: "点赞不显示、点了几次都没用") plus
/// whatever the store currently holds (hydration / quiet-feed echoes).
/// Used to highlight the reaction icon + let a second tap cancel (NIP-09
/// kind-5 delete of the reaction event). O(1) lookup into
/// [interactionIndexProvider] (was: full-store scan per card per flush).
/// When logged out the index never records a myReaction, so this correctly
/// stays null.
final myReactionProvider = Provider.family<Event?, String>((ref, eventId) {
  final stats = ref.watch(interactionIndexProvider)[eventId];
  return stats?.myReaction;
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
  final roots = <Event>[...(children[rootId] ?? const <Event>[]), ...orphans]
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
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
  final unreached = replies.where((e) => !seen.contains(e.id)).toList()
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
        <String, dynamic>{
          'kinds': [1],
          '#e': [eventId],
        },
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
        if (listDisplayName(ev) == category) {
          current = ev;
          break;
        }
      }
    } catch (_) {}
  }

  // 2. Relay REQ (all author's kind-30000) for lists not yet cached, matched
  //    by display name. Collects until ALL connected relays EOSE (8s
  //    timeout) and uses the NEWEST matching revision: different relays
  //    serve different revisions, and completing on the first match could
  //    pick a stale one whose `p` roster misses members a newer revision
  //    added — [followCategory] carries that stale roster over and would
  //    silently drop those members.
  if (current == null) {
    final completer = Completer<Event?>();
    Event? best;
    late StreamSubscription<Event> evSub;
    late StreamSubscription<String> eoseSub;
    evSub = pool.rawEvents.listen((e) {
      if (e.kind == 30000 &&
          e.pubkey == identity.pubkeyHex &&
          listDisplayName(e) == category) {
        if (best == null || e.createdAt > best!.createdAt) best = e;
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
        completer.complete(best);
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
        onTimeout: () => best,
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
      return const RelayOk('', false, '无法确认现有书签列表（中继未及时响应），已取消以防清空。请重试。');
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

/// A user's bookmark groups. NIP-51 kind-10003 (single global list) AND
/// kind-30003 (labeled bookmark lists, multi-instance — Amethyst uses these
/// for named bookmark groups); both carry public `e` tags + NIP-44-encrypted
/// private entries. Output mirrors the follows tab's group model so the
/// 收藏 tab can render the same chip-row + segmented-sections UI: two
/// built-in groups (公开书签 / 私人书签 — aggregated across every list; the
/// private one only for the owner, others can't decrypt) plus one group per
/// kind-30003 `d`. Groups are keyed by the **`d` tag** (stable identifier —
/// Amethyst keeps a UUID in `d` and the human name in `name`), display name
/// from the newest revision's `name` tag else `d` (see [listDisplayName]).
/// Amethyst-style loading: yields the SQLite-cached snapshot instantly,
/// then background-refreshes from relays.
final bookmarksProvider = StreamProvider.family<List<BookmarkGroup>, String>((
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

  // Built-in public/private aggregates (deduped by note id across every
  // list) + one group per kind-30003 list. Map iteration is first-seen `d`
  // order (LinkedHashMap), so chip order stays stable across refreshes.
  List<BookmarkGroup> build(Event? k10003, Map<String, Event> k30003) {
    final all = <BookmarkEntry>[];
    final seen = <String>{};
    void addAll(List<BookmarkEntry> es) {
      for (final e in es) {
        if (seen.add(e.id)) all.add(e);
      }
    }

    addAll(entriesOf(k10003));
    for (final e in k30003.values) {
      addAll(entriesOf(e));
    }
    final groups = <BookmarkGroup>[
      BookmarkGroup('公开书签', all.where((e) => e.public).toList()),
      if (isSelf) BookmarkGroup('私人书签', all.where((e) => !e.public).toList()),
    ];
    for (final g in k30003.entries) {
      groups.add(
        BookmarkGroup(
          listDisplayName(g.value) ?? g.key,
          entriesOf(g.value),
          source: g.value,
        ),
      );
    }
    return groups;
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
  var latest = build(cachedK10003, cachedK30003);
  // Always yield the cache snapshot (even all-empty) so the tab renders
  // chip row + 暂无收藏 instead of an endless spinner for empty lists.
  yield List<BookmarkGroup>.unmodifiable(latest);

  // 2. Relay refresh — kinds [10003, 30003], newest per (kind|d).
  final pool = ref.watch(relayPoolProvider);
  final ctrl = StreamController<List<BookmarkGroup>>();
  Timer? flush;
  var dirty = false;
  void scheduleEmit() {
    dirty = true;
    flush ??= Timer(const Duration(milliseconds: 250), () {
      flush = null;
      if (dirty && !ctrl.isClosed) {
        dirty = false;
        ctrl.add(List<BookmarkGroup>.unmodifiable(latest));
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
        latest = build(netK10003, netK30003);
        scheduleEmit();
      }
    } else if (e.kind == 30003) {
      final d = dOf(e);
      final prev = netK30003[d];
      if (prev == null || e.createdAt > prev.createdAt) {
        netK30003[d] = e;
        latest = build(netK10003, netK30003);
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
      ctrl.add(List<BookmarkGroup>.unmodifiable(latest));
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
final muteListProvider = StreamProvider.family<MuteSet, String>((
  ref,
  pubkey,
) async* {
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

// --- NSFW settings (local, PER-ACCOUNT, not synced to relays) ---------------

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

/// NSFW preferences follow the ACCOUNT, not the device: stored per pubkey in
/// the local config table (`nsfw_*:<pubkey>`). Rebuilds (and reloads) on
/// account switch. The pre-multi-account global values (secure storage) are
/// adopted by whichever account loads first, then deleted.
class NsfwSettingsNotifier extends Notifier<NsfwSettings> {
  static const _legacyAutoReveal = 'costr.nsfw.autoReveal';
  static const _legacyDefault = 'costr.nsfw.defaultCompose';

  @override
  NsfwSettings build() {
    final me = ref.watch(identityProvider.select((v) => v.value?.pubkeyHex));
    if (me != null) _load(me);
    return const NsfwSettings();
  }

  String _keyAutoReveal(String me) => 'nsfw_auto_reveal:$me';
  String _keyDefault(String me) => 'nsfw_default_compose:$me';

  Future<void> _load(String me) async {
    try {
      final cache = await ref.read(localCacheProvider.future);
      var ar = await cache.readConfig(_keyAutoReveal(me));
      var dc = await cache.readConfig(_keyDefault(me));
      if (ar == null && dc == null) {
        // One-time migration of the pre-multi-account global values.
        final s = ref.read(storageProvider);
        final legAr = await s.readValue(_legacyAutoReveal);
        final legDc = await s.readValue(_legacyDefault);
        if (legAr != null || legDc != null) {
          ar = legAr ?? 'false';
          dc = legDc ?? 'false';
          await cache.writeConfig(_keyAutoReveal(me), ar);
          await cache.writeConfig(_keyDefault(me), dc);
          await s.deleteValue(_legacyAutoReveal);
          await s.deleteValue(_legacyDefault);
        }
      }
      if (ar != null || dc != null) {
        state = NsfwSettings(
          autoReveal: ar == 'true',
          defaultComposeNsfw: dc == 'true',
        );
      }
    } catch (_) {
      // Cache unavailable — keep defaults.
    }
  }

  String? get _me => ref.read(identityProvider).value?.pubkeyHex;

  Future<void> setAutoReveal(bool v) async {
    state = state.copyWith(autoReveal: v);
    final me = _me;
    if (me == null) return;
    try {
      final cache = await ref.read(localCacheProvider.future);
      await cache.writeConfig(_keyAutoReveal(me), v.toString());
    } catch (_) {}
  }

  Future<void> setDefaultComposeNsfw(bool v) async {
    state = state.copyWith(defaultComposeNsfw: v);
    final me = _me;
    if (me == null) return;
    try {
      final cache = await ref.read(localCacheProvider.future);
      await cache.writeConfig(_keyDefault(me), v.toString());
    } catch (_) {}
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
          cached = Metadata.fromJson(
            json,
            tags: jsonDecode(row.tagsJson) as List,
          );
          cachedCreatedAt = row.createdAt;
        }
      } catch (_) {}
    }
  }
  // 2. In-memory EventStore (kind-0 arrives via the following/outbox subs
  // and targeted fetches; the global firehose no longer feeds the store).
  if (cached == null) {
    for (final e in ref.read(eventStoreProvider)) {
      if (e.kind == 0 && e.pubkey == pubkey) {
        try {
          final json = jsonDecode(e.content);
          if (json is Map<String, dynamic>) {
            cached = Metadata.fromJson(json, tags: e.tags);
            cachedCreatedAt = e.createdAt;
          }
        } catch (_) {}
        break;
      }
    }
  }
  // 2.5 Ephemeral global window: while the 全球 tab is open, strangers'
  // kind-0 lives ONLY here (never stored, never persisted — user decision).
  if (cached == null) {
    final metaEvent = ref
        .read(globalFeedWindowProvider.notifier)
        .window
        .metadataFor(pubkey);
    if (metaEvent != null) {
      try {
        final json = jsonDecode(metaEvent.content);
        if (json is Map<String, dynamic>) {
          cached = Metadata.fromJson(json, tags: metaEvent.tags);
          cachedCreatedAt = metaEvent.createdAt;
        }
      } catch (_) {}
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
        unawaited(
          db.writeEvent(
            id: e.id,
            pubkey: e.pubkey,
            kind: 0,
            createdAt: e.createdAt,
            content: e.content,
            sig: e.sig,
            raw: jsonEncode(e.toWireObject()),
            tagsJson: jsonEncode(e.tags),
            tags: e.tags,
          ),
        );
      }
      ctrl.add(Metadata.fromJson(json, tags: e.tags));
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
    // The controller CLOSES on EOSE / the 8s timer, but this listener
    // deliberately stays alive to keep persisting fresher statuses — guard
    // the add (this used to throw "Cannot add event after closing" whenever
    // a status event arrived after the initial fetch window).
    if (!ctrl.isClosed) ctrl.add(text);
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

/// Classification + Open Graph preview for bare http(s) URLs in note content
/// (lib/services/link_preview.dart): extension-less images (小红书-style
/// `?imageView2/…/format/jpg` links), signed video links, and webpages with
/// og: tags. The URL stays a plain clickable link until the probe settles;
/// image/video results are injected into the content tokenizer as
/// tag-declared media, webpage results become preview cards.
///
/// Cached per URL for the session — negative results ([UrlNone]) included:
/// they are tiny, and caching them keeps a dead host from being re-probed on
/// every rebuild. In-flight dedup is automatic for the family. No SQLite
/// tier — same trade-off as [nip05VerifiedProvider].
final linkPreviewProvider = FutureProvider.family<UrlInspection, String>(
  (ref, url) => inspectUrl(url),
);

/// ChangeNotifier bridge so GoRouter re-evaluates redirects on login/logout.
class GoRouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}
