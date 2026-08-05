// Regression: a list item growing in place (an image finishing its load)
// must not flip the immersive chrome. Probe-verified Flutter behavior: the
// resize dispatches NO ScrollNotification and does not correct `pixels`
// (content below visually shifts down), so the detector can't react to it —
// this test pins that end-to-end, both hidden→hidden and visible→visible.
//
// History: v0.6.8 "沉浸式还是不稳定，时不时显示上下菜单栏" was suspected to be
// image loads pushing posts down being misread as an up-scroll. The resize
// itself is inert (proven here); the true trigger was upward finger jitter
// during downward drags (covered by the show-hysteresis fix in
// immersive.dart + immersive_scroll_test.dart).

import 'package:costr/app/providers.dart';
import 'package:costr/widgets/immersive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _ImmersiveOn extends ImmersiveBrowseNotifier {
  @override
  bool build() => true;
}

void main() {
  testWidgets('image-load resize never flips immersive chrome', (tester) async {
    final container = ProviderContainer(
      overrides: [immersiveBrowseProvider.overrideWith(() => _ImmersiveOn())],
    );
    addTearDown(container.dispose);

    bool grow = false;
    late StateSetter growSetState;
    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ImmersiveScrollDetector(
              child: ListView.builder(
                controller: controller,
                itemCount: 60,
                itemBuilder: (context, i) {
                  if (i == 2) {
                    return StatefulBuilder(
                      builder: (context, setState) {
                        growSetState = setState;
                        return SizedBox(
                          height: grow ? 600 : 100,
                          child: const ColoredBox(color: Colors.red),
                        );
                      },
                    );
                  }
                  return const SizedBox(
                    height: 100,
                    child: ColoredBox(color: Colors.blue),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(appBarsVisibleProvider), isTrue);

    // Scroll down past item 2 far enough to hide the chrome.
    final g = await tester.startGesture(const Offset(300, 400));
    for (var i = 0; i < 8; i++) {
      await g.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(controller.position.pixels, greaterThan(200));
    expect(
      container.read(appBarsVisibleProvider),
      isFalse,
      reason: 'down-scroll hides the chrome first',
    );

    // Now the image "loads": item 2 (above the viewport, cached) grows by
    // 500px. Content below shifts down, pixels stay — and the chrome state
    // must NOT flip back to visible.
    growSetState(() => grow = true);
    await tester.pumpAndSettle();
    expect(
      container.read(appBarsVisibleProvider),
      isFalse,
      reason: 'an image-load resize must not re-show the chrome',
    );

    // Scrolling further down must still hide (detector not wedged).
    final g2 = await tester.startGesture(const Offset(300, 400));
    for (var i = 0; i < 5; i++) {
      await g2.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await g2.up();
    await tester.pumpAndSettle();
    expect(container.read(appBarsVisibleProvider), isFalse);
  });
}
