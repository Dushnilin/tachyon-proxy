import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../core/models/app_rules.dart';
import '../../core/services/core_bridge.dart';

/// Экран приложений: раздельное туннелирование по приложениям с иконками и шаблонами.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen> {
  List<InstalledApp> _allApps = const [];
  bool _loading = true;
  bool _showSystem = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final controller = AppScope.read(context);
    final apps = await controller.installedApps();
    if (!mounted) return;
    setState(() {
      _allApps = apps;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final mode = controller.settings.appsMode;
    final selected = controller.settings.appPackages.toSet();
    final appRoutes = controller.settings.appRoutes;

    final filtered = _allApps.where((app) {
      final hasRule = appRoutes.containsKey(app.packageName) ||
          selected.contains(app.packageName);
      if (!_showSystem && app.system && !hasRule) return false;
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return app.label.toLowerCase().contains(q) ||
          app.packageName.toLowerCase().contains(q);
    }).toList();

    // Закрепляем приложения с настроенными правилами вверху списка
    filtered.sort((a, b) {
      final ra = appRoutes.containsKey(a.packageName) ? 0 : 1;
      final rb = appRoutes.containsKey(b.packageName) ? 0 : 1;
      if (ra != rb) return ra.compareTo(rb);
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Приложения'),
            if (appRoutes.isNotEmpty) ...[
              const SizedBox(width: Space.sm),
              Pill(
                label: '${appRoutes.length}',
                color: tokens.accent,
                filled: true,
              ),
            ],
          ],
        ),
        actions: [
          FilterChip(
            label: const Text('Системные', style: TextStyle(fontSize: 11.5)),
            selected: _showSystem,
            onSelected: (v) => setState(() => _showSystem = v),
          ),
          const SizedBox(width: Space.md),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  onChanged: (value) => setState(() => _query = value.trim()),
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Поиск по названию или пакету...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: Space.sm),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ActionChip(
                        avatar: Icon(Icons.account_balance_outlined,
                            size: 15, color: tokens.warning),
                        label: const Text('Банки и РФ → Напрямую',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () async {
                          final n = await controller.applyAppPreset(
                            'ru_direct',
                            _allApps,
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Направлено напрямую российских приложений: $n'),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 6),
                      ActionChip(
                        avatar: Icon(Icons.bolt_outlined,
                            size: 15, color: const Color(0xFFFF8C00)),
                        label: const Text('YouTube / Discord → DPI',
                            style: TextStyle(fontSize: 11.5)),
                        onPressed: () async {
                          final n = await controller.applyAppPreset(
                            'yt_discord_desync',
                            _allApps,
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content:
                                  Text('Переведено в DPI-обход приложений: $n'),
                            ),
                          );
                        },
                      ),
                      if (appRoutes.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        ActionChip(
                          avatar: Icon(Icons.clear_all,
                              size: 15, color: tokens.danger),
                          label: const Text('Сбросить',
                              style: TextStyle(fontSize: 11.5)),
                          onPressed: () =>
                              controller.applyAppPreset('clear', _allApps),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.lg),
            child: HairlineCard(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.xs,
              ),
              child: Row(
                children: [
                  Text('Глобальный фильтр:',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<AppsMode>(
                        value: mode,
                        isDense: true,
                        isExpanded: true,
                        items: [
                          for (final option in AppsMode.values)
                            DropdownMenuItem(
                              value: option,
                              child: Text(option.label,
                                  style: const TextStyle(fontSize: 13)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) controller.setAppsMode(value);
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.sm),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.apps_outlined,
                        title: 'Приложения не найдены',
                        description:
                            'Попробуйте изменить поисковый запрос или включить показ системных пакетов.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          0,
                          Space.lg,
                          Space.xxl,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final app = filtered[index];
                          return _AppTile(
                            app: app,
                            bridge: controller.bridge,
                            selected: selected.contains(app.packageName),
                            route: appRoutes[app.packageName],
                            onToggle: () => controller.toggleApp(app.packageName),
                            onRoute: (outbound) =>
                                controller.setAppRoute(app.packageName, outbound),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

/// Асинхронная иконка приложения с кэшем в памяти.
class _AppIcon extends StatefulWidget {
  const _AppIcon({
    required this.packageName,
    required this.label,
    required this.bridge,
    required this.tint,
  });

  final String packageName;
  final String label;
  final CoreBridge bridge;
  final Color tint;

  static final Map<String, Uint8List?> _cache = {};

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  @override
  void didUpdateWidget(covariant _AppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName != widget.packageName) {
      _loadIcon();
    }
  }

  Future<void> _loadIcon() async {
    if (_AppIcon._cache.containsKey(widget.packageName)) {
      _bytes = _AppIcon._cache[widget.packageName];
      return;
    }
    final data = await widget.bridge.appIcon(widget.packageName);
    _AppIcon._cache[widget.packageName] = data;
    if (mounted) {
      setState(() => _bytes = data);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    if (_bytes != null && _bytes!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.memory(
          _bytes!,
          width: 34,
          height: 34,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
      );
    }
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: widget.tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tokens.line),
      ),
      alignment: Alignment.center,
      child: Text(
        widget.label.isEmpty ? '?' : widget.label.characters.first.toUpperCase(),
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: widget.tint,
        ),
      ),
    );
  }
}

/// Плитка приложения с 4-сегментным роутером.
class _AppTile extends StatelessWidget {
  const _AppTile({
    required this.app,
    required this.bridge,
    required this.selected,
    required this.onToggle,
    required this.onRoute,
    this.route,
  });

  final InstalledApp app;
  final CoreBridge bridge;
  final bool selected;
  final String? route;
  final VoidCallback onToggle;
  final void Function(String outbound) onRoute;

  static const _routes = ['proxy', 'direct', 'desync', 'block'];
  static const _labels = {
    'proxy': 'Прокси',
    'direct': 'Напрямую',
    'desync': 'DPI-обход',
    'block': 'Блок',
  };
  static const _icons = {
    'proxy': Icons.vpn_key_outlined,
    'direct': Icons.straighten,
    'desync': Icons.shield_outlined,
    'block': Icons.block,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final current = route;

    Color routeColor(String r) => switch (r) {
          'proxy' => tokens.accent,
          'direct' => tokens.warning,
          'desync' => const Color(0xFFFF8C00),
          'block' => tokens.danger,
          _ => tokens.muted,
        };

    return Padding(
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: HairlineCard(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.sm, Space.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _AppIcon(
                  packageName: app.packageName,
                  label: app.label,
                  bridge: bridge,
                  tint: current != null ? routeColor(current) : tokens.muted,
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        app.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Text(
                        app.packageName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                          color: tokens.faint,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current != null)
                  IconButton(
                    icon: Icon(Icons.close, size: 16, color: tokens.faint),
                    tooltip: 'Убрать правило',
                    onPressed: () => onRoute(''),
                  ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                for (final r in _routes)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _RouteChip(
                        label: _labels[r]!,
                        icon: _icons[r]!,
                        active: current == r,
                        color: routeColor(r),
                        onTap: () => onRoute(current == r ? '' : r),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Компактная кнопка-чип выбора маршрута.
class _RouteChip extends StatelessWidget {
  const _RouteChip({
    required this.label,
    required this.icon,
    required this.active,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.5) : context.tokens.line,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? color : context.tokens.faint,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 9,
                fontWeight: active ? FontWeight.w700 : FontWeight.w400,
                color: active ? color : context.tokens.faint,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
