// Tests for [parseEmbeddedRepost] + [repostRelayHints] — the repost-embed
// resolution used by the repost card and (via repostedEventProvider) the
// post-detail page. Guards the "tap a repost, content never loads" fix.

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:flutter_test/flutter_test.dart';

final _sig = 's' * 128;

Event _note(String id, {String content = 'hi', String? pubkey}) =>
    Event(
      id: id,
      pubkey: pubkey ?? 'p' * 64,
      createdAt: 1,
      kind: 1,
      tags: const [],
      content: content,
      sig: _sig,
    );

Event _repost({
  required String id,
  required Event reposted,
  String repostedRelay = '',
  String content = '',
}) {
  final tags = <List<dynamic>>[
    ['e', reposted.id, repostedRelay, ''],
    ['p', reposted.pubkey],
  ];
  return Event(
    id: id,
    pubkey: 'r' * 64,
    createdAt: 2,
    kind: 6,
    tags: tags,
    content: content,
    sig: _sig,
  );
}

void main() {
  group('parseEmbeddedRepost', () {
    test('parses the embedded note JSON from a compliant repost', () {
      final note = _note('n1', content: 'hello world');
      final repost = _repost(
        id: 'rp1',
        reposted: note,
        content: jsonEncode(note.toWireObject()),
      );
      final parsed = parseEmbeddedRepost(repost);
      expect(parsed, isNotNull);
      expect(parsed!.id, 'n1');
      expect(parsed.content, 'hello world');
      expect(parsed.kind, 1);
    });

    test('returns null for a non-repost event', () {
      final note = _note('n1');
      expect(parseEmbeddedRepost(note), isNull);
    });

    test('returns null for a repost with empty content', () {
      final note = _note('n1');
      final repost = _repost(id: 'rp1', reposted: note, content: '');
      expect(parseEmbeddedRepost(repost), isNull);
    });

    test('returns null for malformed JSON content', () {
      final note = _note('n1');
      final repost = _repost(
        id: 'rp1',
        reposted: note,
        content: 'not-json',
      );
      expect(parseEmbeddedRepost(repost), isNull);
    });

    test('returns null when the embedded event is not post-like', () {
      // A kind-0 metadata event embedded as the repost payload — not a post.
      final meta = Event(
        id: 'm1',
        pubkey: 'p' * 64,
        createdAt: 1,
        kind: 0,
        tags: const [],
        content: '{}',
        sig: _sig,
      );
      final repost = _repost(
        id: 'rp1',
        reposted: _note('n1'),
        content: jsonEncode(meta.toWireObject()),
      );
      expect(parseEmbeddedRepost(repost), isNull);
    });
  });

  group('repostRelayHints', () {
    test('collects the relay hint (t[2]) for the reposted id', () {
      final note = _note('n1');
      final repost = _repost(
        id: 'rp1',
        reposted: note,
        repostedRelay: 'wss://relay.bostr.online/',
      );
      expect(
        repostRelayHints(repost, 'n1'),
        ['wss://relay.bostr.online/'],
      );
    });

    test('ignores hints on e-tags for other ids', () {
      final note = _note('n1');
      final repost = _repost(
        id: 'rp1',
        reposted: note,
        repostedRelay: 'wss://relay.bostr.online/',
      );
      expect(repostRelayHints(repost, 'some-other-id'), isEmpty);
    });

    test('skips non-ws hints', () {
      final note = _note('n1');
      final repost = _repost(
        id: 'rp1',
        reposted: note,
        repostedRelay: 'not-a-url',
      );
      expect(repostRelayHints(repost, 'n1'), isEmpty);
    });

    test('empty when no e-tag carries a relay for the id', () {
      final note = _note('n1');
      final repost = _repost(id: 'rp1', reposted: note);
      expect(repostRelayHints(repost, 'n1'), isEmpty);
    });
  });
}
