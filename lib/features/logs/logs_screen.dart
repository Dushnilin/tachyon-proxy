import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app.dart';
import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';

/// Экран журнала: живое автообновление (Live-tail), поиск, фильтр по уровням, очистка и шеринг.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<String> _lines = const [];
  bool _loading = true;
  bool _liveTail = true;
  String _query = '';
  String _levelFilter = 'ALL'; // ALL, ERROR, WARN, INFO
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reload();
      _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        if (_liveTail) _reload();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final controller = AppScope.read(context);
    await controller.refreshLogs();
    if (!mounted) return;
    setState(() {
      _lines = controller.logs;
      _loading = false;
    });
  }

  bool _matchesLevel(String line) {
    if (_levelFilter == 'ALL') return true;
    final lower = line.toLowerCase();
    return switch (_levelFilter) {
      'ERROR' => lower.contains('error') || lower.contains('fatal'),
      'WARN' => lower.contains('warn'),
      'INFO' => lower.contains('info'),
      _ => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.read(context);
    final tokens = context.tokens;
    final q = _query.trim().toLowerCase();
    final filtered = _lines.where((line) {
      if (!_matchesLevel(line)) return false;
      if (q.isNotEmpty && !line.toLowerCase().contains(q)) return false;
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: tokens.surface,
      appBar: AppBar(
        title: const Text('Журнал'),
        actions: [
          IconButton(
            tooltip: _liveTail ? 'Пауза автообновления' : 'Включить Live-tail',
            onPressed: () => setState(() => _liveTail = !_liveTail),
            icon: Icon(
              _liveTail ? Icons.pause_circle_outline : Icons.play_circle_outline,
              color: _liveTail ? tokens.success : tokens.muted,
            ),
          ),
          IconButton(
            tooltip: 'Очистить журнал',
            onPressed: () async {
              await controller.clearLogs();
              if (!mounted) return;
              setState(() => _lines = const []);
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
          IconButton(
            tooltip: 'Копировать',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: filtered.join('\n')));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Журнал скопирован')),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: 'Поделиться',
            onPressed: () {
              if (filtered.isEmpty) return;
              controller.shareText(
                filtered.join('\n'),
                subject: 'Tachyon VPN Logs',
              );
            },
            icon: const Icon(Icons.share_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.lg, Space.xs, Space.lg, Space.xs),
            child: Column(
              children: [
                TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: const InputDecoration(
                    hintText: 'Поиск по журналу...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: Space.xs),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final lvl in ['ALL', 'ERROR', 'WARN', 'INFO']) ...[
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: Text(
                            lvl == 'ALL' ? 'Все (${_lines.length})' : lvl,
                            style: const TextStyle(fontSize: 11.5),
                          ),
                          selected: _levelFilter == lvl,
                          onSelected: (_) => setState(() => _levelFilter = lvl),
                        ),
                        const SizedBox(width: 6),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : filtered.isEmpty
                    ? const EmptyState(
                        icon: Icons.article_outlined,
                        title: 'Журнал пуст',
                        description:
                            'Строки появятся после запуска туннеля: '
                            'ядро пишет туда все значимые события.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                          Space.lg,
                          Space.sm,
                          Space.lg,
                          Space.xxl,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final line = filtered[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              line,
                              style: TextStyle(
                                fontSize: 11.5,
                                height: 1.45,
                                fontFamily: 'monospace',
                                color: _colorFor(context, line),
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Color _colorFor(BuildContext context, String line) {
    final tokens = context.tokens;
    final lower = line.toLowerCase();
    if (lower.contains('error') || lower.contains('fatal')) {
      return tokens.danger;
    }
    if (lower.contains('warn')) return tokens.warning;
    if (lower.contains('debug')) return tokens.faint;
    return tokens.muted;
  }
}
