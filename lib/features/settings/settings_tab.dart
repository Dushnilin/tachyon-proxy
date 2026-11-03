import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../app/widgets/qr_code_view.dart';
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
                  title: 'Дробить TLS до прокси (Анти-глушилка LTE)',
                  subtitle:
                      'Фрагментировать TLS ClientHello до прокси-узлов (обход блокировок ТСПУ на мобильной сети)',
                  value: settings.proxyTlsFragment,
                  onChanged: controller.setProxyTlsFragment,
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
          const SectionLabel('Центр обновлений (Встроенный загрузчик)'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Отдельно Ядро tachyon-core (libtachyon.so)
                Row(
                  children: [
                    Icon(Icons.memory_rounded, size: 18, color: tokens.muted),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Ядро tachyon-core (libtachyon.so)',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Builder(
                            builder: (context) {
                              final shownVer =
                                  controller.installedCoreVersion.isNotEmpty
                                      ? controller.installedCoreVersion
                                      : _version;
                              return Text(
                                shownVer.isEmpty
                                    ? 'Чтение версии нативного движка...'
                                    : (controller.hasCoreUpdate
                                        ? 'Установлено: $shownVer · Доступно: v${controller.latestCoreVersion}'
                                        : (Platform.isIOS
                                            ? 'Установлено: $shownVer (TachyonCore.xcframework)'
                                            : 'Установлено: $shownVer (горячая замена .so)')),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: controller.hasCoreUpdate
                                          ? tokens.accent
                                          : tokens.muted,
                                      fontFeatures: const [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: controller.isAnyUpdateRunning
                          ? null
                          : () => controller.updateEngineOnly(),
                      icon: controller.updatingEngine
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.bolt_rounded, size: 16),
                      label: const Text('Ядро'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                const Hairline(),
                const SizedBox(height: Space.md),

                // 2. Отдельно Приложение Tachyon Proxy (APK)
                Row(
                  children: [
                    Icon(
                      Icons.install_mobile_rounded,
                      size: 18,
                      color: tokens.muted,
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            Platform.isIOS
                                ? 'Приложение Tachyon Proxy (IPA)'
                                : 'Приложение Tachyon Proxy (APK)',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.hasAppUpdate
                                ? 'Установлено: v${AppController.appVersion} · Доступно: v${controller.latestAppVersion}'
                                : 'Версия v${AppController.appVersion} · MTU ${settings.mtu}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: controller.hasAppUpdate
                                      ? tokens.accent
                                      : tokens.muted,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: controller.isAnyUpdateRunning
                          ? null
                          : () => controller.updateAppOnly(),
                      icon: controller.updatingApp
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.system_update_alt_rounded, size: 16),
                      label: Text(Platform.isIOS ? 'IPA' : 'APK'),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                const Hairline(),
                const SizedBox(height: Space.md),

                // 3. Отдельно Списки маршрутизации tachyon-lists (.trs)
                Row(
                  children: [
                    Icon(
                      Icons.rule_folder_outlined,
                      size: 18,
                      color: tokens.muted,
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Списки правил tachyon-lists (.trs)',
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                  fontWeight: FontWeight.w500,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Бинарные базы доменов и CIDR (YouTube, Discord, Telegram, РФ)',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: tokens.muted,
                                ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.sm),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      onPressed: controller.isAnyUpdateRunning
                          ? null
                          : () => controller.updateListsOnly(),
                      icon: controller.updatingLists
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cloud_download_outlined, size: 16),
                      label: const Text('Списки'),
                    ),
                  ],
                ),

                if (controller.updateStatusText.isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  const Hairline(),
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(
                      controller.updateStatusText,
                      style: TextStyle(
                        fontSize: 12,
                        color: (controller.hasCoreUpdate || controller.hasAppUpdate)
                            ? tokens.accent
                            : tokens.muted,
                      ),
                    ),
                  ),
                ],
                if (controller.isAnyUpdateRunning) ...[
                  const SizedBox(height: Space.sm),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: controller.updateProgress > 0
                          ? controller.updateProgress
                          : null,
                      minHeight: 6,
                    ),
                  ),
                ],
                const SizedBox(height: Space.md),
                OutlinedButton.icon(
                  onPressed: (controller.checkingUpdates ||
                          controller.isAnyUpdateRunning)
                      ? null
                      : () => controller.checkUpdates(),
                  icon: controller.checkingUpdates
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync_rounded, size: 17),
                  label: const Text('Проверить обновления на GitHub'),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('О проекте и поддержка'),
          HairlineCard(
            child: Column(
              children: [
                _LinkRow(
                  icon: Icons.favorite_border_rounded,
                  title: 'Поддержать проект',
                  subtitle:
                      'Карты РФ / СБП (CloudTips), Boosty и криптокошельки',
                  onTap: () => _showDonateDialog(context, controller),
                ),
                const Hairline(),
                _LinkRow(
                  icon: Icons.send_outlined,
                  title: 'Telegram-канал Tachyon',
                  subtitle: 'новости релизов, обсуждение и конфигурации (@tachyon_proxy)',
                  onTap: () async {
                    final opened =
                        await controller.openUrl('https://t.me/tachyon_proxy');
                    if (!opened && context.mounted) {
                      Clipboard.setData(
                        const ClipboardData(text: 'https://t.me/tachyon_proxy'),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Ссылка https://t.me/tachyon_proxy скопирована в буфер',
                          ),
                        ),
                      );
                    }
                  },
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

  Future<void> _showDonateDialog(
    BuildContext context,
    AppController controller,
  ) async {
    const cloudTipsUrl = 'https://pay.cloudtips.ru/p/449c5ef9';
    const boostyUrl = 'https://boosty.to/tachyon';
    const telegramUrl = 'https://t.me/tachyon_proxy';
    const wallets = <({String name, String address})>[
      (
        name: 'Bitcoin (BTC)',
        address: 'bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h',
      ),
      (
        name: 'TON',
        address: 'UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR',
      ),
      (
        name: 'Ethereum (ETH / ERC-20)',
        address: '0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6',
      ),
      (
        name: 'Solana (SOL)',
        address: '3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh',
      ),
    ];

    String? qrTitle;
    String? qrData;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (ctx, setStateLocal) {
          final tokens = ctx.tokens;

          Future<void> openOrCopy(String title, String url) async {
            final opened = await controller.openUrl(url);
            if (!opened && ctx.mounted) {
              Clipboard.setData(ClipboardData(text: url));
              ScaffoldMessenger.of(ctx).showSnackBar(
                SnackBar(content: Text('Ссылка $title скопирована: $url')),
              );
            }
          }

          Widget linkTile({
            required IconData icon,
            required String title,
            required String subtitle,
            required String url,
          }) {
            return Container(
              margin: const EdgeInsets.only(bottom: Space.sm),
              decoration: BoxDecoration(
                color: tokens.surface,
                borderRadius: BorderRadius.circular(Radii.control),
                border: Border.all(color: tokens.line),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(Radii.control),
                onTap: () => openOrCopy(title, url),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: Space.md,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: tokens.accent),
                      const SizedBox(width: Space.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w500,
                                color: tokens.ink,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: tokens.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Показать QR-код',
                        icon: Icon(
                          Icons.qr_code_2_rounded,
                          size: 18,
                          color: qrData == url ? tokens.accent : tokens.muted,
                        ),
                        onPressed: () => setStateLocal(() {
                          if (qrData == url) {
                            qrData = null;
                            qrTitle = null;
                          } else {
                            qrTitle = title;
                            qrData = url;
                          }
                        }),
                      ),
                      Icon(
                        Icons.open_in_new_rounded,
                        size: 16,
                        color: tokens.faint,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  Icons.favorite_border_rounded,
                  size: 20,
                  color: tokens.accent,
                ),
                const SizedBox(width: Space.sm),
                const Expanded(
                  child: Text('Поддержать проект'),
                ),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Если Tachyon помогает вам и делает работу в сети комфортной, вы можете поддержать развитие проекта и автора:',
                      style: Theme.of(ctx).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: Space.md),
                    if (qrData != null) ...[
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: Space.md),
                        padding: const EdgeInsets.all(Space.md),
                        decoration: BoxDecoration(
                          color: tokens.surface,
                          borderRadius: BorderRadius.circular(Radii.card),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Column(
                          children: [
                            Text(
                              qrTitle ?? '',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: tokens.ink,
                              ),
                            ),
                            const SizedBox(height: Space.sm),
                            QrCodeView(data: qrData!, size: 176),
                            const SizedBox(height: Space.xs),
                            Text(
                              qrData!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontFamily: 'monospace',
                                color: tokens.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    linkTile(
                      icon: Icons.credit_card_rounded,
                      title: 'Карты РФ / СБП / Tinkoff Pay',
                      subtitle: 'pay.cloudtips.ru/p/449c5ef9',
                      url: cloudTipsUrl,
                    ),
                    linkTile(
                      icon: Icons.star_outline_rounded,
                      title: 'Boosty (подписки и донаты)',
                      subtitle: 'boosty.to/tachyon',
                      url: boostyUrl,
                    ),
                    linkTile(
                      icon: Icons.send_outlined,
                      title: 'Telegram-канал проекта',
                      subtitle: 't.me/tachyon_proxy',
                      url: telegramUrl,
                    ),
                    const SizedBox(height: Space.sm),
                    Text(
                      'Криптовалюта (нажмите для копирования):',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: tokens.muted,
                      ),
                    ),
                    const SizedBox(height: Space.xs),
                    for (final w in wallets)
                      Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: tokens.surface,
                          borderRadius: BorderRadius.circular(Radii.control),
                          border: Border.all(color: tokens.line),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(Radii.control),
                          onTap: () {
                            Clipboard.setData(ClipboardData(text: w.address));
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text('Адрес ${w.name} скопирован'),
                              ),
                            );
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: Space.md,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        w.name,
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                          color: tokens.ink,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        w.address,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: tokens.muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  tooltip: 'QR-код кошелька',
                                  icon: Icon(
                                    Icons.qr_code_2_rounded,
                                    size: 18,
                                    color: qrData == w.address
                                        ? tokens.accent
                                        : tokens.muted,
                                  ),
                                  onPressed: () => setStateLocal(() {
                                    if (qrData == w.address) {
                                      qrData = null;
                                      qrTitle = null;
                                    } else {
                                      qrTitle = w.name;
                                      qrData = w.address;
                                    }
                                  }),
                                ),
                                Icon(
                                  Icons.copy_rounded,
                                  size: 15,
                                  color: tokens.faint,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(dialogCtx),
                child: const Text('Закрыть'),
              ),
            ],
          );
        },
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
