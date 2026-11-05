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
import 'tv_receive_dialog.dart';

/// Экран профилей: список серверов и импорт подписки.
class ProfilesTab extends StatefulWidget {
  const ProfilesTab({super.key});

  @override
  State<ProfilesTab> createState() => _ProfilesTabState();
}

class _ProfilesTabState extends State<ProfilesTab> {
  String _searchQuery = '';

  List<Profile> _filter(List<Profile> items) {
    final q = _searchQuery.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items
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
    final standaloneProfiles = _filter(controller.sortProfiles(
      profiles.where((p) => p.subscriptionId.isEmpty).toList(),
    ));
    final hasDead = controller.pings.values.any((ms) => ms < 0);

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Профили'),
        actions: [
          if (hasDead)
            IconButton(
              tooltip: 'Удалить недоступные серверы (✗)',
              onPressed: () async {
                final removed = await controller.removeDeadProfiles();
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Удалено недоступных серверов: $removed')),
                );
              },
              icon: Icon(Icons.cleaning_services_outlined, color: tokens.danger),
            ),
          IconButton(
            tooltip: 'Настройки балансировщика (tachyon-core 0.3.9)',
            onPressed: () => showBalancerSettingsSheet(context, controller),
            icon: const Icon(Icons.tune_rounded),
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
            tooltip: 'Принять с телефона по Wi-Fi (Android TV)',
            onPressed: () => showTvReceiveDialog(context, controller),
            icon: const Icon(Icons.tv_rounded),
          ),
          IconButton(
            tooltip: 'Сканировать QR-код',
            onPressed: () => _handleQrScan(context, controller, fromGallery: false),
            icon: const Icon(Icons.qr_code_scanner_rounded),
          ),
          IconButton(
            tooltip: 'Добавить вручную',
            onPressed: () => _showManualDialog(context, controller),
            icon: const Icon(Icons.add),
          ),
          IconButton(
            tooltip: 'Импорт подписки',
            onPressed: () => _showImportDialog(context, controller),
            icon: const Icon(Icons.file_download_outlined),
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
          : ListView(
              padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
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
                    selected: controller.settings.selectedProfileId == 'auto:all',
                    controller: controller,
                    onSelect: () => controller.selectProfile('auto:all'),
                    onConfigure: () => showBalancerSettingsSheet(context, controller),
                  ),
                  const SizedBox(height: Space.md),
                ],
                if (subs.isNotEmpty) ...[
                  _SubscriptionGroupList(
                    controller: controller,
                    searchQuery: _searchQuery,
                    onEditProfile: (profile) =>
                        _showManualDialog(context, controller, edit: profile),
                    onShareProfile: (profile) =>
                        _showQrDialog(context, controller, profile),
                  ),
                  const SizedBox(height: Space.xl),
                ],
                if (standaloneProfiles.isNotEmpty) ...[
                  const SectionLabel('Пользовательские серверы'),
                  for (final profile in standaloneProfiles) ...[
                    _ProfileTile(
                      profile: profile,
                      selected: profile.id == controller.settings.selectedProfileId,
                      onSelect: () => controller.selectProfile(profile.id),
                      onDelete: () => controller.removeProfile(profile.id),
                      onEdit: () => _showManualDialog(context, controller, edit: profile),
                      onShare: () => _showQrDialog(context, controller, profile),
                      onPing: () => controller.pingProfile(profile.id),
                      ping: controller.pingOf(profile.id),
                      isPinging: controller.isPinging(profile.id),
                      telemetry: controller.balancerTelemetryOf(profile.id),
                      isBalancerWinner:
                          controller.activeBalancerWinner?.id == profile.id,
                    ),
                    const SizedBox(height: Space.sm),
                  ],
                ],
              ],
            ),
    );
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
            return AlertDialog(
              title: const Text('Импорт подписки и QR'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Отсканируйте QR-код подписки/сервера или вставьте ссылку, конфиг WG/AmneziaWG, '
                      'Clash YAML, Sing-box/Xray JSON, FPTN-токен или любой URI протокола.',
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
                      style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                      decoration: InputDecoration(
                        hintText: 'https://... или vless://...',
                        suffixIcon: IconButton(
                          tooltip: 'Вставить из буфера',
                          icon: const Icon(Icons.content_paste_rounded),
                          onPressed: () async {
                            final d = await Clipboard.getData(Clipboard.kTextPlain);
                            if (d?.text != null) {
                              textController.text = d!.text!.trim();
                              textController.selection = TextSelection.collapsed(
                                offset: textController.text.length,
                              );
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
                      _ => 'Добавлено профилей: $added',
                    };
                    ScaffoldMessenger.maybeOf(rootContext)?.showSnackBar(
                      SnackBar(content: Text(msg)),
                    );
                  },
                  child: const Text('Импортировать'),
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
    final awgJc = TextEditingController(text: (edit?.extra['jc'] ?? '').toString());
    final awgJmin = TextEditingController(text: (edit?.extra['jmin'] ?? '').toString());
    final awgJmax = TextEditingController(text: (edit?.extra['jmax'] ?? '').toString());
    final awgS1 = TextEditingController(text: (edit?.extra['s1'] ?? '').toString());
    final awgS2 = TextEditingController(text: (edit?.extra['s2'] ?? '').toString());
    final awgH1 = TextEditingController(text: (edit?.extra['h1'] ?? '').toString());
    final awgH2 = TextEditingController(text: (edit?.extra['h2'] ?? '').toString());
    final awgH3 = TextEditingController(text: (edit?.extra['h3'] ?? '').toString());
    final awgH4 = TextEditingController(text: (edit?.extra['h4'] ?? '').toString());

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
                          ],
                        ),
                        if (type == 'wireguard') ...[
                          const SizedBox(height: Space.sm),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text(
                              'Обфускация AmneziaWG (Jc, Jmin, Jmax, S1..H4)',
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
                                ],
                              ),
                              const SizedBox(height: Space.sm),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: awgH1,
                                      decoration: const InputDecoration(labelText: 'H1'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH2,
                                      decoration: const InputDecoration(labelText: 'H2'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH3,
                                      decoration: const InputDecoration(labelText: 'H3'),
                                    ),
                                  ),
                                  const SizedBox(width: Space.sm),
                                  Expanded(
                                    child: TextField(
                                      controller: awgH4,
                                      decoration: const InputDecoration(labelText: 'H4'),
                                    ),
                                  ),
                                ],
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
                        setAwgHeader('h1', awgH1.text);
                        setAwgHeader('h2', awgH2.text);
                        setAwgHeader('h3', awgH3.text);
                        setAwgHeader('h4', awgH4.text);
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
      awgJc,
      awgJmin,
      awgJmax,
      awgS1,
      awgS2,
      awgH1,
      awgH2,
      awgH3,
      awgH4,
    ]) {
      c.dispose();
    }
  }
}

/// Плитка профиля: имя, адрес, тип, пинг, телеметрия балансировщика и компактное меню действий.
class _ProfileTile extends StatelessWidget {
  const _ProfileTile({
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onDelete,
    required this.onEdit,
    required this.onShare,
    this.onPing,
    this.ping,
    this.isPinging = false,
    this.telemetry,
    this.isBalancerWinner = false,
  });

  final Profile profile;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback onShare;
  final VoidCallback? onPing;
  final int? ping;
  final bool isPinging;
  final BalancerNodeTelemetry? telemetry;
  final bool isBalancerWinner;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tel = telemetry;
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
          FocusableTap(
            borderRadius: BorderRadius.circular(4),
            onTap: onPing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: tokens.raised,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tokens.line),
              ),
              child: isPinging
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: tokens.accent,
                      ),
                    )
                  : ping == null
                      ? Icon(Icons.network_ping, size: 14, color: tokens.faint)
                      : Text(
                          ping! < 0 ? '✗' : '${ping}ms',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                            color: ping! < 0
                                ? tokens.danger
                                : ping! < 150
                                    ? tokens.success
                                    : ping! < 400
                                        ? tokens.warning
                                        : tokens.danger,
                          ),
                        ),
            ),
          ),
          const SizedBox(width: 2),
          PopupMenuButton<String>(
            tooltip: 'Действия с сервером',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 168),
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

    final subtitle = winner != null
        ? 'Активен: ${winner.name}${winnerTel != null && winnerTel.ewmaRttMs > 0 ? ' (${winnerTel.ewmaRttMs}ms ±${winnerTel.jitterMs}ms)' : ''} · ${modeOpt.title}'
        : '${modeOpt.title} · пул Top-${balancer.pool} · ${modeOpt.subtitle}';

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

/// Список подписок со сворачиваемыми серверами внутри.
class _SubscriptionGroupList extends StatelessWidget {
  const _SubscriptionGroupList({
    required this.controller,
    required this.searchQuery,
    required this.onEditProfile,
    required this.onShareProfile,
  });

  final AppController controller;
  final String searchQuery;
  final void Function(Profile profile) onEditProfile;
  final void Function(Profile profile) onShareProfile;

  List<Profile> _filter(List<Profile> items) {
    final q = searchQuery.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.server.toLowerCase().contains(q) ||
            p.type.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final subs = controller.settings.visibleSubscriptions;
    final allProfiles = controller.settings.visibleProfiles;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final sub in subs) ...[
          _CollapsibleSubCard(
            sub: sub,
            controller: controller,
            isCollapsed:
                controller.isSubCollapsed(sub.id) && searchQuery.trim().isEmpty,
            profiles: _filter(controller.sortProfiles(
              allProfiles.where((p) => p.subscriptionId == sub.id).toList(),
            )),
            selectedId: controller.settings.selectedProfileId,
            onToggleCollapse: () => controller.toggleSubCollapsed(sub.id),
            onToggleSub: () => controller.toggleSubscription(sub.id),
            onRemoveSub: () => controller.removeSubscription(sub.id),
            onRefreshSub: () => controller.refreshSubscription(sub.id),
            onPingAllSub: () => controller.pingAllProfiles(subscriptionId: sub.id),
            onSelectProfile: (id) => controller.selectProfile(id),
            onDeleteProfile: (id) => controller.removeProfile(id),
            onEditProfile: onEditProfile,
            onShareProfile: onShareProfile,
            onPingProfile: (id) => controller.pingProfile(id),
            onEditSub: () => _showEditSubDialog(context, controller, sub),
          ),
          const SizedBox(height: Space.md),
        ],
      ],
    );
  }

  Future<void> _showEditSubDialog(
    BuildContext context,
    AppController controller,
    SubscriptionEntry sub,
  ) async {
    final nameCtrl = TextEditingController(text: sub.name);
    final urlCtrl = TextEditingController(text: sub.url);

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Редактировать подписку'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration:
                    const InputDecoration(labelText: 'Название (опционально)'),
              ),
              const SizedBox(height: Space.md),
              TextField(
                controller: urlCtrl,
                maxLines: 3,
                minLines: 1,
                decoration:
                    const InputDecoration(labelText: 'Ссылка на подписку'),
              ),
            ],
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
              Navigator.of(dialogCtx).pop();
              if (newUrl.isNotEmpty) {
                await controller.editSubscription(
                  sub.id,
                  url: newUrl,
                  name: newName,
                );
              }
            },
            child: const Text('Сохранить и обновить'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
  }
}

/// Сворачиваемая карточка подписки с информацией о трафике и сроке действия.
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
    required this.onDeleteProfile,
    required this.onEditProfile,
    required this.onShareProfile,
    required this.onPingProfile,
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
  final void Function(String id) onDeleteProfile;
  final void Function(Profile profile) onEditProfile;
  final void Function(Profile profile) onShareProfile;
  final void Function(String id) onPingProfile;

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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final title =
        sub.name.isNotEmpty ? sub.name : (Uri.tryParse(sub.url)?.host ?? sub.url);
    final deadCount = profiles
        .where((p) => (controller.pingOf(p.id) ?? 0) < 0)
        .length;

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
                            Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                            Text(
                              profiles.isEmpty
                                  ? 'нет серверов'
                                  : '${profiles.length} серверов · ${isCollapsed ? "развернуть" : "свернуть"}',
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
                          onPressed: onRefreshSub,
                          icon: const Icon(Icons.sync, size: 13),
                          label: const Text(
                            'Обновить',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11),
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
                title: 'Автовыбор (балансировщик)',
                selected: selectedId == 'auto:${sub.id}',
                controller: controller,
                onSelect: () => onSelectProfile('auto:${sub.id}'),
                onConfigure: () => showBalancerSettingsSheet(context, controller),
              ),
              const SizedBox(height: 4),
              for (final p in profiles) ...[
                _ProfileTile(
                  profile: p,
                  selected: p.id == selectedId,
                  ping: controller.pingOf(p.id),
                  isPinging: controller.isPinging(p.id),
                  telemetry: controller.balancerTelemetryOf(p.id),
                  isBalancerWinner: controller.activeBalancerWinner?.id == p.id,
                  onSelect: () => onSelectProfile(p.id),
                  onDelete: () => onDeleteProfile(p.id),
                  onEdit: () => onEditProfile(p),
                  onShare: () => onShareProfile(p),
                  onPing: () => onPingProfile(p.id),
                ),
                const SizedBox(height: 4),
              ],
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
