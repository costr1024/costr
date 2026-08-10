// Long-post parse hardening (regression: 100KB+ spam posts made every card
// build parse the full content, freezing the feed — "开中文过滤卡死"):
// - collapsed: only a bounded prefix is parsed (deep content absent);
// - expanded: parsed up to the hard cap; content beyond it is replaced by a
//   note instead of a multi-second parse;
// - normal-sized long posts still expand to their full content.
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

Event _post(String id, String content) => Event(
  id: id,
  pubkey: 'p' * 64,
  createdAt: 1700000000,
  kind: 1,
  tags: const [],
  content: content,
  sig: 's',
);

Event _megaPost(String marker) {
  // ~150KB: filler up front, the marker buried far past the expanded cap.
  final buf = StringBuffer();
  for (var i = 0; i < 3000; i++) {
    buf.write('filler paragraph line $i with some words to parse. ');
  }
  buf.write('\n\n');
  buf.write(marker);
  buf.write('\n\n');
  for (var i = 0; i < 3000; i++) {
    buf.write('trailing filler line $i with even more words. ');
  }
  return _post('mega', buf.toString());
}

void main() {
  const marker = 'ZZZDEEMARKER999';

  Widget harness(Event e) => ProviderScope(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      bootstrapProvider.overrideWith((ref) async {}),
      identityProvider.overrideWith(() => _Id()),
      metadataProvider.overrideWith((ref, pk) async* { yield null; }),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: MarkdownContent(event: e)),
      ),
    ),
  );

  testWidgets('mega-post: collapsed parses a prefix, 展开 stops at the cap', (
    tester,
  ) async {
    final sw = Stopwatch()..start();
    await tester.pumpWidget(harness(_megaPost(marker)));
    await tester.pump();
    final collapsedBuildMs = sw.elapsedMilliseconds;

    // Collapse affordance shows; the deep marker is NOT rendered.
    expect(find.text('展开'), findsOneWidget);
    expect(
      find.textContaining(marker, findRichText: true),
      findsNothing,
      reason: 'content past the collapsed parse cap must not be parsed',
    );
    // The beginning of the post still renders.
    expect(
      find.textContaining('filler paragraph line 0', findRichText: true),
      findsOneWidget,
    );

    // Expand — parsing stays bounded at the hard cap; the marker (far past
    // it) never appears; the truncation note does.
    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(find.textContaining(marker, findRichText: true), findsNothing);
    expect(find.text('内容过长，超出部分已省略'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    // Sanity: the collapsed build stayed cheap (full 150KB markdown parse in
    // the widget harness is orders of magnitude slower than the bounded
    // prefix; allow a generous ceiling so CI variance never flakes it).
    expect(
      collapsedBuildMs,
      lessThan(2000),
      reason: 'collapsed build must not parse the whole 150KB post',
    );
  });

  testWidgets('normal long post (>400, <cap) expands to FULL content', (
    tester,
  ) async {
    final buf = StringBuffer();
    for (var i = 0; i < 60; i++) {
      buf.write('a reasonably long paragraph number $i. ');
    }
    buf.write(marker); // ~2.5KB total: collapsible, far under the cap
    await tester.pumpWidget(harness(_post('mid', buf.toString())));
    await tester.pump();
    expect(find.textContaining(marker, findRichText: true), findsNothing);
    await tester.tap(find.text('展开'));
    await tester.pump();
    expect(find.textContaining(marker, findRichText: true), findsOneWidget);
    expect(find.text('内容过长，超出部分已省略'), findsNothing);
  });

  testWidgets('short posts are unaffected (no collapse, full content)', (
    tester,
  ) async {
    await tester.pumpWidget(harness(_post('short', 'hello $marker world')));
    await tester.pump();
    expect(find.textContaining(marker, findRichText: true), findsOneWidget);
    expect(find.text('展开'), findsNothing);
  });
}
