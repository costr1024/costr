// Smoke test: the app boots and the feed page renders its title.

import 'package:flutter_test/flutter_test.dart';

import 'package:costr/app/app.dart';

void main() {
  testWidgets('App boots and shows feed title', (WidgetTester tester) async {
    await tester.pumpWidget(const AppRoot());
    await tester.pumpAndSettle();

    expect(find.text('costr'), findsWidgets);
    expect(find.text('Compose'), findsOneWidget);
  });
}
