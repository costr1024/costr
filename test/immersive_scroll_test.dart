// Tests for the immersive-browse scroll-direction logic
// ([immersiveBarActionFromPixels]). Pure function — no widget tree needed.

import 'package:costr/app/providers.dart';
import 'package:costr/widgets/immersive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const threshold = 40.0;
  const showThreshold = 20.0;
  // Convenience: a user ScrollUpdate (isUserUpdate: true).
  ImmersiveBarAction act(
    double pixels,
    double? scrollDelta, {
    double accumulated = 0,
  }) =>
      immersiveBarActionFromPixels(
        pixels: pixels,
        scrollDelta: scrollDelta,
        isUserUpdate: true,
        accumulated: accumulated,
        threshold: threshold,
        showThreshold: showThreshold,
      );

  test('at top (pixels <= 0) → show', () {
    expect(act(0, 50), ImmersiveBarAction.show);
    expect(act(-5, 50), ImmersiveBarAction.show);
  });

  test('programmatic scroll (null scrollDelta) → none (do not fight)', () {
    expect(
      immersiveBarActionFromPixels(
        pixels: 200,
        scrollDelta: null,
        isUserUpdate: true,
        accumulated: 0,
        threshold: threshold,
        showThreshold: showThreshold,
      ),
      ImmersiveBarAction.none,
    );
  });

  test('non-user update (isUserUpdate: false) → none', () {
    expect(
      immersiveBarActionFromPixels(
        pixels: 200,
        scrollDelta: 100,
        isUserUpdate: false,
        accumulated: 0,
        threshold: threshold,
        showThreshold: showThreshold,
      ),
      ImmersiveBarAction.none,
    );
  });

  test('small DOWN scroll below threshold → none (keep accumulating)', () {
    expect(act(200, 10, accumulated: 0), ImmersiveBarAction.none);
  });

  test('DOWN scroll accumulating past threshold → hide', () {
    // accumulated 30 + delta 20 = 50 >= 40 → hide
    expect(act(200, 20, accumulated: 30), ImmersiveBarAction.hide);
  });

  test('DOWN scroll that does NOT cross threshold → none', () {
    expect(act(200, 5, accumulated: 30), ImmersiveBarAction.none); // 35 < 40
  });

  test('a single large DOWN fling crosses threshold → hide', () {
    expect(act(200, 200, accumulated: 0), ImmersiveBarAction.hide);
  });

  // --- UP-scroll show hysteresis (the "时不时弹出菜单" fix) -----------------
  //
  // Real downward drags jitter: a single negative delta is finger noise, not
  // an intentional scroll-up. Showing on any negative delta made the chrome
  // pop back mid-browse. Now a NET up-scroll of showThreshold is required.

  test('a single tiny UP jitter → none (not an intentional scroll-up)', () {
    expect(act(200, -5, accumulated: 0), ImmersiveBarAction.none);
    expect(act(200, -1, accumulated: 0), ImmersiveBarAction.none);
    expect(act(200, -19, accumulated: 0), ImmersiveBarAction.none);
  });

  test('NET UP scroll reaching showThreshold → show', () {
    // accumulated -15 + delta -5 = -20 <= -20 → show
    expect(act(200, -5, accumulated: -15), ImmersiveBarAction.show);
    // a single firm upward drag
    expect(act(200, -60, accumulated: 0), ImmersiveBarAction.show);
  });

  test('jitter around zero never flips either way', () {
    // +5 then -5 net to 0 — neither hide nor show.
    expect(act(200, 5, accumulated: 0), ImmersiveBarAction.none);
    expect(act(200, -5, accumulated: 5), ImmersiveBarAction.none);
  });

  test('mixed DOWN drag with a jitter dip still hides on net', () {
    // 30 down, 8 up (jitter), then 25 more down → net 47 >= 40 → hide.
    var acc = 0.0;
    var action = act(200, 30, accumulated: acc);
    expect(action, ImmersiveBarAction.none);
    acc += 30;
    action = act(200, -8, accumulated: acc);
    expect(action, ImmersiveBarAction.none, reason: 'jitter dip, no show');
    acc += -8;
    action = act(200, 25, accumulated: acc);
    expect(action, ImmersiveBarAction.hide, reason: 'net down crosses 40');
  });

  group('immersiveIsCorrectivePullback', () {
    test('drag-less negative update → corrective', () {
      expect(
        immersiveIsCorrectivePullback(
          isScrollUpdate: true,
          dragDetails: null,
          scrollDelta: -42,
        ),
        isTrue,
      );
    });
    test('a real finger drag (dragDetails != null) is NEVER corrective', () {
      expect(
        immersiveIsCorrectivePullback(
          isScrollUpdate: true,
          dragDetails: DragUpdateDetails(globalPosition: Offset.zero),
          scrollDelta: -42,
        ),
        isFalse,
      );
    });
    test('positive or non-update → not corrective', () {
      expect(
        immersiveIsCorrectivePullback(
          isScrollUpdate: true,
          dragDetails: null,
          scrollDelta: 7,
        ),
        isFalse,
      );
      expect(
        immersiveIsCorrectivePullback(
          isScrollUpdate: false,
          dragDetails: null,
          scrollDelta: -7,
        ),
        isFalse,
      );
    });
  });

  testWidgets(
    'fast fling to the bottom during the chrome collapse does NOT re-show '
    'the bars',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [immersiveBrowseProvider.overrideWith(() => _On())],
          child: const MaterialApp(home: _FlickerHarness()),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ListView)),
      );
      expect(container.read(appBarsVisibleProvider), isTrue);

      // A hard, SHORT fling down the list (the 关注 pattern): the chrome
      // hides mid-drag, then the ballistic races the 220ms collapse and hits
      // the bottom while the viewport grows — Flutter pulls the offset back
      // with a corrective spring (negative drag-less deltas). Before the fix
      // that pull-back was misread as a user scroll-up and the bars popped
      // back. The small drag distance keeps the drag phase shorter than the
      // collapse so the two actually overlap.
      await tester.fling(find.byType(ListView), const Offset(0, -60), 8000);
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
      await tester.pumpAndSettle();

      expect(
        container.read(appBarsVisibleProvider),
        isFalse,
        reason: 'corrective pull-backs must not re-show the chrome during a '
            'fast DOWN scroll',
      );
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      expect(
        position.pixels,
        position.maxScrollExtent,
        reason: 'the fling landed at the bottom and stayed clamped there',
      );
    },
  );
}

class _On extends ImmersiveBrowseNotifier {
  @override
  bool build() => true;
}

/// Collapsing chrome + SHORT list — models ImmersiveScaffold + AppShell on
/// the 关注 tab (short feeds): when [appBarsVisibleProvider] flips false the
/// top box shrinks 150→0 over 220ms, which GROWS the list's viewport while a
/// hard fling's ballistic is still racing toward the (now closer) bottom —
/// the flicker trigger. 8×100px of content keeps the bottom close enough
/// that the ballistic reaches it DURING the collapse, exactly the reported
/// repro (long lists never hit the bottom mid-collapse, which is why only
/// 关注 flickered).
class _FlickerHarness extends ConsumerWidget {
  const _FlickerHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(appBarsVisibleProvider);
    return Scaffold(
      body: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            height: visible ? 150 : 0,
            color: Colors.blue,
          ),
          Expanded(
            child: ImmersiveScrollDetector(
              child: ListView.builder(
                itemExtent: 100,
                itemCount: 8,
                itemBuilder: (_, i) => Center(child: Text('row $i')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
