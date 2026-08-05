// Regression: pasting a blossom media URL into the compose editor must NOT
// turn the npub inside it into an @-mention chip. blossom serves media under
// the uploader's npub as a subdomain (`https://npub1….blossom.band/<sha>.jpg`);
// chipping the npub part visually broke the URL in the editor (the signed
// content was always fine, only the display mangled). This also guards the
// NIP-27 tag derivation, which must not emit mention `p`/`e` tags for entities
// that live inside a URL.
import 'package:costr/app/providers.dart';
import 'package:costr/features/compose/compose_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:extended_text_field/extended_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

// A real, decodable npub — blossom.band uses it as the media subdomain.
const _npub = 'npub1ak68qfcjj7k95c0jwleu69x72nr8adwv6g80pkwl9xlps6zmkqzqrxy8fx';
const _blossomUrl =
    'https://$_npub.blossom.band/'
    'b1d30250bcfb0075326f6395ba35fc7ed94d3c98498f599ee4b64eec56a3d6a4.jpg';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Nsfw extends NsfwSettingsNotifier {
  @override
  NsfwSettings build() => const NsfwSettings();
}

/// localCacheProvider throws immediately: the composer's draft load/save all
/// `catch (_) {}`, so no drift DB (background isolate) is needed in-test.
ProviderScope _scope(Widget child) => ProviderScope(
  overrides: [
    relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
    bootstrapProvider.overrideWith((ref) async {}),
    identityProvider.overrideWith(() => _Id()),
    nsfwSettingsProvider.overrideWith(() => _Nsfw()),
    metadataProvider.overrideWith((ref, pk) async* {
      yield null;
    }),
    knownUsersProvider.overrideWith((ref) => const <KnownUser>[]),
    localCacheProvider.overrideWith(
      (ref) async => throw StateError('no local cache in tests'),
    ),
  ],
  child: MaterialApp(home: child),
);

/// Count [SpecialTextSpan]s (mention chips) in a span tree.
int _chipCount(InlineSpan span) {
  var n = span is SpecialTextSpan ? 1 : 0;
  if (span is TextSpan) {
    for (final c in span.children ?? const <InlineSpan>[]) {
      n += _chipCount(c);
    }
  }
  return n;
}

/// Set the composer's editor text and let the draft-save debounce settle.
Future<void> _setText(WidgetTester tester, String text) async {
  final field = tester.widget<ExtendedTextField>(
    find.byType(ExtendedTextField),
  );
  final controller = field.controller!;
  controller.value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  // > 300ms so the draft-save debounce timer fires (and is caught), leaving no
  // pending timers at test end.
  await tester.pump(const Duration(milliseconds: 400));
}

TextSpan _editorSpan(WidgetTester tester) {
  final state = tester.state<ExtendedEditableTextState>(
    find.byType(ExtendedEditableText),
  );
  return state.buildTextSpan();
}

void main() {
  testWidgets('npub inside a pasted blossom URL stays plain (no chip)', (
    tester,
  ) async {
    await tester.pumpWidget(_scope(const ComposePage()));
    await tester.pump();

    await _setText(tester, 'look $_blossomUrl here');

    final span = _editorSpan(tester);
    // No mention chip for the npub that is part of the URL host…
    expect(_chipCount(span), 0);
    // …and the URL survives intact as plain text (not rewritten to @…).
    final plain = span.toPlainText();
    expect(plain, contains(_npub));
    expect(plain, contains('.blossom.band'));
    expect(plain, isNot(contains('@npub1')));
  });

  testWidgets('a bare mention outside any URL still becomes a chip', (
    tester,
  ) async {
    await tester.pumpWidget(_scope(const ComposePage()));
    await tester.pump();

    await _setText(tester, 'hi nostr:$_npub bye');

    final span = _editorSpan(tester);
    // The bare entity is chipped (one SpecialTextSpan)…
    expect(_chipCount(span), 1);
    // …so the raw entity no longer appears as plain text (it renders @label).
    final plain = span.toPlainText();
    expect(plain, isNot(contains(_npub)));
    expect(plain, contains('@'));
  });
}
