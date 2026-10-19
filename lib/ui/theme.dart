/// The app's visual language: Persian, right-to-left, warm.
///
/// ## Why the palette is what it is
///
/// The default Material purple reads as a generic template. This app is about
/// food and money, and the colour carries meaning:
///
///   * A warm **amber** primary — appetite, warmth, meals.
///   * A deep **teal** secondary — money and calm, distinct from the food
///     colour so a balance never looks like a meal.
///   * Semantic colours: green for held, red for released, orange for a slot
///     closing.
///
/// Contrast was checked for WCAG AA on the light scheme; the dark scheme is
/// derived from the same hues rather than a separate design.
library;

import 'package:flutter/material.dart';

/// The app's colour scheme.
class AppColors {
  const AppColors._();

  /// Primary: a warm amber, for actions and headers.
  static const Color primary = Color(0xFFB45309);

  /// Primary container, for chips and selected states.
  static const Color primaryContainer = Color(0xFFFEF3C7);

  /// Secondary: a deep teal, for money and information.
  static const Color secondary = Color(0xFF0F766E);

  static const Color secondaryContainer = Color(0xFFCCFBF1);

  /// A meal the student holds.
  static const Color held = Color(0xFF15803D);

  /// A meal that was released or given up.
  static const Color released = Color(0xFFB91C1C);

  /// Something closing or expiring.
  static const Color closing = Color(0xFFEA580C);
}

/// Text and background colours for the light scheme.
const Color _lightSurface = Color(0xFFFDFCFA);
const Color _lightBackground = Color(0xFFF7F4EF);

/// Builds the app's light theme.
ThemeData buildLightTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.light,
  ).copyWith(
    primary: AppColors.primary,
    primaryContainer: AppColors.primaryContainer,
    secondary: AppColors.secondary,
    secondaryContainer: AppColors.secondaryContainer,
    surface: _lightSurface,
  );

  return _base(scheme).copyWith(
    scaffoldBackgroundColor: _lightBackground,
  );
}

/// Builds the app's dark theme.
ThemeData buildDarkTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.primary,
    brightness: Brightness.dark,
  ).copyWith(
    primary: const Color(0xFFF59E0B),
    primaryContainer: const Color(0xFF78350F),
    secondary: const Color(0xFF2DD4BF),
    secondaryContainer: const Color(0xFF134E4A),
  );

  return _base(scheme);
}

/// The parts of the theme shared by both schemes.
ThemeData _base(ColorScheme scheme) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: 'Vazirmatn',
    // Persian needs a little more line height than the Latin default, and the
    // descenders in Arabic script are deep.
    textTheme: _persianTextTheme(scheme),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 2,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: 0.5),
      space: 1,
      thickness: 1,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? scheme.primary
            : scheme.outline,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primaryContainer,
      elevation: 2,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontFamily: 'Vazirmatn',
          fontSize: 12,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? scheme.onSurface
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      labelStyle: const TextStyle(fontFamily: 'Vazirmatn', fontSize: 13),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      contentTextStyle: const TextStyle(fontFamily: 'Vazirmatn'),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      titleTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      contentTextStyle: TextStyle(
        fontFamily: 'Vazirmatn',
        fontSize: 14,
        height: 1.7,
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}

/// The text theme, with Persian-appropriate line heights.
TextTheme _persianTextTheme(ColorScheme scheme) {
  final base = ThemeData.light().textTheme;
  TextStyle style(TextStyle? s, {double? height}) => (s ?? const TextStyle())
      .copyWith(
        fontFamily: 'Vazirmatn',
        height: height ?? 1.6,
        color: scheme.onSurface,
      );

  return TextTheme(
    displaySmall: style(base.displaySmall, height: 1.4),
    headlineMedium: style(base.headlineMedium, height: 1.4),
    headlineSmall: style(base.headlineSmall, height: 1.4),
    titleLarge: style(base.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
    titleMedium: style(base.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
    titleSmall: style(base.titleSmall?.copyWith(fontWeight: FontWeight.w500)),
    bodyLarge: style(base.bodyLarge),
    bodyMedium: style(base.bodyMedium),
    bodySmall: style(base.bodySmall, height: 1.5),
    labelLarge: style(base.labelLarge?.copyWith(fontWeight: FontWeight.w600)),
    labelMedium: style(base.labelMedium),
    labelSmall: style(base.labelSmall),
  );
}
