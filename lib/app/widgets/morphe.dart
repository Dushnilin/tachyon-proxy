import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Заголовок раздела: спокойный sentence-case и hairline-линия справа.
///
/// Так разделы выглядят одинаково на всех экранах и не спорят с содержимым.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              color: tokens.muted,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(child: Divider(color: tokens.line, height: 1)),
          if (trailing != null) ...[
            const SizedBox(width: Space.md),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Карточка с hairline-границей: без тени, без заливки-градиента,
/// с поддержкой подсветки фокуса для пульта Android TV (D-pad).
class HairlineCard extends StatefulWidget {
  const HairlineCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  State<HairlineCard> createState() => _HairlineCardState();
}

class _HairlineCardState extends State<HairlineCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final content = Padding(padding: widget.padding, child: widget.child);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(
          color: _focused ? tokens.accent : tokens.line,
          width: _focused ? 1.8 : 1.0,
        ),
      ),
      child: widget.onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                onFocusChange: (f) {
                  if (_focused != f) setState(() => _focused = f);
                },
                focusColor: tokens.accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(Radii.card),
                child: content,
              ),
            ),
    );
  }
}

/// Технический бейдж (тег): строгий радиус 6px, табличные цифры.
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.color,
    this.filled = false,
    this.icon,
  });

  final String label;
  final Color? color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tone = color ?? tokens.muted;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon == null ? Space.sm : Space.sm - 1,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: filled ? tone.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.tag),
        border: Border.all(
          color: tone.withValues(alpha: filled ? 0.28 : 0.36),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
                color: tone,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка «подпись — значение» с разделителем.
class DetailRow extends StatelessWidget {
  const DetailRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: valueColor ?? tokens.ink,
                fontFamily: monospace ? 'monospace' : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Разделитель-волосок, совпадающий с границей карточки.
class Hairline extends StatelessWidget {
  const Hairline({super.key, this.indent = 0});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: indent),
      child: Divider(color: context.tokens.line, height: 1, thickness: 1),
    );
  }
}

/// Строгий геометрический знак Tachyon без неонового размытия.
class TachyonBoltIcon extends StatelessWidget {
  const TachyonBoltIcon({
    super.key,
    this.size = 24,
    this.primaryColor,
    this.secondaryColor,
    this.glow = false,
  });

  final double size;
  final Color? primaryColor;
  final Color? secondaryColor;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TachyonBoltPainter(
          primary: primaryColor ?? tokens.ink,
          secondary: secondaryColor ?? tokens.accent,
        ),
      ),
    );
  }
}

class _TachyonBoltPainter extends CustomPainter {
  _TachyonBoltPainter({
    required this.primary,
    required this.secondary,
  });

  final Color primary;
  final Color secondary;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final p0 = Offset(w * 0.575, h * 0.10);
    final p1 = Offset(w * 0.220, h * 0.545);
    final p2 = Offset(w * 0.468, h * 0.545);
    final p3 = Offset(w * 0.425, h * 0.90);
    final p4 = Offset(w * 0.780, h * 0.455);
    final p5 = Offset(w * 0.532, h * 0.455);

    final fullBolt = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p3.dx, p3.dy)
      ..lineTo(p4.dx, p4.dy)
      ..lineTo(p5.dx, p5.dy)
      ..close();

    final leftFacet = Path()
      ..moveTo(p0.dx, p0.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p5.dx, p5.dy)
      ..close();

    canvas.drawPath(fullBolt, Paint()..color = secondary);
    canvas.drawPath(leftFacet, Paint()..color = primary);
  }

  @override
  bool shouldRepaint(covariant _TachyonBoltPainter old) =>
      old.primary != primary || old.secondary != secondary;
}

/// Заголовок приложения в приборном стиле без разрежённого капслока.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: tokens.raised,
            borderRadius: BorderRadius.circular(Radii.tag),
            border: Border.all(color: tokens.line),
          ),
          alignment: Alignment.center,
          child: TachyonBoltIcon(
            size: 16,
            primaryColor: tokens.ink,
            secondaryColor: tokens.accent,
          ),
        ),
        const SizedBox(width: Space.sm + 2),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Tachyon',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                height: 1.15,
                color: tokens.ink,
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0,
                  color: tokens.muted,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Пустое состояние: короткий текст и, если есть, действие.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 30, color: tokens.faint),
            const SizedBox(height: Space.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (description != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: Space.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Нажимаемый и фокусируемый (для пульта Android TV / D-pad) контейнер
/// с визуальной подсветкой активного фокуса.
class FocusableTap extends StatefulWidget {
  const FocusableTap({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius,
    this.focusBorderColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final Color? focusBorderColor;

  @override
  State<FocusableTap> createState() => _FocusableTapState();
}

class _FocusableTapState extends State<FocusableTap> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = widget.borderRadius ?? BorderRadius.circular(Radii.tag);
    final borderColor = widget.focusBorderColor ?? tokens.accent;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (f) {
          if (_focused != f) setState(() => _focused = f);
        },
        borderRadius: radius,
        focusColor: borderColor.withValues(alpha: 0.18),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: _focused
              ? BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(color: borderColor, width: 1.8),
                )
              : const BoxDecoration(),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Переключатель-строка в стиле списка настроек (полностью фокусируемая для Android TV / D-pad).
class SwitchRow extends StatefulWidget {
  const SwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<SwitchRow> createState() => _SwitchRowState();
}

class _SwitchRowState extends State<SwitchRow> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final radius = BorderRadius.circular(Radii.control);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onChanged(!widget.value),
        onFocusChange: (f) {
          if (_focused != f) setState(() => _focused = f);
        },
        borderRadius: radius,
        focusColor: tokens.accent.withValues(alpha: 0.14),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.xs,
            vertical: Space.xs,
          ),
          decoration: _focused
              ? BoxDecoration(
                  borderRadius: radius,
                  border: Border.all(
                    color: tokens.accent.withValues(alpha: 0.75),
                    width: 1.4,
                  ),
                )
              : null,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: Theme.of(context).textTheme.bodyLarge),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitle!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              ExcludeFocus(
                child: Switch(
                  value: widget.value,
                  onChanged: widget.onChanged,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Статистика в виде сетки: чистая цифра с табличным выравниванием и спокойная подпись (без лишних иконок).
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.color,
    this.icon,
  });

  final String label;
  final String value;
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tone = color ?? tokens.ink;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w400,
            color: tokens.muted,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.3,
            color: tone,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
