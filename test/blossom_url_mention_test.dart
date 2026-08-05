// Regression: blossom servers serve media under the uploader's npub as a
// subdomain — `https://npub1….blossom.band/<sha256>.mp4` (seen in the wild,
// Amethyst posts). The npub INSIDE the URL must not be linkified into an
// `[@name](nostr:…)` mention: that rewrote the URL, showed a stray `@npub…`
// label and broke the video (the mangled URL no longer matched the media
// tokenizer, and the imeta attachment was skipped as "already in content").
import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:costr/widgets/mention_linkifier.dart';
import 'package:costr/widgets/network_video.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

// The post author's npub, used by blossom.band as the media subdomain.
const _npub = 'npub1ak68qfcjj7k95c0jwleu69x72nr8adwv6g80pkwl9xlps6zmkqzqrxy8fx';
const _authorPk =
    'edb470271297ac5a61f277f3cd14de54c67eb5ccd20ef0d9df29be18685bb004';
const _videoUrl =
    'https://$_npub.blossom.band/'
    '200f65747d4b50e01a6e912a628e2c1da49fc4a45c5bfdccc2cb4fef783e8776.mp4';
const _content = 'NVK knew in 2021. He told Matt Odell. \n\n$_videoUrl';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

Event _blossomPost() => Event(
  id: 'e1',
  pubkey: _authorPk,
  createdAt: 1700000000,
  kind: 1,
  tags: const [
    ['r', _videoUrl],
    [
      'imeta',
      'url $_videoUrl',
      'x 200f65747d4b50e01a6e912a628e2c1da49fc4a45c5bfdccc2cb4fef783e8776',
      'size 13218300',
      'm video/mp4',
      'dim 480x584',
    ],
  ],
  content: _content,
  sig: 's',
);

ProviderScope _scope(Widget child) => ProviderScope(
  overrides: [
    relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
    bootstrapProvider.overrideWith((ref) async {}),
    identityProvider.overrideWith(() => _Id()),
    metadataProvider.overrideWith((ref, pk) async* {
      yield null;
    }),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

/// All rendered text under the tree (flutter_markdown emits RichText, plain
/// Text and Text.rich all appear) — one string to assert on.
String _allText(WidgetTester tester) {
  final buf = StringBuffer();
  for (final el in find.byType(RichText).evaluate()) {
    buf.writeln((el.widget as RichText).text.toPlainText());
  }
  for (final t in tester.widgetList<Text>(find.byType(Text))) {
    buf.writeln(t.textSpan?.toPlainText() ?? t.data ?? '');
  }
  return buf.toString();
}

void main() {
  testWidgets('npub-subdomain video URL renders a video, URL untouched', (
    tester,
  ) async {
    await tester.pumpWidget(_scope(MarkdownContent(event: _blossomPost())));
    await tester.pump(); // build one frame without waiting on the network

    // The bare video URL is extracted and rendered as a video player
    // (exactly once — the imeta copy is deduped against the content URL)…
    expect(find.byType(NetworkVideo), findsOneWidget);
    final all = _allText(tester);
    // …the npub inside it is NOT linkified: no `@npub…` mention label…
    expect(all, isNot(contains('@npub1')));
    // …and no mangled URL tail left behind as plain text (the pre-fix output
    // showed `@label` + `.blossom.band/200….mp4` as text, no video).
    expect(all, isNot(contains('blossom.band')));
    // The post text itself still renders.
    expect(all, contains('NVK knew in 2021'));
  });

  testWidgets('a real mention OUTSIDE any URL is still linkified', (
    tester,
  ) async {
    // Guard against over-skipping: the URL guard must only suppress entities
    // inside URLs. With no metadata the mention label is `@npub1xxx…yyyy`.
    await tester.pumpWidget(
      _scope(
        MarkdownContent(
          event: Event(
            id: 'e2',
            pubkey: _authorPk,
            createdAt: 1700000000,
            kind: 1,
            tags: const [],
            content: 'hello nostr:$_npub world',
            sig: 's',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(_allText(tester), contains('@npub1'));
  });

  testWidgets('linkifyMentions (quote-card previews) leaves URLs untouched', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          metadataProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) =>
                  Text.rich(linkifyMentions(_content, ref)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The URL survives as one intact run (pre-fix the npub part became a
    // `@label` span: `https://@….blossom.band/…`).
    final all = _allText(tester);
    expect(all, contains(_videoUrl));
    expect(all, isNot(contains('@npub1')));
  });
}
