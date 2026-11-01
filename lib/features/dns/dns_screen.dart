import 'package:flutter/material.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';
import '../../core/services/dns_benchmark.dart';

/// Экран DNS: список резолверов, быстрые пресеты, FakeIP, режим маршрутизации и проверка.
class DnsScreen extends StatelessWidget {
  const DnsScreen({super.key});

  /// Заготовки резолверов, которые предлагает приложение.
  static const presets = <(String, String)>[
    ('Google DoH', 'https://dns.google/dns-query'),
    ('Cloudflare DoH', 'https://cloudflare-dns.com/dns-query'),
    ('Quad9 DoH', 'https://dns.quad9.net/dns-query'),
    ('AdGuard DoH', 'https://dns.adguard-dns.com/dns-query'),
    ('Comss DNS', 'https://dns.comss.one/dns-query'),
    ('Яндекс 77.88.8.8', '77.88.8.8'),
    ('Cloudflare 1.1.1.1', '1.1.1.1'),
  ];

  static const _routeModes = <(String, String, String)>[
    ('split_ru', 'Раздельный (.ru напрямую)', 'Зарубежные домены через прокси, РФ — напрямую'),
    ('proxy', 'Всегда через прокси', 'Максимальная приватность без утечек DNS'),
    ('direct', 'Напрямую', 'Быстрое разрешение через загрузочный DNS'),
  ];

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final dns = controller.settings.dns;
    final results = controller.dnsResults;

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(title: const Text('DNS')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.xxl),
        children: [
          const SectionLabel('Режим DNS и анти-утечки'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchRow(
                  title: 'FakeIP (198.18.0.0/15)',
                  subtitle:
                      'Мгновенно выдаёт виртуальные IP и исключает DNS-утечки при подключении',
                  value: dns.fakeIp,
                  onChanged: (value) => controller.setDns(
                    dns.copyWith(fakeIp: value),
                  ),
                ),
                const Hairline(),
                const SizedBox(height: Space.sm),
                Text(
                  'Маршрутизация DNS-запросов',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                const SizedBox(height: Space.xs),
                for (final (modeKey, title, hint) in _routeModes)
                  RadioListTile<String>(
                    value: modeKey,
                    // ignore: deprecated_member_use
                    groupValue: dns.routeMode,
                    // ignore: deprecated_member_use
                    onChanged: (val) {
                      if (val != null) {
                        controller.setDns(dns.copyWith(routeMode: val));
                      }
                    },
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    activeColor: tokens.accent,
                    title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
                    subtitle: Text(hint, style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Резолверы'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchRow(
                  title: 'Подбирать автоматически',
                  subtitle: 'Выбирать самый быстрый по результатам проверки',
                  value: dns.autoSelect,
                  onChanged: (value) => controller.setDns(
                    dns.copyWith(autoSelect: value),
                  ),
                ),
                const Hairline(),
                const SizedBox(height: Space.sm),
                if (dns.servers.isEmpty)
                  Text(
                    'Список пуст — используется системный резолвер.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  )
                else
                  for (final server in dns.servers) ...[
                    _ServerRow(
                      address: server,
                      onRemove: () => controller.setDns(
                        dns.copyWith(
                          servers: dns.servers.where((s) => s != server).toList(),
                        ),
                      ),
                    ),
                    const Hairline(),
                  ],
                const SizedBox(height: Space.sm),
                _AddServerRow(controller: controller),
                const SizedBox(height: Space.md),
                Text(
                  'Быстрое добавление популярных резолверов:',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: Space.xs),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final (label, addr) in presets)
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          dns.servers.contains(addr) ? Icons.check : Icons.add,
                          size: 14,
                          color: dns.servers.contains(addr)
                              ? tokens.success
                              : tokens.accent,
                        ),
                        label: Text(label, style: const TextStyle(fontSize: 11.5)),
                        onPressed: () {
                          final next = dns.servers.contains(addr)
                              ? dns.servers.where((s) => s != addr).toList()
                              : [...dns.servers, addr];
                          controller.setDns(dns.copyWith(servers: next));
                        },
                      ),
                  ],
                ),
                const SizedBox(height: Space.md),
                _CheckedAtRow(controller: controller),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Проверка'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Замеряется задержка до каждого резолвера: '
                  'результат показывает, кто отвечает быстрее.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: Space.lg),
                FilledButton(
                  onPressed: controller.dnsBenchmarkRunning
                      ? null
                      : controller.runDnsBenchmark,
                  child: controller.dnsBenchmarkRunning
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Text('Проверить резолверы'),
                ),
                if (results.isNotEmpty) ...[
                  const SizedBox(height: Space.lg),
                  for (final result in results) _ResultRow(result: result),
                  const SizedBox(height: Space.md),
                  OutlinedButton(
                    onPressed: controller.applyDnsRecommendation,
                    child: const Text('Применить лучшие'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
          const SectionLabel('Загрузочные серверы'),
          HairlineCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Ими разрешаются имена DoH-резолверов и домены, '
                  'которые идут напрямую.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: Space.md),
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (final address in dns.bootstrap)
                      Pill(label: address, color: tokens.muted),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Строка выбранного резолвера.
class _ServerRow extends StatelessWidget {
  const _ServerRow({required this.address, required this.onRemove});

  final String address;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, size: 16, color: tokens.muted),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              address,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            icon: Icon(Icons.close, size: 16, color: tokens.faint),
          ),
        ],
      ),
    );
  }
}

/// Строка: когда последний раз проверяли резолверы.
class _CheckedAtRow extends StatelessWidget {
  const _CheckedAtRow({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final checkedAt = controller.dnsCheckedAt;
    final stale = controller.needsDnsCheck;

    final String text;
    if (checkedAt == null) {
      text = 'Резолверы ещё не проверялись';
    } else {
      final local = checkedAt.toLocal();
      final stamp = '${local.day.toString().padLeft(2, '0')}.'
          '${local.month.toString().padLeft(2, '0')} '
          '${local.hour.toString().padLeft(2, '0')}:'
          '${local.minute.toString().padLeft(2, '0')}';
      text = 'Последняя проверка: $stamp';
    }

    return Row(
      children: [
        Icon(
          stale ? Icons.schedule : Icons.check_circle_outline,
          size: 15,
          color: stale ? tokens.warning : tokens.faint,
        ),
        const SizedBox(width: Space.md),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 12, color: tokens.faint),
          ),
        ),
        if (stale)
          Text(
            'нужна проверка',
            style: TextStyle(fontSize: 12, color: tokens.warning),
          ),
      ],
    );
  }
}

/// Строка добавления резолвера.
class _AddServerRow extends StatefulWidget {
  const _AddServerRow({required this.controller});

  final AppController controller;

  @override
  State<_AddServerRow> createState() => _AddServerRowState();
}

class _AddServerRowState extends State<_AddServerRow> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dns = widget.controller.settings.dns;

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _text,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'https://dns.google/dns-query',
              isDense: true,
            ),
            onSubmitted: (_) => _add(dns),
          ),
        ),
        const SizedBox(width: Space.sm),
        IconButton(
          onPressed: () => _add(dns),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }

  void _add(DnsSettings dns) {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    if (!dns.servers.contains(value)) {
      widget.controller.setDns(dns.copyWith(servers: [...dns.servers, value]));
    }
    _text.clear();
  }
}

/// Результат замера одного резолвера.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.result});

  final DnsResult result;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tone = result.ok
        ? (result.latencyMs <= 80 ? tokens.success : tokens.warning)
        : tokens.danger;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              result.candidate.address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
            ),
          ),
          Text(
            result.ok ? '${result.latencyMs} мс' : 'нет ответа',
            style: TextStyle(fontSize: 12.5, color: tone),
          ),
        ],
      ),
    );
  }
}
