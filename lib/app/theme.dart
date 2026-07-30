/// App theming — X-style light baseline (DESIGN.md §3.2).
///
/// Pure white bg + black primary (#0F1419). No Material3 purple.
library;

import 'package:flutter/material.dart';

/// X-style color constants (DESIGN.md §3.2).
class CostrColors {
  const CostrColors._();
  static const Color bg = Color(0xFFFFFFFF);
  static const Color bg2 = Color(0xFFF7F9F9);
  static const Color border = Color(0xFFEFF3F4);
  static const Color text = Color(0xFF0F1419);
  static const Color text2 = Color(0xFF536471);
  static const Color text3 = Color(0xFF71767B);
  static const Color brand = Color(0xFF0F1419);
  static const Color red = Color(0xFFF4212E);
  static const Color green = Color(0xFF00BA7C);
  static const Color blue = Color(0xFF1D9BF0);
}

class AppTheme {
  static ThemeData light() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: CostrColors.bg,
      colorScheme: const ColorScheme.light(
        primary: CostrColors.brand,
        onPrimary: CostrColors.bg,
        secondary: CostrColors.text2,
        onSecondary: CostrColors.bg,
        surface: CostrColors.bg,
        onSurface: CostrColors.text,
        surfaceContainerHighest: CostrColors.bg2,
        error: CostrColors.red,
        onError: CostrColors.bg,
        outline: CostrColors.border,
        outlineVariant: CostrColors.border,
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: CostrColors.border,
      dividerTheme: const DividerThemeData(
        color: CostrColors.border,
        thickness: 1,
        space: 1,
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: CostrColors.bg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: CostrColors.bg2,
        side: const BorderSide(color: CostrColors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: CostrColors.bg,
        foregroundColor: CostrColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: CostrColors.text,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: CostrColors.bg,
        indicatorColor: Colors.transparent,
        labelTextStyle: const WidgetStatePropertyAll(
          TextStyle(fontSize: 10, color: CostrColors.text),
        ),
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: CostrColors.brand, size: 26);
          }
          return const IconThemeData(color: CostrColors.text3, size: 26);
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: CostrColors.brand,
          foregroundColor: CostrColors.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: CostrColors.text2),
      ),
    );
  }

  static ThemeData dark() {
    // X-style dark theme (future; DESIGN.md says "先做好浅色" but we keep a basic dark).
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}
