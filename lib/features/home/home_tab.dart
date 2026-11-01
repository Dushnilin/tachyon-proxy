import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../app/widgets/qr_code_view.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';
import '../../core/models/tunnel_state.dart';
import '../connections/connections_screen.dart';
import '../diagnostics/diagnostics_screen.dart';

/// Главный экран: состояние туннеля и его включение.
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  Timer? _ticker;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context).startTrafficPolling();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    AppScope.read(context).stopTrafficPolling();
    super.dispose();
  }

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
    final tunnel = controller.tunnel;
    final isDesyncMode = controller.settings.routingMode == RoutingMode.desync;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(child: Wordmark(subtitle: 'ЗАЩИТА СОЕДИНЕНИЯ')),
                IconButton(
                  tooltip: 'Сканировать QR-код подписки или сервера',
                  onPressed: () async {
                    final added = await controller.scanAndImportQr();
                    if (added == null || !context.mounted) return;
                    final msg = switch (added) {
                      -1 => 'Подписка по QR добавлена — серверы загружены',
                      0 => controller.lastError.isNotEmpty
                          ? controller.lastError
                          : 'QR-код не распознан',
                      _ => 'Импортировано серверов по QR: $added',
                    };
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      SnackBar(content: Text(msg)),
                    );
                  },
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 20),
                ),
                IconButton(
                  tooltip: 'Диагностика и спидтест',
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const DiagnosticsScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.speed_rounded, size: 20),
                ),
              ],
            ),
            const SizedBox(height: Space.xl),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: Space.md),
                    _PowerDial(
                      status: tunnel.status,
                      onPressed: (controller.canConnect ||
                              controller.settings.subscriptions.isNotEmpty)
                          ? controller.toggleTunnel
                          : null,
                    ),
                    const SizedBox(height: Space.xl),
                    _StatusLine(
                      tunnel: tunnel,
                      fallbackServerName: isDesyncMode
                          ? 'Режим Обход DPI (Desync)'
                          : (controller.selectedProfile?.name ?? ''),
                    ),
                    if (tunnel.error.isNotEmpty) ...[
                      const SizedBox(height: Space.md),
                      HairlineCard(
                        padding: const EdgeInsets.all(Space.md),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.error_outline,
                              size: 16,
                              color: tokens.danger,
                            ),
                            const SizedBox(width: Space.sm),
                            Expanded(
                              child: Text(
                                tunnel.error,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: tokens.danger,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: Space.lg),
                    _QuickRoutingBar(controller: controller),
                    const SizedBox(height: Space.lg),
                    _TrafficRow(controller: controller),
                    const SizedBox(height: Space.lg),
                    _StatsRow(controller: controller),
                    const SizedBox(height: Space.lg),
                    _ProfileCard(controller: controller),
                    if (controller.settings.profiles.isNotEmpty) ...[
                      const SizedBox(height: Space.lg),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              onChanged: (v) => setState(() => _searchQuery = v),
                              decoration: const InputDecoration(
                                hintText: 'Поиск сервера или страны...',
                                prefixIcon: Icon(Icons.search, size: 18),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: Space.sm),
                          FilledButton.tonalIcon(
                            onPressed: controller.pingingAll
                                ? null
                                : () async {
                                    final best = await controller.autoSelectBestServer();
                                    if (!context.mounted || best == null) return;
                                    final ms = controller.pingOf(best.id);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          'Выбран лучший сервер: ${best.name} (${ms}ms)',
                                        ),
                                      ),
                                    );
                                  },
                            icon: controller.pingingAll
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: tokens.accent,
                                    ),
                                  )
                                : const Icon(Icons.auto_awesome, size: 16),
                            label: const Text('Лучший'),
                          ),
                        ],
                      ),
                      const SizedBox(height: Space.md),
                      if (controller.settings.subscriptions.isNotEmpty) ...[
                        for (final sub in controller.settings.subscriptions) ...[
                          _buildSubscriptionSection(context, controller, sub),
                          const SizedBox(height: Space.md),
                        ],
                        if (controller.settings.profiles
                            .any((p) => p.subscriptionId.isEmpty)) ...[
                          SectionLabel(
                            'Пользовательские серверы',
                            trailing: Text(
                              '${controller.settings.profiles.where((p) => p.subscriptionId.isEmpty).length}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          for (final p in _filter(controller.sortProfiles(
                            controller.settings.profiles
                                .where((p) => p.subscriptionId.isEmpty)
                                .toList(),
                          ))) ...[
                            _DashboardServerTile(
                              profile: p,
                              selected: p.id == controller.settings.selectedProfileId,
                              ping: controller.pingOf(p.id),
                              isPinging: controller.isPinging(p.id),
                              onSelect: () => controller.selectProfile(p.id),
                              onPing: () => controller.pingProfile(p.id),
                            ),
                            const SizedBox(height: Space.sm),
                          ],
                        ],
                      ] else ...[
                        SectionLabel(
                          'Серверы',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: 'Сортировать по пингу',
                                icon: Icon(
                                  Icons.sort_rounded,
                                  size: 18,
                                  color: controller.sortByPing
                                      ? tokens.accent
                                      : tokens.muted,
                                ),
                                onPressed: controller.toggleSortByPing,
                              ),
                              IconButton(
                                tooltip: 'Пропинговать все',
                                icon: controller.pingingAll
                                    ? SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: tokens.accent,
                                        ),
                                      )
                                    : const Icon(Icons.network_ping, size: 18),
                                onPressed: controller.pingingAll
                                    ? null
                                    : () => controller.pingAllProfiles(),
                              ),
                            ],
                          ),
                        ),
                        for (final p in _filter(
                            controller.sortProfiles(controller.settings.profiles))) ...[
                          _DashboardServerTile(
                            profile: p,
                            selected: p.id == controller.settings.selectedProfileId,
                            ping: controller.pingOf(p.id),
                            isPinging: controller.isPinging(p.id),
                            onSelect: () => controller.selectProfile(p.id),
                            onPing: () => controller.pingProfile(p.id),
                          ),
                          const SizedBox(height: Space.sm),
                        ],
                      ],
                    ],
                    const SizedBox(height: Space.lg),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubscriptionSection(
    BuildContext context,
    AppController controller,
    SubscriptionEntry sub,
  ) {
    final tokens = context.tokens;
    final title =
        sub.name.isNotEmpty ? sub.name : (Uri.tryParse(sub.url)?.host ?? sub.url);
    final isCollapsed = controller.isSubCollapsed(sub.id) && _searchQuery.trim().isEmpty;
    final subProfiles = _filter(controller.sortProfiles(
      controller.settings.profiles.where((p) => p.subscriptionId == sub.id).toList(),
    ));

    return HairlineCard(
      padding: const EdgeInsets.all(Space.sm),
      child: Column(
        children: [
          InkWell(
            onTap: () => controller.toggleSubCollapsed(sub.id),
            borderRadius: BorderRadius.circular(Radii.card),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: Space.xs),
              child: Row(
                children: [
                  Icon(
                    isCollapsed ? Icons.chevron_right : Icons.expand_more,
                    color: tokens.muted,
                    size: 20,
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
                          subProfiles.isEmpty
                              ? 'нет серверов'
                              : '${subProfiles.length} серверов · ${isCollapsed ? "развернуть" : "свернуть"}',
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
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Пропинговать все серверы',
                    icon: controller.pingingAll
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.accent,
                            ),
                          )
                        : const Icon(Icons.network_ping, size: 18),
                    onPressed: controller.pingingAll
                        ? null
                        : () => controller.pingAllProfiles(subscriptionId: sub.id),
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
                    tooltip: 'Обновить подписку',
                    icon: const Icon(Icons.sync, size: 18),
                    onPressed: () => controller.fetchSubscription(sub.id),
                  ),
                ],
              ),
            ),
          ),
          if (!isCollapsed) ...[
            if (subProfiles.isNotEmpty) ...[
              const Divider(height: Space.sm),
              for (final p in subProfiles) ...[
                _DashboardServerTile(
                  profile: p,
                  selected: p.id == controller.settings.selectedProfileId,
                  ping: controller.pingOf(p.id),
                  isPinging: controller.isPinging(p.id),
                  onSelect: () => controller.selectProfile(p.id),
                  onPing: () => controller.pingProfile(p.id),
                ),
                const SizedBox(height: 4),
              ],
            ] else ...[
              const Divider(height: Space.sm),
              Padding(
                padding: const EdgeInsets.all(Space.md),
                child: Column(
                  children: [
                    if (controller.lastError.isNotEmpty) ...[
                      Row(
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
                      const SizedBox(height: Space.sm),
                    ],
                    FilledButton.icon(
                      onPressed: controller.loadingSubscription
                          ? null
                          : () => controller.fetchSubscription(sub.id),
                      icon: controller.loadingSubscription
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download, size: 16),
                      label: Text(
                        controller.loadingSubscription
                            ? 'Загрузка...'
                            : 'Загрузить серверы сейчас',
                      ),
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

/// Круглая кнопка включения: кольцо вокруг точки.
class _PowerDial extends StatelessWidget {
  const _PowerDial({required this.status, required this.onPressed});

  final VpnStatus status;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final Color ring;
    final Color core;
    final String label;
    switch (status) {
      case VpnStatus.connected:
        ring = tokens.success;
        core = tokens.success;
        label = 'Подключено';
      case VpnStatus.connecting:
        ring = tokens.accent;
        core = tokens.accent;
        label = 'Подключение';
      case VpnStatus.disconnecting:
        ring = tokens.warning;
        core = tokens.warning;
        label = 'Отключение';
      case VpnStatus.failed:
        ring = tokens.danger;
        core = tokens.danger;
        label = 'Ошибка';
      case VpnStatus.disconnected:
        ring = tokens.line;
        core = tokens.muted;
        label = 'Отключено';
    }

    return GestureDetector(
      onTap: onPressed,
      child: SizedBox(
        width: 212,
        height: 212,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 212,
              height: 212,
              child: CircularProgressIndicator(
                value: status.isActive || status.isBusy ? null : 1,
                strokeWidth: 1,
                backgroundColor: tokens.line,
                valueColor: AlwaysStoppedAnimation<Color>(ring),
              ),
            ),
            Container(
              width: 164,
              height: 164,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: core.withValues(alpha: 0.08),
                border: Border.all(color: core.withValues(alpha: 0.28)),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.bolt_rounded,
                  size: 46,
                  color: core,
                ),
                const SizedBox(height: Space.sm),
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.6,
                    color: core,
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

/// Строка статуса: длительность сессии и адрес сервера.
class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.tunnel, this.fallbackServerName = ''});

  final TunnelState tunnel;
  final String fallbackServerName;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final duration = tunnel.connectedFor;
    final elapsed = duration == Duration.zero
        ? '—'
        : '${duration.inHours.toString().padLeft(2, '0')}:'
            '${(duration.inMinutes % 60).toString().padLeft(2, '0')}:'
            '${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

    final displayName = tunnel.serverName.isNotEmpty
        ? tunnel.serverName
        : (fallbackServerName.isNotEmpty ? fallbackServerName : 'сервер не выбран');

    return Column(
      children: [
        Text(
          elapsed,
          style: TextStyle(
            fontSize: 30,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.2,
            color: tokens.ink,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: Space.xs),
        Text(
          displayName,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// Три показателя: режим маршрутизации, DNS и число списков.
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final settings = controller.settings;

    final enabled = settings.ruleSets.where((set) => set.enabled).length +
        settings.customRules.where((r) => r.enabled).length;
    final dnsCount = settings.dns.servers.isEmpty
        ? 'авто'
        : '${settings.dns.servers.length}';

    return HairlineCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: StatTile(
              label: 'Маршрутизация',
              value: settings.routingMode.label,
              icon: Icons.alt_route,
            ),
          ),
          Expanded(
            child: StatTile(
              label: 'Резолверы',
              value: dnsCount,
              icon: Icons.dns_outlined,
            ),
          ),
          Expanded(
            child: StatTile(
              label: 'Списков',
              value: '$enabled',
              icon: Icons.rule_folder_outlined,
            ),
          ),
        ],
      ),
    );
  }
}

/// Трафик: отправлено, получено, живая скорость, мини-спарклайн и активные соединения.
class _TrafficRow extends StatelessWidget {
  const _TrafficRow({required this.controller});

  final AppController controller;

  static String _fmtRate(int bytesPerSec) {
    if (bytesPerSec <= 0) return '0 Б/с';
    if (bytesPerSec < 1024) return '$bytesPerSec Б/с';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(1)} КБ/с';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(2)} МБ/с';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final stats = controller.traffic;

    return HairlineCard(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const ConnectionsScreen()),
        );
      },
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatTile(
                      label: 'Отправлено',
                      value: stats?.upText ?? '—',
                      icon: Icons.arrow_upward,
                      color: tokens.accent,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '↑ ${_fmtRate(controller.upSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: tokens.accent,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatTile(
                      label: 'Получено',
                      value: stats?.downText ?? '—',
                      icon: Icons.arrow_downward,
                      color: tokens.success,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '↓ ${_fmtRate(controller.downSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: tokens.success,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    StatTile(
                      label: 'Соединения',
                      value: stats == null ? '—' : '${stats.connections}',
                      icon: Icons.link_outlined,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Открыть →',
                      style: TextStyle(
                        fontSize: 11,
                        color: tokens.faint,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (controller.downHistory.any((v) => v > 0) ||
              controller.upHistory.any((v) => v > 0)) ...[
            const SizedBox(height: Space.md),
            SizedBox(
              height: 28,
              width: double.infinity,
              child: CustomPaint(
                painter: _SparklinePainter(
                  downValues: controller.downHistory,
                  upValues: controller.upHistory,
                  downColor: tokens.success,
                  upColor: tokens.accent,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter({
    required this.downValues,
    required this.upValues,
    required this.downColor,
    required this.upColor,
  });

  final List<int> downValues;
  final List<int> upValues;
  final Color downColor;
  final Color upColor;

  @override
  void paint(Canvas canvas, Size size) {
    var maxVal = 1024;
    for (final v in downValues) {
      if (v > maxVal) maxVal = v;
    }
    for (final v in upValues) {
      if (v > maxVal) maxVal = v;
    }

    void drawLine(List<int> pts, Color color, {bool fill = false}) {
      if (pts.length < 2) return;
      final path = Path();
      final stepX = size.width / (pts.length - 1);
      for (var i = 0; i < pts.length; i++) {
        final x = i * stepX;
        final ratio = (pts[i] / maxVal).clamp(0.0, 1.0);
        final y = size.height - ratio * (size.height - 4) - 2;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      if (fill) {
        final fillPath = Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close();
        canvas.drawPath(
          fillPath,
          Paint()
            ..color = color.withValues(alpha: 0.14)
            ..style = PaintingStyle.fill,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke,
      );
    }

    drawLine(upValues, upColor);
    drawLine(downValues, downColor, fill: true);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) => true;
}

/// Карточка выбранного профиля.
class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final profile = controller.selectedProfile;
    final hasSubs = controller.settings.subscriptions.isNotEmpty;

    if (profile == null) {
      if (hasSubs) {
        final isLoading = controller.loadingSubscription;
        final hasError = controller.lastError.isNotEmpty;

        return HairlineCard(
          onTap: isLoading
              ? null
              : () async {
                  for (final sub in controller.settings.subscriptions) {
                    await controller.fetchSubscription(sub.id);
                  }
                },
          padding: const EdgeInsets.all(Space.md),
          child: Row(
            children: [
              if (isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (hasError)
                Icon(Icons.error_outline, size: 22, color: tokens.danger)
              else
                Icon(Icons.sync, size: 22, color: tokens.accent),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isLoading
                          ? 'Загрузка серверов...'
                          : hasError
                              ? 'Ошибка загрузки подписки'
                              : 'Подписка добавлена',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: hasError ? tokens.danger : tokens.accent,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isLoading
                          ? 'Скачиваем и парсим серверы по ссылке...'
                          : hasError
                              ? controller.lastError
                              : 'Нажмите, чтобы загрузить серверы, или перейдите во вкладку Профили',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: hasError
                                ? tokens.danger.withValues(alpha: 0.9)
                                : tokens.muted,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              if (!isLoading)
                Icon(
                  hasError ? Icons.refresh : Icons.download_rounded,
                  size: 20,
                  color: hasError ? tokens.danger : tokens.accent,
                ),
            ],
          ),
        );
      }
      return HairlineCard(
        padding: const EdgeInsets.all(Space.md),
        child: Row(
          children: [
            Icon(Icons.link_off, size: 16, color: tokens.faint),
            const SizedBox(width: Space.md),
            Expanded(
              child: Text(
                'Добавьте профиль или подписку, чтобы включить туннель',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    final urlPing = controller.urlTestPing;

    return HairlineCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: profile.type.toUpperCase(), color: tokens.accent),
              const Spacer(),
              Text(
                '${profile.server}:${profile.port}',
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.faint,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(profile.name, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              Expanded(
                child: Text(
                  profile.fullTransportLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              InkWell(
                onTap: controller.testingUrlPing
                    ? null
                    : () => controller.testUrlPing(),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tokens.line),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (controller.testingUrlPing)
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: tokens.accent,
                          ),
                        )
                      else
                        Icon(
                          Icons.speed,
                          size: 14,
                          color: urlPing == null
                              ? tokens.muted
                              : (urlPing < 0 ? tokens.danger : tokens.success),
                        ),
                      const SizedBox(width: 5),
                      Text(
                        urlPing == null
                            ? 'HTTP-тест'
                            : (urlPing < 0 ? 'Таймаут' : '$urlPing мс'),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: urlPing == null
                              ? tokens.muted
                              : (urlPing < 0 ? tokens.danger : tokens.success),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Space.xs),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'QR-код и ссылка профиля',
                onPressed: () => _showProfileQrSheet(context, controller, profile),
                icon: Icon(Icons.qr_code_2, size: 20, color: tokens.muted),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showProfileQrSheet(
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
}

/// Полоска быстрого переключения режима работы прямо на дашборде.
class _QuickRoutingBar extends StatelessWidget {
  const _QuickRoutingBar({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final current = controller.settings.routingMode;

    return HairlineCard(
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          for (final mode in RoutingMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => controller.setRoutingMode(mode),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  decoration: BoxDecoration(
                    color: current == mode
                        ? (mode == RoutingMode.desync
                            ? tokens.warning.withValues(alpha: 0.16)
                            : tokens.accent.withValues(alpha: 0.16))
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: current == mode
                        ? Border.all(
                            color: mode == RoutingMode.desync
                                ? tokens.warning.withValues(alpha: 0.5)
                                : tokens.accent.withValues(alpha: 0.5),
                          )
                        : null,
                  ),
                  child: Text(
                    mode == RoutingMode.bypass ? 'Исключения' : mode.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight:
                          current == mode ? FontWeight.w600 : FontWeight.w400,
                      color: current == mode
                          ? (mode == RoutingMode.desync
                              ? tokens.warning
                              : tokens.accent)
                          : tokens.muted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Плитка сервера на главном экране (дашборде) с быстрым выбором и пингом.
class _DashboardServerTile extends StatelessWidget {
  const _DashboardServerTile({
    required this.profile,
    required this.selected,
    required this.onSelect,
    required this.onPing,
    this.ping,
    this.isPinging = false,
  });

  final Profile profile;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onPing;
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
            width: 10,
            height: 10,
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
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                      ),
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
          const SizedBox(width: Space.sm),
          GestureDetector(
            onTap: onPing,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: tokens.raised,
                borderRadius: BorderRadius.circular(6),
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
        ],
      ),
    );
  }
}
