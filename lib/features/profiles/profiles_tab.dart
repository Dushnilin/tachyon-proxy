import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../app/widgets/qr_code_view.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';

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
    final profiles = controller.settings.profiles;
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
      body: (profiles.isEmpty && controller.settings.subscriptions.isEmpty)
          ? EmptyState(
              icon: Icons.dns_outlined,
              title: 'Профилей пока нет',
              description:
                  'Импортируйте подписку по ссылке или QR-коду, либо добавьте сервер вручную — '
                  'ссылки vless, trojan, ss, vmess, hysteria2, tuic, '
                  'anytls и socks понимаются, как и подписки '
                  'по https и сырой JSON аутбаунда sing-box.',
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
                if (controller.settings.subscriptions.isNotEmpty) ...[
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
    if (clipText.isNotEmpty &&
        (clipText.startsWith('http') ||
            clipText.startsWith('vless://') ||
            clipText.startsWith('trojan://') ||
            clipText.startsWith('ss://') ||
            clipText.startsWith('vmess://') ||
            clipText.startsWith('hysteria') ||
            clipText.startsWith('hy2://') ||
            clipText.startsWith('tuic://') ||
            clipText.startsWith('anytls://') ||
            clipText.startsWith('socks') ||
            clipText.startsWith('wg://') ||
            clipText.startsWith('naive+'))) {
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
                      'Отсканируйте QR-код подписки/сервера или вставьте ссылку вручную '
                      '(https-подписка, vless, trojan, ss, vmess, hysteria2, tuic, anytls, JSON).',
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

  /// Полноценный диалог добавления/редактирования сервера.
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

    var type = edit?.type ?? 'vless';
    const allowedTypes = [
      'vless',
      'trojan',
      'shadowsocks',
      'hysteria2',
      'tuic',
      'anytls',
      'socks',
    ];
    if (!allowedTypes.contains(type)) type = 'vless';

    var security = 'none';
    if (existingReality['enabled'] == true) {
      security = 'reality';
    } else if (existingTls['enabled'] == true || (edit?.sni.isNotEmpty ?? false)) {
      security = 'tls';
    } else if (edit == null && type == 'vless') {
      security = 'reality';
    }

    var transport = (existingTransport['type'] as String?) ?? 'tcp';
    const allowedTransports = ['tcp', 'xhttp', 'ws', 'grpc', 'httpupgrade'];
    if (!allowedTransports.contains(transport)) transport = 'tcp';

    final name = TextEditingController(text: edit?.name ?? '');
    final address = TextEditingController(
      text: edit != null ? '${edit.server}:${edit.port}' : '',
    );
    final uuid = TextEditingController(text: edit?.uuid ?? '');
    final password = TextEditingController(text: edit?.password ?? '');
    final method = TextEditingController(
      text: (edit?.method.isNotEmpty ?? false) ? edit!.method : 'aes-256-gcm',
    );
    final flow = TextEditingController(text: edit?.flow ?? '');
    final sni = TextEditingController(
      text: (existingTls['server_name'] as String?) ?? edit?.sni ?? '',
    );
    final pbk = TextEditingController(
      text: (existingReality['public_key'] as String?) ?? edit?.publicKey ?? '',
    );
    final sid = TextEditingController(
      text: (existingReality['short_id'] as String?) ?? edit?.shortId ?? '',
    );
    final fp = TextEditingController(
      text: (existingUtls['fingerprint'] as String?) ?? 'chrome',
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

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: Text(edit != null ? 'Редактировать сервер' : 'Новый сервер'),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: type,
                        decoration: const InputDecoration(labelText: 'Протокол'),
                        items: const [
                          DropdownMenuItem(value: 'vless', child: Text('VLESS')),
                          DropdownMenuItem(value: 'trojan', child: Text('Trojan')),
                          DropdownMenuItem(
                            value: 'shadowsocks',
                            child: Text('Shadowsocks'),
                          ),
                          DropdownMenuItem(
                            value: 'hysteria2',
                            child: Text('Hysteria 2'),
                          ),
                          DropdownMenuItem(value: 'tuic', child: Text('TUIC v5')),
                          DropdownMenuItem(value: 'anytls', child: Text('AnyTLS')),
                          DropdownMenuItem(value: 'socks', child: Text('SOCKS5')),
                        ],
                        onChanged: (value) => setState(() => type = value ?? type),
                      ),
                      const SizedBox(height: Space.sm),
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: 'Название'),
                      ),
                      const SizedBox(height: Space.sm),
                      TextField(
                        controller: address,
                        decoration: const InputDecoration(
                          labelText: 'Адрес и порт',
                          hintText: 'example.com:443',
                        ),
                      ),
                      const SizedBox(height: Space.sm),
                      if (type == 'vless' || type == 'tuic') ...[
                        TextField(
                          controller: uuid,
                          decoration: const InputDecoration(labelText: 'UUID'),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type != 'vless') ...[
                        TextField(
                          controller: password,
                          decoration: const InputDecoration(
                            labelText: 'Пароль / ключ',
                          ),
                        ),
                        const SizedBox(height: Space.sm),
                      ],
                      if (type == 'shadowsocks') ...[
                        TextField(
                          controller: method,
                          decoration: const InputDecoration(
                            labelText: 'Метод шифрования',
                            hintText: '2022-blake3-aes-128-gcm / aes-256-gcm',
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
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
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
                              ],
                              onChanged: (v) =>
                                  setState(() => transport = v ?? transport),
                            ),
                          ),
                          const SizedBox(width: Space.sm),
                          Expanded(
                            child: DropdownButtonFormField<String>(
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
                      if (transport != 'tcp') ...[
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
                      if (security != 'none') ...[
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
                            labelText: 'uTLS Fingerprint (chrome / firefox / qq)',
                          ),
                        ),
                      ],
                      if (security == 'reality') ...[
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
                    final separator = host.lastIndexOf(':');
                    final server =
                        separator > 0 ? host.substring(0, separator) : host;
                    final port = separator > 0
                        ? int.tryParse(host.substring(separator + 1)) ?? 443
                        : 443;

                    final nextExtra = Map<String, Object?>.from(edit?.extra ?? const {});
                    if (transport == 'tcp') {
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

                    if (security == 'none') {
                      nextExtra.remove('tls');
                    } else {
                      final tlsMap = Map<String, Object?>.from(existingTls);
                      tlsMap['enabled'] = true;
                      if (sni.text.trim().isNotEmpty) {
                        tlsMap['server_name'] = sni.text.trim();
                      }
                      if (fp.text.trim().isNotEmpty) {
                        tlsMap['utls'] = {
                          'enabled': true,
                          'fingerprint': fp.text.trim(),
                        };
                      }
                      if (security == 'reality') {
                        tlsMap['reality'] = {
                          'enabled': true,
                          'public_key': pbk.text.trim(),
                          if (sid.text.trim().isNotEmpty)
                            'short_id': sid.text.trim(),
                        };
                      } else {
                        tlsMap.remove('reality');
                      }
                      nextExtra['tls'] = tlsMap;
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

    name.dispose();
    address.dispose();
    uuid.dispose();
    password.dispose();
    method.dispose();
    flow.dispose();
    sni.dispose();
    pbk.dispose();
    sid.dispose();
    fp.dispose();
    path.dispose();
    hostHeader.dispose();
    xhttpMode.dispose();
  }
}

/// Плитка профиля: имя, адрес, тип, пинг, QR-код, редактирование и удаление.
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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

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
              color: selected ? tokens.accent : tokens.line,
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.fullTransportLabel} · ${profile.server}:${profile.port}',
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
          GestureDetector(
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
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'QR-код / Поделиться',
            onPressed: onShare,
            icon: Icon(Icons.qr_code_2, size: 18, color: tokens.muted),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Редактировать',
            onPressed: onEdit,
            icon: Icon(Icons.edit_outlined, size: 18, color: tokens.muted),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Удалить',
            onPressed: onDelete,
            icon: Icon(Icons.close, size: 18, color: tokens.faint),
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
    final subs = controller.settings.subscriptions;
    final allProfiles = controller.settings.profiles;

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
          InkWell(
            onTap: onToggleCollapse,
            borderRadius: BorderRadius.circular(Radii.card),
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
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
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
                            : const Icon(Icons.network_ping, size: 14),
                        label: const Text(
                          'Пинг всех',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                        ),
                        onPressed: onRefreshSub,
                        icon: const Icon(Icons.sync, size: 14),
                        label: const Text(
                          'Обновить',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                      const Spacer(),
                      if (deadCount > 0)
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Удалить недоступные ($deadCount)',
                          icon: Icon(
                            Icons.cleaning_services_outlined,
                            size: 18,
                            color: tokens.danger,
                          ),
                          onPressed: () =>
                              controller.removeDeadProfiles(subscriptionId: sub.id),
                        ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: controller.sortByPing
                            ? 'Сортировка по пингу включена'
                            : 'Сортировать по пингу',
                        icon: Icon(
                          Icons.sort_rounded,
                          size: 18,
                          color: controller.sortByPing ? tokens.accent : tokens.muted,
                        ),
                        onPressed: controller.toggleSortByPing,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Редактировать ссылку',
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        onPressed: onEditSub,
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Удалить подписку',
                        icon: Icon(
                          Icons.close_outlined,
                          size: 18,
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
              for (final p in profiles) ...[
                _ProfileTile(
                  profile: p,
                  selected: p.id == selectedId,
                  ping: controller.pingOf(p.id),
                  isPinging: controller.isPinging(p.id),
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
