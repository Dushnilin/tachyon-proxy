import 'package:flutter/material.dart';

/// Цветовые и размерные токены интерфейса.
///
/// Взяты из визуального языка Morphe: почти монохромная основа, тонкие
/// hairline-границы, один сдержанный акцент и много воздуха. Цвет несёт
/// смысл только в состоянии туннеля — всё остальное нейтральное.
class TachyonTokens extends ThemeExtension<TachyonTokens> {
  const TachyonTokens({
    required this.ink,
    required this.muted,
    required this.faint,
    required this.line,
    required this.surface,
    required this.raised,
    required this.accent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
  });

  /// Основной текст.
  final Color ink;

  /// Второстепенный текст.
  final Color muted;

  /// Подписи и единицы измерения.
  final Color faint;

  /// Hairline-разделитель.
  final Color line;

  /// Фон экрана.
  final Color surface;

  /// Фон карточки.
  final Color raised;

  /// Единственный акцент.
  final Color accent;
  final Color accentSoft;

  final Color success;
  final Color warning;
  final Color danger;

  static const dark = TachyonTokens(
    ink: Color(0xFFF2F2F3),
    muted: Color(0xFFA8A8AD),
    faint: Color(0xFF70707A),
    line: Color(0xFF26262B),
    surface: Color(0xFF0B0B0D),
    raised: Color(0xFF141417),
    accent: Color(0xFFB9A8FF),
    accentSoft: Color(0xFF2A2440),
    success: Color(0xFF6FD08C),
    warning: Color(0xFFE5C07B),
    danger: Color(0xFFE06C75),
  );

  static const light = TachyonTokens(
    ink: Color(0xFF131316),
    muted: Color(0xFF5A5A62),
    faint: Color(0xFF8A8A93),
    line: Color(0xFFE4E4E7),
    surface: Color(0xFFFAFAFA),
    raised: Color(0xFFFFFFFF),
    accent: Color(0xFF5B47C7),
    accentSoft: Color(0xFFEDEAFF),
    success: Color(0xFF2E7D4F),
    warning: Color(0xFF9A6B00),
    danger: Color(0xFFB3261E),
  );

  @override
  TachyonTokens copyWith({
    Color? ink,
    Color? muted,
    Color? faint,
    Color? line,
    Color? surface,
    Color? raised,
    Color? accent,
    Color? accentSoft,
    Color? success,
    Color? warning,
    Color? danger,
  }) {
    return TachyonTokens(
      ink: ink ?? this.ink,
      muted: muted ?? this.muted,
      faint: faint ?? this.faint,
      line: line ?? this.line,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
    );
  }

  @override
  TachyonTokens lerp(TachyonTokens? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return TachyonTokens(
      ink: mix(ink, other.ink),
      muted: mix(muted, other.muted),
      faint: mix(faint, other.faint),
      line: mix(line, other.line),
      surface: mix(surface, other.surface),
      raised: mix(raised, other.raised),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      success: mix(success, other.success),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
    );
  }
}

/// Шаг сетки отступов.
abstract final class Space {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 20.0;
  static const xl = 28.0;
  static const xxl = 40.0;
}

/// Радиусы скруглений.
abstract final class Radii {
  static const card = 18.0;
  static const control = 14.0;
  static const pill = 999.0;
}

/// Доступ к токенам без длинного `Theme.of(context).extension!`.
extension TachyonTokensContext on BuildContext {
  TachyonTokens get tokens =>
      Theme.of(this).extension<TachyonTokens>() ?? TachyonTokens.dark;
}
