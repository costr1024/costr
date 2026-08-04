// Regression test: the page tab row (belowBar) collapses together with the
// AppBar when immersive browse hides the chrome on scroll-down, and returns
// on scroll-up ("全球/关注、全部/提及 tab 不会隐藏" bug).

import 'package:costr/app/providers.dart';
import 'package:costr/widgets/immersive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _AlwaysOn extends ImmersiveBrowseNotifier {
  @override
  bool build() => true;
}

const _tabsKey = Key('tabs');

void main() {
  testWidgets('belowBar hides on scroll-down, returns on scroll-up', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [immersiveBrowseProvider.overrideWith(() => _AlwaysOn())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ImmersiveScaffold(
            topBar: AppBar(title: const Text('T')),
            belowBarHeight: 64,
            belowBar: const SizedBox(
              height: 64,
              child: Center(child: Text('TABS', key: _tabsKey)),
            ),
            body: ImmersiveScrollDetector(
              child: ListView(
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Visible at rest: the collapsible bar window is fully expanded
    // (kToolbarHeight 56 + belowBarHeight 64).
    double barHeight() =>
        tester.getSize(find.byType(AnimatedContainer).first).height;
    expect(barHeight(), 120);

    // Scroll DOWN past the 40px threshold → chrome (incl. the tab row)
    // collapses to the (zero) status-bar strip and clips away.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(container.read(appBarsVisibleProvider), isFalse);
    expect(barHeight(), 0);

    // Scroll UP → chrome restored, bar window back to full height.
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(container.read(appBarsVisibleProvider), isTrue);
    expect(barHeight(), 120);
  });
}
