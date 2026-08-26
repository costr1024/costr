// Regression tests for the three notification-aggregation contracts fixed in
// this change:
//   1. Follow (kind 3) dedup — repeated contact-list revisions from the same
//      follower must collapse into one notification (keyed by pubkey, not the
//      per-revision event id).
//   2. Repost (kind 6) preview — content is the stringified-JSON of the
//      reposted event (NIP-18); must NOT be shown as preview text.
//   3. NIP-30 custom-emoji reaction (kind 7) — `:shortcode:` content with an
//      `emoji` tag must yield (shortcode, url) for image rendering, not dump
//      the literal ":shortcode:" token as preview text.

import 'dart:convert';

import 'package:costr/features/notifications/notifications_page.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _ev({
  required int kind,
  required String id,
  required String pubkey,
  required int createdAt,
  String content = '',
  List<List<dynamic>> tags = const [],
}) {
  return Event(
    id: id,
    pubkey: pubkey,
    createdAt: createdAt,
    kind: kind,
    tags: tags,
    content: content,
    sig: 'sig',
  );
}

void main() {
  group(
    'notificationReferencedId — target the interacted post, not the root',
    () {
      const myRoot = 'my_root';
      const myReply = 'my_reply';
      final mine = {myRoot, myReply};

      test('root+reply e-tags both mine → the reply-marked post wins', () {
        // Reply to my_reply inside my thread rooted at my_root: the old
        // first-match scan returned my_root (listed first) → tapping opened the
        // root main post. The reply marker is the post actually replied to.
        final reply = _ev(
          kind: 1,
          id: 'their_reply',
          pubkey: 'pk_other',
          createdAt: 1,
          content: 'hello',
          tags: const [
            ['e', 'my_root', '', 'root'],
            ['e', 'my_reply', '', 'reply'],
            ['p', 'me'],
          ],
        );
        expect(notificationReferencedId(reply, mine), myReply);
      });

      test('positional e-tag (no marker) beats root', () {
        final reaction = _ev(
          kind: 7,
          id: 'rx',
          pubkey: 'pk_other',
          createdAt: 1,
          content: '+',
          tags: const [
            ['e', 'my_root', '', 'root'],
            ['e', 'my_reply'],
            ['p', 'me'],
          ],
        );
        expect(notificationReferencedId(reaction, mine), myReply);
      });

      test('root-only reference still resolves (direct reply to my root)', () {
        final reply = _ev(
          kind: 1,
          id: 'r2',
          pubkey: 'pk_other',
          createdAt: 1,
          tags: const [
            ['e', 'my_root', '', 'root'],
          ],
        );
        expect(notificationReferencedId(reply, mine), myRoot);
      });

      test('e-tags of other users\' posts are ignored', () {
        final reply = _ev(
          kind: 1,
          id: 'r3',
          pubkey: 'pk_other',
          createdAt: 1,
          tags: const [
            ['e', 'someone_elses_root', '', 'root'],
            ['e', 'my_reply', '', 'reply'],
          ],
        );
        expect(notificationReferencedId(reply, mine), myReply);
      });

      test('mention-marked e-tags are never interactions', () {
        final note = _ev(
          kind: 1,
          id: 'r4',
          pubkey: 'pk_other',
          createdAt: 1,
          tags: const [
            ['e', 'my_root', '', 'mention'],
          ],
        );
        expect(notificationReferencedId(note, mine), isNull);
      });
    },
  );

  group('notificationItemKey — follow dedup (bug 1)', () {
    test('two kind-3 revisions from the same follower share a key', () {
      const follower = 'pk_follower_a';
      // The follower re-publishes their contact list; each revision has a
      // new event id but the same p-tag (me) — both must collapse to ONE
      // notification, hence share an item key.
      final v1 = _ev(
        kind: 3,
        id: 'k3_v1',
        pubkey: follower,
        createdAt: 1000,
        tags: const [
          ['p', 'me'],
          ['p', 'someone_else'],
        ],
      );
      final v2 = _ev(
        kind: 3,
        id: 'k3_v2',
        pubkey: follower,
        createdAt: 2000,
        tags: const [
          ['p', 'me'],
          ['p', 'a_third'],
        ],
      );
      final k1 = notificationItemKey(NotificationType.follow, v1, null);
      final k2 = notificationItemKey(NotificationType.follow, v2, null);
      expect(k1, k2, reason: 'same follower → same notification item');
      expect(k1, 'follow:$follower');
    });

    test('two different followers get distinct keys', () {
      final a = _ev(kind: 3, id: 'a1', pubkey: 'pk_a', createdAt: 1);
      final b = _ev(kind: 3, id: 'b1', pubkey: 'pk_b', createdAt: 2);
      expect(
        notificationItemKey(NotificationType.follow, a, null),
        isNot(equals(notificationItemKey(NotificationType.follow, b, null))),
      );
    });

    test('non-follow types still key on the referenced target / event id', () {
      // Two distinct reactions on the SAME post must aggregate into one item.
      final r1 = _ev(kind: 7, id: 'r1', pubkey: 'pk_a', createdAt: 1);
      final r2 = _ev(kind: 7, id: 'r2', pubkey: 'pk_b', createdAt: 2);
      const target = 'my_post';
      expect(
        notificationItemKey(NotificationType.reaction, r1, target),
        notificationItemKey(NotificationType.reaction, r2, target),
      );
    });
  });

  group('notificationPreview — repost shows the reposted post (bug 2)', () {
    test(
      'kind-6 repost: preview is the reposted post\'s OWN text, not JSON',
      () {
        // Per NIP-18 / our actions.repost(), kind-6 content is the stringified
        // JSON of the reposted event. The user wants to see WHICH of their
        // posts was reposted, so the preview must surface the embedded post's
        // content — not the raw JSON, and not nothing.
        final repostedContent = '这是我被转发的那条帖子的正文';
        final embedded = jsonEncode({
          'id': 'my_post',
          'pubkey': 'me',
          'created_at': 1234,
          'kind': 1,
          'content': repostedContent,
          'tags': [],
          'sig': 'sig',
        });
        final repost = _ev(
          kind: 6,
          id: 'rp1',
          pubkey: 'pk_reposter',
          createdAt: 1,
          content: embedded,
          tags: const [
            ['e', 'my_post'],
            ['p', 'me'],
          ],
        );
        expect(notificationPreview(repost), repostedContent);
      },
    );

    test('kind-6 repost with empty content → no preview', () {
      final repost = _ev(
        kind: 6,
        id: 'rp2',
        pubkey: 'pk',
        createdAt: 1,
        content: '',
      );
      expect(notificationPreview(repost), isNull);
    });

    test('kind-6 repost with malformed JSON content → no preview', () {
      final repost = _ev(
        kind: 6,
        id: 'rp3',
        pubkey: 'pk',
        createdAt: 1,
        content: 'not-json-at-all',
      );
      expect(notificationPreview(repost), isNull);
    });

    test('kind-6 repost never leaks the raw JSON as preview', () {
      // Regression guard: even with a non-trivial embedded event, the preview
      // must be the inner post text — never the stringified-JSON blob.
      final embedded = jsonEncode({
        'id': 'x' * 64,
        'pubkey': 'y' * 64,
        'kind': 1,
        'content': 'hello world',
        'tags': [],
        'sig': 'z' * 128,
      });
      final repost = _ev(
        kind: 6,
        id: 'rp4',
        pubkey: 'pk',
        createdAt: 1,
        content: embedded,
      );
      final preview = notificationPreview(repost);
      expect(preview, 'hello world');
      expect(preview, isNot(contains('{')));
      expect(preview, isNot(contains('"')));
    });

    test('kind-1 reply content IS shown as preview', () {
      final reply = _ev(
        kind: 1,
        id: 'rep1',
        pubkey: 'pk_replier',
        createdAt: 1,
        content: 'nice post!',
      );
      expect(notificationPreview(reply), 'nice post!');
    });

    test('kind-7 reaction content is NOT shown as preview', () {
      // The emoji payload is rendered via reactionEmojiFor, not as preview
      // text — otherwise a custom-emoji reaction would show ":shortcode:".
      final reaction = _ev(
        kind: 7,
        id: 'rx1',
        pubkey: 'pk_reacter',
        createdAt: 1,
        content: ':fire:',
        tags: const [
          ['e', 'my_post'],
          ['p', 'me'],
          ['emoji', 'fire', 'https://x/fire.png'],
        ],
      );
      expect(notificationPreview(reaction), isNull);
    });
  });

  group('reactionEmojiFor — NIP-30 custom emoji (bug 3)', () {
    test('custom-emoji reaction yields shortcode + image url', () {
      final e = _ev(
        kind: 7,
        id: 'r1',
        pubkey: 'pk',
        createdAt: 1,
        content: ':fire:',
        tags: const [
          ['e', 'my_post'],
          ['p', 'me'],
          ['emoji', 'fire', 'https://example.com/fire.png'],
        ],
      );
      final r = reactionEmojiFor(e)!;
      expect(r.emoji, 'fire');
      expect(r.url, 'https://example.com/fire.png');
    });

    test(
      'bare shortcode (no emoji tag) → shortcode without colons, null url',
      () {
        final e = _ev(
          kind: 7,
          id: 'r2',
          pubkey: 'pk',
          createdAt: 1,
          content: ':fire:',
        );
        final r = reactionEmojiFor(e)!;
        expect(r.emoji, 'fire');
        expect(r.url, isNull);
      },
    );

    test('unicode emoji content → raw content, null url', () {
      final e = _ev(
        kind: 7,
        id: 'r3',
        pubkey: 'pk',
        createdAt: 1,
        content: '🔥',
      );
      final r = reactionEmojiFor(e)!;
      expect(r.emoji, '🔥');
      expect(r.url, isNull);
    });

    test('empty content OR literal "+" → default 👍 like', () {
      final empty = _ev(
        kind: 7,
        id: 'r4',
        pubkey: 'pk',
        createdAt: 1,
        content: '',
      );
      expect(reactionEmojiFor(empty)!.emoji, '👍');
      expect(reactionEmojiFor(empty)!.url, isNull);

      // Legacy NIP-25 "+" content also normalizes to 👍 (not a bare "+").
      final plus = _ev(
        kind: 7,
        id: 'r4b',
        pubkey: 'pk',
        createdAt: 1,
        content: '+',
      );
      expect(reactionEmojiFor(plus)!.emoji, '👍');
    });

    test('non-kind-7 event → null', () {
      final e = _ev(
        kind: 1,
        id: 'p1',
        pubkey: 'pk',
        createdAt: 1,
        content: 'hi',
      );
      expect(reactionEmojiFor(e), isNull);
    });

    test('does not return the literal ":shortcode:" token as emoji', () {
      // Regression guard: the old code stored the raw ":fire:" string as the
      // emoji, which the tile then rendered verbatim. The fix must strip the
      // colons (or, with a url, hand the bare shortcode + url to the image
      // renderer).
      final e = _ev(
        kind: 7,
        id: 'r5',
        pubkey: 'pk',
        createdAt: 1,
        content: ':fire:',
        tags: const [
          ['emoji', 'fire', 'https://example.com/fire.png'],
        ],
      );
      final r = reactionEmojiFor(e)!;
      expect(r.emoji, isNot(':fire:'));
      expect(r.emoji, 'fire');
    });
  });

  group('flattenPreview — no lone first line from raw newlines', () {
    test('collapses newlines + repeated whitespace to single spaces', () {
      expect(
        flattenPreview('#Costr\nv0.6-beta发布，更新内…'),
        '#Costr v0.6-beta发布，更新内…',
      );
      expect(flattenPreview('a\n\nb\t  c'), 'a b c');
    });

    test('notificationPreview flattens kind-1 and kind-6 content', () {
      final reply = _ev(
        kind: 1,
        id: 'x',
        pubkey: 'pk',
        createdAt: 1,
        content: '第一行\n第二行',
      );
      expect(notificationPreview(reply), '第一行 第二行');
    });
  });

  group('repostedEventId — Amethyst pubkey in the marker slot', () {
    // Real-world Amethyst repost wire shape: the `e` tag's 4th field is the
    // reposted note's AUTHOR PUBKEY, not a NIP-10 marker. The old parser
    // matched no branch → null → "转发内容不可用" even though the repost's
    // content carries the full NIP-18 embedded note.
    test('unrecognized marker resolves as a positional reference', () {
      final repost = _ev(
        kind: 6,
        id: 'rp_am',
        pubkey: 'pk_reposter',
        createdAt: 1,
        tags: const [
          ['e', 'orig_id', 'wss://relay.ditto.pub/', 'author_pubkey_hex'],
          ['p', 'author_pubkey_hex'],
        ],
      );
      expect(repost.repostedEventId, 'orig_id');
    });

    test('root marker still wins over positional', () {
      final repost = _ev(
        kind: 6,
        id: 'rp_rt',
        pubkey: 'pk',
        createdAt: 1,
        tags: const [
          ['e', 'pos_id'],
          ['e', 'root_id', '', 'root'],
        ],
      );
      expect(repost.repostedEventId, 'root_id');
    });

    test('mention marker is never a repost target', () {
      final repost = _ev(
        kind: 6,
        id: 'rp_m',
        pubkey: 'pk',
        createdAt: 1,
        tags: const [
          ['e', 'orig_id', '', 'mention'],
        ],
      );
      expect(repost.repostedEventId, isNull);
    });
  });

  group('foldAggregateAuthor — exact author list (count bug)', () {
    test('5 authors → exactly 5, no phantom overflow', () {
      var pubkeys = <String>[];
      for (final pk in ['a', 'b', 'c', 'd', 'e']) {
        pubkeys = foldAggregateAuthor(pubkeys, pk);
      }
      expect(pubkeys, ['a', 'b', 'c', 'd', 'e']);
      // The head line derives "和另外 N 人" from length: 5 authors show 3
      // names + "和另外 2 人". The old capped-list + always-+1 extraCount
      // rendered the same 5 authors as "5 人和另外 4 人" (read as 9 people).
      expect(pubkeys.length, 5);
    });

    test('every distinct author is kept — count stays exact past 5', () {
      var pubkeys = <String>[];
      for (final pk in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i']) {
        pubkeys = foldAggregateAuthor(pubkeys, pk);
      }
      expect(pubkeys.length, 9); // no cap → "和另外 6 人" is exact
    });

    test('a repeat author is a no-op (identity)', () {
      const start = ['a', 'b'];
      final merged = foldAggregateAuthor(start, 'a');
      expect(identical(merged, start), isTrue);
    });

    test('repeat author is never double counted', () {
      var pubkeys = <String>[];
      for (final pk in ['a', 'b', 'c', 'd', 'e', 'f', 'f', 'a']) {
        pubkeys = foldAggregateAuthor(pubkeys, pk);
      }
      expect(pubkeys, ['a', 'b', 'c', 'd', 'e', 'f']);
    });
  });

  group('notificationItemKey — 整合通知 toggle (aggregate flag)', () {
    final reply = _ev(
      kind: 1,
      id: 'reply_ev',
      pubkey: 'pk',
      createdAt: 1,
      tags: const [
        ['e', 'my_post', '', 'root'],
      ],
    );

    test('aggregate ON (default): replies to the same post share a key', () {
      final other = _ev(
        kind: 1,
        id: 'reply_ev_2',
        pubkey: 'pk2',
        createdAt: 2,
        tags: const [
          ['e', 'my_post', '', 'root'],
        ],
      );
      expect(
        notificationItemKey(NotificationType.reply, reply, 'my_post'),
        notificationItemKey(NotificationType.reply, other, 'my_post'),
      );
    });

    test('aggregate OFF: each reply gets its own key', () {
      final other = _ev(
        kind: 1,
        id: 'reply_ev_2',
        pubkey: 'pk2',
        createdAt: 2,
        tags: const [
          ['e', 'my_post', '', 'root'],
        ],
      );
      final k1 = notificationItemKey(
        NotificationType.reply,
        reply,
        'my_post',
        aggregate: false,
      );
      final k2 = notificationItemKey(
        NotificationType.reply,
        other,
        'my_post',
        aggregate: false,
      );
      expect(k1, isNot(equals(k2)));
      expect(k1, 'reply:reply_ev');
      expect(k2, 'reply:reply_ev_2');
    });

    test('aggregate OFF still keys follow by pubkey (revision dedup)', () {
      final v1 = _ev(kind: 3, id: 'rev1', pubkey: 'follower', createdAt: 1);
      final v2 = _ev(kind: 3, id: 'rev2', pubkey: 'follower', createdAt: 2);
      expect(
        notificationItemKey(
          NotificationType.follow,
          v1,
          null,
          aggregate: false,
        ),
        notificationItemKey(
          NotificationType.follow,
          v2,
          null,
          aggregate: false,
        ),
      );
    });
  });
}
