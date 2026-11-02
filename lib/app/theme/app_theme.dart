import 'package:flutter/material.dart';

import 'tokens.dart';

/// Собирает тему из токенов.
///
/// Правила: никаких теней и градиентов на карточках (границу рисует hairline),
/// крупный межстрочный интервал, малые капсы для служебных подписей.
abstract final class TachyonTheme {
  static ThemeData dark() => _build(Brightness.dark, TachyonTokens.dark);

  static ThemeData light() => _build(Brightness.light, TachyonTokens.light);

  static ThemeData _build(Brightness brightness, TachyonTokens t) {
    final scheme = ColorScheme.fromSeed(
      seedColor: t.accent,
      brightness: brightness,
      surface: t.surface,
    ).copyWith(
      primary: t.accent,
      onPrimary: brightness == Brightness.dark
          ? const Color(0xFF06131C)
          : Colors.white,
      surface: t.surface,
      onSurface: t.ink,
      error: t.danger,
      outline: t.line,
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: t.surface,
    );

    return base.copyWith(
      extensions: [t],
      focusColor: t.accent.withValues(alpha: 0.24),
      hoverColor: t.accent.withValues(alpha: 0.12),
      highlightColor: t.accent.withValues(alpha: 0.16),
      textTheme: _text(base.textTheme, t),
      dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: t.ink,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: t.ink,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: t.raised,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: t.line),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: t.muted,
        textColor: t.ink,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.xs,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? t.accent : t.faint,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? t.accentSoft : t.raised,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? t.accent : t.line,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.accent,
        linearTrackColor: t.line,
        circularTrackColor: t.line,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: t.raised,
        hintStyle: TextStyle(color: t.faint),
        labelStyle: TextStyle(color: t.muted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: t.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: t.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          borderSide: BorderSide(color: t.accent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: t.accent,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: t.ink,
          minimumSize: const Size(64, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          side: BorderSide(color: t.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.control),
          ),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: t.accent,
          textStyle: const TextStyle(fontWeight: FontWeight.w500),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: t.raised,
        contentTextStyle: TextStyle(color: t.ink),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: BorderSide(color: t.line),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: t.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.card),
          side: BorderSide(color: t.line),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: t.raised,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: t.line,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.card + 6),
          ),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: t.surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: t.accentSoft,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.control),
          side: BorderSide(color: t.accent.withValues(alpha: 0.25)),
        ),
        elevation: 0,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11.5,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? t.ink : t.muted,
            letterSpacing: 0,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 20,
            color: states.contains(WidgetState.selected) ? t.accent : t.muted,
          ),
        ),
      ),
    );
  }

  static TextTheme _text(TextTheme base, TachyonTokens t) {
    return base
        .copyWith(
          displaySmall: base.displaySmall?.copyWith(
            fontSize: 32,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.6,
            color: t.ink,
          ),
          headlineSmall: base.headlineSmall?.copyWith(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: t.ink,
          ),
          titleLarge: base.titleLarge?.copyWith(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: t.ink,
          ),
          titleMedium: base.titleMedium?.copyWith(
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
            color: t.ink,
          ),
          bodyLarge: base.bodyLarge?.copyWith(
            fontSize: 14.5,
            height: 1.45,
            color: t.ink,
          ),
          bodyMedium: base.bodyMedium?.copyWith(
            fontSize: 13,
            height: 1.45,
            color: t.muted,
          ),
          bodySmall: base.bodySmall?.copyWith(
            fontSize: 12,
            height: 1.4,
            color: t.faint,
          ),
          labelLarge: base.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            color: t.ink,
          ),
          labelSmall: base.labelSmall?.copyWith(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            color: t.muted,
          ),
        )
        .apply(bodyColor: t.ink, displayColor: t.ink);
  }
}
