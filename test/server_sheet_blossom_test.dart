// Widget tests for the Blossom extras in the customize sheet
// (features/settings/server_list_sheet.dart): drag-reorderable rows, the
// one-click speed test (button, per-row results, editing lock), the
// logged-out degradation, and the "results die with the sheet" guarantee.
// All network is mocked via the sheet's debugSpeedClient hook — no real
// requests, no drift (Map-backed LocalCache stub).
import 'dart:async';
import 'dart:convert';

import 'package:costr/app/providers.dart';
import 'package:costr/app/server_list_rules.dart';
import 'package:costr/features/settings/server_list_sheet.dart';
import 'package:costr/nostr/identity.dart';
import 'package:costr/nostr/relay_pool.dart';
import 'package:costr/services/local_cache.dart' as cache;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _priv =
    '0000000000000000000000000000000000000000000000000000000000000001';
final Identity _identity = Identity.fromPrivkeyHex(_priv);

const _blossomA = 'https://a.example';
const _blossomB = 'https://b.example';

// --- Fakes ------------------------------------------------------------------

class _FixedId extends IdentityNotifier {
  _FixedId(this.id);
  final Identity id;
  @override
  Future<Identity?> build() async => id;
}

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

/// Map-backed LocalCache stub (drift scheduling wedges in the FakeAsync
/// zone — same pattern as server_lists_provider_test.dart).
class _MapCache implements cache.LocalCache {
  final Map<String, String> kv = {};

  @override
  Future<String?> readConfig(String key) async => kv[key];

  @override
  Future<void> writeConfig(String key, String value) async => kv[key] = value;

  @override
  Future<void> deleteConfig(String key) async => kv.remove(key);

  @override
  Future<List<String>?> readServerList(String key) async {
    final raw = kv[key];
    if (raw == null || raw.isEmpty) return null;
    try {
      final list = jsonDecode(raw);
      if (list is List) return list.whereType<String>().toList();
    } catch (_) {}
    return null;
  }

  @override
  Future<void> writeServerList(String key, List<String> urls) async =>
      kv[key] = jsonEncode(urls);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// All-green speed-test responder: PUT /upload → Blossom descriptor JSON,
/// GET (download) → bytes, DELETE (cleanup) → 200.
MockClient _greenClient() => MockClient((req) async {
  if (req.method == 'PUT') {
    final sha = req.headers['X-SHA-256'];
    return http.Response(
      jsonEncode({'url': 'https://${req.url.host}/$sha.mp4'}),
      200,
    );
  }
  if (req.method == 'GET') {
    return http.Response.bytes(List<int>.filled(1024, 7), 200);
  }
  return http.Response('', 200); // DELETE cleanup
});

/// Mimics the real entry point: the 服务器节点 page loads the server lists
/// BEFORE the user can open the customize sheet, so `serverListsProvider` is
/// always resolved by then. Here we pre-warm the same providers and only
/// reveal the open button once they are, keeping the test honest.
class _Launcher extends ConsumerStatefulWidget {
  const _Launcher(this.category, {this.speedClient});

  final ServerCategory category;
  final http.Client? speedClient;

  @override
  ConsumerState<_Launcher> createState() => _LauncherState();
}

class _LauncherState extends ConsumerState<_Launcher> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    () async {
      await ref.read(serverListsProvider.future);
      await ref.read(identityProvider.future);
      if (mounted) setState(() => _ready = true);
    }();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: _ready
            ? FilledButton(
                onPressed: () => showServerListSheet(
                  context: context,
                  ref: ref,
                  category: widget.category,
                  debugSpeedClient: widget.speedClient,
                ),
                child: const Text('open sheet'),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}

Future<_MapCache> _pumpAndOpen(
  WidgetTester tester, {
  required ServerCategory category,
  required IdentityNotifier identity,
  http.Client? speedClient,
  List<String> blossom = const [_blossomA, _blossomB],
}) async {
  final db = _MapCache();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        identityProvider.overrideWith(() => identity),
        serverListsProvider.overrideWith(
          (ref) async => ServerLists(
            relays: const ['wss://relay.example/'],
            search: const ['wss://search.example/'],
            indexer: const ['wss://indexer.example/'],
            blossom: blossom,
          ),
        ),
        localCacheProvider.overrideWith((ref) async => db),
        relayPoolProvider.overrideWith((ref) => RelayPool(const [])),
        searchPoolProvider.overrideWith((ref) => RelayPool(const [])),
        indexerPoolProvider.overrideWith((ref) => RelayPool(const [])),
        bootstrapProvider.overrideWith((ref) async {}),
      ],
      child: MaterialApp(home: _Launcher(category, speedClient: speedClient)),
    ),
  );
  // _Launcher reveals the open button only once the server lists + identity
  // are loaded (mirroring the real 服务器节点 → 自定义 flow).
  await tester.pumpAndSettle();
  await tester.tap(find.text('open sheet'));
  await tester.pumpAndSettle();
  return db;
}

// ---------------------------------------------------------------------------

void main() {
  testWidgets(
    'blossom sheet: drag handles + 测速 button + updated warning copy',
    (tester) async {
      await _pumpAndOpen(
        tester,
        category: ServerCategory.blossom,
        identity: _FixedId(_identity),
        speedClient: _greenClient(),
      );

      // One drag handle per blossom row.
      expect(find.byIcon(Icons.drag_handle), findsNWidgets(2));
      // The 测速 button exists (idle label).
      expect(find.widgetWithText(TextButton, '测速'), findsOneWidget);
      // Warning copy explains both new capabilities in plain words.
      expect(find.textContaining('拖动调整顺序'), findsOneWidget);
      expect(find.textContaining('把快的放前面'), findsOneWidget);
    },
  );

  testWidgets('other categories keep plain rows: no handles, no 测速', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      category: ServerCategory.relay,
      identity: _FixedId(_identity),
    );
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.widgetWithText(TextButton, '测速'), findsNothing);
    expect(find.byIcon(Icons.speed), findsNothing);
  });

  testWidgets('logged out: 测速 disabled, hint mentions speed test', (
    tester,
  ) async {
    await _pumpAndOpen(
      tester,
      category: ServerCategory.blossom,
      identity: _NullId(),
      speedClient: _greenClient(),
    );
    final btn = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '测速'),
    );
    expect(btn.onPressed, isNull);
    expect(find.textContaining('也能一键测速'), findsOneWidget);
  });

  testWidgets('speed test: per-row results, cleared on reopen', (tester) async {
    await _pumpAndOpen(
      tester,
      category: ServerCategory.blossom,
      identity: _FixedId(_identity),
      speedClient: _greenClient(),
    );

    await tester.tap(find.widgetWithText(TextButton, '测速'));
    await tester.pumpAndSettle();

    // Both servers measured → two result lines with both directions
    // (strict pattern: the warning copy also mentions 上传/下载).
    expect(
      find.textContaining(RegExp(r'上传 \d+\.\d+ MB/s · 下载 \d+\.\d+ MB/s')),
      findsNWidgets(2),
    );
    expect(find.text('测速失败'), findsNothing);

    // Close the sheet → reopen → the results are gone (never persisted).
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();
    expect(find.textContaining('MB/s'), findsNothing);
  });

  testWidgets('speed test failure renders 测速失败 per server', (tester) async {
    await _pumpAndOpen(
      tester,
      category: ServerCategory.blossom,
      identity: _FixedId(_identity),
      speedClient: MockClient((req) async => http.Response('', 500)),
    );
    await tester.tap(find.widgetWithText(TextButton, '测速'));
    await tester.pumpAndSettle();
    expect(find.text('测速失败'), findsNWidgets(2));
  });

  testWidgets('drag reorder persists on 保存 in the new order', (tester) async {
    final db = await _pumpAndOpen(
      tester,
      category: ServerCategory.blossom,
      identity: _FixedId(_identity),
      speedClient: _greenClient(),
    );

    // Drag the FIRST row's handle down past the second row — a slow timed
    // drag, matching how a finger moves (a fast flick is not picked up by the
    // reorder gesture recognizer).
    await tester.timedDrag(
      find.byIcon(Icons.drag_handle).first,
      const Offset(0, 80),
      const Duration(milliseconds: 500),
    );
    await tester.pumpAndSettle();

    // Save and check the persisted order flipped.
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(await db.readServerList('blossom_list'), [_blossomB, _blossomA]);
  });

  testWidgets('while a speed test runs, editing is locked, 取消 aborts', (
    tester,
  ) async {
    final gate = Completer<http.Response>();
    final hanging = MockClient((req) => gate.future);
    await _pumpAndOpen(
      tester,
      category: ServerCategory.blossom,
      identity: _FixedId(_identity),
      speedClient: hanging,
    );

    await tester.tap(find.widgetWithText(TextButton, '测速'));
    await tester.pump(); // let the run start (button flips to 测速中 1/2)

    // Progress label + editing lock.
    expect(find.textContaining('测速中'), findsOneWidget);
    expect(find.text('正在测速…（上传 10 MB 测试文件）'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '恢复默认'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '添加'))
          .onPressed,
      isNull,
    );
    // 取消 stays enabled — it is the abort escape hatch.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed,
      isNotNull,
    );

    // Escape: close the sheet mid-test.
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(find.text('open sheet'), findsOneWidget); // sheet dismissed

    // Unlike a real http.Client, MockClient.close() does NOT cancel the
    // in-flight request, so the hanging PUT (and its 30s .timeout timer)
    // would stay pending and fail the test. Complete the gate so the future
    // resolves, the timeout timer cancels, and the run bails on the
    // ctx.mounted guard.
    gate.complete(http.Response('', 500));
    await tester.pumpAndSettle();
  });
}
