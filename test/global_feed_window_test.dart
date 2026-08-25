// Unit tests for GlobalFeedWindow — the ephemeral firehose window behind the
// 全球 tab. Requirement: the 20000-event capped EventStore holds ONLY the
// following feed + related events; the global firehose lives here instead,
// memory-only, cleared when the tab is left. These tests pin the window's
// bounded tiers (posts newest-first capped, interactions only for held posts,
// per-author newest metadata) and the revision counters the providers watch.

import 'dart:convert';

import 'package:costr/models/event.dart';
import 'package:costr/nostr/global_feed_window.dart';
import 'package:flutter_test/flutter_test.dart';

Event _ev({
  required String id,
  required int kind,
  int at = 1000,
  String pubkey = 'a',
  List<List<String>> tags = const [],
  String content = 'x',
}) => Event(
  id: id.padRight(64, '0'),
  pubkey: pubkey.padRight(64, '0'),
  createdAt: at,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

Event _post(String id, {int at = 1000, String pubkey = 'a'}) =>
    _ev(id: id, kind: 1, at: at, pubkey: pubkey, content: 'post $id');

void main() {
  group('posts tier', () {
    test('kind-1 posts are held newest-first regardless of arrival order', () {
      final w = GlobalFeedWindow();
      expect(w.ingest(_post('b', at: 200)), isTrue);
      expect(w.ingest(_post('a', at: 100)), isTrue);
      expect(w.ingest(_post('c', at: 300)), isTrue);
      expect(w.posts.map((e) => e.id).toList(), [
        'c'.padRight(64, '0'),
        'b'.padRight(64, '0'),
        'a'.padRight(64, '0'),
      ]);
      expect(w.contentRevision, 3);
    });

    test('cap evicts the OLDEST post (and its id lookup)', () {
      final w = GlobalFeedWindow(maxPosts: 2);
      w.ingest(_post('a', at: 100));
      w.ingest(_post('b', at: 200));
      w.ingest(_post('c', at: 300)); // evicts a
      expect(w.posts.length, 2);
      expect(w.postById('a'.padRight(64, '0')), isNull);
      expect(w.postById('c'.padRight(64, '0')), isNotNull);
    });

    test('duplicate post id is rejected', () {
      final w = GlobalFeedWindow();
      expect(w.ingest(_post('a')), isTrue);
      expect(w.ingest(_post('a', at: 999)), isFalse);
      expect(w.posts.length, 1);
      expect(w.contentRevision, 1);
    });
  });

  group('language-aware retention', () {
    // The firehose's dominant language churns matching posts out of a plain
    // 1000-post cap ("切换到中文之后只有十几条"). With a filter set, cap
    // eviction must prefer the oldest NON-matching post so the filtered
    // language accumulates up to the full cap.
    Event en(String id, int at) =>
        _ev(id: id, kind: 1, at: at, content: 'hello world $id');
    Event zh(String id, int at) =>
        _ev(id: id, kind: 1, at: at, content: '中文内容$id');

    test('matching posts accumulate; non-matching churn in the slack', () {
      final w = GlobalFeedWindow(maxPosts: 3)..languageFilter = 'zh';
      w.ingest(en('e1', 100));
      w.ingest(en('e2', 200));
      w.ingest(en('e3', 300)); // window full: [e3, e2, e1]
      w.ingest(zh('z1', 400)); // evicts the oldest NON-matching (e1)
      expect(w.postById(en('e1', 0).id), isNull);
      expect(w.postById(zh('z1', 0).id), isNotNull);
      w.ingest(zh('z2', 500)); // evicts e2, NOT z1
      expect(w.postById(en('e2', 0).id), isNull);
      expect(w.postById(zh('z1', 0).id), isNotNull);
      expect(w.postById(zh('z2', 0).id), isNotNull);
      expect(w.posts.length, 3); // still capped
    });

    test('all-matching window falls back to oldest-first eviction', () {
      final w = GlobalFeedWindow(maxPosts: 2)..languageFilter = 'zh';
      w.ingest(zh('z1', 100));
      w.ingest(zh('z2', 200));
      w.ingest(zh('z3', 300)); // every post matches → evict oldest (z1)
      expect(w.postById(zh('z1', 0).id), isNull);
      expect(w.postById(zh('z2', 0).id), isNotNull);
      expect(w.postById(zh('z3', 0).id), isNotNull);
    });

    test('no filter keeps plain oldest-first eviction', () {
      final w = GlobalFeedWindow(maxPosts: 2);
      w.ingest(zh('z1', 100));
      w.ingest(en('e2', 200));
      w.ingest(en('e3', 300)); // oldest-first even though z1 is a rare zh
      expect(w.postById(zh('z1', 0).id), isNull);
      expect(w.postById(en('e2', 0).id), isNotNull);
    });

    test('a repost whose reposted note is Chinese is retained under zh', () {
      final w = GlobalFeedWindow(maxPosts: 2)..languageFilter = 'zh';
      w.ingest(en('e1', 100));
      w.ingest(en('e2', 200));
      final rp = _ev(
        id: 'rp1',
        kind: 6,
        at: 300,
        content: jsonEncode({
          'id': 'inner'.padRight(64, '0'),
          'pubkey': 'b'.padRight(64, '0'),
          'created_at': 50,
          'kind': 1,
          'tags': const [],
          'content': '内嵌中文帖',
          'sig': 's' * 128,
        }),
      );
      w.ingest(rp); // matches via the embedded note → evicts e1, not itself
      expect(w.postById(rp.id), isNotNull);
      expect(w.postById(en('e1', 0).id), isNull);
      expect(w.postById(en('e2', 0).id), isNotNull);
    });

    test('switching the filter flips who is protected', () {
      final w = GlobalFeedWindow(maxPosts: 2)..languageFilter = 'zh';
      w.ingest(zh('z1', 100));
      w.ingest(en('e2', 200));
      w.languageFilter = 'en';
      w.ingest(en('e3', 300)); // now zh is the non-matching side → evict z1
      expect(w.postById(zh('z1', 0).id), isNull);
      expect(w.postById(en('e2', 0).id), isNotNull);
      expect(w.postById(en('e3', 0).id), isNotNull);
    });
  });

  group('interactions tier', () {
    test('kind-7 is kept only when it targets a CURRENTLY-held post', () {
      final w = GlobalFeedWindow();
      w.ingest(_post('p1'));
      final hits = _ev(
        id: 'like1',
        kind: 7,
        tags: [
          ['e', 'p1'.padRight(64, '0')],
        ],
      );
      final misses = _ev(
        id: 'like2',
        kind: 7,
        tags: [
          ['e', 'unknown'.padRight(64, '0')],
        ],
      );
      expect(w.ingest(hits), isTrue);
      expect(w.ingest(misses), isFalse);
      expect(w.interactions.map((e) => e.id), [hits.id]);
      expect(w.interactionRevision, 1);
    });

    test('cap churn drops the oldest ARRIVAL', () {
      final w = GlobalFeedWindow(maxInteractions: 2);
      w.ingest(_post('p1'));
      for (final id in ['l1', 'l2', 'l3']) {
        w.ingest(
          _ev(
            id: id,
            kind: 7,
            tags: [
              ['e', 'p1'.padRight(64, '0')],
            ],
          ),
        );
      }
      expect(w.interactions.map((e) => e.id).toList(), [
        'l2'.padRight(64, '0'),
        'l3'.padRight(64, '0'),
      ]);
    });
  });

  group('kind-6 repost', () {
    test('is both a feed card and an interaction, yielded ONCE by events', () {
      final w = GlobalFeedWindow();
      w.ingest(_post('target'));
      final repost = _ev(
        id: 'rp1',
        kind: 6,
        at: 500,
        tags: [
          ['e', 'target'.padRight(64, '0')],
        ],
      );
      expect(w.ingest(repost), isTrue);
      expect(w.posts.map((e) => e.id), contains(repost.id));
      expect(w.interactions.map((e) => e.id), contains(repost.id));
      // events must not double-count the kind-6 (index merge relies on this).
      final ids = w.events.map((e) => e.id).toList();
      expect(ids.where((id) => id == repost.id).length, 1);
      expect(w.contentRevision, 2); // target + repost card
      expect(w.interactionRevision, 1);
    });
  });

  group('metadata tier', () {
    test('per-author newest kind-0 wins; older duplicate rejected', () {
      final w = GlobalFeedWindow();
      expect(w.ingest(_ev(id: 'm1', kind: 0, at: 100, content: 'old')), isTrue);
      expect(w.ingest(_ev(id: 'm2', kind: 0, at: 200, content: 'new')), isTrue);
      // Older profile for the same author must NOT replace the newer one.
      expect(
        w.ingest(_ev(id: 'm3', kind: 0, at: 150, content: 'stale')),
        isFalse,
      );
      final meta = w.metadataFor('a'.padRight(64, '0'));
      expect(meta, isNotNull);
      expect(meta!.content, 'new');
      expect(w.metadataRevision, 2);
    });

    test('stranger metadata cap drops the oldest-created profile', () {
      final w = GlobalFeedWindow(maxMetadata: 2);
      w.ingest(_ev(id: 'm1', kind: 0, at: 100, pubkey: 'u1'));
      w.ingest(_ev(id: 'm2', kind: 0, at: 200, pubkey: 'u2'));
      w.ingest(_ev(id: 'm3', kind: 0, at: 300, pubkey: 'u3'));
      expect(w.metadataFor('u1'.padRight(64, '0')), isNull);
      expect(w.metadataFor('u3'.padRight(64, '0')), isNotNull);
    });
  });

  group('lifecycle', () {
    test('clear() empties every tier and bumps every revision', () {
      final w = GlobalFeedWindow();
      w.ingest(_post('p1'));
      w.ingest(
        _ev(
          id: 'l1',
          kind: 7,
          tags: [
            ['e', 'p1'.padRight(64, '0')],
          ],
        ),
      );
      w.ingest(_ev(id: 'm1', kind: 0));
      final c0 = w.contentRevision;
      final i0 = w.interactionRevision;
      final m0 = w.metadataRevision;

      w.clear();

      expect(w.isEmpty, isTrue);
      expect(w.posts, isEmpty);
      expect(w.interactions, isEmpty);
      expect(w.contentRevision, greaterThan(c0));
      expect(w.interactionRevision, greaterThan(i0));
      expect(w.metadataRevision, greaterThan(m0));
    });

    test('clear() on an already-empty window does not bump revisions', () {
      final w = GlobalFeedWindow();
      w.clear();
      expect(w.contentRevision, 0);
      expect(w.interactionRevision, 0);
      expect(w.metadataRevision, 0);
    });

    test('unrelated kinds (kind-3 etc.) are ignored', () {
      final w = GlobalFeedWindow();
      expect(w.ingest(_ev(id: 'cl', kind: 3)), isFalse);
      expect(w.isEmpty, isTrue);
    });

    test('bounded seen-set keeps re-delivery idempotent', () {
      // With maxSeen=2 the first id falls out of the seen set, but the
      // per-tier guards still reject the re-delivery (post already held).
      final w = GlobalFeedWindow(maxSeen: 2);
      w.ingest(_post('a', at: 100));
      w.ingest(_post('b', at: 200));
      w.ingest(_post('c', at: 300)); // trims 'a' from the seen set
      expect(w.ingest(_post('a', at: 100)), isFalse);
      expect(w.posts.length, 3); // no duplicate appended
    });
  });
}
