// Regression: attachment COUNT caps must hold while uploads are in flight.
// Attachments only land in _attachments after their upload completes, so the
// cap counters ("最多 9 张图片" / single media slot / 4 files) read stale
// counts mid-upload — re-picking during a batch used to overshoot every cap
// ("单次可上传图片数量可以超出 9 张"). The entry buttons now disable while an
// upload batch is running and the pick handlers re-check the in-flight state.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:costr/app/providers.dart';
import 'package:costr/features/compose/compose_page.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';

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

/// Scripted picker: returns [files] for every pick and counts invocations.
class _FakePicker extends FilePicker {
  _FakePicker(this.files);
  final List<PlatformFile> files;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    return FilePickerResult(files);
  }
}

PlatformFile _file(String name) => PlatformFile(
      name: name,
      size: 16,
      bytes: Uint8List.fromList(List.filled(16, 1)),
    );

void main() {
  late HttpServer server;
  // Gate holding every PUT /upload in flight until the test releases it.
  late Completer<void> gate;
  var uploadsServed = 0;

  setUp(() async {
    // The widget-test binding hooks dart:io HttpClient to answer 400 without
    // sending anything — defeat it so uploads reach the local Blossom stand-in
    // over real loopback.
    HttpOverrides.global = null;
    gate = Completer<void>();
    uploadsServed = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      if (req.method == 'PUT' && req.uri.path == '/upload') {
        await req.drain<void>();
        await gate.future; // stay "uploading" until the test says otherwise
        uploadsServed++;
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'url': 'https://blossom.example/f$uploadsServed',
            'sha256': 'a' * 64,
          }),
        );
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  tearDown(() async {
    if (!gate.isCompleted) gate.complete();
    await server.close(force: true);
  });

  Widget buildApp() => ProviderScope(
        overrides: [
          relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
          identityProvider.overrideWith(() => _Id()),
          nsfwSettingsProvider.overrideWith(() => _Nsfw()),
          localCacheProvider.overrideWith((ref) async => _FakeCache()),
          serverListsProvider.overrideWith(
            (ref) async => ServerLists(
              relays: const [],
              search: const [],
              indexer: const [],
              blossom: ['http://127.0.0.1:${server.port}'],
            ),
          ),
        ],
        child: const MaterialApp(home: ComposePage()),
      );

  TextButton attachBtnOf(WidgetTester tester, String label) =>
      tester.widget<TextButton>(find.widgetWithText(TextButton, label));

  testWidgets('image cap holds mid-upload; re-pick is blocked', (
    tester,
  ) async {
    final picker = _FakePicker(
      List.generate(12, (i) => _file('img$i.jpg')),
    );
    FilePicker.platform = picker;

    await tester.pumpWidget(buildApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() async {
      Future<void> waitFor(Finder f, String why) async {
        for (var i = 0; i < 300; i++) {
          await tester.pump();
          if (f.evaluate().isNotEmpty) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('timed out waiting for $why');
      }

      // First pick: 12 selected → capped to 9 → batch upload starts.
      await tester.tap(find.widgetWithText(TextButton, '图片'));
      await waitFor(
        find.byType(LinearProgressIndicator),
        'upload batch in flight',
      );
      expect(picker.calls, 1);

      // While the batch uploads the entry is disabled — the stale-count
      // window is closed.
      expect(attachBtnOf(tester, '图片').onPressed, isNull);

      // Release the batch; all 9 land as attachments (9 remove buttons).
      gate.complete();
      for (var i = 0; i < 400; i++) {
        await tester.pump();
        if (find.byIcon(Icons.cancel).evaluate().length == 9) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(find.byIcon(Icons.cancel), findsNWidgets(9));
      expect(uploadsServed, 9);

      // Uploads settled → entry re-enabled, but the cap (9) now blocks.
      // (Dismiss the earlier "已只添加前 9 张" snack first — a visible snack
      // overlays the bottom attach row and would swallow the tap.)
      expect(picker.calls, 1);
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
          .hideCurrentSnackBar();
      await tester.pump();
      await tester.tap(find.widgetWithText(TextButton, '图片'));
      await tester.pump();
      expect(find.text('最多 9 张图片'), findsOneWidget);
      expect(picker.calls, 1);
    });
  });

  testWidgets('media slot: a second pick mid-upload is blocked', (
    tester,
  ) async {
    final picker = _FakePicker([_file('voice.mp3')]);
    FilePicker.platform = picker;

    await tester.pumpWidget(buildApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.runAsync(() async {
      Future<void> waitFor(Finder f, String why) async {
        for (var i = 0; i < 300; i++) {
          await tester.pump();
          if (f.evaluate().isNotEmpty) return;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        fail('timed out waiting for $why');
      }

      await tester.tap(find.widgetWithText(TextButton, '音视频'));
      await waitFor(
        find.byType(LinearProgressIndicator),
        'audio upload in flight',
      );
      expect(picker.calls, 1);
      // Double-tap used to attach two media — the slot is now disabled.
      expect(attachBtnOf(tester, '音视频').onPressed, isNull);

      gate.complete();
      await waitFor(
        find.byIcon(Icons.music_note_rounded),
        'audio attachment thumbnail',
      );
      expect(find.byIcon(Icons.music_note_rounded), findsOneWidget);
      expect(picker.calls, 1);
    });
  });
}
