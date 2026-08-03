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
      final k1 = notificationItemKey(
        NotificationType.follow,
        v1,
        null,
      );
      final k2 = notificationItemKey(
        NotificationType.follow,
        v2,
        null,
      );
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
    test('kind-6 repost: preview is the reposted post\'s OWN text, not JSON', () {
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
    });

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

    test('bare shortcode (no emoji tag) → shortcode without colons, null url', () {
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
    });

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
}
