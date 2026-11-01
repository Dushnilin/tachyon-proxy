import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/tunnel_state.dart';

/// Результат проверки конфигурации движком.
class ConfigCheck {
  const ConfigCheck({required this.ok, this.error = '', this.warnings = const []});

  final bool ok;
  final String error;
  final List<String> warnings;

  static ConfigCheck fromJson(String raw) {
    try {
      final map = Map<String, dynamic>.from(
        // ignore: avoid_dynamic_calls
        (const JsonCodec().decode(raw) as Map).cast<String, dynamic>(),
      );
      final ok = map['ok'] == true;
      return ConfigCheck(
        ok: ok,
        error: (map['error'] as String?) ?? '',
        warnings: ((map['warnings'] as List?) ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
      );
    } catch (_) {
      return const ConfigCheck(ok: false, error: 'движок ответил неожиданным форматом');
    }
  }
}

/// Мост между Flutter и нативным слоем (Kotlin + `libtachyon.so`).
///
/// Канал один: `app.tachyon.proxy/vpn`. Всё, что касается ядра, живёт в
/// Kotlin; Dart отвечает только за состояние интерфейса и настройки.
class CoreBridge {
  CoreBridge._();

  static final CoreBridge instance = CoreBridge._();

  static const MethodChannel _channel = MethodChannel('app.tachyon.proxy/vpn');

  /// События от нативного слоя: смена состояния, ошибки, счётчики.
  static const EventChannel _events = EventChannel('app.tachyon.proxy/events');

  void Function(TunnelState state)? onState;
  void Function(String log)? onLog;
  void Function(String cmd)? onCommand;
  void Function(String url)? onDeepLink;

  bool _listening = false;

  /// Подписка на события ядра.
  void listen() {
    if (_listening) return;
    _listening = true;
    _events.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final data = event.cast<String, dynamic>();
        switch (data['type']) {
          case 'state':
            onState?.call(
              TunnelState(
                status: _parseStatus(data['status'] as String?),
                error: (data['error'] as String?) ?? '',
              ),
            );
          case 'log':
            onLog?.call((data['line'] as String?) ?? '');
          case 'cmd':
            onCommand?.call((data['cmd'] as String?) ?? '');
          case 'deeplink':
            final url = (data['url'] as String?)?.trim() ?? '';
            if (url.isNotEmpty) {
              onDeepLink?.call(url);
            }
        }
      },
      onError: (Object error) {
        onState?.call(
          TunnelState(status: VpnStatus.failed, error: error.toString()),
        );
      },
    );
  }

  static VpnStatus _parseStatus(String? raw) {
    return switch (raw) {
      'connected' => VpnStatus.connected,
      'connecting' => VpnStatus.connecting,
      'disconnecting' => VpnStatus.disconnecting,
      'failed' => VpnStatus.failed,
      _ => VpnStatus.disconnected,
    };
  }

  /// Проверяет конфигурацию движком, не запуская его.
  Future<ConfigCheck> check(String config) async {
    try {
      final raw = await _channel.invokeMethod<String>('check', {'config': config});
      if (raw == null) {
        return const ConfigCheck(ok: false, error: 'движок не ответил');
      }
      return ConfigCheck.fromJson(raw);
    } on PlatformException catch (error) {
      return ConfigCheck(ok: false, error: error.message ?? error.code);
    }
  }

  /// Адаптивно скачивает и разбирает подписку напрямую через нативный движок `tachyon-core`.
  Future<Map<String, dynamic>?> fetchSubscription(
    String url, {
    String customUa = '',
    bool sendHwid = true,
    String customHwid = '',
    bool insecure = false,
  }) async {
    try {
      final raw = await _channel.invokeMethod<String>('fetchSubscription', {
        'url': url,
        'customUa': customUa,
        'sendHwid': sendHwid,
        'customHwid': customHwid,
        'insecure': insecure,
      });
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Разбирает любой текст/JSON/YAML подписки напрямую через нативный движок `tachyon-core`.
  Future<Map<String, dynamic>?> parseSubscription(String payload) async {
    try {
      final raw = await _channel.invokeMethod<String>('parseSubscription', {
        'payload': payload,
      });
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Кэш иконок установленных приложений.
  final Map<String, Uint8List?> _iconCache = {};

  /// Поднимает туннель.
  ///
  /// Возвращает текст ошибки, если запуск не удался; null — успех.
  Future<String?> start(
    String config, {
    List<String> allowedApps = const [],
    List<String> disallowedApps = const [],
    String serverName = '',
    int mtu = 9000,
    bool proxyOnly = false,
  }) async {
    try {
      final error = await _channel.invokeMethod<String>('start', {
        'config': config,
        'allowedApps': allowedApps,
        'disallowedApps': disallowedApps,
        'serverName': serverName,
        'mtu': mtu,
        'proxyOnly': proxyOnly,
      });
      return error;
    } on PlatformException catch (error) {
      return error.message ?? error.code;
    }
  }

  /// Останавливает туннель.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException {
      // Остановка не должна падать в UI: состояние всё равно придёт из ядра.
    }
  }

  /// Текущее состояние по данным нативного слоя.
  Future<TunnelState> status() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('status');
      if (data == null) return const TunnelState();
      return TunnelState(
        status: _parseStatus(data['status'] as String?),
        error: (data['error'] as String?) ?? '',
        serverName: (data['server'] as String?) ?? '',
      );
    } on PlatformException {
      return const TunnelState();
    }
  }

  /// Статистика трафика: байты отправлено/получено и соединения.
  Future<TrafficStats?> stats() async {
    try {
      final raw = await _channel.invokeMethod<String>('stats');
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return TrafficStats.fromJson(map);
    } on PlatformException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// Версия нативного ядра.
  Future<String> coreVersion() async {
    try {
      return await _channel.invokeMethod<String>('version') ?? 'неизвестно';
    } on PlatformException {
      return 'неизвестно';
    }
  }

  /// Хвост журнала ядра.
  Future<List<String>> logs({int limit = 400}) async {
    try {
      final lines = await _channel.invokeMethod<List<Object?>>(
        'logs',
        {'limit': limit},
      );
      return (lines ?? const []).map((line) => line.toString()).toList(growable: false);
    } on PlatformException {
      return const [];
    }
  }

  /// Очищает файл журнала ядра.
  Future<void> clearLogs() async {
    try {
      await _channel.invokeMethod<bool>('clearLogs');
    } on PlatformException {
      // Игнорируем ошибку очистки
    }
  }

  /// Возвращает PNG-иконку приложения (64x64) с кэшированием в память.
  Future<Uint8List?> appIcon(String packageName) async {
    if (_iconCache.containsKey(packageName)) {
      return _iconCache[packageName];
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>(
        'appIcon',
        {'package': packageName},
      );
      _iconCache[packageName] = bytes;
      return bytes;
    } on PlatformException {
      _iconCache[packageName] = null;
      return null;
    }
  }

  /// Открывает системное диалоговое окно «Поделиться».
  Future<void> shareText(String text, {String subject = ''}) async {
    try {
      await _channel.invokeMethod<bool>('shareText', {
        'text': text,
        'subject': subject,
      });
    } on PlatformException {
      // Игнорируем ошибку
    }
  }

  /// Запускает нативный сканер QR-кода (с камеры или выбор из галереи).
  Future<String?> scanQr({bool fromGallery = false}) async {
    try {
      return await _channel.invokeMethod<String>('scanQr', {
        'fromGallery': fromGallery,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Определяет активный тип подключения: `wifi`, `cellular`, `ethernet`, `none`.
  Future<String> networkType() async {
    try {
      return await _channel.invokeMethod<String>('networkInfo') ?? 'none';
    } on PlatformException {
      return 'none';
    }
  }

  /// Приватный каталог приложения: сюда кладутся списки правил и журнал.
  Future<String> filesDir() async {
    try {
      return await _channel.invokeMethod<String>('filesDir') ?? '';
    } on PlatformException {
      return '';
    }
  }

  /// Основная архитектура процессора устройства (`arm64-v8a`, `armeabi-v7a`, `x86_64`).
  Future<String> deviceAbi() async {
    try {
      return await _channel.invokeMethod<String>('deviceAbi') ?? 'arm64-v8a';
    } on PlatformException {
      return 'arm64-v8a';
    }
  }

  /// Горячая установка скачанного `libtachyon.so` с перезапуском процесса (либо `"requires_apk"`).
  Future<String> installEngineSo(String path) async {
    try {
      return await _channel.invokeMethod<String>('installEngineSo', {'path': path}) ??
          'requires_apk';
    } on PlatformException {
      return 'requires_apk';
    }
  }

  /// Запуск системного установщика Android для скачанного APK в `filesDir/update/<fileName>`.
  Future<String> installApk(String fileName) async {
    try {
      return await _channel.invokeMethod<String>('installApk', {'fileName': fileName}) ??
          'error';
    } on PlatformException catch (e) {
      return 'error: ${e.message}';
    }
  }

  /// Возвращает внешнюю ссылку/текст (ACTION_VIEW / ACTION_SEND), с которой было открыто приложение.
  Future<String?> consumeLaunchLink() async {
    try {
      return await _channel.invokeMethod<String>('consumeLaunchLink');
    } on PlatformException {
      return null;
    }
  }

  /// Установленные приложения — пул для правил «разрешено/запрещено».
  Future<List<InstalledApp>> installedApps() async {
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('apps');
      if (raw == null) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map(
            (map) => InstalledApp(
              packageName: (map['package'] as String?) ?? '',
              label: (map['label'] as String?) ?? '',
              system: map['system'] == true,
            ),
          )
          .where((app) => app.packageName.isNotEmpty)
          .toList(growable: false);
    } on PlatformException {
      return const [];
    }
  }
}

/// Статистика трафика от ядра.
class TrafficStats {
  const TrafficStats({
    required this.running,
    required this.up,
    required this.down,
    required this.connections,
  });

  /// Работает ли ядро сейчас.
  final bool running;

  /// Отправлено байт с момента запуска.
  final int up;

  /// Получено байт с момента запуска.
  final int down;

  /// Активные соединения.
  final int connections;

  static TrafficStats fromJson(Map<String, dynamic> json) {
    return TrafficStats(
      running: json['running'] == true,
      up: (json['up'] as num?)?.toInt() ?? 0,
      down: (json['down'] as num?)?.toInt() ?? 0,
      connections: (json['connections'] as num?)?.toInt() ?? 0,
    );
  }

  /// Отправлено в человекочитаемом виде.
  String get upText => formatBytes(up);

  /// Получено в человекочитаемом виде.
  String get downText => formatBytes(down);
}

/// Форматирование размера в байтах.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} КБ';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} МБ';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} ГБ';
}

/// Приложение, установленное на устройстве.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.system,
  });

  final String packageName;
  final String label;
  final bool system;
}
