import 'package:flutter/material.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';

/// Экран правил: режим маршрутизации, свои правила и списки из каталога.
class RulesTab extends StatefulWidget {
  const RulesTab({super.key});

  @override
  State<RulesTab> createState() => _RulesTabState();
}

class _RulesTabState extends State<RulesTab> {
  String _listQuery = '';
  bool _onlyEnabledLists = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = AppScope.read(context);
      if (controller.settings.ruleSets.isEmpty) {
        controller.refreshLists();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final sets = controller.settings.ruleSets;
    final customRules = controller.settings.customRules;

    final filteredSets = sets.where((s) {
      if (_onlyEnabledLists && !s.enabled) return false;
      final q = _listQuery.trim().toLowerCase();
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) || s.id.toLowerCase().contains(q);
    }).toList();

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Правила'),
        actions: [
          IconButton(
            tooltip: 'Добавить своё правило',
            onPressed: () => _showAddCustomRuleDialog(context, controller),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Обновить каталог',
            onPressed: () => controller.refreshLists(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.lg,
          Space.sm,
          Space.lg,
          Space.xxl,
        ),
        children: [
          const SectionLabel('Режим работы'),
          _ModeSelector(controller: controller),
          if (controller.settings.profiles.length > 1) ...[
            const SizedBox(height: Space.md),
            _DetourChainCard(controller: controller),
          ],
          const SizedBox(height: Space.xl),
          SectionLabel(
            'Пользовательские правила',
            trailing: TextButton.icon(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              onPressed: () => _showAddCustomRuleDialog(context, controller),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Добавить'),
            ),
          ),
          _CustomRulesSection(
            controller: controller,
            rules: customRules,
            onAdd: () => _showAddCustomRuleDialog(context, controller),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Точечно по сервисам'),
          _ServiceRoutesSection(controller: controller),
          const SizedBox(height: Space.xl),
          const SectionLabel('Настройка обхода DPI (Desync)'),
          _DesyncModeCard(controller: controller),
          const SizedBox(height: Space.xl),
          SectionLabel(
            'Каталог списков (tachyon-lists)',
            trailing: sets.isEmpty
                ? null
                : Text(
                    '${sets.where((set) => set.enabled).length} из ${sets.length}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
          ),
          if (sets.isNotEmpty) ...[
            Row(
              children: [
                Expanded(
                  child: TextField(
                    onChanged: (v) => setState(() => _listQuery = v),
                    decoration: const InputDecoration(
                      hintText: 'Поиск по спискам...',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: Space.sm),
                FilterChip(
                  label: const Text('Активные'),
                  selected: _onlyEnabledLists,
                  onSelected: (v) => setState(() => _onlyEnabledLists = v),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
          ],
          if (sets.isEmpty)
            HairlineCard(
              padding: const EdgeInsets.all(Space.md),
              child: Row(
                children: [
                  Icon(Icons.rule_folder_outlined, size: 20, color: tokens.muted),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      'Дополнительные региональные и доменные списки (.trs)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  FilledButton(
                    onPressed: () => controller.refreshLists(),
                    child: const Text('Загрузить'),
                  ),
                ],
              ),
            )
          else
            _RuleSetList(controller: controller, sets: filteredSets),
        ],
      ),
    );
  }

  Future<void> _showAddCustomRuleDialog(
    BuildContext context,
    AppController controller,
  ) async {
    var ruleType = 'domain_suffix';
    var action = 'proxy';
    final valueCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setStateLocal) => AlertDialog(
          title: const Text('Новое правило'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: ruleType,
                  decoration: const InputDecoration(labelText: 'Тип совпадения'),
                  items: const [
                    DropdownMenuItem(
                      value: 'domain_suffix',
                      child: Text('Домен и поддомены (domain_suffix)'),
                    ),
                    DropdownMenuItem(
                      value: 'domain',
                      child: Text('Точный домен (domain)'),
                    ),
                    DropdownMenuItem(
                      value: 'domain_keyword',
                      child: Text('Ключевое слово в домене (keyword)'),
                    ),
                    DropdownMenuItem(
                      value: 'ip_cidr',
                      child: Text('IP / Подсеть (CIDR)'),
                    ),
                  ],
                  onChanged: (v) => setStateLocal(() => ruleType = v ?? ruleType),
                ),
                const SizedBox(height: Space.md),
                TextField(
                  controller: valueCtrl,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: ruleType == 'ip_cidr' ? 'IP или CIDR' : 'Домен / слово',
                    hintText: ruleType == 'ip_cidr' ? '1.1.1.1/32' : 'example.com',
                  ),
                ),
                const SizedBox(height: Space.md),
                DropdownButtonFormField<String>(
                  initialValue: action,
                  decoration: const InputDecoration(labelText: 'Действие'),
                  items: const [
                    DropdownMenuItem(value: 'proxy', child: Text('Через прокси (VPN)')),
                    DropdownMenuItem(
                      value: 'desync',
                      child: Text('Через DPI-обход (Desync)'),
                    ),
                    DropdownMenuItem(
                      value: 'direct',
                      child: Text('Напрямую (в обход VPN)'),
                    ),
                    DropdownMenuItem(value: 'block', child: Text('Блокировать')),
                  ],
                  onChanged: (v) => setStateLocal(() => action = v ?? action),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () async {
                var val = valueCtrl.text.trim();
                if (val.isEmpty) return;
                if (ruleType == 'ip_cidr' && !val.contains('/')) {
                  val = '$val/32';
                }
                Navigator.pop(dialogCtx);
                await controller.addCustomRule(
                  CustomRule(
                    id: 'cr-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
                    type: ruleType,
                    value: val,
                    action: action,
                  ),
                );
              },
              child: const Text('Добавить'),
            ),
          ],
        ),
      ),
    );
    valueCtrl.dispose();
  }
}

class _CustomRulesSection extends StatelessWidget {
  const _CustomRulesSection({
    required this.controller,
    required this.rules,
    required this.onAdd,
  });

  final AppController controller;
  final List<CustomRule> rules;
  final VoidCallback onAdd;

  static const _actions = ['proxy', 'direct', 'desync', 'block'];
  static const _labels = {
    'proxy': 'ТУННЕЛЬ',
    'direct': 'НАПРЯМУЮ',
    'desync': 'ОБХОД DPI',
    'block': 'БЛОК',
  };
  static const _typeLabels = {
    'domain_suffix': 'Суффикс домена',
    'domain': 'Точный домен',
    'domain_keyword': 'Ключевое слово',
    'ip_cidr': 'IP / Подсеть',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    if (rules.isEmpty) {
      return HairlineCard(
        onTap: onAdd,
        padding: const EdgeInsets.all(Space.md),
        child: Row(
          children: [
            Icon(Icons.add_circle_outline, size: 18, color: tokens.accent),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                'Добавьте свои домены или IP-адреса для точечной маршрутизации',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        for (final r in rules) ...[
          HairlineCard(
            padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.xs),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        r.value,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                          color: tokens.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _typeLabels[r.type] ?? r.type,
                        style: TextStyle(fontSize: 11, color: tokens.faint),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    final idx = _actions.indexOf(r.action);
                    final next = _actions[(idx + 1) % _actions.length];
                    controller.setCustomRuleAction(r.id, next);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _colorFor(tokens, r.action).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: _colorFor(tokens, r.action).withValues(alpha: 0.45),
                      ),
                    ),
                    child: Text(
                      _labels[r.action] ?? 'ТУННЕЛЬ',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: _colorFor(tokens, r.action),
                      ),
                    ),
                  ),
                ),
                Switch(
                  value: r.enabled,
                  onChanged: (_) => controller.toggleCustomRule(r.id),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Удалить правило',
                  onPressed: () => controller.removeCustomRule(r.id),
                  icon: Icon(Icons.close, size: 18, color: tokens.faint),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xs),
        ],
      ],
    );
  }

  Color _colorFor(TachyonTokens tokens, String action) => switch (action) {
        'direct' => tokens.success,
        'desync' => tokens.warning,
        'block' => tokens.danger,
        _ => tokens.accent,
      };
}

/// Точечный выбор маршрута для популярных сервисов (включая привязку к конкретному серверу).
class _ServiceRoutesSection extends StatelessWidget {
  const _ServiceRoutesSection({required this.controller});

  final AppController controller;

  static const _options = <(String, String)>[
    ('off', 'По умолч.'),
    ('desync', 'DPI (Desync)'),
    ('proxy', 'Прокси'),
    ('direct', 'Напрямую'),
    ('block', 'Блок'),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final routes = controller.settings.serviceRoutes;
    final profiles = controller.settings.profiles;

    return Column(
      children: [
        for (final service in BuiltInService.catalog) ...[
          Builder(
            builder: (context) {
              final currentRoute = routes[service.id] ?? 'off';
              final isCustomServer = currentRoute.startsWith('profile:');
              final pinnedProfileId =
                  isCustomServer ? currentRoute.substring('profile:'.length) : '';
              final pinnedProfile = isCustomServer
                  ? profiles.where((p) => p.id == pinnedProfileId).firstOrNull
                  : null;

              return HairlineCard(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            service.title,
                            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                        ),
                        if (profiles.isNotEmpty && service.id != 'ru')
                          GestureDetector(
                            onTap: () => _pickServerForService(
                              context,
                              service,
                              pinnedProfileId,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isCustomServer
                                    ? tokens.accent.withValues(alpha: 0.16)
                                    : tokens.raised,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isCustomServer ? tokens.accent : tokens.line,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.dns_outlined,
                                    size: 12,
                                    color: isCustomServer ? tokens.accent : tokens.muted,
                                  ),
                                  const SizedBox(width: 4),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 130),
                                    child: Text(
                                      pinnedProfile?.name ?? 'Свой сервер...',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: isCustomServer
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color:
                                            isCustomServer ? tokens.accent : tokens.muted,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      service.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontSize: 11.5,
                            color: tokens.faint,
                          ),
                    ),
                    const SizedBox(height: Space.sm),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final (value, label) in _options)
                          _buildChip(
                            context,
                            label: label,
                            value: value,
                            selected: currentRoute == value,
                            onTap: () => controller.setServiceRoute(service.id, value),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }

  Future<void> _pickServerForService(
    BuildContext context,
    BuiltInService service,
    String currentProfileId,
  ) async {
    final profiles = controller.sortProfiles(controller.settings.profiles);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          children: [
            Text(
              'Выделенный сервер для ${service.title}',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Трафик ${service.title} пойдёт через выбранный сервер независимо от основного профиля.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            ListTile(
              dense: true,
              leading: const Icon(Icons.layers_clear_outlined),
              title: const Text('Использовать общий прокси (по умолчанию)'),
              selected: currentProfileId.isEmpty,
              onTap: () {
                Navigator.pop(ctx);
                controller.setServiceRoute(service.id, 'proxy');
              },
            ),
            const Hairline(),
            for (final p in profiles)
              ListTile(
                dense: true,
                leading: Icon(
                  p.id == currentProfileId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${p.fullTransportLabel} · ${p.server}:${p.port}'),
                selected: p.id == currentProfileId,
                onTap: () {
                  Navigator.pop(ctx);
                  controller.setServiceRoute(service.id, 'profile:${p.id}');
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(
    BuildContext context, {
    required String label,
    required String value,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final tokens = context.tokens;
    final Color activeColor = switch (value) {
      'desync' => tokens.warning,
      'proxy' => tokens.accent,
      'direct' => tokens.success,
      'block' => tokens.danger,
      _ => tokens.muted,
    };

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? activeColor.withValues(alpha: 0.16) : tokens.raised,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? activeColor : tokens.line,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? activeColor : tokens.muted,
          ),
        ),
      ),
    );
  }
}

/// Переключатель режима маршрутизации.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final mode = controller.settings.routingMode;

    return HairlineCard(
      padding: const EdgeInsets.all(Space.sm),
      child: Row(
        children: [
          for (final option in RoutingMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => controller.setRoutingMode(option),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(vertical: Space.md),
                  decoration: BoxDecoration(
                    color: mode == option ? tokens.accentSoft : Colors.transparent,
                    borderRadius: BorderRadius.circular(Radii.control),
                    border: Border.all(
                      color: mode == option ? tokens.accent : Colors.transparent,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(
                        option.label,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: mode == option ? tokens.ink : tokens.muted,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Список правил, сгруппированный по назначению.
class _RuleSetList extends StatelessWidget {
  const _RuleSetList({required this.controller, required this.sets});

  final AppController controller;
  final List<RuleSetEntry> sets;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<RuleSetEntry>>{};
    for (final set in sets) {
      groups.putIfAbsent(_groupOf(set.id), () => []).add(set);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in groups.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.sm, bottom: Space.sm),
            child: Text(
              group.key,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          for (final set in group.value) ...[
            _RuleSetTile(controller: controller, set: set),
            const SizedBox(height: Space.sm),
          ],
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }

  String _groupOf(String id) {
    const names = <String, String>{
      'ai': 'ИИ-сервисы',
      'block': 'Блокировки',
      'direct': 'Напрямую',
      'gaming': 'Игры',
      'infra': 'Инфраструктура',
      'internal': 'Внутренние',
      'media': 'Медиа',
      'other': 'Прочее',
      'regional': 'Регион',
      'social': 'Соцсети',
      'tech': 'Технологии',
    };
    for (final entry in names.entries) {
      if (id.startsWith(entry.key)) return entry.value;
    }
    return 'Прочее';
  }
}

/// Плитка списка правил: название, размер и включение.
class _RuleSetTile extends StatelessWidget {
  const _RuleSetTile({required this.controller, required this.set});

  final AppController controller;
  final RuleSetEntry set;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final downloaded = set.sizeBytes > 0;

    return HairlineCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _shortTitle(set.title),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    _ActionPill(controller: controller, set: set),
                    const SizedBox(width: Space.sm),
                    if (downloaded)
                      Text(
                        '${(set.sizeBytes / 1024).toStringAsFixed(0)} КБ',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    else
                      Text(
                        'не скачан',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (downloaded && set.updatedAt > 0) ...[
                      const SizedBox(width: Space.sm),
                      Text(
                        _updatedLabel(set.updatedAt),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          if (!downloaded)
            IconButton(
              tooltip: 'Скачать',
              onPressed: () => controller.downloadList(set.id),
              icon: Icon(Icons.download_outlined, size: 20, color: tokens.muted),
            ),
          Switch(
            value: set.enabled,
            onChanged: (_) => controller.toggleRuleSet(set.id),
          ),
        ],
      ),
    );
  }

  String _shortTitle(String title) {
    final index = title.indexOf(':');
    if (index > 0 && index < 60) return title.substring(0, index).trim();
    return title;
  }
}

String _updatedLabel(int updatedAt) {
  final moment = DateTime.fromMillisecondsSinceEpoch(updatedAt);
  final now = DateTime.now();
  final day = moment.day.toString().padLeft(2, '0');
  final month = moment.month.toString().padLeft(2, '0');

  if (moment.year == now.year && moment.month == now.month && moment.day == now.day) {
    final hour = moment.hour.toString().padLeft(2, '0');
    final minute = moment.minute.toString().padLeft(2, '0');
    return 'сегодня $hour:$minute';
  }
  return '$day.$month';
}

/// Карточка настроек DPI-обхода на экране Правила.
class _DesyncModeCard extends StatelessWidget {
  const _DesyncModeCard({required this.controller});

  final AppController controller;

  static const _presets = <(String, String)>[
    ('auto', 'Авто'),
    ('fake_split', 'Fake + Split'),
    ('fake_disorder', 'Fake + Disorder'),
    ('tlsrec', 'TLS Record'),
    ('multi_split', 'Multi-Split'),
    ('split', 'Split'),
    ('disorder', 'Disorder'),
  ];

  static const _foolings = <(String, String)>[
    ('autottl', 'AutoTTL'),
    ('md5', 'MD5Sig'),
    ('timestamp', 'Timestamp'),
    ('badseq', 'BadSeq'),
    ('badsum', 'BadSum'),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final desync = controller.settings.desync;
    final enabled = desync.enabled;

    return HairlineCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Весь остальной трафик через DPI',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Рецепт: ${desync.preset} · Обман: ${desync.fooling}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (_) => controller.setDesync(
                  desync.copyWith(enabled: !enabled),
                ),
              ),
            ],
          ),
          const Divider(height: 20),
          Text(
            'Рецепт обхода (Preset)',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in _presets)
                GestureDetector(
                  onTap: () => controller.setDesync(desync.copyWith(preset: value)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: desync.preset == value
                          ? tokens.warning.withValues(alpha: 0.16)
                          : tokens.raised,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: desync.preset == value ? tokens.warning : tokens.line,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight:
                            desync.preset == value ? FontWeight.w600 : FontWeight.w400,
                        color: desync.preset == value ? tokens.warning : tokens.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(
            'Способ обмана ТСПУ (Fooling)',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in _foolings)
                GestureDetector(
                  onTap: () => controller.setDesync(desync.copyWith(fooling: value)),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: desync.fooling == value
                          ? tokens.accent.withValues(alpha: 0.16)
                          : tokens.raised,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: desync.fooling == value ? tokens.accent : tokens.line,
                      ),
                    ),
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight:
                            desync.fooling == value ? FontWeight.w600 : FontWeight.w400,
                        color: desync.fooling == value ? tokens.accent : tokens.muted,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Адаптивный автоподбор под провайдера',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              Switch(
                value: desync.autoTune,
                onChanged: (v) => controller.setDesync(desync.copyWith(autoTune: v)),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Разные рецепты для Wi-Fi и Мобильной сети',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      'Wi-Fi: ${desync.wifiPreset} · LTE: ${desync.cellularPreset}',
                      style: TextStyle(fontSize: 11, color: tokens.faint),
                    ),
                  ],
                ),
              ),
              Switch(
                value: controller.settings.perNetworkDesync,
                onChanged: controller.setPerNetworkDesync,
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: controller.testingDesync
                      ? null
                      : () async {
                          final chosen = await controller.autoPickDesyncPreset();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Подобран рецепт DPI: $chosen')),
                          );
                        },
                  icon: const Icon(Icons.bolt_outlined, size: 16),
                  label: const Text('Быстрый подбор'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: controller.testingDesync
                      ? null
                      : () async {
                          final winner = await controller.scanAllDesyncStrategies();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                winner != null
                                    ? 'Снайпер выбрал: ${winner.label} (${winner.avgMs} мс)'
                                    : 'Сканирование завершено',
                              ),
                            ),
                          );
                        },
                  icon: controller.testingDesync
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.radar_rounded, size: 16),
                  label: const Text('Снайпер (6x)'),
                ),
              ),
            ],
          ),
          if (controller.desyncTestStatus.isNotEmpty) ...[
            const SizedBox(height: Space.xs),
            Text(
              controller.desyncTestStatus,
              style: TextStyle(fontSize: 11.5, color: tokens.accent),
            ),
          ],
          if (controller.desyncScanResults.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            for (final item in controller.desyncScanResults)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Icon(
                      item.ok ? Icons.check_circle_outline : Icons.cancel_outlined,
                      size: 14,
                      color: item.ok ? tokens.success : tokens.danger,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        item.label,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    Text(
                      item.ok
                          ? 'YT: ${item.youtubeMs >= 0 ? "${item.youtubeMs}мс" : "✗"} · DC: ${item.discordMs >= 0 ? "${item.discordMs}мс" : "✗"}'
                          : 'Таймаут',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: item.ok ? tokens.success : tokens.faint,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Карточка выбора каскадного сервера (Proxy Chain / Detour).
class _DetourChainCard extends StatelessWidget {
  const _DetourChainCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final detour = controller.settings.detourProfile;
    final active = detour != null;

    return HairlineCard(
      onTap: () => _showPickDetourSheet(context),
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
      child: Row(
        children: [
          Icon(
            Icons.route_outlined,
            size: 20,
            color: active ? tokens.accent : tokens.muted,
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Каскад прокси (Proxy Chain / Detour)',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                Text(
                  active
                      ? 'Через узел: ${detour.name} (${detour.server})'
                      : 'Отключено — прямое подключение к выбранному серверу',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11.5,
                        color: active ? tokens.accent : tokens.faint,
                      ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: tokens.faint),
        ],
      ),
    );
  }

  Future<void> _showPickDetourSheet(BuildContext context) async {
    final currentId = controller.settings.detourProfileId;
    final selectedMainId = controller.settings.selectedProfileId;
    final candidates = controller
        .sortProfiles(controller.settings.profiles)
        .where((p) => p.id != selectedMainId)
        .toList();

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          children: [
            Text(
              'Каскадирование (Proxy Chain)',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
            const SizedBox(height: Space.xs),
            Text(
              'Трафик сначала пойдёт на промежуточный сервер (например, российский VDS), '
              'а из него — на основной зарубежный узел.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
            const SizedBox(height: Space.md),
            ListTile(
              dense: true,
              leading: const Icon(Icons.link_off_rounded),
              title: const Text('Без каскада (Напрямую к основному серверу)'),
              selected: currentId.isEmpty,
              onTap: () {
                Navigator.pop(ctx);
                controller.setDetourProfile('');
              },
            ),
            const Hairline(),
            for (final p in candidates)
              ListTile(
                dense: true,
                leading: Icon(
                  p.id == currentId
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${p.fullTransportLabel} · ${p.server}:${p.port}'),
                selected: p.id == currentId,
                onTap: () {
                  Navigator.pop(ctx);
                  controller.setDetourProfile(p.id);
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// Циклический переключатель действия для списка правил: тап = следующий режим.
class _ActionPill extends StatelessWidget {
  const _ActionPill({required this.controller, required this.set});

  final AppController controller;
  final RuleSetEntry set;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    const actions = ['proxy', 'direct', 'desync', 'block'];
    const labels = {
      'proxy': 'ТУННЕЛЬ',
      'direct': 'НАПРЯМУЮ',
      'desync': 'ОБХОД DPI',
      'block': 'БЛОК',
    };

    final current = set.action.isEmpty ? 'proxy' : set.action;

    final Color color;
    switch (current) {
      case 'direct':
        color = tokens.warning;
      case 'desync':
        color = const Color(0xFFFF8C00);
      case 'block':
        color = tokens.danger;
      default:
        color = tokens.accent;
    }

    return GestureDetector(
      onTap: () {
        final idx = actions.indexOf(current);
        final next = actions[(idx + 1) % actions.length];
        controller.setRuleSetAction(set.id, next);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Text(
          labels[current] ?? 'ТУННЕЛЬ',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: color,
          ),
        ),
      ),
    );
  }
}
