// Regression: a misbehaving relay (observed: top.testrelay.top) serves a
// MUTATED variant of an existing kind-7 under the SAME event id — tag NAMES
// truncated to their first char (`["emoji", code, url]`→`["e", code, url]`,
// `["client", …]`→`["c", …]`). Same id, SAME tag count, so neither arrival
// order nor a tags.length tie-break identifies the renderable copy; the old
// store-first/seenIds merge (v1.0.8) and the length rule (v1.0.9) both let
// the mutated copy win → reaction glyph fell back to the raw `:shortcode:`
// ("表情图一闪而过变回 shortcode", then "都显示 shortcode"). Both the index
// and the interactors list must prefer the copy carrying the well-formed
// NIP-30 emoji tag, regardless of tier order.

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
final String _postId = 'p' * 64;
final String _author = 'a' * 64;

/// The SAME event id in both tiers — the full copy carries the well-formed
/// NIP-30 emoji tag; the mutated copy (relay-mangled) truncates tag names
/// but keeps the SAME tag count.
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

Event _reaction({required bool mutated}) => Event(
  id: _reactionId,
  pubkey: 'b' * 64,
  createdAt: 1700000100,
  kind: 7,
  tags: mutated
      ? [
          ['e', _postId, '', _author],
          ['p', _author, ''],
          ['k', '1'],
          // Truncated names: emoji→e, client→c (as observed in the wild).
          ['e', 'wechat_ThumbsUp', _emojiUrl],
          ['c', 'Amethyst'],
        ]
      : [
          ['e', _postId, '', _author],
          ['p', _author, ''],
          ['k', '1'],
          ['emoji', 'wechat_ThumbsUp', _emojiUrl],
          ['client', 'Amethyst'],
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
  test('index: mutated store copy must not shadow the full cache copy', () async {
    final container = await _container(store: [_reaction(mutated: true)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(mutated: false)]);
    final chips = container.read(reactionsProvider(_postId));
    expect(chips[':wechat_ThumbsUp:']?.count, 1);
    expect(chips[':wechat_ThumbsUp:']?.emojiUrl, _emojiUrl);
  });

  test('index: reverse tier order keeps the renderable copy too', () async {
    final container = await _container(store: [_reaction(mutated: false)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(mutated: true)]);
    final chips = container.read(reactionsProvider(_postId));
    expect(chips[':wechat_ThumbsUp:']?.emojiUrl, _emojiUrl);
  });

  test('index: mutated-only (no full copy anywhere) still counts, no url', () async {
    final container = await _container(store: [_reaction(mutated: true)]);
    addTearDown(container.dispose);
    final chips = container.read(reactionsProvider(_postId));
    expect(chips[':wechat_ThumbsUp:']?.count, 1);
    expect(chips[':wechat_ThumbsUp:']?.emojiUrl, isNull);
  });

  test('interactors list: same renderable-copy rule as the index', () async {
    final container = await _container(store: [_reaction(mutated: true)]);
    addTearDown(container.dispose);
    container
        .read(interactionCacheProvider.notifier)
        .ingest([_reaction(mutated: false)]);
    final events = container.read(interactorEventsProvider(_postId));
    expect(events, hasLength(1));
    expect(
      events.single.tags.any((t) => t.isNotEmpty && t[0] == 'emoji'),
      isTrue,
      reason: 'the glyph source must be the well-formed copy',
    );
  });
}
