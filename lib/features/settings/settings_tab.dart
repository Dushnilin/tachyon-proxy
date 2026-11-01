import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../core/app_controller.dart';
import '../../core/models/app_rules.dart';
import '../../features/apps/apps_screen.dart';
import '../../features/connections/connections_screen.dart';
import '../../features/diagnostics/diagnostics_screen.dart';
import '../../features/dns/dns_screen.dart';
import '../../features/logs/logs_screen.dart';

/// Экран настроек: оформление, сеть, системные параметры, резервное копирование и сведения о сборке.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final controller = AppScope.read(context);
      final version = await controller.coreVersion();
      if (mounted) setState(() => _version = version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final settings = controller.settings;

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(title: const Text('Настройки')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
        children: [
          const SectionLabel('Оформление'),
          HairlineCard(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Тема',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        settings.themeMode == 'light' ? 'Светлая' : 'Тёмная',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'dark', label: Text('Тёмная')),
                    ButtonSegment(value: 'light', label: Text('Светлая')),
                  ],
                  selected: {settings.themeMode},
                  showSelectedIcon: false,
                  onSelectionChanged: (value) => controller.setThemeMode(
                    value.first,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Сеть и диагностика'),
          HairlineCard(
            child: Column(
              children: [
                _LinkRow(
                  icon: Icons.speed_rounded,
                  title: 'Диагностика и спидтест',
                  subtitle: 'внешний IP/гео, матрица доступности ТСПУ и замер скорости',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiagnosticsScreen(),
                    ),
                  ),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.dns_outlined,
                  title: 'DNS и FakeIP',
                  subtitle: settings.dns.servers.isEmpty
                      ? 'системный резолвер${settings.dns.fakeIp ? " · FakeIP" : ""}'
                      : '${settings.dns.servers.length} резолвера${settings.dns.fakeIp ? " · FakeIP" : ""}',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const DnsScreen()),
                  ),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.apps_outlined,
                  title: 'Приложения',
                  subtitle: settings.appRoutes.isNotEmpty
                      ? '${settings.appRoutes.length} точечных правил'
                      : (settings.appsMode == AppsMode.all
                          ? 'весь трафик в туннеле'
                          : '${settings.appPackages.length} отмечено'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const AppsScreen()),
                  ),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.hub_outlined,
                  title: 'Активные соединения',
                  subtitle:
                      'живой монитор хостов и быстрое создание правил',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ConnectionsScreen(),
                    ),
                  ),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.article_outlined,
                  title: 'Журнал ядра',
                  subtitle: 'Live-tail, фильтр по уровням и поиск',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const LogsScreen()),
                  ),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.verified_outlined,
                  title: 'Проверить конфигурацию',
                  subtitle: 'движок проверит настройки без запуска',
                  onTap: () => _checkConfig(context, controller),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Параметры туннеля и системы'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchRow(
                  title: 'Умная отказоустойчивость (Smart Failover)',
                  subtitle: 'Автоматически переключать на лучший сервер при падении текущего',
                  value: settings.smartFailover,
                  onChanged: controller.setSmartFailover,
                ),
                const Hairline(),
                SwitchRow(
                  title: 'Режим «Только прокси» (без VPN TUN)',
                  subtitle: 'Запускать локальный SOCKS5/HTTP на :2080 без системного VPN',
                  value: settings.proxyOnly,
                  onChanged: controller.setProxyOnly,
                ),
                const Hairline(),
                SwitchRow(
                  title: 'Раздавать прокси в локальную сеть (Allow LAN)',
                  subtitle: 'Слушать SOCKS5/HTTP на 0.0.0.0:2080 для домашней сети',
                  value: settings.allowLan,
                  onChanged: controller.setAllowLan,
                ),
                const Hairline(),
                SwitchRow(
                  title: 'Автозапуск при включении Android',
                  subtitle: 'Восстанавливать туннель после перезагрузки устройства',
                  value: settings.autoStart,
                  onChanged: controller.setAutoStart,
                ),
                const Hairline(),
                SwitchRow(
                  title: 'Автообновление подписок',
                  subtitle: 'Фоновое обновление серверов каждые 12 часов',
                  value: settings.autoUpdateSubs,
                  onChanged: controller.setAutoUpdateSubs,
                ),
                const Hairline(),
                const SizedBox(height: Space.sm),
                Text(
                  'Размер пакета туннеля (MTU)',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  children: [
                    for (final mtu in const [1360, 1400, 1420, 1500, 9000])
                      GestureDetector(
                        onTap: () => controller.setMtu(mtu),
                        child: Pill(
                          label: '$mtu',
                          color: settings.mtu == mtu ? tokens.accent : tokens.faint,
                          filled: settings.mtu == mtu,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Резервное копирование'),
          HairlineCard(
            child: Column(
              children: [
                _LinkRow(
                  icon: Icons.upload_file_outlined,
                  title: 'Экспорт настроек (JSON)',
                  subtitle:
                      'сохранить профили, подписки, правила и настройки в буфер или файл',
                  onTap: () => _showExportDialog(context, controller),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.download_for_offline_outlined,
                  title: 'Импорт настроек (JSON)',
                  subtitle: 'восстановить все параметры из резервной копии',
                  onTap: () => _showImportBackupDialog(context, controller),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Обход DPI'),
          HairlineCard(
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
                            'Включить обход',
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Нативный desync-аутбаунд ядра: обман DPI на первых пакетах',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: settings.desync.enabled,
                      onChanged: (value) => controller.setDesync(
                        settings.desync.copyWith(enabled: value),
                      ),
                    ),
                  ],
                ),
                if (settings.desync.enabled) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    'Рецепт',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      for (final preset in const [
                        'auto',
                        'fake_split',
                        'fake_disorder',
                        'multi_split',
                        'split',
                        'disorder',
                        'tlsrec',
                        'fake',
                        'oob',
                      ])
                        GestureDetector(
                          onTap: () => controller.setDesync(
                            settings.desync.copyWith(preset: preset),
                          ),
                          child: Pill(
                            label: preset,
                            color: settings.desync.preset == preset
                                ? tokens.accent
                                : tokens.faint,
                            filled: settings.desync.preset == preset,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Одурачивание',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      for (final fooling in const [
                        'autottl',
                        'md5',
                        'timestamp',
                        'badseq',
                        'badsum',
                      ])
                        GestureDetector(
                          onTap: () => controller.setDesync(
                            settings.desync.copyWith(fooling: fooling),
                          ),
                          child: Pill(
                            label: fooling,
                            color: settings.desync.fooling == fooling
                                ? tokens.accent
                                : tokens.faint,
                            filled: settings.desync.fooling == fooling,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Адаптивная подстройка',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      Switch(
                        value: settings.desync.autoTune,
                        onChanged: (value) => controller.setDesync(
                          settings.desync.copyWith(autoTune: value),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                ],
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Уровень журнала'),
          HairlineCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.sm),
              child: Wrap(
                spacing: Space.sm,
                children: [
                  for (final level in const ['error', 'warn', 'info', 'debug'])
                    GestureDetector(
                      onTap: () => controller.setLogLevel(level),
                      child: Pill(
                        label: level.toUpperCase(),
                        color: settings.logLevel == level
                            ? tokens.accent
                            : tokens.faint,
                        filled: settings.logLevel == level,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('О приложении'),
          HairlineCard(
            child: Column(
              children: [
                DetailRow(label: 'Ядро', value: _version.isEmpty ? '—' : _version),
                const Hairline(),
                DetailRow(
                  label: 'Приложение',
                  value: 'Tachyon ${settings.mtu} MTU',
                ),
                const Hairline(),
                const DetailRow(
                  label: 'Плитка шторки Android',
                  value: 'Доступна в быстрых настройках',
                ),
                const Hairline(),
                const DetailRow(
                  label: 'Списки',
                  value: 'tachyon-lists',
                ),
              ],
            ),
          ),
          if (controller.lastError.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            HairlineCard(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline, size: 16, color: tokens.danger),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      controller.lastError,
                      style: TextStyle(fontSize: 12.5, color: tokens.danger),
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

  Future<void> _showExportDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final jsonText = controller.exportSettingsJson();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Экспорт настроек'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: TextEditingController(text: jsonText),
            readOnly: true,
            maxLines: 8,
            style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: jsonText));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Резервная копия скопирована в буфер')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Копировать'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              controller.shareText(
                jsonText,
                subject: 'tachyon-backup.json',
              );
            },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Поделиться'),
          ),
        ],
      ),
    );
  }

  Future<void> _showImportBackupDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final textCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Импорт резервной копии'),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: textCtrl,
            maxLines: 8,
            minLines: 4,
            style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace'),
            decoration: InputDecoration(
              hintText: 'Вставьте JSON резервной копии...',
              suffixIcon: IconButton(
                tooltip: 'Вставить из буфера',
                icon: const Icon(Icons.content_paste_rounded),
                onPressed: () async {
                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                  if (d?.text != null) {
                    textCtrl.text = d!.text!;
                  }
                },
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () async {
              final raw = textCtrl.text.trim();
              if (raw.isEmpty) return;
              Navigator.pop(ctx);
              final ok = await controller.importSettingsJson(raw);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    ok
                        ? 'Настройки успешно восстановлены'
                        : 'Не удалось разобрать JSON резервной копии',
                  ),
                ),
              );
            },
            child: const Text('Восстановить'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
  }

  Future<void> _checkConfig(
    BuildContext context,
    AppController controller,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await controller.checkConfig();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          error == null ? 'Конфигурация принята движком' : 'Ошибка: $error',
        ),
      ),
    );
  }
}

/// Строка-ссылка на другой экран.
class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Space.md),
        child: Row(
          children: [
            Icon(icon, size: 17, color: tokens.muted),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: tokens.faint),
          ],
        ),
      ),
    );
  }
}
