// Regression: flutter_markdown's fromTheme paints blockquotes on
// `Colors.blue.shade100` — a Material blue outside the X palette. Posts that
// quote a headline with `> …` (e.g. 财新-style link posts) rendered as glaring
// blue blocks in the feed. costrMarkdownStyleSheet must restyle them onto the
// app palette (bg2 fill + hairline left border).
import 'package:costr/app/providers.dart';
import 'package:costr/app/theme.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

// Shape of the reported post: hashtag + `> quote` + link.
const _content =
    '#财新\n'
    '> 消息传出后，保诚、汇丰和渣打股价下跌\n'
    '\n'
    'https://database.caixin.com/2026-08-06/102471636.html';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Every [BoxDecoration] in the tree.
List<BoxDecoration> _boxDecorations(WidgetTester tester) {
  final out = <BoxDecoration>[];
  for (final el in find.byType(DecoratedBox).evaluate()) {
    final d = (el.widget as DecoratedBox).decoration;
    if (d is BoxDecoration) out.add(d);
  }
  for (final el in find.byType(Container).evaluate()) {
    final d = (el.widget as Container).decoration;
    if (d is BoxDecoration) out.add(d);
  }
  return out;
}

void main() {
  testWidgets('blockquote renders on palette, not Material blue', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          metadataProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MarkdownContent(
              event: Event(
                id: 'e1',
                pubkey:
                    'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
                createdAt: 1700000000,
                kind: 1,
                tags: const [
                  ['t', '财新'],
                ],
                content: _content,
                sig: 's',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // build a frame without waiting on the network

    final decos = _boxDecorations(tester);
    // The library default blue (Colors.blue.shade100 = 0xFFBBDEFB) is gone…
    expect(decos.where((d) => d.color == const Color(0xFFBBDEFB)), isEmpty);
    // …replaced by the palette's secondary surface…
    expect(decos.where((d) => d.color == CostrColors.light.bg2), isNotEmpty);
    // …with the quote-card style left border.
    expect(
      decos.where((d) {
        final b = d.border;
        return b is Border && b.left.width == 3;
      }),
      isNotEmpty,
    );
    // The quoted text itself still renders.
    final all = StringBuffer();
    for (final el in find.byType(RichText).evaluate()) {
      all.writeln((el.widget as RichText).text.toPlainText());
    }
    expect(all.toString(), contains('消息传出后'));
  });
}
