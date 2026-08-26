/// Local cache (drift/SQLite) for Nostr events — 30-day persistent store.
library;

import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'local_cache.g.dart';

@DataClassName('EventRow')
class Events extends Table {
  TextColumn get id => text()();
  TextColumn get pubkey => text()();
  IntColumn get kind => integer()();
  IntColumn get createdAt => integer()();
  TextColumn get content => text()();
  TextColumn get sig => text()();
  TextColumn get raw => text()();
  TextColumn get tagsJson => text()();
  IntColumn get receivedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Outbox drafts — events that failed to publish, stored for retry.
class Drafts extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get rawJson => text()();
  IntColumn get createdAt => integer()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();

  @override
  String get tableName => 'drafts';
}

class ReplaceableEvents extends Table {
  TextColumn get pubkey => text()();
  IntColumn get kind => integer()();
  TextColumn get dTag => text().withDefault(const Constant(''))();
  TextColumn get id => text()();
  IntColumn get createdAt => integer()();
  TextColumn get content => text()();
  TextColumn get sig => text()();
  TextColumn get raw => text()();
  TextColumn get tagsJson => text()();

  @override
  Set<Column> get primaryKey => {pubkey, kind, dTag};
}

class EventTags extends Table {
  TextColumn get eventId => text()();
  TextColumn get name => text()();
  TextColumn get value => text()();
  IntColumn get position => integer()();

  @override
  Set<Column> get primaryKey => {eventId, position};
}

class ConfigTable extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

class RelayConfig extends Table {
  TextColumn get url => text()();
  IntColumn get enabled => integer().withDefault(const Constant(1))();
  IntColumn get read => integer().withDefault(const Constant(1))();
  IntColumn get write => integer().withDefault(const Constant(1))();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {url};
}

@DriftDatabase(
  tables: [
    Events,
    ReplaceableEvents,
    EventTags,
    ConfigTable,
    RelayConfig,
    Drafts,
  ],
)
class LocalCache extends _$LocalCache {
  LocalCache(super.e);

  factory LocalCache.open(String dbPath) {
    return LocalCache(NativeDatabase.createInBackground(File(dbPath)));
  }

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
      await _createIndexes(m);
      await _createFts(m);
    },
    onUpgrade: (m, from, to) async {
      if (from < 2) {
        await m.createTable(drafts);
      }
    },
  );

  Future<void> _createIndexes(Migrator m) async {
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_events_pubkind ON events(pubkey, kind, created_at DESC)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_events_kindtime ON events(kind, created_at DESC)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_events_pubtime ON events(pubkey, created_at DESC)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at DESC)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tags_nameval ON event_tags(name, value)',
    );
    await m.database.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_tags_event ON event_tags(event_id)',
    );
  }

  Future<void> _createFts(Migrator m) async {
    await m.database.customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5("
      "content, pubkey, kind, content=events, content_rowid=rowid, "
      "tokenize='unicode61')",
    );
    await m.database.customStatement(
      "CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN "
      "INSERT INTO events_fts(rowid, content, pubkey, kind) "
      "VALUES (new.rowid, new.content, new.pubkey, new.kind); END",
    );
    await m.database.customStatement(
      "CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN "
      "DELETE FROM events_fts WHERE rowid = old.rowid; END",
    );
  }

  // --- Write ---

  Future<void> writeEvent({
    required String id,
    required String pubkey,
    required int kind,
    required int createdAt,
    required String content,
    required String sig,
    required String raw,
    required String tagsJson,
    required List<List<dynamic>> tags,
  }) async {
    final isReplaceable =
        kind == 0 ||
        kind == 3 ||
        (kind >= 10000 && kind < 20000) ||
        (kind >= 30000 && kind < 40000);

    if (isReplaceable) {
      String dTag = '';
      for (final t in tags) {
        if (t.length >= 2 && t[0] == 'd' && t[1] is String) {
          dTag = t[1] as String;
          break;
        }
      }
      // Newest-wins guard: different relays serve different revisions of the
      // same replaceable event, and they arrive in arbitrary order (a relay
      // that missed a rename still serves the older revision).
      // insertOnConflictUpdate is last-write-wins, so without this check a
      // stale revision arriving late permanently replaces the newer row —
      // e.g. a pre-rename kind-30000 with no `name` tag makes the follow
      // list render as its UUID `d` identifier until the newer revision
      // happens to be re-ingested (the "列表名偶尔变 UUID，重启恢复" bug).
      final existing = await queryReplaceable(pubkey, kind, dTag: dTag);
      if (existing != null && existing.createdAt > createdAt) return;
      await into(replaceableEvents).insertOnConflictUpdate(
        ReplaceableEventsCompanion.insert(
          pubkey: pubkey,
          kind: kind,
          dTag: Value(dTag),
          id: id,
          createdAt: createdAt,
          content: content,
          sig: sig,
          raw: raw,
          tagsJson: tagsJson,
        ),
      );
    } else {
      await customStatement(
        'INSERT OR IGNORE INTO events(id, pubkey, kind, created_at, content, sig, raw, tags_json, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          id,
          pubkey,
          kind,
          createdAt,
          content,
          sig,
          raw,
          tagsJson,
          DateTime.now().millisecondsSinceEpoch ~/ 1000,
        ],
      );
      if (kind == 1 || kind == 6 || kind == 7) {
        for (var i = 0; i < tags.length; i++) {
          final t = tags[i];
          if (t.length < 2) continue;
          await customStatement(
            'INSERT OR IGNORE INTO event_tags(event_id, name, value, position) VALUES (?, ?, ?, ?)',
            [id, t[0].toString(), t[1].toString(), i],
          );
        }
      }
    }
  }

  // --- Read ---

  Future<List<EventRow>> queryFeed({int limit = 200}) {
    return (select(events)
          ..where((e) => e.kind.isIn(const [1, 6]))
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .get();
  }

  /// Kind-1/6 feed rows authored by any of [authors], newest first. Used to
  /// hydrate ONE account's following feed from the shared [events] table: the
  /// table holds posts cached for EVERY account on the device, so loading the
  /// global newest-N (the old [queryFeed] path) let other accounts' followees
  /// crowd out the active account's and its following feed hydrated empty.
  /// Scoping to the account's follows (+ own posts) makes each account's feed
  /// restore instantly regardless of how many accounts share the device.
  /// [authors] may be empty → no rows (a follows-less account has no feed).
  Future<List<EventRow>> queryFeedForAuthors(
    List<String> authors, {
    int limit = 1000,
  }) {
    if (authors.isEmpty) return Future.value(const <EventRow>[]);
    return (select(events)
          ..where((e) => e.pubkey.isIn(authors) & e.kind.isIn(const [1, 6]))
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .get();
  }

  Future<List<EventRow>> queryUserPosts(String pubkey, {int limit = 100}) {
    return (select(events)
          ..where((e) => e.pubkey.equals(pubkey) & e.kind.equals(1))
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .get();
  }

  Future<ReplaceableEvent?> queryMetadata(String pubkey) async {
    final q = select(replaceableEvents)
      ..where((e) => e.pubkey.equals(pubkey) & e.kind.equals(0))
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first;
  }

  /// Generic replaceable-event lookup by pubkey + kind + `d` tag (for
  /// NIP-51 kind-30000 follow sets, NIP-38 kind-30315 user statuses, …).
  /// [dTag] defaults to '' (the default list / general status).
  Future<ReplaceableEvent?> queryReplaceable(
    String pubkey,
    int kind, {
    String dTag = '',
  }) async {
    final q = select(replaceableEvents)
      ..where(
        (e) =>
            e.pubkey.equals(pubkey) & e.kind.equals(kind) & e.dTag.equals(dTag),
      )
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first;
  }

  /// All replaceable events of [kind] authored by [pubkey] — e.g. every
  /// kind-30000 follow set (one per `d` tag = group name) for a user. Used to
  /// hydrate the profile's grouped-follows / group-names from SQLite on cold
  /// start instead of waiting for relays. Ordered by `dTag` for stable output.
  Future<List<ReplaceableEvent>> queryReplaceableByAuthor(
    String pubkey,
    int kind,
  ) async {
    final q = select(replaceableEvents)
      ..where((e) => e.pubkey.equals(pubkey) & e.kind.equals(kind))
      ..orderBy([(e) => OrderingTerm.asc(e.dTag)]);
    return q.get();
  }

  /// Convenience: all kind-30000 follow sets for [pubkey]. See
  /// [queryReplaceableByAuthor].
  Future<List<ReplaceableEvent>> queryFollowSets(String pubkey) =>
      queryReplaceableByAuthor(pubkey, 30000);

  Future<List<EventRow>> queryReactions(String eventId) async {
    final results = await customSelect(
      'SELECT e.* FROM events e JOIN event_tags t ON e.id = t.event_id WHERE e.kind = 7 AND t.name = ? AND t.value = ?',
      variables: [Variable('e'), Variable(eventId)],
    ).get();
    return results
        .map(
          (r) => EventRow(
            id: r.read<String>('id'),
            pubkey: r.read<String>('pubkey'),
            kind: r.read<int>('kind'),
            createdAt: r.read<int>('created_at'),
            content: r.read<String>('content'),
            sig: r.read<String>('sig'),
            raw: r.read<String>('raw'),
            tagsJson: r.read<String>('tags_json'),
            receivedAt: r.read<int>('received_at'),
          ),
        )
        .toList();
  }

  Future<EventRow?> queryEventById(String id) async {
    final q = select(events)
      ..where((e) => e.id.equals(id))
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<EventRow>> queryReplies(String eventId) async {
    final results = await customSelect(
      'SELECT e.* FROM events e JOIN event_tags t ON e.id = t.event_id WHERE e.kind = 1 AND t.name = ? AND t.value = ? ORDER BY e.created_at DESC',
      variables: [Variable('e'), Variable(eventId)],
    ).get();
    return results
        .map(
          (r) => EventRow(
            id: r.read<String>('id'),
            pubkey: r.read<String>('pubkey'),
            kind: r.read<int>('kind'),
            createdAt: r.read<int>('created_at'),
            content: r.read<String>('content'),
            sig: r.read<String>('sig'),
            raw: r.read<String>('raw'),
            tagsJson: r.read<String>('tags_json'),
            receivedAt: r.read<int>('received_at'),
          ),
        )
        .toList();
  }

  /// Cached kind-1 notes carrying a `t` tag = [tag] (NIP-12 hashtags), so the
  /// hashtag feed can hydrate from SQLite on cold start / offline instead of
  /// scanning only the in-memory EventStore (≤5000, recent-window only).
  /// [tag] is matched case-insensitively (NIP-12 values are lowercased on
  /// write), newest-first.
  Future<List<EventRow>> queryPostsByTag(String tag, {int limit = 200}) async {
    final results = await customSelect(
      'SELECT e.* FROM events e JOIN event_tags t ON e.id = t.event_id '
      'WHERE e.kind = 1 AND t.name = ? AND LOWER(t.value) = LOWER(?) '
      'ORDER BY e.created_at DESC LIMIT ?',
      variables: [Variable('t'), Variable(tag), Variable(limit)],
    ).get();
    return results
        .map(
          (r) => EventRow(
            id: r.read<String>('id'),
            pubkey: r.read<String>('pubkey'),
            kind: r.read<int>('kind'),
            createdAt: r.read<int>('created_at'),
            content: r.read<String>('content'),
            sig: r.read<String>('sig'),
            raw: r.read<String>('raw'),
            tagsJson: r.read<String>('tags_json'),
            receivedAt: r.read<int>('received_at'),
          ),
        )
        .toList();
  }

  Future<List<EventRow>> searchEvents(String query, {int limit = 100}) async {
    final results = await customSelect(
      'SELECT e.* FROM events e JOIN events_fts f ON e.rowid = f.rowid WHERE e.kind = 1 AND events_fts MATCH ? ORDER BY e.created_at DESC LIMIT ?',
      variables: [Variable(query), Variable(limit)],
    ).get();
    return results
        .map(
          (r) => EventRow(
            id: r.read<String>('id'),
            pubkey: r.read<String>('pubkey'),
            kind: r.read<int>('kind'),
            createdAt: r.read<int>('created_at'),
            content: r.read<String>('content'),
            sig: r.read<String>('sig'),
            raw: r.read<String>('raw'),
            tagsJson: r.read<String>('tags_json'),
            receivedAt: r.read<int>('received_at'),
          ),
        )
        .toList();
  }

  Future<List<ReplaceableEvent>> queryAllMetadata() {
    return (select(replaceableEvents)..where((e) => e.kind.equals(0))).get();
  }

  /// All cached replaceable events of [kind], across ALL authors — e.g. every
  /// kind-10002 (NIP-65 relay list) or kind-10063 (Blossom server list) the
  /// app has ever fetched. Server discovery aggregates candidate servers from
  /// these (the user's own view of the network — no central directory).
  /// Newest first, capped so a huge table can't stall a discovery run.
  Future<List<ReplaceableEvent>> queryAllReplaceableOfKind(
    int kind, {
    int limit = 500,
  }) {
    return (select(replaceableEvents)
          ..where((e) => e.kind.equals(kind))
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .get();
  }

  Future<List<EventRow>> queryRecentReactions({int limit = 500}) {
    return (select(events)
          ..where((e) => e.kind.equals(7))
          ..orderBy([(e) => OrderingTerm.desc(e.createdAt)])
          ..limit(limit))
        .get();
  }

  Future<ReplaceableEvent?> queryContactList(String pubkey) async {
    final q = select(replaceableEvents)
      ..where((e) => e.pubkey.equals(pubkey) & e.kind.equals(3))
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first;
  }

  /// The user's NIP-51 kind-30015 default Interests list (followed hashtags,
  /// d-tag ""). Used by FollowedTagsNotifier for cold-start hydration before
  /// the relay responds.
  Future<ReplaceableEvent?> queryInterests(String pubkey) async {
    final q = select(replaceableEvents)
      ..where(
        (e) =>
            e.pubkey.equals(pubkey) & e.kind.equals(30015) & e.dTag.equals(''),
      )
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first;
  }

  // --- Config ---

  Future<String?> readConfig(String key) async {
    final q = select(configTable)
      ..where((c) => c.key.equals(key))
      ..limit(1);
    final rows = await q.get();
    return rows.isEmpty ? null : rows.first.value;
  }

  Future<void> writeConfig(String key, String value) async {
    await into(configTable).insertOnConflictUpdate(
      ConfigTableCompanion.insert(key: key, value: value),
    );
  }

  Future<void> deleteConfig(String key) async {
    await (delete(configTable)..where((c) => c.key.equals(key))).go();
  }

  // --- Server list persistence (relay + Blossom), source of truth for the
  // 服务器节点 page and (later) editing. Seeded from the code constants on
  // first run; published to Nostr (kind 10002 relays / kind 10063 Blossom). ---

  /// Read a JSON array of server URLs stored under [key]. Null if absent or
  /// malformed (caller falls back to the code default + re-seeds).
  Future<List<String>?> readServerList(String key) async {
    final raw = await readConfig(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.whereType<String>().toList(growable: false);
      }
    } catch (_) {}
    return null;
  }

  /// Persist a list of server URLs under [key] as a JSON array.
  Future<void> writeServerList(String key, List<String> urls) async {
    await writeConfig(key, jsonEncode(urls));
  }

  // --- Relay/Blossom RTT cache (last N samples per server, FIFO) ---

  static const int _rttKeep = 3;

  /// Read the cached RTT samples (ms) for [url] under [prefix]. Empty if
  /// none/invalid. [prefix] separates relay vs blossom samples
  /// (`relay_rtt` / `blossom_rtt`).
  Future<List<int>> readRtt(String url, {String prefix = 'relay_rtt'}) async {
    final raw = await readConfig('$prefix:$url');
    if (raw == null || raw.isEmpty) return const <int>[];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.whereType<int>().toList(growable: false);
      }
    } catch (_) {}
    return const <int>[];
  }

  /// Append [ms] to the cached samples for [url] under [prefix], keeping only
  /// the most recent [_rttKeep] (FIFO eviction). Persists immediately.
  Future<void> pushRtt(
    String url,
    int ms, {
    String prefix = 'relay_rtt',
  }) async {
    final samples = (await readRtt(url, prefix: prefix)).toList()..add(ms);
    final kept = samples.length > _rttKeep
        ? samples.sublist(samples.length - _rttKeep)
        : samples;
    await writeConfig('$prefix:$url', jsonEncode(kept));
  }

  // --- Relay write success-rate samples (last N publish verdicts per relay).
  // READ verdicts are deliberately not tracked: a relay that accepts writes
  // can almost always be read from, so only the write path gets statistics.

  static const int _writeSamplesKeep = 10;

  /// Read the cached write-verdict samples for [url]: true = the relay
  /// accepted the publish, false = it rejected. Empty when no samples /
  /// corrupt value. FIFO, last [_writeSamplesKeep].
  Future<List<bool>> readWriteSamples(String url) async {
    final raw = await readConfig('relay_write_stats:$url');
    if (raw == null || raw.isEmpty) return const <bool>[];
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        return list.map((v) => v == true || v == 1).toList(growable: false);
      }
    } catch (_) {}
    return const <bool>[];
  }

  /// Append a write verdict for [url] (true = accepted, false = rejected),
  /// keeping only the most recent [_writeSamplesKeep] (FIFO eviction).
  /// Persists immediately.
  Future<void> pushWriteSample(String url, bool ok) async {
    final samples = (await readWriteSamples(url)).toList()..add(ok);
    final kept = samples.length > _writeSamplesKeep
        ? samples.sublist(samples.length - _writeSamplesKeep)
        : samples;
    await writeConfig('relay_write_stats:$url', jsonEncode(kept));
  }

  /// Store the relay's most recent WRITE rejection reason (raw OK reason
  /// string, e.g. "blocked: pubkey is blacklisted" / "rate-limited: …") so
  /// the 服务器节点 page can show WHY a relay keeps failing. Empty string
  /// clears it (a subsequent accepted write resets the relay to healthy).
  /// Capped so a verbose relay can't bloat the config row.
  Future<void> setWriteRejectReason(String url, String reason) async {
    final trimmed = reason.trim();
    final capped = trimmed.length > 120 ? trimmed.substring(0, 120) : trimmed;
    await writeConfig('relay_write_reject:$url', capped);
  }

  /// The most recent stored rejection reason for [url], or null when none /
  /// empty (relay healthy or never rejected).
  Future<String?> readWriteRejectReason(String url) async {
    final raw = await readConfig('relay_write_reject:$url');
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  /// Drop ALL write-verdict samples + rejection reasons. One-shot upgrade
  /// cleanup: samples recorded before the NIP-42/duplicate normalization
  /// counted auth handshakes and slow-relay races as failures — stale data
  /// that would keep flagging healthy relays after the fix ships.
  Future<void> clearWriteStats() async {
    await (delete(configTable)..where(
          (c) =>
              c.key.like('relay_write_stats:%') |
              c.key.like('relay_write_reject:%'),
        ))
        .go();
  }

  // --- Drafts (outbox: events that failed to publish, for retry) ---

  /// Save a draft event (failed to publish) for later retry. Returns the
  /// SQLite rowid so callers can delete THIS exact draft when the user
  /// retries successfully (the retry signs a fresh event, so it can't be
  /// matched by id — without the rowid the stale draft would linger and
  /// `retryDrafts` would republish it on the next cold start → duplicate).
  Future<int> saveDraft(String rawJson) async {
    // Transaction guarantees the INSERT and the last_insert_rowid() read run
    // on the same connection (drift may pool connections), so the rowid is
    // the one we just inserted, not 0 / a sibling insert's.
    return transaction(() async {
      await customStatement(
        'INSERT INTO drafts(raw_json, created_at, attempts) VALUES (?, ?, 0)',
        [rawJson, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
      final row = await customSelect(
        'SELECT last_insert_rowid() AS id',
      ).getSingle();
      return row.read<int>('id');
    });
  }

  /// Load all pending drafts (oldest first). Returns raw JSON strings.
  Future<List<String>> getDrafts() async {
    final results = await customSelect(
      'SELECT raw_json FROM drafts ORDER BY created_at ASC',
    ).get();
    return results.map((r) => r.read<String>('raw_json')).toList();
  }

  /// Load all pending drafts with their rowid (oldest first), so callers can
  /// delete / bump attempts after a retry round. The `id` column of an
  /// AUTOINCREMENT table IS the SQLite rowid (alias), and reading it works
  /// with drift's customSelect — a bare `SELECT rowid` column does NOT
  /// resolve through QueryRow.read (null → type-cast crash, which silently
  /// killed draft retries whenever a draft existed).
  Future<List<(int, String)>> getDraftsWithRowid() async {
    final results = await customSelect(
      'SELECT id, raw_json FROM drafts ORDER BY created_at ASC',
    ).get();
    return results
        .map((r) => (r.read<int>('id'), r.read<String>('raw_json')))
        .toList();
  }

  /// Delete a draft after successful publish.
  Future<void> deleteDraft(int rowid) async {
    await customStatement('DELETE FROM drafts WHERE rowid = ?', [rowid]);
  }

  /// Delete an immutable event (events + its tags). The events AFTER DELETE
  /// trigger cleans events_fts. Used after a NIP-09 kind-5 deletion.
  Future<void> deleteEvent(String id) async {
    await customStatement('DELETE FROM event_tags WHERE event_id = ?', [id]);
    await customStatement('DELETE FROM events WHERE id = ?', [id]);
  }

  /// Delete a replaceable event by its NIP-01 coordinate (pubkey, kind, d) —
  /// used to honor a NIP-09 kind-5 deletion with an `a` tag
  /// `"<kind>:<pubkey>:<d>"`. Safe to call when no matching row exists (no-op).
  Future<void> deleteReplaceableByCoord(
    String pubkey,
    int kind,
    String dTag,
  ) async {
    await customStatement(
      'DELETE FROM replaceable_events WHERE pubkey = ? AND kind = ? AND d_tag = ?',
      [pubkey, kind, dTag],
    );
  }

  /// Increment attempt count on a draft (for backoff decisions).
  Future<void> incrementDraftAttempts(int rowid) async {
    await customStatement(
      'UPDATE drafts SET attempts = attempts + 1 WHERE rowid = ?',
      [rowid],
    );
  }

  // --- Relay config ---

  Future<List<RelayConfigData>> getRelays() => select(relayConfig).get();

  Future<void> upsertRelay(
    String url, {
    bool read = true,
    bool write = true,
    bool enabled = true,
  }) async {
    await into(relayConfig).insertOnConflictUpdate(
      RelayConfigCompanion.insert(
        url: url,
        read: Value(read ? 1 : 0),
        write: Value(write ? 1 : 0),
        enabled: Value(enabled ? 1 : 0),
      ),
    );
  }

  Future<void> deleteRelay(String url) async {
    await (delete(relayConfig)..where((r) => r.url.equals(url))).go();
  }

  // --- Cleanup ---

  /// Delete cached events older than [ttlDays]. Every pubkey in
  /// [ownPubkeys] (all accounts logged in on this device) is exempt: own
  /// posts are notification targets (a kind-7 reaction notification deep-links
  /// to the reacted post), and once TTL-evicted the only remaining source is
  /// the relays — which often prune old events too, making "X 赞了你" open to
  /// "未找到该帖子". Keeping own posts locally makes notification targets
  /// resolve instantly forever — for every stored account, so switching to a
  /// dormant account doesn't surface dead links.
  Future<int> cleanupOldEvents({
    int ttlDays = 30,
    Set<String> ownPubkeys = const {},
  }) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - ttlDays * 86400;
    if (ownPubkeys.isEmpty) {
      await customStatement(
        'DELETE FROM events WHERE created_at < ? AND kind != 5',
        [cutoff],
      );
    } else {
      final placeholders = List.filled(ownPubkeys.length, '?').join(', ');
      await customStatement(
        'DELETE FROM events WHERE created_at < ? AND kind != 5 '
        'AND pubkey NOT IN ($placeholders)',
        [cutoff, ...ownPubkeys],
      );
    }
    await customStatement(
      'DELETE FROM event_tags WHERE event_id NOT IN (SELECT id FROM events)',
      [],
    );
    await customStatement(
      'DELETE FROM events_fts WHERE rowid NOT IN (SELECT rowid FROM events)',
      [],
    );
    return 0; // drift customStatement doesn't return affected count
  }

  Future<void> enforceSizeCap({int maxBytes = 200 * 1024 * 1024}) async {
    final pageResult = await customSelect('PRAGMA page_count').getSingle();
    final sizeResult = await customSelect('PRAGMA page_size').getSingle();
    final dbSize =
        (pageResult.data['page_count'] as int) *
        (sizeResult.data['page_size'] as int);
    if (dbSize > maxBytes) {
      await customStatement(
        'DELETE FROM events WHERE id IN (SELECT id FROM events ORDER BY created_at ASC LIMIT (SELECT COUNT(*) / 10 FROM events))',
        [],
      );
      await customStatement(
        'DELETE FROM event_tags WHERE event_id NOT IN (SELECT id FROM events)',
        [],
      );
      await customStatement(
        'DELETE FROM events_fts WHERE rowid NOT IN (SELECT rowid FROM events)',
        [],
      );
    }
  }

  Future<void> vacuum() async {
    await customStatement('VACUUM', []);
  }

  Future<int> get eventCount async {
    final r = await customSelect(
      'SELECT COUNT(*) as c FROM events',
    ).getSingle();
    return r.data['c'] as int;
  }
}
