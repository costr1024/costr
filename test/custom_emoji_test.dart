// NIP-30 custom-emoji display: a `:shortcode:` in content backed by an
// `["emoji", shortcode, url]` tag must render as an inline image (not the
// raw `:shortcode:` text). Uses pump (not pumpAndSettle) so the network
// image is never actually fetched — we only assert the Image widget is built.
import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

void main() {
  testWidgets('custom emoji :shortcode: renders an inline image', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          metadataProvider.overrideWith((ref, pk) async* { yield null; }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownContent(
              event: Event(
                id: 'e1',
                pubkey:
                    'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
                createdAt: 1700000000,
                kind: 1,
                tags: const [
                  ['emoji', 'costr', 'https://example.com/costr.png'],
                ],
                content: 'hello :costr: world',
                sig: 's',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(); // build a frame without waiting on the network
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('unknown shortcode (no emoji tag) stays as text', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          metadataProvider.overrideWith((ref, pk) async* { yield null; }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: MarkdownContent(
              event: Event(
                id: 'e2',
                pubkey:
                    'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
                createdAt: 1700000000,
                kind: 1,
                tags: const [],
                content: 'no emoji :unknown: here',
                sig: 's',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsNothing);
  });
}
