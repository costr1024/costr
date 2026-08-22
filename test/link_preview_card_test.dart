// Link-preview rendering in MarkdownContent: bare web URLs resolve via
// linkPreviewProvider — image results replace the URL text in place, webpage
// results add an Open Graph card below, UrlNone keeps today's plain link.
// Uses pump (not pumpAndSettle) so no network image is ever actually fetched.
import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/link_preview.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:costr/widgets/proxied_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

const _url = 'https://example.com/article';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

Event _note(String content) => Event(
  id: 'e1',
  pubkey: 'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's',
);

Widget _app(Widget child, UrlInspection Function(String url) resolve) {
  return ProviderScope(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      bootstrapProvider.overrideWith((ref) async {}),
      identityProvider.overrideWith(() => _Id()),
      metadataProvider.overrideWith((ref, pk) async* {
        yield null;
      }),
      linkPreviewProvider.overrideWith((ref, url) async => resolve(url)),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

/// All visible text in the tree.
String _allText(WidgetTester tester) {
  final all = StringBuffer();
  for (final el in find.byType(RichText).evaluate()) {
    all.writeln((el.widget as RichText).text.toPlainText());
  }
  for (final el in find.byType(Text).evaluate()) {
    all.writeln((el.widget as Text).data ?? '');
  }
  return all.toString();
}

void main() {
  testWidgets('UrlNone keeps the plain clickable URL, no card', (tester) async {
    await tester.pumpWidget(
      _app(MarkdownContent(event: _note('看看 $_url 吧')), (u) => const UrlNone()),
    );
    await tester.pump();
    await tester.pump();
    expect(_allText(tester), contains(_url)); // still a text link
    expect(find.text('预览标题'), findsNothing);
    expect(find.byType(CostrNetworkImage), findsNothing);
  });

  testWidgets('UrlWebpage renders the OG card AND keeps the URL text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        MarkdownContent(event: _note('看看 $_url 吧')),
        (u) => const UrlWebpage(
          LinkPreview(
            pageUrl: 'https://example.com/article',
            domain: 'example.com',
            title: '预览标题',
            description: '预览描述文字',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final all = _allText(tester);
    expect(all, contains(_url)); // the link text itself stays
    expect(find.text('预览标题'), findsOneWidget);
    expect(find.text('预览描述文字'), findsOneWidget);
    expect(find.text('example.com'), findsOneWidget);
  });

  testWidgets('anti-bot wall degrades to a domain-only card', (tester) async {
    await tester.pumpWidget(
      _app(
        MarkdownContent(
          event: _note('https://m.weibo.cn/detail/5334299719240859'),
        ),
        (u) => const UrlWebpage(
          LinkPreview(
            pageUrl: 'https://m.weibo.cn/detail/5334299719240859',
            domain: 'm.weibo.cn',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final all = _allText(tester);
    expect(all, isNot(contains('Sina Visitor System')));
    // Domain line: one occurrence in the URL text + one in the card.
    expect(find.text('m.weibo.cn'), findsOneWidget);
  });

  testWidgets('UrlImage replaces the URL text with the image in place', (
    tester,
  ) async {
    const img = 'https://ci.xiaohongshu.com/n/abc?imageView2/2/w/0/format/jpg';
    await tester.pumpWidget(
      _app(
        MarkdownContent(event: _note('野原新之助 $img')),
        (u) => const UrlImage(img),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(_allText(tester), isNot(contains('xiaohongshu'))); // text gone
    expect(find.byType(CostrNetworkImage), findsOneWidget); // image in place
  });
}
