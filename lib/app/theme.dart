/// App theming — X-style light baseline + X-style dark (DESIGN.md §3.2).
///
/// Light: pure white bg + black primary (#0F1419). Dark: pure black bg +
/// near-white primary (#E7E9EA) — X's actual dark scheme. No Material3 purple.
///
/// All UI colors resolve through [CostrColors.of] so every call site adapts
/// to the active brightness. The historical static `CostrColors.xxx` consts
/// were removed on purpose: any leftover hard reference is a compile error,
/// so nothing can silently stay light-only again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

/// The resolved color palette for one brightness. Obtain via
/// [CostrColors.of] — never construct directly in widgets.
///
/// Token semantics:
/// - [bg]/[bg2]: page surface / secondary surface (chip & preview boxes).
/// - [border]: hairline dividers + outline borders.
/// - [text]/[text2]/[text3]: primary / secondary / tertiary foreground.
/// - [brand]: the accent. In light mode it is the near-black X primary used
///   BOTH as foreground (icons/links) and as a filled background; in dark
///   mode it inverts to near-white so both usages stay visible. Content drawn
///   ON a [brand] fill must use [onBrand] (never hardcode white).
class CostrPalette {
  const CostrPalette({
    required this.bg,
    required this.bg2,
    required this.border,
    required this.text,
    required this.text2,
    required this.text3,
    required this.brand,
    required this.onBrand,
    required this.red,
    required this.green,
    required this.blue,
    required this.warnBg,
    required this.warnBorder,
  });

  final Color bg;
  final Color bg2;
  final Color border;
  final Color text;
  final Color text2;
  final Color text3;
  final Color brand;
  final Color onBrand;
  final Color red;
  final Color green;
  final Color blue;

  /// Warning callout surfaces (login nsec reminder). Light: cream/amber;
  /// dark: dim amber so the box reads as a warning without glaring.
  final Color warnBg;
  final Color warnBorder;
}

/// Brightness-aware color access. `CostrColors.of(context)` returns the
/// palette matching [Theme.of]'s brightness.
class CostrColors {
  const CostrColors._();

  /// X light scheme (DESIGN.md §3.2 baseline).
  static const CostrPalette light = CostrPalette(
    bg: Color(0xFFFFFFFF),
    bg2: Color(0xFFF7F9F9),
    border: Color(0xFFEFF3F4),
    text: Color(0xFF0F1419),
    text2: Color(0xFF536471),
    text3: Color(0xFF71767B),
    brand: Color(0xFF0F1419),
    onBrand: Color(0xFFFFFFFF),
    red: Color(0xFFF4212E),
    green: Color(0xFF00BA7C),
    blue: Color(0xFF1D9BF0),
    warnBg: Color(0xFFFFF4E6),
    warnBorder: Color(0xFFFFD9A0),
  );

  /// X dark scheme (black bg, near-white primary, inverted brand).
  static const CostrPalette dark = CostrPalette(
    bg: Color(0xFF000000),
    bg2: Color(0xFF16181C),
    border: Color(0xFF2F3336),
    text: Color(0xFFE7E9EA),
    text2: Color(0xFF71767B),
    text3: Color(0xFF536471),
    brand: Color(0xFFE7E9EA),
    onBrand: Color(0xFF0F1419),
    red: Color(0xFFF4212E),
    green: Color(0xFF00BA7C),
    blue: Color(0xFF1D9BF0),
    warnBg: Color(0xFF3A2F14),
    warnBorder: Color(0xFF6E5A2E),
  );

  /// The palette for the ambient brightness of [context].
  static CostrPalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }
}

class AppTheme {
  /// Shared component themes, parameterized by [p] so light and dark stay
  /// structurally identical (a widget styled by the theme looks the same in
  /// both modes, only the palette differs).
  static ThemeData _build(CostrPalette p, Brightness brightness) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: p.bg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: p.brand,
        onPrimary: p.onBrand,
        secondary: p.text2,
        onSecondary: p.bg,
        surface: p.bg,
        onSurface: p.text,
        surfaceContainerHighest: p.bg2,
        error: p.red,
        onError: const Color(0xFFFFFFFF),
        outline: p.border,
        outlineVariant: p.border,
      ),
      visualDensity: VisualDensity.adaptivePlatformDensity,
      dividerColor: p.border,
      dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: p.bg,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: p.bg2,
        side: BorderSide(color: p.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: p.bg,
        foregroundColor: p.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.bg,
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 10, color: p.text),
        ),
        height: 64,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: p.brand, size: 26);
          }
          return IconThemeData(color: p.text3, size: 26);
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: p.brand,
          foregroundColor: p.onBrand,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.text2),
      ),
    );
  }

  static ThemeData light() => _build(CostrColors.light, Brightness.light);

  static ThemeData dark() => _build(CostrColors.dark, Brightness.dark);
}

/// Markdown body styling for post/about rendering.
///
/// The library default ([MarkdownStyleSheet.fromTheme]) paints blockquotes on
/// `Colors.blue.shade100` — a Material blue outside the X palette, so posts
/// quoting a headline with `> …` (e.g. 财新-style link posts) rendered as
/// glaring blue blocks. Blockquotes are restyled on-palette here: [CostrPalette.bg2]
/// fill + hairline left border, matching the app's quote-card look.
MarkdownStyleSheet costrMarkdownStyleSheet(BuildContext context) {
  final p = CostrColors.of(context);
  return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
    blockquoteDecoration: BoxDecoration(
      color: p.bg2,
      border: Border(left: BorderSide(color: p.border, width: 3)),
      borderRadius: BorderRadius.circular(8),
    ),
    blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  );
}
