// Widget test: the search field's X (Amethyst-style) one-tap clear — and
// clearing the keyword to empty stops the search + clears the results.

import 'package:costr/app/providers.dart';
import 'package:costr/features/search/search_page.dart';
import 'package:costr/models/event.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImmersiveOff extends ImmersiveBrowseNotifier {
  @override
  bool build() => false;
}

void main() {
  Widget buildPage() {
    return ProviderScope(
      overrides: [
        immersiveBrowseProvider.overrideWith(() => _ImmersiveOff()),
        searchUsersProvider.overrideWith(
          (ref, q) async* {
            yield const <UserResult>[];
          },
        ),
        searchPostsProvider.overrideWith(
          (ref, q) async* {
            yield const <Event>[];
          },
        ),
      ],
      child: const MaterialApp(home: SearchPage()),
    );
  }

  testWidgets('X clears the keyword and the results', (tester) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    // Idle state: hint, no X.
    expect(find.text('输入关键词搜索帖子与用户'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);

    // Type + submit → search runs (providers overridden to empty results).
    await tester.enterText(find.byType(TextField), '百度');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsOneWidget); // X appeared
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    // Body now shows the (empty) results, not the idle hint.
    expect(find.text('无帖子结果'), findsOneWidget);
    expect(find.text('输入关键词搜索帖子与用户'), findsNothing);

    // Tap X → keyword cleared → search stopped + results cleared.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('百度'), findsNothing);
    expect(find.text('无帖子结果'), findsNothing);
    expect(find.text('输入关键词搜索帖子与用户'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsNothing);
  });

  testWidgets('deleting the keyword to empty also clears the results', (
    tester,
  ) async {
    await tester.pumpWidget(buildPage());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '百度');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('无帖子结果'), findsOneWidget);

    // Manually delete all text (backspace to empty) → results clear too.
    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    expect(find.text('无帖子结果'), findsNothing);
    expect(find.text('输入关键词搜索帖子与用户'), findsOneWidget);
  });
}
