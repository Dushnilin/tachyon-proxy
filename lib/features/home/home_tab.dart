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
                    const SizedBox(height: Space.xs),
                    _PowerDial(
                      status: tunnel.status,
                      downSpeed: controller.downSpeed,
                      upSpeed: controller.upSpeed,
                      pingMs: controller.urlTestPing,
                      onPressed: (controller.canConnect ||
                              controller.settings.subscriptions.isNotEmpty)
                          ? controller.toggleTunnel
                          : null,
                    ),
                    const SizedBox(height: Space.md),
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
                    if (tunnel.status.isActive) ...[
                      const SizedBox(height: Space.lg),
                      _ExitNodeCard(controller: controller),
                    ],
                    const SizedBox(height: Space.lg),
                    _TrafficRow(controller: controller),
                    const SizedBox(height: Space.lg),
                    _StatsRow(controller: controller),
                    const SizedBox(height: Space.lg),
                    _ProfileCard(controller: controller),
                    const SizedBox(height: Space.lg),
                    _FreeTunnelsCard(controller: controller),
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

/// Многослойный тахионный реактор и спидометр подключения (вдохновлён OrbitDialView из MSN-GUARD,
/// адаптирован под Tachyon: 60 делений спидометра, 3-лепестковая электромагнитная волна,
/// ветвящиеся молнии, ударные волны, стеклянное 3D-ядро с бликом и пружинящим откликом).
class _PowerDial extends StatefulWidget {
  const _PowerDial({
    required this.status,
    required this.onPressed,
    this.downSpeed = 0,
    this.upSpeed = 0,
    this.pingMs,
  });

  final VpnStatus status;
  final VoidCallback? onPressed;
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

  @override
  void initState() {
    super.initState();
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
    _revealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
      value: widget.status == VpnStatus.connected ? 1.0 : 0.0,
    );
  }

  @override
  void didUpdateWidget(covariant _PowerDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status != oldWidget.status) {
      if (widget.status == VpnStatus.connected) {
        HapticFeedback.heavyImpact();
        _revealController.forward(from: 0.0);
      } else if (widget.status == VpnStatus.failed) {
        HapticFeedback.vibrate();
        _revealController.reverse();
      } else {
        _revealController.animateTo(
          0.0,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
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
        primary = tokens.muted;
        secondary = tokens.line;
        label = 'Запустить';
    }

    final liveSpeed = widget.status == VpnStatus.connected
        ? _shortSpeed(widget.downSpeed + widget.upSpeed)
        : '';

    return GestureDetector(
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
        scale: _pressed ? 0.958 : 1.0,
        duration: Duration(milliseconds: _pressed ? 95 : 190),
        curve: _pressed ? Curves.easeOutQuad : Curves.elasticOut,
        child: SizedBox(
          width: 256,
          height: 256,
          child: AnimatedBuilder(
            animation: Listenable.merge([_loopController, _revealController]),
            builder: (context, child) {
              return CustomPaint(
                painter: _TachyonDialPainter(
                  status: widget.status,
                  phase: _loopController.value,
                  reveal: CurvedAnimation(
                    parent: _revealController,
                    curve: Curves.easeOutCubic,
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
                    duration: const Duration(milliseconds: 260),
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: TachyonBoltIcon(
                      key: ValueKey<VpnStatus>(widget.status),
                      size: widget.status == VpnStatus.connected ? 62 : 56,
                      primaryColor: widget.status == VpnStatus.disconnected
                          ? tokens.ink.withValues(alpha: 0.9)
                          : Colors.white,
                      secondaryColor: widget.status == VpnStatus.disconnected
                          ? const Color(0xFF60A5FA)
                          : primary,
                      glow: widget.status.isActive || widget.status.isBusy,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.7,
                      color: widget.status == VpnStatus.disconnected
                          ? tokens.muted
                          : primary,
                    ),
                  ),
                  if (liveSpeed.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '⚡ $liveSpeed',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        color: tokens.ink.withValues(alpha: 0.9),
                      ),
                    ),
                  ] else if (widget.status == VpnStatus.connected &&
                      widget.pingMs != null &&
                      widget.pingMs! > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      '${widget.pingMs} мс',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
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
    // Запас под ударные волны и гало (как BLEED_DP в OrbitDialView)
    final dialR = maxR * 0.76;
    final ringR = dialR * 0.93;
    final coreR = dialR * 0.72;

    final isConnected = status == VpnStatus.connected;
    final isConnecting = status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    final breath = 0.5 + 0.5 * math.sin(phase * 2 * math.pi);

    // 1. Дышащее энергетическое гало (Breathing Halo)
    final haloAlpha = isConnected
        ? (0.18 + 0.10 * breath)
        : isConnecting
            ? (0.14 + 0.08 * breath)
            : (0.05 + 0.03 * breath);
    final haloRadius = dialR * (1.16 + 0.06 * breath);
    final haloPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          primaryColor.withValues(alpha: haloAlpha),
          secondaryColor.withValues(alpha: haloAlpha * 0.45),
          primaryColor.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.58, 1.0],
      ).createShader(Rect.fromCircle(center: center, radius: haloRadius));
    canvas.drawCircle(center, haloRadius, haloPaint);

    // 2. Расходящиеся ударные волны (Shockwave Ripples) в активном состоянии и при разгоне
    if (isConnected || isConnecting) {
      for (var i = 0; i < 2; i++) {
        final p = (phase + i * 0.5) % 1.0;
        final fade = math.pow(1.0 - p, 1.85).toDouble();
        final rippleR = ringR * (1.0 + 0.30 * p);
        final rippleAlpha = (isConnected ? 0.34 : 0.24) * fade;
        final ripplePaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (2.2 - 1.1 * p).clamp(0.7, 2.5)
          ..color = Color.lerp(primaryColor, secondaryColor, p)!
              .withValues(alpha: rippleAlpha);
        canvas.drawCircle(center, rippleR, ripplePaint);
      }
    }

    // 3. Внешнее вращающееся пунктирное орбитальное кольцо (Orbit Track)
    final orbitR = dialR * 1.02;
    final orbitSegments = 36;
    final orbitRot = phase * 2 * math.pi * (isConnecting ? 1.0 : 0.25);
    final orbitPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..color = (isConnected || isConnecting ? primaryColor : lineColor)
          .withValues(alpha: isConnected || isConnecting ? 0.32 : 0.45);
    final segSweep = (2 * math.pi / orbitSegments) * 0.45;
    for (var i = 0; i < orbitSegments; i++) {
      final a = orbitRot + (i * 2 * math.pi / orbitSegments);
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: orbitR),
        a,
        segSweep,
        false,
        orbitPaint,
      );
    }

    // 4. 60 делений тахионного спидометра (60 Gauge Ticks — полный круг 360°)
    final speedBoost = (math.log(downSpeed + 1) / math.log(10 * 1024 * 1024 + 1))
        .clamp(0.0, 1.0);
    final litTicks = (_tickCount * reveal).round();
    final runnerIdx = ((phase * _tickCount) % _tickCount).floor();

    for (var i = 0; i < _tickCount; i++) {
      final isMajor = i % 5 == 0;
      final angle = -math.pi / 2 + (i * 2 * math.pi / _tickCount);
      var len = isMajor ? 9.5 : 5.5;
      var strokeW = isMajor ? 2.1 : 1.35;
      Color tickColor;

      if (isConnecting) {
        // 3-лепестковая стоячая электромагнитная волна из OrbitDialView
        final wave = math
            .pow(0.5 + 0.5 * math.sin(angle * 3 - phase * 4 * math.pi), 2.4)
            .toDouble();
        len += 4.5 * wave;
        final c = Color.lerp(primaryColor, Colors.white, wave * 0.55)!;
        tickColor = c.withValues(alpha: (0.22 + 0.72 * wave).clamp(0.0, 1.0));
      } else if (isConnected) {
        if (i < litTicks) {
          final t = i / _tickCount;
          final c = Color.lerp(primaryColor, secondaryColor, (0.5 - 0.5 * math.cos(t * 2 * math.pi)))!;
          final pulse = 0.85 + 0.15 * math.sin(phase * 2 * math.pi - t * 2 * math.pi);
          final distToRunner = math.min(
            (i - runnerIdx).abs(),
            _tickCount - (i - runnerIdx).abs(),
          );
          final runnerGlow = (1.0 - (distToRunner / 5.0)).clamp(0.0, 1.0);
          len += (isMajor ? 2.0 : 1.0) * speedBoost + 3.2 * runnerGlow;
          strokeW += 0.45 * runnerGlow;
          final litColor = Color.lerp(c, Colors.white, runnerGlow * 0.6)!;
          tickColor = litColor.withValues(
            alpha: (0.86 * pulse + 0.14 * runnerGlow).clamp(0.0, 1.0),
          );
        } else {
          tickColor = lineColor.withValues(alpha: isMajor ? 0.55 : 0.30);
        }
      } else {
        // Отключено: мягкая волна ожидания по шкале
        final idleWave =
            0.5 + 0.5 * math.sin(angle * 2 - phase * 2 * math.pi);
        tickColor = lineColor.withValues(
          alpha: (isMajor ? 0.65 : 0.35) + 0.15 * idleWave,
        );
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

    // 5. Внутренняя градиентная дуга мощности (полные 360° при подключении)
    final arcR = coreR + (ringR - coreR) * 0.34;
    final arcRect = Rect.fromCircle(center: center, radius: arcR);
    canvas.drawCircle(
      center,
      arcR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = lineColor.withValues(alpha: 0.25),
    );

    if (isConnecting) {
      final startAngle = phase * 2 * math.pi - math.pi / 2;
      const sweep = math.pi * 0.72;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            primaryColor.withValues(alpha: 0.0),
            primaryColor,
            Colors.white,
          ],
          stops: const [0.0, 0.75, 1.0],
          transform: GradientRotation(startAngle),
        ).createShader(arcRect);
      canvas.drawArc(arcRect, startAngle, sweep, false, arcPaint);
    } else if (isConnected && reveal > 0.01) {
      final sweep = 2 * math.pi * reveal;
      const startAngle = -math.pi / 2;
      final rotAngle = startAngle + phase * 2 * math.pi;
      final arcPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.8
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            primaryColor,
            secondaryColor,
            primaryColor,
          ],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(rotAngle),
        ).createShader(arcRect);
      canvas.drawArc(arcRect, startAngle, sweep, false, arcPaint);

      // Светящийся тахионный импульс, бегущий по полному замкнутому кольцу 360°
      final headAngle = reveal < 0.99
          ? (startAngle + sweep)
          : (startAngle + phase * 2 * math.pi);
      final headPos = Offset(
        center.dx + arcR * math.cos(headAngle),
        center.dy + arcR * math.sin(headAngle),
      );
      canvas.drawCircle(
        headPos,
        5.5,
        Paint()
          ..color = primaryColor.withValues(alpha: 0.65)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
      canvas.drawCircle(headPos, 2.6, Paint()..color = Colors.white);
    }

    // 6. Объёмная стеклянная сфера (Sculpted Glass Core)
    final coreRect = Rect.fromCircle(center: center, radius: coreR);
    // Тень под ядром
    canvas.drawCircle(
      center.translate(0, 5),
      coreR,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // Базовая заливка сферы с верхним левым бликом (Top-Left Specular Highlight)
    final highlightCenter = Offset(
      center.dx - coreR * 0.32,
      center.dy - coreR * 0.34,
    );
    final coreFillPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.topLeft,
        radius: 1.25,
        colors: [
          Color.lerp(surfaceColor, primaryColor, isConnected || isConnecting ? 0.22 : 0.06)!,
          surfaceColor,
          Color.lerp(surfaceColor, Colors.black, 0.38)!,
        ],
        stops: const [0.0, 0.58, 1.0],
      ).createShader(coreRect);
    canvas.drawCircle(center, coreR, coreFillPaint);

    // Мягкое внутреннее свечение от верхнего блика
    canvas.drawCircle(
      highlightCenter,
      coreR * 0.55,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(alpha: isConnected ? 0.12 : 0.07),
            Colors.white.withValues(alpha: 0.0),
          ],
        ).createShader(
          Rect.fromCircle(center: highlightCenter, radius: coreR * 0.55),
        ),
    );

    // Пробегающий диагональный световой блик по стеклу (Sheen Band) и ветвящиеся молнии Tachyon
    canvas.save();
    canvas.clipPath(Path()..addOval(coreRect));

    if (isConnected || isConnecting) {
      final sheenPos = ((phase * 1.6) % 1.6) - 0.3; // от -0.3 до 1.3
      final sheenOffset = Offset(
        center.dx + (sheenPos - 0.5) * coreR * 2.4,
        center.dy + (sheenPos - 0.5) * coreR * 2.4,
      );
      final sheenRect = Rect.fromCenter(
        center: sheenOffset,
        width: coreR * 2.4,
        height: coreR * 0.65,
      );
      canvas.save();
      canvas.translate(sheenOffset.dx, sheenOffset.dy);
      canvas.rotate(-math.pi / 4);
      canvas.translate(-sheenOffset.dx, -sheenOffset.dy);
      canvas.drawRect(
        sheenRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: 0.0),
              primaryColor.withValues(alpha: 0.12),
              Colors.white.withValues(alpha: 0.0),
            ],
          ).createShader(sheenRect),
      );
      canvas.restore();

      // Электрические дуги / молнии Tachyon внутри реактора
      _drawLightningArcs(canvas, center, coreR);
    }
    canvas.restore();

    // Двойная окантовка стеклянного ядра (Outer Rim + Inner Hairline)
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          (isConnected || isConnecting ? primaryColor : inkColor)
              .withValues(alpha: isConnected || isConnecting ? 0.72 : 0.24),
          lineColor.withValues(alpha: 0.25),
          (isConnected || isConnecting ? secondaryColor : lineColor)
              .withValues(alpha: isConnected || isConnecting ? 0.48 : 0.15),
        ],
      ).createShader(coreRect);
    canvas.drawCircle(center, coreR, rimPaint);
    canvas.drawCircle(
      center,
      coreR - 3.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = primaryColor.withValues(
          alpha: isConnected || isConnecting ? 0.18 : 0.06,
        ),
    );
  }

  /// Рисует живые электрические разряды (молнии Tachyon) от центра ядра к ободу.
  void _drawLightningArcs(Canvas canvas, Offset center, double coreR) {
    final isConnecting = status == VpnStatus.connecting || status == VpnStatus.disconnecting;
    final boltCount = isConnecting ? 4 : 3;
    // Дискретный слот времени, чтобы молнии перещёлкивались как настоящие электрические дуги
    final timeSlot = (phase * (isConnecting ? 18 : 10)).floor();

    for (var b = 0; b < boltCount; b++) {
      final seed = timeSlot * 37 + b * 101;
      final rng = math.Random(seed);
      // Показываем дугу с вероятностью ~70% в каждом такте для эффекта мерцания разряда
      if (!isConnecting && rng.nextDouble() < 0.32) continue;

      final baseAngle = (b * 2 * math.pi / boltCount) +
          phase * 2 * math.pi * (isConnecting ? 1.2 : 0.35) +
          (rng.nextDouble() - 0.5) * 0.45;

      final path = Path();
      const steps = 6;
      final startR = coreR * 0.22;
      final endR = coreR * 0.94;

      for (var s = 0; s <= steps; s++) {
        final t = s / steps;
        final r = startR + (endR - startR) * t;
        final jitter = (s == 0 || s == steps)
            ? 0.0
            : (rng.nextDouble() - 0.5) * 0.34;
        final a = baseAngle + jitter;
        final pt = Offset(
          center.dx + r * math.cos(a),
          center.dy + r * math.sin(a),
        );
        if (s == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }

      // Мягкое свечение разряда
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = primaryColor.withValues(alpha: isConnecting ? 0.36 : 0.24)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      // Тонкое яркое ядро молнии
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.15
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white.withValues(alpha: isConnecting ? 0.72 : 0.48),
      );
    }
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

/// Карточка выходного узла (вдохновлена ExitNodeCard из MSN-GUARD):
/// флаг страны в скульптурной плитке, внешний IP, геолокация/провайдер и живой спарклайн задержки.
class _ExitNodeCard extends StatelessWidget {
  const _ExitNodeCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ip = controller.exitIp;
    final flag = controller.exitFlag.isNotEmpty ? controller.exitFlag : '⚡';
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
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  tokens.accent.withValues(alpha: 0.20),
                  tokens.success.withValues(alpha: 0.10),
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tokens.accent.withValues(alpha: 0.35)),
            ),
            child: Text(
              flag,
              style: const TextStyle(fontSize: 22),
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
                      'ВЫХОДНОЙ УЗЕЛ',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: tokens.accent,
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
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                    color: tokens.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  locationParts.isNotEmpty
                      ? locationParts.join(' · ')
                      : (controller.settings.routingMode == RoutingMode.desync
                          ? 'Прямой маршрут с обходом ТСПУ (Desync)'
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
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                ping != null && ping > 0 ? '$ping мс' : '— мс',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                  color: ping == null || ping < 0
                      ? tokens.muted
                      : (ping < 160
                          ? tokens.success
                          : (ping < 350 ? tokens.warning : tokens.danger)),
                ),
              ),
              const SizedBox(height: 6),
              SizedBox(
                width: 68,
                height: 22,
                child: CustomPaint(
                  painter: _LatencySparklinePainter(
                    values: controller.latencyHistory,
                    color: tokens.success,
                    lineColor: tokens.line,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LatencySparklinePainter extends CustomPainter {
  _LatencySparklinePainter({
    required this.values,
    required this.color,
    required this.lineColor,
  });

  final List<int> values;
  final Color color;
  final Color lineColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) {
      final y = size.height * 0.65;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = lineColor
          ..strokeWidth = 1.2,
      );
      return;
    }

    final pts = values.length == 1 ? [values.first, values.first] : values;
    var minV = pts.first;
    var maxV = pts.first;
    for (final v in pts) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final span = math.max(20, maxV - minV);

    final path = Path();
    final stepX = size.width / (pts.length - 1);
    Offset lastPt = Offset.zero;
    for (var i = 0; i < pts.length; i++) {
      final x = i * stepX;
      final norm = ((pts[i] - minV) / span).clamp(0.0, 1.0);
      final y = size.height - 3 - norm * (size.height - 6);
      lastPt = Offset(x, y);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0.0),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    canvas.drawCircle(lastPt, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _LatencySparklinePainter oldDelegate) => true;
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

/// Карточка быстрой генерации бесплатных туннелей (Cloudflare WARP AmneziaWG + автоподбор SHARD).
class _FreeTunnelsCard extends StatelessWidget {
  const _FreeTunnelsCard({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final busy = controller.provisioningFreeNodes;
    final status = controller.freeNodesStatus;

    return HairlineCard(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TachyonBoltIcon(
                size: 18,
                primaryColor: Colors.white,
                secondaryColor: tokens.accent,
                glow: true,
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  'Бесплатные туннели и автоподбор',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: tokens.accent,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            status.isNotEmpty
                ? status
                : 'Автогенерация Cloudflare WARP с обфускацией AmneziaWG (Anti-DPI) или гонка бесплатных узлов SHARD по живым Cloudflare Edge IP',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tokens.muted,
                ),
          ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: busy
                      ? null
                      : () async {
                          final count = await controller.provisionFreeWarp();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                count > 0
                                    ? 'Создано $count узлов WARP (AmneziaWG)'
                                    : controller.freeNodesStatus,
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.shield_outlined, size: 16),
                  label: const Text('WARP + AWG'),
                ),
              ),
              const SizedBox(width: Space.sm),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          final count =
                              await controller.provisionFreeShardNodes();
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                count > 0
                                    ? 'Подобрано $count живых узлов SHARD'
                                    : controller.freeNodesStatus,
                              ),
                            ),
                          );
                        },
                  icon: const Icon(Icons.bolt_rounded, size: 17),
                  label: const Text('Автоподбор SHARD'),
                ),
              ),
            ],
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
