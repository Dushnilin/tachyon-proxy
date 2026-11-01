import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_controller.dart';
import '../features/home/home_tab.dart';
import '../features/profiles/profiles_tab.dart';
import '../features/rules/rules_tab.dart';
import '../features/settings/settings_tab.dart';
import 'theme/app_theme.dart';

/// Доступ к контроллеру состояния из любого места дерева виджетов.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({
    super.key,
    required AppController controller,
    required super.child,
  }) : super(notifier: controller);

  /// Контроллер; подписка на изменения происходит автоматически.
  static AppController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден в дереве виджетов');
    return scope!.notifier!;
  }

  /// Контроллер без подписки: для действий и вызовов.
  static AppController read(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope не найден в дереве виджетов');
    return scope!.notifier!;
  }
}

/// Корень приложения: тема, тема оформления и навигация.
class TachyonApp extends StatelessWidget {
  const TachyonApp({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: controller,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final isDark = controller.settings.themeMode != 'light';
          return MaterialApp(
            title: 'Tachyon',
            debugShowCheckedModeBanner: false,
            theme: isDark ? TachyonTheme.dark() : TachyonTheme.light(),
            home: const RootShell(),
          );
        },
      ),
    );
  }
}

/// Оболочка приложения: четыре раздела в нижней навигации.
class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _index = 0;
  String _lastCheckedClip = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkClipboard());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkClipboard();
    }
  }

  Future<void> _checkClipboard() async {
    try {
      final clip = await Clipboard.getData(Clipboard.kTextPlain);
      final raw = clip?.text?.trim() ?? '';
      if (raw.isEmpty || raw == _lastCheckedClip) return;
      _lastCheckedClip = raw;

      final isLink = raw.startsWith('http://') ||
          raw.startsWith('https://') ||
          raw.startsWith('vless://') ||
          raw.startsWith('vmess://') ||
          raw.startsWith('trojan://') ||
          raw.startsWith('ss://') ||
          raw.startsWith('hy2://') ||
          raw.startsWith('hysteria2://') ||
          raw.startsWith('tuic://') ||
          raw.startsWith('anytls://');

      if (!isLink || !mounted) return;

      final controller = AppScope.read(context);
      final alreadySub = controller.settings.subscriptions.any((s) => s.url == raw);
      if (alreadySub) return;

      final preview = raw.length > 40 ? '${raw.substring(0, 40)}...' : raw;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          behavior: SnackBarBehavior.floating,
          content: Text(
            'В буфере обнаружена ссылка:\n$preview',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          action: SnackBarAction(
            label: 'Импортировать',
            onPressed: () async {
              final added = await controller.importProfiles(raw);
              if (!mounted) return;
              final msg = switch (added) {
                -1 => 'Подписка добавлена — загрузка серверов...',
                0 => controller.lastError.isNotEmpty
                    ? controller.lastError
                    : 'Не удалось распознать ссылку',
                _ => 'Добавлено профилей: $added',
              };
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(msg)),
              );
            },
          ),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final controller = AppScope.of(context);
    final notice = controller.consumeImportNotice();
    if (notice != null && notice.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text(notice)),
        );
      });
    }

    final pages = <Widget>[
      const HomeTab(),
      const ProfilesTab(),
      const RulesTab(),
      const SettingsTab(),
    ];

    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.bolt_outlined),
            selectedIcon: Icon(Icons.bolt_rounded),
            label: 'Туннель',
          ),
          NavigationDestination(
            icon: Icon(Icons.dns_outlined),
            selectedIcon: Icon(Icons.dns),
            label: 'Профили',
          ),
          NavigationDestination(
            icon: Icon(Icons.rule_folder_outlined),
            selectedIcon: Icon(Icons.rule_folder),
            label: 'Правила',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: 'Настройки',
          ),
        ],
      ),
    );
  }
}
