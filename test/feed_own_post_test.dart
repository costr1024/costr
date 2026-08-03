// Regression test: the user's OWN posts must appear in the 关注 (following)
// feed. You don't follow yourself, so the old filter
// `set.contains(e.pubkey)` silently dropped own notes — a just-published post
// (already echoed into the store by publishAndWait) was visible in the profile
// 帖子 tab but never in the feed, and pull-refresh couldn't bring it back.

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

class _FollowingMode extends FeedModeNotifier {
  @override
  FeedMode build() => FeedMode.following;
}

class _NoLangFilter extends LanguageFilterNotifier {
  @override
  LanguageFilter build() => LanguageFilter.all;
}

class _NoTagFilter extends TagFilterNotifier {
  @override
  String? build() => null;
}

class _NoFollowingFilter extends FollowingFilterNotifier {
  @override
  String? build() => null;
}

class _Follows extends FollowingNotifier {
  _Follows(this.list);
  final List<String> list;

  @override
  Future<List<String>> build() async => list;
}

/// Fixed in-memory store (no SQLite / relay wiring in unit tests).
class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _post(String id, String pubkey, int createdAt) => Event(
  id: id,
  pubkey: pubkey,
  createdAt: createdAt,
  kind: 1,
  tags: const [],
  content: 'post $id',
  sig: 's' * 128,
);

void main() {
  late ProviderContainer container;
  late String me;

  setUp(() {
    me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
  });

  ProviderContainer buildContainer(List<Event> store, List<String> follows) {
    return ProviderContainer(
      overrides: [
        feedModeProvider.overrideWith(() => _FollowingMode()),
        languageFilterProvider.overrideWith(() => _NoLangFilter()),
        tagFilterProvider.overrideWith(() => _NoTagFilter()),
        followingFilterProvider.overrideWith(() => _NoFollowingFilter()),
        identityProvider.overrideWith(() => _Id()),
        followingStateProvider.overrideWith(() => _Follows(follows)),
        eventStoreProvider.overrideWith(() => _FixedStore(store)),
        myMuteSetProvider.overrideWith((ref) => const MuteSet()),
        feedSubscriptionProvider.overrideWith((ref) {}),
        followingOutboxProvider.overrideWith((ref) {}),
      ],
    );
  }

  Future<void> pollUntil(
    bool Function() cond, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) fail('condition not met within $timeout');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test(
      'own post appears in the following feed (you don\'t follow yourself)',
      () async {
    const followee = 'feed000000000000000000000000000000000000000000000000000000000';
    final myPost = _post('mine01', me, 300);
    final followeePost = _post('theirs01', followee, 200);
    final strangerPost = _post('stranger1', 'a' * 64, 100);

    container = buildContainer(
      [myPost, followeePost, strangerPost],
      [followee],
    );
    addTearDown(container.dispose);
    // Keep the feed provider alive while its async deps (identity/follows)
    // resolve, then wait for the derived list to include the own post.
    final sub = container.listen(currentFeedEventsProvider, (_, _) {});
    addTearDown(sub.close);
    await pollUntil(
      () => container
          .read(currentFeedEventsProvider)
          .any((e) => e.id == 'mine01'),
    );

    final ids = container
        .read(currentFeedEventsProvider)
        .map((e) => e.id)
        .toList();
    expect(ids, contains('mine01'), reason: 'own post must be in the feed');
    expect(ids, contains('theirs01'));
    // Global-firehose strangers stay out of the following feed.
    expect(ids, isNot(contains('stranger1')));
    // Newest-first ordering preserved.
    expect(ids.indexOf('mine01'), lessThan(ids.indexOf('theirs01')));
  });

  test('own post survives a simulated refresh (store intact, re-derived)',
      () async {
    const followee = 'feed000000000000000000000000000000000000000000000000000000000';
    final myPost = _post('mine01', me, 300);
    container = buildContainer([myPost], [followee]);
    addTearDown(container.dispose);
    final sub = container.listen(currentFeedEventsProvider, (_, _) {});
    addTearDown(sub.close);
    await pollUntil(
      () => container
          .read(currentFeedEventsProvider)
          .any((e) => e.id == 'mine01'),
    );

    // First derivation (initial load)…
    expect(container.read(currentFeedEventsProvider).map((e) => e.id), [
      'mine01',
    ]);
    // …and after an invalidate (what pull-refresh does to the feed drivers),
    // the re-derived list still contains the own post.
    container.invalidate(currentFeedEventsProvider);
    await pollUntil(
      () => container
          .read(currentFeedEventsProvider)
          .any((e) => e.id == 'mine01'),
    );
    expect(container.read(currentFeedEventsProvider).map((e) => e.id), [
      'mine01',
    ]);
  });
}
