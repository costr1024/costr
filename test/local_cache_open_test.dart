// Regression test: an overlay upgrade (覆盖升级) carries the old costr.db over.
// If that inherited file is broken (corrupt page, stale WAL, bad FTS index),
// the first query used to wedge startup — the app sat on the splash screen
// forever, and only uninstall (which deletes the file) "fixed" it.
// openLocalCache must instead probe the DB with a timeout, quarantine the
// broken file, and open a fresh cache — same outcome as uninstall+reinstall,
// without losing the login.

import 'dart:io';

import 'package:costr/app/providers.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('fresh path → working cache, nothing quarantined', () async {
    final dir = await Directory.systemTemp.createTemp('costr_cache_ok');
    addTearDown(() => dir.delete(recursive: true));
    final dbPath = '${dir.path}/costr.db';

    final db = await openLocalCache(dbPath);
    addTearDown(db.close);

    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM events')
        .getSingle();
    expect(row.read<int>('c'), 0);
    expect(File(dbPath).existsSync(), isTrue);
    final corrupt = dir
        .listSync()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(corrupt, isEmpty);
  });

  test('corrupt inherited DB is quarantined and a fresh cache opened',
      () async {
    final dir = await Directory.systemTemp.createTemp('costr_cache_bad');
    addTearDown(() => dir.delete(recursive: true));
    final dbPath = '${dir.path}/costr.db';

    // Simulate a broken file carried over from an older install — not a
    // SQLite database at all.
    await File(dbPath).writeAsString(
      'this is definitely not a sqlite database',
    );

    final db = await openLocalCache(dbPath);
    addTearDown(db.close);

    // The replacement cache is fully functional...
    final row = await db
        .customSelect('SELECT COUNT(*) AS c FROM events')
        .getSingle();
    expect(row.read<int>('c'), 0);

    // ...and the broken file was renamed aside (kept for diagnosis), not
    // silently deleted.
    final corrupt = dir
        .listSync()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(corrupt, isNotEmpty);
  });

  test('repeated corruption keeps at most ONE quarantined backup', () async {
    final dir = await Directory.systemTemp.createTemp('costr_cache_repeat');
    addTearDown(() => dir.delete(recursive: true));
    final dbPath = '${dir.path}/costr.db';

    // Round 1: corrupt file inherited → quarantined, fresh cache opened.
    await File(dbPath).writeAsString('garbage one');
    final db1 = await openLocalCache(dbPath);
    await db1.close();
    var corrupt = dir
        .listSync()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(corrupt, hasLength(1));

    // Round 2: the fresh DB breaks again — the stale round-1 backup must be
    // pruned, not joined by a second one (no unbounded pile-up).
    await File(dbPath).writeAsString('garbage two');
    final db2 = await openLocalCache(dbPath);
    addTearDown(db2.close);
    corrupt = dir
        .listSync()
        .where((f) => f.path.contains('.corrupt-'))
        .toList();
    expect(corrupt, hasLength(1), reason: 'stale backups must be pruned');
  });
}
