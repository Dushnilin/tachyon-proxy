import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models/app_rules.dart';
import 'models/runtime_config.dart';
import 'models/tunnel_state.dart';
import 'services/core_bridge.dart';
import 'services/dns_benchmark.dart';
import 'services/free_nodes_service.dart';
import 'services/link_parser.dart';
import 'services/lists_repository.dart';
import 'services/settings_store.dart';

/// Состояние приложения.
///
/// Один контроллер на всё приложение: экраны читают его через
/// [AppScope], а меняют состояние только через методы здесь.
class AppController extends ChangeNotifier {
  AppController({
    required this.store,
    required this.bridge,
    required this.lists,
  });

  final SettingsStore store;
  final CoreBridge bridge;
  final ListsRepository lists;

  AppSettings _settings = const AppSettings();
  TunnelState _tunnel = const TunnelState();
  bool _loading = true;

  /// Результаты проверки DNS: по мере готовности добавляются в список.
  final List<DnsResult> _dnsResults = [];

  /// Идёт ли проверка DNS прямо сейчас.
  bool _dnsBenchmarkRunning = false;

  /// Статистика трафика от ядра.
  TrafficStats? _traffic;

  /// Таймер опроса: трафик меняется во время сессии, опрос раз в две секунды.
  Timer? _trafficTimer;

  /// Текст последней ошибки действия (импорт, скачивание, запуск).
  String _lastError = '';

  /// Уведомление об автоматическом импорте по внешней ссылке / «Поделиться».
  String _lastImportNotice = '';

  /// Журнал ядра.
  List<String> _logs = const [];

  /// Кэш результатов пинга серверов: profileId -> мс (-1 = недоступен).
  final Map<String, int> _pings = {};
  final Set<String> _pingingIds = {};
  bool _pingingAll = false;
  bool _sortByPing = false;

  /// Живая скорость трафика (байт/сек) и история для графика (спарклайна).
  int _upSpeed = 0;
  int _downSpeed = 0;
  int _prevUp = 0;
  int _prevDown = 0;
  DateTime? _prevTrafficAt;
  final List<int> _downHistory = List<int>.filled(24, 0, growable: true);
  final List<int> _upHistory = List<int>.filled(24, 0, growable: true);

  /// Реальный HTTP 204 пинг через поднятый туннель (URL-Test).
  int? _urlTestPing;
  bool _testingUrlPing = false;
  final List<int> _latencyHistory = List<int>.filled(24, 0, growable: true);

  /// Данные выходного узла (Exit Node GeoIP), по аналогии с MSN-GUARD OrbitCards/ExitGeo.
  String _exitIp = '';
  String _exitCountry = '';
  String _exitCity = '';
  String _exitFlag = '⚡';
  String _exitIsp = '';
  bool _refreshingExitGeo = false;

  /// Автоподбор оптимального MTU (MtuAutoScan).
  bool _scanningMtu = false;
  String _mtuScanStatus = '';

  /// Автоподбор бесплатных туннелей (Cloudflare WARP AmneziaWG + SHARD пул).
  bool _provisioningFreeNodes = false;
  String _freeNodesStatus = '';
  bool get provisioningFreeNodes => _provisioningFreeNodes;
  String get freeNodesStatus => _freeNodesStatus;

  /// Автоподбор рецепта DPI (Desync).
  bool _testingDesync = false;
  String _desyncTestStatus = '';
  List<DesyncScanEntry> _desyncScanResults = const [];

  /// Счётчики для фонового Smart Failover и автосмены профиля DPI по типу сети.
  int _pollTickCount = 0;
  int _consecutiveWatchdogFails = 0;
  String _lastNetType = '';

  /// Версия приложения и состояние встроенного загрузчика обновлений (отдельно ядро, APK, списки).
  static const String appVersion = '0.0.5';
  bool _checkingUpdates = false;
  bool _updatingEngine = false;
  bool _updatingApp = false;
  bool _updatingLists = false;
  double _updateProgress = 0.0;
  String _updateStatusText = '';
  String _installedCoreVersion = '';
  String _latestCoreVersion = '';
  String _latestAppVersion = '';
  String _latestCoreSoUrl = '';

  AppSettings get settings => _settings;
  TunnelState get tunnel => _tunnel;
  bool get loading => _loading;
  bool _loadingSubscription = false;
  bool get loadingSubscription => _loadingSubscription;
  List<DnsResult> get dnsResults => _dnsResults;
  bool get dnsBenchmarkRunning => _dnsBenchmarkRunning;
  String get lastError => _lastError;
  String? consumeImportNotice() {
    if (_lastImportNotice.isEmpty) return null;
    final msg = _lastImportNotice;
    _lastImportNotice = '';
    return msg;
  }
  List<String> get logs => _logs;
  Map<String, int> get pings => _pings;
  Set<String> get pingingIds => _pingingIds;
  bool get pingingAll => _pingingAll;
  bool get sortByPing => _sortByPing;
  int get upSpeed => _upSpeed;
  int get downSpeed => _downSpeed;
  List<int> get downHistory => _downHistory;
  List<int> get upHistory => _upHistory;
  int? get urlTestPing => _urlTestPing;
  bool get testingUrlPing => _testingUrlPing;
  List<int> get latencyHistory => _latencyHistory;
  String get exitIp => _exitIp;
  String get exitCountry => _exitCountry;
  String get exitCity => _exitCity;
  String get exitFlag => _exitFlag;
  String get exitIsp => _exitIsp;
  bool get refreshingExitGeo => _refreshingExitGeo;
  bool get scanningMtu => _scanningMtu;
  String get mtuScanStatus => _mtuScanStatus;
  bool get testingDesync => _testingDesync;
  String get desyncTestStatus => _desyncTestStatus;
  List<DesyncScanEntry> get desyncScanResults => _desyncScanResults;
  String get activeNetworkType => _lastNetType;
  bool get checkingUpdates => _checkingUpdates;
  bool get updatingEngine => _updatingEngine;
  bool get updatingApp => _updatingApp;
  bool get updatingLists => _updatingLists;
  bool get isAnyUpdateRunning => _updatingEngine || _updatingApp || _updatingLists;
  double get updateProgress => _updateProgress;
  String get updateStatusText => _updateStatusText;
  String get installedCoreVersion => _installedCoreVersion;
  String get latestCoreVersion => _latestCoreVersion;
  String get latestAppVersion => _latestAppVersion;
  bool get hasCoreUpdate =>
      _latestCoreVersion.isNotEmpty &&
      _installedCoreVersion.isNotEmpty &&
      _compareSemver(_latestCoreVersion, _installedCoreVersion) > 0;
  bool get hasAppUpdate =>
      _latestAppVersion.isNotEmpty &&
      _compareSemver(_latestAppVersion, appVersion) > 0;

  int? pingOf(String id) => _pings[id];
  bool isPinging(String id) => _pingingIds.contains(id);

  bool isSubCollapsed(String subId) => _settings.collapsedSubs.contains(subId);

  Future<void> toggleSubCollapsed(String subId) async {
    final next = [..._settings.collapsedSubs];
    if (next.contains(subId)) {
      next.remove(subId);
    } else {
      next.add(subId);
    }
    await _update(_settings.copyWith(collapsedSubs: next));
  }

  void toggleSortByPing() {
    _sortByPing = !_sortByPing;
    notifyListeners();
  }

  /// Возвращает список профилей с учётом сортировки по пингу (если включена).
  List<Profile> sortProfiles(List<Profile> items) {
    if (!_sortByPing || items.length < 2) return items;
    final copy = [...items];
    copy.sort((a, b) {
      final pa = _pings[a.id];
      final pb = _pings[b.id];
      final rankA = pa == null ? 1 : (pa >= 0 ? 0 : 2);
      final rankB = pb == null ? 1 : (pb >= 0 ? 0 : 2);
      if (rankA != rankB) return rankA.compareTo(rankB);
      if (rankA == 0) return pa!.compareTo(pb!);
      return 0;
    });
    return copy;
  }

  Profile? get selectedProfile {
    final sel = _settings.selectedProfile;
    if (sel != null) return sel;
    if (_settings.profiles.isNotEmpty) return _settings.profiles.first;
    return null;
  }

  /// Готова ли конфигурация к запуску.
  bool get canConnect {
    if (_tunnel.status.isBusy) return false;
    if (_settings.routingMode == RoutingMode.desync ||
        _settings.desync.enabled ||
        _settings.serviceRoutes.values.contains('desync') ||
        _settings.appRoutes.values.contains('desync')) {
      return true;
    }
    final hasSub = _settings.subscriptions.isNotEmpty;
    final profile = selectedProfile;
    if (profile == null && !hasSub) return false;
    if (profile != null && profile.server.isEmpty && !hasSub) return false;
    return true;
  }

  /// Загружает настройки и подписывается на события ядра.
  Future<void> bootstrap() async {
    _settings = await store.load();

    final native = await bridge.status();
    _tunnel = _withServer(native);
    try {
      filesDirPath = await bridge.filesDir();
    } catch (_) {}
    _loading = false;

    if (_settings.selectedProfileId.isEmpty && _settings.profiles.isNotEmpty) {
      _settings = _settings.copyWith(selectedProfileId: _settings.profiles.first.id);
    }

    // Миграция и дедупликация профилей (устранение дублей и коллизий id)
    if (_settings.profiles.isNotEmpty) {
      final defaultSubId = _settings.subscriptions.isNotEmpty
          ? _settings.subscriptions.first.id
          : '';
      final deduped = _dedupProfiles(_settings.profiles, defaultSubId: defaultSubId);
      final selectedExists = _settings.selectedProfileId.startsWith('auto:') ||
          deduped.any((p) => p.id == _settings.selectedProfileId);
      final nonWarpFirst = deduped
          .where((p) => p.subscriptionId != 'free-warp')
          .firstOrNull;
      final effectiveSelectedId = (_settings.selectedProfileId.startsWith('free-warp') &&
              nonWarpFirst != null)
          ? nonWarpFirst.id
          : (selectedExists
              ? _settings.selectedProfileId
              : (deduped.isNotEmpty ? deduped.first.id : ''));
      _settings = _settings.copyWith(
        profiles: deduped,
        selectedProfileId: effectiveSelectedId,
      );
      unawaited(store.save(_settings));
    }

    // Синхронизируем кэш подписок для ядра в формате чистого sing-box JSON
    if (filesDirPath.isNotEmpty) {
      for (final sub in _settings.subscriptions) {
        final subProfiles = _settings.profiles.where((p) => p.subscriptionId == sub.id).toList();
        if (subProfiles.isNotEmpty) {
          try {
            final cacheFile = File('$filesDirPath/subs/${sub.id}.txt');
            await cacheFile.parent.create(recursive: true);
            final outboundsList = subProfiles.map((p) => p.toOutbound(tag: p.name)).toList();
            await cacheFile.writeAsString(jsonEncode(outboundsList));
          } catch (_) {}
        }
      }
    }
    notifyListeners();

    bridge.onState = _applyNativeState;
    bridge.onCommand = _handleExternalCommand;
    bridge.onDeepLink = (url) => unawaited(_handleIncomingDeepLink(url));
    bridge.listen();

    unawaited(() async {
      final launchLink = await bridge.consumeLaunchLink();
      if (launchLink != null && launchLink.trim().isNotEmpty) {
        await _handleIncomingDeepLink(launchLink);
      }
    }());

    // Фоновое обновление: подписки без серверов, список устарел или резолверы ещё не проверены.
    unawaited(_refreshStale());
  }

  Future<void> _handleIncomingDeepLink(String raw) async {
    final clean = raw.trim();
    if (clean.isEmpty) return;
    final added = await importProfiles(clean);
    if (added == -1) {
      _lastImportNotice = 'Подписка https:// успешно добавлена и загружена';
    } else if (added > 0) {
      _lastImportNotice = 'Импортировано профилей по ссылке: $added';
    } else if (_lastError.isNotEmpty) {
      _lastImportNotice = _lastError;
    }
    notifyListeners();
  }

  /// Обновляет устаревшие списки и, если нужно, резолверы.
  Future<void> _refreshStale() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final sub in _settings.subscriptions) {
      if (sub.enabled) {
        final hasServers = _settings.profiles.any((p) => p.subscriptionId == sub.id);
        final isOld = _settings.autoUpdateSubs &&
            (sub.updatedAt == 0 || (nowMs - sub.updatedAt) > 12 * 3600 * 1000);
        if (!hasServers || isOld) {
          await fetchSubscription(sub.id);
        }
      }
    }

    final stale = _settings.ruleSets
        .where((set) => set.isStale(DateTime.now()))
        .map((set) => set.id)
        .toList(growable: false);

    if (stale.isNotEmpty) {
      await refreshLists();
      for (final id in stale) {
        await downloadList(id);
      }
    }

    await ensureRequiredListsDownloaded();

    if (needsDnsCheck) {
      await runDnsBenchmark();
    }
  }

  /// Докачивает отсутствующие на диске `.trs` файлы из `tachyon-lists`
  /// для всех активных `serviceRoutes` (YouTube, Discord, Telegram, Сайты РФ и др.)
  /// и включённых пользователем списков `ruleSets`.
  Future<void> ensureRequiredListsDownloaded() async {
    if (filesDirPath.isEmpty) return;
    final requiredIds = <String>{};
    for (final service in BuiltInService.catalog) {
      final route = _settings.serviceRoutes[service.id];
      if (route != null && route.isNotEmpty && route != 'off') {
        requiredIds.add(service.trsId);
      }
    }
    for (final set in _settings.ruleSets) {
      if (set.enabled) {
        requiredIds.add(set.id);
      }
    }
    var downloadedAny = false;
    for (final id in requiredIds) {
      final file = File(lists.pathFor(id));
      if (!file.existsSync() || file.lengthSync() < 8) {
        final res = await lists.download(id);
        if (res.startsWith('/') || res.contains(RegExp(r'^[A-Z]:'))) {
          downloadedAny = true;
          final size = await lists.sizeOf(id);
          final sets = _settings.ruleSets.map((set) {
            if (set.id != id) return set;
            return set.copyWith(
              path: res,
              sizeBytes: size,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
            );
          }).toList();
          await _update(_settings.copyWith(ruleSets: sets));
        }
      }
    }
    if (downloadedAny && _tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Удаляет полные дубликаты серверов и гарантирует уникальность `id` каждого сервера.
  List<Profile> _dedupProfiles(List<Profile> items, {String defaultSubId = ''}) {
    final seenKeys = <String>{};
    final usedIds = <String>{};
    final result = <Profile>[];
    for (final p in items) {
      final subId = (p.subscriptionId.isEmpty && defaultSubId.isNotEmpty)
          ? defaultSubId
          : p.subscriptionId;
      final dedupKey = '$subId|${p.name}|${p.server}|${p.port}|${p.type}';
      if (!seenKeys.add(dedupKey)) continue;

      var id = p.id;
      if (id.isEmpty || usedIds.contains(id)) {
        final hash = (dedupKey.hashCode & 0x7fffffff).toRadixString(36);
        id = '${p.type}-$hash';
      }
      usedIds.add(id);

      if (id != p.id || subId != p.subscriptionId) {
        result.add(Profile.fromJson({
          ...p.toJson(),
          'id': id,
          'subscriptionId': subId,
        }));
      } else {
        result.add(p);
      }
    }
    return result;
  }

  /// Сохраняет настройки на диск.
  Future<void> _persist() async {
    await store.save(_settings);
    notifyListeners();
  }

  /// Заменяет настройки и сохраняет их.
  Future<void> _update(AppSettings next) async {
    _settings = next;
    await _persist();
  }

  /// Выбирает профиль и при активном туннеле сразу переключает соединение.
  Future<void> selectProfile(String id) async {
    final changed = _settings.selectedProfileId != id;
    await _update(_settings.copyWith(selectedProfileId: id));
    if (changed && _tunnel.status.isActive && _settings.routingMode != RoutingMode.desync) {
      await _restartActiveTunnel();
    }
  }

  /// Ожидает готовности локального mixed-прокси ядра (127.0.0.1:2080).
  Future<bool> _waitForLocalProxyReady({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          2080,
          timeout: const Duration(milliseconds: 250),
        );
        s.destroy();
        return true;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }
    }
    return false;
  }

  /// Перезапускает активный туннель с новой конфигурацией.
  Future<void> _restartActiveTunnel() async {
    for (var i = 0; i < 20 && _tunnel.status.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_tunnel.status.isActive) return;
    await toggleTunnel();
    for (var i = 0; i < 20 && _tunnel.status.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (!_tunnel.status.isActive && !_tunnel.status.isBusy) {
      await toggleTunnel();
      await _waitForLocalProxyReady();
    }
  }

  /// Добавляет или обновляет профиль в списке (сохраняя позицию при редактировании).
  Future<void> addProfile(Profile profile) async {
    final idx = _settings.profiles.indexWhere((p) => p.id == profile.id);
    final List<Profile> profiles;
    if (idx >= 0) {
      profiles = [..._settings.profiles];
      profiles[idx] = profile;
    } else {
      profiles = [..._settings.profiles, profile];
    }
    await _update(
      _settings.copyWith(
        profiles: profiles,
        selectedProfileId:
            _settings.selectedProfileId.isEmpty ? profile.id : _settings.selectedProfileId,
      ),
    );
  }

  /// Удаляет профиль.
  Future<void> removeProfile(String id) async {
    final profiles = _settings.profiles.where((p) => p.id != id).toList();
    final selected = _settings.selectedProfileId == id
        ? (profiles.isEmpty ? '' : profiles.first.id)
        : _settings.selectedProfileId;
    await _update(_settings.copyWith(profiles: profiles, selectedProfileId: selected));
  }

  /// Импортирует подписку или серверы: принимает ссылку, deep-link, QR-пейлоад или готовое содержимое.
  Future<int> importProfiles(String content) async {
    var payload = content.trim();
    if (payload.isEmpty) return 0;

    // Распаковка клиентских deep-link обёрток (v2raytun://, happ://, v2rayng://, clash://, sing-box://, hiddify://, sub://, tachyon://)
    final unwrappedUrl = _unwrapSubscriptionDeepLink(payload);
    if (unwrappedUrl != null && unwrappedUrl.isNotEmpty) {
      payload = unwrappedUrl;
    }

    // Если пользователь скопировал сообщение из Telegram-бота целиком («Ваша подписка: https://...»),
    // извлекаем https:// ссылку, если в тексте нет прямых URI серверов (vless://, hy2:// и т.д.).
    if (!payload.startsWith('http://') && !payload.startsWith('https://')) {
      final hasDirectProxyScheme = RegExp(
        r'\b(vless|vmess|trojan|ss|shadowsocks|hy2|hysteria2?|tuic|wg|wireguard|amneziawg|awg|anytls|naive\+https|naive\+quic|snell|shadowtls|fptns?|tewfai|mierus?|masque|trusttunnel|openconnect|socks5?|ssh|mtproto|tg)://',
        caseSensitive: false,
      ).hasMatch(payload);
      if (!hasDirectProxyScheme) {
        final deepMatch = RegExp(
          r'(v2raytun|happ|hiddify|sing-box|clash|v2rayng|streisand|karing|flclash|sub|tachyon)://[^\s"<>]+',
          caseSensitive: false,
        ).firstMatch(payload);
        if (deepMatch != null) {
          final inner = _unwrapSubscriptionDeepLink(deepMatch.group(0)!);
          if (inner != null && inner.isNotEmpty) {
            payload = inner;
          }
        } else {
          final httpMatch = RegExp(
            r'https?://[^\s"<>]+',
            caseSensitive: false,
          ).firstMatch(payload);
          if (httpMatch != null) {
            payload = httpMatch.group(0)!.replaceAll(RegExp(r'[.,;)\]]+$'), '');
          }
        }
      }
    }

    // http(s)-ссылка на подписку (не одиночный http://user:pass@host:port прокси)
    if ((payload.startsWith('http://') || payload.startsWith('https://')) &&
        !payload.contains('\n')) {
      final uri = Uri.tryParse(payload);
      final isDirectHttpProxy = uri != null &&
          uri.userInfo.isNotEmpty &&
          (uri.path.isEmpty || uri.path == '/') &&
          uri.query.isEmpty;
      final isTgMtproto = uri != null &&
          (uri.host.toLowerCase() == 't.me' || uri.host.toLowerCase() == 'telegram.me') &&
          uri.path == '/proxy';
      if (!isDirectHttpProxy && !isTgMtproto) {
        await addSubscription(payload);
        return _lastError.isEmpty ? -1 : 0;
      }
    }

    final parser = LinkParser();
    List<Profile> profiles = const [];
    final nativeParsed = await bridge.parseSubscription(payload);
    if (nativeParsed != null &&
        nativeParsed['ok'] == true &&
        nativeParsed['nodes'] is List) {
      profiles = parser.parseEngineNodes(
        nativeParsed['nodes'] as List,
        (nativeParsed['primary_tags'] as List?) ?? const [],
      );
    }
    if (profiles.isEmpty) {
      profiles = parser.parseSubscription(payload);
    }
    if (profiles.isEmpty) {
      _lastError = 'Не удалось распознать ссылку или формат подписки';
      notifyListeners();
      return 0;
    }
    _lastError = '';
    final byId = {for (final p in _settings.profiles) p.id: p};
    for (final p in profiles) {
      byId[p.id] = p;
    }
    final merged = byId.values.toList();
    await _update(
      _settings.copyWith(
        profiles: merged,
        selectedProfileId: profiles.length == 1
            ? profiles.first.id
            : (_settings.selectedProfileId.isEmpty ? profiles.first.id : _settings.selectedProfileId),
      ),
    );
    return profiles.length;
  }

  String? _unwrapSubscriptionDeepLink(String raw) {
    final trimmed = raw.trim();
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('sub://')) {
      final body = trimmed.substring(6).split('#').first.trim();
      if (body.startsWith('http://') || body.startsWith('https://')) {
        return body;
      }
      try {
        var b64 = body.replaceAll('-', '+').replaceAll('_', '/');
        if (b64.length % 4 != 0) {
          b64 = b64.padRight(b64.length + (4 - b64.length % 4), '=');
        }
        final decoded = utf8.decode(base64.decode(b64)).trim();
        if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
          return decoded;
        }
      } catch (_) {}
    }
    if (lower.startsWith('happ://crypt')) {
      final slashIdx = trimmed.indexOf('/', 'happ://crypt'.length);
      if (slashIdx > 0 && slashIdx + 1 < trimmed.length) {
        final body = trimmed.substring(slashIdx + 1).split('#').first.trim();
        try {
          var b64 = body.replaceAll('-', '+').replaceAll('_', '/');
          if (b64.length % 4 != 0) {
            b64 = b64.padRight(b64.length + (4 - b64.length % 4), '=');
          }
          final decoded = utf8.decode(base64.decode(b64)).trim();
          if (decoded.startsWith('http://') || decoded.startsWith('https://')) {
            return decoded;
          }
        } catch (_) {}
      }
    }
    if (lower.startsWith('v2raytun://') ||
        lower.startsWith('happ://') ||
        lower.startsWith('v2rayng://') ||
        lower.startsWith('clash://') ||
        lower.startsWith('clashmeta://') ||
        lower.startsWith('flclash://') ||
        lower.startsWith('sing-box://') ||
        lower.startsWith('hiddify://') ||
        lower.startsWith('streisand://') ||
        lower.startsWith('karing://') ||
        lower.startsWith('tachyon://')) {
      final uri = Uri.tryParse(trimmed);
      final urlParam = uri?.queryParameters['url'] ??
          uri?.queryParameters['config'] ??
          uri?.queryParameters['sub'];
      if (urlParam != null && urlParam.isNotEmpty) {
        return Uri.decodeComponent(urlParam).trim();
      }
      final idx = trimmed.indexOf('https://');
      if (idx > 0) {
        final tail = trimmed.substring(idx).split('#').first.trim();
        return tail.contains('%3A%2F%2F') || tail.contains('%2F')
            ? Uri.decodeComponent(tail)
            : tail;
      }
      final idxHttp = trimmed.indexOf('http://');
      if (idxHttp > 0) {
        final tail = trimmed.substring(idxHttp).split('#').first.trim();
        return tail.contains('%3A%2F%2F') || tail.contains('%2F')
            ? Uri.decodeComponent(tail)
            : tail;
      }
    }
    return null;
  }

  /// Извлекает ссылку на подписку или прямые URI серверов из HTML-лендинга личного кабинета
  /// (Marzban, Remnawave, 3x-ui, PasarGuard, Hiddify).
  (String? subUrl, List<Profile> profiles) _extractFromHtmlLanding(
    String html,
    String subId,
    LinkParser parser,
  ) {
    // 1. Проверяем, нет ли в HTML зашитых deep-link кнопок (v2raytun://import/https://..., happ://add/https://..., sing-box://...)
    final deepLinks = RegExp(
      r"""(v2raytun|happ|hiddify|sing-box|clash|v2rayng|streisand|karing)://[^\s"'<>]+""",
      caseSensitive: false,
    ).allMatches(html);
    for (final m in deepLinks) {
      final unwrapped = _unwrapSubscriptionDeepLink(m.group(0)!);
      if (unwrapped != null &&
          (unwrapped.startsWith('https://') || unwrapped.startsWith('http://'))) {
        return (unwrapped, const []);
      }
    }

    // 2. Проверяем прямые URI протоколов (vless://, hy2://, trojan://, ss://, vmess:// и др.) внутри HTML
    final directMatches = RegExp(
      r"""(vless|vmess|trojan|ss|hy2|hysteria2|tuic|amneziawg|awg|wg|anytls|tewfai)://[^\s"'<>\\]+""",
      caseSensitive: false,
    ).allMatches(html);
    if (directMatches.isNotEmpty) {
      final joined = directMatches.map((m) => m.group(0)!).join('\n');
      final parsed = parser.parseSubscription(joined, subscriptionId: subId);
      if (parsed.isNotEmpty) {
        return (null, parsed);
      }
    }

    return (null, const []);
  }

  /// Добавляет подписку: ядро качает её само, с железными заголовками.
  Future<void> addSubscription(String url) async {
    var clean = url.trim();
    final unwrapped = _unwrapSubscriptionDeepLink(clean);
    if (unwrapped != null && unwrapped.isNotEmpty) {
      clean = unwrapped;
    }
    if (!clean.startsWith('http://') && !clean.startsWith('https://')) {
      _lastError = 'подписка должна быть http(s)-ссылкой';
      notifyListeners();
      return;
    }
    final existing = _settings.subscriptions
        .where((sub) => sub.url == clean)
        .toList(growable: false);
    if (existing.isNotEmpty) {
      // Подписка уже существует: принудительно обновляем её серверы
      _lastError = '';
      await fetchSubscription(existing.first.id);
      return;
    }
    final id = 's${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    await _update(_settings.copyWith(
      subscriptions: [
        ..._settings.subscriptions,
        SubscriptionEntry(id: id, url: clean),
      ],
    ));
    _lastError = '';
    // Мгновенно загружаем серверы, чтобы они сразу появились на дашборде!
    await fetchSubscription(id);
  }


  /// Загружает содержимое подписки по сети, парсит серверы и кладёт в профили.
  Future<int> fetchSubscription(String subId) async {
    final sub = _settings.subscriptions.where((s) => s.id == subId).firstOrNull;
    if (sub == null || sub.url.isEmpty) return 0;
    _loadingSubscription = true;
    _lastError = '';
    notifyListeners();

    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..badCertificateCallback = ((cert, host, port) => true);

      var hwid = _settings.hwid;
      if (hwid.isEmpty) {
        final rng = Random.secure();
        hwid = List.generate(16, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
        _settings = _settings.copyWith(hwid: hwid);
        unawaited(_persist());
      }

      const userAgents = [
        'v2rayNG/1.8.5 (Linux; Android)',
        'Tachyon/0.0.3 (Android; compatible; sing-box/1.11; HiddifyNext)',
        'Happ/1.6.0 (Android; compatible; sing-box; Mihomo)',
        'v2rayTun/1.8.20 (Android)',
        'ClashMetaForAndroid/2.11.2.Meta',
      ];

      final parser = LinkParser();
      List<Profile> fresh = const [];
      HttpClientResponse? response;
      var lastStatusCode = 0;
      var gotHtml = false;
      var targetSubUrl = sub.url.trim();
      Map<String, dynamic>? nativeUserInfo;

      // 1. Сначала пробуем адаптивную загрузку и разбор напрямую через нативный движок tachyon-core
      final nativeRes = await bridge.fetchSubscription(
        targetSubUrl,
        sendHwid: true,
        customHwid: hwid,
        insecure: true,
      );
      if (nativeRes != null &&
          nativeRes['ok'] == true &&
          nativeRes['nodes'] is List) {
        fresh = parser.parseEngineNodes(
          nativeRes['nodes'] as List,
          (nativeRes['primary_tags'] as List?) ?? const [],
          subscriptionId: subId,
        );
        if (nativeRes['user_info'] is Map) {
          nativeUserInfo = Map<String, dynamic>.from(nativeRes['user_info'] as Map);
        }
      }

      // 2. Фоллбэк: если провайдер отдал HTML-лендинг или кастомную схему роутера
      for (final ua in fresh.isNotEmpty ? const <String>[] : userAgents) {
        var currentUrl = targetSubUrl;
        HttpClientResponse? attemptResp;
        for (var redirect = 0; redirect < 6; redirect++) {
          final uri = Uri.tryParse(currentUrl);
          if (uri == null) {
            _lastError = 'Некорректная ссылка: $currentUrl';
            notifyListeners();
            return 0;
          }
          final request = await client.getUrl(uri);
          request.headers.set('User-Agent', ua);
          request.headers.set('Accept', 'application/json, text/plain, */*');
          request.headers.set('Accept-Encoding', 'gzip, deflate');
          request.headers.set('X-Hwid', hwid);
          request.headers.set('x-device-os', 'Android');
          request.headers.set('x-ver-os', '14');
          request.headers.set('x-device-model', 'Android');
          request.followRedirects = false;
          attemptResp = await request.close();

          if (attemptResp.statusCode >= 300 && attemptResp.statusCode < 400) {
            final loc = attemptResp.headers.value(HttpHeaders.locationHeader);
            await attemptResp.drain();
            if (loc != null && loc.isNotEmpty) {
              currentUrl = uri.resolve(loc).toString();
              continue;
            }
          }
          break;
        }

        if (attemptResp == null) continue;
        lastStatusCode = attemptResp.statusCode;
        if (attemptResp.statusCode != 200) {
          await attemptResp.drain();
          continue;
        }

        var bytes = await attemptResp.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
        if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
          try {
            bytes = gzip.decode(bytes);
          } catch (_) {}
        }

        String body;
        try {
          body = utf8.decode(bytes);
        } catch (_) {
          body = latin1.decode(bytes);
        }

        final trimmed = body.trim();
        if (trimmed.toLowerCase().startsWith('<!doctype html') ||
            trimmed.toLowerCase().startsWith('<html')) {
          gotHtml = true;
          final (extractedSubUrl, extractedProfiles) = _extractFromHtmlLanding(
            trimmed,
            subId,
            parser,
          );
          if (extractedProfiles.isNotEmpty) {
            fresh = extractedProfiles;
            response = attemptResp;
            break;
          }
          if (extractedSubUrl != null &&
              extractedSubUrl.isNotEmpty &&
              extractedSubUrl != targetSubUrl) {
            targetSubUrl = extractedSubUrl;
          }
          continue;
        }

        var parsed = <Profile>[];
        final nativeBodyParsed = await bridge.parseSubscription(body);
        if (nativeBodyParsed != null &&
            nativeBodyParsed['ok'] == true &&
            nativeBodyParsed['nodes'] is List) {
          parsed = parser.parseEngineNodes(
            nativeBodyParsed['nodes'] as List,
            (nativeBodyParsed['primary_tags'] as List?) ?? const [],
            subscriptionId: subId,
          );
        }
        if (parsed.isEmpty) {
          parsed = parser.parseSubscription(body, subscriptionId: subId);
        }
        if (parsed.isNotEmpty) {
          fresh = parsed;
          response = attemptResp;
          break;
        }
      }

      if (fresh.isEmpty) {
        if (lastStatusCode != 200 && lastStatusCode != 0) {
          _lastError = 'Сервер вернул HTTP $lastStatusCode при загрузке подписки';
        } else if (gotHtml) {
          _lastError = 'Сервер вернул HTML-страницу вместо серверов (Cloudflare/капча/ошибка хостинга)';
        } else {
          final nativeErr = nativeRes?['error']?.toString() ?? '';
          _lastError = nativeErr.isNotEmpty
              ? 'Не удалось загрузить подписку ($nativeErr)'
              : 'В ответе подписки не найдено распознаваемых серверов';
        }
        notifyListeners();
        return 0;
      }

      // Парсим метаданные подписки (Subscription-Userinfo, Profile-Title, Support-Url)
      int uploadBytes = (nativeUserInfo?['upload'] as num?)?.toInt() ?? sub.uploadBytes;
      int downloadBytes = (nativeUserInfo?['download'] as num?)?.toInt() ?? sub.downloadBytes;
      int totalBytes = (nativeUserInfo?['total'] as num?)?.toInt() ?? sub.totalBytes;
      int expireUnix = (nativeUserInfo?['expire'] as num?)?.toInt() ?? sub.expireUnix;
      final userInfo = response?.headers.value('subscription-userinfo') ??
          response?.headers.value('Subscription-Userinfo') ??
          '';
      if (userInfo.isNotEmpty) {
        for (final part in userInfo.split(';')) {
          final kv = part.trim().split('=');
          if (kv.length == 2) {
            final k = kv[0].trim().toLowerCase();
            final v = int.tryParse(kv[1].trim()) ?? 0;
            if (k == 'upload') uploadBytes = v;
            if (k == 'download') downloadBytes = v;
            if (k == 'total') totalBytes = v;
            if (k == 'expire') expireUnix = v;
          }
        }
      }
      var parsedTitle = sub.name;
      if (parsedTitle.isEmpty) {
        final rawTitle = response?.headers.value('profile-title') ??
            response?.headers.value('Profile-Title') ??
            '';
        if (rawTitle.startsWith('base64:')) {
          try {
            parsedTitle = utf8.decode(base64.decode(rawTitle.substring(7).trim()));
          } catch (_) {}
        } else if (rawTitle.isNotEmpty) {
          parsedTitle = rawTitle.trim();
        }
      }
      final supportUrl = response?.headers.value('support-url') ??
          response?.headers.value('profile-web-page-url') ??
          sub.supportUrl;

      // Сохраняем файл кэша для ядра в виде готового списка outbounds (sing-box JSON)
      try {
        final cacheFile = File('$filesDirPath/subs/$subId.txt');
        await cacheFile.parent.create(recursive: true);
        final outboundsList = fresh.map((p) => p.toOutbound(tag: p.name)).toList();
        await cacheFile.writeAsString(jsonEncode(outboundsList));
      } catch (_) {}

      // Заменяем старые профили этой подписки свежими
      final otherProfiles = _settings.profiles.where((p) => p.subscriptionId != subId).toList();
      final updatedProfiles = [...otherProfiles, ...fresh];
      final keepSelected = _settings.selectedProfileId.startsWith('auto:') ||
          updatedProfiles.any((p) => p.id == _settings.selectedProfileId);
      final newSelected = keepSelected
          ? _settings.selectedProfileId
          : updatedProfiles.first.id;
      final updatedSubs = [
        for (final s in _settings.subscriptions)
          if (s.id == subId)
            s.copyWith(
              name: parsedTitle,
              uploadBytes: uploadBytes,
              downloadBytes: downloadBytes,
              totalBytes: totalBytes,
              expireUnix: expireUnix,
              updatedAt: DateTime.now().millisecondsSinceEpoch,
              supportUrl: supportUrl,
            )
          else
            s,
      ];

      await _update(_settings.copyWith(
        profiles: updatedProfiles,
        selectedProfileId: newSelected,
        subscriptions: updatedSubs,
      ));
      _lastError = '';
      return fresh.length;
    } catch (e) {
      _lastError = 'Сбой сети: $e';
      notifyListeners();
      return 0;
    } finally {
      _loadingSubscription = false;
      notifyListeners();
    }
  }

  /// Редактирует подписку (URL или название) и обновляет её.
  Future<void> editSubscription(String id, {String? url, String? name}) async {
    await _update(_settings.copyWith(
      subscriptions: [
        for (final s in _settings.subscriptions)
          if (s.id == id)
            s.copyWith(
              url: url?.trim() ?? s.url,
              name: name?.trim() ?? s.name,
            )
          else
            s,
      ],
    ));
    if (url != null && url.isNotEmpty) {
      await fetchSubscription(id);
    }
  }

  /// Удаляет подписку, её серверы и её кэш.
  Future<void> removeSubscription(String id) async {
    final file = File('$filesDirPath/subs/$id.txt');
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }
    final remainingProfiles = _settings.profiles
        .where((p) => p.subscriptionId != id)
        .toList(growable: false);
    final nextSelected = remainingProfiles.any((p) => p.id == _settings.selectedProfileId)
        ? _settings.selectedProfileId
        : (remainingProfiles.isNotEmpty ? remainingProfiles.first.id : '');

    await _update(_settings.copyWith(
      subscriptions: _settings.subscriptions
          .where((sub) => sub.id != id)
          .toList(growable: false),
      profiles: remainingProfiles,
      selectedProfileId: nextSelected,
    ));
  }

  /// Включает или выключает подписку.
  Future<void> toggleSubscription(String id) async {
    await _update(_settings.copyWith(
      subscriptions: [
        for (final sub in _settings.subscriptions)
          if (sub.id == id) sub.copyWith(enabled: !sub.enabled) else sub,
      ],
    ));
  }

  /// Меняет тему оформления: `dark` или `light`.
  Future<void> setThemeMode(String mode) async {
    await _update(_settings.copyWith(themeMode: mode));
  }

  /// Меняет настройки обхода DPI.
  Future<void> setDesync(DesyncSettings desync) async {
    await _update(_settings.copyWith(desync: desync));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет уровень журнала ядра.
  Future<void> setLogLevel(String level) async {
    await _update(_settings.copyWith(logLevel: level));
  }

  /// Меняет режим маршрутизации.
  Future<void> setRoutingMode(RoutingMode mode) async {
    final changed = _settings.routingMode != mode;
    await _update(_settings.copyWith(routingMode: mode));
    if (changed && _tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Назначает встроенному сервису (YouTube, Discord и др.) конкретный маршрут:
  /// `desync`, `proxy`, `direct`, `block`, либо `off` (выключено).
  Future<void> setServiceRoute(String serviceId, String outbound) async {
    final routes = Map<String, String>.from(_settings.serviceRoutes);
    if (outbound.isEmpty || outbound == 'off') {
      routes.remove(serviceId);
    } else {
      routes[serviceId] = outbound;
    }
    await _update(_settings.copyWith(serviceRoutes: routes));
    if (outbound.isNotEmpty && outbound != 'off') {
      await ensureRequiredListsDownloaded();
    }
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет режим по приложениям.
  Future<void> setAppsMode(AppsMode mode) async {
    await _update(_settings.copyWith(appsMode: mode));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Отмечает или снимает отметку с приложения.
  Future<void> toggleApp(String packageName) async {
    final packages = [..._settings.appPackages];
    if (packages.contains(packageName)) {
      packages.remove(packageName);
    } else {
      packages.add(packageName);
    }
    await _update(_settings.copyWith(appPackages: packages));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет параметры DNS.
  Future<void> setDns(DnsSettings dns) async {
    await _update(_settings.copyWith(dns: dns));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Включает или выключает список правил.
  Future<void> toggleRuleSet(String id) async {
    var enabling = false;
    final sets = _settings.ruleSets.map((set) {
      if (set.id != id) return set;
      enabling = !set.enabled;
      return set.copyWith(enabled: !set.enabled);
    }).toList();
    await _update(_settings.copyWith(ruleSets: sets));
    if (enabling) {
      final path = lists.pathFor(id);
      if (path.isNotEmpty && !File(path).existsSync()) {
        await downloadList(id);
      }
    }
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет действие списка: в туннель, напрямую или блокировать.
  Future<void> setRuleSetAction(String id, String action) async {
    final sets = _settings.ruleSets.map((set) {
      if (set.id != id) return set;
      return set.copyWith(action: action);
    }).toList();
    await _update(_settings.copyWith(ruleSets: sets));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Обновляет каталог списков и подтягивает описание на диск.
  Future<void> refreshLists() async {
    _lastError = '';
    try {
      final catalog = await lists.refreshCatalog();
      final existing = {
        for (final set in _settings.ruleSets) set.id: set,
      };
      final merged = <RuleSetEntry>[];
      for (final entry in catalog.entries) {
        final previous = existing[entry.id];
        merged.add(
          RuleSetEntry(
            id: entry.id,
            title: entry.title,
            path: previous?.path ?? lists.pathFor(entry.id),
            action: previous?.action ?? entry.routeAction,
            enabled: previous?.enabled ?? false,
            sizeBytes: previous?.sizeBytes ?? 0,
            updatedAt: previous?.updatedAt ?? 0,
            ttlHours: previous?.ttlHours ?? 24,
          ),
        );
      }
      await _update(_settings.copyWith(ruleSets: merged));
    } catch (error) {
      _lastError = 'каталог списков недоступен: $error';
      notifyListeners();
    }
  }

  /// Скачивает список правил.
  Future<void> downloadList(String id) async {
    _lastError = '';
    notifyListeners();
    final result = await lists.download(id);
    if (result.startsWith('/') || result.contains(RegExp(r'^[A-Z]:'))) {
      final size = await lists.sizeOf(id);
      final sets = _settings.ruleSets.map((set) {
        if (set.id != id) return set;
        return set.copyWith(
          path: result,
          sizeBytes: size,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }).toList();
      await _update(_settings.copyWith(ruleSets: sets));
    } else {
      _lastError = result;
      notifyListeners();
    }
  }

  /// Приватный каталог: кэш подписок. Заполняется при загрузке.
  String filesDirPath = '';

  /// Собирает конфигурацию для текущих настроек.
  ///
  /// Возвращает null только когда нет ни профиля, ни подписок, ни режима DPI.
  RuntimeConfig? buildConfig() {
    final profile = selectedProfile;
    final hasProfile = profile != null && profile.server.isNotEmpty;
    final hasSubs = _settings.subscriptions.any((sub) => sub.enabled);
    final hasDesync = _settings.routingMode == RoutingMode.desync ||
        _settings.desync.enabled ||
        _settings.serviceRoutes.values.contains('desync') ||
        _settings.appRoutes.values.contains('desync') ||
        _settings.customRules.any((r) => r.enabled && r.action == 'desync');
    if (!hasProfile && !hasSubs && !hasDesync) return null;
    return RuntimeConfig(
      profile: profile ?? const Profile(id: '', name: '', type: 'direct', server: '', port: 0),
      routingMode: _settings.routingMode,
      dns: _settings.dns,
      ruleSets: _settings.ruleSets,
      logLevel: _settings.logLevel == 'warn' ? 'info' : _settings.logLevel,
      mtu: _settings.mtu,
      desync: _settings.desync,
      subscriptions: hasProfile ? const [] : _settings.subscriptions,
      filesDir: filesDirPath,
      appRoutes: _settings.appRoutes,
      serviceRoutes: _settings.serviceRoutes,
      customRules: _settings.customRules,
      allowLan: _settings.allowLan,
      proxyOnly: _settings.proxyOnly,
      detourProfile: _settings.detourProfile,
      extraProfiles: _settings.profiles,
      proxyTlsFragment: _settings.proxyTlsFragment,
    );
  }

  /// Поднимает или опускает туннель.
  Future<void> toggleTunnel() async {
    if (_tunnel.status.isBusy) return;

    if (_tunnel.status.isActive) {
      _tunnel = _tunnel.copyWith(status: VpnStatus.disconnecting);
      notifyListeners();
      await bridge.stop();
      _upSpeed = 0;
      _downSpeed = 0;
      _prevTrafficAt = null;
      _urlTestPing = null;
      _exitIp = '';
      _exitCountry = '';
      _exitCity = '';
      _exitFlag = '';
      _exitIsp = '';
      _latencyHistory.clear();
      _tunnel = _tunnel.copyWith(
        status: VpnStatus.disconnected,
        clearStartedAt: true,
      );
      notifyListeners();
      return;
    }

    await ensureRequiredListsDownloaded();
    final config = buildConfig();
    if (config == null) {
      _lastError = 'нет профиля или подписки';
      notifyListeners();
      return;
    }

    final currentServer = _settings.routingMode == RoutingMode.desync
        ? 'Режим Обход DPI (Desync)'
        : (selectedProfile?.name ?? (config.profile.name.isNotEmpty ? config.profile.name : ''));
    _tunnel = _tunnel.copyWith(
      status: VpnStatus.connecting,
      error: '',
      serverName: currentServer,
    );
    notifyListeners();

    final error = await bridge.start(
      config.encode(),
      allowedApps: _allowedApps,
      disallowedApps: _disallowedApps,
      serverName: currentServer,
      mtu: _settings.mtu,
      proxyOnly: _settings.proxyOnly,
    );
    if (error != null) {
      _tunnel = _tunnel.copyWith(
        status: VpnStatus.failed,
        error: error,
        serverName: currentServer,
      );
      _lastError = error;
      notifyListeners();
      return;
    }

    // Дальше состояние придёт от нативного слоя: ядро сообщает «connected»
    // только когда оно действительно поднялось. Пока этого не случилось,
    // интерфейс остаётся в состоянии «подключение».
    _tunnel = _tunnel.copyWith(serverName: currentServer.isNotEmpty ? currentServer : config.profile.name);
    notifyListeners();
  }

  /// Состояние от нативного слоя: оно авторитетнее локального.
  void _applyNativeState(TunnelState state) {
    final server = _settings.routingMode == RoutingMode.desync
        ? 'Режим Обход DPI (Desync)'
        : (selectedProfile?.name ?? '');
    if (state.status == VpnStatus.connected) {
      _tunnel = state.copyWith(
        serverName: server,
        startedAt: _tunnel.startedAt ?? DateTime.now(),
      );
      unawaited(_pollTrafficOnce());
      unawaited(refreshExitGeo());
    } else {
      if (!state.status.isActive) {
        _exitIp = '';
        _exitCountry = '';
        _exitCity = '';
        _exitFlag = '';
        _exitIsp = '';
      }
      _tunnel = _withServer(state);
    }
    notifyListeners();
  }

  /// Дописывает имя выбранного сервера к состоянию.
  TunnelState _withServer(TunnelState state) => state.copyWith(
        serverName: _settings.routingMode == RoutingMode.desync
            ? 'Режим Обход DPI (Desync)'
            : (selectedProfile?.name ?? ''),
      );

  /// Приложения, которым разрешено ходить в туннель.
  ///
  /// В режиме «все» список пуст: в туннель идёт весь трафик. В режиме
  /// «только выбранные» — отмеченные пакеты. В режиме «кроме выбранных» —
  /// наоборот, отмеченные пакеты идут мимо туннеля.
  List<String> get _allowedApps {
    if (_settings.appsMode == AppsMode.allow) return _settings.appPackages;
    return const [];
  }

  /// Приложения, исключённые из туннеля.
  ///
  /// Включает как список `AppsMode.deny`, так и приложения с точечным правилом
  /// `direct` из `appRoutes` (чтобы их трафик гарантированно шёл мимо VPN даже на
  /// ядрах Android с ограничением netlink UID-lookup).
  List<String> get _disallowedApps {
    final set = <String>{};
    if (_settings.appsMode == AppsMode.deny) {
      set.addAll(_settings.appPackages);
    }
    if (_settings.appsMode != AppsMode.allow) {
      for (final entry in _settings.appRoutes.entries) {
        if (entry.value == 'direct' && entry.key.isNotEmpty) {
          set.add(entry.key);
        }
      }
    }
    return set.toList(growable: false);
  }

  /// Проверяет конфигурацию движком, не запуская туннель.
  Future<String?> checkConfig() async {
    final config = buildConfig();
    if (config == null) return 'не выбран профиль';
    final result = await bridge.check(config.encode());
    return result.ok ? null : result.error;
  }

  /// Прогоняет проверку DNS-резолверов.
  Future<void> runDnsBenchmark() async {
    if (_dnsBenchmarkRunning) return;
    _dnsBenchmarkRunning = true;
    _dnsResults.clear();
    notifyListeners();

    final benchmark = DnsBenchmark();
    await benchmark.run(
      onResult: (result) {
        _dnsResults.add(result);
        notifyListeners();
      },
    );

    _dnsBenchmarkRunning = false;
    notifyListeners();
  }

  /// Применяет лучшие найденные резолверы.
  ///
  /// Результат помечается временем проверки: когда он устареет, приложение
  /// предложит проверить резолверы заново.
  Future<void> applyDnsRecommendation() async {
    if (_dnsResults.isEmpty) return;
    final recommendation = DnsRecommendation.from(_dnsResults);
    await setDns(
      _settings.dns.copyWith(
        autoSelect: true,
        servers: recommendation.servers,
        bootstrap: recommendation.bootstrap,
        checkedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  /// Нужно ли заново проверять резолверы.
  bool get needsDnsCheck => _settings.dns.isStale(DateTime.now());

  /// Время последней проверки резолверов.
  DateTime? get dnsCheckedAt {
    final at = _settings.dns.checkedAt;
    return at == 0 ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  /// Статистика трафика: null, пока ядро не запущено.
  TrafficStats? get traffic => _traffic;

  Future<void> _pollTrafficOnce() async {
    final next = await bridge.stats();
    final now = DateTime.now();
    if (next != null) {
      final dtMs = _prevTrafficAt == null
          ? 2000
          : now.difference(_prevTrafficAt!).inMilliseconds.clamp(250, 10000);
      final du = next.up - _prevUp;
      final dd = next.down - _prevDown;
      _upSpeed = du > 0 ? (du * 1000 ~/ dtMs) : 0;
      _downSpeed = dd > 0 ? (dd * 1000 ~/ dtMs) : 0;
      _prevUp = next.up;
      _prevDown = next.down;
      _prevTrafficAt = now;
      if (_downHistory.length >= 24) _downHistory.removeAt(0);
      _downHistory.add(_downSpeed);
      if (_upHistory.length >= 24) _upHistory.removeAt(0);
      _upHistory.add(_upSpeed);
    } else {
      _upSpeed = 0;
      _downSpeed = 0;
      _prevUp = 0;
      _prevDown = 0;
      _prevTrafficAt = null;
    }
    _traffic = next;
    _pollTickCount++;

    // Автоматическое переключение рецепта Desync при смене Wi-Fi <-> Мобильная сеть
    if (_settings.perNetworkDesync && _pollTickCount % 5 == 0) {
      unawaited(_checkNetworkDesyncProfile());
    }

    // Smart Failover (Watchdog): раз в 30 сек проверяет живой отклик туннеля
    if (_tunnel.status.isActive &&
        _settings.smartFailover &&
        _settings.routingMode != RoutingMode.desync &&
        _settings.profiles.length > 1 &&
        _pollTickCount % 15 == 0) {
      unawaited(_runFailoverCheck());
    }

    notifyListeners();
  }

  Future<void> _checkNetworkDesyncProfile() async {
    final net = await bridge.networkType();
    if (net == _lastNetType || (net != 'wifi' && net != 'cellular')) return;
    _lastNetType = net;
    final targetPreset = net == 'wifi'
        ? _settings.desync.wifiPreset
        : _settings.desync.cellularPreset;
    if (targetPreset.isNotEmpty && targetPreset != _settings.desync.preset) {
      await setDesync(_settings.desync.copyWith(preset: targetPreset));
    } else {
      notifyListeners();
    }
  }

  Future<void> _runFailoverCheck() async {
    if (_testingUrlPing || _pingingAll) return;
    final ms = await testUrlPing();
    if (ms < 0) {
      _consecutiveWatchdogFails++;
      if (_consecutiveWatchdogFails >= 2) {
        _consecutiveWatchdogFails = 0;
        await autoSelectBestServer();
      }
    } else {
      _consecutiveWatchdogFails = 0;
    }
  }

  /// Начинает опрос статистики трафика.
  void startTrafficPolling() {
    stopTrafficPolling();
    unawaited(_pollTrafficOnce());
    _trafficTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _pollTrafficOnce();
    });
  }

  /// Останавливает опрос статистики.
  void stopTrafficPolling() {
    _trafficTimer?.cancel();
    _trafficTimer = null;
    _upSpeed = 0;
    _downSpeed = 0;
    _prevUp = 0;
    _prevDown = 0;
    _prevTrafficAt = null;
  }

  /// Читает журнал ядра.
  Future<void> refreshLogs() async {
    _logs = await bridge.logs();
    notifyListeners();
  }

  /// Очищает журнал ядра.
  Future<void> clearLogs() async {
    await bridge.clearLogs();
    _logs = const [];
    notifyListeners();
  }

  /// Открывает системное меню «Поделиться».
  Future<void> shareText(String text, {String subject = ''}) =>
      bridge.shareText(text, subject: subject);

  /// Сканирует QR-код камерой или из галереи и импортирует подписку/профили.
  /// Возвращает `null`, если сканирование отменено; `-1` при добавлении подписки;
  /// `> 0` — число добавленных серверов; `0` — ошибка разбора.
  Future<int?> scanAndImportQr({bool fromGallery = false}) async {
    final raw = await bridge.scanQr(fromGallery: fromGallery);
    if (raw == null || raw.trim().isEmpty) return null;
    return importProfiles(raw.trim());
  }

  /// Выполняет HTTPS-запрос через локальный mixed-инбаунд ядра (`127.0.0.1:2080`),
  /// если туннель активен, и возвращает время отклика в мс (или `-1` при ошибке).
  ///
  /// Так как сам пакет `app.tachyon.tachyon_proxy` добавлен в `addDisallowedApplication`
  /// в `TachyonVpnService` для защиты от петель маршрутизации, прямые сокеты из Dart
  /// идут мимо TUN. Направление проверочного запроса в `127.0.0.1:2080` гарантирует,
  /// что тест реально проходит через `tachyon-core` (включая `desync` и `proxy`).
  Future<int> _probeHttpsViaCore(
    String url, {
    Duration timeout = const Duration(milliseconds: 2800),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = const Duration(seconds: 1)
      ..badCertificateCallback = (_, _, _) => true;
    if (_tunnel.status.isActive) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
    }
    try {
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set('Cache-Control', 'no-cache');
      req.headers.set('Connection', 'close');
      final resp = await req.close().timeout(timeout);
      await resp.drain<void>().timeout(timeout);
      sw.stop();
      if (resp.statusCode > 0 && resp.statusCode < 500) {
        return sw.elapsedMilliseconds;
      }
      return -1;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  /// Проверяет реальный сквозной HTTP 204 пинг через текущий маршрут/туннель.
  Future<int> testUrlPing() async {
    if (_testingUrlPing) return _urlTestPing ?? -1;
    _testingUrlPing = true;
    notifyListeners();
    var result = -1;
    try {
      result = await _probeHttpsViaCore(
        'http://cp.cloudflare.com/generate_204',
        timeout: const Duration(seconds: 5),
      );
    } finally {
      _urlTestPing = result;
      if (result > 0) {
        if (_latencyHistory.length >= 24) _latencyHistory.removeAt(0);
        _latencyHistory.add(result);
      }
      _testingUrlPing = false;
      notifyListeners();
    }
    return result;
  }

  /// Определяет внешний IP-адрес, флаг страны, город и провайдера через активный туннель,
  /// а также обновляет историю задержки для спарклайна `ExitNodeCard`.
  Future<void> refreshExitGeo() async {
    if (_refreshingExitGeo) return;
    _refreshingExitGeo = true;
    notifyListeners();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 1)
      ..badCertificateCallback = (_, _, _) => true;
    if (_tunnel.status.isActive) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
    }

    try {
      // Замеряем живой пинг параллельно с определением GeoIP
      unawaited(testUrlPing());

      Future<Map<String, dynamic>?> fetchJson(String url) async {
        try {
          final sw = Stopwatch()..start();
          final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
          req.headers.set('Accept', 'application/json');
          req.headers.set('User-Agent', 'Tachyon/0.0.4');
          final resp = await req.close().timeout(const Duration(seconds: 4));
          if (resp.statusCode != 200) {
            await resp.drain<void>();
            return null;
          }
          final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
          sw.stop();
          if (_latencyHistory.isEmpty && sw.elapsedMilliseconds > 0) {
            _latencyHistory.add(sw.elapsedMilliseconds);
            _urlTestPing ??= sw.elapsedMilliseconds;
          }
          final decoded = jsonDecode(body);
          return decoded is Map<String, dynamic> ? decoded : null;
        } catch (_) {
          return null;
        }
      }

      var data = await fetchJson('https://ipwho.is/?lang=ru');
      if (data != null && data['success'] != false && (data['ip'] as String?)?.isNotEmpty == true) {
        _exitIp = (data['ip'] as String? ?? '').trim();
        _exitCountry = (data['country'] as String? ?? '').trim();
        _exitCity = (data['city'] as String? ?? '').trim();
        final cc = (data['country_code'] as String? ?? '').trim().toUpperCase();
        _exitFlag = _countryCodeToFlag(cc);
        final conn = data['connection'];
        _exitIsp = conn is Map ? (conn['isp']?.toString() ?? conn['org']?.toString() ?? '').trim() : '';
      } else {
        data = await fetchJson('http://ip-api.com/json/?fields=status,country,countryCode,city,isp,query&lang=ru');
        if (data != null && data['status'] == 'success') {
          _exitIp = (data['query'] as String? ?? '').trim();
          _exitCountry = (data['country'] as String? ?? '').trim();
          _exitCity = (data['city'] as String? ?? '').trim();
          final cc = (data['countryCode'] as String? ?? '').trim().toUpperCase();
          _exitFlag = _countryCodeToFlag(cc);
          _exitIsp = (data['isp'] as String? ?? '').trim();
        }
      }
    } finally {
      client.close(force: true);
      _refreshingExitGeo = false;
      notifyListeners();
    }
  }

  String _countryCodeToFlag(String code) {
    if (code.length != 2) return '🌐';
    final a = code.codeUnitAt(0);
    final b = code.codeUnitAt(1);
    if (a < 65 || a > 90 || b < 65 || b > 90) return '🌐';
    return String.fromCharCodes([0x1F1E6 + (a - 65), 0x1F1E6 + (b - 65)]);
  }

  /// Автоподбор оптимального MTU для туннеля (по аналогии с MtuAutoScan в MSN-GUARD).
  /// Проверяет кандидатов от 1280 до 1460 байт без разрыва активных соединений
  /// и выставляет самый быстрый и стабильный MTU один раз в конце.
  Future<int> scanOptimalMtu() async {
    if (_scanningMtu) return _settings.mtu;
    _scanningMtu = true;
    _mtuScanStatus = 'Подготовка сканирования MTU...';
    notifyListeners();

    const candidates = [1460, 1420, 1400, 1380, 1360, 1320, 1280];
    final originalMtu = _settings.mtu;
    var bestMtu = 1400;
    var bestScore = 999999;

    try {
      for (var i = 0; i < candidates.length; i++) {
        final mtu = candidates[i];
        _mtuScanStatus = 'Проверка MTU $mtu (${i + 1}/${candidates.length})...';
        notifyListeners();

        final r1 = await _probeHttpsViaCore(
          'http://cp.cloudflare.com/generate_204',
          timeout: const Duration(milliseconds: 1500),
        );
        final r2 = await _probeHttpsViaCore(
          'https://www.gstatic.com/generate_204',
          timeout: const Duration(milliseconds: 1500),
        );

        final valid = [if (r1 > 0) r1, if (r2 > 0) r2];
        if (valid.isNotEmpty) {
          final avg = valid.reduce((a, b) => a + b) ~/ valid.length;
          final penalty = valid.length == 2 ? 0 : 120;
          final score = avg + penalty - ((mtu - 1280) ~/ 20);
          if (score < bestScore) {
            bestScore = score;
            bestMtu = mtu;
          }
        }
      }

      await setMtu(bestMtu);
      _mtuScanStatus =
          'Оптимальный MTU: $bestMtu байт (${bestScore < 999999 ? "$bestScore мс" : "применён"})';
      return bestMtu;
    } catch (e) {
      _mtuScanStatus = 'Ошибка автоподбора MTU: $e';
      return originalMtu;
    } finally {
      _scanningMtu = false;
      notifyListeners();
    }
  }

  /// Генерирует бесплатный Cloudflare WARP с обфускацией AmneziaWG (Anti-DPI),
  /// сканирует живые эндпоинты Cloudflare и выбирает самый быстрый узел.
  Future<int> provisionFreeWarp() async {
    if (_provisioningFreeNodes) return 0;
    _provisioningFreeNodes = true;
    _freeNodesStatus = 'Генерация бесплатного WARP (AmneziaWG)...';
    notifyListeners();

    try {
      final service = FreeNodesService();
      final generated = await service.generateWarpProfiles(
        useLocalProxy: _tunnel.status.isActive,
        onStatus: (msg) {
          _freeNodesStatus = msg;
          notifyListeners();
        },
      );
      if (generated.isEmpty) {
        _freeNodesStatus = 'Не удалось создать профили WARP';
        return 0;
      }

      const subId = 'free-warp';
      final otherSubs = _settings.subscriptions
          .where((s) => s.id != subId)
          .toList();
      final warpSub = SubscriptionEntry(
        id: subId,
        url: 'https://api.cloudflareclient.com/warp',
        name: '⚡ Cloudflare WARP (AmneziaWG)',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      final previousSelectedId = _settings.selectedProfileId;
      final otherProfiles = _settings.profiles
          .where((p) => p.subscriptionId != subId)
          .toList();
      final mergedProfiles = [...otherProfiles, ...generated];

      await _update(
        _settings.copyWith(
          subscriptions: [...otherSubs, warpSub],
          profiles: mergedProfiles,
          selectedProfileId: generated.first.id,
        ),
      );
      if (_tunnel.status.isActive) {
        await _restartActiveTunnel();
        await _waitForLocalProxyReady();
        final probeMs = await _probeHttpsViaCore(
          'http://cp.cloudflare.com/generate_204',
          timeout: const Duration(milliseconds: 3500),
        );
        if (probeMs < 0 &&
            previousSelectedId.isNotEmpty &&
            otherProfiles.isNotEmpty) {
          await _update(
            _settings.copyWith(selectedProfileId: previousSelectedId),
          );
          await _restartActiveTunnel();
          _freeNodesStatus =
              'Узлы WARP созданы (${generated.length} шт.), но ваш провайдер блокирует UDP WARP — возвращён рабочий профиль';
          return generated.length;
        }
      }
      _freeNodesStatus =
          'Готово: создано ${generated.length} узлов WARP AmneziaWG, выбран ${generated.first.name}';
      return generated.length;
    } catch (e) {
      _freeNodesStatus = 'Ошибка генерации WARP: $e';
      return 0;
    } finally {
      _provisioningFreeNodes = false;
      notifyListeners();
    }
  }

  /// Скачивает пул бесплатных узлов SHARD (как в MSN-GUARD), размножает по живым
  /// Cloudflare Edge IP, проводит параллельную гонку (Race) и выбирает лучший узел.
  Future<int> provisionFreeShardNodes() async {
    if (_provisioningFreeNodes) return 0;
    _provisioningFreeNodes = true;
    _freeNodesStatus = 'Подключение к пулу бесплатных узлов SHARD...';
    notifyListeners();

    try {
      final service = FreeNodesService();
      final winners = await service.fetchAndRaceShardNodes(
        useLocalProxy: _tunnel.status.isActive,
        onStatus: (msg) {
          _freeNodesStatus = msg;
          notifyListeners();
        },
      );
      if (winners.isEmpty) {
        _freeNodesStatus = 'Не удалось загрузить пул бесплатных узлов';
        return 0;
      }

      const subId = 'free-shard';
      final otherSubs = _settings.subscriptions
          .where((s) => s.id != subId)
          .toList();
      final shardSub = SubscriptionEntry(
        id: subId,
        url: FreeNodesService.shardSources.first,
        name: '⚡ Бесплатный пул (SHARD · CF Edge)',
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      final otherProfiles = _settings.profiles
          .where((p) => p.subscriptionId != subId)
          .toList();
      final mergedProfiles = [...winners, ...otherProfiles];

      await _update(
        _settings.copyWith(
          subscriptions: [shardSub, ...otherSubs],
          profiles: mergedProfiles,
          selectedProfileId: winners.first.id,
        ),
      );
      if (_tunnel.status.isActive) {
        await _restartActiveTunnel();
      }
      _freeNodesStatus =
          'Подобран лучший узел: ${winners.first.name} (всего ${winners.length})';
      return winners.length;
    } catch (e) {
      _freeNodesStatus = 'Ошибка автоподбора SHARD: $e';
      return 0;
    } finally {
      _provisioningFreeNodes = false;
      notifyListeners();
    }
  }

  /// Пингует серверы и автоматически переключается на самый быстрый рабочий сервер.
  Future<Profile?> autoSelectBestServer({String? subscriptionId}) async {
    await pingAllProfiles(subscriptionId: subscriptionId);
    final candidates = subscriptionId == null
        ? _settings.profiles
        : _settings.profiles.where((p) => p.subscriptionId == subscriptionId).toList();
    Profile? best;
    var bestMs = 999999;
    for (final p in candidates) {
      final ms = _pings[p.id];
      if (ms != null && ms >= 0 && ms < bestMs) {
        bestMs = ms;
        best = p;
      }
    }
    if (best != null) {
      await selectProfile(best.id);
    }
    return best;
  }

  /// Удаляет недоступные серверы (с пингом < 0) из списка или конкретной подписки.
  Future<int> removeDeadProfiles({String? subscriptionId}) async {
    final before = _settings.profiles.length;
    final remaining = _settings.profiles.where((p) {
      if (subscriptionId != null && p.subscriptionId != subscriptionId) return true;
      final ms = _pings[p.id];
      return ms == null || ms >= 0;
    }).toList();
    final removed = before - remaining.length;
    if (removed > 0) {
      final selectedExists = remaining.any((p) => p.id == _settings.selectedProfileId);
      await _update(_settings.copyWith(
        profiles: remaining,
        selectedProfileId: selectedExists
            ? _settings.selectedProfileId
            : (remaining.isNotEmpty ? remaining.first.id : ''),
      ));
    }
    return removed;
  }

  /// Добавляет или обновляет пользовательское правило маршрутизации.
  Future<void> addCustomRule(CustomRule rule) async {
    final list = [..._settings.customRules.where((r) => r.id != rule.id), rule];
    await _update(_settings.copyWith(customRules: list));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Переключает активность пользовательского правила.
  Future<void> toggleCustomRule(String id) async {
    final list = _settings.customRules
        .map((r) => r.id == id ? r.copyWith(enabled: !r.enabled) : r)
        .toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет действие пользовательского правила (proxy / direct / desync / block).
  Future<void> setCustomRuleAction(String id, String action) async {
    final list = _settings.customRules
        .map((r) => r.id == id ? r.copyWith(action: action) : r)
        .toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Удаляет пользовательское правило.
  Future<void> removeCustomRule(String id) async {
    final list = _settings.customRules.where((r) => r.id != id).toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Автоподбор оптимального рецепта Desync путём проверки TLS-соединения с YouTube/Discord.
  Future<String> autoPickDesyncPreset() async {
    final winner = await scanAllDesyncStrategies();
    return winner?.preset ?? _settings.desync.preset;
  }

  /// Глубокий сканер (Снайпер) стратегий Desync: тестирует 6 боевых связок
  /// `preset × fooling` с замером реального HTTPS-прохождения через `tachyon-core` (`127.0.0.1:2080`).
  Future<DesyncScanEntry?> scanAllDesyncStrategies() async {
    if (_testingDesync) return null;
    _testingDesync = true;
    _desyncScanResults = const [];
    _desyncTestStatus = 'Запуск снайпера стратегий DPI (6 профилей)...';
    notifyListeners();

    const candidates = [
      ('fake_disorder', 'autottl', 'Fake + Disorder (AutoTTL)'),
      ('fake_disorder', 'md5', 'Fake + Disorder (MD5 Sig)'),
      ('fake_split', 'autottl', 'Fake + Split (AutoTTL)'),
      ('fake_split', 'badseq', 'Fake + Split (BadSeq)'),
      ('multi_split', 'autottl', 'Multi-Split (Дробление TLS)'),
      ('tlsrec', 'md5', 'TLS Record Split (До SNI)'),
    ];

    final results = <DesyncScanEntry>[];
    DesyncScanEntry? best;
    final prevRoutingMode = _settings.routingMode;

    try {
      final netType = await bridge.networkType();
      _lastNetType = netType;

      for (var i = 0; i < candidates.length; i++) {
        final (preset, fooling, label) = candidates[i];
        _desyncTestStatus = '[${i + 1}/${candidates.length}] Тест $label...';
        notifyListeners();

        // На время замера принудительно направляем трафик в desync и отключаем autoTune,
        // чтобы ядро применило именно тестируемую пару preset + fooling.
        await _update(_settings.copyWith(
          routingMode: RoutingMode.desync,
          desync: _settings.desync.copyWith(
            enabled: true,
            preset: preset,
            fooling: fooling,
            autoTune: false,
          ),
        ));
        if (_tunnel.status.isActive) {
          await _restartActiveTunnel();
        } else {
          await toggleTunnel();
          await _waitForLocalProxyReady();
        }

        // Замеряем скорость реального HTTPS-ответа от YouTube и Discord через 127.0.0.1:2080
        final ytMs = await _probeHttpsViaCore(
          'https://www.youtube.com/generate_204',
          timeout: const Duration(milliseconds: 2600),
        );
        final dcMs = await _probeHttpsViaCore(
          'https://discord.com/api/v9/experiments',
          timeout: const Duration(milliseconds: 2600),
        );

        final scoreMs = (ytMs >= 0 && dcMs >= 0)
            ? ((ytMs + dcMs) ~/ 2)
            : (ytMs >= 0 ? ytMs : dcMs);

        final entry = DesyncScanEntry(
          preset: preset,
          fooling: fooling,
          label: label,
          youtubeMs: ytMs,
          discordMs: dcMs,
          avgMs: scoreMs,
        );
        results.add(entry);
        _desyncScanResults = [...results];
        if (scoreMs >= 0 && (best == null || scoreMs < best.avgMs)) {
          best = entry;
        }
        notifyListeners();
      }

      final winnerPreset = best?.preset ?? 'fake_disorder';
      final winnerFooling = best?.fooling ?? 'autottl';
      await _update(_settings.copyWith(
        routingMode: prevRoutingMode,
        desync: _settings.desync.copyWith(
          enabled: true,
          preset: winnerPreset,
          fooling: winnerFooling,
          autoTune: true,
          wifiPreset: netType == 'wifi' ? winnerPreset : _settings.desync.wifiPreset,
          cellularPreset: netType == 'cellular' ? winnerPreset : _settings.desync.cellularPreset,
        ),
      ));
      if (_tunnel.status.isActive) {
        await _restartActiveTunnel();
      }
      _desyncTestStatus = best != null
          ? 'Лучший: ${best.label} (${best.avgMs} мс)'
          : 'Применён надёжный профиль: $winnerPreset ($winnerFooling)';
      return best;
    } finally {
      if (_settings.routingMode != prevRoutingMode) {
        await _update(_settings.copyWith(routingMode: prevRoutingMode));
      }
      _testingDesync = false;
      notifyListeners();
    }
  }

  /// Быстрые шаблоны маршрутизации приложений в 1 клик.
  Future<int> applyAppPreset(String preset, List<InstalledApp> installed) async {
    final routes = Map<String, String>.from(_settings.appRoutes);
    var count = 0;
    if (preset == 'clear') {
      final prev = routes.length;
      routes.clear();
      await _update(_settings.copyWith(appRoutes: routes));
      if (_tunnel.status.isActive) {
        await _restartActiveTunnel();
      }
      return prev;
    }
    const ruKeywords = [
      'ru.sberbank',
      'sberbankonline',
      'com.idamob.tinkoff',
      'tbank',
      'ru.alfabank',
      'ru.vtb24',
      'vtb',
      'raiffeisen',
      'sovcombank',
      'gazprombank',
      'psbank',
      'rshb',
      'uralsib',
      'pochtabank',
      'mtsbank',
      'ozonbank',
      'yoomoney',
      'ru.rostel',
      'ru.gosuslugi',
      'com.vkontakte',
      'com.vk.im',
      'ru.ok.android',
      'ru.yandex',
      'com.yandex',
      'ru.ozon',
      'com.wildberries',
      'ru.beru',
      'megamarket',
      'samokat',
      'kuper',
      'sbermarket',
      'dodo',
      'pyaterochka',
      'magnit',
      'perekrestok',
      'vkusvill',
      'ru.avito',
      'ru.cian',
      'ru.hh.android',
      'ru.dublgis',
      'dgis',
      'ru.pochta',
      'cdek',
      'ru.nalog',
      'ru.mos',
      'emias',
      'rzd',
      'kinopoisk',
      'okko',
      'ivi',
      'wink',
      'rutube',
      'ru.mirpay',
      'com.sbp',
      'sberpay',
    ];
    const dpiKeywords = [
      'com.google.android.youtube',
      'app.revanced',
      'com.discord',
      'com.aliucord',
      'com.vendetta',
    ];
    for (final app in installed) {
      final pkg = app.packageName.toLowerCase();
      if (preset == 'ru_direct') {
        if (pkg.startsWith('ru.') || ruKeywords.any(pkg.contains)) {
          routes[app.packageName] = 'direct';
          count++;
        }
      } else if (preset == 'yt_discord_desync') {
        if (dpiKeywords.any(pkg.contains)) {
          routes[app.packageName] = 'desync';
          count++;
        }
      }
    }
    await _update(_settings.copyWith(appRoutes: routes));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
    return count;
  }

  /// Настройки MTU, Allow LAN, автозапуска и автообновления подписок.
  Future<void> setMtu(int mtu) => _update(_settings.copyWith(mtu: mtu));
  Future<void> setAllowLan(bool value) async {
    await _update(_settings.copyWith(allowLan: value));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }
  Future<void> setAutoStart(bool value) => _update(_settings.copyWith(autoStart: value));
  Future<void> setAutoUpdateSubs(bool value) =>
      _update(_settings.copyWith(autoUpdateSubs: value));
  Future<void> setProxyOnly(bool value) async {
    await _update(_settings.copyWith(proxyOnly: value));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  Future<void> setSmartFailover(bool value) =>
      _update(_settings.copyWith(smartFailover: value));

  Future<void> setDetourProfile(String profileId) async {
    await _update(_settings.copyWith(detourProfileId: profileId));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  Future<void> setPerNetworkDesync(bool value) async {
    await _update(_settings.copyWith(perNetworkDesync: value));
    if (value) {
      await _checkNetworkDesyncProfile();
    }
  }

  /// Включает или выключает фрагментацию TLS ClientHello на прокси-соединениях (Анти-глушилка LTE).
  Future<void> setProxyTlsFragment(bool value) async {
    await _update(_settings.copyWith(proxyTlsFragment: value));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Экспортирует все настройки приложения в форматированный JSON.
  String exportSettingsJson() =>
      const JsonEncoder.withIndent('  ').convert(_settings.toJson());

  /// Импортирует настройки из резервной копии JSON.
  Future<bool> importSettingsJson(String raw) async {
    try {
      final decoded = jsonDecode(raw.trim());
      if (decoded is! Map) return false;
      final imported = AppSettings.fromJson(Map<String, Object?>.from(decoded));
      await _update(imported);
      return true;
    } catch (e) {
      _lastError = 'Ошибка импорта настроек: $e';
      notifyListeners();
      return false;
    }
  }

  /// Возвращает разобранный список недавних соединений из журнала ядра.
  List<ConnectionEntry> get parsedConnections {
    final result = <ConnectionEntry>[];
    final seen = <String>{};
    for (var i = _logs.length - 1; i >= 0; i--) {
      final line = _logs[i];
      if (!line.contains('CONNECT') && !line.contains('hijack-dns')) continue;
      final entry = ConnectionEntry.tryParse(line);
      if (entry != null && seen.add('${entry.network}|${entry.target}')) {
        result.add(entry);
        if (result.length >= 120) break;
      }
    }
    return result;
  }

  /// Назначает приложению конкретный outbound: proxy / direct / desync / block.
  /// Пустая строка убирает точечное правило — приложение наследует общий режим.
  Future<void> setAppRoute(String packageName, String outbound) async {
    final routes = Map<String, String>.from(_settings.appRoutes);
    if (outbound.isEmpty) {
      routes.remove(packageName);
    } else {
      routes[packageName] = outbound;
    }
    await _update(_settings.copyWith(appRoutes: routes));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Проверяет доступность и задержку сервера профиля с учётом TLS/Reality-рукопожатия.
  /// Возвращает мс или -1 при ошибке/блокировке ТСПУ.
  Future<int> pingProfile(String id) async {
    final profile = _settings.profiles.where((p) => p.id == id).firstOrNull;
    if (profile == null || profile.server.isEmpty) return -1;
    _pingingIds.add(id);
    notifyListeners();
    final sw = Stopwatch()..start();
    var result = -1;
    try {
      // Если профиль использует цепочку прокси (detour), проверяем первый входной узел цепочки
      var targetHost = profile.server;
      var targetPort = profile.port;
      final chain = profile.extra['chain_outbounds'];
      if (chain is List && chain.isNotEmpty && chain.last is Map) {
        final entryHop = chain.last as Map;
        final h = (entryHop['server'] ?? '').toString();
        final p = (entryHop['server_port'] as num?)?.toInt() ?? 0;
        if (h.isNotEmpty && p > 0) {
          targetHost = h;
          targetPort = p;
        }
      }

      final socket = await Socket.connect(
        targetHost,
        targetPort,
        timeout: const Duration(milliseconds: 2800),
      );
      final tcpRtt = sw.elapsedMilliseconds;

      // Для TCP+TLS/Reality узлов без транзитного SOCKS проверяем реальный TLS ServerHello,
      // чтобы отсеивать заблокированные ТСПУ IP, где TCP SYN проходит, но TLS глушится (blackhole).
      final isDirectTlsTcp = (chain is! List || chain.isEmpty) &&
          profile.hasTls &&
          !const {'hysteria2', 'hysteria', 'tuic', 'wireguard', 'masque'}.contains(profile.type);
      if (isDirectTlsTcp) {
        try {
          final sni = profile.sni.isNotEmpty ? profile.sni : targetHost;
          final secure = await SecureSocket.secure(
            socket,
            host: sni,
            onBadCertificate: (_) => true,
          ).timeout(const Duration(milliseconds: 2200));
          sw.stop();
          await secure.close();
          result = sw.elapsedMilliseconds;
        } on HandshakeException {
          // Для REALITY без shortId сервер отвечает подменённым сертификатом или TLS alert —
          // это доказывает, что пакет дошёл до сервера и ТСПУ не дропнул ClientHello!
          sw.stop();
          result = sw.elapsedMilliseconds;
        } on TlsException {
          sw.stop();
          result = sw.elapsedMilliseconds;
        } catch (_) {
          // Таймаут или сброс на ClientHello — узел заблокирован ТСПУ
          result = -1;
        } finally {
          try {
            socket.destroy();
          } catch (_) {}
        }
      } else {
        sw.stop();
        await socket.close();
        result = tcpRtt;
      }
    } catch (_) {
      result = -1;
    } finally {
      _pings[id] = result;
      _pingingIds.remove(id);
      notifyListeners();
    }
    return result;
  }

  /// Пингует все серверы (или серверы конкретной подписки) параллельно батчами
  /// и включает сортировку по пингу.
  Future<void> pingAllProfiles({String? subscriptionId}) async {
    if (_pingingAll) return;
    final targets = subscriptionId == null
        ? _settings.profiles
        : _settings.profiles
            .where((p) => p.subscriptionId == subscriptionId)
            .toList(growable: false);
    if (targets.isEmpty) return;

    _pingingAll = true;
    _sortByPing = true;
    notifyListeners();

    try {
      const batchSize = 8;
      for (var i = 0; i < targets.length; i += batchSize) {
        final end = (i + batchSize < targets.length) ? i + batchSize : targets.length;
        final batch = targets.sublist(i, end);
        await Future.wait(batch.map((p) => pingProfile(p.id)));
      }
      // Если текущий выбранный сервер недоступен или не выбран — автоматически выбираем самый быстрый рабочий
      final sorted = sortProfiles(targets);
      final best = sorted.firstOrNull;
      final currentPing = _pings[_settings.selectedProfileId];
      if (best != null &&
          (_pings[best.id] ?? -1) >= 0 &&
          (_settings.selectedProfileId.isEmpty || (currentPing != null && currentPing < 0))) {
        await selectProfile(best.id);
      }
    } finally {
      _pingingAll = false;
      notifyListeners();
    }
  }

  /// Обрабатывает внешние команды из нативного слоя (Intent `--es cmd ...`).
  Future<void> _handleExternalCommand(String cmd) async {
    switch (cmd.trim()) {
      case 'connect':
        if (!_tunnel.status.isActive && !_tunnel.status.isBusy) {
          await toggleTunnel();
        }
      case 'disconnect':
        if (_tunnel.status.isActive && !_tunnel.status.isBusy) {
          await toggleTunnel();
        }
      case 'toggle':
        await toggleTunnel();
      case 'next_server':
        final list = sortProfiles(_settings.profiles);
        if (list.length > 1) {
          final idx = list.indexWhere((p) => p.id == _settings.selectedProfileId);
          final next = list[(idx + 1) % list.length];
          await selectProfile(next.id);
        }
      case 'mode:desync':
        await setRoutingMode(RoutingMode.desync);
      case 'mode:rules':
        await setRoutingMode(RoutingMode.rules);
      case 'mode:global':
        await setRoutingMode(RoutingMode.global);
      case 'ping_all':
        await pingAllProfiles();
      case 'refresh_sub':
        if (_settings.subscriptions.isNotEmpty) {
          await fetchSubscription(_settings.subscriptions.first.id);
        }
    }
  }

  /// Принудительно обновляет подписку: перезапускает ядро с тем же конфигом,
  /// что заставляет ядро перекачать все подписки немедленно.
  Future<void> refreshSubscription(String id) async {
    await fetchSubscription(id);
    if (_tunnel.status.isActive) {
      await toggleTunnel();
      await Future<void>.delayed(const Duration(milliseconds: 800));
      await toggleTunnel();
    }
  }

  /// Версия нативного ядра.
  Future<String> coreVersion() async {
    final v = await bridge.coreVersion();
    _installedCoreVersion = v.replaceFirst(RegExp(r'^v'), '').trim();
    return v;
  }

  static int _compareSemver(String a, String b) {
    final pa = a.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.-]'));
    final pb = b.replaceFirst(RegExp(r'^v'), '').split(RegExp(r'[.-]'));
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final na = i < pa.length ? (int.tryParse(pa[i]) ?? 0) : 0;
      final nb = i < pb.length ? (int.tryParse(pb[i]) ?? 0) : 0;
      if (na != nb) return na.compareTo(nb);
    }
    return 0;
  }

  /// Вспомогательный запрос текста/JSON с автоповтором через туннель и напрямую.
  Future<String?> _fetchTextWithFallback(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final modes = <bool>[
      if (_tunnel.status.isActive) true,
      false,
    ];
    for (final useProxy in modes) {
      final client = HttpClient()
        ..connectionTimeout = timeout
        ..badCertificateCallback = (_, _, _) => true;
      if (useProxy) {
        client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
      }
      try {
        var curr = url;
        for (var hop = 0; hop < 6; hop++) {
          final req = await client.getUrl(Uri.parse(curr)).timeout(timeout);
          req.headers.set('User-Agent', 'TachyonProxy/$appVersion');
          headers.forEach(req.headers.set);
          req.followRedirects = false;
          final resp = await req.close().timeout(timeout);
          if (resp.statusCode >= 300 && resp.statusCode < 400) {
            final loc = resp.headers.value(HttpHeaders.locationHeader);
            await resp.drain<void>();
            if (loc != null && loc.isNotEmpty) {
              curr = Uri.parse(curr).resolve(loc).toString();
              continue;
            }
          }
          if (resp.statusCode == 200) {
            return await resp.transform(utf8.decoder).join().timeout(timeout);
          }
          await resp.drain<void>();
          break;
        }
      } catch (_) {
        // Пробуем следующий режим
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  /// Проверяет наличие новых релизов `tachyon-core` и `tachyon-proxy` на GitHub.
  Future<void> checkUpdates() async {
    if (_checkingUpdates) return;
    _checkingUpdates = true;
    _updateStatusText = 'Проверка релизов на GitHub...';
    notifyListeners();

    try {
      final currCore = await bridge.coreVersion();
      _installedCoreVersion = currCore.replaceFirst(RegExp(r'^v'), '').trim();
      final abi = await bridge.deviceAbi();
      final abiSuffix = switch (abi) {
        'armeabi-v7a' || 'armeabi' => 'armeabi-v7a',
        'x86_64' => 'x86_64',
        _ => 'arm64-v8a',
      };

      // 1. Проверяем последний релиз ядра Dushnilin/tachyon-core
      final coreBody = await _fetchTextWithFallback(
        'https://api.github.com/repos/Dushnilin/tachyon-core/releases/latest',
        headers: const {'Accept': 'application/vnd.github+json'},
      );
      if (coreBody != null) {
        final json = jsonDecode(coreBody);
        if (json is Map && json['tag_name'] != null) {
          _latestCoreVersion = json['tag_name']
              .toString()
              .replaceFirst(RegExp(r'^v'), '')
              .trim();
          final assets = json['assets'];
          if (assets is List) {
            for (final a in assets) {
              if (a is Map) {
                final name = (a['name'] ?? '').toString().toLowerCase();
                final dlUrl = (a['browser_download_url'] ?? '').toString();
                if (dlUrl.isNotEmpty &&
                    name.endsWith('.so') &&
                    name.contains(abiSuffix.toLowerCase())) {
                  _latestCoreSoUrl = dlUrl;
                  break;
                }
              }
            }
          }
        }
      }

      // 2. Проверяем version.json или последний релиз Dushnilin/tachyon-proxy
      final verBody = await _fetchTextWithFallback(
            'https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/version.json',
          ) ??
          await _fetchTextWithFallback(
            'https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/version.json',
          );
      if (verBody != null) {
        final json = jsonDecode(verBody);
        if (json is Map) {
          final av = (json['app_version'] ?? '')
              .toString()
              .replaceFirst(RegExp(r'^v'), '')
              .trim();
          final cv = (json['core_version'] ?? '')
              .toString()
              .replaceFirst(RegExp(r'^v'), '')
              .trim();
          if (av.isNotEmpty) _latestAppVersion = av;
          if (cv.isNotEmpty &&
              (_latestCoreVersion.isEmpty ||
                  _compareSemver(cv, _latestCoreVersion) > 0)) {
            _latestCoreVersion = cv;
          }
        }
      } else {
        final appBody = await _fetchTextWithFallback(
          'https://api.github.com/repos/Dushnilin/tachyon-proxy/releases/latest',
          headers: const {'Accept': 'application/vnd.github+json'},
        );
        if (appBody != null) {
          final json = jsonDecode(appBody);
          if (json is Map && json['tag_name'] != null) {
            final tag = json['tag_name']
                .toString()
                .replaceFirst(RegExp(r'^v'), '')
                .trim();
            if (tag != 'latest' && tag.isNotEmpty) {
              _latestAppVersion = tag;
            }
          }
        }
      }

      if (_latestAppVersion.isEmpty) _latestAppVersion = appVersion;
      if (_latestCoreVersion.isEmpty) _latestCoreVersion = _installedCoreVersion;

      if (hasCoreUpdate || hasAppUpdate) {
        _updateStatusText =
            'Доступно обновление: Приложение v$_latestAppVersion · Ядро v$_latestCoreVersion';
      } else {
        _updateStatusText =
            'Установлены актуальные версии (Приложение v$appVersion · Ядро v$_installedCoreVersion)';
      }
    } catch (e) {
      _updateStatusText = 'Не удалось проверить обновления: $e';
    } finally {
      _checkingUpdates = false;
      notifyListeners();
    }
  }

  /// Вспомогательный загрузчик файлов с поддержкой GitHub-редиректов,
  /// автоматическим переключением туннель/напрямую и прогресс-баром.
  Future<bool> _downloadUpdateFile(
    String url,
    File targetFile,
    String label,
  ) async {
    _updateStatusText = '$label...';
    _updateProgress = 0.05;
    notifyListeners();

    final proxyModes = <bool>[
      if (_tunnel.status.isActive) true,
      false,
    ];

    for (final useProxy in proxyModes) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..badCertificateCallback = (_, _, _) => true;
      if (useProxy) {
        client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
      }

      IOSink? sink;
      try {
        var currUrl = url;
        HttpClientResponse? resp;
        for (var i = 0; i < 8; i++) {
          final req = await client
              .getUrl(Uri.parse(currUrl))
              .timeout(const Duration(seconds: 15));
          req.headers.set('User-Agent', 'TachyonProxy/$appVersion');
          req.followRedirects = false;
          resp = await req.close().timeout(const Duration(seconds: 20));
          if (resp.statusCode >= 300 && resp.statusCode < 400) {
            final loc = resp.headers.value(HttpHeaders.locationHeader);
            await resp.drain<void>();
            if (loc != null && loc.isNotEmpty) {
              currUrl = Uri.parse(currUrl).resolve(loc).toString();
              continue;
            }
          }
          break;
        }
        if (resp == null || resp.statusCode != 200) {
          await resp?.drain<void>();
          continue;
        }
        final total = resp.contentLength;
        var received = 0;
        final partFile = File('${targetFile.path}.part');
        sink = partFile.openWrite();
        await for (final chunk in resp.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          received += chunk.length;
          final mb = (received / (1024 * 1024)).toStringAsFixed(1);
          if (total > 0) {
            _updateProgress = (received / total).clamp(0.05, 0.98);
            final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
            final pct = (_updateProgress * 100).round();
            _updateStatusText = '$label: $mb / $totalMb МБ ($pct%)';
          } else {
            _updateProgress =
                (received / (25 * 1024 * 1024)).clamp(0.08, 0.95);
            _updateStatusText = '$label: скачано $mb МБ...';
          }
          notifyListeners();
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (partFile.existsSync() && partFile.lengthSync() > 500000) {
          if (targetFile.existsSync()) {
            targetFile.deleteSync();
          }
          partFile.renameSync(targetFile.path);
          return true;
        }
      } catch (_) {
        // Пробуем следующий режим/зеркало
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
        client.close(force: true);
      }
    }
    return false;
  }

  /// Отдельное обновление ТОЛЬКО нативного ядра (`libtachyon.so`) через внутренний загрузчик.
  Future<void> updateEngineOnly() async {
    if (isAnyUpdateRunning) return;
    _updatingEngine = true;
    _updateProgress = 0.02;
    _updateStatusText = 'Подготовка загрузчика ядра tachyon-core...';
    notifyListeners();

    try {
      final abi = await bridge.deviceAbi();
      final fDir = await bridge.filesDir();
      if (fDir.isEmpty) {
        _updateStatusText = 'Ошибка: каталог приложения недоступен';
        return;
      }
      final updateDir = Directory('$fDir/update');
      if (!updateDir.existsSync()) {
        updateDir.createSync(recursive: true);
      }

      final abiSuffix = switch (abi) {
        'armeabi-v7a' || 'armeabi' => 'armeabi-v7a',
        'x86_64' => 'x86_64',
        _ => 'arm64-v8a',
      };

      final soFile = File('${updateDir.path}/libtachyon.so');
      final candidateUrls = <String>[
        if (_latestCoreSoUrl.isNotEmpty) _latestCoreSoUrl,
        'https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/libtachyon-$abiSuffix.so',
        'https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/libtachyon-$abiSuffix.so',
        'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/libtachyon-$abiSuffix.so',
        'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/libtachyon-$abiSuffix.so',
      ];

      var downloaded = false;
      for (final soUrl in candidateUrls) {
        downloaded = await _downloadUpdateFile(
          soUrl,
          soFile,
          'Скачивание ядра libtachyon ($abiSuffix)',
        );
        if (downloaded) break;
      }

      if (!downloaded) {
        _updateStatusText =
            'Не удалось скачать бинарник ядра libtachyon-$abiSuffix.so с GitHub Releases';
        return;
      }

      _updateStatusText = 'Горячая установка нового ядра в загрузчик...';
      _updateProgress = 0.99;
      notifyListeners();
      if (_tunnel.status.isActive) {
        await bridge.stop();
      }
      final res = await bridge.installEngineSo(soFile.path);
      if (res == 'ok') {
        if (_latestCoreVersion.isNotEmpty) {
          _installedCoreVersion = _latestCoreVersion;
        }
        _updateProgress = 1.0;
        _updateStatusText =
            'Ядро tachyon-core v$_installedCoreVersion успешно обновлено — перезапуск...';
      } else if (res == 'requires_apk') {
        _updatingEngine = false;
        _updateStatusText =
            'Загрузчик .so требует обновления базового пакета — скачиваем и запускаем установку APK...';
        notifyListeners();
        await updateAppOnly();
        return;
      } else {
        _updateStatusText = 'Ошибка установки ядра: $res';
      }
    } catch (e) {
      _updateStatusText = 'Ошибка обновления ядра: $e';
    } finally {
      _updatingEngine = false;
      notifyListeners();
    }
  }

  /// Отдельное обновление ТОЛЬКО приложения (`APK`) через системный установщик Android.
  Future<void> updateAppOnly() async {
    if (isAnyUpdateRunning) return;
    _updatingApp = true;
    _updateProgress = 0.02;
    _updateStatusText = 'Подготовка загрузчика APK...';
    notifyListeners();

    try {
      final abi = await bridge.deviceAbi();
      final fDir = await bridge.filesDir();
      if (fDir.isEmpty) {
        _updateStatusText = 'Ошибка: каталог приложения недоступен';
        return;
      }
      final updateDir = Directory('$fDir/update');
      if (!updateDir.existsSync()) {
        updateDir.createSync(recursive: true);
      }

      final abiSuffix = switch (abi) {
        'armeabi-v7a' || 'armeabi' => 'armeabi-v7a',
        'x86_64' => 'x86_64',
        _ => 'arm64-v8a',
      };

      const apkName = 'tachyon-update.apk';
      final apkFile = File('${updateDir.path}/$apkName');
      final candidateApkUrls = <String>[
        'https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/tachyon-proxy-$abiSuffix.apk',
        'https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/tachyon-proxy-$abiSuffix.apk',
        'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/tachyon-proxy-$abiSuffix.apk',
        'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/tachyon-proxy-$abiSuffix.apk',
      ];

      var okApk = false;
      for (final apkUrl in candidateApkUrls) {
        okApk = await _downloadUpdateFile(
          apkUrl,
          apkFile,
          'Скачивание APK приложения ($abiSuffix)',
        );
        if (okApk) break;
      }
      if (!okApk) {
        _updateStatusText =
            'Не удалось скачать APK приложения с GitHub Releases';
        return;
      }

      _updateProgress = 1.0;
      _updateStatusText = 'Запуск системного установщика Android...';
      notifyListeners();
      final res = await bridge.installApk(apkName);
      if (res != 'ok') {
        _updateStatusText = 'Ошибка установки APK: $res';
      } else {
        _updateStatusText =
            'Пакет скачан — подтвердите установку обновления в окне Android';
      }
    } catch (e) {
      _updateStatusText = 'Ошибка обновления APK: $e';
    } finally {
      _updatingApp = false;
      notifyListeners();
    }
  }

  /// Отдельное обновление всех списков маршрутизации (`tachyon-lists` `.trs`).
  Future<void> updateListsOnly() async {
    if (isAnyUpdateRunning) return;
    _updatingLists = true;
    _updateProgress = 0.05;
    _updateStatusText = 'Обновление каталога tachyon-lists...';
    notifyListeners();

    try {
      await refreshLists();
      final idsToUpdate = <String>{};
      for (final entry in _settings.serviceRoutes.entries) {
        if (entry.value.isNotEmpty && entry.value != 'off') {
          final svc = BuiltInService.catalog
              .where((s) => s.id == entry.key)
              .firstOrNull;
          if (svc != null && svc.trsId.isNotEmpty) {
            idsToUpdate.add(svc.trsId);
          }
        }
      }
      for (final rs in _settings.ruleSets) {
        if (rs.enabled || rs.sizeBytes > 0) {
          idsToUpdate.add(rs.id);
        }
      }
      if (idsToUpdate.isEmpty) {
        for (final svc in BuiltInService.catalog) {
          idsToUpdate.add(svc.trsId);
        }
      }

      final list = idsToUpdate.toList();
      for (var i = 0; i < list.length; i++) {
        final id = list[i];
        _updateProgress = ((i + 1) / list.length).clamp(0.1, 0.99);
        _updateStatusText =
            'Скачивание списка $id.trs (${i + 1}/${list.length})...';
        notifyListeners();
        await downloadList(id);
      }

      if (_tunnel.status.isActive) {
        await _restartActiveTunnel();
      }
      _updateProgress = 1.0;
      _updateStatusText =
          'Списки tachyon-lists успешно обновлены (${list.length} шт.)';
    } catch (e) {
      _updateStatusText = 'Ошибка обновления списков: $e';
    } finally {
      _updatingLists = false;
      notifyListeners();
    }
  }

  /// Совместимый метод установки обновления.
  Future<void> installUpdate({bool preferEngineOnly = false}) =>
      preferEngineOnly ? updateEngineOnly() : updateAppOnly();

  /// Список установленных приложений.
  Future<List<InstalledApp>> installedApps() => bridge.installedApps();

  /// Приватный каталог приложения: туда кладутся списки правил.
  Future<String> filesDirectory() => bridge.filesDir();

  @override
  void dispose() {
    stopTrafficPolling();
    lists.close();
    super.dispose();
  }
}

/// Запись об активном/недавнем соединении из журнала ядра.
class ConnectionEntry {
  const ConnectionEntry({
    required this.timestamp,
    required this.network,
    required this.target,
    required this.host,
    required this.port,
    required this.route,
  });

  final String timestamp;
  final String network;
  final String target;
  final String host;
  final int port;
  final String route;

  static final RegExp _connectRe = RegExp(
    r'(\d{2}:\d{2}:\d{2}).*?\b(tcp|udp)\b\s+([^\s]+\s*->\s*)?([a-zA-Z0-9._-]+|\[\:?[0-9a-fA-F:]+\]):(\d+)',
    caseSensitive: false,
  );

  static ConnectionEntry? tryParse(String line) {
    final m = _connectRe.firstMatch(line);
    if (m == null) return null;
    final time = m.group(1) ?? '';
    final net = (m.group(2) ?? 'tcp').toUpperCase();
    final host = m.group(4) ?? '';
    final port = int.tryParse(m.group(5) ?? '0') ?? 0;
    var route = 'proxy';
    final lower = line.toLowerCase();
    if (lower.contains('hijack-dns')) {
      route = 'dns';
    } else if (lower.contains('direct')) {
      route = 'direct';
    } else if (lower.contains('desync')) {
      route = 'desync';
    } else if (lower.contains('block')) {
      route = 'block';
    }
    return ConnectionEntry(
      timestamp: time,
      network: net,
      target: '$host:$port',
      host: host,
      port: port,
      route: route,
    );
  }
}

/// Результат тестирования одной связки `preset × fooling` в снайпере DPI.
class DesyncScanEntry {
  const DesyncScanEntry({
    required this.preset,
    required this.fooling,
    required this.label,
    required this.youtubeMs,
    required this.discordMs,
    required this.avgMs,
  });

  final String preset;
  final String fooling;
  final String label;
  final int youtubeMs;
  final int discordMs;
  final int avgMs;

  bool get ok => avgMs >= 0;
}
