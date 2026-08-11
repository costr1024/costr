import 'package:costr/app/providers.dart';
import 'package:costr/features/feed/event_card.dart';
import 'package:costr/models/event.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

class _Id extends IdentityNotifier {
  @override
  Future<Identity?> build() async => Identity.fromPrivkeyHex(_priv);
}

Event _ev(
  String id, {
  List<List<dynamic>> tags = const [],
  String content = '',
}) => Event(
  id: id,
  pubkey: 'b73d3ed864c50fe656ae62de1098282cf1b9d1f49e6ac6459cb4cbe7b9176ab0',
  createdAt: 1700000000,
  kind: 1,
  tags: tags,
  content: content,
  sig: 's',
);

void main() {
  testWidgets('NSFW card with short content: no overflow into next card', (
    tester,
  ) async {
    final details = <FlutterErrorDetails>[];
    final old = FlutterError.onError;
    FlutterError.onError = (d) {
      details.add(d);
      FlutterError.presentError(d);
    };
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          bootstrapProvider.overrideWith((ref) async {}),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _NsfwOff()),
          metadataProvider.overrideWith((ref, pk) async* {
            yield null;
          }),
          reactionsProvider.overrideWith((ref, id) => const {}),
          followedTagsProvider.overrideWith(() => _EmptyTags()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                EventCard(
                  event: _ev(
                    'nsfw1',
                    tags: const [
                      ['t', 'nsfw'],
                    ],
                    content: '短帖',
                  ),
                ),
                EventCard(event: _ev('plain1', content: '下一条普通帖子')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    FlutterError.onError = old;
    for (final d in details) {
      debugPrint('=== NSFW OVERFLOW ===\n${d.toString()}\n=== END ===');
    }
    expect(details, isEmpty, reason: 'NSFW card must not overflow');
  });
}

class _NsfwOff extends NsfwSettingsNotifier {
  @override
  NsfwSettings build() => const NsfwSettings();
}

class _EmptyTags extends FollowedTagsNotifier {
  @override
  Future<List<String>> build() async => const <String>[];
}
