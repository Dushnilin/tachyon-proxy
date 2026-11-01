import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Заголовок раздела: мелкие капсы и hairline-линия справа.
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
          Text(text.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
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

/// Карточка с hairline-границей: без тени, без заливки-градиента.
class HairlineCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final content = Padding(padding: padding, child: child);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.raised,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: tokens.line),
      ),
      child: onTap == null
          ? content
          : Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(Radii.card),
                child: content,
              ),
            ),
    );
  }
}

/// Небольшой бейдж: серая подложка, мелкий текст.
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
        horizontal: icon == null ? Space.sm + 2 : Space.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: filled ? tone.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: tone.withValues(alpha: filled ? 0.32 : 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: tone,
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
                fontSize: 13.5,
                height: 1.4,
                color: valueColor ?? tokens.ink,
                fontFamily: monospace ? 'monospace' : null,
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

/// Центрированный логотип приложения: разрежённые капитель и точка-акцент.
class Wordmark extends StatelessWidget {
  const Wordmark({super.key, this.subtitle});

  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: tokens.accent,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: Space.sm + 2),
            Text(
              'TACHYON',
              style: TextStyle(
                fontSize: 19,
                fontWeight: FontWeight.w600,
                letterSpacing: 4.5,
                color: tokens.ink,
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: Space.xs),
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 1.4,
              color: tokens.faint,
            ),
          ),
        ],
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

/// Переключатель-строка в стиле списка настроек.
class SwitchRow extends StatelessWidget {
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
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.bodyLarge),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// Статистика в виде сетки: крупное число и подпись под ним.
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
        if (icon != null) ...[
          Icon(icon, size: 15, color: tone),
          const SizedBox(height: Space.sm),
        ],
        Text(
          value,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: tone,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
