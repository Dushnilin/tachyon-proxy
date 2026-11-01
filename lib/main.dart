import 'dart:io';

import 'package:flutter/material.dart';

import 'app/app.dart';
import 'core/app_controller.dart';
import 'core/services/core_bridge.dart';
import 'core/services/lists_repository.dart';
import 'core/services/settings_store.dart';

/// Точка входа: собирает зависимости и запускает приложение.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final bridge = CoreBridge.instance;

  // Приватный каталог приложения: настройки и списки правил живут там.
  var directory = await bridge.filesDir();
  if (directory.isEmpty) {
    // Файлы недоступны — используем временный каталог, чтобы приложение
    // всё же запустилось.
    directory = Directory.systemTemp.path;
  }

  final controller = AppController(
    store: SettingsStore(directory: directory),
    bridge: bridge,
    lists: ListsRepository(directory: directory),
  );

  await controller.bootstrap();

  runApp(TachyonApp(controller: controller));
}
