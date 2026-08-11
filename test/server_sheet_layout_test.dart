// Regression: the customize sheet's action row (恢复默认 | 取消 | 保存) must
// sit directly under the add field, ABOVE the count caption and the
// recommendations block — not at the very bottom of the sheet under the reco
// list (the old position forced scrolling past the recommendations after
// adding a server). All four server categories share this one sheet, so the
// indexer category stands in for all of them here (it has no recommendation
// block — discoverySupported(indexer) is false — which keeps the test free
// of network probing and pending FutureBuilder timers).

import 'package:costr/app/providers.dart';
import 'package:costr/app/server_list_rules.dart';
import 'package:costr/features/settings/server_list_sheet.dart';
import 'package:costr/nostr/identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _NullId extends IdentityNotifier {
  @override
  Future<Identity?> build() async => null;
}

class _Launcher extends ConsumerWidget {
  const _Launcher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          onPressed: () => showServerListSheet(
            context: context,
            ref: ref,
            category: ServerCategory.indexer,
          ),
          child: const Text('open sheet'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('恢复默认 | 取消 | 保存 row sits under 添加, above the caption', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          identityProvider.overrideWith(() => _NullId()),
          serverListsProvider.overrideWith(
            (ref) async => const ServerLists(
              relays: ['wss://relay.example/'],
              search: ['wss://search.example/'],
              indexer: ['wss://indexer.example/'],
              blossom: ['https://blossom.example/'],
            ),
          ),
        ],
        child: const MaterialApp(home: _Launcher()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open sheet'));
    await tester.pumpAndSettle();

    // Exactly ONE of each action button (the old bottom-row copy must be
    // gone — there is a single action row now).
    final saveBtn = find.widgetWithText(FilledButton, '保存');
    expect(saveBtn, findsOneWidget);
    final addBtn = find.widgetWithText(FilledButton, '添加');
    expect(addBtn, findsOneWidget);
    final restoreBtn = find.widgetWithText(TextButton, '恢复默认');
    final cancelBtn = find.widgetWithText(TextButton, '取消');
    expect(restoreBtn, findsOneWidget);
    expect(cancelBtn, findsOneWidget);

    // ONE shared row: 恢复默认 | 取消 | 保存 left-to-right, same height.
    final restoreTL = tester.getTopLeft(restoreBtn);
    final cancelTL = tester.getTopLeft(cancelBtn);
    final saveTL = tester.getTopLeft(saveBtn);
    expect(restoreTL.dy, closeTo(saveTL.dy, 1));
    expect(cancelTL.dy, closeTo(saveTL.dy, 1));
    expect(restoreTL.dx, lessThan(cancelTL.dx));
    expect(cancelTL.dx, lessThan(saveTL.dx));

    // The row sits UNDER the add field, and ABOVE the count caption (which
    // in turn sits above the recommendation block in the categories that
    // have one).
    final addTop = tester.getTopLeft(addBtn).dy;
    final captionTop = tester.getTopLeft(find.textContaining('最多')).dy;
    expect(saveTL.dy, greaterThan(addTop));
    expect(saveTL.dy, lessThan(captionTop));
  });
}
