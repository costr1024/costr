// Regression tests for the "自定义关注列表名偶尔显示成 UUID、重启恢复" bug.
//
// Root cause: different relays serve different revisions of the same
// replaceable list (a relay that missed a rename still serves the older
// revision, which for kind-30000 can lack the `name` tag entirely). Two
// defenses are tested here:
//
// 1. LocalCache.writeEvent must be NEWEST-WINS for replaceable events — a
//    stale revision arriving late must not overwrite the newer cached row
//    (insertOnConflictUpdate alone is last-write-wins).
// 2. _buildFollowGroups must take the display name from the NEWEST revision
//    per `d`, so a stale nameless revision cannot make the group fall back
//    to the UUID `d` identifier when a newer named revision is known.
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/services/local_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _pk = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

Future<void> writeSet(
  LocalCache db, {
  required String id,
  required int createdAt,
  required List<List<dynamic>> tags,
}) {
  return db.writeEvent(
    id: id,
    pubkey: _pk,
    kind: 30000,
    createdAt: createdAt,
    content: '',
    sig: 'sig',
    raw: jsonEncode({'id': id}),
    tagsJson: jsonEncode(tags),
    tags: tags,
  );
}

Event _k30000({
  required String id,
  required int createdAt,
  required List<List<dynamic>> tags,
}) => Event(
  id: id,
  pubkey: _pk,
  createdAt: createdAt,
  kind: 30000,
  tags: tags,
  content: '',
  sig: 's',
);

void main() {
  group('LocalCache.writeEvent newest-wins (replaceable events)', () {
    late LocalCache db;

    setUp(() {
      db = LocalCache(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test(
      'stale kind-30000 arriving late does NOT overwrite newer row',
      () async {
        // Newer revision (post-rename, carries the human name)…
        await writeSet(
          db,
          id: 'new',
          createdAt: 200,
          tags: [
            ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
            ['name', '真人用户'],
          ],
        );
        // …then a stale revision (pre-rename, name stripped) lands afterwards.
        await writeSet(
          db,
          id: 'stale',
          createdAt: 100,
          tags: [
            ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
          ],
        );
        final rows = await db.queryFollowSets(_pk);
        expect(rows.length, 1);
        expect(rows.single.id, 'new');
        expect(rows.single.createdAt, 200);
        expect(rows.single.tagsJson, contains('真人用户'));
      },
    );

    test('newer kind-30000 replaces an older row', () async {
      await writeSet(
        db,
        id: 'stale',
        createdAt: 100,
        tags: [
          ['d', 'd3ce9497-6a45-4712-ac0f-fce6a02e161f'],
        ],
      );
      await writeSet(
        db,
        id: 'new',
        createdAt: 200,
        tags: [
          ['d', 'd3ce9497-6a45-4712-ac0f-fce6a02e161f'],
          ['name', '真人用户'],
        ],
      );
      final rows = await db.queryFollowSets(_pk);
      expect(rows.length, 1);
      expect(rows.single.id, 'new');
      expect(rows.single.tagsJson, contains('真人用户'));
    });

    test('distinct d tags stay separate rows', () async {
      await writeSet(
        db,
        id: 'a',
        createdAt: 100,
        tags: [
          ['d', 'list-a'],
          ['name', '美女美图'],
        ],
      );
      await writeSet(
        db,
        id: 'b',
        createdAt: 100,
        tags: [
          ['d', 'list-b'],
          ['name', '新闻资讯'],
        ],
      );
      final rows = await db.queryFollowSets(_pk);
      expect(rows.length, 2);
      expect(rows.map((r) => r.dTag).toSet(), {'list-a', 'list-b'});
    });

    test('guard applies to plain replaceables too (kind 3, d="")', () async {
      await db.writeEvent(
        id: 'new',
        pubkey: _pk,
        kind: 3,
        createdAt: 200,
        content: '',
        sig: 'sig',
        raw: '{}',
        tagsJson: jsonEncode([
          ['p', 'pk-new'],
        ]),
        tags: [
          ['p', 'pk-new'],
        ],
      );
      await db.writeEvent(
        id: 'stale',
        pubkey: _pk,
        kind: 3,
        createdAt: 100,
        content: '',
        sig: 'sig',
        raw: '{}',
        tagsJson: jsonEncode([
          ['p', 'pk-stale'],
        ]),
        tags: [
          ['p', 'pk-stale'],
        ],
      );
      final row = await db.queryContactList(_pk);
      expect(row, isNotNull);
      expect(row!.id, 'new');
      expect(row.tagsJson, contains('pk-new'));
      expect(row.tagsJson, isNot(contains('pk-stale')));
    });
  });

  group('_buildFollowGroups newest-revision display name', () {
    test('stale nameless revision + newer named revision → human name', () {
      // Stale revision first in the input (arrival order must not matter).
      final groups = buildFollowGroupsForTest(
        const ['pk1'],
        [
          _k30000(
            id: 'stale',
            createdAt: 100,
            tags: [
              ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
              ['p', 'pk1'],
            ],
          ),
          _k30000(
            id: 'new',
            createdAt: 200,
            tags: [
              ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
              ['name', '真人用户'],
              ['p', 'pk1'],
            ],
          ),
        ],
      );
      expect(groups.length, 2); // 默认分组 + the custom group
      expect(groups[1].name, '真人用户');
      expect(groups[1].source?.id, 'new');
    });

    test('newest revision wins regardless of input order', () {
      final groups = buildFollowGroupsForTest(
        const ['pk1'],
        [
          _k30000(
            id: 'new',
            createdAt: 200,
            tags: [
              ['d', 'uuid-d'],
              ['name', '真人用户'],
              ['p', 'pk1'],
            ],
          ),
          _k30000(
            id: 'stale',
            createdAt: 100,
            tags: [
              ['d', 'uuid-d'],
              ['p', 'pk1'],
            ],
          ),
        ],
      );
      expect(groups[1].name, '真人用户');
    });

    test('nameless-only list still falls back to the d tag', () {
      final groups = buildFollowGroupsForTest(const <String>[], [
        _k30000(
          id: 'only',
          createdAt: 100,
          tags: [
            ['d', 'f40fa7f0-8441-4eae-8b55-f605699da40b'],
          ],
        ),
      ]);
      expect(groups[1].name, 'f40fa7f0-8441-4eae-8b55-f605699da40b');
    });
  });
}
