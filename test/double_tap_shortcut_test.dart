// DoubleTapShortcut: double-tap fires without competing with the wrapped
// children's own tap handling (a GestureDetector(onDoubleTap) wrapper would
// lose the gesture arena to the child's tap recognizer and never fire).
//
// Widget tests synthesize pointer events with zero timestamps, so the
// double-tap window is exercised through the injected test clock.

import 'package:costr/widgets/double_tap_shortcut.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(
  VoidCallback onDoubleTap,
  VoidCallback onChildTap,
  Duration Function() now,
) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: DoubleTapShortcut(
          onDoubleTap: onDoubleTap,
          now: now,
          child: SizedBox(
            height: 64,
            width: 300,
            child: ElevatedButton(
              onPressed: onChildTap,
              child: const Text('TAP'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> tap(WidgetTester tester, Offset at) async {
  final g = await tester.startGesture(at);
  await tester.pump(const Duration(milliseconds: 30));
  await g.up();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  testWidgets('single tap: child fires, shortcut does not', (tester) async {
    var fires = 0;
    var childTaps = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(
        _harness(() => fires++, () => childTaps++, () => clock));
    await tap(tester, tester.getCenter(find.byType(ElevatedButton)));
    await tester.pumpAndSettle();
    expect(childTaps, 1);
    expect(fires, 0);
  });

  testWidgets('double tap: shortcut fires once, child keeps both taps',
      (tester) async {
    var fires = 0;
    var childTaps = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(
        _harness(() => fires++, () => childTaps++, () => clock));
    final at = tester.getCenter(find.byType(ElevatedButton));
    await tap(tester, at);
    clock += const Duration(milliseconds: 120);
    await tap(tester, at);
    await tester.pumpAndSettle();
    expect(childTaps, 2, reason: 'children keep handling every tap');
    expect(fires, 1);
  });

  testWidgets('triple tap fires once (tap3 starts a fresh sequence)',
      (tester) async {
    var fires = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(_harness(() => fires++, () {}, () => clock));
    final at = tester.getCenter(find.byType(ElevatedButton));
    for (var i = 0; i < 3; i++) {
      await tap(tester, at);
      clock += const Duration(milliseconds: 120);
    }
    await tester.pumpAndSettle();
    expect(fires, 1);
  });

  testWidgets('two slow taps (> 300ms apart) do not fire', (tester) async {
    var fires = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(_harness(() => fires++, () {}, () => clock));
    final at = tester.getCenter(find.byType(ElevatedButton));
    await tap(tester, at);
    clock += const Duration(milliseconds: 400);
    await tap(tester, at);
    await tester.pumpAndSettle();
    expect(fires, 0);
  });

  testWidgets('two far-apart taps do not fire', (tester) async {
    var fires = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(_harness(() => fires++, () {}, () => clock));
    final c = tester.getCenter(find.byType(ElevatedButton));
    await tap(tester, c - const Offset(140, 0));
    clock += const Duration(milliseconds: 100);
    await tap(tester, c + const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(fires, 0);
  });

  testWidgets('a drag (down + move + up) leaves no tap candidate',
      (tester) async {
    var fires = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(_harness(() => fires++, () {}, () => clock));
    final c = tester.getCenter(find.byType(ElevatedButton));
    // Drag away (> touch slop), then tap the same spot twice.
    final g = await tester.startGesture(c);
    await g.moveBy(const Offset(0, 60));
    await tester.pump(const Duration(milliseconds: 30));
    await g.up();
    await tester.pump(const Duration(milliseconds: 60));
    clock += const Duration(milliseconds: 100);
    await tap(tester, c);
    await tester.pumpAndSettle();
    expect(fires, 0, reason: 'drag + single tap is not a double tap');
  });

  testWidgets('onDoubleTapAt reports the second tap-down position',
      (tester) async {
    final positions = <Offset>[];
    var clock = Duration.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DoubleTapShortcut(
              onDoubleTapAt: positions.add,
              now: () => clock,
              child: const SizedBox(height: 64, width: 300),
            ),
          ),
        ),
      ),
    );
    final shortcutTopLeft = tester.getTopLeft(find.byType(DoubleTapShortcut));
    final first = tester.getCenter(find.byType(DoubleTapShortcut));
    await tap(tester, first);
    clock += const Duration(milliseconds: 100);
    // Second tap slightly off — the callback must carry the SECOND tap's
    // position (the first tap may have hit a different target within the
    // 100px double-tap slop).
    final second = first + const Offset(20, 4);
    await tap(tester, second);
    await tester.pumpAndSettle();
    expect(positions, hasLength(1));
    expect(positions.single, second - shortcutTopLeft);
  });

  testWidgets('onDoubleTapAt-only shortcut fires; child keeps both taps',
      (tester) async {
    var fires = 0;
    var childTaps = 0;
    var clock = Duration.zero;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: DoubleTapShortcut(
              onDoubleTapAt: (_) => fires++,
              now: () => clock,
              child: SizedBox(
                height: 64,
                width: 300,
                child: ElevatedButton(
                  onPressed: () => childTaps++,
                  child: const Text('TAP'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(ElevatedButton));
    await tap(tester, at);
    clock += const Duration(milliseconds: 120);
    await tap(tester, at);
    await tester.pumpAndSettle();
    expect(childTaps, 2);
    expect(fires, 1);
  });

  test('constructing without any callback asserts', () {
    expect(
      () => DoubleTapShortcut(child: const SizedBox()),
      throwsAssertionError,
    );
  });
}
