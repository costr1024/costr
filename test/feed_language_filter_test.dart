// Regression: language-filtered global feed.
//
// Two bugs fixed together:
// 1. "null matches EVERY filter" used to leak posts with no detectable
//    language into 中文/英文/日文 — empty posts, `✄--- 2:25 ---✄` symbol
//    posts, emoji posts, and Cyrillic/Arabic/… foreign-script posts. Now a
//    specific filter shows only posts detected as that language; among the
//    undetectable (null) posts, ONLY pure-link posts stay visible (v1.0.2),
//    while foreign-script / empty / symbol / number / emoji posts are dropped.
// 2. Reposts (kind-6) used to be classified by the wrapper's own content
//    (empty or the target's JSON) instead of the reposted note the user sees,
//    so English reposts flooded the 中文 filter. Now a repost is judged by its
//    reposted note (embedded NIP-18 JSON first, then a store lookup).

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _GlobalMode extends FeedModeNotifier {
  @override
  FeedMode build() => FeedMode.global;
}

class _LangFilter extends LanguageFilterNotifier {
  _LangFilter(this.value);
  final LanguageFilter value;
  @override
  LanguageFilter build() => value;
}

class _NoTagFilter extends TagFilterNotifier {
  @override
  String? build() => null;
}

/// Fixed in-memory store (no SQLite / relay wiring in unit tests).
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _post(String id, int createdAt, String content) => Event(
  id: id,
  pubkey: 'a' * 64,
  createdAt: createdAt,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's' * 128,
);

/// Stringified-JSON of an embedded note (NIP-18 repost content).
String _embeddedJson(String innerId, String innerContent) => jsonEncode({
  'id': innerId,
  'pubkey': 'b' * 64,
  'created_at': 100,
  'kind': 1,
  'tags': const [],
  'content': innerContent,
  'sig': 's' * 128,
});

/// A kind-6 repost; [content] is either embedded JSON or '' (e-tag-only).
Event _repost(String id, int createdAt, String content, String targetId) =>
    Event(
      id: id,
      pubkey: 'c' * 64,
      createdAt: createdAt,
      kind: 6,
      tags: [
        ['e', targetId],
      ],
      content: content,
      sig: 's' * 128,
    );

void main() {
  // Plain notes.
  final zhPost = _post('zh01', 300, '今天天气真好');
  final enPost = _post('en01', 290, 'Hello world');
  final pureUrl = _post('url01', 280, 'https://example.com/download');
  final emojiOnly = _post('emo01', 270, '🎉🎉🎉');
  final emptyPost = _post('empty01', 260, '');
  final symbolPost = _post('sym01', 250, '✄------------ 2:25 ------------✄');
  final cyrillicPost = _post('cyr01', 240, 'привет мир');

  // Reposts: embedded-JSON targets need not be in the store; e-tag-only
  // targets (tgtEn/tgtZh) ARE in the store so the store-lookup path resolves.
  final targetEn = _post('tgtEn', 230, 'This is the English original');
  final targetZh = _post('tgtZh', 220, '这是中文原帖');
  final repostEmbEn = _repost(
    'rpEmbEn',
    210,
    _embeddedJson('inEn', 'Embedded English note'),
    'inEn',
  );
  final repostEmbZh = _repost(
    'rpEmbZh',
    200,
    _embeddedJson('inZh', '内嵌中文帖'),
    'inZh',
  );
  final repostEmptyEn = _repost('rpEmptyEn', 190, '', 'tgtEn');
  final repostEmptyZh = _repost('rpEmptyZh', 180, '', 'tgtZh');

  final all = [
    zhPost,
    enPost,
    pureUrl,
    emojiOnly,
    emptyPost,
    symbolPost,
    cyrillicPost,
    targetEn,
    targetZh,
    repostEmbEn,
    repostEmbZh,
    repostEmptyEn,
    repostEmptyZh,
  ];

  ProviderContainer buildContainer(LanguageFilter f) {
    final container = ProviderContainer(
      overrides: [
        feedModeProvider.overrideWith(() => _GlobalMode()),
        languageFilterProvider.overrideWith(() => _LangFilter(f)),
        tagFilterProvider.overrideWith(() => _NoTagFilter()),
        identityProvider.overrideWith(() => _Id()),
        eventStoreProvider.overrideWith(() => _FixedStore(all)),
        myMuteSetProvider.overrideWith((ref) => const MuteSet()),
        feedSubscriptionProvider.overrideWith((ref) {}),
        followingOutboxProvider.overrideWith((ref) {}),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  List<String> ids(ProviderContainer c) =>
      c.read(currentFeedEventsProvider).map((e) => e.id).toList();

  test('all → everything visible', () {
    final c = buildContainer(LanguageFilter.all);
    expect(ids(c), containsAll(all.map((e) => e.id)));
  });

  test('zh → only Chinese + pure-link; junk and foreign hidden', () {
    final got = ids(buildContainer(LanguageFilter.zh));
    // Detected Chinese (incl. reposts whose reposted note is Chinese).
    expect(got, contains('zh01'));
    expect(got, contains('tgtZh'));
    expect(got, contains('rpEmbZh'));
    expect(got, contains('rpEmptyZh'));
    // Pure-link stays visible under every filter (v1.0.2).
    expect(got, contains('url01'));
    // English (notes AND reposts whose reposted note is English) hidden.
    expect(got, isNot(contains('en01')));
    expect(got, isNot(contains('tgtEn')));
    expect(got, isNot(contains('rpEmbEn')));
    expect(got, isNot(contains('rpEmptyEn')));
    // Undetectable junk hidden: empty / symbol / emoji / foreign-script.
    expect(got, isNot(contains('empty01')));
    expect(got, isNot(contains('sym01')));
    expect(got, isNot(contains('emo01')));
    expect(got, isNot(contains('cyr01')));
  });

  test('en → only English + pure-link; Chinese/foreign/junk hidden', () {
    final got = ids(buildContainer(LanguageFilter.en));
    expect(got, contains('en01'));
    expect(got, contains('tgtEn'));
    expect(got, contains('rpEmbEn'));
    expect(got, contains('rpEmptyEn'));
    expect(got, contains('url01'));
    expect(got, isNot(contains('zh01')));
    expect(got, isNot(contains('tgtZh')));
    expect(got, isNot(contains('rpEmbZh')));
    expect(got, isNot(contains('rpEmptyZh')));
    expect(got, isNot(contains('cyr01')));
    expect(got, isNot(contains('emo01')));
  });

  test('ja → only pure-link (no Japanese posts present)', () {
    final got = ids(buildContainer(LanguageFilter.ja));
    expect(got, contains('url01'));
    expect(got, isNot(contains('zh01')));
    expect(got, isNot(contains('en01')));
    expect(got, isNot(contains('cyr01')));
    expect(got, isNot(contains('emo01')));
  });
}
