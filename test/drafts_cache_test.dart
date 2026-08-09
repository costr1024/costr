// Regression for the drafts rowid crash: getDraftsWithRowid used a bare
// `SELECT rowid`, which drift's QueryRow.read resolves to null → a type-cast
// exception. That silently killed draft retries whenever ANY draft existed
// (the whole retryDrafts path aborted on the first getDraftsWithRowid). The
// fix reads the AUTOINCREMENT `id` column (an alias of the SQLite rowid).
import 'package:costr/services/local_cache.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LocalCache drafts', () {
    late LocalCache db;

    setUp(() {
      db = LocalCache(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('saveDraft → getDraftsWithRowid roundtrip returns the id', () async {
      final rowid = await db.saveDraft('{"kind":1}');
      expect(rowid, greaterThan(0));
      final drafts = await db.getDraftsWithRowid();
      expect(drafts.length, 1);
      expect(drafts.first.$1, rowid);
      expect(drafts.first.$2, '{"kind":1}');
    });

    test('deleteDraft removes exactly that row', () async {
      final a = await db.saveDraft('{"n":1}');
      final b = await db.saveDraft('{"n":2}');
      await db.deleteDraft(a);
      final left = await db.getDraftsWithRowid();
      expect(left.length, 1);
      expect(left.first.$1, b);
      expect(left.first.$2, '{"n":2}');
    });

    test('getDraftsWithRowid is ordered oldest first', () async {
      await db.saveDraft('first');
      await db.saveDraft('second');
      final drafts = await db.getDraftsWithRowid();
      expect(drafts.map((d) => d.$2), ['first', 'second']);
    });

    test('incrementDraftAttempts bumps the counter', () async {
      final id = await db.saveDraft('x');
      await db.incrementDraftAttempts(id);
      await db.incrementDraftAttempts(id);
      final r = await db
          .customSelect(
            'SELECT attempts FROM drafts WHERE id = ?',
            variables: [Variable(id)],
          )
          .getSingle();
      expect(r.read<int>('attempts'), 2);
    });

    test('empty drafts table → empty list (no crash)', () async {
      expect(await db.getDraftsWithRowid(), isEmpty);
      expect(await db.getDrafts(), isEmpty);
    });
  });
}
