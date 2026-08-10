// Regression: language-filtered global feed. A post whose language can't be
// detected (pure link / numbers / emoji) must show under EVERY language
// option — not be silently dropped — while a detected language still filters
// correctly (Chinese post hidden from the English filter and vice versa).
//
// Motivated by the fix that makes URL-only posts classify as null (links are
// not language evidence); they must remain visible in 中文/英文/日文 filters.

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

void main() {
  final zhPost = _post('zh01', 300, '今天天气真好');
  final enPost = _post('en01', 200, 'Hello world');
  final pureUrl = _post('url01', 100, 'https://example.com/download');
  final emojiOnly = _post('emo01', 50, '🎉🎉🎉');

  ProviderContainer buildContainer(LanguageFilter f) {
    final container = ProviderContainer(
      overrides: [
        feedModeProvider.overrideWith(() => _GlobalMode()),
        languageFilterProvider.overrideWith(() => _LangFilter(f)),
        tagFilterProvider.overrideWith(() => _NoTagFilter()),
        identityProvider.overrideWith(() => _Id()),
        eventStoreProvider.overrideWith(
          () => _FixedStore([zhPost, enPost, pureUrl, emojiOnly]),
        ),
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
    expect(ids(c), containsAll(['zh01', 'en01', 'url01', 'emo01']));
  });

  test('zh → Chinese + undetectable (pure-url/emoji); English hidden', () {
    final c = buildContainer(LanguageFilter.zh);
    final got = ids(c);
    expect(got, contains('zh01'));
    expect(got, contains('url01')); // pure link → shown under every filter
    expect(got, contains('emo01')); // emoji-only → undetectable → shown
    expect(got, isNot(contains('en01')));
  });

  test('en → English + undetectable; Chinese hidden', () {
    final c = buildContainer(LanguageFilter.en);
    final got = ids(c);
    expect(got, contains('en01'));
    expect(got, contains('url01'));
    expect(got, contains('emo01'));
    expect(got, isNot(contains('zh01')));
  });

  test('ja → undetectable only (no Japanese posts present)', () {
    final c = buildContainer(LanguageFilter.ja);
    final got = ids(c);
    expect(got, contains('url01'));
    expect(got, contains('emo01'));
    expect(got, isNot(contains('zh01')));
    expect(got, isNot(contains('en01')));
  });
}
