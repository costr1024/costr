// Smoke test for the outbox/inbox explainer diagram: it must render without
// layout overflow at a narrow (phone) width, in both light and dark themes,
// and expose the key concepts (发件箱/收件箱 + the two flows).
import 'package:costr/app/theme.dart';
import 'package:costr/widgets/outbox_inbox_diagram.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pump(WidgetTester tester, ThemeData theme) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: OutboxInboxDiagram(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders the two flows without overflow (light)', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester, AppTheme.light());
    expect(find.text('发件箱 与 收件箱'), findsOneWidget);
    expect(find.textContaining('去对方的发件箱取'), findsOneWidget);
    expect(find.textContaining('写进你的收件箱'), findsOneWidget);
    expect(find.textContaining('NIP-65 read'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders without overflow (dark)', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await _pump(tester, AppTheme.dark());
    expect(find.text('发件箱 与 收件箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
