// Reaction picker: more than the old 2 rows of unicode, plus a NIP-30
// custom-emoji section fed by the post's own emoji tags + custom emoji
// others already reacted with (user: "只有2排可选").

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/post_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

Event _post({List<List<String>> tags = const []}) => Event(
  id: 'p' * 64,
  pubkey: 'a' * 64,
  createdAt: 100000,
  kind: 1,
  tags: tags,
  content: 'hello',
  sig: 's' * 128,
);

Future<void> pumpActions(WidgetTester tester, Event event) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        identityProvider.overrideWith(() => _Id()),
        userRelayListProvider.overrideWith((ref, pubkey) async => null),
      ],
      child: MaterialApp(
        home: Scaffold(body: PostActions(event: event)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('picker offers a wide unicode grid (not just 2 rows)', (
    tester,
  ) async {
    await pumpActions(tester, _post());
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();

    expect(find.text('选择表情'), findsOneWidget);
    // Old set was 10 emojis; the new set must be far wider — spot-check a
    // few that used to be missing.
    for (final e in ['🥳', '😭', '🚀', '💯', '🫶', '🎂']) {
      expect(find.text(e), findsOneWidget, reason: '$e must be offered');
    }
    // The sheet content is scrollable (SingleChildScrollView present).
    expect(find.byType(SingleChildScrollView), findsWidgets);
  });

  testWidgets('custom emoji from the post tags are offered', (tester) async {
    await pumpActions(
      tester,
      _post(
        tags: [
          ['emoji', 'pepe', 'https://example.com/pepe.png'],
        ],
      ),
    );
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    // The chip's label IS the emoji image (mirrors the unicode section where
    // the glyph is the label); the shortcode survives as the chip tooltip.
    // Before the fix the chip rendered avatar image AND a `:code:` Text label
    // side by side — 「自定义表情同时显示 :xxx:」bug — so the old code shows
    // an unconditional `:pepe:` Text here and no tooltip. In the test env the
    // image sits in its placeholder state, so the new chip shows NO text at
    // all (on-device a dead image falls back to the :code: text instead).
    expect(
      find.byTooltip(':pepe:'),
      findsOneWidget,
      reason: 'the post\'s own custom emoji must be offered',
    );
    expect(
      find.text(':pepe:'),
      findsNothing,
      reason: 'no :code: text rendered next to the emoji image',
    );
  });

  testWidgets('picking a unicode emoji publishes a kind-7', (tester) async {
    await pumpActions(tester, _post());
    await tester.tap(find.byIcon(Icons.favorite_border));
    await tester.pumpAndSettle();
    await tester.tap(find.text('🔥'));
    await tester.pumpAndSettle();
    // Let the 2s snackbar timer run out so no timer is pending at teardown.
    // Empty pool → publish fails fast with a snack ("no connected relay"),
    // but the picker flow completes without error.
    expect(find.textContaining('反应失败'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}
