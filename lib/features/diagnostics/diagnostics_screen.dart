import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';

/// Экран комплексной диагностики сети, проверки доступности сервисов,
/// детектора IP/гео и встроенного спидтеста.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _checkingIp = false;
  _IpInfo? _ipInfo;
  String _traceColo = '';
  String _traceTls = '';
  String _traceHttp = '';

  bool _checkingMatrix = false;
  final Map<String, _ProbeResult> _probes = {};

  bool _runningSpeedtest = false;
  double _speedMbps = 0.0;
  double _peakMbps = 0.0;
  double _speedProgress = 0.0;
  int _downloadedBytes = 0;
  String _speedStatus =
      'Нажмите «Запустить спидтест» для замера пропускной способности';

  static const List<_ProbeTarget> _targets = [
    _ProbeTarget(
      id: 'youtube',
      title: 'YouTube API',
      subtitle: 'www.youtube.com',
      url: 'https://www.youtube.com/generate_204',
      icon: Icons.play_circle_outline_rounded,
    ),
    _ProbeTarget(
      id: 'ggc',
      title: 'YouTube Video (GGC)',
      subtitle: 'redirector.googlevideo.com',
      url: 'https://redirector.googlevideo.com',
      icon: Icons.ondemand_video_rounded,
    ),
    _ProbeTarget(
      id: 'discord',
      title: 'Discord API',
      subtitle: 'discord.com',
      url: 'https://discord.com/api/v9/experiments',
      icon: Icons.headset_mic_outlined,
    ),
    _ProbeTarget(
      id: 'telegram',
      title: 'Telegram',
      subtitle: 'core.telegram.org',
      url: 'https://core.telegram.org',
      icon: Icons.send_rounded,
    ),
    _ProbeTarget(
      id: 'openai',
      title: 'ChatGPT / OpenAI',
      subtitle: 'chatgpt.com',
      url: 'https://chatgpt.com',
      icon: Icons.auto_awesome_outlined,
    ),
    _ProbeTarget(
      id: 'cloudflare',
      title: 'Cloudflare Trace',
      subtitle: '1.1.1.1 / cdn-cgi',
      url: 'https://1.1.1.1/cdn-cgi/trace',
      icon: Icons.cloud_outlined,
    ),
    _ProbeTarget(
      id: 'ru_direct',
      title: 'Сайты РФ (Яндекс)',
      subtitle: 'ya.ru (проверка прямого обхода)',
      url: 'https://ya.ru',
      icon: Icons.language_rounded,
    ),
  ];

  @override
  void initState() {
    super.initState();
    unawaited(_runFullDiagnostics());
  }

  Future<void> _runFullDiagnostics() async {
    await Future.wait([
      _checkIpAndTrace(),
      _checkMatrix(),
    ]);
  }

  HttpClient _newHttpClient(Duration timeout) {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..badCertificateCallback = ((_, _, _) => true);
    if (mounted && AppScope.read(context).tunnel.status.isActive) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
    }
    return client;
  }

  Future<void> _checkIpAndTrace() async {
    if (_checkingIp) return;
    setState(() => _checkingIp = true);
    final client = _newHttpClient(const Duration(seconds: 6));
    try {
      try {
        final req = await client.getUrl(
          Uri.parse(
            'http://ip-api.com/json/?fields=status,country,countryCode,city,isp,as,query',
          ),
        );
        req.headers.set('User-Agent', 'curl/8.5.0');
        final resp = await req.close().timeout(const Duration(seconds: 6));
        final raw = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(raw) as Map<String, dynamic>;
        if (map['status'] == 'success') {
          _ipInfo = _IpInfo(
            ip: (map['query'] as String?) ?? '',
            country: (map['country'] as String?) ?? '',
            countryCode: (map['countryCode'] as String?) ?? '',
            city: (map['city'] as String?) ?? '',
            isp: (map['isp'] as String?) ?? '',
            asn: (map['as'] as String?) ?? '',
          );
        }
      } catch (_) {}

      if (_ipInfo == null) {
        try {
          final req = await client.getUrl(Uri.parse('https://ipwho.is/'));
          final resp = await req.close().timeout(const Duration(seconds: 6));
          final raw = await resp.transform(utf8.decoder).join();
          final map = jsonDecode(raw) as Map<String, dynamic>;
          if (map['success'] == true) {
            final conn = (map['connection'] as Map?) ?? const {};
            _ipInfo = _IpInfo(
              ip: (map['ip'] as String?) ?? '',
              country: (map['country'] as String?) ?? '',
              countryCode: (map['country_code'] as String?) ?? '',
              city: (map['city'] as String?) ?? '',
              isp: (conn['isp'] as String?) ?? '',
              asn: conn['asn'] != null ? 'AS${conn['asn']}' : '',
            );
          }
        } catch (_) {}
      }

      try {
        final req = await client.getUrl(Uri.parse('https://1.1.1.1/cdn-cgi/trace'));
        final resp = await req.close().timeout(const Duration(seconds: 5));
        final text = await resp.transform(utf8.decoder).join();
        for (final line in text.split('\n')) {
          final parts = line.split('=');
          if (parts.length == 2) {
            final k = parts[0].trim();
            final v = parts[1].trim();
            if (k == 'colo') _traceColo = v;
            if (k == 'tls') _traceTls = v;
            if (k == 'http') _traceHttp = v;
            if (k == 'ip' && (_ipInfo == null || _ipInfo!.ip.isEmpty)) {
              _ipInfo = _IpInfo(
                ip: v,
                country: '',
                countryCode: '',
                city: '',
                isp: '',
                asn: '',
              );
            }
          }
        }
      } catch (_) {}
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() => _checkingIp = false);
      }
    }
  }

  Future<void> _checkMatrix() async {
    if (_checkingMatrix) return;
    setState(() {
      _checkingMatrix = true;
      _probes.clear();
    });

    await Future.wait(_targets.map((target) async {
      final client = _newHttpClient(const Duration(seconds: 5));
      var ms = -1;
      var status = 0;
      try {
        final sw = Stopwatch()..start();
        final req = await client.getUrl(Uri.parse(target.url));
        req.headers.set('User-Agent', 'Mozilla/5.0 (Linux; Android 14) Chrome/124.0.0.0');
        req.followRedirects = false;
        final resp = await req.close().timeout(const Duration(seconds: 5));
        await resp.drain<void>();
        sw.stop();
        status = resp.statusCode;
        if (status > 0 && status < 500) {
          ms = sw.elapsedMilliseconds;
        }
      } catch (_) {
        ms = -1;
      } finally {
        client.close(force: true);
      }
      if (mounted) {
        setState(() {
          _probes[target.id] = _ProbeResult(ms: ms, statusCode: status);
        });
      }
    }));

    if (mounted) {
      setState(() => _checkingMatrix = false);
    }
  }

  Future<void> _runSpeedtest() async {
    if (_runningSpeedtest) return;
    setState(() {
      _runningSpeedtest = true;
      _speedMbps = 0.0;
      _peakMbps = 0.0;
      _speedProgress = 0.0;
      _downloadedBytes = 0;
      _speedStatus = 'Подключение к тестовому узлу Cloudflare (10 МБ)...';
    });

    const totalTargetBytes = 10 * 1024 * 1024;
    final client = _newHttpClient(const Duration(seconds: 8));

    try {
      final req = await client.getUrl(
        Uri.parse('https://speed.cloudflare.com/__down?bytes=$totalTargetBytes'),
      );
      req.headers.set('User-Agent', 'Mozilla/5.0 (Linux; Android 14)');
      req.headers.set('Cache-Control', 'no-cache');
      final resp = await req.close().timeout(const Duration(seconds: 10));

      final sw = Stopwatch()..start();
      var received = 0;
      var lastUpdateMs = 0;

      await for (final chunk in resp.timeout(const Duration(seconds: 20))) {
        if (!mounted) break;
        received += chunk.length;
        final elapsedMs = sw.elapsedMilliseconds;
        if (elapsedMs - lastUpdateMs >= 150 || received >= totalTargetBytes) {
          lastUpdateMs = elapsedMs;
          final secs = (elapsedMs / 1000.0).clamp(0.1, 60.0);
          final mbps = (received * 8.0) / (secs * 1000000.0);
          setState(() {
            _downloadedBytes = received;
            _speedMbps = mbps;
            if (mbps > _peakMbps) _peakMbps = mbps;
            _speedProgress = (received / totalTargetBytes).clamp(0.0, 1.0);
            _speedStatus =
                'Загружено ${(received / (1024 * 1024)).toStringAsFixed(1)} МБ за ${secs.toStringAsFixed(1)} сек';
          });
        }
      }
      sw.stop();
      final totalSecs = (sw.elapsedMilliseconds / 1000.0).clamp(0.1, 60.0);
      final avgMbps = (received * 8.0) / (totalSecs * 1000000.0);
      if (mounted) {
        setState(() {
          _speedMbps = avgMbps;
          if (avgMbps > _peakMbps) _peakMbps = avgMbps;
          _speedProgress = 1.0;
          _speedStatus =
              'Готово: средняя ${avgMbps.toStringAsFixed(1)} Мбит/с (${(avgMbps / 8).toStringAsFixed(2)} МБ/с), пик ${_peakMbps.toStringAsFixed(1)} Мбит/с';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _speedStatus = 'Ошибка замера скорости: $e';
        });
      }
    } finally {
      client.close(force: true);
      if (mounted) {
        setState(() => _runningSpeedtest = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final isConnected = controller.tunnel.status.isActive;

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Диагностика и спидтест'),
        actions: [
          IconButton(
            tooltip: 'Обновить всё',
            onPressed: (_checkingIp || _checkingMatrix) ? null : _runFullDiagnostics,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
        children: [
          SectionLabel(
            isConnected ? 'Выходной узел (Туннель активен)' : 'Текущая сеть (Без туннеля)',
          ),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: (isConnected ? tokens.success : tokens.accent)
                            .withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        isConnected ? Icons.shield_rounded : Icons.public_rounded,
                        color: isConnected ? tokens.success : tokens.accent,
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    Expanded(
                      child: _checkingIp
                          ? const Text('Определение внешнего IP и геолокации...')
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _ipInfo?.ip.isNotEmpty == true
                                      ? _ipInfo!.ip
                                      : 'IP не определён',
                                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _ipInfo != null
                                      ? [
                                          if (_ipInfo!.countryCode.isNotEmpty)
                                            '[${_ipInfo!.countryCode}]',
                                          if (_ipInfo!.country.isNotEmpty) _ipInfo!.country,
                                          if (_ipInfo!.city.isNotEmpty) _ipInfo!.city,
                                        ].join(' · ')
                                      : 'Нажмите обновить для повторной проверки',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                    ),
                  ],
                ),
                if (_ipInfo != null && (_ipInfo!.isp.isNotEmpty || _ipInfo!.asn.isNotEmpty)) ...[
                  const SizedBox(height: Space.md),
                  const Hairline(),
                  const SizedBox(height: Space.sm),
                  Row(
                    children: [
                      Icon(Icons.dns_outlined, size: 16, color: tokens.faint),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${_ipInfo!.isp} ${_ipInfo!.asn.isNotEmpty ? "(${_ipInfo!.asn})" : ""}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
                if (_traceColo.isNotEmpty || _traceTls.isNotEmpty) ...[
                  const SizedBox(height: Space.sm),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (_traceColo.isNotEmpty)
                        Pill(label: 'CF: $_traceColo', color: tokens.accent),
                      if (_traceTls.isNotEmpty)
                        Pill(label: _traceTls, color: tokens.success),
                      if (_traceHttp.isNotEmpty)
                        Pill(label: _traceHttp, color: tokens.muted),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Тест скорости (Speedtest)'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _speedMbps.toStringAsFixed(1),
                      style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: tokens.accent,
                          ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Мбит/с  (${(_speedMbps / 8).toStringAsFixed(2)} МБ/с)',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const Spacer(),
                    if (_peakMbps > 0)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          'Пик: ${_peakMbps.toStringAsFixed(1)} Мбит/с',
                          style: TextStyle(color: tokens.success, fontSize: 12),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Space.sm),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _runningSpeedtest
                        ? _speedProgress
                        : (_downloadedBytes > 0 ? 1.0 : 0.0),
                    minHeight: 8,
                    backgroundColor: tokens.line,
                    valueColor: AlwaysStoppedAnimation<Color>(tokens.accent),
                  ),
                ),
                const SizedBox(height: Space.sm),
                Text(
                  _speedStatus,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _runningSpeedtest ? null : _runSpeedtest,
                    icon: _runningSpeedtest
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.speed_rounded),
                    label: Text(
                      _runningSpeedtest
                          ? 'Идёт замер скорости...'
                          : 'Запустить спидтест (10 МБ)',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Автоподбор MTU (MtuAutoScan)'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.tune_rounded, size: 20, color: tokens.accent),
                    const SizedBox(width: Space.sm),
                    Expanded(
                      child: Text(
                        'Текущий MTU: ${controller.settings.mtu} байт',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ),
                    Pill(
                      label: '${controller.settings.mtu} B',
                      color: tokens.accent,
                    ),
                  ],
                ),
                const SizedBox(height: Space.xs),
                Text(
                  controller.mtuScanStatus.isNotEmpty
                      ? controller.mtuScanStatus
                      : 'Автоматический поиск оптимального размера пакета (1280–1460 байт) без фрагментации',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.md),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: controller.scanningMtu
                        ? null
                        : () => controller.scanOptimalMtu(),
                    icon: controller.scanningMtu
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.radar_rounded, size: 18),
                    label: Text(
                      controller.scanningMtu
                          ? 'Сканирование MTU...'
                          : 'Подобрать оптимальный MTU',
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Матрица доступности сервисов и ТСПУ'),
          HairlineCard(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (var i = 0; i < _targets.length; i++) ...[
                  if (i > 0) const Hairline(),
                  _buildProbeRow(context, _targets[i], tokens),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbeRow(
    BuildContext context,
    _ProbeTarget target,
    TachyonTokens tokens,
  ) {
    final res = _probes[target.id];
    final loading = _checkingMatrix && res == null;
    final ok = res != null && res.ms >= 0;

    final Color badgeColor;
    final String badgeText;
    if (loading) {
      badgeColor = tokens.faint;
      badgeText = '...';
    } else if (ok) {
      badgeColor = res.ms < 350 ? tokens.success : tokens.warning;
      badgeText = '${res.ms} мс';
    } else {
      badgeColor = tokens.danger;
      badgeText = 'Блок / Таймаут';
    }

    return ListTile(
      dense: true,
      leading: Icon(
        target.icon,
        color: ok ? tokens.accent : tokens.muted,
      ),
      title: Text(
        target.title,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: Text(
        target.subtitle,
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Pill(
        label: badgeText,
        color: badgeColor,
      ),
    );
  }
}

class _IpInfo {
  const _IpInfo({
    required this.ip,
    required this.country,
    required this.countryCode,
    required this.city,
    required this.isp,
    required this.asn,
  });

  final String ip;
  final String country;
  final String countryCode;
  final String city;
  final String isp;
  final String asn;
}

class _ProbeTarget {
  const _ProbeTarget({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.url,
    required this.icon,
  });

  final String id;
  final String title;
  final String subtitle;
  final String url;
  final IconData icon;
}

class _ProbeResult {
  const _ProbeResult({required this.ms, required this.statusCode});

  final int ms;
  final int statusCode;
}
