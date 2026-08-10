/// Decentralized server discovery (精简版) — recommends working servers for
/// the customize sheet WITHOUT any central directory server. DESIGN.md §13.
///
/// Candidates come from the user's OWN view of the network:
/// - relay/search: `r` tags of every kind-10002 (NIP-65 relay list) cached in
///   SQLite + a bounded live REQ to the already-connected relays;
/// - blossom: `server` tags of every kind-10063 (Blossom server list), same
///   two sources.
/// URLs are voted on (how many distinct users' lists mention them) and
/// already-configured ones are dropped.
///
/// Every candidate is then PROBED before recommendation:
/// - relay:  connectable (transient WS probe) + free (NIP-11 limitation/fees,
///           when the relay answers NIP-11 — no answer = unknown, kept);
/// - search: connectable + free + self-declared NIP-50 support in NIP-11
///           (without the doc we can't verify search support → not
///           recommended; the empirical gibberish-search probe is deferred);
/// - blossom: a REAL test upload under the logged-in identity — the only
///           check that proves "Blossom protocol + free + no whitelist" at
///           once. Logged out → no blossom recommendations;
/// - indexer: NOT recommended this iteration — there is no cheap trustworthy
///           signal for "indexes everyone's metadata".
///
/// Results are ranked (votes → NIP-11-confirmed-free → URL), capped at
/// [maxRecommendations], and cached 24h under `server_reco:<category>`
/// (empty results are NOT cached so a transient network failure doesn't hide
/// recommendations for a day).
///
/// Rotation (「换一批」) is ROLLING, not permanent exclusion: a per-category
/// memory of already-recommended URLs is kept under
/// `server_reco_seen:<category>`. An explicit refresh excludes the seen URLs
/// so each batch shows NEW servers; but as soon as there is no NEW
/// recommendable server left — every candidate already shown, OR the only
/// unseen ones fail probing — the memory resets and drawing starts back at
/// the top (first) batch. Dedup is per-cycle only, so a small pool cycles
/// through its working servers instead of going empty forever.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app/server_list_rules.dart';
import '../nostr/identity.dart';
import '../nostr/relay_client.dart';
import '../nostr/relay_pool.dart';
import 'blossom_upload.dart';
import 'local_cache.dart' as cache;

const int maxRecommendations = 10;
const int maxProbeCandidates = 20;
/// Rotation memory cap: at most this many already-recommended URLs are kept
/// per category (~5 full batches). Oldest entries are dropped first, so very
/// large pools still rotate instead of stalling on a full memory.
const int maxSeenUrls = 50;
// Probing is mostly WAITING (WS handshake + NIP-11 fetch, both capped), so a
// wider pool keeps the total wall time short even when many candidates are
// GFW-blocked and each burns its full connect timeout.
const int discoveryConcurrency = 8;
const Duration discoveryCacheTtl = Duration(hours: 24);

/// Config key holding the cached recommendation (`{"at":…, "urls":[…]}`).
String discoveryCacheKey(ServerCategory category) =>
    'server_reco:${category.name}';

/// Config key holding the rotation memory for 「换一批」: JSON list of URLs
/// already recommended for this category, oldest first.
String discoverySeenKey(ServerCategory category) =>
    'server_reco_seen:${category.name}';

/// Merge freshly-shown [shown] URLs into the rotation memory [seen]:
/// duplicates collapsed (a re-shown URL moves to the end), order preserved
/// otherwise, capped at [cap] by dropping the OLDEST entries. Pure so the
/// rotation bookkeeping is unit-testable without I/O.
List<String> mergeSeenUrls(
  List<String> seen,
  List<String> shown, {
  int cap = maxSeenUrls,
}) {
  final merged = <String>[];
  final known = <String>{};
  for (final url in seen) {
    if (!shown.contains(url) && known.add(url)) merged.add(url);
  }
  for (final url in shown) {
    if (known.add(url)) merged.add(url);
  }
  return merged.length <= cap
      ? merged
      : merged.sublist(merged.length - cap);
}

/// Whether discovery can recommend for [category] at all this iteration.
/// Indexer has no cheap trustworthy signal (see library doc) → the UI hides
/// the recommendation block for it.
bool discoverySupported(ServerCategory category) =>
    category != ServerCategory.indexer;

// ---------------------------------------------------------------------------
// Pure candidate aggregation (unit-tested without I/O)
// ---------------------------------------------------------------------------

/// Normalized `wss://`/`ws://` URLs from the `r` tags of a NIP-65 kind-10002
/// relay list (read/write markers ignored — a relay mentioned at all counts).
List<String> relayUrlsFromTags(List<List<dynamic>> tags) {
  final out = <String>[];
  for (final t in tags) {
    if (t.length < 2 || t[0] != 'r') continue;
    final url = normalizeServerUrl('${t[1]}');
    if (url.startsWith('wss://') || url.startsWith('ws://')) out.add(url);
  }
  return out;
}

/// Normalized `https://` URLs from a kind-10063 Blossom server list. Accepts
/// both `server` tags (the convention) and plain `r` tags.
List<String> blossomUrlsFromTags(List<List<dynamic>> tags) {
  final out = <String>[];
  for (final t in tags) {
    if (t.length < 2 || (t[0] != 'server' && t[0] != 'r')) continue;
    final url = normalizeServerUrl('${t[1]}');
    if (url.startsWith('https://')) out.add(url);
  }
  return out;
}

/// Parse a stored replaceable row's `tagsJson` into tag lists. Malformed JSON
/// → empty (a bad row must never sink a discovery run).
List<List<dynamic>> parseTagsJson(String tagsJson) {
  try {
    final decoded = jsonDecode(tagsJson);
    if (decoded is! List) return const <List<dynamic>>[];
    return decoded
        .whereType<List>()
        .map((t) => List<dynamic>.of(t))
        .toList(growable: false);
  } catch (_) {
    return const <List<dynamic>>[];
  }
}

/// Vote count per normalized URL: how many source events mention it. [urls]
/// is one iterable of URLs per source event (already normalized).
Map<String, int> voteServerUrls(Iterable<Iterable<String>> urls) {
  final votes = <String, int>{};
  for (final perEvent in urls) {
    // One vote per URL per event even if a malformed list repeats a URL.
    for (final url in perEvent.toSet()) {
      votes[url] = (votes[url] ?? 0) + 1;
    }
  }
  return votes;
}

/// Pick the best candidates from [votes]: drop [exclude]d URLs (already
/// configured on this device), sort by votes desc — ties broken by [boost]
/// membership first (NIP-11-confirmed-free sorts ahead of unknown) then by
/// URL for stable output — and cap at [limit].
List<String> topServerCandidates(
  Map<String, int> votes, {
  required Set<String> exclude,
  Set<String> boost = const {},
  int limit = maxRecommendations,
}) {
  final entries = votes.entries.where((e) => !exclude.contains(e.key)).toList()
    ..sort((a, b) {
      final byVotes = b.value.compareTo(a.value);
      if (byVotes != 0) return byVotes;
      final byBoost =
          (boost.contains(b.key) ? 1 : 0) - (boost.contains(a.key) ? 1 : 0);
      if (byBoost != 0) return byBoost;
      return a.key.compareTo(b.key);
    });
  return entries.take(limit).map((e) => e.key).toList();
}

/// Map [fn] over [items] with at most [concurrency] calls in flight; results
/// keep input order.
Future<List<R>> mapConcurrent<T, R>(
  Iterable<T> items,
  int concurrency,
  Future<R> Function(T item) fn,
) async {
  final list = items.toList();
  final results = List<R?>.filled(list.length, null);
  var next = 0; // single-threaded: safe to increment between awaits
  Future<void> worker() async {
    while (true) {
      final i = next++;
      if (i >= list.length) return;
      results[i] = await fn(list[i]);
    }
  }

  final workers = <Future<void>>[];
  for (var w = 0; w < concurrency && w < list.length; w++) {
    workers.add(worker());
  }
  await Future.wait(workers);
  return results.cast<R>();
}

// ---------------------------------------------------------------------------
// NIP-11 relay information document
// ---------------------------------------------------------------------------

/// Parsed NIP-11 fields discovery cares about (free-ness + NIP-50 support).
class Nip11Info {
  const Nip11Info({
    required this.authRequired,
    required this.paymentRequired,
    required this.admissionFee,
    required this.publicationFee,
    required this.supportedNips,
  });

  final bool authRequired;
  final bool paymentRequired;
  final num admissionFee;
  final num publicationFee;
  final List<int> supportedNips;

  /// Free = no forced auth, no payment required, no admission/publication fee.
  bool get isFree =>
      !authRequired &&
      !paymentRequired &&
      admissionFee <= 0 &&
      publicationFee <= 0;

  bool get supportsNip50 => supportedNips.contains(50);

  /// Parse a NIP-11 document. Null on anything unexpected — callers treat
  /// null as "unknown" (many fine relays don't serve NIP-11 at all).
  static Nip11Info? parse(dynamic doc) {
    if (doc is! Map) return null;
    final limitation = doc['limitation'];
    final fees = doc['fees'];
    num fee(String key) {
      if (fees is! Map) return 0;
      final v = fees[key];
      return v is num ? v : 0;
    }

    final nips = <int>[];
    final rawNips = doc['supported_nips'];
    if (rawNips is List) {
      for (final n in rawNips) {
        if (n is int) nips.add(n);
      }
    }
    return Nip11Info(
      authRequired: limitation is Map && limitation['auth_required'] == true,
      paymentRequired:
          limitation is Map && limitation['payment_required'] == true,
      admissionFee: fee('admission'),
      publicationFee: fee('publication'),
      supportedNips: nips,
    );
  }
}

final http.Client _nip11Client = http.Client();

/// Fetch a relay's NIP-11 info document: HTTP(S) GET on the WS URL with the
/// `application/nostr+json` Accept header. Null when unreachable / non-200 /
/// unparsable — callers treat that as UNKNOWN, not as "not free".
Future<Nip11Info?> fetchNip11(
  String relayUrl, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 4),
}) async {
  final httpUrl = relayUrl
      .replaceFirst('wss://', 'https://')
      .replaceFirst('ws://', 'http://');
  final uri = Uri.tryParse(httpUrl);
  if (uri == null) return null;
  final c = client ?? _nip11Client;
  try {
    final res = await c
        .get(uri, headers: const {'Accept': 'application/nostr+json'})
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    return Nip11Info.parse(jsonDecode(res.body));
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Probes
// ---------------------------------------------------------------------------

/// WS liveness probe: open a TRANSIENT connection to [url], ask for one
/// recent kind-1 (`REQ {kinds:[1], limit:1}`); alive = any EVENT or EOSE
/// frame within [timeout] after connect. Follows RelayPool.fetchFromUrls'
/// transient-client discipline: subscriptions cancelled + client disposed on
/// EVERY exit path. [makeClient] is injectable (tests use a fake).
///
/// [connectTimeout] is deliberately SHORT (default 5s): from mainland China a
/// GFW-blocked foreign relay never completes its WS handshake, and every such
/// candidate must fail fast so a recommendation run isn't dragged out by a
/// long tail of unreachable relays (the "一直加载中" complaint).
Future<bool> probeRelayAlive(
  String url, {
  RelayConnection Function(String url)? makeClient,
  Duration timeout = const Duration(seconds: 8),
  Duration connectTimeout = const Duration(seconds: 5),
}) async {
  final c = (makeClient ?? RelayClient.new)(url);
  final done = Completer<void>();
  final evSub = c.events.listen((_) {
    if (!done.isCompleted) done.complete();
  });
  final eoseSub = c.eose.listen((_) {
    if (!done.isCompleted) done.complete();
  });
  try {
    // RelayClient.connect never throws — it awaits the handshake (10s cap
    // internally) and leaves isConnected false on failure; the [connectTimeout]
    // wrapper fails fast on GFW-blackholed relays, and also covers fakes/odd
    // transports that could hang.
    await c.connect().timeout(connectTimeout);
    if (!c.isConnected) return false;
    c.request('costr:probe', const {
      'kinds': [1],
      'limit': 1,
    });
    await done.future.timeout(timeout);
    return true;
  } catch (_) {
    return false;
  } finally {
    await evSub.cancel();
    await eoseSub.cancel();
    try {
      c.closeSubscription('costr:probe');
    } catch (_) {}
    await c.dispose();
  }
}

/// The only check that proves "Blossom protocol + free + no whitelist" at
/// once: actually upload a few bytes under the user's identity (kind-24242
/// auth event). Any 2xx means the server accepted a real upload from this
/// account. The probe blob is 5 bytes of text; it becomes a (harmless,
/// tiny) public blob on the server — inherent to testing uploads.
Future<bool> probeBlossomWritable(
  String serverUrl,
  Identity identity, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  try {
    final result = await blossomUpload(
      identity,
      utf8.encode('costr'),
      mimetype: 'text/plain',
      note: 'costr server discovery probe',
      servers: [serverUrl],
      timeout: timeout,
      client: client,
    );
    return result != null;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Orchestrator
// ---------------------------------------------------------------------------

class _RelayProbeResult {
  const _RelayProbeResult(this.alive, this.nip11);
  final bool alive;
  final Nip11Info? nip11;
}

/// Discovers recommendable servers for one customize-sheet session. All I/O
/// dependencies are injectable: [db] (votes + cache + configured lists),
/// [pool] (bounded live sampling + its [RelayPool.makeClient] for probes),
/// [identity] (blossom test uploads), [httpClient] (NIP-11 + test uploads).
class ServerDiscovery {
  ServerDiscovery({
    required this.db,
    this.pool,
    this.identity,
    this.httpClient,
    RelayConnection Function(String url)? makeClient,
    this.candidateCap = maxProbeCandidates,
    this.recoCap = maxRecommendations,
    this.concurrency = discoveryConcurrency,
    this._cacheTtl = discoveryCacheTtl,
  }) : makeClient = makeClient ?? RelayClient.new;

  final cache.LocalCache db;
  final RelayPool? pool;
  final Identity? identity;
  final http.Client? httpClient;
  final RelayConnection Function(String url) makeClient;
  final int candidateCap;
  final int recoCap;
  final int concurrency;
  final Duration _cacheTtl;

  /// Recommended servers for [category] (≤ [recoCap]). Reads the 24h cache
  /// unless [force]; empty list = nothing recommendable (the UI hides the
  /// block). Unsupported categories (indexer, this iteration) → always empty.
  ///
  /// [force] (「换一批」) also rotates: URLs already recommended earlier are
  /// excluded so each refresh shows a NEW batch; when the pool of unseen
  /// candidates is exhausted the rotation memory resets and drawing starts
  /// from the top again.
  Future<List<String>> recommend(
    ServerCategory category, {
    bool force = false,
  }) async {
    if (!discoverySupported(category)) return const <String>[];
    var seen = const <String>[];
    if (!force) {
      final cached = await _readCache(category);
      if (cached != null) return cached;
      // Fresh draw (first run or cache expired) → the rotation restarts from
      // the top candidates; drop any stale rotation memory.
      await _writeSeen(category, const <String>[]);
    } else {
      seen = await _readSeen(category);
      if (seen.isEmpty) {
        // First rotation after the memory was introduced (or lost): treat the
        // batch currently in the cache — what the user is looking at right
        // now — as already shown, so 「换一批」 doesn't just re-serve it.
        final cached = await _readCache(category);
        if (cached != null) seen = cached;
      }
    }
    // Rolling recommendation (滚动推荐): dedup is per-CYCLE, not permanent.
    // Show servers not yet shown this cycle; when there is no NEW
    // recommendable server left — either every candidate was already shown,
    // or the only unseen ones fail probing — roll back to the top (first)
    // batch instead of going empty. Otherwise a few taps of 「换一批」 would
    // leave the user staring at nothing forever. `seen` empty = genuinely
    // first draw, nothing to roll back to.
    var urls = category == ServerCategory.blossom
        ? await _recommendBlossom(excludeSeen: seen.toSet())
        : await _recommendRelays(category, excludeSeen: seen.toSet());
    var wrapped = false;
    if (urls.isEmpty && seen.isNotEmpty) {
      urls = category == ServerCategory.blossom
          ? await _recommendBlossom(excludeSeen: const <String>{})
          : await _recommendRelays(category, excludeSeen: const <String>{});
      wrapped = true;
    }
    if (urls.isNotEmpty) {
      await _writeCache(category, urls);
      // After a wrap the cycle restarts from this batch; otherwise the batch
      // is appended to what was already shown this cycle.
      await _writeSeen(
        category,
        mergeSeenUrls(wrapped ? const <String>[] : seen, urls),
      );
    }
    return urls;
  }

  // --- relay / search ---

  /// Candidates for [category] that pass the probes, excluding [excludeSeen]
  /// (already shown this rotation cycle) and the configured servers. Empty
  /// when nothing NEW is recommendable; [recommend] then rolls back to the
  /// top batch (rolling recommendation — dedup is per-cycle, not permanent).
  Future<List<String>> _recommendRelays(
    ServerCategory category, {
    Set<String> excludeSeen = const {},
  }) async {
    final votes = await _aggregateRelayVotes();
    if (votes.isEmpty) return const <String>[];
    final configured = await _configuredUrls();
    final candidates = topServerCandidates(
      votes,
      exclude: {...configured, ...excludeSeen},
      limit: candidateCap,
    );
    if (candidates.isEmpty) return const <String>[];

    final results = await mapConcurrent(
      candidates,
      concurrency,
      _probeRelayCandidate,
    );
    final passed = <String>[];
    final freeConfirmed = <String>{};
    for (var i = 0; i < candidates.length; i++) {
      final url = candidates[i];
      final r = results[i];
      if (!r.alive) continue;
      // Declared paid/auth-required → never recommend. No NIP-11 answer =
      // unknown → still recommendable (many good relays skip NIP-11); the
      // liveness probe is the primary gate.
      if (r.nip11 != null && !r.nip11!.isFree) continue;
      if (category == ServerCategory.search) {
        // Search relays must SELF-DECLARE NIP-50 in NIP-11. Without the doc
        // we can't verify search support → don't recommend as search.
        if (r.nip11 == null || !r.nip11!.supportsNip50) continue;
      }
      passed.add(url);
      if (r.nip11 != null && r.nip11!.isFree) freeConfirmed.add(url);
    }
    if (passed.isEmpty) return const <String>[];
    return topServerCandidates(
      {for (final u in passed) u: votes[u] ?? 0},
      exclude: const {},
      boost: freeConfirmed,
      limit: recoCap,
    );
  }

  Future<_RelayProbeResult> _probeRelayCandidate(String url) async {
    // NIP-11 fetch and WS liveness run together — they're independent.
    final results = await Future.wait<Object?>([
      probeRelayAlive(url, makeClient: makeClient),
      fetchNip11(url, client: httpClient),
    ]);
    return _RelayProbeResult(results[0] == true, results[1] as Nip11Info?);
  }

  /// Votes from every kind-10002 the app has cached, plus a BOUNDED live REQ
  /// `{kinds:[10002], limit:100}` to the currently-connected relays (cold
  /// users have few cached lists; this tops the sample up without depending
  /// on any central directory). One vote per distinct event per URL.
  Future<Map<String, int>> _aggregateRelayVotes() async {
    final perEvent = <List<String>>[];
    final seenIds = <String>{};
    void addEvent(String id, List<List<dynamic>> tags) {
      if (!seenIds.add(id)) return;
      perEvent.add(relayUrlsFromTags(tags));
    }

    try {
      for (final row in await db.queryAllReplaceableOfKind(10002)) {
        addEvent(row.id, parseTagsJson(row.tagsJson));
      }
    } catch (_) {}
    final pool = this.pool;
    if (pool != null) {
      final urls = pool.states.map((s) => s.url).toList();
      if (urls.isNotEmpty) {
        try {
          final events = await pool.fetchFromUrls(
            const {
              'kinds': [10002],
              'limit': 100,
            },
            urls,
            timeout: const Duration(seconds: 8),
          );
          for (final e in events) {
            addEvent(e.id, e.tags);
          }
        } catch (_) {}
      }
    }
    return voteServerUrls(perEvent);
  }

  // --- blossom ---

  /// Blossom candidates that pass the test-upload probe, excluding
  /// [excludeSeen] + configured servers. Empty when nothing NEW is
  /// recommendable; [recommend] then rolls back to the top batch.
  Future<List<String>> _recommendBlossom({
    Set<String> excludeSeen = const {},
  }) async {
    final identity = this.identity;
    // Logged out → the test-upload probe can't run; the UI shows a hint.
    if (identity == null) return const <String>[];

    final perEvent = <List<String>>[];
    final seenIds = <String>{};
    void addEvent(String id, List<List<dynamic>> tags) {
      if (!seenIds.add(id)) return;
      perEvent.add(blossomUrlsFromTags(tags));
    }

    try {
      for (final row in await db.queryAllReplaceableOfKind(10063)) {
        addEvent(row.id, parseTagsJson(row.tagsJson));
      }
    } catch (_) {}
    final pool = this.pool;
    if (pool != null) {
      final urls = pool.states.map((s) => s.url).toList();
      if (urls.isNotEmpty) {
        try {
          final events = await pool.fetchFromUrls(
            const {
              'kinds': [10063],
              'limit': 50,
            },
            urls,
            timeout: const Duration(seconds: 8),
          );
          for (final e in events) {
            addEvent(e.id, e.tags);
          }
        } catch (_) {}
      }
    }

    final votes = voteServerUrls(perEvent);
    if (votes.isEmpty) return const <String>[];
    final configured = await _configuredUrls();
    final candidates = topServerCandidates(
      votes,
      exclude: {...configured, ...excludeSeen},
      limit: candidateCap,
    );
    if (candidates.isEmpty) return const <String>[];

    final writable = await mapConcurrent(
      candidates,
      concurrency,
      (url) => probeBlossomWritable(url, identity, client: httpClient),
    );
    final passedVotes = <String, int>{};
    for (var i = 0; i < candidates.length; i++) {
      if (writable[i]) passedVotes[candidates[i]] = votes[candidates[i]] ?? 0;
    }
    if (passedVotes.isEmpty) return const <String>[];
    return topServerCandidates(passedVotes, exclude: const {}, limit: recoCap);
  }

  // --- shared helpers ---

  /// URLs already configured in ANY of the 4 lists — never recommend what the
  /// user already has.
  Future<Set<String>> _configuredUrls() async {
    final all = <String>{};
    for (final key in serverListKeys.values) {
      try {
        final list = await db.readServerList(key);
        if (list != null) all.addAll(list.map(normalizeServerUrl));
      } catch (_) {}
    }
    return all;
  }

  Future<List<String>?> _readCache(ServerCategory category) async {
    try {
      final raw = await db.readConfig(discoveryCacheKey(category));
      if (raw == null || raw.isEmpty) return null;
      final doc = jsonDecode(raw);
      if (doc is! Map) return null;
      final at = doc['at'];
      final urls = doc['urls'];
      if (at is! int || urls is! List) return null;
      final age = DateTime.now().millisecondsSinceEpoch ~/ 1000 - at;
      if (age < 0 || age > _cacheTtl.inSeconds) return null;
      final list = urls
          .whereType<String>()
          .where((u) => u.isNotEmpty)
          .toList(growable: false);
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(ServerCategory category, List<String> urls) async {
    try {
      await db.writeConfig(
        discoveryCacheKey(category),
        jsonEncode({
          'at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          'urls': urls,
        }),
      );
    } catch (_) {}
  }

  // --- rotation memory (「换一批」 dedup) ---

  /// Already-recommended URLs for [category] (oldest first). Empty on any
  /// read problem — a broken memory must degrade to "no dedup", never crash.
  Future<List<String>> _readSeen(ServerCategory category) async {
    try {
      final raw = await db.readConfig(discoverySeenKey(category));
      if (raw == null || raw.isEmpty) return const <String>[];
      final doc = jsonDecode(raw);
      if (doc is! List) return const <String>[];
      return doc
          .whereType<String>()
          .where((u) => u.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const <String>[];
    }
  }

  Future<void> _writeSeen(ServerCategory category, List<String> urls) async {
    try {
      await db.writeConfig(discoverySeenKey(category), jsonEncode(urls));
    } catch (_) {}
  }
}
