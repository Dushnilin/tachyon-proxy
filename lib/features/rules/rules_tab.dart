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

enum _RulesSubPage {
  routes('Маршруты и сервисы', Icons.alt_route_rounded),
  desync('Десинхронизация', Icons.tune_rounded),
  catalog('Каталог списков', Icons.folder_copy_outlined);

  const _RulesSubPage(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _RulesTabState extends State<RulesTab> {
  _RulesSubPage _page = _RulesSubPage.routes;
  String _listQuery = '';
  bool _onlyEnabledLists = false;
  String _selectedCategory = 'Все';
  final Set<String> _collapsedGroups = {'Прочее'};

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

  static String _groupOf(String id) {
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

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final sets = controller.settings.ruleSets;
    final customRules = controller.settings.customRules;

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
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.sm),
            child: HairlineCard(
              padding: const EdgeInsets.all(4),
              child: Row(
                children: [
                  for (final subPage in _RulesSubPage.values)
                    Expanded(
                      child: FocusableTap(
                        borderRadius: BorderRadius.circular(Radii.control),
                        onTap: () => setState(() => _page = subPage),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 6,
                          ),
                          decoration: BoxDecoration(
                            color: _page == subPage
                                ? tokens.accentSoft
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(Radii.control),
                            border: Border.all(
                              color: _page == subPage
                                  ? tokens.accent
                                  : Colors.transparent,
                            ),
                          ),
                          child: Text(
                            subPage == _RulesSubPage.catalog && sets.isNotEmpty
                                ? 'Списки (${sets.where((s) => s.enabled).length}/${sets.length})'
                                : subPage.label,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: _page == subPage
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: _page == subPage ? tokens.ink : tokens.muted,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(
            child: switch (_page) {
              _RulesSubPage.routes => ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.xs,
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
                        onPressed: () =>
                            _showAddCustomRuleDialog(context, controller),
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
                  ],
                ),
              _RulesSubPage.desync => ListView(
                  padding: const EdgeInsets.fromLTRB(
                    Space.lg,
                    Space.xs,
                    Space.lg,
                    Space.xxl,
                  ),
                  children: [
                    const SectionLabel('Настройка десинхронизации (Desync)'),
                    _DesyncModeCard(controller: controller),
                  ],
                ),
              _RulesSubPage.catalog => _buildCatalogPage(
                  context,
                  controller,
                  sets,
                ),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCatalogPage(
    BuildContext context,
    AppController controller,
    List<RuleSetEntry> sets,
  ) {
    final tokens = context.tokens;
    if (sets.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
        children: [
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
          ),
        ],
      );
    }

    final categoryCounts = <String, int>{};
    for (final s in sets) {
      final cat = _groupOf(s.id);
      categoryCounts[cat] = (categoryCounts[cat] ?? 0) + 1;
    }
    final categories = ['Все', ...categoryCounts.keys];

    final q = _listQuery.trim().toLowerCase();
    final filteredSets = sets.where((s) {
      if (_onlyEnabledLists && !s.enabled) return false;
      if (_selectedCategory != 'Все' && _groupOf(s.id) != _selectedCategory) {
        return false;
      }
      if (q.isEmpty) return true;
      return s.title.toLowerCase().contains(q) || s.id.toLowerCase().contains(q);
    }).toList();

    final groups = <String, List<RuleSetEntry>>{};
    for (final s in filteredSets) {
      groups.putIfAbsent(_groupOf(s.id), () => []).add(s);
    }

    final flatItems = <Object>[];
    for (final entry in groups.entries) {
      final isCollapsed = _selectedCategory == 'Все' &&
          q.isEmpty &&
          !_onlyEnabledLists &&
          _collapsedGroups.contains(entry.key);
      flatItems.add(_CatalogGroupHeader(
        title: entry.key,
        count: entry.value.length,
        enabledCount: entry.value.where((e) => e.enabled).length,
        isCollapsed: isCollapsed,
      ));
      if (!isCollapsed) {
        flatItems.addAll(entry.value);
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              const SizedBox(height: Space.sm),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final cat in categories) ...[
                      ChoiceChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          cat == 'Все'
                              ? 'Все (${sets.length})'
                              : '$cat (${categoryCounts[cat] ?? 0})',
                          style: const TextStyle(fontSize: 11.5),
                        ),
                        selected: _selectedCategory == cat,
                        onSelected: (_) =>
                            setState(() => _selectedCategory = cat),
                      ),
                      const SizedBox(width: 6),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Space.xs),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.xs,
              Space.lg,
              Space.xxl,
            ),
            itemCount: flatItems.length,
            itemBuilder: (ctx, idx) {
              final item = flatItems[idx];
              if (item is _CatalogGroupHeader) {
                return Padding(
                  padding: const EdgeInsets.only(top: Space.sm, bottom: Space.xs),
                  child: FocusableTap(
                    borderRadius: BorderRadius.circular(Radii.control),
                    onTap: () {
                      setState(() {
                        if (_collapsedGroups.contains(item.title)) {
                          _collapsedGroups.remove(item.title);
                        } else {
                          _collapsedGroups.add(item.title);
                        }
                      });
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.md,
                        vertical: Space.sm,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.raised,
                        borderRadius: BorderRadius.circular(Radii.control),
                        border: Border.all(color: tokens.line),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            item.isCollapsed
                                ? Icons.chevron_right_rounded
                                : Icons.expand_more_rounded,
                            size: 18,
                            color: tokens.muted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              item.title,
                              style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          if (item.enabledCount > 0) ...[
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.accent.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'вкл: ${item.enabledCount}',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: tokens.accent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            '${item.count} списков',
                            style: TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: tokens.faint,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              final set = item as RuleSetEntry;
              return Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: _RuleSetTile(controller: controller, set: set),
              );
            },
          ),
        ),
      ],
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
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: ruleType,
                    decoration: const InputDecoration(labelText: 'Тип совпадения'),
                    items: const [
                      DropdownMenuItem(
                        value: 'domain_suffix',
                        child: Text(
                          'Домен и поддомены (domain_suffix)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'domain',
                        child: Text(
                          'Точный домен (domain)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'domain_keyword',
                        child: Text(
                          'Ключевое слово в домене (keyword)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'ip_cidr',
                        child: Text(
                          'IP / Подсеть (CIDR)',
                          overflow: TextOverflow.ellipsis,
                        ),
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
                    isExpanded: true,
                    initialValue: action,
                    decoration: const InputDecoration(labelText: 'Действие'),
                    items: const [
                      DropdownMenuItem(
                        value: 'proxy',
                        child: Text(
                          'Через прокси (VPN)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'desync',
                        child: Text(
                          'Десинхронизация (Desync)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'direct',
                        child: Text(
                          'Напрямую (в обход VPN)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'block',
                        child: Text('Блокировать'),
                      ),
                    ],
                    onChanged: (v) => setStateLocal(() => action = v ?? action),
                  ),
                ],
              ),
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
    'proxy': 'Туннель',
    'direct': 'Напрямую',
    'desync': 'Desync',
    'block': 'Блок',
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
            onTap: () => controller.toggleCustomRule(r.id),
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
                FocusableTap(
                  borderRadius: BorderRadius.circular(Radii.tag),
                  focusBorderColor: _colorFor(tokens, r.action),
                  onTap: () {
                    final idx = _actions.indexOf(r.action);
                    final next = _actions[(idx + 1) % _actions.length];
                    controller.setCustomRuleAction(r.id, next);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _colorFor(tokens, r.action).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(Radii.tag),
                      border: Border.all(
                        color: _colorFor(tokens, r.action).withValues(alpha: 0.35),
                      ),
                    ),
                    child: Text(
                      _labels[r.action] ?? 'Туннель',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _colorFor(tokens, r.action),
                      ),
                    ),
                  ),
                ),
                ExcludeFocus(
                  child: Switch(
                    value: r.enabled,
                    onChanged: (_) => controller.toggleCustomRule(r.id),
                  ),
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
    ('desync', 'Desync'),
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
                          FocusableTap(
                            borderRadius: BorderRadius.circular(6),
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

    return FocusableTap(
      borderRadius: BorderRadius.circular(6),
      focusBorderColor: activeColor == tokens.muted ? tokens.accent : activeColor,
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
              child: FocusableTap(
                borderRadius: BorderRadius.circular(Radii.control),
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

class _CatalogGroupHeader {
  const _CatalogGroupHeader({
    required this.title,
    required this.count,
    required this.enabledCount,
    required this.isCollapsed,
  });

  final String title;
  final int count;
  final int enabledCount;
  final bool isCollapsed;
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
      onTap: () => controller.toggleRuleSet(set.id),
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
          ExcludeFocus(
            child: Switch(
              value: set.enabled,
              onChanged: (_) => controller.toggleRuleSet(set.id),
            ),
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

/// Карточка настроек пакетной десинхронизации на экране Правила.
class _DesyncModeCard extends StatelessWidget {
  const _DesyncModeCard({required this.controller});

  final AppController controller;

  static const _presets = <(String, String)>[
    ('auto', 'Авто'),
    ('fake_split', 'Fake + Split'),
    ('fake_disorder', 'Fake + Disorder'),
    ('tlsrec', 'TLS Record'),
    ('multi_split', 'Multi-Split'),
    ('multi_disorder', 'Multi-Disorder'),
    ('split', 'Split'),
    ('disorder', 'Disorder'),
    ('oob', 'OOB'),
  ];

  static const _foolings = <(String, String)>[
    ('autottl', 'AutoTTL'),
    ('md5', 'MD5Sig'),
    ('badack', 'BadACK'),
    ('md5_badack', 'MD5+BadACK'),
    ('timestamp', 'Timestamp'),
    ('badseq', 'BadSeq'),
    ('badsum', 'BadSum'),
    ('badseq_badack_badsum', 'Triple'),
    ('hopbyhop', 'IPv6 Hop'),
    ('datanoack', 'DataNoACK'),
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
          SwitchRow(
            title: 'Весь остальной трафик через Desync',
            subtitle: 'Рецепт: ${desync.preset} · Маркировка: ${desync.fooling}',
            value: enabled,
            onChanged: (v) => controller.setDesync(
              desync.copyWith(enabled: v),
            ),
          ),
          const Divider(height: 20),
          Text(
            'Рецепт десинхронизации (Preset)',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in _presets)
                FocusableTap(
                  borderRadius: BorderRadius.circular(6),
                  focusBorderColor: tokens.warning,
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
            'Маркировка тестовых пакетов (Fooling)',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final (value, label) in _foolings)
                FocusableTap(
                  borderRadius: BorderRadius.circular(6),
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
          SwitchRow(
            title: 'Адаптивный автоподбор под провайдера',
            value: desync.autoTune,
            onChanged: (v) => controller.setDesync(desync.copyWith(autoTune: v)),
          ),
          SwitchRow(
            title: 'Разные рецепты для Wi-Fi и Мобильной сети',
            subtitle: 'Wi-Fi: ${desync.wifiPreset} · LTE: ${desync.cellularPreset}',
            value: controller.settings.perNetworkDesync,
            onChanged: controller.setPerNetworkDesync,
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
                            SnackBar(content: Text('Подобран рецепт десинхронизации: $chosen')),
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
                  label: const Text('Снайпер (7x)'),
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
      'proxy': 'Туннель',
      'direct': 'Напрямую',
      'desync': 'Desync',
      'block': 'Блок',
    };

    final current = set.action.isEmpty ? 'proxy' : set.action;

    final Color color;
    switch (current) {
      case 'direct':
        color = tokens.success;
      case 'desync':
        color = tokens.warning;
      case 'block':
        color = tokens.danger;
      default:
        color = tokens.accent;
    }

    return FocusableTap(
      borderRadius: BorderRadius.circular(Radii.tag),
      focusBorderColor: color,
      onTap: () {
        final idx = actions.indexOf(current);
        final next = actions[(idx + 1) % actions.length];
        controller.setRuleSetAction(set.id, next);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.tag),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          labels[current] ?? 'Туннель',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            color: color,
          ),
        ),
      ),
    );
  }
}
