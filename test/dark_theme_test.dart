// Regression tests for the dark-mode theme system.
//
// Before this refactor, dark mode was broken: AppTheme.dark() was an empty
// stub (Material widgets fell back to M3 default purple) and ~107 call sites
// hardcoded light CostrColors consts, so they never adapted to the ambient
// brightness. The fix makes every color resolve through CostrColors.of(context)
// and gives dark a real X-style palette with an inverted brand.

import 'package:costr/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CostrColors palette', () {
    test('light and dark palettes expose the same token set', () {
      // Sanity: both palettes are fully specified (no nulls) and differ on the
      // surface/text tokens but keep the semantic accents identical.
      expect(CostrColors.light.red, CostrColors.dark.red);
      expect(CostrColors.light.green, CostrColors.dark.green);
      expect(CostrColors.light.blue, CostrColors.dark.blue);
      // The surfaces must actually differ (white bg vs black bg).
      expect(CostrColors.light.bg, isNot(CostrColors.dark.bg));
      expect(CostrColors.light.text, isNot(CostrColors.dark.text));
    });

    test('dark brand is inverted (light) with a dark onBrand', () {
      // brand doubles as foreground AND fill; in dark mode it inverts to a
      // light value so both usages stay visible, and content drawn on a brand
      // fill uses the dark onBrand (never hardcoded white).
      expect(CostrColors.dark.brand.computeLuminance(), greaterThan(0.5));
      expect(CostrColors.dark.onBrand.computeLuminance(), lessThan(0.2));
      expect(CostrColors.light.brand.computeLuminance(), lessThan(0.2));
      expect(CostrColors.light.onBrand.computeLuminance(), greaterThan(0.5));
    });
  });

  group('AppTheme.dark()', () {
    test('is a real dark theme, not the M3-default stub', () {
      final dark = AppTheme.dark();
      expect(dark.brightness, Brightness.dark);
      // X-style black scaffold, not the M3 dark grey.
      expect(dark.scaffoldBackgroundColor, CostrColors.dark.bg);
      // Primary is the inverted (light) brand — NOT the M3 default purple.
      expect(dark.colorScheme.primary, CostrColors.dark.brand);
      expect(dark.colorScheme.onPrimary, CostrColors.dark.onBrand);
      // Component themes present (card/appbar/nav/filledButton all themed).
      expect(dark.cardTheme.color, CostrColors.dark.bg);
      expect(dark.appBarTheme.backgroundColor, CostrColors.dark.bg);
      expect(dark.navigationBarTheme.backgroundColor, CostrColors.dark.bg);
    });

    test('light theme is unchanged (X white baseline)', () {
      final light = AppTheme.light();
      expect(light.brightness, Brightness.light);
      expect(light.scaffoldBackgroundColor, CostrColors.light.bg);
      expect(light.colorScheme.primary, CostrColors.light.brand);
    });
  });

  group('CostrColors.of(context)', () {
    Future<CostrPalette> resolvePalette(WidgetTester tester, ThemeMode mode)
    async {
      late CostrPalette resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: mode,
          home: Builder(
            builder: (context) {
              resolved = CostrColors.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return resolved;
    }

    testWidgets('resolves the light palette in light mode', (tester) async {
      final p = await resolvePalette(tester, ThemeMode.light);
      expect(p.bg, CostrColors.light.bg);
      expect(p.text, CostrColors.light.text);
      expect(p.brand, CostrColors.light.brand);
    });

    testWidgets('resolves the dark palette in dark mode', (tester) async {
      final p = await resolvePalette(tester, ThemeMode.dark);
      expect(p.bg, CostrColors.dark.bg);
      expect(p.text, CostrColors.dark.text);
      expect(p.brand, CostrColors.dark.brand);
      // The whole point: surfaces are dark, not white.
      expect(p.bg, isNot(CostrColors.light.bg));
    });
  });
}
