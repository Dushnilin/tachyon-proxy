import 'dart:async';
import 'dart:math' as math;

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
import '../profiles/profiles_tab.dart' show showBalancerSettingsSheet;
import '../profiles/tv_receive_dialog.dart';

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

    final isWideTv = MediaQuery.sizeOf(context).width >= 780;

    final dialAndModeColumn = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: Space.xs),
        _PowerDial(
          status: tunnel.status,
          pausedWifiSsid: tunnel.pausedWifiSsid,
          downSpeed: controller.downSpeed,
          upSpeed: controller.upSpeed,
          pingMs: controller.urlTestPing,
          onPressed: (controller.canConnect ||
                  controller.settings.visibleSubscriptions.isNotEmpty ||
                  tunnel.isPausedByWifi)
              ? controller.toggleTunnel
              : null,
        ),
        const SizedBox(height: Space.md),
        _StatusLine(
          tunnel: tunnel,
          fallbackServerName: isDesyncMode
              ? 'Режим Десинхронизации (Desync)'
              : (controller.selectedProfile?.name ?? ''),
        ),
        if (tunnel.isPausedByWifi) ...[
          const SizedBox(height: Space.md),
          _HomeWifiPauseBanner(controller: controller),
        ],
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
      ],
    );

    final detailsListChildren = <Widget>[
      if (tunnel.status.isActive) ...[
        if (!isWideTv) const SizedBox(height: Space.lg),
        _ExitNodeCard(controller: controller),
        const SizedBox(height: Space.lg),
      ] else if (!isWideTv) ...[
        const SizedBox(height: Space.lg),
      ],
      _TrafficRow(controller: controller),
      const SizedBox(height: Space.lg),
      _StatsRow(controller: controller),
      const SizedBox(height: Space.lg),
      _ProfileCard(controller: controller),
      if (controller.settings.visibleProfiles.isNotEmpty) ...[
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
                  : const Icon(Icons.network_check_rounded, size: 16),
              label: const Text('Лучший'),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        if (controller.settings.visibleSubscriptions.isNotEmpty) ...[
          for (final sub in controller.settings.visibleSubscriptions) ...[
            _buildSubscriptionSection(context, controller, sub),
            const SizedBox(height: Space.md),
          ],
          if (controller.settings.visibleProfiles
              .any((p) => p.subscriptionId.isEmpty)) ...[
            SectionLabel(
              'Пользовательские серверы',
              trailing: Text(
                '${controller.settings.visibleProfiles.where((p) => p.subscriptionId.isEmpty).length}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            for (final p in _filter(controller.sortProfiles(
              controller.settings.visibleProfiles
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
                    color: controller.sortByPing ? tokens.accent : tokens.muted,
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
              controller.sortProfiles(controller.settings.visibleProfiles))) ...[
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
    ];

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.lg, Space.lg, 0),
        child: Column(
          children: [
            Row(
              children: [
                const Expanded(
                  child: Wordmark(subtitle: 'Маршрутизация и туннелирование'),
                ),
                IconButton(
                  tooltip: 'Принять подписку с телефона по Wi-Fi (Android TV)',
                  onPressed: () => showTvReceiveDialog(context, controller),
                  icon: const Icon(Icons.tv_rounded, size: 20),
                ),
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
              child: isWideTv
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 340,
                          child: SingleChildScrollView(
                            child: dialAndModeColumn,
                          ),
                        ),
                        const SizedBox(width: Space.xl),
                        Expanded(
                          child: SingleChildScrollView(
                            child: Column(children: detailsListChildren),
                          ),
                        ),
                      ],
                    )
                  : SingleChildScrollView(
                      child: Column(
                        children: [
                          dialAndModeColumn,
                          ...detailsListChildren,
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
          FocusableTap(
            borderRadius: BorderRadius.circular(Radii.card),
            onTap: () => controller.toggleSubCollapsed(sub.id),
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
                    icon: controller.loadingSubscription
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync, size: 18),
                    onPressed: controller.loadingSubscription
                        ? null
                        : () async {
                            final count = await controller.fetchSubscription(sub.id);
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
                  ),
                ],
              ),
            ),
          ),
          if (!isCollapsed) ...[
            if (subProfiles.isNotEmpty) ...[
              const Divider(height: Space.sm),
              HairlineCard(
                onTap: () => controller.selectProfile('auto:${sub.id}'),
                padding: const EdgeInsets.symmetric(
                  horizontal: Space.md,
                  vertical: Space.sm,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.bolt_rounded,
                      size: 18,
                      color: controller.settings.selectedProfileId == 'auto:${sub.id}'
                          ? tokens.accent
                          : tokens.muted,
                    ),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Автовыбор (${controller.settings.balancer.modeOption.title})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: controller.settings.selectedProfileId == 'auto:${sub.id}'
                                      ? tokens.accent
                                      : tokens.ink,
                                ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.settings.selectedProfileId == 'auto:${sub.id}' &&
                                    controller.activeBalancerWinner != null
                                ? 'Активен: ${controller.activeBalancerWinner!.name}'
                                : controller.settings.balancer.modeOption.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontSize: 11,
                                  color: controller.settings.selectedProfileId == 'auto:${sub.id}' &&
                                          controller.activeBalancerWinner != null
                                      ? tokens.success
                                      : tokens.faint,
                                ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.all(4),
                      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
                      tooltip: 'Алгоритм балансировщика',
                      onPressed: () => showBalancerSettingsSheet(context, controller),
                      icon: Icon(
                        Icons.tune_rounded,
                        size: 17,
                        color: controller.settings.selectedProfileId == 'auto:${sub.id}'
                            ? tokens.accent
                            : tokens.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
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

/// Многослойный тахионный реактор и спидометр подключения (вдохновлён OrbitDialView из MSN-GUARD,
/// адаптирован под Tachyon: 60 делений спидометра, 3-лепестковая электромагнитная волна,
/// ветвящиеся молнии, ударные волны, стеклянное 3D-ядро с бликом и пружинящим откликом).
class _PowerDial extends StatefulWidget {
  const _PowerDial({
    required this.status,
    required this.onPressed,
    this.pausedWifiSsid = '',
    this.downSpeed = 0,
    this.upSpeed = 0,
    this.pingMs,
  });

  final VpnStatus status;
  final VoidCallback? onPressed;
  final String pausedWifiSsid;
  final int downSpeed;
  final int upSpeed;
  final int? pingMs;

  @override
  State<_PowerDial> createState() => _PowerDialState();
}

class _PowerDialState extends State<_PowerDial> with TickerProviderStateMixin {
  late final AnimationController _loopController;
  late final AnimationController _revealController;
  bool _pressed = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    );
    if (widget.status.isActive || widget.status.isBusy) {
      _loopController.repeat();
    }
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
      value: widget.status == VpnStatus.connected ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant _PowerDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status) {
      if (widget.status.isActive || widget.status.isBusy) {
        if (!_loopController.isAnimating) {
          _loopController.repeat();
        }
      } else {
        _loopController.stop();
      }
      if (widget.status == VpnStatus.connected) {
        HapticFeedback.heavyImpact();
        _revealController.forward(from: 0.0);
      } else if (widget.status == VpnStatus.failed) {
        HapticFeedback.vibrate();
        _revealController.reverse();
      } else {
        _revealController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 320),
          curve: const Cubic(0.22, 1.0, 0.36, 1.0),
        );
      }
    }
  }

  @override
  void dispose() {
    _loopController.dispose();
    _revealController.dispose();
    super.dispose();
  }

  static String _shortSpeed(int bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024) return '$bytesPerSec Б/с';
    if (bytesPerSec < 1024 * 1024) {
      return '${(bytesPerSec / 1024).toStringAsFixed(0)} КБ/с';
    }
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} МБ/с';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final Color primary;
    final Color secondary;
    final String label;
    switch (widget.status) {
      case VpnStatus.connected:
        primary = tokens.success;
        secondary = tokens.accent;
        label = 'Подключено';
      case VpnStatus.connecting:
        primary = tokens.accent;
        secondary = const Color(0xFF38BDF8);
        label = 'Разгон ядра';
      case VpnStatus.disconnecting:
        primary = tokens.warning;
        secondary = tokens.accent;
        label = 'Отключение';
      case VpnStatus.failed:
        primary = tokens.danger;
        secondary = tokens.warning;
        label = 'Сбой';
      case VpnStatus.disconnected:
        if (widget.pausedWifiSsid.isNotEmpty) {
          primary = tokens.accent;
          secondary = tokens.line;
          label = 'Авто-пауза Wi-Fi';
        } else {
          primary = tokens.muted;
          secondary = tokens.line;
          label = 'Запустить';
        }
    }

    final liveSpeed = widget.status == VpnStatus.connected
        ? _shortSpeed(widget.downSpeed + widget.upSpeed)
        : '';

    return FocusableActionDetector(
      autofocus: true,
      enabled: widget.onPressed != null,
      onShowFocusHighlight: (f) {
        if (_focused != f) setState(() => _focused = f);
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            HapticFeedback.mediumImpact();
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.onPressed == null
            ? null
            : (_) {
                HapticFeedback.lightImpact();
                setState(() => _pressed = true);
              },
        onTapCancel: () {
          if (_pressed) setState(() => _pressed = false);
        },
        onTapUp: widget.onPressed == null
            ? null
            : (_) {
                setState(() => _pressed = false);
                HapticFeedback.mediumImpact();
                widget.onPressed?.call();
              },
        child: AnimatedScale(
          scale: _pressed ? 0.97 : (_focused ? 1.02 : 1.0),
          duration: Duration(milliseconds: _pressed ? 100 : 180),
          curve: const Cubic(0.22, 1.0, 0.36, 1.0),
          child: Container(
            width: 240,
            height: 240,
            decoration: _focused
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: tokens.accent.withValues(alpha: 0.85),
                      width: 2.0,
                    ),
                  )
                : null,
            child: AnimatedBuilder(
              animation: Listenable.merge([_loopController, _revealController]),
              builder: (context, child) {
                return CustomPaint(
                  painter: _TachyonDialPainter(
                    status: widget.status,
                    phase: _loopController.value,
                    reveal: CurvedAnimation(
                      parent: _revealController,
                      curve: const Cubic(0.22, 1.0, 0.36, 1.0),
                    ).value,
                    primaryColor: primary,
                    secondaryColor: secondary,
                    surfaceColor: tokens.raised,
                    lineColor: tokens.line,
                    inkColor: tokens.ink,
                    downSpeed: widget.downSpeed,
                  ),
                  child: child,
                );
              },
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      child: TachyonBoltIcon(
                        key: ValueKey<VpnStatus>(widget.status),
                        size: 46,
                        primaryColor: tokens.ink,
                        secondaryColor: widget.status == VpnStatus.disconnected
                            ? tokens.accent
                            : primary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                        color: widget.status == VpnStatus.disconnected
                            ? tokens.muted
                            : primary,
                      ),
                    ),
                    if (liveSpeed.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        liveSpeed,
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: tokens.ink,
                        ),
                      ),
                    ] else if (widget.status == VpnStatus.connected &&
                        widget.pingMs != null &&
                        widget.pingMs! > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${widget.pingMs} мс',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                          fontFamily: 'monospace',
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: tokens.muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TachyonDialPainter extends CustomPainter {
  _TachyonDialPainter({
    required this.status,
    required this.phase,
    required this.reveal,
    required this.primaryColor,
    required this.secondaryColor,
    required this.surfaceColor,
    required this.lineColor,
    required this.inkColor,
    required this.downSpeed,
  });

  final VpnStatus status;
  final double phase;
  final double reveal;
  final Color primaryColor;
  final Color secondaryColor;
  final Color surfaceColor;
  final Color lineColor;
  final Color inkColor;
  final int downSpeed;

  static const int _tickCount = 60;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = math.min(size.width, size.height) / 2;
    final dialR = maxR * 0.84;
    final ringR = dialR * 0.94;
    final coreR = dialR * 0.72;

    final isConnected = status == VpnStatus.connected;
    final isConnecting =
        status == VpnStatus.connecting || status == VpnStatus.disconnecting;

    // 1. Внешнее инструментальное кольцо отсчёта (только тонкий контур без размытого свечения)
    canvas.drawCircle(
      center,
      dialR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = (isConnected || isConnecting ? primaryColor : lineColor)
            .withValues(alpha: isConnected || isConnecting ? 0.24 : 0.65),
    );

    // 2. 60 делений приборной шкалы (60 Gauge Ticks — полный круг 360°)
    final speedBoost = (math.log(downSpeed + 1) / math.log(10 * 1024 * 1024 + 1))
        .clamp(0.0, 1.0);
    final litTicks = (_tickCount * reveal).round();
    final runnerIdx = ((phase * _tickCount) % _tickCount).floor();

    for (var i = 0; i < _tickCount; i++) {
      final isMajor = i % 5 == 0;
      final angle = -math.pi / 2 + (i * 2 * math.pi / _tickCount);
      var len = isMajor ? 8.5 : 4.5;
      final strokeW = isMajor ? 1.8 : 1.2;
      Color tickColor;

      if (isConnecting) {
        final wave = math
            .pow(0.5 + 0.5 * math.sin(angle * 2 - phase * 2 * math.pi), 2.0)
            .toDouble();
        len += 2.5 * wave;
        tickColor = primaryColor.withValues(
          alpha: (0.25 + 0.70 * wave).clamp(0.0, 1.0),
        );
      } else if (isConnected) {
        if (i < litTicks) {
          final distToRunner = math.min(
            (i - runnerIdx).abs(),
            _tickCount - (i - runnerIdx).abs(),
          );
          final runnerGlow = (1.0 - (distToRunner / 4.0)).clamp(0.0, 1.0);
          len += (isMajor ? 1.5 : 0.8) * speedBoost + 2.0 * runnerGlow;
          tickColor = Color.lerp(primaryColor, inkColor, runnerGlow * 0.45)!
              .withValues(alpha: (0.82 + 0.18 * runnerGlow).clamp(0.0, 1.0));
        } else {
          tickColor = lineColor.withValues(alpha: isMajor ? 0.65 : 0.35);
        }
      } else {
        // В покое шкала полностью статична
        tickColor = lineColor.withValues(alpha: isMajor ? 0.85 : 0.45);
      }

      final rOuter = ringR;
      final rInner = ringR - len;
      final p1 = Offset(
        center.dx + rInner * math.cos(angle),
        center.dy + rInner * math.sin(angle),
      );
      final p2 = Offset(
        center.dx + rOuter * math.cos(angle),
        center.dy + rOuter * math.sin(angle),
      );
      canvas.drawLine(
        p1,
        p2,
        Paint()
          ..color = tickColor
          ..strokeWidth = strokeW
          ..strokeCap = StrokeCap.round,
      );
    }

    // 3. Внутренняя дуга состояния канала
    final arcR = coreR + (ringR - coreR) * 0.34;
    final arcRect = Rect.fromCircle(center: center, radius: arcR);
    canvas.drawCircle(
      center,
      arcR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = lineColor.withValues(alpha: 0.45),
    );

    if (isConnecting) {
      final startAngle = phase * 2 * math.pi - math.pi / 2;
      const sweep = math.pi * 0.65;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = primaryColor;
      canvas.drawArc(arcRect, startAngle, sweep, false, arcPaint);
    } else if (isConnected && reveal > 0.01) {
      final sweep = 2 * math.pi * reveal;
      const startAngle = -math.pi / 2;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = primaryColor.withValues(alpha: 0.85);
      canvas.drawArc(arcRect, startAngle, sweep, false, arcPaint);
    }

    // 4. Центральный приборный диск (без мыльных бликов и молний)
    canvas.drawCircle(
      center,
      coreR,
      Paint()..color = surfaceColor,
    );
    canvas.drawCircle(
      center,
      coreR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = isConnected || isConnecting
            ? primaryColor.withValues(alpha: 0.45)
            : lineColor,
    );
  }

  @override
  bool shouldRepaint(covariant _TachyonDialPainter old) {
    return old.phase != phase ||
        old.reveal != reveal ||
        old.status != status ||
        old.downSpeed != downSpeed ||
        old.primaryColor != primaryColor;
  }
}

/// Карточка выходного узла: ISO-код страны, внешний IP, провайдер и задержка.
class _ExitNodeCard extends StatelessWidget {
  const _ExitNodeCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ip = controller.exitIp;
    final cc = controller.exitFlag.trim();
    final refreshing = controller.refreshingExitGeo || controller.testingUrlPing;
    final ping = controller.urlTestPing;
    final locationParts = <String>[
      if (controller.exitCountry.isNotEmpty) controller.exitCountry,
      if (controller.exitCity.isNotEmpty) controller.exitCity,
      if (controller.exitIsp.isNotEmpty) controller.exitIsp,
    ];

    return HairlineCard(
      onTap: refreshing ? null : controller.refreshExitGeo,
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(Radii.control),
              border: Border.all(color: tokens.line),
            ),
            child: cc.isNotEmpty
                ? Text(
                    cc,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: tokens.accent,
                    ),
                  )
                : Icon(
                    Icons.public_outlined,
                    size: 18,
                    color: tokens.muted,
                  ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Выходной узел',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        color: tokens.muted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (refreshing)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: tokens.accent,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  ip.isNotEmpty
                      ? ip
                      : (refreshing ? 'Определение IP...' : 'Нажмите для проверки IP'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: tokens.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  locationParts.isNotEmpty
                      ? locationParts.join(' · ')
                      : (controller.settings.routingMode == RoutingMode.desync
                          ? 'Прямой маршрут с десинхронизацией (Desync)'
                          : 'Нажмите, чтобы обновить гео и задержку'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.muted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: tokens.surface,
              borderRadius: BorderRadius.circular(Radii.tag),
              border: Border.all(color: tokens.line),
            ),
            child: Text(
              ping != null && ping > 0 ? '$ping мс' : '— мс',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                fontFamily: 'monospace',
                fontFeatures: const [FontFeature.tabularFigures()],
                color: ping == null || ping < 0
                    ? tokens.muted
                    : (ping < 160
                        ? tokens.success
                        : (ping < 350 ? tokens.warning : tokens.danger)),
              ),
            ),
          ),
        ],
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

    if (tunnel.isPausedByWifi) {
      return Column(
        children: [
          Text(
            'ДОМАШНИЙ WI-FI',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: tokens.accent,
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            '${tunnel.pausedWifiSsid} · маршрутизация на паузе',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: tokens.muted,
                ),
          ),
        ],
      );
    }

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

/// Баннер авто-паузы в домашней Wi-Fi сети с кнопками принудительного запуска и отключения.
class _HomeWifiPauseBanner extends StatelessWidget {
  const _HomeWifiPauseBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ssid = controller.tunnel.pausedWifiSsid;

    return HairlineCard(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.home_rounded, size: 18, color: tokens.accent),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  'Домашний интернет · $ssid',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: tokens.ink,
                  ),
                ),
              ),
              Pill(label: 'НА ПАУЗЕ', color: tokens.accent),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Маршрутизация отключена, пока телефон подключён к этой Wi-Fi сети. Как только вы отключитесь от неё, туннель поднимется автоматически.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: tokens.muted,
            ),
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 34),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: controller.forceResumeFromHomeWifi,
                  icon: const Icon(Icons.bolt_rounded, size: 16),
                  label: const Text('Включить сейчас'),
                ),
              ),
              const SizedBox(width: Space.sm),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: controller.toggleTunnel,
                icon: const Icon(Icons.stop_rounded, size: 16),
                label: const Text('Выключить'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Моноширинная телеметрическая сводка маршрутизации (Signature-строка).
class _StatsRow extends StatelessWidget {
  const _StatsRow({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final settings = controller.settings;

    final enabled = settings.ruleSets.where((set) => set.enabled).length +
        settings.customRules.where((r) => r.enabled).length;
    final dnsCount = settings.dns.servers.isEmpty
        ? 'авто'
        : '${settings.dns.servers.length}';

    Widget item(String label, String val) {
      return Expanded(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$label ',
              style: TextStyle(
                fontSize: 11.5,
                color: tokens.muted,
              ),
            ),
            Flexible(
              child: Text(
                val,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: tokens.ink,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return HairlineCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: 10),
      child: Row(
        children: [
          item('Режим:', settings.routingMode.label),
          Container(width: 1, height: 14, color: tokens.line),
          item('DNS:', dnsCount),
          Container(width: 1, height: 14, color: tokens.line),
          item('Правил:', '$enabled'),
        ],
      ),
    );
  }
}

/// Трафик: отправлено, получено, живая скорость, единый спарклайн и активные соединения.
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
                      label: 'Получено',
                      value: stats?.downText ?? '—',
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '↓ ${_fmtRate(controller.downSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
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
                      label: 'Отправлено',
                      value: stats?.upText ?? '—',
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '↑ ${_fmtRate(controller.upSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: tokens.muted,
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
                  downColor: tokens.accent,
                  upColor: tokens.muted.withValues(alpha: 0.65),
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
    final isAutoBalancer = profile.type == 'urltest';
    final balancerMode = controller.settings.balancer.modeOption;
    final winner = controller.activeBalancerWinner;

    return HairlineCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(
                label: isAutoBalancer
                    ? 'BALANCER · ${balancerMode.shortBadge}'
                    : profile.type.toUpperCase(),
                color: tokens.accent,
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  isAutoBalancer
                      ? (winner != null
                          ? 'Активен: ${winner.name}'
                          : 'Пул Top-${controller.settings.balancer.pool}')
                      : '${profile.server}:${profile.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: isAutoBalancer && winner != null
                        ? tokens.success
                        : tokens.faint,
                    fontFamily: 'monospace',
                  ),
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
                  isAutoBalancer
                      ? '${balancerMode.title} · ${balancerMode.subtitle}'
                      : profile.fullTransportLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FocusableTap(
                borderRadius: BorderRadius.circular(8),
                onTap: controller.testingUrlPing
                    ? null
                    : () => controller.testUrlPing(),
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
              if (isAutoBalancer)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Настроить алгоритм балансировщика',
                  onPressed: () => showBalancerSettingsSheet(context, controller),
                  icon: Icon(Icons.tune_rounded, size: 20, color: tokens.accent),
                )
              else
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
              child: FocusableTap(
                borderRadius: BorderRadius.circular(8),
                focusBorderColor:
                    mode == RoutingMode.desync ? tokens.warning : tokens.accent,
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
          FocusableTap(
            borderRadius: BorderRadius.circular(6),
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
