import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../core/app_controller.dart';
import '../../core/models/runtime_config.dart';

/// Экран активных и недавних сетевых соединений с быстрым созданием правил.
class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  Timer? _timer;
  String _query = '';
  String _netFilter = 'ALL'; // ALL, TCP, UDP

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
    });
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    await AppScope.read(context).refreshLogs();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final tokens = context.tokens;
    final activeCount = controller.traffic?.connections ?? 0;
    final allEntries = controller.parsedConnections;
    final q = _query.trim().toLowerCase();
    final filtered = allEntries.where((e) {
      if (_netFilter != 'ALL' && e.network != _netFilter) return false;
      if (q.isNotEmpty && !e.target.toLowerCase().contains(q)) return false;
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Соединения'),
            const SizedBox(width: Space.sm),
            Pill(
              label: '$activeCount актив.',
              color: activeCount > 0 ? tokens.success : tokens.muted,
              filled: true,
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Обновить',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, Space.sm),
            child: Column(
              children: [
                TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Поиск по домену, IP или порту...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: Space.sm),
                Row(
                  children: [
                    for (final net in ['ALL', 'TCP', 'UDP']) ...[
                      ChoiceChip(
                        label: Text(net == 'ALL' ? 'Все (${allEntries.length})' : net),
                        selected: _netFilter == net,
                        onSelected: (_) => setState(() => _netFilter = net),
                      ),
                      const SizedBox(width: Space.xs),
                    ],
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const EmptyState(
                    icon: Icons.hub_outlined,
                    title: 'Нет зафиксированных соединений',
                    description:
                        'Запустите туннель и откройте любое приложение или сайт. '
                        'Нажмите на любое соединение, чтобы в один тап создать правило маршрутизации.',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                      Space.lg,
                      Space.xs,
                      Space.lg,
                      Space.xxl,
                    ),
                    itemCount: filtered.length,
                    separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                    itemBuilder: (context, index) {
                      final entry = filtered[index];
                      return _ConnectionTile(
                        entry: entry,
                        onCreateRule: (action) async {
                          final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(entry.host);
                          final ruleVal = isIp ? '${entry.host}/32' : _rootDomain(entry.host);
                          final ruleType = isIp ? 'ip_cidr' : 'domain_suffix';
                          final id = 'cr-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
                          await controller.addCustomRule(
                            CustomRule(
                              id: id,
                              type: ruleType,
                              value: ruleVal,
                              action: action,
                            ),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Добавлено правило: $ruleVal → $action'),
                            ),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _rootDomain(String host) {
    final parts = host.split('.');
    if (parts.length <= 2) return host;
    return '${parts[parts.length - 2]}.${parts.last}';
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({
    required this.entry,
    required this.onCreateRule,
  });

  final ConnectionEntry entry;
  final ValueChanged<String> onCreateRule;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return HairlineCard(
      padding: const EdgeInsets.symmetric(horizontal: Space.md, vertical: Space.sm),
      onTap: () => _showRuleSheet(context),
      child: Row(
        children: [
          Pill(
            label: entry.network,
            color: entry.network == 'UDP' ? tokens.warning : tokens.accent,
            filled: true,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.host,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: tokens.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Порт ${entry.port} · ${entry.timestamp}',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: tokens.muted,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Создать правило',
            onPressed: () => _showRuleSheet(context),
            icon: Icon(Icons.add_moderator_outlined, size: 18, color: tokens.accent),
          ),
        ],
      ),
    );
  }

  void _showRuleSheet(BuildContext context) {
    final tokens = context.tokens;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.raised,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.card)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.host,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: tokens.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Создать пользовательское правило для этого узла:',
                style: TextStyle(fontSize: 12.5, color: tokens.muted),
              ),
              const SizedBox(height: Space.md),
              ListTile(
                leading: Icon(Icons.shield_outlined, color: tokens.accent),
                title: const Text('Через прокси (VPN)'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCreateRule('proxy');
                },
              ),
              ListTile(
                leading: Icon(Icons.bolt_outlined, color: tokens.warning),
                title: const Text('Через DPI-обход (Desync)'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCreateRule('desync');
                },
              ),
              ListTile(
                leading: Icon(Icons.call_split_outlined, color: tokens.success),
                title: const Text('Напрямую (в обход VPN)'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCreateRule('direct');
                },
              ),
              ListTile(
                leading: Icon(Icons.block_outlined, color: tokens.danger),
                title: const Text('Заблокировать'),
                onTap: () {
                  Navigator.pop(ctx);
                  onCreateRule('block');
                },
              ),
              ListTile(
                leading: Icon(Icons.copy_outlined, color: tokens.muted),
                title: const Text('Скопировать хост'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: entry.host));
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
