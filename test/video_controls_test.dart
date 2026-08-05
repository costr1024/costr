import 'package:costr/widgets/video_controls.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('clampSeek', () {
    const total = Duration(seconds: 100);
    test('steps inside the range', () {
      expect(
        clampSeek(const Duration(seconds: 50), 10, total),
        const Duration(seconds: 60),
      );
      expect(
        clampSeek(const Duration(seconds: 50), -10, total),
        const Duration(seconds: 40),
      );
    });

    test('clamps at both ends', () {
      expect(clampSeek(const Duration(seconds: 5), -10, total), Duration.zero);
      expect(clampSeek(const Duration(seconds: 95), 10, total), total);
    });
  });

  group('showSpeedPickerSheet', () {
    testWidgets('lists 6 speeds, checks the current one, returns tapped', (
      tester,
    ) async {
      double? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext ctx) => FilledButton(
                  onPressed: () async {
                    picked = await showSpeedPickerSheet(ctx, 1.0);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('播放速度'), findsOneWidget);
      for (final s in kPlaybackSpeeds) {
        expect(find.text('${s}x'), findsOneWidget);
      }
      // Current speed (1.0x) carries the check mark.
      expect(find.byIcon(Icons.check), findsOneWidget);

      await tester.tap(find.text('2.0x'));
      await tester.pumpAndSettle();
      expect(picked, 2.0);
    });

    testWidgets('dismiss without picking returns null', (tester) async {
      double? picked;
      var opened = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Builder(
                builder: (BuildContext ctx) => FilledButton(
                  onPressed: () async {
                    opened = true;
                    picked = await showSpeedPickerSheet(ctx, 1.0);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(opened, true);
      // Tap the scrim above the sheet to dismiss.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(picked, null);
    });
  });
}
