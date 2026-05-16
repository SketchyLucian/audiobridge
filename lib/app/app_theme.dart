import 'package:flutter/material.dart';

class AppTheme {
  static const _primary = Color(0xFF006C67);
  static const _secondary = Color(0xFFB8563C);
  static const _tertiary = Color(0xFF7A6A1F);
  static const _lightBackground = Color(0xFFF5F7F4);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _darkBackground = Color(0xFF151817);
  static const _darkSurface = Color(0xFF202423);

  static ThemeData light() {
    return _theme(
      ColorScheme.fromSeed(
        seedColor: _primary,
        brightness: Brightness.light,
      ).copyWith(
        primary: _primary,
        secondary: _secondary,
        tertiary: _tertiary,
        surface: _lightSurface,
      ),
      _lightBackground,
    );
  }

  static ThemeData dark() {
    return _theme(
      ColorScheme.fromSeed(
        seedColor: _primary,
        brightness: Brightness.dark,
      ).copyWith(
        primary: const Color(0xFF46D1C8),
        secondary: const Color(0xFFFFB09A),
        tertiary: const Color(0xFFE3D270),
        surface: _darkSurface,
      ),
      _darkBackground,
    );
  }

  static ThemeData _theme(ColorScheme scheme, Color background) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
    );

    final textTheme = _zeroLetterSpacing(base.textTheme);
    final roundedShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );

    return base.copyWith(
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: background,
        foregroundColor: scheme.onSurface,
        titleTextStyle: textTheme.titleLarge?.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surface,
        margin: EdgeInsets.zero,
        shape: roundedShape,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(roundedShape),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(roundedShape),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(roundedShape),
          visualDensity: VisualDensity.compact,
        ),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
        activeTrackColor: scheme.primary,
      ),
    );
  }

  static TextTheme _zeroLetterSpacing(TextTheme theme) {
    return theme.copyWith(
      displayLarge: theme.displayLarge?.copyWith(letterSpacing: 0),
      displayMedium: theme.displayMedium?.copyWith(letterSpacing: 0),
      displaySmall: theme.displaySmall?.copyWith(letterSpacing: 0),
      headlineLarge: theme.headlineLarge?.copyWith(letterSpacing: 0),
      headlineMedium: theme.headlineMedium?.copyWith(letterSpacing: 0),
      headlineSmall: theme.headlineSmall?.copyWith(letterSpacing: 0),
      titleLarge: theme.titleLarge?.copyWith(letterSpacing: 0),
      titleMedium: theme.titleMedium?.copyWith(letterSpacing: 0),
      titleSmall: theme.titleSmall?.copyWith(letterSpacing: 0),
      bodyLarge: theme.bodyLarge?.copyWith(letterSpacing: 0),
      bodyMedium: theme.bodyMedium?.copyWith(letterSpacing: 0),
      bodySmall: theme.bodySmall?.copyWith(letterSpacing: 0),
      labelLarge: theme.labelLarge?.copyWith(letterSpacing: 0),
      labelMedium: theme.labelMedium?.copyWith(letterSpacing: 0),
      labelSmall: theme.labelSmall?.copyWith(letterSpacing: 0),
    );
  }
}
