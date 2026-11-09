import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'models/app_rules.dart';
import 'models/runtime_config.dart';
import 'models/tunnel_state.dart';
import 'services/core_bridge.dart';
import 'services/dns_benchmark.dart';
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
  final Map<String, BalancerNodeTelemetry> _nodeTelemetry = {};
  Profile? _activeBalancerWinner;
  final Set<String> _pingingIds = {};
  bool _pingingAll = false;
  bool _sortByPing = false;
  Timer? _pingCoalesceTimer;

  /// Гранулярные нотификаторы для точечной перерисовки без глобального rebuild:
  /// - [themeModeNotifier] — перестраивает `MaterialApp` только при смене темы;
  /// - [trafficRevision] — обновляет только виджеты скорости/трафика/узла выхода;
  /// - [pingRevision] и [_serverRevisions] — обновляют отдельные строки серверов.
  final ValueNotifier<String> themeModeNotifier = ValueNotifier<String>('dark');
  final ValueNotifier<int> trafficRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> pingRevision = ValueNotifier<int>(0);
  final Map<String, ValueNotifier<int>> _serverRevisions = {};

  ValueListenable<int> serverRevisionOf(String id) =>
      _serverRevisions.putIfAbsent(id, () => ValueNotifier<int>(0));

  void _bumpServerRevision(String id) {
    final notifier = _serverRevisions[id];
    if (notifier != null) {
      notifier.value++;
    }
    pingRevision.value++;
  }

  void _schedulePingCoalescedNotify() {
    if (_pingCoalesceTimer?.isActive ?? false) return;
    _pingCoalesceTimer = Timer(const Duration(milliseconds: 160), () {
      notifyListeners();
    });
  }

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
  String _exitFlag = '';
  String _exitIsp = '';
  bool _refreshingExitGeo = false;

  /// Автоподбор оптимального MTU (MtuAutoScan).
  bool _scanningMtu = false;
  String _mtuScanStatus = '';

  /// Автоподбор рецепта DPI (Desync).
  bool _testingDesync = false;
  String _desyncTestStatus = '';
  List<DesyncScanEntry> _desyncScanResults = const [];

  /// Счётчики для фонового Smart Failover и автосмены профиля DPI по типу сети.
  int _pollTickCount = 0;
  int _consecutiveWatchdogFails = 0;
  String _lastNetType = '';
  String _lastTunnelNetType = '';
  bool _pollingTrafficInFlight = false;
  int _trafficPollGeneration = 0;

  /// Состояние подключённого Wi-Fi и режима «Домашний интернет».
  String _currentWifiSsid = '';
  bool _isWifiConnected = false;
  bool _hasWifiPermission = false;
  bool _wifiLocationEnabled = true;
  List<String> _nearbyWifiSsids = const [];

  /// Версия приложения и состояние встроенного загрузчика обновлений (отдельно ядро, APK, списки).
  static const String appVersion = '0.0.17';
  static const String minRequiredCoreVersion = '0.3.9';
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
  String get currentWifiSsid => _currentWifiSsid;
  bool get isWifiConnected => _isWifiConnected;
  bool get hasWifiPermission => _hasWifiPermission;
  bool get wifiLocationEnabled => _wifiLocationEnabled;
  List<String> get nearbyWifiSsids => _nearbyWifiSsids;
  bool get isCurrentWifiTrusted =>
      _currentWifiSsid.isNotEmpty &&
      _settings.trustedWifiSsids.any(
        (s) => s.trim().toLowerCase() == _currentWifiSsid.trim().toLowerCase(),
      );
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
      _compareSemver(_latestCoreVersion, minRequiredCoreVersion) >= 0 &&
      _compareSemver(_latestCoreVersion, _installedCoreVersion) > 0;
  bool get hasAppUpdate =>
      _latestAppVersion.isNotEmpty &&
      _compareSemver(_latestAppVersion, appVersion) > 0;

  int? pingOf(String id) => _pings[id];
  BalancerNodeTelemetry? balancerTelemetryOf(String id) => _nodeTelemetry[id];
  Profile? get activeBalancerWinner => _activeBalancerWinner;
  BalancerRuntimeStatus? get activeBalancerStatus => _traffic?.balancer;
  bool isPinging(String id) => _pingingIds.contains(id);

  bool isSubCollapsed(String subId) => _settings.collapsedSubs.contains(subId);

  Future<void> toggleSubCollapsed(String subId) async {
    final next = [..._settings.collapsedSubs];
    if (next.contains(subId)) {
      next.remove(subId);
    } else {
      next.add(subId);
    }
    _settings = _settings.copyWith(collapsedSubs: next);
    notifyListeners();
    store.saveDebounced(_settings);
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
    final pool = _settings.visibleProfiles;
    if (pool.isNotEmpty) return pool.first;
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
    final hasSub = _settings.visibleSubscriptions.isNotEmpty;
    final profile = selectedProfile;
    if (profile == null && !hasSub) return false;
    if (profile != null && profile.server.isEmpty && !hasSub) return false;
    return true;
  }

  /// Загружает настройки и подписывается на события ядра.
  Future<void> bootstrap() async {
    _settings = await store.load();
    themeModeNotifier.value = _settings.themeMode;

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
      final deduped = _dedupProfiles(
        _settings.profiles,
        subscriptions: _settings.subscriptions,
      );
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

    // Очистка устаревших кэш-файлов и синхронизация кэша подписок для ядра
    if (filesDirPath.isNotEmpty) {
      for (final freeId in const ['free-warp', 'free-shard']) {
        final f = File('$filesDirPath/subs/$freeId.txt');
        if (f.existsSync()) {
          try {
            f.deleteSync();
          } catch (_) {}
        }
      }
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
      final launchCmd = await bridge.consumeLaunchCommand();
      if (launchCmd != null && launchCmd.trim().isNotEmpty) {
        await _handleExternalCommand(launchCmd);
      }
      final launchLink = await bridge.consumeLaunchLink();
      if (launchLink != null && launchLink.trim().isNotEmpty) {
        await _handleIncomingDeepLink(launchLink);
      }
    }());

    // Фоновое обновление: подписки без серверов, список устарел или резолверы ещё не проверены.
    unawaited(_refreshStale());
    unawaited(refreshWifiInfo());
    unawaited(_checkNetworkDesyncProfile(forceCheck: true));
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

  /// Проверяет, разрешён ли профиль текущими фильтрами исключения стран и протоколов.
  bool isProfileAllowedByFilters(Profile p) {
    final sub = p.subscriptionId.isEmpty
        ? null
        : _settings.subscriptions.where((s) => s.id == p.subscriptionId).firstOrNull;
    final exCountries = <String>[
      ..._settings.balancer.excludedCountries,
      if (sub != null) ...sub.excludedCountries,
    ];
    final exProtocols = <String>[
      ..._settings.balancer.excludedProtocols,
      if (sub != null) ...sub.excludedProtocols,
    ];
    if (exCountries.isEmpty && exProtocols.isEmpty) return true;
    return BalancerSettings.matchesFilter(
      p,
      excludedProtocols: exProtocols,
      excludedCountries: exCountries,
    );
  }

  /// Возвращает интервал автообновления подписки в миллисекундах.
  int _subAutoUpdateIntervalMs(SubscriptionEntry sub) {
    final minutes = sub.autoUpdateHours > 0
        ? sub.autoUpdateHours * 60
        : _settings.autoUpdateIntervalMinutes;
    return minutes.clamp(15, 10080) * 60 * 1000;
  }

  /// Фоновая проверка расписания автообновления подписок при работающем приложении/туннеле.
  Future<void> _checkScheduledSubAutoUpdate() async {
    if (_loadingSubscription) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final sub in _settings.visibleSubscriptions) {
      if (!sub.enabled || AppSettings.isFreeSubId(sub.id) || sub.isFptnToken) continue;
      final autoEnabled = _settings.autoUpdateSubs || sub.autoUpdateHours > 0;
      if (!autoEnabled) continue;
      final intervalMs = _subAutoUpdateIntervalMs(sub);
      if (sub.updatedAt > 0 && (nowMs - sub.updatedAt) >= intervalMs) {
        await fetchSubscription(sub.id);
      }
    }
  }

  /// Обновляет устаревшие списки и, если нужно, резолверы.
  Future<void> _refreshStale() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    for (final sub in _settings.visibleSubscriptions) {
      if (sub.enabled && !AppSettings.isFreeSubId(sub.id)) {
        final hasServers = _settings.profiles.any((p) => p.subscriptionId == sub.id);
        final autoEnabled = _settings.autoUpdateSubs || sub.autoUpdateHours > 0;
        final intervalMs = _subAutoUpdateIntervalMs(sub);
        final isOld = autoEnabled &&
            !sub.isFptnToken &&
            (sub.updatedAt == 0 || (nowMs - sub.updatedAt) >= intervalMs);
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
        if (service.id == 'ru') {
          requiredIds.add('ru_only_inside');
        }
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

  /// Удаляет полные дубликаты серверов, гарантирует уникальность `id` каждого сервера
  /// и восстанавливает привязку серверов FPTN к подписке FPTN, если ранее они попали в чужую группу.
  List<Profile> _dedupProfiles(
    List<Profile> items, {
    String defaultSubId = '',
    List<SubscriptionEntry> subscriptions = const [],
  }) {
    final fptnSubIds = {
      for (final s in subscriptions)
        if (s.isFptnToken && s.id.isNotEmpty) s.id,
    };
    final primaryFptnSubId = fptnSubIds.firstOrNull ?? '';

    String resolveSubId(Profile p) {
      if (p.type == 'fptn' && primaryFptnSubId.isNotEmpty) {
        if (p.subscriptionId.isEmpty || !fptnSubIds.contains(p.subscriptionId)) {
          return primaryFptnSubId;
        }
      }
      if (p.subscriptionId.isEmpty && defaultSubId.isNotEmpty) {
        return defaultSubId;
      }
      return p.subscriptionId;
    }

    // Сначала обрабатываем профили с уже корректной привязкой к группе,
    // чтобы при дедупликации приоритет оставался за актуальными записями подписки.
    final ordered = [
      ...items.where((p) => resolveSubId(p) == p.subscriptionId),
      ...items.where((p) => resolveSubId(p) != p.subscriptionId),
    ];

    final seenKeys = <String>{};
    final usedIds = <String>{};
    final result = <Profile>[];
    for (final p in ordered) {
      final subId = resolveSubId(p);
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

  /// Сохраняет настройки на диск, мгновенно уведомляя UI до завершения записи.
  Future<void> _persist() async {
    if (themeModeNotifier.value != _settings.themeMode) {
      themeModeNotifier.value = _settings.themeMode;
    }
    notifyListeners();
    await store.save(_settings);
  }

  /// Генерирует новый случайный 32-символьный hex HWID.
  static String generateRandomHwid() {
    final rng = Random.secure();
    return List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Возвращает глобальный HWID устройства (генерируя и сохраняя его при первом обращении).
  String get effectiveHwid {
    var hwid = _settings.hwid.trim();
    if (hwid.isEmpty) {
      hwid = generateRandomHwid();
      _settings = _settings.copyWith(hwid: hwid);
      unawaited(_persist());
    }
    return hwid;
  }

  /// Задаёт общий HWID устройства.
  Future<void> setGlobalHwid(String hwid) async {
    final clean = hwid.trim();
    await _update(_settings.copyWith(hwid: clean.isEmpty ? generateRandomHwid() : clean));
  }

  /// Задаёт сетевую область действия для конкретного сервера (`'all'`, `'wifi'`, `'cellular'`).
  Future<void> setProfileNetworkScope(String profileId, String scope) async {
    final cleanScope = (scope == 'wifi' || scope == 'cellular') ? scope : 'all';
    final nextProfiles = [
      for (final p in _settings.profiles)
        if (p.id == profileId)
          Profile(
            id: p.id,
            name: p.name,
            type: p.type,
            server: p.server,
            port: p.port,
            uuid: p.uuid,
            password: p.password,
            method: p.method,
            transport: p.transport,
            sni: p.sni,
            alpn: p.alpn,
            allowInsecure: p.allowInsecure,
            flow: p.flow,
            publicKey: p.publicKey,
            shortId: p.shortId,
            subscriptionId: p.subscriptionId,
            extra: {
              ...p.extra,
              if (cleanScope == 'all')
                ...(<String, dynamic>{})
              else
                'network_scope': cleanScope,
            }..removeWhere((k, _) => cleanScope == 'all' && k == 'network_scope'),
          )
        else
          p,
    ];
    await _update(_settings.copyWith(profiles: nextProfiles));
    await _checkNetworkDesyncProfile(forceCheck: true);
    if (_tunnel.status.isActive &&
        _settings.routingMode != RoutingMode.desync &&
        _settings.selectedProfileId.startsWith('auto:')) {
      await _restartActiveTunnel();
    }
  }

  /// Настраивает автоматический выбор профиля / списка серверов отдельно для Wi-Fi и мобильной сети.
  Future<void> setNetworkProfiles({
    String? wifiProfileId,
    String? cellularProfileId,
  }) async {
    await _update(
      _settings.copyWith(
        wifiProfileId: wifiProfileId ?? _settings.wifiProfileId,
        cellularProfileId: cellularProfileId ?? _settings.cellularProfileId,
      ),
    );
    await _checkNetworkDesyncProfile(forceCheck: true);
  }

  bool get _hasNetworkScopedNodes =>
      _settings.subscriptions.any((s) => s.networkScope != 'all') ||
      _settings.profiles.any((p) => p.networkScope != 'all');
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

  /// Перезапускает активный туннель с новой конфигурацией без разрыва VPN-сессии.
  Future<void> _restartActiveTunnel() async {
    for (var i = 0; i < 20 && _tunnel.status.isBusy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!_tunnel.status.isActive) return;

    final config = buildConfig();
    if (config == null) return;

    _activeBalancerWinner = null;
    _nodeTelemetry.clear();
    _lastTunnelNetType = _lastNetType;

    final currentServer = _settings.routingMode == RoutingMode.desync
        ? 'Режим Десинхронизации (Desync)'
        : (selectedProfile?.name ?? (config.profile.name.isNotEmpty ? config.profile.name : ''));

    final error = await bridge.start(
      config.encode(),
      allowedApps: _allowedApps,
      disallowedApps: _disallowedApps,
      serverName: currentServer,
      mtu: _settings.mtu,
      proxyOnly: _settings.proxyOnly,
    );
    if (error != null) {
      _lastError = error;
      notifyListeners();
      return;
    }

    _tunnel = _tunnel.copyWith(
      serverName: currentServer.isNotEmpty ? currentServer : config.profile.name,
    );
    notifyListeners();
    await _waitForLocalProxyReady();
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
  Future<int> importProfiles(String content, {String? fileName}) async {
    var payload = content.trim();
    if (payload.isEmpty) return 0;

    final cleanFileName = fileName
        ?.trim()
        .replaceAll(RegExp(r'\.(conf|fptn|json|txt|yaml|yml)$', caseSensitive: false), '')
        .trim();

    final parser = LinkParser();

    // 1. Токен или конфигурация FPTN (fptn:, fptnb:, JSON с service_name + servers) ->
    //    группируем в отдельную подписку FPTN с собственным балансировщиком и заменой старых серверов.
    if (parser.isFptnPayload(payload)) {
      return importFptnToken(
        payload,
        customName: (cleanFileName != null && cleanFileName.isNotEmpty) ? cleanFileName : null,
      );
    }

    // 2. Конфигурационный файл WireGuard / AmneziaWG (.conf 1.5 / 2.0 / 3.0 / 3.1)
    if (parser.looksLikeWireGuardConf(payload)) {
      final wgProfiles = parser.parseWireGuardConfAll(
        payload,
        nameOverride: (cleanFileName != null && cleanFileName.isNotEmpty) ? cleanFileName : null,
      );
      if (wgProfiles.isNotEmpty) {
        _lastError = '';
        final byId = {for (final p in _settings.profiles) p.id: p};
        for (final p in wgProfiles) {
          byId[p.id] = p;
        }
        final merged = byId.values.toList();
        await _update(
          _settings.copyWith(
            profiles: merged,
            selectedProfileId: wgProfiles.length == 1
                ? wgProfiles.first.id
                : (_settings.selectedProfileId.isEmpty
                    ? wgProfiles.first.id
                    : _settings.selectedProfileId),
          ),
        );
        return wgProfiles.length;
      }
    }

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
    if (cleanFileName != null && cleanFileName.isNotEmpty && profiles.length == 1) {
      final single = profiles.first;
      if (single.name.isEmpty || single.name == single.server || single.name == 'WireGuard') {
        profiles = [
          Profile.fromJson({
            ...single.toJson(),
            'name': cleanFileName,
          }),
        ];
      }
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

  /// Ключ идентификации сервера внутри FPTN-токена (`host:port`).
  static String fptnServerKey(Profile p) => '${p.server}:${p.port}';

  /// Разбирает токен FPTN (`fptn:`, `fptnb:`, JSON) и возвращает полный список серверов из него.
  Future<List<Profile>> parseFptnCandidates(
    String rawToken, {
    String subscriptionId = '',
  }) async {
    final trimmed = rawToken.trim();
    if (trimmed.isEmpty) return const [];
    final parser = LinkParser();
    List<Profile> candidates = const [];
    final nativeParsed = await bridge.parseSubscription(trimmed);
    if (nativeParsed != null &&
        nativeParsed['ok'] == true &&
        nativeParsed['nodes'] is List) {
      candidates = parser.parseEngineNodes(
        nativeParsed['nodes'] as List,
        (nativeParsed['primary_tags'] as List?) ?? const [],
        subscriptionId: subscriptionId,
      );
    }
    if (candidates.isEmpty) {
      candidates = parser.parseSubscription(trimmed, subscriptionId: subscriptionId);
    }
    return candidates.where((p) => p.type == 'fptn').toList(growable: false);
  }

  /// Импортирует или обновляет токен FPTN как группу подписки с собственным балансировщиком
  /// (`auto:<subId>`), возможностью выбора конкретных серверов и автоматической очисткой старых серверов.
  Future<int> importFptnToken(
    String rawToken, {
    String? customName,
    Set<String>? selectedServerKeys,
    String? targetSubId,
    String? networkScope,
    bool selectBalancer = true,
  }) async {
    final cleanToken = rawToken.trim();
    if (cleanToken.isEmpty) return 0;

    final parser = LinkParser();
    final extractedName = parser.extractFptnServiceName(cleanToken);
    final desiredName = (customName != null && customName.trim().isNotEmpty)
        ? customName.trim()
        : extractedName;

    // Ищем существующую группу FPTN для обновления (чтобы старые серверы заменялись автоматически)
    SubscriptionEntry? existing;
    if (targetSubId != null && targetSubId.isNotEmpty) {
      existing = _settings.subscriptions.where((s) => s.id == targetSubId).firstOrNull;
    }
    existing ??= _settings.subscriptions
        .where(
          (s) =>
              s.isFptnToken &&
              (s.name.toLowerCase() == desiredName.toLowerCase() || s.url.trim() == cleanToken),
        )
        .firstOrNull;
    existing ??= _settings.subscriptions.where((s) => s.isFptnToken).firstOrNull;

    final subId =
        existing?.id ?? 's${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';

    final allCandidates = await parseFptnCandidates(cleanToken, subscriptionId: subId);
    if (allCandidates.isEmpty) {
      _lastError = 'Не удалось разобрать токен FPTN или в нём нет серверов';
      notifyListeners();
      return 0;
    }

    final effectiveFilter = selectedServerKeys ??
        (existing != null && existing.selectedServerKeys.isNotEmpty
            ? existing.selectedServerKeys.toSet()
            : null);

    var filtered = effectiveFilter == null || effectiveFilter.isEmpty
        ? allCandidates
        : allCandidates
            .where(
              (p) =>
                  effectiveFilter.contains(fptnServerKey(p)) ||
                  effectiveFilter.contains(p.name),
            )
            .toList(growable: false);

    // Если после обновления токена ни один из прежних выбранных серверов не совпал, берём все серверы
    if (filtered.isEmpty) {
      filtered = allCandidates;
    }

    final otherFptnSubIds = {
      for (final s in _settings.subscriptions)
        if (s.isFptnToken && s.id != subId) s.id,
    };

    bool belongsToThisFptnGroup(Profile p) =>
        p.subscriptionId == subId ||
        (p.type == 'fptn' && !otherFptnSubIds.contains(p.subscriptionId));

    // Сохраняем пользовательские привязки к сети (Wi-Fi / Мобильная) со старых серверов FPTN
    final prevScopes = <String, String>{
      for (final p in _settings.profiles)
        if (belongsToThisFptnGroup(p) && p.networkScope != 'all')
          fptnServerKey(p): p.networkScope,
    };

    final scopedFresh = [
      for (final p in filtered)
        if (prevScopes.containsKey(fptnServerKey(p)))
          Profile.fromJson({
            ...p.toJson(),
            'subscriptionId': subId,
            'extra': {
              ...p.extra,
              'network_scope': prevScopes[fptnServerKey(p)],
            },
          })
        else
          Profile.fromJson({
            ...p.toJson(),
            'subscriptionId': subId,
          }),
    ];

    try {
      if (filesDirPath.isNotEmpty) {
        final cacheFile = File('$filesDirPath/subs/$subId.txt');
        await cacheFile.parent.create(recursive: true);
        final outboundsList = scopedFresh.map((p) => p.toOutbound(tag: p.name)).toList();
        await cacheFile.writeAsString(jsonEncode(outboundsList));
      }
    } catch (_) {}

    final prevSubOutboundsJson = jsonEncode(
      _settings.profiles
          .where(belongsToThisFptnGroup)
          .map((p) => p.toOutbound(tag: p.name))
          .toList(),
    );
    final nextSubOutboundsJson = jsonEncode(
      scopedFresh.map((p) => p.toOutbound(tag: p.name)).toList(),
    );
    final nodesChanged = prevSubOutboundsJson != nextSubOutboundsJson;

    // Удаляем старые серверы этой FPTN-группы И старые разрозненные серверы FPTN
    final otherProfiles = _settings.profiles
        .where((p) => !belongsToThisFptnGroup(p))
        .toList(growable: false);
    final updatedProfiles = [...otherProfiles, ...scopedFresh];

    final savedKeys = (selectedServerKeys != null &&
            selectedServerKeys.isNotEmpty &&
            selectedServerKeys.length < allCandidates.length)
        ? selectedServerKeys.toList(growable: false)
        : (selectedServerKeys != null
            ? const <String>[]
            : (existing?.selectedServerKeys ?? const <String>[]));

    final updatedEntry = (existing ?? SubscriptionEntry(id: subId, url: cleanToken)).copyWith(
      url: cleanToken,
      name: (customName != null && customName.trim().isNotEmpty)
          ? customName.trim()
          : (existing != null && existing.name.isNotEmpty ? existing.name : desiredName),
      updatedAt: DateTime.now().millisecondsSinceEpoch,
      networkScope: networkScope ?? existing?.networkScope ?? 'all',
      selectedServerKeys: savedKeys,
    );

    final List<SubscriptionEntry> updatedSubs;
    if (existing != null) {
      updatedSubs = [
        for (final s in _settings.subscriptions)
          if (s.id == subId) updatedEntry else s,
      ];
    } else {
      updatedSubs = [..._settings.subscriptions, updatedEntry];
    }

    var nextSelected = _settings.selectedProfileId;
    final prevSelectedRemoved = nextSelected.isNotEmpty &&
        !nextSelected.startsWith('auto:') &&
        !updatedProfiles.any((p) => p.id == nextSelected);
    if (selectBalancer && scopedFresh.length >= 2) {
      if (nextSelected.isEmpty ||
          prevSelectedRemoved ||
          nextSelected == 'auto:$subId') {
        nextSelected = 'auto:$subId';
      }
    } else if (scopedFresh.length == 1 && (nextSelected.isEmpty || prevSelectedRemoved)) {
      nextSelected = scopedFresh.first.id;
    } else if (prevSelectedRemoved) {
      nextSelected = scopedFresh.length >= 2 ? 'auto:$subId' : scopedFresh.first.id;
    }

    _lastError = '';
    await _update(
      _settings.copyWith(
        profiles: updatedProfiles,
        subscriptions: updatedSubs,
        selectedProfileId: nextSelected,
      ),
    );

    if (_tunnel.status.isActive &&
        _settings.routingMode != RoutingMode.desync &&
        nodesChanged &&
        (nextSelected == 'auto:all' ||
            nextSelected == 'auto:$subId' ||
            scopedFresh.any((p) => p.id == nextSelected))) {
      await _restartActiveTunnel();
    }
    return scopedFresh.length;
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


  /// Выносит разбор массивных списков узлов в отдельный изолят без захвата `this` (`AppController`).
  static Future<List<Profile>> _parseEngineNodesIsolated(
    List<dynamic> nodes,
    List<dynamic> primaryTags,
    String subId,
  ) {
    if (nodes.length >= 25) {
      return Isolate.run(
        () => const LinkParser().parseEngineNodes(
          nodes,
          primaryTags,
          subscriptionId: subId,
        ),
      );
    }
    return Future<List<Profile>>.value(
      const LinkParser().parseEngineNodes(
        nodes,
        primaryTags,
        subscriptionId: subId,
      ),
    );
  }

  /// Выносит разбор текста крупных подписок в отдельный изолят без захвата `this` (`AppController`).
  static Future<List<Profile>> _parseSubTextIsolated(
    String bodyText,
    String subId,
  ) {
    if (bodyText.length > 24 * 1024) {
      return Isolate.run(
        () => const LinkParser().parseSubscription(
          bodyText,
          subscriptionId: subId,
        ),
      );
    }
    return Future<List<Profile>>.value(
      const LinkParser().parseSubscription(
        bodyText,
        subscriptionId: subId,
      ),
    );
  }

  /// Загружает содержимое подписки по сети, парсит серверы и кладёт в профили.
  Future<int> fetchSubscription(String subId) async {
    final sub = _settings.subscriptions.where((s) => s.id == subId).firstOrNull;
    if (sub == null || sub.url.isEmpty) return 0;
    if (sub.isFptnToken) {
      _loadingSubscription = true;
      _lastError = '';
      notifyListeners();
      try {
        return await importFptnToken(
          sub.url,
          customName: sub.name,
          selectedServerKeys: sub.selectedServerKeys.isEmpty
              ? null
              : sub.selectedServerKeys.toSet(),
          targetSubId: sub.id,
          selectBalancer: false,
        );
      } finally {
        _loadingSubscription = false;
        notifyListeners();
      }
    }
    _loadingSubscription = true;
    _lastError = '';
    notifyListeners();

    try {
      final globalHwid = effectiveHwid;
      final hwid = sub.customHwid.trim().isNotEmpty
          ? sub.customHwid.trim()
          : globalHwid;

      const userAgents = [
        'Tachyon/0.0.17 (Android; compatible; sing-box 1.14.3; HiddifyNext)',
        'v2rayNG/1.8.29 (Linux; Android)',
        'Happ/3.9.2 (Android; compatible; sing-box; Mihomo)',
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
      Map<String, dynamic>? nativeRes;

      Future<void> tryNativeFetch() async {
        if (fresh.isNotEmpty) return;
        nativeRes = await bridge.fetchSubscription(
          targetSubUrl,
          sendHwid: true,
          customHwid: hwid,
          insecure: true,
        );
        if (nativeRes != null &&
            nativeRes!['ok'] == true &&
            nativeRes!['nodes'] is List) {
          fresh = await _parseEngineNodesIsolated(
            nativeRes!['nodes'] as List,
            (nativeRes!['primary_tags'] as List?) ?? const [],
            subId,
          );
          if (nativeRes!['user_info'] is Map) {
            nativeUserInfo = Map<String, dynamic>.from(nativeRes!['user_info'] as Map);
          }
        }
      }

      Future<void> tryHttpCascade({required bool viaProxy}) async {
        if (fresh.isNotEmpty) return;
        final client = HttpClient()
          ..connectionTimeout = Duration(seconds: viaProxy ? 10 : 15)
          ..badCertificateCallback = ((cert, host, port) => true);
        if (viaProxy) {
          client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
        }
        try {
          for (final ua in userAgents) {
            if (fresh.isNotEmpty) break;
            try {
              var currentUrl = targetSubUrl;
              HttpClientResponse? attemptResp;
              for (var redirect = 0; redirect < 6; redirect++) {
                final uri = Uri.tryParse(currentUrl);
                if (uri == null || (!uri.isScheme('http') && !uri.isScheme('https'))) {
                  break;
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
                attemptResp = await request.close().timeout(
                      Duration(seconds: viaProxy ? 12 : 15),
                    );

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

              var bytes = await attemptResp
                  .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
                  .timeout(Duration(seconds: viaProxy ? 15 : 20));
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

              // Синтез секции [Peer] из HTTP-заголовков для AmneziaWG / WireGuard подписок
              if (RegExp(r'^\s*\[Interface\]\s*$', multiLine: true, caseSensitive: false)
                      .hasMatch(body) &&
                  !RegExp(r'^\s*\[Peer\]\s*$', multiLine: true, caseSensitive: false)
                      .hasMatch(body)) {
                String? hdr(List<String> names) {
                  for (final n in names) {
                    final v = attemptResp!.headers.value(n)?.trim();
                    if (v != null && v.isNotEmpty) return v;
                  }
                  return null;
                }

                final pk = hdr([
                  'x-peer-public-key',
                  'x-wg-public-key',
                  'x-awg-public-key',
                  'x-server-public-key',
                  'peer-public-key',
                ]);
                var ep = hdr([
                  'x-peer-endpoint',
                  'x-wg-endpoint',
                  'x-awg-endpoint',
                  'x-endpoint',
                  'peer-endpoint',
                ]);
                if (ep == null) {
                  final host = hdr(['x-peer-host', 'x-server-host', 'x-wg-host', 'x-awg-host']);
                  if (host != null) {
                    final port =
                        hdr(['x-peer-port', 'x-server-port', 'x-wg-port', 'x-awg-port']) ?? '51820';
                    ep = (host.contains(':') && !host.startsWith('['))
                        ? '[$host]:$port'
                        : '$host:$port';
                  }
                }
                final psk = hdr([
                  'x-preshared-key',
                  'x-peer-preshared-key',
                  'x-wg-preshared-key',
                  'x-awg-preshared-key',
                ]);
                if (pk != null && ep != null) {
                  final buf = StringBuffer(body);
                  if (!body.endsWith('\n')) buf.writeln();
                  buf.writeln('\n[Peer]');
                  buf.writeln('PublicKey = $pk');
                  if (psk != null) buf.writeln('PresharedKey = $psk');
                  buf.writeln('Endpoint = $ep');
                  buf.writeln('AllowedIPs = 0.0.0.0/0, ::/0');
                  body = buf.toString();
                }
              }

              var parsed = <Profile>[];
              final nativeBodyParsed = await bridge.parseSubscription(body);
              if (nativeBodyParsed != null &&
                  nativeBodyParsed['ok'] == true &&
                  nativeBodyParsed['nodes'] is List) {
                parsed = await _parseEngineNodesIsolated(
                  nativeBodyParsed['nodes'] as List,
                  (nativeBodyParsed['primary_tags'] as List?) ?? const [],
                  subId,
                );
              }
              if (parsed.isEmpty) {
                parsed = await _parseSubTextIsolated(body, subId);
              }
              if (parsed.isNotEmpty) {
                fresh = parsed;
                response = attemptResp;
                break;
              }
            } catch (_) {
              continue;
            }
          }
        } finally {
          client.close(force: false);
        }
      }

      // При активном VPN-туннеле приложение исключено из TUN (addDisallowedApplication),
      // поэтому сначала загружаем подписку ЧЕРЕЗ локальный прокси ядра (127.0.0.1:2080),
      // чтобы обновление работало даже при сетевых ограничениях оператора (белых списках),
      // не разрывая текущее соединение.
      final proxyReady = _tunnel.status.isActive ||
          await _waitForLocalProxyReady(timeout: const Duration(milliseconds: 220));
      if (proxyReady) {
        await tryHttpCascade(viaProxy: true);
        if (fresh.isEmpty) {
          await tryNativeFetch();
        }
        if (fresh.isEmpty) {
          await tryHttpCascade(viaProxy: false);
        }
      } else {
        await tryNativeFetch();
        if (fresh.isEmpty) {
          await tryHttpCascade(viaProxy: false);
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

      // Заменяем старые профили этой подписки свежими (сохраняя пользовательские network_scope)
      final prevScopes = <String, String>{
        for (final p in _settings.profiles)
          if (p.subscriptionId == subId && p.networkScope != 'all')
            '${p.name}|${p.server}|${p.port}': p.networkScope,
      };
      final scopedFresh = prevScopes.isEmpty
          ? fresh
          : [
              for (final p in fresh)
                if (prevScopes.containsKey('${p.name}|${p.server}|${p.port}'))
                  Profile.fromJson({
                    ...p.toJson(),
                    'extra': {
                      ...p.extra,
                      'network_scope': prevScopes['${p.name}|${p.server}|${p.port}'],
                    },
                  })
                else
                  p,
            ];

      final prevSubOutboundsJson = jsonEncode(
        _settings.profiles
            .where((p) => p.subscriptionId == subId)
            .map((p) => p.toOutbound(tag: p.name))
            .toList(),
      );
      final nextSubOutboundsList = scopedFresh.map((p) => p.toOutbound(tag: p.name)).toList();
      final nextSubOutboundsJson = jsonEncode(nextSubOutboundsList);
      final nodesChanged = prevSubOutboundsJson != nextSubOutboundsJson;

      // Сохраняем файл кэша для ядра в виде готового списка outbounds (sing-box JSON)
      try {
        final cacheFile = File('$filesDirPath/subs/$subId.txt');
        await cacheFile.parent.create(recursive: true);
        await cacheFile.writeAsString(nextSubOutboundsJson);
      } catch (_) {}

      final otherProfiles = _settings.profiles.where((p) => p.subscriptionId != subId).toList();
      final updatedProfiles = [...otherProfiles, ...scopedFresh];
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

      final usesThisSub = newSelected == 'auto:all' ||
          newSelected == 'auto:$subId' ||
          scopedFresh.any((p) => p.id == newSelected);
      if (_tunnel.status.isActive &&
          _settings.routingMode != RoutingMode.desync &&
          usesThisSub &&
          nodesChanged) {
        await _restartActiveTunnel();
      }

      _lastError = '';
      return scopedFresh.length;
    } catch (e) {
      _lastError = 'Сбой сети: $e';
      notifyListeners();
      return 0;
    } finally {
      _loadingSubscription = false;
      notifyListeners();
    }
  }

  /// Редактирует подписку (URL, название, HWID, привязку к сети, фильтры или интервал) и обновляет её.
  Future<void> editSubscription(
    String id, {
    String? url,
    String? name,
    String? customHwid,
    String? networkScope,
    List<String>? excludedCountries,
    List<String>? excludedProtocols,
    int? autoUpdateHours,
  }) async {
    final prev = _settings.subscriptions.where((s) => s.id == id).firstOrNull;
    final nextUrl = url?.trim() ?? prev?.url ?? '';
    final nextHwid = customHwid != null ? customHwid.trim() : (prev?.customHwid ?? '');
    final nextScope = networkScope != null
        ? ((networkScope == 'wifi' || networkScope == 'cellular') ? networkScope : 'all')
        : (prev?.networkScope ?? 'all');
    final nextExCountries = excludedCountries ?? prev?.excludedCountries ?? const <String>[];
    final nextExProtocols = excludedProtocols ?? prev?.excludedProtocols ?? const <String>[];
    final nextAutoHours = autoUpdateHours ?? prev?.autoUpdateHours ?? 0;
    final shouldRefetch = prev == null ||
        prev.updatedAt == 0 ||
        (url != null && nextUrl != prev.url) ||
        (customHwid != null && nextHwid != prev.customHwid);
    final routingFilterChanged = prev != null &&
        (nextScope != prev.networkScope ||
            jsonEncode(nextExCountries) != jsonEncode(prev.excludedCountries) ||
            jsonEncode(nextExProtocols) != jsonEncode(prev.excludedProtocols));

    await _update(_settings.copyWith(
      subscriptions: [
        for (final s in _settings.subscriptions)
          if (s.id == id)
            s.copyWith(
              url: nextUrl,
              name: name?.trim() ?? s.name,
              customHwid: nextHwid,
              networkScope: nextScope,
              excludedCountries: nextExCountries,
              excludedProtocols: nextExProtocols,
              autoUpdateHours: nextAutoHours,
            )
          else
            s,
      ],
    ));
    if (nextUrl.isNotEmpty && shouldRefetch) {
      await fetchSubscription(id);
    }
    if (routingFilterChanged) {
      await _checkNetworkDesyncProfile(forceCheck: true);
    }
    if (routingFilterChanged &&
        _tunnel.status.isActive &&
        _settings.routingMode != RoutingMode.desync &&
        _settings.selectedProfileId.startsWith('auto:')) {
      await _restartActiveTunnel();
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

  /// Меняет настройки десинхронизации пакетов (Desync).
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
    final activeSubs = _settings.visibleSubscriptions;
    final hasSubs = activeSubs.any((sub) => sub.enabled);
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
      subscriptions: hasProfile ? const [] : activeSubs,
      allSubscriptions: activeSubs,
      filesDir: filesDirPath,
      appRoutes: _settings.appRoutes,
      serviceRoutes: _settings.serviceRoutes,
      customRules: _settings.customRules,
      allowLan: _settings.allowLan,
      proxyOnly: _settings.proxyOnly,
      detourProfile: _settings.detourProfile,
      extraProfiles: _settings.visibleProfiles,
      proxyTlsFragment: _settings.proxyTlsFragment,
      balancer: _settings.balancer,
      activeNetworkType: _lastNetType,
    );
  }

  bool _isValidSelectableProfileId(String id) {
    if (id.isEmpty) return false;
    if (id == 'auto:all') return _settings.visibleProfiles.isNotEmpty;
    if (id.startsWith('auto:')) {
      final subId = id.substring(5);
      return _settings.visibleSubscriptions.any((s) => s.id == subId);
    }
    return _settings.visibleProfiles.any((p) => p.id == id);
  }

  /// Поднимает или опускает туннель.
  Future<void> toggleTunnel() async {
    if (_tunnel.status.isBusy) return;

    if (_tunnel.status.isActive || _tunnel.isPausedByWifi) {
      _tunnel = _tunnel.copyWith(
        status: VpnStatus.disconnecting,
        pausedWifiSsid: '',
      );
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
      _activeBalancerWinner = null;
      _nodeTelemetry.clear();
      _latencyHistory.clear();
      _lastTunnelNetType = '';
      _tunnel = _tunnel.copyWith(
        status: VpnStatus.disconnected,
        pausedWifiSsid: '',
        clearStartedAt: true,
      );
      notifyListeners();
      return;
    }

    _activeBalancerWinner = null;
    _nodeTelemetry.clear();
    await _checkNetworkDesyncProfile(forceCheck: true);
    final config = buildConfig();
    if (config == null) {
      _lastError = 'нет профиля или подписки';
      notifyListeners();
      return;
    }

    _lastTunnelNetType = _lastNetType;
    final currentServer = _settings.routingMode == RoutingMode.desync
        ? 'Режим Десинхронизации (Desync)'
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
    unawaited(ensureRequiredListsDownloaded());
  }

  /// Состояние от нативного слоя: оно авторитетнее локального.
  void _applyNativeState(TunnelState state) {
    final server = _settings.routingMode == RoutingMode.desync
        ? 'Режим Десинхронизации (Desync)'
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
        _urlTestPing = null;
        _activeBalancerWinner = null;
        _nodeTelemetry.clear();
        _lastTunnelNetType = '';
      }
      _tunnel = _withServer(state);
    }
    notifyListeners();
  }

  /// Дописывает имя выбранного сервера к состоянию.
  TunnelState _withServer(TunnelState state) => state.copyWith(
        serverName: _settings.routingMode == RoutingMode.desync
            ? 'Режим Десинхронизации (Desync)'
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
  /// `direct` из `appRoutes` и пакеты сервисов с маршрутом `direct`
  /// (чтобы их трафик гарантированно шёл мимо VPN даже на ядрах Android с ограничением netlink UID-lookup).
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
      for (final service in BuiltInService.catalog) {
        final action = _settings.serviceRoutes[service.id];
        if (action == 'direct' && service.packages.isNotEmpty) {
          for (final pkg in service.packages) {
            if (pkg.isNotEmpty && (_settings.appRoutes[pkg] ?? '').isEmpty) {
              set.add(pkg);
            }
          }
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
    if (_pollingTrafficInFlight) return;
    _pollingTrafficInFlight = true;
    final pollGen = _trafficPollGeneration;
    try {
      final next = await bridge.stats();
      if (pollGen != _trafficPollGeneration) return;
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
      final prevWinnerId = _activeBalancerWinner?.id;
      final changedWinner = _syncBalancerTelemetry(next?.balancer);
      _pollTickCount++;

      // Автоматическое переключение профиля/списка серверов и рецепта Desync при смене Wi-Fi <-> Мобильная сеть
      if ((_settings.perNetworkDesync ||
              _settings.wifiProfileId.isNotEmpty ||
              _settings.cellularProfileId.isNotEmpty ||
              _hasNetworkScopedNodes) &&
          _pollTickCount % 3 == 0) {
        unawaited(_checkNetworkDesyncProfile());
      }

      // Опрос текущего Wi-Fi и состояния «Домашний интернет»
      if (_pollTickCount % 2 == 0) {
        unawaited(refreshWifiInfo());
      }

      // Периодическая проверка расписания автообновления подписок (раз в минуту)
      if (_pollTickCount % 30 == 0) {
        unawaited(_checkScheduledSubAutoUpdate());
      }

      // Watchdog / Smart Failover: раз в 16 сек при отсутствии входящего трафика проверяет живой отклик
      // туннеля и автоматически переподключает сессию после перезагрузки роутера/сервера
      if (_tunnel.status.isActive &&
          _settings.routingMode != RoutingMode.desync &&
          _downSpeed == 0 &&
          _upSpeed < 2048 &&
          _pollTickCount % 8 == 0) {
        unawaited(_runFailoverCheck());
      }

      trafficRevision.value++;
      if (changedWinner || _activeBalancerWinner?.id != prevWinnerId) {
        notifyListeners();
      }
    } finally {
      _pollingTrafficInFlight = false;
    }
  }

  bool _syncBalancerTelemetry(BalancerRuntimeStatus? bal) {
    final prevWinnerId = _activeBalancerWinner?.id;
    final sel = selectedProfile;
    if (bal == null || sel == null || (!sel.id.startsWith('auto:') && sel.type != 'urltest')) {
      final hadWinner = _activeBalancerWinner != null;
      _activeBalancerWinner = null;
      _nodeTelemetry.clear();
      return hadWinner;
    }
    final candidates = RuntimeConfig.resolveAutoCandidates(
      sel,
      _settings.visibleProfiles,
      activeNetworkType: _lastNetType,
      subscriptions: _settings.visibleSubscriptions,
      balancer: _settings.balancer,
    );
    _activeBalancerWinner = null;
    _nodeTelemetry.clear();
    var anyProbedAlive = false;
    for (var i = 0; i < candidates.length; i++) {
      final tel = bal.telemetry['auto-srv-$i'];
      if (tel != null && tel.rttMs > 0 && !tel.quarantined) {
        anyProbedAlive = true;
        break;
      }
    }
    for (var i = 0; i < candidates.length; i++) {
      final tag = 'auto-srv-$i';
      final cand = candidates[i];
      if (bal.now == tag) {
        _activeBalancerWinner = cand;
      }
      final tel = bal.telemetry[tag];
      if (tel != null) {
        final prevTel = _nodeTelemetry[cand.id];
        final prevPing = _pings[cand.id];
        _nodeTelemetry[cand.id] = tel;
        if (tel.rttMs > 0 && !tel.quarantined) {
          _pings[cand.id] = tel.rttMs;
          if (bal.now == tag && !_testingUrlPing && (_urlTestPing == null || _urlTestPing! <= 0)) {
            _urlTestPing = tel.rttMs;
          }
        } else if (anyProbedAlive && (tel.quarantined || tel.lossPenaltyMs > 0)) {
          _pings[cand.id] = -1;
        }
        if (prevPing != _pings[cand.id] ||
            prevTel?.ewmaRttMs != tel.ewmaRttMs ||
            prevTel?.quarantined != tel.quarantined) {
          _bumpServerRevision(cand.id);
        }
      }
    }
    return _activeBalancerWinner?.id != prevWinnerId;
  }

  /// Выбирает целевой сервер или список серверов для указанной сети (`'wifi'` или `'cellular'`).
  /// Учитывает как явные `wifiProfileId` / `cellularProfileId`, так и разметку `networkScope`
  /// у отдельных серверов и подписок.
  String _resolveAutoSwitchTargetForNetwork(String net) {
    final explicitId =
        net == 'wifi' ? _settings.wifiProfileId : _settings.cellularProfileId;
    if (_isValidSelectableProfileId(explicitId)) {
      return explicitId;
    }

    final currentId = _settings.selectedProfileId;
    if (currentId == 'auto:all') return '';

    String effectiveScopeOf(Profile p) {
      if (p.networkScope == 'wifi' || p.networkScope == 'cellular') {
        return p.networkScope;
      }
      if (p.subscriptionId.isNotEmpty) {
        final sub = _settings.subscriptions
            .where((s) => s.id == p.subscriptionId)
            .firstOrNull;
        if (sub != null &&
            (sub.networkScope == 'wifi' || sub.networkScope == 'cellular')) {
          return sub.networkScope;
        }
      }
      return 'all';
    }

    // 1. Если выбран авто-пул конкретной подписки (auto:<subId>)
    if (currentId.startsWith('auto:')) {
      final curSubId = currentId.substring(5);
      final curSub = _settings.visibleSubscriptions
          .where((s) => s.id == curSubId)
          .firstOrNull;
      if (curSub != null && curSub.networkScope == net) {
        return '';
      }
      final scopedSub = _settings.visibleSubscriptions
          .where((s) => s.enabled && s.networkScope == net)
          .firstOrNull;
      if (scopedSub != null) {
        return 'auto:${scopedSub.id}';
      }
      if (curSub != null &&
          curSub.networkScope != 'all' &&
          curSub.networkScope != net) {
        final fallbackSub = _settings.visibleSubscriptions
            .where((s) => s.enabled && s.networkScope == 'all')
            .firstOrNull;
        return fallbackSub != null ? 'auto:${fallbackSub.id}' : 'auto:all';
      }
      return '';
    }

    // 2. Если выбран конкретный сервер
    final curProfile =
        _settings.visibleProfiles.where((p) => p.id == currentId).firstOrNull;
    final curDirectScope = curProfile?.networkScope ?? 'all';
    final curEffScope =
        curProfile != null ? effectiveScopeOf(curProfile) : 'all';

    // Если есть серверы, явно помеченные для текущей сети (p.networkScope == net)
    final directMatches = sortProfiles(
      _settings.visibleProfiles
          .where((p) => p.networkScope == net && isProfileAllowedByFilters(p))
          .toList(growable: false),
    );
    if (directMatches.isNotEmpty) {
      if (curDirectScope == net) return '';
      return directMatches.first.id;
    }

    // Если есть подписка, помеченная для текущей сети (s.networkScope == net)
    final scopedSub = _settings.visibleSubscriptions
        .where((s) => s.enabled && s.networkScope == net)
        .firstOrNull;
    if (scopedSub != null) {
      if (curEffScope == net) return '';
      final subServers = sortProfiles(
        _settings.visibleProfiles
            .where((p) =>
                p.subscriptionId == scopedSub.id &&
                effectiveScopeOf(p) == net &&
                isProfileAllowedByFilters(p))
            .toList(growable: false),
      );
      if (subServers.isNotEmpty) {
        return subServers.first.id;
      }
      return 'auto:${scopedSub.id}';
    }

    // 3. Если текущий выбранный сервер привязан к другой сети (например, только Wi-Fi, а сейчас LTE)
    if (curEffScope != 'all' && curEffScope != net) {
      final allowedFallbacks = sortProfiles(
        _settings.visibleProfiles
            .where((p) {
              final sc = effectiveScopeOf(p);
              return (sc == 'all' || sc == net) && isProfileAllowedByFilters(p);
            })
            .toList(growable: false),
      );
      if (allowedFallbacks.isNotEmpty) {
        return allowedFallbacks.first.id;
      }
    }

    return '';
  }

  Future<void> _checkNetworkDesyncProfile({bool forceCheck = false}) async {
    var net = await bridge.networkType();
    if (net == 'ethernet') net = 'wifi';
    if (net != 'wifi' && net != 'cellular') return;
    final netChanged = net != _lastNetType;
    if (!forceCheck && !netChanged) return;
    _lastNetType = net;

    if (_settings.perNetworkDesync) {
      final targetPreset = net == 'wifi'
          ? _settings.desync.wifiPreset
          : _settings.desync.cellularPreset;
      if (targetPreset.isNotEmpty && targetPreset != _settings.desync.preset) {
        await setDesync(_settings.desync.copyWith(preset: targetPreset));
      }
    }

    final targetProfileId = _resolveAutoSwitchTargetForNetwork(net);
    if (_isValidSelectableProfileId(targetProfileId) &&
        targetProfileId != _settings.selectedProfileId) {
      await selectProfile(targetProfileId);
      return;
    }

    final tunnelNetMismatch =
        _lastTunnelNetType.isNotEmpty && _lastTunnelNetType != net;
    if ((netChanged || tunnelNetMismatch) &&
        _settings.selectedProfileId.startsWith('auto:') &&
        _hasNetworkScopedNodes) {
      _activeBalancerWinner = null;
      _nodeTelemetry.clear();
      if (_tunnel.status.isActive &&
          _settings.routingMode != RoutingMode.desync) {
        await _restartActiveTunnel();
        return;
      }
    }

    notifyListeners();
  }

  bool _reconnectingFailover = false;

  Future<void> _runFailoverCheck({bool immediate = false}) async {
    if (_testingUrlPing || _pingingAll || _reconnectingFailover) return;
    if (!_tunnel.status.isActive || _settings.routingMode == RoutingMode.desync) return;

    final ms = await testUrlPing();
    if (ms >= 0) {
      _consecutiveWatchdogFails = 0;
      return;
    }

    _consecutiveWatchdogFails++;
    if (!immediate && _consecutiveWatchdogFails < 2) {
      return;
    }
    _consecutiveWatchdogFails = 0;
    _reconnectingFailover = true;
    try {
      // 1. Режим балансировщика (`auto:`): если туннель потерял связность (например, после перезагрузки роутера),
      //    пингуем кандидатов и при ответе любого узла перезапускаем сессию туннеля.
      if (_settings.selectedProfileId.startsWith('auto:')) {
        final sel = selectedProfile;
        if (sel != null) {
          final candidates = RuntimeConfig.resolveAutoCandidates(
            sel,
            _settings.visibleProfiles,
            activeNetworkType: _lastNetType,
            subscriptions: _settings.visibleSubscriptions,
            balancer: _settings.balancer,
          );
          final probeTargets = candidates.take(6).toList(growable: false);
          var anyAlive = false;
          for (final cand in probeTargets) {
            final rtt = await pingProfile(cand.id, coalesce: true);
            if (rtt >= 0) {
              anyAlive = true;
              break;
            }
          }
          if (anyAlive && _tunnel.status.isActive) {
            await _restartActiveTunnel();
          }
        }
        return;
      }

      // 2. Одиночный выбранный профиль: сначала проверяем сам текущий сервер.
      //    Если роутер/сервер уже поднялся после перезагрузки (curPing >= 0),
      //    принудительно переустанавливаем туннельную сессию на нём же.
      final current = selectedProfile;
      if (current != null && current.server.isNotEmpty) {
        _nodeTelemetry.remove(current.id);
        final curPing = await pingProfile(current.id);
        if (curPing >= 0 && _tunnel.status.isActive) {
          await _restartActiveTunnel();
          return;
        }
      }

      // 3. Если текущий сервер всё ещё недоступен и включён Smart Failover — переключаемся на лучший живой.
      if (_settings.smartFailover && _settings.visibleProfiles.length > 1) {
        await autoSelectBestServer(forceRestart: true);
      }
    } finally {
      _reconnectingFailover = false;
    }
  }

  Future<void> _onNetworkRestored() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await refreshWifiInfo();
    await _checkNetworkDesyncProfile(forceCheck: true);
    if (_tunnel.status.isActive) {
      await _runFailoverCheck(immediate: true);
    }
  }

  Future<void> _onNetworkChanged() async {
    await refreshWifiInfo();
    await _checkNetworkDesyncProfile(forceCheck: true);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await refreshWifiInfo();
    await _checkNetworkDesyncProfile(forceCheck: true);
  }

  /// Вызывается при возвращении приложения на передний план.
  Future<void> onAppResumed() async {
    await refreshWifiInfo();
    await _checkNetworkDesyncProfile(forceCheck: true);
  }

  /// Начинает опрос статистики трафика.
  void startTrafficPolling() {
    stopTrafficPolling();
    _trafficPollGeneration++;
    unawaited(_pollTrafficOnce());
    _trafficTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollTrafficOnce());
    });
  }

  /// Останавливает опрос статистики.
  void stopTrafficPolling() {
    _trafficPollGeneration++;
    _pollingTrafficInFlight = false;
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

  /// Открывает внешнюю ссылку в системном браузере.
  Future<bool> openUrl(String url) => bridge.openUrl(url);

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
  /// Сначала прогревает поток через локальный прокси, затем замеряет чистый 1-RTT отклик.
  Future<int> testUrlPing() async {
    if (_testingUrlPing) return _urlTestPing ?? -1;
    _testingUrlPing = true;
    notifyListeners();
    var result = -1;
    final client = HttpClient()
      ..connectionTimeout = const Duration(milliseconds: 2500)
      ..idleTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (_, _, _) => true;
    if (_tunnel.status.isActive) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
    }
    try {
      final configuredUrl = _settings.balancer.url.trim();
      final probeUrl = (configuredUrl.startsWith('http://') || configuredUrl.startsWith('https://'))
          ? configuredUrl
          : 'http://cp.cloudflare.com/generate_204';
      final uri = Uri.parse(probeUrl);
      // 1. Прогрев туннельного соединения (установка потока до выходного узла)
      final warmSw = Stopwatch()..start();
      final warmReq = await client.getUrl(uri).timeout(const Duration(milliseconds: 2500));
      warmReq.headers.set('Cache-Control', 'no-cache');
      final warmResp = await warmReq.close().timeout(const Duration(milliseconds: 2500));
      await warmResp.drain<void>().timeout(const Duration(milliseconds: 1500));
      warmSw.stop();

      if (warmResp.statusCode > 0 && warmResp.statusCode < 500) {
        result = warmSw.elapsedMilliseconds;
        // 2. Замер чистого RTT по уже открытому keep-alive потоку туннеля
        try {
          final rttSw = Stopwatch()..start();
          final req = await client.getUrl(uri).timeout(const Duration(milliseconds: 1800));
          req.headers.set('Cache-Control', 'no-cache');
          final resp = await req.close().timeout(const Duration(milliseconds: 1800));
          await resp.drain<void>().timeout(const Duration(milliseconds: 1000));
          rttSw.stop();
          if (resp.statusCode > 0 && resp.statusCode < 500 && rttSw.elapsedMilliseconds > 0) {
            result = rttSw.elapsedMilliseconds;
          }
        } catch (_) {
          // Если повторный запрос не прошёл, оставляем результат первого
        }
      }
    } catch (_) {
      result = -1;
    } finally {
      client.close(force: true);
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
          final req = await client.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 4));
          req.headers.set('Accept', 'application/json');
          req.headers.set('User-Agent', 'Tachyon/0.0.10');
          final resp = await req.close().timeout(const Duration(seconds: 4));
          if (resp.statusCode != 200) {
            await resp.drain<void>();
            return null;
          }
          final body = await resp.transform(utf8.decoder).join().timeout(const Duration(seconds: 4));
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
    if (code.length != 2) return '';
    final a = code.codeUnitAt(0);
    final b = code.codeUnitAt(1);
    if (a < 65 || a > 90 || b < 65 || b > 90) return '';
    return code;
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

  /// Пингует серверы и автоматически переключается на самый быстрый рабочий сервер.
  Future<Profile?> autoSelectBestServer({
    String? subscriptionId,
    bool forceRestart = false,
  }) async {
    await pingAllProfiles(subscriptionId: subscriptionId);
    final rawCandidates = subscriptionId == null
        ? _settings.visibleProfiles
        : _settings.visibleProfiles.where((p) => p.subscriptionId == subscriptionId).toList();
    final filtered = rawCandidates.where(isProfileAllowedByFilters).toList(growable: false);
    final candidates = filtered.isNotEmpty ? filtered : rawCandidates;
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
      final sameProfile = _settings.selectedProfileId == best.id;
      await selectProfile(best.id);
      if (forceRestart &&
          sameProfile &&
          _tunnel.status.isActive &&
          _settings.routingMode != RoutingMode.desync) {
        await _restartActiveTunnel();
      }
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
    _desyncTestStatus = 'Запуск снайпера стратегий Desync (7 профилей)...';
    notifyListeners();

    const candidates = [
      ('fake_disorder', 'autottl', 'Fake + Disorder (AutoTTL)'),
      ('fake_disorder', 'md5_badack', 'Fake + Disorder (MD5 + BadACK)'),
      ('multi_disorder', 'autottl', 'Multi-Disorder (7-точечный SNI)'),
      ('fake_split', 'autottl', 'Fake + Split (AutoTTL)'),
      ('fake_split', 'badseq_badack_badsum', 'Fake + Split (Triple Fooling)'),
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
  Future<void> setAutoUpdateIntervalMinutes(int minutes) =>
      _update(_settings.copyWith(autoUpdateIntervalMinutes: minutes.clamp(15, 10080)));
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

  /// Включает или выключает фрагментацию TLS ClientHello на прокси-соединениях (LTE).
  Future<void> setProxyTlsFragment(bool value) async {
    await _update(_settings.copyWith(proxyTlsFragment: value));
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Обновляет настройки нативного балансировщика `tachyon-core` 0.3.9+.
  Future<void> setBalancer(BalancerSettings balancer) async {
    await _update(_settings.copyWith(balancer: balancer));
    if (_tunnel.status.isActive &&
        _settings.routingMode != RoutingMode.desync &&
        _settings.selectedProfileId.startsWith('auto:')) {
      await _restartActiveTunnel();
    }
  }

  /// Обновляет данные о текущем Wi-Fi SSID, разрешениях и списке сетей вокруг.
  Future<void> refreshWifiInfo({bool requestPermission = false}) async {
    if (requestPermission) {
      await bridge.requestWifiPermission();
    }
    final info = await bridge.wifiInfo();
    final ssidOrNetChanged =
        _currentWifiSsid != info.ssid || _isWifiConnected != info.isWifi;
    final changed = ssidOrNetChanged ||
        _hasWifiPermission != info.hasPermission ||
        _wifiLocationEnabled != info.locationEnabled ||
        _nearbyWifiSsids.length != info.nearbySsids.length ||
        _tunnel.pausedWifiSsid != info.pausedWifiSsid;
    _currentWifiSsid = info.ssid;
    _isWifiConnected = info.isWifi;
    _hasWifiPermission = info.hasPermission;
    _wifiLocationEnabled = info.locationEnabled;
    _nearbyWifiSsids = info.nearbySsids;
    if (_tunnel.pausedWifiSsid != info.pausedWifiSsid) {
      _tunnel = _tunnel.copyWith(pausedWifiSsid: info.pausedWifiSsid);
    }
    if (ssidOrNetChanged && _settings.homeWifiMode) {
      unawaited(bridge.recheckHomeWifi());
    }
    if (ssidOrNetChanged &&
        (_settings.wifiProfileId.isNotEmpty ||
            _settings.cellularProfileId.isNotEmpty ||
            _hasNetworkScopedNodes ||
            _settings.perNetworkDesync)) {
      unawaited(_checkNetworkDesyncProfile());
    }
    if (changed || requestPermission) {
      notifyListeners();
    }
  }

  /// Открывает системные настройки геолокации (требуется Android для чтения SSID).
  Future<void> openLocationSettings() => bridge.openLocationSettings();

  /// Включает или выключает режим «Домашний интернет» (авто-пауза в доверенных Wi-Fi сетях).
  Future<void> setHomeWifiMode(bool enabled) async {
    if (enabled && !_hasWifiPermission) {
      await bridge.requestWifiPermission();
    }
    await _update(_settings.copyWith(homeWifiMode: enabled));
    await refreshWifiInfo();
    await bridge.recheckHomeWifi();
    if (enabled &&
        !_tunnel.status.isActive &&
        !_tunnel.isPausedByWifi &&
        isCurrentWifiTrusted &&
        canConnect) {
      await toggleTunnel();
    }
  }

  /// Добавляет Wi-Fi сеть (SSID) в список доверенных домашних/офисных сетей.
  Future<void> addTrustedWifiSsid(String rawSsid) async {
    var clean = rawSsid.trim();
    if (clean.length >= 2 && clean.startsWith('"') && clean.endsWith('"')) {
      clean = clean.substring(1, clean.length - 1).trim();
    }
    if (clean.isEmpty) return;
    final exists = _settings.trustedWifiSsids.any(
      (s) => s.trim().toLowerCase() == clean.toLowerCase(),
    );
    final next = exists
        ? _settings.trustedWifiSsids
        : [..._settings.trustedWifiSsids, clean];
    await _update(
      _settings.copyWith(
        homeWifiMode: true,
        trustedWifiSsids: next,
      ),
    );
    await refreshWifiInfo();
    await bridge.recheckHomeWifi();
    if (!_tunnel.status.isActive &&
        !_tunnel.isPausedByWifi &&
        isCurrentWifiTrusted &&
        canConnect) {
      await toggleTunnel();
    }
  }

  /// Удаляет Wi-Fi сеть (SSID) из списка доверенных сетей.
  Future<void> removeTrustedWifiSsid(String ssid) async {
    final target = ssid.trim().toLowerCase();
    final next = _settings.trustedWifiSsids
        .where((s) => s.trim().toLowerCase() != target)
        .toList(growable: false);
    await _update(_settings.copyWith(trustedWifiSsids: next));
    await bridge.recheckHomeWifi();
    await refreshWifiInfo();
  }

  /// Принудительно включает маршрутизацию, несмотря на активный домашний Wi-Fi.
  Future<void> forceResumeFromHomeWifi() async {
    await bridge.forceResumeFromWifi();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await refreshWifiInfo();
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

  static Uint8List _buildTlsClientHello(String sni) {
    final rng = Random();
    final exts = BytesBuilder(copy: false);

    final cleanSni = sni.trim();
    if (cleanSni.isNotEmpty && InternetAddress.tryParse(cleanSni) == null) {
      final hostBytes = ascii.encode(cleanSni);
      final nameListLen = hostBytes.length + 3;
      final extLen = nameListLen + 2;
      exts.add([
        0x00, 0x00,
        (extLen >> 8) & 0xff, extLen & 0xff,
        (nameListLen >> 8) & 0xff, nameListLen & 0xff,
        0x00,
        (hostBytes.length >> 8) & 0xff, hostBytes.length & 0xff,
        ...hostBytes,
      ]);
    }

    exts.add(const [0x00, 0x17, 0x00, 0x00, 0xff, 0x01, 0x00, 0x01, 0x00]);
    exts.add(const [
      0x00, 0x0a, 0x00, 0x08, 0x00, 0x06,
      0x00, 0x1d, 0x00, 0x17, 0x00, 0x18,
    ]);
    exts.add(const [0x00, 0x0b, 0x00, 0x02, 0x01, 0x00]);
    exts.add(const [
      0x00, 0x0d, 0x00, 0x12, 0x00, 0x10,
      0x04, 0x03, 0x05, 0x03, 0x06, 0x03,
      0x08, 0x04, 0x08, 0x05, 0x08, 0x06,
      0x04, 0x01, 0x08, 0x07,
    ]);
    exts.add(const [0x00, 0x2b, 0x00, 0x05, 0x04, 0x03, 0x04, 0x03, 0x03]);
    exts.add(const [0x00, 0x2d, 0x00, 0x02, 0x01, 0x01]);
    final keyShare = List<int>.generate(32, (_) => rng.nextInt(256));
    keyShare[0] &= 248;
    keyShare[31] = (keyShare[31] & 127) | 64;
    exts.add([
      0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20,
      ...keyShare,
    ]);

    final extBytes = exts.takeBytes();
    final body = BytesBuilder(copy: false);
    body.add(const [0x03, 0x03]);
    body.add(List<int>.generate(32, (_) => rng.nextInt(256)));
    body.addByte(32);
    body.add(List<int>.generate(32, (_) => rng.nextInt(256)));
    body.add(const [
      0x00, 0x12,
      0x13, 0x01, 0x13, 0x02, 0x13, 0x03,
      0xc0, 0x2b, 0xc0, 0x2f, 0xc0, 0x2c,
      0xc0, 0x30, 0xcc, 0xa9, 0xcc, 0xaa,
    ]);
    body.add(const [0x01, 0x00]);
    body.add([(extBytes.length >> 8) & 0xff, extBytes.length & 0xff]);
    body.add(extBytes);

    final bodyBytes = body.takeBytes();
    final hsLen = bodyBytes.length;
    final recLen = hsLen + 4;
    final record = BytesBuilder(copy: false);
    record.add([
      0x16, 0x03, 0x01,
      (recLen >> 8) & 0xff, recLen & 0xff,
      0x01,
      (hsLen >> 16) & 0xff, (hsLen >> 8) & 0xff, hsLen & 0xff,
    ]);
    record.add(bodyBytes);
    return record.takeBytes();
  }

  /// Проверяет доступность и задержку до сервера профиля.
  /// Для TLS/Reality-профилей после TCP-рукопожатия отправляет TLS ClientHello
  /// с фактическим SNI профиля и проверяет приход ServerHello, чтобы выявлять
  /// фильтрацию и сброс соединения после SYN-ACK на транзитных узлах.
  Future<int> pingProfile(String id, {bool coalesce = false}) async {
    final profile = _settings.profiles.where((p) => p.id == id).firstOrNull;
    if (profile == null || profile.server.isEmpty) return -1;
    _pingingIds.add(id);
    _bumpServerRevision(id);
    if (!coalesce && _sortByPing) {
      notifyListeners();
    }
    var result = -1;
    Socket? socket;
    try {
      if (_tunnel.status.isActive && _nodeTelemetry.containsKey(id)) {
        final tel = _nodeTelemetry[id]!;
        final anyAlive = _nodeTelemetry.values.any((t) => t.rttMs > 0 && !t.quarantined);
        if (tel.rttMs > 0 && !tel.quarantined) {
          result = tel.rttMs;
          return result;
        } else if (anyAlive && (tel.quarantined || tel.lossPenaltyMs > 0)) {
          result = -1;
          return result;
        }
      }

      // Если профиль использует цепочку прокси (detour), проверяем первый входной узел цепочки
      var targetHost = profile.server.trim();
      var targetPort = profile.port;
      var useTlsProbe = profile.hasTls &&
          profile.type != 'hysteria2' &&
          profile.type != 'hysteria' &&
          profile.type != 'tuic' &&
          profile.type != 'masque' &&
          profile.type != 'wireguard';
      var probeSni = profile.sni.trim().isNotEmpty ? profile.sni.trim() : targetHost;

      final chain = profile.extra['chain_outbounds'];
      if (chain is List && chain.isNotEmpty && chain.last is Map) {
        final entryHop = chain.last as Map;
        final h = (entryHop['server'] ?? '').toString().trim();
        final p = (entryHop['server_port'] as num?)?.toInt() ?? 0;
        if (h.isNotEmpty && p > 0) {
          targetHost = h;
          targetPort = p;
          final hopTls = entryHop['tls'];
          if (hopTls is Map && hopTls['enabled'] == true) {
            useTlsProbe = true;
            final hopSni = (hopTls['server_name'] ?? '').toString().trim();
            probeSni = hopSni.isNotEmpty ? hopSni : targetHost;
          } else {
            useTlsProbe = false;
          }
        }
      }

      // Резолвим IP заранее вне замера RTT
      Object connectTarget = targetHost;
      final parsedIp = InternetAddress.tryParse(targetHost);
      if (parsedIp != null) {
        connectTarget = parsedIp;
      } else {
        final resolved = await InternetAddress.lookup(targetHost)
            .timeout(const Duration(milliseconds: 2000));
        if (resolved.isNotEmpty) {
          connectTarget = resolved.first;
        }
      }

      final sw = Stopwatch()..start();
      socket = await Socket.connect(
        connectTarget,
        targetPort,
        timeout: const Duration(milliseconds: 2200),
      );
      sw.stop();
      final tcpMs = sw.elapsedMilliseconds.clamp(1, 9999);

      if (useTlsProbe) {
        final tlsSw = Stopwatch()..start();
        socket.add(_buildTlsClientHello(probeSni));
        final chunk = await socket.first.timeout(const Duration(milliseconds: 2200));
        tlsSw.stop();
        if (chunk.length >= 2 && chunk[0] == 0x16 && chunk[1] == 0x03) {
          result = tcpMs;
        } else {
          result = -1;
        }
      } else {
        result = tcpMs;
      }
    } catch (_) {
      result = -1;
    } finally {
      socket?.destroy();
      _pings[id] = result;
      _pingingIds.remove(id);
      _bumpServerRevision(id);
      if (coalesce) {
        _schedulePingCoalescedNotify();
      } else if (_sortByPing) {
        notifyListeners();
      }
    }
    return result;
  }

  /// Пингует все серверы (или серверы конкретной подписки) пулом из 8 параллельных
  /// воркеров (освободившийся слот сразу берёт следующий сервер) с коалесценцией UI.
  Future<void> pingAllProfiles({String? subscriptionId}) async {
    if (_pingingAll) return;
    final targets = subscriptionId == null
        ? _settings.visibleProfiles
        : _settings.profilesForSubscription(subscriptionId);
    if (targets.isEmpty) return;

    _pingingAll = true;
    _sortByPing = true;
    notifyListeners();

    try {
      const concurrency = 8;
      var cursor = 0;
      Future<void> worker() async {
        while (true) {
          final idx = cursor++;
          if (idx >= targets.length) break;
          await pingProfile(targets[idx].id, coalesce: true);
        }
      }

      final workerCount = targets.length < concurrency ? targets.length : concurrency;
      await Future.wait(List.generate(workerCount, (_) => worker()));

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
      _pingCoalesceTimer?.cancel();
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
      case 'network_restored':
        unawaited(_onNetworkRestored());
      case 'network_changed':
        unawaited(_onNetworkChanged());
    }
  }

  /// Принудительно обновляет подписку по её ID без отключения активного VPN-туннеля.
  Future<int> refreshSubscription(String id) {
    return fetchSubscription(id);
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
      final ts = DateTime.now().millisecondsSinceEpoch;
      final verBody = await _fetchTextWithFallback(
            'https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/version.json?t=$ts',
            headers: const {'Cache-Control': 'no-cache'},
          ) ??
          await _fetchTextWithFallback(
            'https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/version.json?t=$ts',
            headers: const {'Cache-Control': 'no-cache'},
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
        final ts = DateTime.now().millisecondsSinceEpoch;
        var currUrl = url.contains('?') ? '$url&t=$ts' : '$url?t=$ts';
        HttpClientResponse? resp;
        for (var i = 0; i < 8; i++) {
          final req = await client
              .getUrl(Uri.parse(currUrl))
              .timeout(const Duration(seconds: 15));
          req.headers.set('User-Agent', 'TachyonProxy/$appVersion');
          req.headers.set('Cache-Control', 'no-cache, no-store, must-revalidate');
          req.headers.set('Pragma', 'no-cache');
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
        var lastNotifiedPct = -1;
        var lastNotifiedMs = 0;
        final progressSw = Stopwatch()..start();
        final partFile = File('${targetFile.path}.part');
        sink = partFile.openWrite();
        await for (final chunk in resp.timeout(const Duration(seconds: 45))) {
          sink.add(chunk);
          received += chunk.length;
          final nowMs = progressSw.elapsedMilliseconds;
          var pct = -1;
          if (total > 0) {
            _updateProgress = (received / total).clamp(0.05, 0.98);
            pct = (_updateProgress * 100).round();
          } else {
            _updateProgress =
                (received / (25 * 1024 * 1024)).clamp(0.08, 0.95);
          }
          if ((pct != lastNotifiedPct && nowMs - lastNotifiedMs >= 100) ||
              nowMs - lastNotifiedMs >= 150) {
            lastNotifiedPct = pct;
            lastNotifiedMs = nowMs;
            final mb = (received / (1024 * 1024)).toStringAsFixed(1);
            if (total > 0) {
              final totalMb = (total / (1024 * 1024)).toStringAsFixed(1);
              _updateStatusText = '$label: $mb / $totalMb МБ ($pct%)';
            } else {
              _updateStatusText = '$label: скачано $mb МБ...';
            }
            notifyListeners();
          }
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
    if (Platform.isIOS) {
      await updateAppOnly();
      return;
    }
    if (_latestCoreVersion.isNotEmpty &&
        _compareSemver(_latestCoreVersion, minRequiredCoreVersion) < 0) {
      _updateStatusText =
          'Для приложения v$appVersion требуется ядро tachyon-core v$minRequiredCoreVersion или новее (на сервере: v$_latestCoreVersion)';
      notifyListeners();
      return;
    }
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
        'https://github.com/Dushnilin/tachyon-core/releases/latest/download/libtachyon-$abiSuffix.so',
        'https://ghfast.top/https://github.com/Dushnilin/tachyon-core/releases/latest/download/libtachyon-$abiSuffix.so',
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

  /// Отдельное обновление ТОЛЬКО приложения (`APK` / `IPA`) через системный установщик.
  Future<void> updateAppOnly() async {
    if (isAnyUpdateRunning) return;
    _updatingApp = true;
    _updateProgress = 0.02;
    _updateStatusText = Platform.isIOS
        ? 'Подготовка загрузки пакета IPA...'
        : 'Подготовка загрузчика APK...';
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

      if (Platform.isIOS) {
        const ipaName = 'tachyon-proxy-ios.ipa';
        final ipaFile = File('${updateDir.path}/$ipaName');
        const candidateIpaUrls = <String>[
          'https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/tachyon-proxy-ios.ipa',
          'https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/tachyon-proxy-ios.ipa',
          'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/latest/download/tachyon-proxy-ios.ipa',
          'https://ghfast.top/https://github.com/Dushnilin/tachyon-proxy/releases/download/latest/tachyon-proxy-ios.ipa',
        ];
        var okIpa = false;
        for (final ipaUrl in candidateIpaUrls) {
          okIpa = await _downloadUpdateFile(
            ipaUrl,
            ipaFile,
            'Скачивание IPA приложения (iOS arm64)',
          );
          if (okIpa) break;
        }
        if (!okIpa) {
          _updateStatusText =
              'Не удалось скачать IPA приложения с GitHub Releases';
          return;
        }
        _updateProgress = 1.0;
        _updateStatusText = 'Открытие меню установки / экспорта IPA...';
        notifyListeners();
        final res = await bridge.installApk(ipaName);
        if (res != 'ok') {
          _updateStatusText = 'Ошибка открытия IPA: $res';
        } else {
          _updateStatusText =
              'IPA скачан — выберите TrollStore / SideStore / AltStore или сохраните в Файлы';
        }
        return;
      }

      final abiSuffix = switch (abi) {
        'armeabi-v7a' || 'armeabi' => 'armeabi-v7a',
        'x86_64' => 'x86_64',
        _ => 'arm64-v8a',
      };

      const apkName = 'tachyon-update.apk';
      final apkFile = File('${updateDir.path}/$apkName');
      if (apkFile.existsSync()) {
        try {
          apkFile.deleteSync();
        } catch (_) {}
      }
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
    _pingCoalesceTimer?.cancel();
    stopTrafficPolling();
    themeModeNotifier.dispose();
    trafficRevision.dispose();
    pingRevision.dispose();
    for (final n in _serverRevisions.values) {
      n.dispose();
    }
    _serverRevisions.clear();
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
