import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../app/widgets/qr_code_view.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';
import '../../core/services/core_bridge.dart';
import '../../core/services/link_parser.dart';
import 'tv_receive_dialog.dart';

/// Экран профилей: список серверов и импорт подписки.
class ProfilesTab extends StatefulWidget {
  const ProfilesTab({super.key});

  @override
  State<ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<ProfilesTab> {
  String _searchQuery = '';

  List<Profile> _filter(
    List<Profile> items,
    AppController controller, {
    SubscriptionEntry? contextSub,
  }) {
    final allowed = items
        .where((p) => controller.isProfileAllowedByFilters(p, contextSub: contextSub))
        .toList(growable: false);
    final base = allowed.isNotEmpty ? allowed : items;
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return base;
    return base
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.server.toLowerCase().contains(q) ||
            p.type.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final profiles = controller.settings.visibleProfiles;
    final subs = controller.settings.visibleSubscriptions;
    final hasActiveFilters = controller.settings.balancer.excludedCountries.isNotEmpty ||
        controller.settings.balancer.excludedProtocols.isNotEmpty ||
        subs.any((s) => s.excludedCountries.isNotEmpty || s.excludedProtocols.isNotEmpty);

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Профили'),
        actions: [
          if (controller.pingingAll)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: Space.md),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              tooltip: 'Пропинговать все серверы',
              onPressed: profiles.isEmpty ? null : () => controller.pingAllProfiles(),
              icon: const Icon(Icons.network_ping),
            ),
          IconButton(
            tooltip: controller.sortByPing
                ? 'Сортировка по пингу включена'
                : 'Сортировать по пингу',
            onPressed: profiles.isEmpty ? null : controller.toggleSortByPing,
            icon: Icon(
              Icons.sort_rounded,
              color: controller.sortByPing ? tokens.accent : null,
            ),
          ),
          IconButton(
            tooltip: 'Импорт подписки или серверов',
            onPressed: () => _showImportDialog(context, controller),
            icon: const Icon(Icons.file_download_outlined),
          ),
          PopupMenuButton<String>(
            tooltip: 'Дополнительные действия',
            icon: Icon(
              Icons.more_vert_rounded,
              color: hasActiveFilters ? tokens.accent : null,
            ),
            onSelected: (action) async {
              switch (action) {
                case 'qr':
                  await _handleQrScan(context, controller, fromGallery: false);
                case 'add_manual':
                  if (context.mounted) {
                    _showManualDialog(context, controller);
                  }
                case 'balancer':
                  if (context.mounted) {
                    await showBalancerSettingsSheet(context, controller);
                  }
                case 'network_lists':
                  if (context.mounted) {
                    await showNetworkListsSheet(context, controller);
                  }
                case 'merge_subs':
                  if (context.mounted) {
                    await showCombinedGroupDialog(context, controller);
                  }
                case 'tv_receive':
                  if (context.mounted) {
                    await showTvReceiveDialog(context, controller);
                  }
                case 'clean_dead':
                  final removed = await controller.removeDeadProfiles();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Удалено недоступных серверов: $removed')),
                    );
                  }
              }
            },
            itemBuilder: (ctx) {
              final hasDead = controller.pings.values.any((ms) => ms < 0);
              return [
                const PopupMenuItem(
                  value: 'qr',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.qr_code_scanner_rounded, size: 20),
                    title: Text('Сканировать QR-код'),
                  ),
                ),
                const PopupMenuItem(
                  value: 'add_manual',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.add_rounded, size: 20),
                    title: Text('Добавить сервер вручную'),
                  ),
                ),
                PopupMenuItem(
                  value: 'balancer',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      Icons.tune_rounded,
                      size: 20,
                      color: hasActiveFilters ? tokens.accent : null,
                    ),
                    title: const Text('Балансировщик и фильтры'),
                  ),
                ),
                if (profiles.isNotEmpty || subs.isNotEmpty)
                  const PopupMenuItem(
                    value: 'network_lists',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.swap_calls_rounded, size: 20),
                      title: Text('Списки для Wi-Fi и Мобильной сети'),
                    ),
                  ),
                if (subs.where((s) => !s.isCombinedGroup).length >= 2 ||
                    (subs.any((s) => !s.isCombinedGroup) &&
                        controller.settings.profilesForSubscription('').isNotEmpty))
                  const PopupMenuItem(
                    value: 'merge_subs',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.workspaces_outline, size: 20),
                      title: Text('Объединить подписки в группу'),
                    ),
                  ),
                const PopupMenuItem(
                  value: 'tv_receive',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.tv_rounded, size: 20),
                    title: Text('Принять на ТВ (Wi-Fi)'),
                  ),
                ),
                if (hasDead)
                  PopupMenuItem(
                    value: 'clean_dead',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        Icons.cleaning_services_outlined,
                        size: 20,
                        color: tokens.danger,
                      ),
                      title: Text(
                        'Удалить недоступные серверы',
                        style: TextStyle(color: tokens.danger),
                      ),
                    ),
                  ),
              ];
            },
          ),
        ],
      ),
      body: (profiles.isEmpty && subs.isEmpty)
          ? EmptyState(
              icon: Icons.dns_outlined,
              title: 'Профилей пока нет',
              description:
                  'Импортируйте подписку по ссылке или QR-коду, либо добавьте сервер вручную — '
                  'поддерживаются все протоколы tachyon-core: TewFai, VLESS, VMess, Trojan, Shadowsocks-2022, '
                  'Hysteria 2, TUIC v5, WireGuard / AmneziaWG, AnyTLS, NaiveProxy, Snell, ShadowTLS, '
                  'FPTN, MASQUE, Mieru, TrustTunnel, OpenConnect, SSH, MTProto, SOCKS5/HTTP, '
                  'а также подписки Sing-box, Xray, Clash/Mihomo YAML и SIP008.',
              action: Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: () => _showImportDialog(context, controller),
                    icon: const Icon(Icons.file_download_outlined, size: 18),
                    label: const Text('Импортировать'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => showTvReceiveDialog(context, controller),
                    icon: const Icon(Icons.tv_rounded, size: 18),
                    label: const Text('Принять на ТВ (Wi-Fi)'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _handleQrScan(context, controller, fromGallery: false),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: const Text('Сканировать QR'),
                  ),
                ],
              ),
            )
          : ValueListenableBuilder<int>(
              valueListenable: controller.pingRevision,
              builder: (context, _, _) {
                final freshStandalone = _filter(
                  controller.sortProfiles(
                    controller.settings.profilesForSubscription(''),
                  ),
                  controller,
                );
                return CustomScrollView(
                  slivers: _buildProfileSlivers(
                    context,
                    controller,
                    profiles,
                    subs,
                    freshStandalone,
                  ),
                );
              },
            ),
    );
  }

  List<Widget> _buildProfileSlivers(
    BuildContext context,
    AppController controller,
    List<Profile> profiles,
    List<SubscriptionEntry> subs,
    List<Profile> standaloneProfiles,
  ) {
    final selectedId = controller.settings.selectedProfileId;
    final winnerId = controller.activeBalancerWinner?.id;
    final slivers = <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
        sliver: SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (profiles.length > 4) ...[
                TextField(
                  onChanged: (v) => setState(() => _searchQuery = v),
                  decoration: const InputDecoration(
                    hintText: 'Фильтр по названию, хосту или протоколу...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: Space.md),
              ],
              if (profiles.length >= 2 && _searchQuery.trim().isEmpty) ...[
                _AutoBalancerTile(
                  title: 'Глобальный балансировщик (все серверы)',
                  selected: selectedId == 'auto:all',
                  controller: controller,
                  onSelect: () => controller.selectProfile('auto:all'),
                  onConfigure: () => showBalancerSettingsSheet(context, controller),
                ),
                const SizedBox(height: Space.sm),
                _NetworkListsSummaryTile(
                  controller: controller,
                  onTap: () => showNetworkListsSheet(context, controller),
                ),
                if (subs.where((s) => !s.isCombinedGroup).length >= 2 ||
                    (subs.any((s) => !s.isCombinedGroup) &&
                        standaloneProfiles.isNotEmpty)) ...[
                  const SizedBox(height: Space.xs),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(
                          horizontal: Space.md,
                          vertical: 8,
                        ),
                      ),
                      onPressed: () => showCombinedGroupDialog(context, controller),
                      icon: const Icon(Icons.workspaces_outline, size: 16),
                      label: const Text(
                        'Объединить подписки в группу',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: Space.md),
              ],
            ],
          ),
        ),
      ),
    ];

    for (final sub in subs) {
      final isCollapsed =
          controller.isSubCollapsed(sub.id) && _searchQuery.trim().isEmpty;
      final subProfiles = _filter(
        controller.sortProfiles(
          controller.settings.profilesForSubscription(sub.id),
        ),
        controller,
        contextSub: sub,
      );

      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          sliver: SliverToBoxAdapter(
            child: _CollapsibleSubCard(
              sub: sub,
              controller: controller,
              isCollapsed: isCollapsed,
              profiles: subProfiles,
              selectedId: selectedId,
              onToggleCollapse: () => controller.toggleSubCollapsed(sub.id),
              onToggleSub: () => controller.toggleSubscription(sub.id),
              onRemoveSub: () => controller.removeSubscription(sub.id),
              onRefreshSub: () async {
                if (sub.isFptnToken) {
                  await showFptnTokenDialog(
                    context,
                    controller,
                    sub.url,
                    existingSub: sub,
                  );
                  return;
                }
                final count = await controller.refreshSubscription(sub.id);
                if (!context.mounted) return;
                final msg = count > 0
                    ? 'Подписка обновлена (серверов: $count)'
                    : (controller.lastError.isNotEmpty
                        ? controller.lastError
                        : 'Не удалось обновить подписку');
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
              onPingAllSub: () =>
                  controller.pingAllProfiles(subscriptionId: sub.id),
              onSelectProfile: (id) => controller.selectProfile(id),
              onEditSub: () => sub.isCombinedGroup
                  ? showCombinedGroupDialog(
                      context,
                      controller,
                      existingGroup: sub,
                    )
                  : (sub.isFptnToken
                      ? showFptnTokenDialog(
                          context,
                          controller,
                          sub.url,
                          existingSub: sub,
                        )
                      : _showEditSubDialog(context, controller, sub)),
            ),
          ),
        ),
      );

      if (!isCollapsed && subProfiles.isNotEmpty) {
        slivers.add(
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Space.lg, 4, Space.lg, 0),
            sliver: SliverList.builder(
              itemCount: subProfiles.length,
              itemBuilder: (context, index) {
                final p = subProfiles[index];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _ProfileTile(
                    controller: controller,
                    profile: p,
                    selected: p.id == selectedId,
                    ping: controller.pingOf(p.id),
                    isPinging: controller.isPinging(p.id),
                    telemetry: controller.balancerTelemetryOf(p.id),
                    isBalancerWinner: winnerId == p.id,
                    onSelect: () => controller.selectProfile(p.id),
                    onDelete: () => controller.removeProfile(p.id),
                    onEdit: () => _showManualDialog(context, controller, edit: p),
                    onShare: () => _showQrDialog(context, controller, p),
                    onPing: () => controller.pingProfile(p.id),
                    onChangeNetworkScope: (scope) =>
                        controller.setProfileNetworkScope(p.id, scope),
                  ),
                );
              },
            ),
          ),
        );
      }

      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Space.md)),
      );
    }

    if (subs.isNotEmpty) {
      slivers.add(
        const SliverToBoxAdapter(child: SizedBox(height: Space.md)),
      );
    }

    if (standaloneProfiles.isNotEmpty) {
      slivers.add(
        const SliverPadding(
          padding: EdgeInsets.symmetric(horizontal: Space.lg),
          sliver: SliverToBoxAdapter(
            child: SectionLabel('Пользовательские серверы'),
          ),
        ),
      );
      slivers.add(
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          sliver: SliverList.builder(
            itemCount: standaloneProfiles.length,
            itemBuilder: (context, index) {
              final profile = standaloneProfiles[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: Space.sm),
                child: _ProfileTile(
                  controller: controller,
                  profile: profile,
                  selected: profile.id == selectedId,
                  onSelect: () => controller.selectProfile(profile.id),
                  onDelete: () => controller.removeProfile(profile.id),
                  onEdit: () =>
                      _showManualDialog(context, controller, edit: profile),
                  onShare: () => _showQrDialog(context, controller, profile),
                  onPing: () => controller.pingProfile(profile.id),
                  onChangeNetworkScope: (scope) =>
                      controller.setProfileNetworkScope(profile.id, scope),
                  ping: controller.pingOf(profile.id),
                  isPinging: controller.isPinging(profile.id),
                  telemetry: controller.balancerTelemetryOf(profile.id),
                  isBalancerWinner: winnerId == profile.id,
                ),
              );
            },
          ),
        ),
      );
    }

    slivers.add(
      const SliverToBoxAdapter(child: SizedBox(height: Space.xxl)),
    );
    return slivers;
  }

  void _showQrDialog(
    BuildContext context,
    AppController controller,
    Profile profile,
  ) {
    final uri = profile.toShareUri();
    final tokens = context.tokens;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          profile.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrCodeView(data: uri, size: 210),
            const SizedBox(height: Space.md),
            Text(
              uri,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: tokens.muted,
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: uri));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Ссылка профиля скопирована')),
              );
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Копировать'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              controller.shareText(uri, subject: profile.name);
            },
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Поделиться'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleQrScan(
    BuildContext context,
    AppController controller, {
    required bool fromGallery,
    BuildContext? closeDialog,
  }) async {
    if (closeDialog != null && closeDialog.mounted) {
      Navigator.of(closeDialog).pop();
    }
    final added = await controller.scanAndImportQr(fromGallery: fromGallery);
    if (added == null || !context.mounted) return;
    final msg = switch (added) {
      -1 => 'Подписка по QR добавлена — серверы загружены',
      0 => controller.lastError.isNotEmpty
          ? controller.lastError
          : 'QR-код не содержит поддерживаемых ссылок',
      _ => 'Импортировано серверов по QR: $added',
    };
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  /// Диалог импорта: ссылка, содержимое подписки или QR-код.
  Future<void> _showImportDialog(
    BuildContext context,
    AppController controller,
  ) async {
    final textController = TextEditingController();
    final rootContext = context;

    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    final clipText = clip?.text?.trim() ?? '';
    final clipLower = clipText.toLowerCase();
    if (clipText.isNotEmpty &&
        (clipLower.startsWith('http') ||
            clipLower.startsWith('vless://') ||
            clipLower.startsWith('trojan://') ||
            clipLower.startsWith('ss://') ||
            clipLower.startsWith('shadowsocks://') ||
            clipLower.startsWith('vmess://') ||
            clipLower.startsWith('hysteria') ||
            clipLower.startsWith('hy2://') ||
            clipLower.startsWith('tuic://') ||
            clipLower.startsWith('anytls://') ||
            clipLower.startsWith('socks') ||
            clipLower.startsWith('wg://') ||
            clipLower.startsWith('wireguard://') ||
            clipLower.startsWith('amneziawg://') ||
            clipLower.startsWith('awg://') ||
            clipLower.startsWith('naive') ||
            clipLower.startsWith('snell://') ||
            clipLower.startsWith('shadowtls://') ||
            clipLower.startsWith('fptn') ||
            clipLower.startsWith('ssh://') ||
            clipLower.startsWith('mtproto://') ||
            clipLower.startsWith('tg://proxy') ||
            clipLower.startsWith('tewfai://') ||
            clipLower.startsWith('mieru://') ||
            clipLower.startsWith('mierus://') ||
            clipLower.startsWith('masque://') ||
            clipLower.startsWith('trusttunnel://') ||
            clipLower.startsWith('openconnect://') ||
            clipText.contains('[Interface]') ||
            clipText.contains('proxies:') ||
            clipText.startsWith('{'))) {
      textController.text = clipText;
    }

    if (!rootContext.mounted) return;

    await showDialog<void>(
      context: rootContext,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setStateLocal) {
            final currentText = textController.text.trim();
            final isFptn = LinkParser().isFptnPayload(currentText);

            return AlertDialog(
              title: const Text('Импорт подписки, файла или QR'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Отсканируйте QR-код, выберите файл (.conf AmneziaWG 2.0/3.0/3.1, .fptn, .json) '
                      'или вставьте ссылку подписки, токен FPTN или любой URI протокола.',
                      style: Theme.of(dialogContext).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _handleQrScan(
                              rootContext,
                              controller,
                              fromGallery: false,
                              closeDialog: dialogContext,
                            ),
                            icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                            label: const Text('Камера QR'),
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _handleQrScan(
                              rootContext,
                              controller,
                              fromGallery: true,
                              closeDialog: dialogContext,
                            ),
                            icon: const Icon(Icons.photo_library_outlined, size: 18),
                            label: const Text('Из галереи'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await CoreBridge.instance.pickConfigFile();
                          if (picked == null) return;
                          final fileName = picked['name'] ?? '';
                          final fileContent = picked['content'] ?? '';
                          if (fileContent.trim().isEmpty) return;
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          if (!rootContext.mounted) return;
                          if (LinkParser().isFptnPayload(fileContent)) {
                            await showFptnTokenDialog(
                              rootContext,
                              controller,
                              fileContent,
                              initialName: fileName
                                  .replaceAll(
                                    RegExp(r'\.(fptn|json|txt)$', caseSensitive: false),
                                    '',
                                  )
                                  .trim(),
                            );
                            return;
                          }
                          final added = await controller.importProfiles(
                            fileContent,
                            fileName: fileName,
                          );
                          if (!rootContext.mounted) return;
                          final msg = switch (added) {
                            -1 => 'Подписка из файла добавлена — серверы загружены',
                            0 => controller.lastError.isNotEmpty
                                ? controller.lastError
                                : 'Не удалось распознать формат файла',
                            _ => 'Импортировано из файла «$fileName»: $added',
                          };
                          ScaffoldMessenger.maybeOf(rootContext)?.showSnackBar(
                            SnackBar(content: Text(msg)),
                          );
                        },
                        icon: const Icon(Icons.folder_open_rounded, size: 18),
                        label: const Text('Выбрать файл (.conf / .fptn / .json)'),
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          Navigator.of(dialogContext).pop();
                          showTvReceiveDialog(rootContext, controller);
                        },
                        icon: const Icon(Icons.tv_rounded, size: 18),
                        label: const Text('Принять с телефона по Wi-Fi (Android TV)'),
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    TextField(
                      controller: textController,
                      maxLines: 5,
                      minLines: 3,
                      autofocus: true,
                      onChanged: (_) => setStateLocal(() {}),
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        hintText: 'https://..., vless://..., fptn:... или [Interface]',
                        suffixIcon: IconButton(
                          tooltip: 'Вставить из буфера',
                          icon: const Icon(Icons.content_paste_rounded),
                          onPressed: () async {
                            final d = await Clipboard.getData(Clipboard.kTextPlain);
                            if (d?.text != null) {
                              setStateLocal(() {
                                textController.text = d!.text!.trim();
                                textController.selection = TextSelection.collapsed(
                                  offset: textController.text.length,
                                );
                              });
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                if (isFptn)
                  OutlinedButton.icon(
                    onPressed: () {
                      final value = textController.text.trim();
                      Navigator.of(dialogContext).pop();
                      showFptnTokenDialog(rootContext, controller, value);
                    },
                    icon: const Icon(Icons.checklist_rounded, size: 16),
                    label: const Text('Выбрать серверы…'),
                  ),
                FilledButton(
                  onPressed: () async {
                    final value = textController.text.trim();
                    if (value.isEmpty) return;
                    Navigator.of(dialogContext).pop();

                    final added = await controller.importProfiles(value);
                    if (!rootContext.mounted) return;

                    final msg = switch (added) {
                      -1 => 'Подписка добавлена — профили загружены',
                      0 => controller.lastError.isNotEmpty
                          ? controller.lastError
                          : 'Ничего не распознано',
                      _ => isFptn
                          ? 'Группа FPTN обновлена: $added серверов'
                          : 'Добавлено профилей: $added',
                    };
                    ScaffoldMessenger.maybeOf(rootContext)?.showSnackBar(
                      SnackBar(content: Text(msg)),
                    );
                  },
                  child: Text(isFptn ? 'Импортировать все' : 'Импортировать'),
                ),
              ],
            );
          },
        );
      },
    );
    textController.dispose();
  }

  /// Полноценный диалог добавления/редактирования сервера со всеми протоколами tachyon-core.
  Future<void> _showManualDialog(
    BuildContext context,
    AppController controller, {
    Profile? edit,
  }) async {
    final existingTls = edit?.extra['tls'] is Map
        ? Map<String, Object?>.from(edit!.extra['tls']! as Map)
        : <String, Object?>{};
    final existingReality = existingTls['reality'] is Map
        ? Map<String, Object?>.from(existingTls['reality']! as Map)
        : <String, Object?>{};
    final existingUtls = existingTls['utls'] is Map
        ? Map<String, Object?>.from(existingTls['utls']! as Map)
        : <String, Object?>{};
    final existingTransport = edit?.extra['transport'] is Map
        ? Map<String, Object?>.from(edit!.extra['transport']! as Map)
        : <String, Object?>{};
    final existingObfs = edit?.extra['obfs'] is Map
        ? Map<String, Object?>.from(edit!.extra['obfs']! as Map)
        : <String, Object?>{};

    var type = edit?.type ?? 'vless';
    const allowedTypes = [
      'vless',
      'vmess',
      'trojan',
      'shadowsocks',
      'hysteria2',
      'hysteria',
      'tuic',
      'wireguard',
      'anytls',
      'naive',
      'snell',
      'shadowtls',
      'fptn',
      'socks',
      'http',
      'ssh',
      'mtproto',
      'masque',
      'mieru',
      'trusttunnel',
      'openconnect',
    ];
    if (!allowedTypes.contains(type)) type = 'vless';

    var security = 'none';
    if (existingReality['enabled'] == true || (edit?.isReality ?? false)) {
      security = 'reality';
    } else if (existingTls['enabled'] == true ||
        (edit?.sni.isNotEmpty ?? false) ||
        edit?.extra['security'] == 'tls') {
      security = 'tls';
    } else if (edit == null && type == 'vless') {
      security = 'reality';
    } else if (edit == null &&
        const {'trojan', 'hysteria2', 'hysteria', 'tuic', 'anytls', 'naive', 'shadowtls'}
            .contains(type)) {
      security = 'tls';
    }

    var transport = (existingTransport['type'] as String?) ?? edit?.transport ?? 'tcp';
    const allowedTransports = ['tcp', 'xhttp', 'ws', 'grpc', 'httpupgrade', 'http', 'quic'];
    if (!allowedTransports.contains(transport)) transport = 'tcp';

    final name = TextEditingController(text: edit?.name ?? '');
    final address = TextEditingController(
      text: edit != null ? '${edit.server}:${edit.port}' : '',
    );
    final uuid = TextEditingController(text: edit?.uuid ?? '');
    final username = TextEditingController(
      text: (edit?.extra['username'] ?? edit?.extra['user'] ?? '').toString(),
    );
    final password = TextEditingController(
      text: edit?.password.isNotEmpty == true
          ? edit!.password
          : (edit?.extra['private_key'] ?? edit?.extra['psk'] ?? edit?.extra['secret'] ?? '')
              .toString(),
    );
    final method = TextEditingController(
      text: (edit?.method.isNotEmpty ?? false) ? edit!.method : '2022-blake3-aes-128-gcm',
    );
    final vmessSecurity = TextEditingController(
      text: (edit?.extra['vmess_security'] ?? 'auto').toString(),
    );
    final flow = TextEditingController(text: edit?.flow ?? '');
    final sni = TextEditingController(
      text: (existingTls['server_name'] as String?) ?? edit?.sni ?? '',
    );
    final pbk = TextEditingController(
      text: (existingReality['public_key'] as String?) ??
          (edit?.extra['peer_public_key'] as String?) ??
          edit?.publicKey ??
          '',
    );
    final sid = TextEditingController(
      text: (existingReality['short_id'] as String?) ?? edit?.shortId ?? '',
    );
    final fp = TextEditingController(
      text: (existingUtls['fingerprint'] as String?) ??
          (edit?.extra['fp'] as String?) ??
          'chrome',
    );
    final path = TextEditingController(
      text: (existingTransport['path'] as String?) ??
          (existingTransport['service_name'] as String?) ??
          '',
    );
    final hostHeader = TextEditingController(
      text: (existingTransport['host'] is List &&
              (existingTransport['host'] as List).isNotEmpty)
          ? '${(existingTransport['host'] as List).first}'
          : ((existingTransport['host'] as String?) ?? ''),
    );
    final xhttpMode = TextEditingController(
      text: (existingTransport['mode'] as String?) ?? 'auto',
    );
    final hy2ObfsPw = TextEditingController(
      text: (existingObfs['password'] ?? edit?.extra['obfs-password'] ?? '').toString(),
    );
    final hy2Mport = TextEditingController(
      text: edit?.extra['server_ports'] is List
          ? (edit!.extra['server_ports'] as List).join(',')
          : '',
    );
    final tuicCc = TextEditingController(
      text: (edit?.extra['congestion_control'] ?? 'bbr').toString(),
    );
    final wgLocalIp = TextEditingController(
      text: edit?.extra['local_address'] is List &&
              (edit!.extra['local_address'] as List).isNotEmpty
          ? (edit.extra['local_address'] as List).join(',')
          : '10.0.0.2/32',
    );
    final wgMtu = TextEditingController(
      text: (edit?.extra['mtu'] ?? '1420').toString(),
    );
    final wgKeepalive = TextEditingController(
      text: (edit?.extra['persistent_keepalive_interval'] ?? '').toString(),
    );
    final awgJc = TextEditingController(text: (edit?.extra['jc'] ?? '').toString());
    final awgJmin = TextEditingController(text: (edit?.extra['jmin'] ?? '').toString());
    final awgJmax = TextEditingController(text: (edit?.extra['jmax'] ?? '').toString());
    final awgS1 = TextEditingController(text: (edit?.extra['s1'] ?? '').toString());
    final awgS2 = TextEditingController(text: (edit?.extra['s2'] ?? '').toString());
    final awgS3 = TextEditingController(text: (edit?.extra['s3'] ?? '').toString());
    final awgS4 = TextEditingController(text: (edit?.extra['s4'] ?? '').toString());
    final awgH1 = TextEditingController(text: (edit?.extra['h1'] ?? '').toString());
    final awgH2 = TextEditingController(text: (edit?.extra['h2'] ?? '').toString());
    final awgH3 = TextEditingController(text: (edit?.extra['h3'] ?? '').toString());
    final awgH4 = TextEditingController(text: (edit?.extra['h4'] ?? '').toString());
    final awgI1 = TextEditingController(text: (edit?.extra['i1'] ?? '').toString());
    final awgI2 = TextEditingController(text: (edit?.extra['i2'] ?? '').toString());
    final awgI3 = TextEditingController(text: (edit?.extra['i3'] ?? '').toString());
    final awgI4 = TextEditingController(text: (edit?.extra['i4'] ?? '').toString());
    final awgI5 = TextEditingController(text: (edit?.extra['i5'] ?? '').toString());
    final awgHpk = TextEditingController(
      text: (edit?.extra['header_protection_key'] ?? '').toString(),
    );
    final awgCpa = TextEditingController(
      text: (edit?.extra['content_padding_addition'] ?? '').toString(),
    );
    final awgId = TextEditingController(text: (edit?.extra['id'] ?? '').toString());
    final awgIp = TextEditingController(text: (edit?.extra['ip'] ?? '').toString());
    final awgIb = TextEditingController(text: (edit?.extra['ib'] ?? '').toString());
    var awgRandomTrailers = edit?.extra['random_trailers'] == true;
    var awgDisableCookies = edit?.extra['disable_cookies'] == true;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            final hasStreamTransport = const {'vless', 'vmess', 'trojan'}.contains(type);
            final hasTlsConfig = !const {
              'wireguard',
              'shadowsocks',
              'socks',
              'ssh',
              'snell',
              'mtproto',
              'mieru',
            }.contains(type);
            final needsUsername = const {
              'naive',
              'socks',
              'http',
              'ssh',
              'fptn',
              'mieru',
              'trusttunnel',
              'openconnect',
            }.contains(type);

            return AlertDialog(
              title: Text(edit != null ? 'Редактировать сервер' : 'Новый сервер'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: type,
                        decoration: const InputDecoration(labelText: 'Протокол'),
                        items: const [
                          DropdownMenuItem(value: 'vless', child: Text('VLESS (XTLS / Reality / XHTTP)')),
                          DropdownMenuItem(value: 'tewfai', child: Text('TewFai (QUIC + TCP / PQC)')),
                          DropdownMenuItem(value: 'vmess', child: Text('VMess (V2Ray / Xray)')),
                          DropdownMenuItem(value: 'trojan', child: Text('Trojan')),
                          DropdownMenuItem(value: 'shadowsocks', child: Text('Shadowsocks / SS-2022')),
                          DropdownMenuItem(value: 'hysteria2', child: Text('Hysteria 2 (QUIC)')),
                          DropdownMenuItem(value: 'hysteria', child: Text('Hysteria v1')),
                          DropdownMenuItem(value: 'tuic', child: Text('TUIC v5 (QUIC)')),
                          DropdownMenuItem(value: 'wireguard', child: Text('WireGuard / AmneziaWG')),
                          DropdownMenuItem(value: 'anytls', child: Text('AnyTLS')),
                          DropdownMenuItem(value: 'naive', child: Text('NaiveProxy (HTTPS / QUIC)')),
                          DropdownMenuItem(value: 'snell', child: Text('Snell v4/v5')),
                          DropdownMenuItem(value: 'shadowtls', child: Text('ShadowTLS v3')),
                          DropdownMenuItem(value: 'fptn', child: Text('FPTN')),
                          DropdownMenuItem(value: 'masque', child: Text('Cloudflare MASQUE (HTTP/3)')),
                          DropdownMenuItem(value: 'mieru', child: Text('Mieru')),
                          DropdownMenuItem(value: 'trusttunnel', child: Text('TrustTunnel')),
                          DropdownMenuItem(value: 'openconnect', child: Text('OpenConnect (AnyConnect)')),
                          DropdownMenuItem(value: 'mtproto', child: Text('Telegram MTProto')),
                          DropdownMenuItem(value: 'ssh', child: Text('SSH Tunnel')),
                          DropdownMenuItem(value: 'socks', child: Text('SOCKS4 / SOCKS5')),
                          DropdownMenuItem(value: 'http', child: Text('HTTP / HTTPS Proxy')),
                        ],
                        onChanged: (value) => setState(() {
                          type = value ?? type;
                          if (const {
                                'hysteria2',
                                'hysteria',
                                'tuic',
                                'anytls',
                                'naive',
                                'shadowtls',
                                'tewfai',
                              }.contains(type) &&
                              security == 'none') {
                            security = 'tls';
                          }
                        }),
                      ),
                      const SizedBox(height: Space.sm),
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: 'Название'),
                      ),
                      const SizedBox(height: Space.sm),
                      TextField(
                        controller: address,
                        decoration: InputDecoration(
                          labelText: edit == null
                              ? 'Адрес:порт или ссылка https:// подписки'
                              : 'Адрес и порт',
                          hintText: type == 'wireguard'
                              ? 'engage.cloudflareclient.com:2408'
                              : 'https://... или example.com:443',
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      if (type == 'vless' || type == 'vmess' || type == 'tuic' || type == 'tewfai') ...[
                        TextField(
                          controller: uuid,
                          decoration: const InputDecoration(labelText: 'UUID'),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (needsUsername) ...[
                        TextField(
                          controller: username,
                          decoration: const InputDecoration(labelText: 'Имя пользователя (Username)'),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type != 'vless' && type != 'vmess') ...[
                        TextField(
                          controller: password,
                          decoration: InputDecoration(
                            labelText: switch (type) {
                              'wireguard' || 'masque' => 'Приватный ключ клиента (Private Key)',
                              'snell' => 'Ключ PSK',
                              'mtproto' => 'Секрет MTProto (hex / dd...)',
                              _ => 'Пароль / ключ',
                            },
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                       if (type == 'wireguard' || type == 'masque') ...[
                        if (type == 'wireguard') ...[
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                final picked = await CoreBridge.instance.pickConfigFile();
                                if (picked == null) return;
                                final fileName = (picked['name'] ?? '')
                                    .replaceAll(RegExp(r'\.(conf|txt)$', caseSensitive: false), '')
                                    .trim();
                                final content = picked['content'] ?? '';
                                final parsedList = LinkParser().parseWireGuardConfAll(
                                  content,
                                  nameOverride: fileName.isNotEmpty ? fileName : null,
                                );
                                if (parsedList.isEmpty) return;
                                final p = parsedList.first;
                                setState(() {
                                  if (name.text.trim().isEmpty || fileName.isNotEmpty) {
                                    name.text = p.name;
                                  }
                                  address.text = '${p.server}:${p.port}';
                                  password.text = (p.extra['private_key'] ?? p.password).toString();
                                  pbk.text = (p.extra['peer_public_key'] ?? p.publicKey).toString();
                                  if (p.extra['local_address'] is List &&
                                      (p.extra['local_address'] as List).isNotEmpty) {
                                    wgLocalIp.text = (p.extra['local_address'] as List).join(',');
                                  }
                                  wgMtu.text = (p.extra['mtu'] ?? '1280').toString();
                                  wgKeepalive.text =
                                      (p.extra['persistent_keepalive_interval'] ?? '').toString();
                                  awgJc.text = (p.extra['jc'] ?? '').toString();
                                  awgJmin.text = (p.extra['jmin'] ?? '').toString();
                                  awgJmax.text = (p.extra['jmax'] ?? '').toString();
                                  awgS1.text = (p.extra['s1'] ?? '').toString();
                                  awgS2.text = (p.extra['s2'] ?? '').toString();
                                  awgS3.text = (p.extra['s3'] ?? '').toString();
                                  awgS4.text = (p.extra['s4'] ?? '').toString();
                                  awgH1.text = (p.extra['h1'] ?? '').toString();
                                  awgH2.text = (p.extra['h2'] ?? '').toString();
                                  awgH3.text = (p.extra['h3'] ?? '').toString();
                                  awgH4.text = (p.extra['h4'] ?? '').toString();
                                  awgI1.text = (p.extra['i1'] ?? '').toString();
                                  awgI2.text = (p.extra['i2'] ?? '').toString();
                                  awgI3.text = (p.extra['i3'] ?? '').toString();
                                  awgI4.text = (p.extra['i4'] ?? '').toString();
                                  awgI5.text = (p.extra['i5'] ?? '').toString();
                                  awgHpk.text =
                                      (p.extra['header_protection_key'] ?? '').toString();
                                  awgCpa.text =
                                      (p.extra['content_padding_addition'] ?? '').toString();
                                  awgId.text = (p.extra['id'] ?? '').toString();
                                  awgIp.text = (p.extra['ip'] ?? '').toString();
                                  awgIb.text = (p.extra['ib'] ?? '').toString();
                                  awgRandomTrailers = p.extra['random_trailers'] == true;
                                  awgDisableCookies = p.extra['disable_cookies'] == true;
                                });
                              },
                              icon: const Icon(Icons.folder_open_rounded, size: 17),
                              label: const Text(
                                'Загрузить из .conf файла (AmneziaWG 1.5 / 2.0 / 3.0 / 3.1)',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(height: Space.sm),
                        ],
                        TextField(
                          controller: pbk,
                          decoration: const InputDecoration(
                            labelText: 'Публичный ключ сервера (Peer Public Key)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: wgLocalIp,
                                decoration: const InputDecoration(
                                  labelText: 'Локальный IP (CIDR)',
                                  hintText: '10.0.0.2/32',
                                ),
                              ),
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: TextField(
                                controller: wgMtu,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(labelText: 'MTU'),
                              ),
                            ),
                            if (type == 'wireguard') ...[
                              const SizedBox(width: Space.sm),
                              Expanded(
                                child: TextField(
                                  controller: wgKeepalive,
                                  decoration: const InputDecoration(
                                    labelText: 'Keepalive',
                                    hintText: '25 / 15-30',
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (type == 'wireguard') ...[
                          const SizedBox(height: Space.sm),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text(
                              'Параметры AmneziaWG 1.5 / 2.0 / 3.0 / 3.1',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgJc,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'Jc'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgJmin,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'Jmin'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgJmax,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'Jmax'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgS1,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'S1'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgS2,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'S2'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgS3,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'S3 (v2.0+)'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgS4,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(labelText: 'S4 (v2.0+)'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgH1,
                                      decoration: const InputDecoration(
                                        labelText: 'H1',
                                        hintText: 'число / min-max',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH2,
                                      decoration: const InputDecoration(
                                        labelText: 'H2',
                                        hintText: 'число / min-max',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH3,
                                      decoration: const InputDecoration(
                                        labelText: 'H3',
                                        hintText: 'число / min-max',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH4,
                                      decoration: const InputDecoration(
                                        labelText: 'H4',
                                        hintText: 'число / min-max',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              TextField(
                                controller: awgI1,
                                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                decoration: const InputDecoration(
                                  labelText: 'I1 (CPS Signature Packet 1 — AWG 2.0)',
                                  hintText: '<b 0x...><r 16><t><c>',
                                ),
                              ),
                              const SizedBox(height: Space.xs),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgI2,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(labelText: 'I2'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgI3,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(labelText: 'I3'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.xs),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgI4,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(labelText: 'I4'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgI5,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(labelText: 'I5'),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: TextField(
                                      controller: awgHpk,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(
                                        labelText: 'HeaderProtectionKey (AWG 3.0)',
                                        hintText: 'base64 (32 байта)',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgCpa,
                                      keyboardType: TextInputType.number,
                                      decoration: const InputDecoration(
                                        labelText: 'Padding (AWG 3.0)',
                                        hintText: '0..1024',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgIp,
                                      decoration: const InputDecoration(
                                        labelText: 'IP (AWG 3.0)',
                                        hintText: 'dns / stun / sip',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgId,
                                      decoration: const InputDecoration(
                                        labelText: 'ID (DNS ID)',
                                        hintText: 'число / 0x...',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    flex: 2,
                                    child: TextField(
                                      controller: awgIb,
                                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                                      decoration: const InputDecoration(
                                        labelText: 'IB (Payload)',
                                        hintText: 'base64 / hex',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Space.xs),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: const Text(
                                  'RandomTrailers (AWG 3.1)',
                                  style: TextStyle(fontSize: 12.5),
                                ),
                                subtitle: const Text(
                                  'Случайный хвост данных в пакетах рукопожатия',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: awgRandomTrailers,
                                onChanged: (v) => setState(() => awgRandomTrailers = v),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                title: const Text(
                                  'DisableCookies (AWG 3.1)',
                                  style: TextStyle(fontSize: 12.5),
                                ),
                                subtitle: const Text(
                                  'Отключить обработку Cookie Reply',
                                  style: TextStyle(fontSize: 11),
                                ),
                                value: awgDisableCookies,
                                onChanged: (v) => setState(() => awgDisableCookies = v),
                              ),
                            ],
                          ),
                        ],
                      ],
                      if (type == 'shadowsocks') ...[
                        TextField(
                          controller: method,
                          decoration: const InputDecoration(
                            labelText: 'Метод шифрования',
                            hintText: '2022-blake3-aes-128-gcm / chacha20-ietf-poly1305 / aes-256-gcm',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type == 'vmess') ...[
                        TextField(
                          controller: vmessSecurity,
                          decoration: const InputDecoration(
                            labelText: 'Шифрование VMess (auto / aes-128-gcm / chacha20-poly1305 / zero)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type == 'vless') ...[
                        TextField(
                          controller: flow,
                          decoration: const InputDecoration(
                            labelText: 'Flow (например xtls-rprx-vision)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type == 'hysteria2') ...[
                        TextField(
                          controller: hy2ObfsPw,
                          decoration: const InputDecoration(
                            labelText: 'Пароль обфускации Salamander (опционально)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: hy2Mport,
                          decoration: const InputDecoration(
                            labelText: 'Port Hopping (например 20000:30000)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type == 'tuic') ...[
                        TextField(
                          controller: tuicCc,
                          decoration: const InputDecoration(
                            labelText: 'Congestion Control (bbr / cubic / new_reno)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (hasStreamTransport || hasTlsConfig)
                        Row(
                          children: [
                            if (hasStreamTransport)
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  initialValue: transport,
                                  decoration: const InputDecoration(labelText: 'Транспорт'),
                                  items: const [
                                    DropdownMenuItem(value: 'tcp', child: Text('TCP / Raw')),
                                    DropdownMenuItem(value: 'xhttp', child: Text('XHTTP')),
                                    DropdownMenuItem(value: 'ws', child: Text('WebSocket')),
                                    DropdownMenuItem(value: 'grpc', child: Text('gRPC')),
                                    DropdownMenuItem(
                                      value: 'httpupgrade',
                                      child: Text('HTTPUpgrade'),
                                    ),
                                    DropdownMenuItem(value: 'http', child: Text('HTTP/2 (H2)')),
                                    DropdownMenuItem(value: 'quic', child: Text('QUIC')),
                                  ],
                                  onChanged: (v) =>
                                     setState(() => transport = v ?? transport),
                                ),
                              ),
                            if (hasStreamTransport && hasTlsConfig)
                              const SizedBox(width: Space.sm),
                            if (hasTlsConfig)
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  isExpanded: true,
                                  initialValue: security,
                                  decoration:
                                      const InputDecoration(labelText: 'Безопасность'),
                                  items: const [
                                    DropdownMenuItem(value: 'none', child: Text('Нет')),
                                    DropdownMenuItem(value: 'tls', child: Text('TLS')),
                                    DropdownMenuItem(
                                      value: 'reality',
                                      child: Text('REALITY'),
                                    ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => security = v ?? security),
                                ),
                              ),
                          ],
                        ),
                      if (hasStreamTransport && transport != 'tcp' && transport != 'quic') ...[
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: path,
                          decoration: InputDecoration(
                            labelText:
                                transport == 'grpc' ? 'Service Name' : 'Путь (Path)',
                            hintText: '/',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: hostHeader,
                          decoration: const InputDecoration(
                            labelText: 'Host-заголовок (опционально)',
                          ),
                        ),
                        if (transport == 'xhttp') ...[
                          const SizedBox(height: Space.sm),
                          TextField(
                            controller: xhttpMode,
                            decoration: const InputDecoration(
                              labelText: 'Режим XHTTP (auto / packet-up / stream-one)',
                            ),
                          ),
                        ],
                      ],
                      if (hasTlsConfig && security != 'none') ...[
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: sni,
                          decoration: const InputDecoration(
                            labelText: 'SNI (Server Name)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: fp,
                          decoration: const InputDecoration(
                            labelText: 'uTLS Fingerprint (chrome / firefox / safari / qq)',
                          ),
                        ),
                      ],
                      if (hasTlsConfig && security == 'reality') ...[
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: pbk,
                          decoration: const InputDecoration(
                            labelText: 'REALITY Public Key (pbk)',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                        TextField(
                          controller: sid,
                          decoration: const InputDecoration(
                            labelText: 'REALITY Short ID (sid)',
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton(
                  onPressed: () async {
                    final host = address.text.trim();
                    final hostLower = host.toLowerCase();
                    if (edit == null &&
                        (hostLower.startsWith('https://') ||
                            hostLower.startsWith('http://') ||
                            hostLower.startsWith('vless://') ||
                            hostLower.startsWith('vmess://') ||
                            hostLower.startsWith('trojan://') ||
                            hostLower.startsWith('ss://') ||
                            hostLower.startsWith('hy2://') ||
                            hostLower.startsWith('hysteria2://') ||
                            hostLower.startsWith('tuic://') ||
                            hostLower.startsWith('wg://') ||
                            hostLower.startsWith('amneziawg://'))) {
                      Navigator.of(dialogContext).pop();
                      final added = await controller.importProfiles(host);
                      if (!context.mounted) return;
                      final msg = switch (added) {
                        -1 => 'Подписка по ссылке добавлена — серверы загружены',
                        0 => controller.lastError.isNotEmpty
                            ? controller.lastError
                            : 'Не удалось загрузить серверы по ссылке',
                        _ => 'Добавлено серверов: $added',
                      };
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                        SnackBar(content: Text(msg)),
                      );
                      return;
                    }
                    final separator = host.lastIndexOf(':');
                    final server =
                        separator > 0 ? host.substring(0, separator) : host;
                    final defaultPort = switch (type) {
                      'wireguard' => 51820,
                      'shadowsocks' => 8388,
                      'socks' => 1080,
                      'http' => 8080,
                      'ssh' => 22,
                      _ => 443,
                    };
                    final port = separator > 0
                        ? int.tryParse(host.substring(separator + 1)) ?? defaultPort
                        : defaultPort;

                    final nextExtra = Map<String, Object?>.from(edit?.extra ?? const {});
                    nextExtra['security'] = hasTlsConfig ? security : 'none';
                    if (fp.text.trim().isNotEmpty && hasTlsConfig && security != 'none') {
                      nextExtra['fp'] = fp.text.trim();
                    }

                    if (!hasStreamTransport || transport == 'tcp') {
                      nextExtra.remove('transport');
                    } else {
                      final tr = Map<String, Object?>.from(existingTransport);
                      tr['type'] = transport;
                      if (transport == 'grpc') {
                        if (path.text.trim().isNotEmpty) {
                          tr['service_name'] = path.text.trim();
                        }
                      } else {
                        if (path.text.trim().isNotEmpty) {
                          tr['path'] = path.text.trim();
                        }
                      }
                      if (hostHeader.text.trim().isNotEmpty) {
                        tr['host'] = hostHeader.text.trim();
                      }
                      if (transport == 'xhttp' && xhttpMode.text.trim().isNotEmpty) {
                        tr['mode'] = xhttpMode.text.trim();
                      }
                      nextExtra['transport'] = tr;
                    }

                    if (needsUsername && username.text.trim().isNotEmpty) {
                      final key = (type == 'ssh' || type == 'openconnect') ? 'user' : 'username';
                      nextExtra[key] = username.text.trim();
                    }
                    if (type == 'vmess') {
                      nextExtra['vmess_security'] =
                          vmessSecurity.text.trim().isEmpty ? 'auto' : vmessSecurity.text.trim();
                    }
                    if (type == 'hysteria2') {
                      if (hy2ObfsPw.text.trim().isNotEmpty) {
                        nextExtra['obfs'] = {
                          'type': 'salamander',
                          'password': hy2ObfsPw.text.trim(),
                        };
                      } else {
                        nextExtra.remove('obfs');
                      }
                      if (hy2Mport.text.trim().isNotEmpty) {
                        nextExtra['server_ports'] = hy2Mport.text
                            .split(',')
                            .map((s) => s.trim().replaceAll('-', ':'))
                            .where((s) => s.isNotEmpty)
                            .toList();
                      }
                    }
                    if (type == 'tuic' && tuicCc.text.trim().isNotEmpty) {
                      nextExtra['congestion_control'] = tuicCc.text.trim();
                    }
                    if (type == 'wireguard' || type == 'masque') {
                      nextExtra['private_key'] = password.text.trim();
                      nextExtra['peer_public_key'] = pbk.text.trim();
                      final addrs = wgLocalIp.text
                          .split(',')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList();
                      nextExtra['local_address'] =
                          addrs.isEmpty ? ['10.0.0.2/32'] : addrs;
                      final mtuVal = int.tryParse(wgMtu.text.trim());
                      if (mtuVal != null && mtuVal > 0) nextExtra['mtu'] = mtuVal;
                      if (type == 'wireguard') {
                        void setAwgInt(String k, String raw) {
                          final v = int.tryParse(raw.trim());
                          if (v != null) {
                            nextExtra[k] = v;
                          } else {
                            nextExtra.remove(k);
                          }
                        }

                        void setAwgHeader(String k, String raw) {
                          final s = raw.trim();
                          if (s.isEmpty) {
                            nextExtra.remove(k);
                          } else {
                            nextExtra[k] = int.tryParse(s) ?? s;
                          }
                        }

                        setAwgInt('jc', awgJc.text);
                        setAwgInt('jmin', awgJmin.text);
                        setAwgInt('jmax', awgJmax.text);
                        setAwgInt('s1', awgS1.text);
                        setAwgInt('s2', awgS2.text);
                        setAwgInt('s3', awgS3.text);
                        setAwgInt('s4', awgS4.text);
                        setAwgHeader('h1', awgH1.text);
                        setAwgHeader('h2', awgH2.text);
                        setAwgHeader('h3', awgH3.text);
                        setAwgHeader('h4', awgH4.text);
                        setAwgHeader('persistent_keepalive_interval', wgKeepalive.text);

                        void setAwgStr(String k, String raw) {
                          final s = raw.trim();
                          if (s.isEmpty) {
                            nextExtra.remove(k);
                          } else {
                            nextExtra[k] = s;
                          }
                        }

                        setAwgStr('i1', awgI1.text);
                        setAwgStr('i2', awgI2.text);
                        setAwgStr('i3', awgI3.text);
                        setAwgStr('i4', awgI4.text);
                        setAwgStr('i5', awgI5.text);
                        setAwgStr('header_protection_key', awgHpk.text);
                        setAwgInt('content_padding_addition', awgCpa.text);
                        setAwgHeader('id', awgId.text);
                        setAwgStr('ip', awgIp.text);
                        setAwgStr('ib', awgIb.text);
                        if (awgRandomTrailers) {
                          nextExtra['random_trailers'] = true;
                        } else {
                          nextExtra.remove('random_trailers');
                        }
                        if (awgDisableCookies) {
                          nextExtra['disable_cookies'] = true;
                        } else {
                          nextExtra.remove('disable_cookies');
                        }
                      }
                    }

                    Navigator.of(dialogContext).pop();
                    final profile = Profile(
                      id: edit?.id ??
                          '$type-$server-$port-${DateTime.now().millisecondsSinceEpoch}',
                      name: name.text.trim().isEmpty
                          ? '$server:$port'
                          : name.text.trim(),
                      type: type,
                      server: server,
                      port: port,
                      uuid: uuid.text.trim(),
                      password: password.text.trim(),
                      method: type == 'shadowsocks' ? method.text.trim() : '',
                      transport: hasStreamTransport ? transport : 'tcp',
                      flow: flow.text.trim(),
                      sni: sni.text.trim(),
                      publicKey: pbk.text.trim(),
                      shortId: sid.text.trim(),
                      subscriptionId: edit?.subscriptionId ?? '',
                      extra: nextExtra,
                    );
                    await controller.addProfile(profile);
                  },
                  child: Text(edit != null ? 'Сохранить' : 'Добавить'),
                ),
              ],
            );
          },
        );
      },
    );

    for (final c in [
      name,
      address,
      uuid,
      username,
      password,
      method,
      vmessSecurity,
      flow,
      sni,
      pbk,
      sid,
      fp,
      path,
      hostHeader,
      xhttpMode,
      hy2ObfsPw,
      hy2Mport,
      tuicCc,
      wgLocalIp,
      wgMtu,
      wgKeepalive,
      awgJc,
      awgJmin,
      awgJmax,
      awgS1,
      awgS2,
      awgS3,
      awgS4,
      awgH1,
      awgH2,
      awgH3,
      awgH4,
      awgI1,
      awgI2,
      awgI3,
      awgI4,
      awgI5,
      awgHpk,
      awgCpa,
      awgId,
      awgIp,
      awgIb,
    ]) {
      c.dispose();
    }
  }
}

/// Плитка профиля: имя, адрес, тип, пинг, телеметрия балансировщика и компактное меню действий.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    this.controller,
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
    required this.onEdit,
    required this.onShare,
    this.onPing,
    this.onChangeNetworkScope,
    this.ping,
    this.isPinging = false,
    this.telemetry,
    this.isBalancerWinner = false,
  });

  final AppController? controller;
  final Profile profile;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback? onPing;
  final void Function(String scope)? onChangeNetworkScope;
  final int? ping;
  final bool isPinging;
  final BalancerNodeTelemetry? telemetry;
  final bool isBalancerWinner;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tel = telemetry;
    final scope = profile.networkScope;
    final telSuffix = tel == null
        ? ''
        : tel.quarantined
            ? ' · КАРАНТИН'
            : (tel.jitterMs > 0 || tel.activeConns > 0)
                ? ' · ±${tel.jitterMs}ms${tel.activeConns > 0 ? ' · ${tel.activeConns} сесс.' : ''}'
                : '';

    return HairlineCard(
      onTap: onSelect,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: selected
                  ? tokens.accent
                  : isBalancerWinner
                      ? tokens.success
                      : tokens.line,
            ),
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: selected
                                  ? tokens.accent
                                  : isBalancerWinner
                                      ? tokens.success
                                      : tokens.ink,
                            ),
                      ),
                    ),
                    if (scope != 'all') ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: tokens.accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: tokens.accent.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          scope == 'wifi' ? 'Wi-Fi' : 'LTE',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            color: tokens.accent,
                          ),
                        ),
                      ),
                    ],
                    if (isBalancerWinner && !selected) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: tokens.success.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(3),
                          border: Border.all(color: tokens.success.withValues(alpha: 0.35)),
                        ),
                        child: Text(
                          'АКТИВЕН',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            fontFamily: 'monospace',
                            color: tokens.success,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.fullTransportLabel} · ${profile.server}:${profile.port}$telSuffix',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: tel?.quarantined == true ? tokens.danger : tokens.faint,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.xs),
          ValueListenableBuilder<int>(
            valueListenable:
                controller?.serverRevisionOf(profile.id) ?? ValueNotifier<int>(0),
            builder: (context, _, _) {
              final livePing = controller?.pingOf(profile.id) ?? ping;
              final livePinging = controller?.isPinging(profile.id) ?? isPinging;
              return FocusableTap(
                borderRadius: BorderRadius.circular(4),
                onTap: onPing,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: tokens.raised,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: tokens.line),
                  ),
                  child: livePinging
                      ? SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: tokens.accent,
                          ),
                        )
                      : livePing == null
                          ? Icon(Icons.network_ping, size: 14, color: tokens.faint)
                          : Text(
                              livePing < 0 ? '✗' : '${livePing}ms',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                fontFamily: 'monospace',
                                color: livePing < 0
                                    ? tokens.danger
                                    : livePing < 150
                                        ? tokens.success
                                        : livePing < 400
                                            ? tokens.warning
                                            : tokens.danger,
                              ),
                            ),
                ),
              );
            },
          ),
          const SizedBox(width: 2),
          PopupMenuButton<String>(
            tooltip: 'Действия с сервером',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 196),
            icon: SizedBox(
              width: 28,
              height: 28,
              child: Icon(Icons.more_vert_rounded, size: 18, color: tokens.muted),
            ),
            onSelected: (action) {
              switch (action) {
                case 'ping':
                  onPing?.call();
                case 'share':
                  onShare();
                case 'edit':
                  onEdit();
                case 'scope:all':
                  onChangeNetworkScope?.call('all');
                case 'scope:wifi':
                  onChangeNetworkScope?.call('wifi');
                case 'scope:cellular':
                  onChangeNetworkScope?.call('cellular');
                case 'delete':
                  onDelete();
              }
            },
            itemBuilder: (ctx) => [
              if (onPing != null)
                const PopupMenuItem<String>(
                  value: 'ping',
                  child: Row(
                    children: [
                      Icon(Icons.network_ping, size: 17),
                      SizedBox(width: 10),
                      Text('Проверить задержку'),
                    ],
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'share',
                child: Row(
                  children: [
                    Icon(Icons.qr_code_2, size: 17),
                    SizedBox(width: 10),
                    Text('QR-код / Поделиться'),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 17),
                    SizedBox(width: 10),
                    Text('Редактировать'),
                  ],
                ),
              ),
              if (onChangeNetworkScope != null) ...[
                const PopupMenuDivider(),
                PopupMenuItem<String>(
                  value: 'scope:all',
                  child: Row(
                    children: [
                      Icon(
                        scope == 'all'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: scope == 'all' ? tokens.accent : tokens.muted,
                      ),
                      const SizedBox(width: 10),
                      const Text('Сеть: Все сети'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'scope:wifi',
                  child: Row(
                    children: [
                      Icon(
                        scope == 'wifi'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: scope == 'wifi' ? tokens.accent : tokens.muted,
                      ),
                      const SizedBox(width: 10),
                      const Text('Сеть: Только Wi-Fi'),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'scope:cellular',
                  child: Row(
                    children: [
                      Icon(
                        scope == 'cellular'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        size: 16,
                        color: scope == 'cellular' ? tokens.accent : tokens.muted,
                      ),
                      const SizedBox(width: 10),
                      const Text('Сеть: Мобильная (LTE)'),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
              ],
              PopupMenuItem<String>(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(Icons.delete_outline, size: 17, color: tokens.danger),
                    const SizedBox(width: 10),
                    Text('Удалить', style: TextStyle(color: tokens.danger)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Плитка интеллектуального балансировщика tachyon-core 0.3.9 (для подписки или всех серверов).
class _AutoBalancerTile extends StatelessWidget {
  const _AutoBalancerTile({
    required this.title,
    required this.selected,
    required this.controller,
    required this.onSelect,
    required this.onConfigure,
  });

  final String title;
  final bool selected;
  final AppController controller;
  final VoidCallback onSelect;
  final VoidCallback onConfigure;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final balancer = controller.settings.balancer;
    final modeOpt = balancer.modeOption;
    final winner = selected ? controller.activeBalancerWinner : null;
    final winnerTel = winner != null ? controller.balancerTelemetryOf(winner.id) : null;
    final hasScoped = controller.settings.visibleSubscriptions.any((s) => s.networkScope != 'all') ||
        controller.settings.visibleProfiles.any((p) => p.networkScope != 'all');
    final netType = controller.activeNetworkType;
    final netLabel = netType == 'wifi'
        ? 'Wi-Fi'
        : (netType == 'cellular' ? 'LTE' : '');
    final activeCount = (selected && hasScoped && controller.selectedProfile != null)
        ? RuntimeConfig.resolveAutoCandidates(
            controller.selectedProfile!,
            controller.settings.visibleProfiles,
            activeNetworkType: netType,
            subscriptions: controller.settings.visibleSubscriptions,
            balancer: balancer,
          ).length
        : 0;
    final netSuffix = (selected && hasScoped && netLabel.isNotEmpty && activeCount > 0)
        ? ' · Сеть: $netLabel ($activeCount серв.)'
        : '';

    final subtitle = winner != null
        ? 'Активен: ${winner.name}${winnerTel != null && winnerTel.ewmaRttMs > 0 ? ' (${winnerTel.ewmaRttMs}ms ±${winnerTel.jitterMs}ms)' : ''}$netSuffix · ${modeOpt.title}'
        : '${modeOpt.title} · пул Top-${balancer.pool}$netSuffix · ${modeOpt.subtitle}';

    return HairlineCard(
      onTap: onSelect,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.bolt_rounded,
            size: 18,
            color: selected ? tokens.accent : tokens.muted,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: selected ? tokens.accent : tokens.ink,
                            ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: selected
                            ? tokens.accent.withValues(alpha: 0.14)
                            : tokens.raised,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: selected
                              ? tokens.accent.withValues(alpha: 0.4)
                              : tokens.line,
                        ),
                      ),
                      child: Text(
                        modeOpt.shortBadge,
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                          color: selected ? tokens.accent : tokens.muted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: winner != null ? tokens.success : tokens.faint,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.xs),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            tooltip: 'Алгоритм и параметры балансировщика',
            onPressed: onConfigure,
            icon: Icon(
              Icons.tune_rounded,
              size: 17,
              color: selected ? tokens.accent : tokens.muted,
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _showEditSubDialog(
  BuildContext context,
  AppController controller,
  SubscriptionEntry sub,
) async {
  final nameCtrl = TextEditingController(text: sub.name);
  final urlCtrl = TextEditingController(text: sub.url);
  final hwidCtrl = TextEditingController(text: sub.customHwid);
  final countriesCtrl = TextEditingController(text: sub.excludedCountries.join(', '));
  final includeRegexCtrl = TextEditingController(text: sub.includeRegex);
  final excludeRegexCtrl = TextEditingController(text: sub.excludeRegex);
  final globalHwid = controller.effectiveHwid;
  var selectedScope = sub.networkScope;
  var selectedAutoHours = sub.autoUpdateHours;
  final selectedExProtos = <String>{...sub.excludedProtocols};

  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setStateDialog) {
        final tokens = ctx.tokens;
        final shortGlobalHwid = globalHwid.length > 12
            ? '${globalHwid.substring(0, 12)}…'
            : globalHwid;

        return AlertDialog(
          title: const Text('Редактировать подписку'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Название (опционально)',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    controller: urlCtrl,
                    maxLines: 3,
                    minLines: 1,
                    decoration: const InputDecoration(
                      labelText: 'Ссылка на подписку',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    controller: hwidCtrl,
                    style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                    onChanged: (_) => setStateDialog(() {}),
                    decoration: InputDecoration(
                      labelText: 'HWID подписки (X-HWID)',
                      hintText: globalHwid,
                      helperText: hwidCtrl.text.trim().isEmpty
                          ? 'По умолчанию: общий HWID ($shortGlobalHwid)'
                          : 'Индивидуальный HWID для этой подписки',
                      helperMaxLines: 2,
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Сгенерировать новый случайный HWID',
                            icon: const Icon(Icons.casino_outlined, size: 19),
                            onPressed: () {
                              setStateDialog(() {
                                hwidCtrl.text = AppController.generateRandomHwid();
                              });
                            },
                          ),
                          if (hwidCtrl.text.isNotEmpty)
                            IconButton(
                              tooltip: 'Сбросить на общий HWID устройства',
                              icon: const Icon(Icons.restore_rounded, size: 19),
                              onPressed: () {
                                setStateDialog(() {
                                  hwidCtrl.clear();
                                });
                              },
                            )
                          else
                            IconButton(
                              tooltip: 'Скопировать текущий HWID',
                              icon: const Icon(Icons.copy_rounded, size: 17),
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: globalHwid));
                                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                  const SnackBar(content: Text('HWID скопирован в буфер')),
                                );
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Интервал автообновления',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in const [
                        (0, 'По умолч.'),
                        (1, '1 ч'),
                        (3, '3 ч'),
                        (6, '6 ч'),
                        (12, '12 ч'),
                        (24, '24 ч'),
                      ])
                        ChoiceChip(
                          label: Text(item.$2),
                          selected: selectedAutoHours == item.$1,
                          onSelected: (_) =>
                              setStateDialog(() => selectedAutoHours = item.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Сеть для серверов подписки',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Позволяет использовать разные подписки для Wi-Fi и мобильной сети при автовыборе.',
                    style: TextStyle(fontSize: 11, color: tokens.faint),
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final item in const [
                        ('all', 'Все сети', Icons.public_rounded),
                        ('wifi', 'Только Wi-Fi', Icons.wifi_rounded),
                        ('cellular', 'Мобильная сеть', Icons.signal_cellular_alt_rounded),
                      ])
                        ChoiceChip(
                          avatar: Icon(item.$3, size: 15),
                          label: Text(item.$2),
                          selected: selectedScope == item.$1,
                          onSelected: (_) =>
                              setStateDialog(() => selectedScope = item.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Исключить страны из подписки',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in BalancerSettings.commonCountryFilters)
                        Builder(
                          builder: (_) {
                            final currentTokens = countriesCtrl.text
                                .split(',')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList();
                            final isSelected = currentTokens.any(
                              (x) => x.toUpperCase() == c.$1,
                            );
                            return FilterChip(
                              label: Text(
                                '${c.$2} ${c.$1}',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              tooltip: c.$3,
                              selected: isSelected,
                              onSelected: (on) {
                                final next = currentTokens
                                    .where((x) => x.toUpperCase() != c.$1)
                                    .toList();
                                if (on) next.add(c.$1);
                                setStateDialog(() {
                                  countriesCtrl.text = next.join(', ');
                                });
                              },
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: countriesCtrl,
                    onChanged: (_) => setStateDialog(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Коды стран или ключевые слова (через запятую)',
                      hintText: 'Например: RU, KZ, NL, реклама',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Исключить протоколы',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final proto in BalancerSettings.commonProtocolFilters)
                        FilterChip(
                          label: Text(proto.$2, style: const TextStyle(fontSize: 11.5)),
                          selected: selectedExProtos.contains(proto.$1),
                          onSelected: (on) {
                            setStateDialog(() {
                              if (on) {
                                selectedExProtos.add(proto.$1);
                              } else {
                                selectedExProtos.remove(proto.$1);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Фильтр по регулярному выражению (RegExp)',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: includeRegexCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Включить по регулярному выражению / слову',
                      hintText: 'Например: LTE|Whitelist|МТС',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: excludeRegexCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Исключить по регулярному выражению',
                      hintText: 'Например: резерв|тест|expired',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: () async {
                final newUrl = urlCtrl.text.trim();
                final newName = nameCtrl.text.trim();
                final newHwid = hwidCtrl.text.trim();
                final exCountries = countriesCtrl.text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList(growable: false);
                final exProtos = selectedExProtos.toList(growable: false);
                final incRx = includeRegexCtrl.text.trim();
                final excRx = excludeRegexCtrl.text.trim();
                Navigator.of(dialogCtx).pop();
                if (newUrl.isNotEmpty) {
                  await controller.editSubscription(
                    sub.id,
                    url: newUrl,
                    name: newName,
                    customHwid: newHwid,
                    networkScope: selectedScope,
                    excludedCountries: exCountries,
                    excludedProtocols: exProtos,
                    autoUpdateHours: selectedAutoHours,
                    includeRegex: incRx,
                    excludeRegex: excRx,
                  );
                }
              },
              child: const Text('Сохранить и обновить'),
            ),
          ],
        );
      },
    ),
  );
  nameCtrl.dispose();
  urlCtrl.dispose();
  hwidCtrl.dispose();
  countriesCtrl.dispose();
  includeRegexCtrl.dispose();
  excludeRegexCtrl.dispose();
}

/// Диалог создания или редактирования объединённой группы из нескольких подписок (и/или отдельных серверов).
Future<void> showCombinedGroupDialog(
  BuildContext context,
  AppController controller, {
  SubscriptionEntry? existingGroup,
}) async {
  final sourceSubs = controller.settings.visibleSubscriptions
      .where((s) => !s.isCombinedGroup)
      .toList(growable: false);
  final standaloneProfiles = controller.settings.profilesForSubscription('');
  final nameCtrl = TextEditingController(
    text: existingGroup?.name.isNotEmpty == true ? existingGroup!.name : 'Общая группа',
  );
  final countriesCtrl = TextEditingController(
    text: existingGroup?.excludedCountries.join(', ') ?? '',
  );
  final includeRegexCtrl = TextEditingController(
    text: existingGroup?.includeRegex ?? '',
  );
  final excludeRegexCtrl = TextEditingController(
    text: existingGroup?.excludeRegex ?? '',
  );
  var selectedScope = existingGroup?.networkScope ?? 'all';
  final selectedExProtos = <String>{...?existingGroup?.excludedProtocols};
  final selectedMembers = <String>{
    if (existingGroup != null && existingGroup.mergedSubscriptionIds.isNotEmpty)
      ...existingGroup.mergedSubscriptionIds
    else ...[
      for (final s in sourceSubs) s.id,
      if (standaloneProfiles.isNotEmpty) '__standalone__',
    ],
  };

  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (ctx, setStateDialog) {
        final tokens = ctx.tokens;
        return AlertDialog(
          title: Text(
            existingGroup == null
                ? 'Объединить подписки в группу'
                : 'Настроить объединённую группу',
          ),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Объединяет серверы из выбранных подписок в единую группу со своим автовыбором. '
                    'Исходные подписки остаются на месте и продолжают работать как вместе, так и по отдельности.',
                    style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: tokens.muted),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Название группы',
                      hintText: 'Например: Основной пул',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Row(
                    children: [
                      Text(
                        'Включить подписки (${selectedMembers.length})',
                        style: Theme.of(ctx).textTheme.titleSmall,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setStateDialog(() {
                            final totalAvailable = sourceSubs.length +
                                (standaloneProfiles.isNotEmpty ? 1 : 0);
                            if (selectedMembers.length >= totalAvailable) {
                              selectedMembers.clear();
                            } else {
                              for (final s in sourceSubs) {
                                selectedMembers.add(s.id);
                              }
                              if (standaloneProfiles.isNotEmpty) {
                                selectedMembers.add('__standalone__');
                              }
                            }
                          });
                        },
                        child: const Text('Все / Сброс', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: tokens.surface,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tokens.line),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final s in sourceSubs)
                          Builder(
                            builder: (_) {
                              final count = controller.settings.profilesForSubscription(s.id).length;
                              final label = s.name.isNotEmpty
                                  ? s.name
                                  : (s.isFptnToken
                                      ? 'FPTN'
                                      : (Uri.tryParse(s.url)?.host ?? 'Подписка'));
                              return CheckboxListTile(
                                dense: true,
                                controlAffinity: ListTileControlAffinity.leading,
                                value: selectedMembers.contains(s.id),
                                onChanged: (on) {
                                  setStateDialog(() {
                                    if (on == true) {
                                      selectedMembers.add(s.id);
                                    } else {
                                      selectedMembers.remove(s.id);
                                    }
                                  });
                                },
                                title: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                                ),
                                subtitle: Text(
                                  '$count серв.',
                                  style: TextStyle(fontSize: 11, color: tokens.muted),
                                ),
                              );
                            },
                          ),
                        if (standaloneProfiles.isNotEmpty)
                          CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: selectedMembers.contains('__standalone__'),
                            onChanged: (on) {
                              setStateDialog(() {
                                if (on == true) {
                                  selectedMembers.add('__standalone__');
                                } else {
                                  selectedMembers.remove('__standalone__');
                                }
                              });
                            },
                            title: const Text(
                              'Отдельные серверы (без подписки)',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(
                              '${standaloneProfiles.length} серв.',
                              style: TextStyle(fontSize: 11, color: tokens.muted),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Сеть для этой группы',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final opt in const [
                        ('all', 'Все сети', Icons.public_rounded),
                        ('wifi', 'Только Wi-Fi', Icons.wifi_rounded),
                        ('cellular', 'Мобильная (LTE/5G)', Icons.signal_cellular_alt_rounded),
                      ])
                        ChoiceChip(
                          avatar: Icon(opt.$3, size: 15),
                          label: Text(opt.$2, style: const TextStyle(fontSize: 12)),
                          selected: selectedScope == opt.$1,
                          onSelected: (_) => setStateDialog(() => selectedScope = opt.$1),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    'Исключить страны в этой группе',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final c in BalancerSettings.commonCountryFilters)
                        Builder(
                          builder: (_) {
                            final currentTokens = countriesCtrl.text
                                .split(',')
                                .map((s) => s.trim())
                                .where((s) => s.isNotEmpty)
                                .toList();
                            final isSelected = currentTokens.any(
                              (x) => x.toUpperCase() == c.$1,
                            );
                            return FilterChip(
                              label: Text(
                                '${c.$2} ${c.$1}',
                                style: const TextStyle(fontSize: 11.5),
                              ),
                              tooltip: c.$3,
                              selected: isSelected,
                              onSelected: (on) {
                                final next = currentTokens
                                    .where((x) => x.toUpperCase() != c.$1)
                                    .toList();
                                if (on) next.add(c.$1);
                                setStateDialog(() {
                                  countriesCtrl.text = next.join(', ');
                                });
                              },
                            );
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: countriesCtrl,
                    onChanged: (_) => setStateDialog(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Коды стран или ключевые слова (через запятую)',
                      hintText: 'Например: RU, KZ, NL',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Исключить протоколы',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final proto in BalancerSettings.commonProtocolFilters)
                        FilterChip(
                          label: Text(proto.$2, style: const TextStyle(fontSize: 11.5)),
                          selected: selectedExProtos.contains(proto.$1),
                          onSelected: (on) {
                            setStateDialog(() {
                              if (on) {
                                selectedExProtos.add(proto.$1);
                              } else {
                                selectedExProtos.remove(proto.$1);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Фильтр по регулярному выражению (RegExp)',
                    style: Theme.of(ctx).textTheme.titleSmall,
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: includeRegexCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Включить по регулярному выражению / слову',
                      hintText: 'Например: LTE|Whitelist|МТС',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: Space.xs),
                  TextField(
                    controller: excludeRegexCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Исключить по регулярному выражению',
                      hintText: 'Например: резерв|тест|expired',
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Отмена'),
            ),
            FilledButton(
              onPressed: selectedMembers.isEmpty
                  ? null
                  : () async {
                      final exCountries = countriesCtrl.text
                          .split(',')
                          .map((s) => s.trim())
                          .where((s) => s.isNotEmpty)
                          .toList(growable: false);
                      final exProtos = selectedExProtos.toList(growable: false);
                      final groupName = nameCtrl.text.trim();
                      final members = selectedMembers.toList(growable: false);
                      final incRx = includeRegexCtrl.text.trim();
                      final excRx = excludeRegexCtrl.text.trim();
                      Navigator.of(dialogCtx).pop();
                      await controller.saveCombinedSubscriptionGroup(
                        existingId: existingGroup?.id,
                        name: groupName,
                        memberIds: members,
                        networkScope: selectedScope,
                        excludedCountries: exCountries,
                        excludedProtocols: exProtos,
                        includeRegex: incRx,
                        excludeRegex: excRx,
                      );
                    },
              child: Text(existingGroup == null ? 'Создать группу' : 'Сохранить'),
            ),
          ],
        );
      },
    ),
  );
  nameCtrl.dispose();
  countriesCtrl.dispose();
  includeRegexCtrl.dispose();
  excludeRegexCtrl.dispose();
}

/// Сворачиваемая карточка заголовка подписки с информацией о трафике и сроке действия.
/// Сами серверы подписки рендерятся лениво через `SliverList.builder` в `ProfilesTab`.
class _CollapsibleSubCard extends StatelessWidget {
  const _CollapsibleSubCard({
    required this.sub,
    required this.controller,
    required this.isCollapsed,
    required this.profiles,
    required this.selectedId,
    required this.onToggleCollapse,
    required this.onToggleSub,
    required this.onRemoveSub,
    required this.onRefreshSub,
    required this.onPingAllSub,
    required this.onSelectProfile,
    required this.onEditSub,
  });

  final SubscriptionEntry sub;
  final AppController controller;
  final bool isCollapsed;
  final List<Profile> profiles;
  final String selectedId;
  final VoidCallback onToggleCollapse;
  final VoidCallback onToggleSub;
  final VoidCallback onRemoveSub;
  final VoidCallback onRefreshSub;
  final VoidCallback onPingAllSub;
  final VoidCallback onEditSub;
  final void Function(String id) onSelectProfile;

  static String _fmtBytes(int b) {
    if (b <= 0) return '0 Б';
    const gb = 1024 * 1024 * 1024;
    const mb = 1024 * 1024;
    if (b >= gb) return '${(b / gb).toStringAsFixed(1)} ГБ';
    if (b >= mb) return '${(b / mb).toStringAsFixed(0)} МБ';
    return '${(b / 1024).toStringAsFixed(0)} КБ';
  }

  static String _fmtExpire(int unixSec) {
    if (unixSec <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final days = dt.difference(DateTime.now()).inDays;
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final y = dt.year;
    if (days < 0) return 'Истекла $d.$m.$y';
    return 'до $d.$m.$y ($days дн.)';
  }

  static String _fmtUpdatedAt(int updatedAtMs) {
    if (updatedAtMs <= 0) return 'не обновлялась';
    final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMs);
    final now = DateTime.now();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(dt.year, dt.month, dt.day);
    final diffDays = today.difference(targetDay).inDays;
    if (diffDays == 0) return 'обн. сегодня в $hh:$mm';
    if (diffDays == 1) return 'обн. вчера в $hh:$mm';
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    if (dt.year == now.year) return 'обн. $d.$m в $hh:$mm';
    return 'обн. $d.$m.${dt.year} в $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final title =
        sub.name.isNotEmpty ? sub.name : (Uri.tryParse(sub.url)?.host ?? sub.url);
    final deadCount = profiles
        .where((p) => (controller.pingOf(p.id) ?? 0) < 0)
        .length;
    final updatedLabel = _fmtUpdatedAt(sub.updatedAt);

    return HairlineCard(
      padding: const EdgeInsets.all(Space.sm),
      child: Column(
        children: [
          FocusableTap(
            borderRadius: BorderRadius.circular(Radii.card),
            onTap: onToggleCollapse,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.sm,
                vertical: Space.xs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isCollapsed ? Icons.chevron_right : Icons.expand_more,
                        color: tokens.muted,
                        size: 22,
                      ),
                      const SizedBox(width: Space.xs),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                if (sub.isCombinedGroup) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.accent.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: tokens.accent.withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Text(
                                      'ГРУППА (${sub.mergedSubscriptionIds.length})',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        color: tokens.accent,
                                      ),
                                    ),
                                  ),
                                ],
                                if (sub.isFptnToken) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.accent.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: tokens.accent.withValues(alpha: 0.4),
                                      ),
                                    ),
                                    child: Text(
                                      'FPTN',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        color: tokens.accent,
                                      ),
                                    ),
                                  ),
                                ],
                                if (sub.networkScope != 'all') ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.accent.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: tokens.accent.withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Text(
                                      sub.networkScope == 'wifi' ? 'Wi-Fi' : 'Мобильная',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        color: tokens.accent,
                                      ),
                                    ),
                                  ),
                                ],
                                if (sub.customHwid.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.raised,
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(color: tokens.line),
                                    ),
                                    child: Text(
                                      'HWID',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        color: tokens.muted,
                                      ),
                                    ),
                                  ),
                                ],
                                if (sub.excludedCountries.isNotEmpty ||
                                    sub.excludedProtocols.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: tokens.warning.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: tokens.warning.withValues(alpha: 0.35),
                                      ),
                                    ),
                                    child: Text(
                                      'Фильтр (${sub.excludedCountries.length + sub.excludedProtocols.length})',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                        color: tokens.warning,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            Text(
                              profiles.isEmpty
                                  ? 'нет серверов · $updatedLabel'
                                  : '${profiles.length} серверов · $updatedLabel · ${isCollapsed ? "развернуть" : "свернуть"}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontSize: 11,
                                    color: tokens.faint,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: sub.enabled,
                        onChanged: (_) => onToggleSub(),
                      ),
                    ],
                  ),
                  if (sub.hasTrafficInfo || sub.expireUnix > 0) ...[
                    const SizedBox(height: 6),
                    if (sub.totalBytes > 0) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: sub.usageRatio,
                          minHeight: 5,
                          backgroundColor: tokens.line,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            sub.usageRatio > 0.85 ? tokens.danger : tokens.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Row(
                      children: [
                        if (sub.hasTrafficInfo)
                          Text(
                            sub.totalBytes > 0
                                ? '${_fmtBytes(sub.usedBytes)} / ${_fmtBytes(sub.totalBytes)}'
                                : 'Использовано: ${_fmtBytes(sub.usedBytes)}',
                            style: TextStyle(
                              fontSize: 11,
                              color: tokens.muted,
                              fontFamily: 'monospace',
                            ),
                          ),
                        const Spacer(),
                        if (sub.expireUnix > 0)
                          Text(
                            _fmtExpire(sub.expireUnix),
                            style: TextStyle(
                              fontSize: 11,
                              color: tokens.muted,
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Flexible(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                          ),
                          onPressed: controller.pingingAll ? null : onPingAllSub,
                          icon: controller.pingingAll
                              ? SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: tokens.accent,
                                  ),
                                )
                              : const Icon(Icons.network_ping, size: 13),
                          label: const Text(
                            'Пинг всех',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                          ),
                          onPressed: controller.loadingSubscription ? null : onRefreshSub,
                          icon: controller.loadingSubscription && !sub.isFptnToken
                              ? const SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: CircularProgressIndicator(strokeWidth: 1.8),
                                )
                              : Icon(
                                  sub.isFptnToken ? Icons.checklist_rounded : Icons.sync,
                                  size: 13,
                                ),
                          label: Text(
                            sub.isFptnToken
                                ? 'Токен / Серверы'
                                : (controller.loadingSubscription ? 'Обновление...' : 'Обновить'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ),
                      const Spacer(),
                      if (deadCount > 0)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                          tooltip: 'Удалить недоступные ($deadCount)',
                          icon: Icon(
                            Icons.cleaning_services_outlined,
                            size: 17,
                            color: tokens.danger,
                          ),
                          onPressed: () =>
                              controller.removeDeadProfiles(subscriptionId: sub.id),
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        tooltip: controller.sortByPing
                            ? 'Сортировка по пингу включена'
                            : 'Сортировать по пингу',
                        icon: Icon(
                          Icons.sort_rounded,
                          size: 17,
                          color: controller.sortByPing ? tokens.accent : tokens.muted,
                        ),
                        onPressed: controller.toggleSortByPing,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        tooltip: 'Редактировать ссылку',
                        icon: const Icon(Icons.edit_outlined, size: 17),
                        onPressed: onEditSub,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.all(4),
                        constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                        tooltip: 'Удалить подписку',
                        icon: Icon(
                          Icons.close_outlined,
                          size: 17,
                          color: tokens.faint,
                        ),
                        onPressed: onRemoveSub,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (!isCollapsed) ...[
            if (profiles.isNotEmpty) ...[
              const Divider(height: Space.sm),
              _AutoBalancerTile(
                title: sub.isFptnToken
                    ? 'Балансировщик FPTN (автовыбор)'
                    : 'Автовыбор (балансировщик)',
                selected: selectedId == 'auto:${sub.id}',
                controller: controller,
                onSelect: () => onSelectProfile('auto:${sub.id}'),
                onConfigure: () => showBalancerSettingsSheet(context, controller),
              ),
            ] else ...[
              const Divider(height: Space.sm),
              Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.link, size: 16, color: tokens.faint),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(
                            sub.url,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: tokens.faint,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Space.sm),
                    FilledButton.icon(
                      onPressed: onRefreshSub,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Загрузить серверы сейчас'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Диалог управления токеном FPTN: обновление токена, выбор отдельных серверов и объединение в балансировщик.
Future<void> showFptnTokenDialog(
  BuildContext context,
  AppController controller,
  String initialToken, {
  SubscriptionEntry? existingSub,
  String? initialName,
}) async {
  final parser = LinkParser();
  final extractedName = parser.extractFptnServiceName(initialToken);
  final nameCtrl = TextEditingController(
    text: (existingSub != null && existingSub.name.isNotEmpty)
        ? existingSub.name
        : ((initialName != null && initialName.isNotEmpty) ? initialName : extractedName),
  );
  final tokenCtrl = TextEditingController(text: initialToken.trim());
  var selectedScope = existingSub?.networkScope ?? 'all';
  var selectBalancer = true;

  var candidates = await controller.parseFptnCandidates(
    initialToken,
    subscriptionId: existingSub?.id ?? '',
  );
  final selectedKeys = <String>{};
  if (existingSub != null && existingSub.selectedServerKeys.isNotEmpty) {
    for (final p in candidates) {
      final k = AppController.fptnServerKey(p);
      if (existingSub.selectedServerKeys.contains(k) ||
          existingSub.selectedServerKeys.contains(p.name)) {
        selectedKeys.add(k);
      }
    }
  }
  if (selectedKeys.isEmpty) {
    for (final p in candidates) {
      selectedKeys.add(AppController.fptnServerKey(p));
    }
  }

  if (!context.mounted) {
    nameCtrl.dispose();
    tokenCtrl.dispose();
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (dialogCtx) {
      return StatefulBuilder(
        builder: (ctx, setStateDialog) {
          final tokens = ctx.tokens;

          Future<void> reloadToken(String nextRaw, {String? fileTitle}) async {
            final trimmed = nextRaw.trim();
            tokenCtrl.text = trimmed;
            final nextCandidates = await controller.parseFptnCandidates(
              trimmed,
              subscriptionId: existingSub?.id ?? '',
            );
            final nextServiceName = parser.extractFptnServiceName(trimmed);
            if (!ctx.mounted) return;
            setStateDialog(() {
              candidates = nextCandidates;
              if (fileTitle != null && fileTitle.isNotEmpty && nameCtrl.text.trim().isEmpty) {
                nameCtrl.text = fileTitle;
              } else if (nextServiceName.isNotEmpty &&
                  (nameCtrl.text.trim().isEmpty || nameCtrl.text.trim() == 'FPTN')) {
                nameCtrl.text = nextServiceName;
              }
              selectedKeys
                ..clear()
                ..addAll(nextCandidates.map(AppController.fptnServerKey));
            });
          }

          return AlertDialog(
            title: Text(
              existingSub != null ? 'Группа FPTN и выбор серверов' : 'Импорт токена FPTN',
            ),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Серверы из токена группируются в отдельную подписку FPTN с собственным балансировщиком. '
                      'При вставке нового токена старые серверы заменяются автоматически.',
                      style: TextStyle(fontSize: 12, color: tokens.muted),
                    ),
                    const SizedBox(height: Space.md),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Название группы FPTN',
                        hintText: 'FPTN',
                      ),
                    ),
                    const SizedBox(height: Space.sm),
                    TextField(
                      controller: tokenCtrl,
                      maxLines: 3,
                      minLines: 2,
                      style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                      onChanged: (v) => reloadToken(v),
                      decoration: InputDecoration(
                        labelText: 'Токен FPTN (fptn:... / fptnb:... / JSON)',
                        suffixIcon: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Вставить новый токен из буфера',
                              icon: const Icon(Icons.content_paste_rounded, size: 18),
                              onPressed: () async {
                                final d = await Clipboard.getData(Clipboard.kTextPlain);
                                final txt = d?.text?.trim() ?? '';
                                if (txt.isNotEmpty) {
                                  await reloadToken(txt);
                                }
                              },
                            ),
                            IconButton(
                              tooltip: 'Загрузить из файла (.fptn / .json)',
                              icon: const Icon(Icons.folder_open_rounded, size: 18),
                              onPressed: () async {
                                final picked = await CoreBridge.instance.pickConfigFile();
                                if (picked == null) return;
                                final fn = (picked['name'] ?? '')
                                    .replaceAll(
                                      RegExp(r'\.(fptn|json|txt)$', caseSensitive: false),
                                      '',
                                    )
                                    .trim();
                                await reloadToken(picked['content'] ?? '', fileTitle: fn);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: Space.md),
                    Text(
                      'Сеть для группы FPTN',
                      style: Theme.of(ctx).textTheme.titleSmall,
                    ),
                    const SizedBox(height: Space.xs),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final item in const [
                          ('all', 'Все сети', Icons.public_rounded),
                          ('wifi', 'Только Wi-Fi', Icons.wifi_rounded),
                          ('cellular', 'Мобильная сеть', Icons.signal_cellular_alt_rounded),
                        ])
                          ChoiceChip(
                            avatar: Icon(item.$3, size: 15),
                            label: Text(item.$2),
                            selected: selectedScope == item.$1,
                            onSelected: (_) =>
                                setStateDialog(() => selectedScope = item.$1),
                          ),
                      ],
                    ),
                    const SizedBox(height: Space.md),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Серверы в токене (${selectedKeys.length} из ${candidates.length})',
                            style: Theme.of(ctx).textTheme.titleSmall,
                          ),
                        ),
                        if (candidates.isNotEmpty) ...[
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () => setStateDialog(() {
                              selectedKeys
                                ..clear()
                                ..addAll(candidates.map(AppController.fptnServerKey));
                            }),
                            child: const Text('Все', style: TextStyle(fontSize: 12)),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () => setStateDialog(selectedKeys.clear),
                            child: const Text('Сбросить', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    if (candidates.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(Space.md),
                        decoration: BoxDecoration(
                          color: tokens.raised,
                          borderRadius: BorderRadius.circular(Radii.card),
                          border: Border.all(color: tokens.line),
                        ),
                        child: Text(
                          'Вставьте корректный токен FPTN (fptn:... или fptnb:...), чтобы увидеть список серверов.',
                          style: TextStyle(fontSize: 12, color: tokens.faint),
                        ),
                      )
                    else
                      Container(
                        constraints: const BoxConstraints(maxHeight: 240),
                        decoration: BoxDecoration(
                          color: tokens.raised,
                          borderRadius: BorderRadius.circular(Radii.card),
                          border: Border.all(color: tokens.line),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: candidates.length,
                          separatorBuilder: (_, _) => Divider(height: 1, color: tokens.line),
                          itemBuilder: (_, idx) {
                            final p = candidates[idx];
                            final key = AppController.fptnServerKey(p);
                            final checked = selectedKeys.contains(key);
                            return CheckboxListTile(
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: checked,
                              onChanged: (v) {
                                setStateDialog(() {
                                  if (v == true) {
                                    selectedKeys.add(key);
                                  } else {
                                    selectedKeys.remove(key);
                                  }
                                });
                              },
                              title: Text(
                                p.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '${p.server}:${p.port}${p.sni.isNotEmpty ? " · SNI: ${p.sni}" : ""}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  color: tokens.faint,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    if (candidates.length >= 2) ...[
                      const SizedBox(height: Space.xs),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        title: const Text(
                          'Активировать балансировщик FPTN после сохранения',
                          style: TextStyle(fontSize: 12.5),
                        ),
                        value: selectBalancer,
                        onChanged: (v) => setStateDialog(() => selectBalancer = v),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogCtx).pop(),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: candidates.isEmpty || selectedKeys.isEmpty
                    ? null
                    : () async {
                        final raw = tokenCtrl.text.trim();
                        final customTitle = nameCtrl.text.trim();
                        final keys = Set<String>.from(selectedKeys);
                        Navigator.of(dialogCtx).pop();
                        final added = await controller.importFptnToken(
                          raw,
                          customName: customTitle.isNotEmpty ? customTitle : null,
                          selectedServerKeys: keys,
                          targetSubId: existingSub?.id,
                          networkScope: selectedScope,
                          selectBalancer: selectBalancer,
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(
                              added > 0
                                  ? 'Группа FPTN обновлена: серверов в балансировщике — $added'
                                  : (controller.lastError.isNotEmpty
                                      ? controller.lastError
                                      : 'Не удалось обновить токен FPTN'),
                            ),
                          ),
                        );
                      },
                child: Text(
                  existingSub != null
                      ? 'Обновить (${selectedKeys.length})'
                      : 'Добавить в группу (${selectedKeys.length})',
                ),
              ),
            ],
          );
        },
      );
    },
  );
  nameCtrl.dispose();
  tokenCtrl.dispose();
}

/// Панель настройки нативного балансировщика tachyon-core 0.3.9.
Future<void> showBalancerSettingsSheet(
  BuildContext context,
  AppController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setStateModal) {
          final tokens = ctx.tokens;
          final current = controller.settings.balancer;
          final runtimeStatus = controller.activeBalancerStatus;
          final winner = controller.activeBalancerWinner;

          Future<void> updateBalancer(BalancerSettings next) async {
            await controller.setBalancer(next);
            if (ctx.mounted) setStateModal(() {});
          }

          return DraggableScrollableSheet(
            initialChildSize: 0.78,
            minChildSize: 0.45,
            maxChildSize: 0.94,
            expand: false,
            builder: (ctx, scrollCtrl) {
              return Container(
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  border: Border.all(color: tokens.line),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tokens.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Space.lg, Space.md, Space.md, Space.sm),
                      child: Row(
                        children: [
                          Icon(Icons.bolt_rounded, color: tokens.accent, size: 22),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Балансировщик tachyon-core 0.3.9',
                                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                Text(
                                  'Атомарный выбор узла без блокировок (lock-free) и телеметрия EWMA',
                                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                        fontSize: 11,
                                        color: tokens.faint,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(sheetCtx).pop(),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.md,
                          Space.lg,
                          Space.xxl,
                        ),
                        children: [
                          if (runtimeStatus != null) ...[
                            HairlineCard(
                              padding: const EdgeInsets.all(Space.md),
                              child: Row(
                                children: [
                                  Icon(Icons.sensors_rounded, size: 18, color: tokens.success),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          winner != null
                                              ? 'Активный узел: ${winner.name}'
                                              : 'Текущий тег: ${runtimeStatus.now}',
                                          style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                                color: tokens.success,
                                                fontWeight: FontWeight.w600,
                                              ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          'Режим ядра: ${runtimeStatus.mode} · Узлов в пуле: ${runtimeStatus.telemetry.length}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontFamily: 'monospace',
                                            color: tokens.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: Space.md),
                          ],
                          const SectionLabel('Алгоритм выбора узла'),
                          for (final opt in BalancerSettings.modes) ...[
                            HairlineCard(
                              onTap: () => updateBalancer(current.copyWith(mode: opt.id)),
                              padding: const EdgeInsets.symmetric(
                                horizontal: Space.md,
                                vertical: Space.sm,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    current.modeOption == opt
                                        ? Icons.radio_button_checked
                                        : Icons.radio_button_unchecked,
                                    size: 18,
                                    color: current.modeOption == opt
                                        ? tokens.accent
                                        : tokens.muted,
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                opt.title,
                                                style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                                      color: current.modeOption == opt
                                                          ? tokens.accent
                                                          : tokens.ink,
                                                      fontWeight: FontWeight.w600,
                                                    ),
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 5,
                                                vertical: 1,
                                              ),
                                              decoration: BoxDecoration(
                                                color: tokens.raised,
                                                borderRadius: BorderRadius.circular(3),
                                                border: Border.all(color: tokens.line),
                                              ),
                                              child: Text(
                                                opt.shortBadge,
                                                style: TextStyle(
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w700,
                                                  fontFamily: 'monospace',
                                                  color: current.modeOption == opt
                                                      ? tokens.accent
                                                      : tokens.muted,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          opt.subtitle,
                                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                                fontSize: 11,
                                                color: tokens.faint,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          const SizedBox(height: Space.md),
                          const SectionLabel('Параметры пула и переключения'),
                          HairlineCard(
                            padding: const EdgeInsets.all(Space.md),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Кандидатов в активном пуле (Top-N)',
                                  style: Theme.of(ctx).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Ограничивает выбор N самыми быстрыми и стабильными серверами.',
                                  style: TextStyle(fontSize: 11, color: tokens.faint),
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final n in const [2, 3, 4, 6, 8, 12])
                                      ChoiceChip(
                                        label: Text('Top-$n'),
                                        selected: current.pool == n,
                                        onSelected: (_) =>
                                            updateBalancer(current.copyWith(pool: n)),
                                      ),
                                  ],
                                ),
                                const Divider(height: Space.lg),
                                Text(
                                  'Допуск гистерезиса по задержке',
                                  style: Theme.of(ctx).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Защищает от лишних переключений при небольших колебаниях пинга.',
                                  style: TextStyle(fontSize: 11, color: tokens.faint),
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final ms in const [30, 50, 80, 120, 200])
                                      ChoiceChip(
                                        label: Text('$ms мс'),
                                        selected: current.poolTolerance == ms,
                                        onSelected: (_) => updateBalancer(
                                          current.copyWith(
                                            tolerance: ms,
                                            poolTolerance: ms,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const Divider(height: Space.lg),
                                Text(
                                  'Интервал проверки доступности',
                                  style: Theme.of(ctx).textTheme.titleSmall,
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final iv in const ['15s', '30s', '1m', '3m', '5m'])
                                      ChoiceChip(
                                        label: Text(iv),
                                        selected: current.interval == iv,
                                        onSelected: (_) =>
                                            updateBalancer(current.copyWith(interval: iv)),
                                      ),
                                  ],
                                ),
                                const Divider(height: Space.lg),
                                Text(
                                  'URL проверки доступности (URL-Test)',
                                  style: Theme.of(ctx).textTheme.titleSmall,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  current.url,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    color: tokens.accent,
                                  ),
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final presetUrl in const [
                                      ('https://www.gstatic.com/generate_204', 'Gstatic (HTTPS)'),
                                      ('http://cp.cloudflare.com/generate_204', 'Cloudflare (HTTP)'),
                                      ('https://cp.cloudflare.com/generate_204', 'Cloudflare (HTTPS)'),
                                      ('http://connectivitycheck.gstatic.com/generate_204', 'Android Check'),
                                    ])
                                      ChoiceChip(
                                        label: Text(presetUrl.$2),
                                        selected: current.url == presetUrl.$1,
                                        onSelected: (_) =>
                                            updateBalancer(current.copyWith(url: presetUrl.$1)),
                                      ),
                                    ActionChip(
                                      avatar: const Icon(Icons.edit_outlined, size: 15),
                                      label: const Text('Свой URL...'),
                                      onPressed: () async {
                                        final urlCtrl = TextEditingController(text: current.url);
                                        final saved = await showDialog<String>(
                                          context: ctx,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text('Свой URL проверки'),
                                            content: TextField(
                                              controller: urlCtrl,
                                              autofocus: true,
                                              decoration: const InputDecoration(
                                                labelText: 'HTTP/HTTPS адрес (200/204)',
                                                hintText: 'https://www.gstatic.com/generate_204',
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(dCtx).pop(),
                                                child: const Text('Отмена'),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(urlCtrl.text.trim()),
                                                child: const Text('Сохранить'),
                                              ),
                                            ],
                                          ),
                                        );
                                        urlCtrl.dispose();
                                        if (saved != null &&
                                            (saved.startsWith('http://') ||
                                                saved.startsWith('https://'))) {
                                          updateBalancer(current.copyWith(url: saved));
                                        }
                                      },
                                    ),
                                  ],
                                ),
                                if (current.modeOption.id == 'sticky') ...[
                                  const Divider(height: Space.lg),
                                  Text(
                                    'Ключи консистентного хеширования (Sticky)',
                                    style: Theme.of(ctx).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Закрепляет сессии одного сайта или IP за одним и тем же выходным узлом.',
                                    style: TextStyle(fontSize: 11, color: tokens.faint),
                                  ),
                                  const SizedBox(height: Space.sm),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final entry in const [
                                        ('domain', 'Домен (SNI)'),
                                        ('dest_ip', 'IP назначения'),
                                        ('dest_port', 'Порт'),
                                        ('source_ip', 'IP источника'),
                                      ])
                                        FilterChip(
                                          label: Text(entry.$2),
                                          selected: current.stickyHash.contains(entry.$1),
                                          onSelected: (on) {
                                            final next = [...current.stickyHash];
                                            if (on) {
                                              if (!next.contains(entry.$1)) {
                                                next.add(entry.$1);
                                              }
                                            } else if (next.length > 1) {
                                              next.remove(entry.$1);
                                            }
                                            updateBalancer(
                                              current.copyWith(stickyHash: next),
                                            );
                                          },
                                        ),
                                    ],
                                  ),
                                ],
                                if (current.modeOption.id == 'quota') ...[
                                  const Divider(height: Space.lg),
                                  Text(
                                    'Квота трафика на один узел (МБ)',
                                    style: Theme.of(ctx).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: Space.sm),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      for (final mib in const [100, 256, 512, 1024, 2048])
                                        ChoiceChip(
                                          label: Text('$mib МБ'),
                                          selected: current.quotaMib == mib,
                                          onSelected: (_) =>
                                              updateBalancer(current.copyWith(quotaMib: mib)),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: Space.md),
                          const SectionLabel('Фильтр исключения стран и протоколов'),
                          HairlineCard(
                            padding: const EdgeInsets.all(Space.md),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Исключить страны',
                                        style: Theme.of(ctx).textTheme.titleSmall,
                                      ),
                                    ),
                                    if (current.excludedCountries.isNotEmpty)
                                      TextButton(
                                        onPressed: () => updateBalancer(
                                          current.copyWith(excludedCountries: const []),
                                        ),
                                        child: const Text('Сбросить'),
                                      ),
                                  ],
                                ),
                                Text(
                                  'Отмеченные страны и ключевые слова исключаются из списка серверов и автовыбора.',
                                  style: TextStyle(fontSize: 11, color: tokens.faint),
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final c in BalancerSettings.commonCountryFilters)
                                      FilterChip(
                                        label: Text(
                                          '${c.$2} ${c.$1}',
                                          style: const TextStyle(fontSize: 11.5),
                                        ),
                                        tooltip: c.$3,
                                        selected: current.excludedCountries.any(
                                          (x) => x.toUpperCase() == c.$1,
                                        ),
                                        onSelected: (on) {
                                          final next = current.excludedCountries
                                              .where((x) => x.toUpperCase() != c.$1)
                                              .toList();
                                          if (on) next.add(c.$1);
                                          updateBalancer(
                                            current.copyWith(excludedCountries: next),
                                          );
                                        },
                                      ),
                                    ActionChip(
                                      avatar: const Icon(Icons.add_rounded, size: 15),
                                      label: const Text('Свои слова...'),
                                      onPressed: () async {
                                        final ctrl = TextEditingController(
                                          text: current.excludedCountries.join(', '),
                                        );
                                        final res = await showDialog<String>(
                                          context: ctx,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text('Исключить страны / слова'),
                                            content: TextField(
                                              controller: ctrl,
                                              autofocus: true,
                                              decoration: const InputDecoration(
                                                labelText: 'Коды стран или слова через запятую',
                                                hintText: 'RU, KZ, BY, реклама, vip',
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(dCtx).pop(),
                                                child: const Text('Отмена'),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(ctrl.text),
                                                child: const Text('Применить'),
                                              ),
                                            ],
                                          ),
                                        );
                                        ctrl.dispose();
                                        if (res != null) {
                                          final parsed = res
                                              .split(',')
                                              .map((s) => s.trim())
                                              .where((s) => s.isNotEmpty)
                                              .toList(growable: false);
                                          updateBalancer(
                                            current.copyWith(excludedCountries: parsed),
                                          );
                                        }
                                      },
                                    ),
                                  ],
                                ),
                                const Divider(height: Space.lg),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Исключить протоколы',
                                        style: Theme.of(ctx).textTheme.titleSmall,
                                      ),
                                    ),
                                    if (current.excludedProtocols.isNotEmpty)
                                      TextButton(
                                        onPressed: () => updateBalancer(
                                          current.copyWith(excludedProtocols: const []),
                                        ),
                                        child: const Text('Сбросить'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final proto in BalancerSettings.commonProtocolFilters)
                                      FilterChip(
                                        label: Text(
                                          proto.$2,
                                          style: const TextStyle(fontSize: 11.5),
                                        ),
                                        selected: current.excludedProtocols.contains(proto.$1),
                                        onSelected: (on) {
                                          final next = current.excludedProtocols
                                              .where((x) => x != proto.$1)
                                              .toList();
                                          if (on) next.add(proto.$1);
                                          updateBalancer(
                                            current.copyWith(excludedProtocols: next),
                                          );
                                        },
                                      ),
                                  ],
                                ),
                                const Divider(height: Space.lg),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Фильтр по регулярному выражению (RegExp)',
                                        style: Theme.of(ctx).textTheme.titleSmall,
                                      ),
                                    ),
                                    if (current.includeRegex.isNotEmpty ||
                                        current.excludeRegex.isNotEmpty)
                                      TextButton(
                                        onPressed: () => updateBalancer(
                                          current.copyWith(
                                            includeRegex: '',
                                            excludeRegex: '',
                                          ),
                                        ),
                                        child: const Text('Сбросить'),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Позволяет оставить только серверы с нужным словом/шаблоном (например, для мобильной сети) или скрыть лишние.',
                                  style: TextStyle(fontSize: 11, color: tokens.faint),
                                ),
                                const SizedBox(height: Space.sm),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    ActionChip(
                                      avatar: Icon(
                                        Icons.check_circle_outline_rounded,
                                        size: 15,
                                        color: current.includeRegex.isNotEmpty
                                            ? tokens.accent
                                            : tokens.muted,
                                      ),
                                      label: Text(
                                        current.includeRegex.isNotEmpty
                                            ? 'Включить: ${current.includeRegex}'
                                            : 'Включить по RegExp...',
                                      ),
                                      onPressed: () async {
                                        final ctrl = TextEditingController(
                                          text: current.includeRegex,
                                        );
                                        final res = await showDialog<String>(
                                          context: ctx,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text('Включить по регулярному выражению'),
                                            content: TextField(
                                              controller: ctrl,
                                              autofocus: true,
                                              decoration: const InputDecoration(
                                                labelText: 'Шаблон RegExp или ключевое слово',
                                                hintText: 'Например: LTE|Whitelist|МТС',
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(dCtx).pop(),
                                                child: const Text('Отмена'),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(ctrl.text.trim()),
                                                child: const Text('Применить'),
                                              ),
                                            ],
                                          ),
                                        );
                                        ctrl.dispose();
                                        if (res != null) {
                                          updateBalancer(current.copyWith(includeRegex: res));
                                        }
                                      },
                                    ),
                                    ActionChip(
                                      avatar: Icon(
                                        Icons.remove_circle_outline_rounded,
                                        size: 15,
                                        color: current.excludeRegex.isNotEmpty
                                            ? tokens.accent
                                            : tokens.muted,
                                      ),
                                      label: Text(
                                        current.excludeRegex.isNotEmpty
                                            ? 'Исключить: ${current.excludeRegex}'
                                            : 'Исключить по RegExp...',
                                      ),
                                      onPressed: () async {
                                        final ctrl = TextEditingController(
                                          text: current.excludeRegex,
                                        );
                                        final res = await showDialog<String>(
                                          context: ctx,
                                          builder: (dCtx) => AlertDialog(
                                            title: const Text('Исключить по регулярному выражению'),
                                            content: TextField(
                                              controller: ctrl,
                                              autofocus: true,
                                              decoration: const InputDecoration(
                                                labelText: 'Шаблон RegExp или ключевое слово',
                                                hintText: 'Например: резерв|тест|expired',
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(dCtx).pop(),
                                                child: const Text('Отмена'),
                                              ),
                                              FilledButton(
                                                onPressed: () =>
                                                    Navigator.of(dCtx).pop(ctrl.text.trim()),
                                                child: const Text('Применить'),
                                              ),
                                            ],
                                          ),
                                        );
                                        ctrl.dispose();
                                        if (res != null) {
                                          updateBalancer(current.copyWith(excludeRegex: res));
                                        }
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: Space.md),
                          _NetworkListsSummaryTile(
                            controller: controller,
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              showNetworkListsSheet(context, controller);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}

String _resolveProfileTargetLabel(AppController controller, String id) {
  if (id.isEmpty) return 'Не менять';
  if (id == 'auto:all') return 'Автовыбор (все серверы)';
  if (id.startsWith('auto:')) {
    final subId = id.substring(5);
    for (final s in controller.settings.visibleSubscriptions) {
      if (s.id == subId) {
        final name = s.name.isNotEmpty
            ? s.name
            : (Uri.tryParse(s.url)?.host ?? 'подписка');
        return 'Автовыбор ($name)';
      }
    }
    return 'Автовыбор (подписка)';
  }
  for (final p in controller.settings.visibleProfiles) {
    if (p.id == id) return p.name;
  }
  return 'Не менять';
}

/// Компактная плитка состояния списков серверов для Wi-Fi и мобильной сети.
class _NetworkListsSummaryTile extends StatelessWidget {
  const _NetworkListsSummaryTile({
    required this.controller,
    required this.onTap,
  });

  final AppController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final wifiId = controller.settings.wifiProfileId;
    final cellId = controller.settings.cellularProfileId;
    final scopedSubs = controller.settings.visibleSubscriptions
        .where((s) => s.networkScope != 'all')
        .length;
    final scopedProfs = controller.settings.visibleProfiles
        .where((p) => p.networkScope != 'all')
        .length;
    final isConfigured =
        wifiId.isNotEmpty || cellId.isNotEmpty || scopedSubs > 0 || scopedProfs > 0;

    final String subtitle;
    if (wifiId.isNotEmpty || cellId.isNotEmpty) {
      subtitle =
          'Wi-Fi: ${_resolveProfileTargetLabel(controller, wifiId)} · Мобильная: ${_resolveProfileTargetLabel(controller, cellId)}';
    } else if (scopedSubs > 0 || scopedProfs > 0) {
      subtitle =
          'Размечено по сети: подписок — $scopedSubs, отдельных серверов — $scopedProfs';
    } else {
      subtitle = 'Настроить отдельные подписки или серверы для мобильной сети и Wi-Fi';
    }

    return HairlineCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.swap_calls_rounded,
            size: 18,
            color: isConfigured ? tokens.accent : tokens.muted,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Списки серверов для Wi-Fi и Мобильной сети',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: isConfigured ? tokens.accent : tokens.ink,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontSize: 11,
                        color: tokens.faint,
                      ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 18, color: tokens.muted),
        ],
      ),
    );
  }
}

/// Панель настройки отдельных списков серверов и автопереключения для Wi-Fi и Мобильной сети.
Future<void> showNetworkListsSheet(
  BuildContext context,
  AppController controller,
) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setStateModal) {
          final tokens = ctx.tokens;
          final settings = controller.settings;
          final subs = settings.visibleSubscriptions;
          final profiles = settings.visibleProfiles;

          final options = <(String, String)>[
            ('', 'Не менять автоматически'),
            if (profiles.length >= 2)
              ('auto:all', 'Глобальный балансировщик (все серверы)'),
            for (final s in subs)
              (
                'auto:${s.id}',
                'Автовыбор: ${s.name.isNotEmpty ? s.name : (Uri.tryParse(s.url)?.host ?? s.url)}',
              ),
            for (final p in profiles) (p.id, 'Сервер: ${p.name}'),
          ];

          String safeValue(String raw) =>
              options.any((o) => o.$1 == raw) ? raw : '';

          return DraggableScrollableSheet(
            initialChildSize: 0.72,
            minChildSize: 0.45,
            maxChildSize: 0.92,
            expand: false,
            builder: (ctx, scrollCtrl) {
              return Container(
                decoration: BoxDecoration(
                  color: tokens.surface,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  border: Border.all(color: tokens.line),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tokens.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Space.lg,
                        Space.md,
                        Space.md,
                        Space.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.swap_calls_rounded, color: tokens.accent, size: 22),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Списки серверов по типу сети',
                                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                Text(
                                  'Отдельные подписки и автовыбор для Мобильной сети и Wi-Fi',
                                  style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                                        fontSize: 11,
                                        color: tokens.faint,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(sheetCtx).pop(),
                            icon: const Icon(Icons.close, size: 20),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.md,
                          Space.lg,
                          Space.xxl,
                        ),
                        children: [
                          const SectionLabel('Автовыбор списка при смене сети'),
                          HairlineCard(
                            padding: const EdgeInsets.all(Space.md),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(Icons.wifi_rounded, size: 17, color: tokens.accent),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Сеть Wi-Fi',
                                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: Space.xs),
                                DropdownButtonFormField<String>(
                                  initialValue: safeValue(settings.wifiProfileId),
                                  isExpanded: true,
                                  items: [
                                    for (final opt in options)
                                      DropdownMenuItem<String>(
                                        value: opt.$1,
                                        child: Text(
                                          opt.$2,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                  ],
                                  onChanged: (val) async {
                                    if (val == null) return;
                                    await controller.setNetworkProfiles(wifiProfileId: val);
                                    if (ctx.mounted) setStateModal(() {});
                                  },
                                ),
                                const Divider(height: Space.lg),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.signal_cellular_alt_rounded,
                                      size: 17,
                                      color: tokens.accent,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Мобильная сеть (LTE / 5G)',
                                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: Space.xs),
                                DropdownButtonFormField<String>(
                                  initialValue: safeValue(settings.cellularProfileId),
                                  isExpanded: true,
                                  items: [
                                    for (final opt in options)
                                      DropdownMenuItem<String>(
                                        value: opt.$1,
                                        child: Text(
                                          opt.$2,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 13),
                                        ),
                                      ),
                                  ],
                                  onChanged: (val) async {
                                    if (val == null) return;
                                    await controller.setNetworkProfiles(cellularProfileId: val);
                                    if (ctx.mounted) setStateModal(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                          if (subs.isNotEmpty) ...[
                            const SizedBox(height: Space.md),
                            const SectionLabel('Фильтр подписок внутри балансировщика'),
                            Text(
                              'Если выбран «Глобальный балансировщик», подписки с пометкой «Только Wi-Fi» '
                              'или «Мобильная» будут автоматически включаться только в соответствующей сети.',
                              style: TextStyle(fontSize: 11, color: tokens.faint),
                            ),
                            const SizedBox(height: Space.sm),
                            for (final sub in subs) ...[
                              HairlineCard(
                                padding: const EdgeInsets.all(Space.md),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      sub.name.isNotEmpty
                                          ? sub.name
                                          : (Uri.tryParse(sub.url)?.host ?? sub.url),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(ctx).textTheme.titleSmall?.copyWith(
                                            fontWeight: FontWeight.w600,
                                          ),
                                    ),
                                    const SizedBox(height: Space.xs),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (final item in const [
                                          ('all', 'Все сети'),
                                          ('wifi', 'Только Wi-Fi'),
                                          ('cellular', 'Мобильная'),
                                        ])
                                          ChoiceChip(
                                            label: Text(item.$2),
                                            selected: sub.networkScope == item.$1,
                                            onSelected: (_) async {
                                              await controller.editSubscription(
                                                sub.id,
                                                networkScope: item.$1,
                                              );
                                              if (ctx.mounted) setStateModal(() {});
                                            },
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}
