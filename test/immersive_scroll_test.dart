// Tests for the immersive-browse scroll-direction logic
// ([immersiveBarActionFromPixels]). Pure function — no widget tree needed.

import 'package:costr/widgets/immersive.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const threshold = 40.0;
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
      );

  test('at top (pixels <= 0) → show', () {
    expect(act(0, 50), ImmersiveBarAction.show);
    expect(act(-5, 50), ImmersiveBarAction.show);
  });

  test('user UP scroll → show immediately (no threshold)', () {
    expect(act(200, -5), ImmersiveBarAction.show);
    expect(act(200, -1), ImmersiveBarAction.show);
  });

  test('programmatic scroll (null scrollDelta) → none (do not fight)', () {
    expect(
      immersiveBarActionFromPixels(
        pixels: 200,
        scrollDelta: null,
        isUserUpdate: true,
        accumulated: 0,
        threshold: threshold,
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
}
