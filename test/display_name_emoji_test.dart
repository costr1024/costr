// NIP-30 custom emoji in DISPLAY NAMES: a kind-0 name like
// "科代 :winnie_kanahei_0:" + `["emoji", shortcode, url]` tags must render
// the image inline (Amethyst does; Costr showed the raw :shortcode: text).
// Covers both the standalone [DisplayName] widget and the embeddable
// [displayNameSpans] (used in the notification title line).

import 'package:costr/models/metadata.dart';
import 'package:costr/widgets/display_name.dart';
import 'package:costr/widgets/proxied_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Metadata _meta(String name, {List<List<String>> tags = const []}) =>
    Metadata.fromJson(
      <String, dynamic>{'name': name},
      tags: tags,
    );

void main() {
  test('Metadata.fromJson parses emoji tags into customEmoji', () {
    final m = Metadata.fromJson(
      <String, dynamic>{'name': 'x'},
      tags: [
        ['emoji', 'winnie', 'https://example.com/w.png'],
        ['p', 'somethingelse'],
        ['emoji', 'cat', 'https://example.com/c.png'],
      ],
    );
    expect(m.customEmoji, {
      'winnie': 'https://example.com/w.png',
      'cat': 'https://example.com/c.png',
    });
    expect(Metadata.fromJson(<String, dynamic>{'name': 'x'}).customEmoji,
        isEmpty);
  });

  testWidgets('known shortcode becomes an inline image', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DisplayName(
            pubkey: 'a' * 64,
            meta: _meta(
              '科代 :winnie:',
              tags: [
                ['emoji', 'winnie', 'https://example.com/w.png']
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // The plain name fragment stays…
    expect(find.textContaining('科代'), findsOneWidget);
    // …and the shortcode is replaced by the emoji image (no raw :winnie:).
    expect(find.byType(CostrNetworkImage), findsOneWidget);
    expect(
      find.textContaining(':winnie:'),
      findsNothing,
      reason: 'the raw shortcode text must not be shown',
    );
  });

  testWidgets('unknown shortcode keeps its text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DisplayName(
            pubkey: 'a' * 64,
            meta: _meta('name :nope: here'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining(':nope:'), findsOneWidget);
    expect(find.byType(CostrNetworkImage), findsNothing);
  });

  testWidgets('no emoji tags → plain name text', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DisplayName(pubkey: 'a' * 64, meta: _meta('plain name')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('plain name'), findsOneWidget);
  });

  testWidgets('no metadata → shortened npub fallback', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: DisplayName(pubkey: 'a' * 64, meta: null)),
      ),
    );
    await tester.pump();
    expect(find.byType(Text), findsOneWidget);
    expect(find.textContaining('npub'), findsOneWidget);
  });

  group('displayNameSpans (notification title embedding)', () {
    const style = TextStyle(fontSize: 14, fontWeight: FontWeight.w700);

    test('emoji name → mixed spans with an image widget span', () {
      final spans = displayNameSpans(
        pubkey: 'a' * 64,
        meta: _meta(
          '科代 :winnie:',
          tags: [
            ['emoji', 'winnie', 'https://example.com/w.png']
          ],
        ),
        style: style,
      );
      expect(spans.length, 2);
      expect((spans[0] as TextSpan).text, '科代 ');
      expect(spans[1], isA<WidgetSpan>());
    });

    test('plain name → single styled TextSpan', () {
      final spans = displayNameSpans(
        pubkey: 'a' * 64,
        meta: _meta('普通名字'),
        style: style,
      );
      expect(spans.length, 1);
      final span = spans.single as TextSpan;
      expect(span.text, '普通名字');
      expect(span.style, style,
          reason: 'spans carry the style explicitly — they get dropped into '
              'a foreign RichText (notification title) where inheritance '
              'would not apply');
    });

    test('no metadata → npub fallback span', () {
      final spans =
          displayNameSpans(pubkey: 'a' * 64, meta: null, style: style);
      expect(spans.length, 1);
      expect((spans.single as TextSpan).text, contains('npub'));
    });
  });
}
