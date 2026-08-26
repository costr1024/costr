// Per-account following-feed cache: queryFeedForAuthors must scope the shared
// events table to ONE account's followees so multiple accounts on a device
// each hydrate their own feed instantly (the global newest-N let other
// accounts' followees crowd out the active account's — "多账号关注流不秒出").

import 'dart:convert';

import 'package:costr/services/local_cache.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

const _acctA = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1';
const _acctB = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2';
const _followA1 = 'f0000000000000000000000000000000000000000000000000000000000000a1';
const _followA2 = 'f0000000000000000000000000000000000000000000000000000000000000a2';
const _followB1 = 'f0000000000000000000000000000000000000000000000000000000000000b1';

Future<void> _note(
  LocalCache db, {
  required String id,
  required String pubkey,
  required int createdAt,
}) {
  return db.writeEvent(
    id: id,
    pubkey: pubkey,
    kind: 1,
    createdAt: createdAt,
    content: 'note $id',
    sig: 'sig',
    raw: jsonEncode({'id': id}),
    tagsJson: jsonEncode(const []),
    tags: const [],
  );
}

void main() {
  late LocalCache db;

  setUp(() {
    db = LocalCache(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  test('queryFeedForAuthors returns only the given authors, newest first', () async {
    // A shared table holding posts for two accounts' follow graphs.
    await _note(db, id: 'a1-new', pubkey: _followA1, createdAt: 300);
    await _note(db, id: 'a2-old', pubkey: _followA2, createdAt: 100);
    await _note(db, id: 'b1-mid', pubkey: _followB1, createdAt: 200);
    await _note(db, id: 'acctA-own', pubkey: _acctA, createdAt: 250);

    // Account A hydrates its follows + own post.
    final rowsA = await db.queryFeedForAuthors([_followA1, _followA2, _acctA]);
    expect(rowsA.map((r) => r.id).toList(), ['a1-new', 'acctA-own', 'a2-old']);

    // Account B hydrates only its follow — none of A's posts leak in.
    final rowsB = await db.queryFeedForAuthors([_followB1, _acctB]);
    expect(rowsB.map((r) => r.id).toList(), ['b1-mid']);
  });

  test('queryFeedForAuthors ignores non-feed kinds', () async {
    await _note(db, id: 'k1', pubkey: _followA1, createdAt: 100);
    await db.writeEvent(
      id: 'k7',
      pubkey: _followA1,
      kind: 7,
      createdAt: 200,
      content: '+',
      sig: 'sig',
      raw: '{}',
      tagsJson: jsonEncode(const []),
      tags: const [],
    );
    final rows = await db.queryFeedForAuthors([_followA1]);
    expect(rows.map((r) => r.id).toList(), ['k1']); // kind-7 excluded
  });

  test('queryFeedForAuthors with empty authors returns nothing', () async {
    await _note(db, id: 'x', pubkey: _followA1, createdAt: 100);
    final rows = await db.queryFeedForAuthors(const []);
    expect(rows, isEmpty);
  });

  test('queryFeedForAuthors respects limit', () async {
    for (var i = 0; i < 5; i++) {
      await _note(db, id: 'n$i', pubkey: _followA1, createdAt: 100 + i);
    }
    final rows = await db.queryFeedForAuthors([_followA1], limit: 3);
    expect(rows.length, 3);
    expect(rows.map((r) => r.id).toList(), ['n4', 'n3', 'n2']);
  });
}
