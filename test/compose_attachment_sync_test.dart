// Regression: compose attachment thumbnails and the editor text hold the same
// uploaded URLs and must stay in sync BOTH ways. Before this, deleting an
// image URL from the text left its thumbnail behind (manual × required), and
// removing a thumbnail left the URL in the text.

import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/features/compose/compose_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:extended_text_field/extended_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
const _url = 'https://blossom.example/x.jpg';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

class _Nsfw extends NsfwSettingsNotifier {
  @override
  NsfwSettings build() => const NsfwSettings();
}

class _FakeCache implements cache.LocalCache {
  final Map<String, String> config = {};

  @override
  Future<String?> readConfig(String key) async => config[key];

  @override
  Future<void> writeConfig(String key, String value) async {
    config[key] = value;
  }

  @override
  Future<int> saveDraft(String rawJson) async => 0;

  @override
  Future<void> deleteDraft(int rowid) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('deleting the URL from the text removes the thumbnail', (
    tester,
  ) async {
    final db = _FakeCache();
    db.config['compose_draft'] = jsonEncode(<String, dynamic>{
      'text': 'hello\n$_url',
      'attachments': [
        <String, String>{
          'url': _url,
          'sha256': 'a' * 64,
          'mime': 'image/jpeg',
          'name': 'x.jpg',
          'kind': 'image',
        },
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _Nsfw()),
          localCacheProvider.overrideWith((ref) async => db),
        ],
        child: const MaterialApp(home: ComposePage()),
      ),
    );
    // Draft load (async config read) settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.cancel), findsOneWidget,
        reason: 'restored draft shows the attachment thumbnail');

    // User deletes the image URL from the editor text. Drive the editor's
    // own controller (extended_text_field wraps EditableText in custom
    // internals enterText can't see); the change listener still fires.
    final field =
        tester.widget<ExtendedTextField>(find.byType(ExtendedTextField));
    field.controller!.text = 'hello';
    await tester.pump();

    expect(find.byIcon(Icons.cancel), findsNothing,
        reason: 'thumbnail must follow the deleted URL out');
  });

  testWidgets('removing the thumbnail strips its URL from the text', (
    tester,
  ) async {
    final db = _FakeCache();
    db.config['compose_draft'] = jsonEncode(<String, dynamic>{
      'text': 'hello\n$_url',
      'attachments': [
        <String, String>{
          'url': _url,
          'sha256': 'a' * 64,
          'mime': 'image/jpeg',
          'name': 'x.jpg',
          'kind': 'image',
        },
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _Nsfw()),
          localCacheProvider.overrideWith((ref) async => db),
        ],
        child: const MaterialApp(home: ComposePage()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byIcon(Icons.cancel), findsOneWidget);
    await tester.tap(find.byIcon(Icons.cancel));
    await tester.pump();

    final field =
        tester.widget<ExtendedTextField>(find.byType(ExtendedTextField));
    expect(field.controller!.text, isNot(contains(_url)),
        reason: 'the removed thumbnail\'s URL must leave the editor');
    expect(field.controller!.text, contains('hello'));
    expect(find.byIcon(Icons.cancel), findsNothing);
  });
}
