// NIP-19 naddr references in post content: the raw entity is stripped from
// the text and an embed card is appended below (Amethyst-style), mirroring
// the NIP-27 quote-embed contract — loading text while the lookup runs, the
// resolved article's title + snippet when found, a compact label for
// non-post kinds.

import 'dart:async';
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/models/event.dart';
import 'package:costr/models/mute_set.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/link_preview.dart';
import 'package:costr/utils/bech32_codec.dart';
import 'package:costr/widgets/markdown_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

const _author =
    'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

/// Build a real `naddr1…` entity (NIP-19 TLV: 0=d, 1=relay, 2=author,
/// 3=kind big-endian).
String _naddr({String d = 'my-article', int kind = 30023}) {
  final tlv = <int>[];
  final dBytes = utf8.encode(d);
  tlv.addAll([0, dBytes.length, ...dBytes]);
  final pk = <int>[
    for (var i = 0; i < 64; i += 2)
      int.parse(_author.substring(i, i + 2), radix: 16),
  ];
  tlv.addAll([2, 32, ...pk]);
  tlv.addAll([
    3,
    4,
    (kind >> 24) & 0xff,
    (kind >> 16) & 0xff,
    (kind >> 8) & 0xff,
    kind & 0xff,
  ]);
  return encodeBech32('naddr', tlv);
}

Event _note(String content) => Event(
      id: 'e1',
      pubkey: _author,
      createdAt: 1700000000,
      kind: 1,
      tags: const [],
      content: content,
      sig: 's',
    );

Widget _app(Widget child, Future<Event?> Function(String key) resolve) {
  return ProviderScope(
    overrides: [
      relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
      bootstrapProvider.overrideWith((ref) async {}),
      identityProvider.overrideWith(() => _Id()),
      metadataProvider.overrideWith((ref, pk) async* {
        yield null;
      }),
      linkPreviewProvider.overrideWith(
        (ref, url) async => const UrlNone(),
      ),
      myMuteSetProvider.overrideWith((ref) => const MuteSet()),
      addressedEventProvider.overrideWith((ref, key) => resolve(key)),
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
  testWidgets('bare naddr entity is stripped; card loads, then resolves', (
    tester,
  ) async {
    final entity = _naddr();
    final article = Event(
      id: 'a1',
      pubkey: _author,
      createdAt: 1700000100,
      kind: 30023,
      tags: const [
        ['d', 'my-article'],
        ['title', '深度长文标题'],
      ],
      content: '文章正文第一段，介绍背景。',
      sig: 's',
    );
    final gate = Completer<Event?>();
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: MarkdownContent(event: _note('看看这篇：nostr:$entity')),
        ),
        (key) => gate.future,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // The raw entity never shows as text; the lookup card does.
    expect(_allText(tester), isNot(contains('naddr1')));
    expect(_allText(tester), contains('加载引用…'));

    // Resolve the lookup → title + snippet render in the embed card.
    gate.complete(article);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_allText(tester), contains('深度长文标题'));
    expect(_allText(tester), contains('文章正文第一段，介绍背景。'));
  });

  testWidgets('miss settles to 点击重试', (tester) async {
    final entity = _naddr();
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: MarkdownContent(event: _note('nostr:$entity')),
        ),
        (key) async => null,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_allText(tester), contains('引用内容不可用'));
  });

  testWidgets('non-post kinds render the compact label, not a post card', (
    tester,
  ) async {
    final entity = _naddr(kind: 10002);
    final relayList = Event(
      id: 'r1',
      pubkey: _author,
      createdAt: 1700000100,
      kind: 10002,
      tags: const [
        ['d', 'relay-list'],
      ],
      content: '',
      sig: 's',
    );
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: MarkdownContent(event: _note('nostr:$entity')),
        ),
        (key) async => relayList,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_allText(tester), contains('引用了类型 10002 的事件'));
  });
}
