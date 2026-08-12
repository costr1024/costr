// Regression: a misbehaving relay (observed: top.testrelay.top) serves a
// tag-STRIPPED variant of an existing kind-7 under the SAME event id (the id
// commits to the tags, so the variant is invalid NIP-01-wise, but it still
// arrives). The store tier can hold the stripped copy while the cache tier
// holds the full one; the old store-first/seenIds-shortcut merge made the
// reaction chip flip from the emoji image to the raw `:shortcode:` the
// moment the stripped copy landed ("表情图一闪而过变回 shortcode"), while
// 「点赞与转发」(cache-overrides-store) kept the image. Both surfaces must
// prefer the fuller copy regardless of tier order.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
final String _postId = 'p' * 64;
final String _author = 'a' * 64;

/// The SAME event id in both tiers — full copy carries the NIP-30 emoji tag,
/// stripped copy (relay-mangled) does not.
const _reactionId = '2d825743612e0000000000000000000000000000000000000000000000000000';
const _emojiUrl = 'https://media.naeu.net/emoji/wechat/thumbsup.webp';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _FixedStore extends EventStoreNotifier {
  _FixedStore(this.events);
  final List<Event> events;

  @override
  List<Event> build() => events;
}

Event _reaction({required bool stripped}) => Event(
  id: _reactionId,
  pubkey: 'b' * 64,
  createdAt: 1700000100,
  kind: 7,
  tags: [
    ['e', _postId],
    ['p', _author],
    if (!stripped) ['emoji', 'wechat_ThumbsUp', _emojiUrl],
  ],
  content: ':wechat_ThumbsUp:',
  sig: 's' * 128,
);

Future<ProviderContainer> _container({List<Event> store = const []}) async {
  final container = ProviderContainer(
    overrides: [
      eventStoreProvider.overrideWith(() => _FixedStore(store)),
      identityProvider.overrideWith(() => _Id()),
    ],
  );
  await container.read(identityProvider.future);
  return container;
}

void main() {
  test('index: stripped store copy must not shadow the full cache copy', () async {
    final container = await _container(store: [_reaction(stripped: true)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(stripped: false)]);
    final chips = container.read(reactionsProvider(_postId));
    expect(chips[':wechat_ThumbsUp:']?.count, 1);
    expect(chips[':wechat_ThumbsUp:']?.emojiUrl, _emojiUrl);
  });

  test('index: reverse tier order keeps the fuller copy too', () async {
    final container = await _container(store: [_reaction(stripped: false)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(stripped: true)]);
    final chips = container.read(reactionsProvider(_postId));
    expect(chips[':wechat_ThumbsUp:']?.emojiUrl, _emojiUrl);
  });

  test('interactors list: same fuller-copy rule as the index', () async {
    final container = await _container(store: [_reaction(stripped: true)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(stripped: false)]);
    final events = container.read(interactorEventsProvider(_postId));
    expect(events, hasLength(1));
    expect(
      events.single.tags.any((t) => t.isNotEmpty && t[0] == 'emoji'),
      isTrue,
      reason: 'the glyph source must be the full copy',
    );
  });
}
