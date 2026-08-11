// Tests for [threadReplies] — the timeline-ordered + hierarchical flattening
// of the reply list shown under a post on the detail page.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

final _me = 'me' * 16; // 32-byte hex-ish author (value irrelevant here)

Event _reply(
  String id,
  String author,
  int createdAt, {
  String? replyTo,
  String? root,
}) {
  final tags = <List<dynamic>>[];
  if (root != null) tags.add(['e', root, '', 'root']);
  if (replyTo != null) tags.add(['e', replyTo, '', 'reply']);
  return Event(
    id: id,
    pubkey: author,
    createdAt: createdAt,
    kind: 1,
    tags: tags,
    content: 'content-$id',
    sig: 's' * 128,
  );
}

void main() {
  const root = 'rootpost';

  group('threadReplies', () {
    test('direct replies to the root are depth 0, oldest-first', () {
      final r1 = _reply('a', _me, 100, replyTo: root);
      final r2 = _reply('b', _me, 200, replyTo: root);
      final out = threadReplies([r2, r1], root);
      expect(out.map((t) => t.event.id), ['a', 'b']);
      expect(out.every((t) => t.depth == 0), isTrue);
    });

    test('sub-replies nest under their parent, depth-first', () {
      // root ← a ← a1 ← a1a, and root ← b (sibling of a).
      final a = _reply('a', _me, 100, replyTo: root);
      final a1 = _reply('a1', _me, 110, replyTo: 'a');
      final a1a = _reply('a1a', _me, 120, replyTo: 'a1');
      final b = _reply('b', _me, 200, replyTo: root);
      final out = threadReplies([b, a1a, a1, a], root);
      // Depth-first, oldest-first within siblings: a, a1, a1a, b.
      expect(out.map((t) => '${t.event.id}:${t.depth}').toList(), [
        'a:0',
        'a1:1',
        'a1a:2',
        'b:0',
      ]);
    });

    test('newest reply to root does NOT jump above an older sub-thread', () {
      // Regression guard for the bug: flat createdAt-desc put the newest
      // direct reply on top, scattering the older sub-thread. Threaded
      // output keeps chronological sibling order.
      final old = _reply('old', _me, 100, replyTo: root);
      final oldChild = _reply('oc', _me, 110, replyTo: 'old');
      final fresh = _reply('fresh', _me, 999, replyTo: root);
      final out = threadReplies([fresh, oldChild, old], root);
      expect(
        out.map((t) => t.event.id).toList(),
        ['old', 'oc', 'fresh'], // fresh is newest but stays after old's subtree
      );
    });

    test(
      'reply whose parent is not in the set is reparented to root depth 0',
      () {
        // parent 'ghost' isn't among the replies and isn't the root → orphan.
        final orphan = _reply('o', _me, 100, replyTo: 'ghost');
        final out = threadReplies([orphan], root);
        expect(out.length, 1);
        expect(out.first.event.id, 'o');
        expect(out.first.depth, 0);
      },
    );

    test('reply with no e tags at all is reparented to root depth 0', () {
      final topless = Event(
        id: 't',
        pubkey: _me,
        createdAt: 100,
        kind: 1,
        tags: const [],
        content: 'c',
        sig: 's' * 128,
      );
      final out = threadReplies([topless], root);
      expect(out.first.depth, 0);
      expect(out.first.event.id, 't');
    });

    test('siblings of equal age sort by createdAt then are stable', () {
      final a = _reply('a', _me, 100, replyTo: root);
      final b = _reply('b', _me, 50, replyTo: root);
      final out = threadReplies([a, b], root);
      expect(out.map((t) => t.event.id).toList(), ['b', 'a']);
    });

    test('cycle (A replies B, B replies A) does not loop forever', () {
      final a = _reply('a', _me, 100, replyTo: 'b');
      final b = _reply('b', _me, 90, replyTo: 'a');
      // Neither parent is the root nor outside the set, so both nest under
      // each other → would loop. The seen-set must break the cycle.
      final out = threadReplies([a, b], root);
      // Each event appears at most once.
      expect(out.map((t) => t.event.id).toSet().length, 2);
      expect(out.length, 2);
    });

    test('empty input → empty output', () {
      expect(threadReplies(const <Event>[], root), isEmpty);
    });

    test('nested replies carry increasing depth (hierarchy visible)', () {
      // root ← l0 ← l1 ← l2 ← l3
      final l0 = _reply('l0', _me, 10, replyTo: root);
      final l1 = _reply('l1', _me, 20, replyTo: 'l0');
      final l2 = _reply('l2', _me, 30, replyTo: 'l1');
      final l3 = _reply('l3', _me, 40, replyTo: 'l2');
      final out = threadReplies([l3, l2, l1, l0], root);
      expect(out.map((t) => t.depth).toList(), [0, 1, 2, 3]);
    });
  });
}
