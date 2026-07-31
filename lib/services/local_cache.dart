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
      if (kind == 1 || kind == 7) {
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
          ..where((e) => e.kind.equals(1))
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

  // --- Drafts (outbox: events that failed to publish, for retry) ---

  /// Save a draft event (failed to publish) for later retry.
  Future<void> saveDraft(String rawJson) async {
    await customStatement(
      'INSERT INTO drafts(raw_json, created_at, attempts) VALUES (?, ?, 0)',
      [rawJson, DateTime.now().millisecondsSinceEpoch ~/ 1000],
    );
  }

  /// Load all pending drafts (oldest first). Returns raw JSON strings.
  Future<List<String>> getDrafts() async {
    final results = await customSelect(
      'SELECT raw_json FROM drafts ORDER BY created_at ASC',
    ).get();
    return results.map((r) => r.read<String>('raw_json')).toList();
  }

  /// Delete a draft after successful publish.
  Future<void> deleteDraft(int rowid) async {
    await customStatement('DELETE FROM drafts WHERE rowid = ?', [rowid]);
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

  Future<int> cleanupOldEvents({int ttlDays = 30}) async {
    final cutoff =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 - ttlDays * 86400;
    await customStatement(
      'DELETE FROM events WHERE created_at < ? AND kind != 5',
      [cutoff],
    );
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
