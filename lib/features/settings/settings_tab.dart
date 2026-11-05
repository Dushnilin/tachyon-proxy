import 'dart:async' show unawaited;
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
import '../../features/profiles/profiles_tab.dart' show showBalancerSettingsSheet;

enum _SettingsSubPage {
  network('Сеть и диагностика'),
  tunnel('Туннель и Desync'),
  system('Система и бэкап');

  const _SettingsSubPage(this.label);
  final String label;
}

/// Экран настроек: оформление, сеть, системные параметры, резервное копирование и сведения о сборке.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  String _version = '';
  _SettingsSubPage _page = _SettingsSubPage.network;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final controller = AppScope.read(context);
      unawaited(controller.refreshWifiInfo());
      final version = await controller.coreVersion();
      if (mounted) setState(() => _version = version);
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final settings = controller.settings;

    final isLight = settings.themeMode == 'light';

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Настройки'),
        actions: [
          IconButton(
            tooltip: 'Проверить конфигурацию ядра',
            onPressed: () => _checkConfig(context, controller),
            icon: const Icon(Icons.verified_outlined, size: 20),
          ),
          IconButton(
            tooltip: isLight ? 'Включить тёмную тему' : 'Включить светлую тему',
            onPressed: () => controller.setThemeMode(isLight ? 'dark' : 'light'),
            icon: Icon(
              isLight ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              size: 20,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 2, Space.lg, Space.xs),
            child: HairlineCard(
              padding: const EdgeInsets.all(3),
              child: Row(
                children: [
                  for (final subPage in _SettingsSubPage.values)
                    Expanded(
                      child: FocusableTap(
                        borderRadius: BorderRadius.circular(Radii.control),
                        onTap: () => setState(() => _page = subPage),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            vertical: 7,
                            horizontal: 4,
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
                            subPage.label,
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
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.xl),
              children: [
                if (_page == _SettingsSubPage.network) ...[
                  const SectionLabel('Инструменты и маршрутизация'),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.bolt_rounded,
                          title: 'Балансировщик',
                          subtitle:
                              '${settings.balancer.modeOption.shortLabel} · Top-${settings.balancer.pool}',
                          accent: true,
                          onTap: () => showBalancerSettingsSheet(context, controller),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.dns_outlined,
                          title: 'DNS и FakeIP',
                          subtitle: settings.dns.servers.isEmpty
                              ? 'системный${settings.dns.fakeIp ? " · FakeIP" : ""}'
                              : '${settings.dns.servers.length} серв.${settings.dns.fakeIp ? " · FakeIP" : ""}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const DnsScreen()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.apps_outlined,
                          title: 'Приложения',
                          subtitle: settings.appRoutes.isNotEmpty
                              ? '${settings.appRoutes.length} правил'
                              : (settings.appsMode == AppsMode.all
                                  ? 'весь трафик'
                                  : '${settings.appPackages.length} выбр.'),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const AppsScreen()),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.hub_outlined,
                          title: 'Соединения',
                          subtitle: 'живой монитор',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const ConnectionsScreen(),
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
                        child: _CompactToolCard(
                          icon: Icons.speed_rounded,
                          title: 'Диагностика',
                          subtitle: 'IP, пинг, спидтест',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const DiagnosticsScreen(),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.article_outlined,
                          title: 'Журнал ядра',
                          subtitle: 'уровень: ${settings.logLevel.toUpperCase()}',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(builder: (_) => const LogsScreen()),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  const SectionLabel('Домашний Wi-Fi (Авто-пауза)'),
                  _HomeWifiSettingsCard(controller: controller),
                ],
                if (_page == _SettingsSubPage.tunnel) ...[
                  const SectionLabel('Режимы туннеля и отказоустойчивость'),
                  HairlineCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.md,
                      vertical: Space.xs,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SwitchRow(
                          title: 'Умная отказоустойчивость (Smart Failover)',
                          subtitle: 'Автопереключение при недоступности узла',
                          value: settings.smartFailover,
                          onChanged: controller.setSmartFailover,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Фрагментация TLS до прокси (LTE)',
                          subtitle: 'Дробить TLS ClientHello до прокси-узлов',
                          value: settings.proxyTlsFragment,
                          onChanged: controller.setProxyTlsFragment,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Десинхронизация пакетов (Desync)',
                          subtitle:
                              'Рецепт: ${settings.desync.preset} · ${settings.desync.fooling}',
                          value: settings.desync.enabled,
                          onChanged: (value) => controller.setDesync(
                            settings.desync.copyWith(enabled: value),
                          ),
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Только локальный прокси (:2080 без TUN)',
                          subtitle: 'SOCKS5/HTTP без системного VPN-интерфейса',
                          value: settings.proxyOnly,
                          onChanged: controller.setProxyOnly,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Раздавать прокси в LAN (0.0.0.0:2080)',
                          subtitle: 'Доступ для устройств в домашней сети',
                          value: settings.allowLan,
                          onChanged: controller.setAllowLan,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Автозапуск при старте системы',
                          subtitle: 'Восстанавливать туннель после перезагрузки',
                          value: settings.autoStart,
                          onChanged: controller.setAutoStart,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Автообновление подписок (раз в 12 ч)',
                          subtitle: 'Фоновая синхронизация списков серверов',
                          value: settings.autoUpdateSubs,
                          onChanged: controller.setAutoUpdateSubs,
                        ),
                        const Hairline(),
                        SwitchRow(
                          title: 'Блок резервных узлов (WARP · SHARD)',
                          subtitle: 'Показывать генератор на главном экране',
                          value: settings.showFreeNodes,
                          onChanged: controller.setShowFreeNodes,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  const SectionLabel('Пакетный буфер (MTU) и журнал'),
                  HairlineCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Space.md,
                      vertical: Space.sm,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            SizedBox(
                              width: 54,
                              child: Text(
                                'MTU',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: tokens.muted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  for (final mtu in const [1360, 1400, 1420, 1500, 9000])
                                    FocusableTap(
                                      onTap: () => controller.setMtu(mtu),
                                      child: Pill(
                                        label: '$mtu',
                                        color: settings.mtu == mtu
                                            ? tokens.accent
                                            : tokens.faint,
                                        filled: settings.mtu == mtu,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Hairline(),
                        ),
                        Row(
                          children: [
                            SizedBox(
                              width: 54,
                              child: Text(
                                'Логи',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: tokens.muted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  for (final level in const ['error', 'warn', 'info', 'debug'])
                                    FocusableTap(
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
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_page == _SettingsSubPage.system) ...[
                  const SectionLabel('Центр обновлений'),
                  HairlineCard(
                    padding: const EdgeInsets.all(Space.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Icon(Icons.memory_rounded, size: 17, color: tokens.muted),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Ядро tachyon-core',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  Builder(
                                    builder: (context) {
                                      final shownVer =
                                          controller.installedCoreVersion.isNotEmpty
                                              ? controller.installedCoreVersion
                                              : _version;
                                      return Text(
                                        shownVer.isEmpty
                                            ? 'Чтение версии...'
                                            : (controller.hasCoreUpdate
                                                ? '$shownVer → доступно v${controller.latestCoreVersion}'
                                                : 'Установлено: $shownVer'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11,
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
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                              ),
                              onPressed: controller.isAnyUpdateRunning
                                  ? null
                                  : () => controller.updateEngineOnly(),
                              icon: controller.updatingEngine
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.bolt_rounded, size: 14),
                              label: const Text('Ядро', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Hairline(),
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.install_mobile_rounded,
                              size: 17,
                              color: tokens.muted,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    Platform.isIOS
                                        ? 'Приложение (IPA)'
                                        : 'Приложение (APK)',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  Text(
                                    controller.hasAppUpdate
                                        ? 'v${AppController.appVersion} → доступно v${controller.latestAppVersion}'
                                        : 'Версия v${AppController.appVersion}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
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
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                              ),
                              onPressed: controller.isAnyUpdateRunning
                                  ? null
                                  : () => controller.updateAppOnly(),
                              icon: controller.updatingApp
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.system_update_alt_rounded, size: 14),
                              label: Text(
                                Platform.isIOS ? 'IPA' : 'APK',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Hairline(),
                        ),
                        Row(
                          children: [
                            Icon(
                              Icons.rule_folder_outlined,
                              size: 17,
                              color: tokens.muted,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Списки правил (.trs)',
                                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  Text(
                                    'Базы доменов и подсетей tachyon-lists',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: tokens.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                              ),
                              onPressed: controller.isAnyUpdateRunning
                                  ? null
                                  : () => controller.updateListsOnly(),
                              icon: controller.updatingLists
                                  ? const SizedBox(
                                      width: 12,
                                      height: 12,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.cloud_download_outlined, size: 14),
                              label: const Text('Списки', style: TextStyle(fontSize: 11.5)),
                            ),
                          ],
                        ),
                        if (controller.updateStatusText.isNotEmpty) ...[
                          const SizedBox(height: Space.xs),
                          Text(
                            controller.updateStatusText,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: (controller.hasCoreUpdate || controller.hasAppUpdate)
                                  ? tokens.accent
                                  : tokens.muted,
                            ),
                          ),
                        ],
                        if (controller.isAnyUpdateRunning) ...[
                          const SizedBox(height: 6),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: controller.updateProgress > 0
                                  ? controller.updateProgress
                                  : null,
                              minHeight: 5,
                            ),
                          ),
                        ],
                        const SizedBox(height: Space.sm),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: (controller.checkingUpdates ||
                                  controller.isAnyUpdateRunning)
                              ? null
                              : () => controller.checkUpdates(),
                          icon: controller.checkingUpdates
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.sync_rounded, size: 15),
                          label: const Text(
                            'Проверить обновления на GitHub',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  const SectionLabel('Резервная копия и проект'),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.upload_file_outlined,
                          title: 'Экспорт JSON',
                          subtitle: 'сохранить бэкап',
                          onTap: () => _showExportDialog(context, controller),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.download_for_offline_outlined,
                          title: 'Импорт JSON',
                          subtitle: 'восстановить',
                          onTap: () => _showImportBackupDialog(context, controller),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.favorite_border_rounded,
                          title: 'Поддержать',
                          subtitle: 'СБП, Boosty, крипто',
                          onTap: () => _showDonateDialog(context, controller),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Expanded(
                        child: _CompactToolCard(
                          icon: Icons.send_outlined,
                          title: 'Telegram-канал',
                          subtitle: '@tachyon_proxy',
                          onTap: () async {
                            final opened = await controller.openUrl(
                              'https://t.me/tachyon_proxy',
                            );
                            if (!opened && context.mounted) {
                              Clipboard.setData(
                                const ClipboardData(
                                  text: 'https://t.me/tachyon_proxy',
                                ),
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
                      ),
                    ],
                  ),
                ],
                if (controller.lastError.isNotEmpty) ...[
                  const SizedBox(height: Space.md),
                  HairlineCard(
                    padding: const EdgeInsets.all(Space.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.error_outline, size: 16, color: tokens.danger),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(
                            controller.lastError,
                            style: TextStyle(fontSize: 12, color: tokens.danger),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
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

/// Компактная плитка инструмента в сетке 2xN (с поддержкой фокуса Android TV).
class _CompactToolCard extends StatelessWidget {
  const _CompactToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.accent = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return HairlineCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: 10,
      ),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: accent
                  ? tokens.accent.withValues(alpha: 0.14)
                  : tokens.surface,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: accent
                    ? tokens.accent.withValues(alpha: 0.35)
                    : tokens.line,
              ),
            ),
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 16,
              color: accent ? tokens.accent : tokens.muted,
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: tokens.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: accent ? tokens.accent : tokens.muted,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 16, color: tokens.faint),
        ],
      ),
    );
  }
}

/// Компактная карточка настройки режима «Домашний интернет».
class _HomeWifiSettingsCard extends StatelessWidget {
  const _HomeWifiSettingsCard({required this.controller});

  final AppController controller;

  Future<void> _showAddSsidDialog(BuildContext context) async {
    final textCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Добавить Wi-Fi сеть (SSID)'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Введите точное название Wi-Fi сети (например, домашнего или офисного роутера). При подключении к ней маршрутизация будет автоматически отключаться:',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: textCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Например: Keenetic-5G, Home_WiFi, Office',
                  prefixIcon: Icon(Icons.wifi_rounded, size: 18),
                ),
                onSubmitted: (val) {
                  final clean = val.trim();
                  if (clean.isNotEmpty) {
                    controller.addTrustedWifiSsid(clean);
                    Navigator.pop(ctx);
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              final clean = textCtrl.text.trim();
              if (clean.isNotEmpty) {
                controller.addTrustedWifiSsid(clean);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Добавить'),
          ),
        ],
      ),
    );
    textCtrl.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final settings = controller.settings;
    final trusted = settings.trustedWifiSsids;
    final currentSsid = controller.currentWifiSsid;
    final isWifi = controller.isWifiConnected;
    final hasPerm = controller.hasWifiPermission;
    final locEnabled = controller.wifiLocationEnabled;
    final isCurrentTrusted = controller.isCurrentWifiTrusted;
    final pausedSsid = controller.tunnel.pausedWifiSsid;

    final nearbySuggestions = controller.nearbyWifiSsids
        .where(
          (s) => !trusted.any(
            (t) => t.trim().toLowerCase() == s.trim().toLowerCase(),
          ),
        )
        .toList(growable: false);

    return HairlineCard(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchRow(
            title: 'Авто-пауза в домашних Wi-Fi сетях',
            subtitle: trusted.isEmpty
                ? 'Отключать VPN при входе в выбранные сети (роутер с Tachyon)'
                : 'Активно для сетей: ${trusted.join(", ")}',
            value: settings.homeWifiMode,
            onChanged: controller.setHomeWifiMode,
          ),
          const Hairline(),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Icon(
                  isWifi ? Icons.wifi_rounded : Icons.signal_cellular_alt_rounded,
                  size: 16,
                  color: isWifi
                      ? (isCurrentTrusted ? tokens.accent : tokens.success)
                      : tokens.muted,
                ),
                const SizedBox(width: Space.xs),
                Expanded(
                  child: Text(
                    pausedSsid.isNotEmpty
                        ? 'Авто-пауза: $pausedSsid'
                        : currentSsid.isNotEmpty
                            ? 'Сеть: $currentSsid${isCurrentTrusted ? " (домашняя)" : ""}'
                            : (isWifi
                                ? (!hasPerm
                                    ? 'Нужен доступ к геолокации для чтения SSID'
                                    : (!locEnabled
                                        ? 'Включите геолокацию для чтения SSID'
                                        : 'Wi-Fi подключён'))
                                : 'Мобильная сеть / Wi-Fi выключен'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: (pausedSsid.isNotEmpty || isCurrentTrusted)
                          ? tokens.accent
                          : tokens.muted,
                    ),
                  ),
                ),
                if (currentSsid.isNotEmpty && !isCurrentTrusted)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => controller.addTrustedWifiSsid(currentSsid),
                    icon: const Icon(Icons.add_rounded, size: 14),
                    label: const Text('В домашние', style: TextStyle(fontSize: 11.5)),
                  )
                else if (isWifi && currentSsid.isEmpty && !hasPerm)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () =>
                        controller.refreshWifiInfo(requestPermission: true),
                    child: const Text('Разрешить', style: TextStyle(fontSize: 11.5)),
                  )
                else if (isWifi && currentSsid.isEmpty && !locEnabled)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: controller.openLocationSettings,
                    child: const Text('Геолокация', style: TextStyle(fontSize: 11.5)),
                  ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 28),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => _showAddSsidDialog(context),
                  icon: const Icon(Icons.add_rounded, size: 14),
                  label: const Text('SSID', style: TextStyle(fontSize: 11.5)),
                ),
              ],
            ),
          ),
          if (trusted.isNotEmpty || nearbySuggestions.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final ssid in trusted)
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => controller.removeTrustedWifiSsid(ssid),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: tokens.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: tokens.accent.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.home_rounded, size: 12, color: tokens.accent),
                            const SizedBox(width: 4),
                            Text(
                              ssid,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: tokens.ink,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.close_rounded, size: 12, color: tokens.muted),
                          ],
                        ),
                      ),
                    ),
                  for (final near in nearbySuggestions.take(4))
                    FocusableTap(
                      onTap: () => controller.addTrustedWifiSsid(near),
                      child: Pill(
                        label: '+ $near',
                        color: tokens.muted,
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
