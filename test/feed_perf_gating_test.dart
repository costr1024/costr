// Tests for the firehose-churn gating behind the 全球 scroll-perf fix:
// - feedContentRevisionProvider notifies ONLY on kind-1/6 changes, so
//   reaction (kind-7) churn stops rebuilding the feed list;
// - interactionRevisionProvider notifies on kind-1/6/7 changes (counts must
//   stay live) but NOT on kind-0 metadata churn;
// - interactionIndexProvider builds correct per-target stats in ONE pass and
//   reuses unchanged per-target instances so per-card providers skip rebuilds.
//
// Riverpod delivers derived-provider notifications on a microtask, so each
// mutation is followed by a zero-delay pump before asserting.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/event_store.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Store with synchronous, externally-triggerable ingestion (mimics the
/// 200ms-batched live flush of the real EventStoreNotifier). The `store`
/// getter override makes the revision getters see the SAME store the state
/// list comes from.
class _LiveStore extends EventStoreNotifier {
  @override
  final EventStore store = EventStore();

  @override
  List<Event> build() => store.events;

  void add(Event e) {
    if (store.add(e)) state = store.events;
  }
}

Event _e(
  String id,
  int createdAt, {
  int kind = 1,
  String? pubkey,
  List<List<dynamic>> tags = const [],
  String content = '',
}) => Event(
  id: id,
  pubkey: pubkey ?? 'p' * 64,
  createdAt: createdAt,
  kind: kind,
  tags: tags,
  content: content,
  sig: 's' * 128,
);

ProviderContainer _container(_LiveStore store) {
  final container = ProviderContainer(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      eventStoreProvider.overrideWith(() => store),
      identityProvider.overrideWith(() => _Id()),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Let Riverpod flush derived-provider notifications (microtask-scheduled).
Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('feed revision ignores kind-7/kind-0 churn; interaction revision '
      'ignores only kind-0', () async {
    final store = _LiveStore();
    final container = _container(store);
    // Mount the notifier (build) before driving it — _LiveStore.add assigns
    // `state`, which is illegal before build.
    container.read(eventStoreProvider);

    var feedNotifs = 0;
    var interNotifs = 0;
    container.listen(feedContentRevisionProvider, (_, _) => feedNotifs++);
    container.listen(interactionRevisionProvider, (_, _) => interNotifs++);
    await _flush();

    store.add(_e('p1', 100)); // kind-1 → both bump
    await _flush();
    expect(feedNotifs, 1);
    expect(interNotifs, 1);

    store.add(_e('r1', 110, kind: 7, tags: [
      ['e', 'p1'],
    ])); // kind-7 → interaction only
    await _flush();
    expect(feedNotifs, 1, reason: 'reaction churn must not rebuild the feed');
    expect(interNotifs, 2);

    store.add(_e('m1', 120, kind: 0)); // metadata → neither
    await _flush();
    expect(feedNotifs, 1);
    expect(interNotifs, 2);

    store.add(_e('rp1', 130, kind: 6, tags: [
      ['e', 'p1'],
    ])); // kind-6 → both
    await _flush();
    expect(feedNotifs, 2);
    expect(interNotifs, 3);
  });

  test('interaction index: one pass tallies replies/reposts/reactions/'
      'myReaction per target', () async {
    final me = Identity.fromPrivkeyHex(_priv).pubkeyHex;
    final store = _LiveStore();
    final container = _container(store);
    container.read(eventStoreProvider); // mount before driving
    // The async identity override must resolve before the index builds,
    // or `me` is null and myReaction is never recorded.
    await container.read(identityProvider.future);

    store.add(_e('post1', 100, pubkey: me));
    store.add(_e('reply1', 110, tags: [
      ['e', 'post1', '', 'reply'],
      ['p', me],
    ]));
    store.add(_e('repost1', 120, kind: 6, tags: [
      ['e', 'post1'],
    ]));
    store.add(_e('react1', 130, kind: 7, content: '+', tags: [
      ['e', 'post1'],
    ]));
    store.add(_e('react2', 140, kind: 7, content: ':fire:', tags: [
      ['e', 'post1'],
      ['emoji', 'fire', 'https://x/fire.png'],
    ]));
    store.add(_e('myreact', 150, kind: 7, pubkey: me, tags: [
      ['e', 'post1'],
    ]));
    await _flush();

    final index = container.read(interactionIndexProvider);
    final stats = index['post1']!;
    expect(stats.replies, 1);
    expect(stats.reposts, 1);
    // The tally INCLUDES my own reaction (legacy semantics): react1 ('+') +
    // myreact ('') both normalize to 👍.
    expect(stats.reactions['👍']?.count, 2); // '+' and '' normalized (NIP-25)
    expect(stats.reactions[':fire:']?.count, 1);
    expect(stats.reactions[':fire:']?.emojiUrl, 'https://x/fire.png');
    expect(stats.myReaction?.id, 'myreact');

    // A reply that e-tags TWO targets counts once per target (legacy
    // per-provider semantics).
    store.add(_e('root', 90));
    store.add(_e('reply2', 160, tags: [
      ['e', 'root', '', 'root'],
      ['e', 'post1', '', 'reply'],
    ]));
    await _flush();
    final index2 = container.read(interactionIndexProvider);
    expect(index2['post1']!.replies, 2);
    expect(index2['root']!.replies, 1);
  });

  test('interaction index reuses unchanged per-target instances', () async {
    final store = _LiveStore();
    final container = _container(store);
    container.read(eventStoreProvider);

    store.add(_e('post1', 100));
    store.add(_e('react1', 110, kind: 7, tags: [
      ['e', 'post1'],
    ]));
    await _flush();
    final before = container.read(interactionIndexProvider)['post1'];

    // Churn on a DIFFERENT post rebuilds the index, but post1's stats object
    // must be carried over BY IDENTITY so its per-card providers don't
    // rebuild.
    store.add(_e('post2', 200));
    store.add(_e('react2', 210, kind: 7, tags: [
      ['e', 'post2'],
    ]));
    await _flush();
    final after = container.read(interactionIndexProvider)['post1'];
    expect(identical(before, after), isTrue);

    // A new reaction ON post1 replaces its stats object.
    store.add(_e('react3', 220, kind: 7, tags: [
      ['e', 'post1'],
    ]));
    await _flush();
    final changed = container.read(interactionIndexProvider)['post1'];
    expect(identical(before, changed), isFalse);
    expect(changed!.reactions['👍']?.count, 2);
  });
}
