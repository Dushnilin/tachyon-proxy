import 'dart:convert';
import 'dart:io';
import 'dart:async';

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

  /// Автоподбор рецепта DPI (Desync).
  bool _testingDesync = false;
  String _desyncTestStatus = '';
  List<DesyncScanEntry> _desyncScanResults = const [];

  /// Счётчики для фонового Smart Failover и автосмены профиля DPI по типу сети.
  int _pollTickCount = 0;
  int _consecutiveWatchdogFails = 0;
  String _lastNetType = '';

  AppSettings get settings => _settings;
  TunnelState get tunnel => _tunnel;
  bool get loading => _loading;
  bool _loadingSubscription = false;
  bool get loadingSubscription => _loadingSubscription;
  List<DnsResult> get dnsResults => _dnsResults;
  bool get dnsBenchmarkRunning => _dnsBenchmarkRunning;
  String get lastError => _lastError;
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
  bool get testingDesync => _testingDesync;
  String get desyncTestStatus => _desyncTestStatus;
  List<DesyncScanEntry> get desyncScanResults => _desyncScanResults;
  String get activeNetworkType => _lastNetType;

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
      final selectedExists = deduped.any((p) => p.id == _settings.selectedProfileId);
      _settings = _settings.copyWith(
        profiles: deduped,
        selectedProfileId: selectedExists
            ? _settings.selectedProfileId
            : (deduped.isNotEmpty ? deduped.first.id : ''),
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
    bridge.listen();

    // Фоновое обновление: подписки без серверов, список устарел или резолверы ещё не проверены.
    unawaited(_refreshStale());
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

    if (needsDnsCheck) {
      await runDnsBenchmark();
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

  /// Перезапускает активный туннель с новой конфигурацией.
  Future<void> _restartActiveTunnel() async {
    if (!_tunnel.status.isActive || _tunnel.status.isBusy) return;
    await toggleTunnel();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    if (!_tunnel.status.isActive && !_tunnel.status.isBusy) {
      await toggleTunnel();
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

  /// Импортирует подписку: принимает ссылку или готовое содержимое.
  Future<int> importProfiles(String content) async {
    final payload = content.trim();
    // https-ссылка - подписка: её качает и обновляет само ядро.
    if (payload.startsWith('http://') || payload.startsWith('https://')) {
      await addSubscription(payload);
      return _lastError.isEmpty ? -1 : 0;
    }
    final parser = LinkParser();
    final profiles = parser.parseSubscription(payload);
    if (profiles.isEmpty) {
      _lastError = 'не удалось разобрать ни одной ссылки';
      notifyListeners();
      return 0;
    }
    final existing = _settings.profiles.map((p) => p.id).toSet();
    final fresh = profiles.where((p) => !existing.contains(p.id)).toList();
    await _update(
      _settings.copyWith(
        profiles: [..._settings.profiles, ...fresh],
        selectedProfileId: _settings.selectedProfileId.isEmpty && fresh.isNotEmpty
            ? fresh.first.id
            : _settings.selectedProfileId,
      ),
    );
    return fresh.length;
  }

  /// Добавляет подписку: ядро качает её само, с железными заголовками.
  Future<void> addSubscription(String url) async {
    final clean = url.trim();
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
        hwid = 'e4d909c290d0fb1ca068ffaddf22cbd0';
        _settings = _settings.copyWith(hwid: hwid);
        unawaited(_persist());
      }

      var currentUrl = sub.url.trim();
      HttpClientResponse? response;
      for (var redirect = 0; redirect < 6; redirect++) {
        final uri = Uri.tryParse(currentUrl);
        if (uri == null) {
          _lastError = 'Некорректная ссылка: $currentUrl';
          notifyListeners();
          return 0;
        }
        final request = await client.getUrl(uri);
        request.headers.set('User-Agent', 'v2rayNG/1.8.5 (Linux; Android)');
        request.headers.set('Accept', '*/*');
        request.headers.set('Accept-Encoding', 'gzip, deflate');
        request.headers.set('X-Hwid', hwid);
        request.followRedirects = false;
        response = await request.close();

        if (response.statusCode >= 300 && response.statusCode < 400) {
          final loc = response.headers.value(HttpHeaders.locationHeader);
          await response.drain();
          if (loc != null && loc.isNotEmpty) {
            currentUrl = uri.resolve(loc).toString();
            continue;
          }
        }
        break;
      }

      if (response == null || response.statusCode != 200) {
        final code = response?.statusCode ?? 0;
        _lastError = 'Сервер вернул HTTP $code при загрузке подписки';
        notifyListeners();
        return 0;
      }

      var bytes = await response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));

      // Проверяем gzip magic 0x1f 0x8b
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
        _lastError = 'Сервер вернул HTML-страницу вместо серверов (Cloudflare/капча/ошибка хостинга)';
        notifyListeners();
        return 0;
      }

      final parser = LinkParser();
      final fresh = parser.parseSubscription(body, subscriptionId: subId);
      if (fresh.isEmpty) {
        _lastError = 'В ответе подписки не найдено распознаваемых серверов';
        notifyListeners();
        return 0;
      }

      // Парсим метаданные подписки (Subscription-Userinfo, Profile-Title, Support-Url)
      int uploadBytes = sub.uploadBytes;
      int downloadBytes = sub.downloadBytes;
      int totalBytes = sub.totalBytes;
      int expireUnix = sub.expireUnix;
      final userInfo = response.headers.value('subscription-userinfo') ??
          response.headers.value('Subscription-Userinfo') ??
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
        final rawTitle = response.headers.value('profile-title') ??
            response.headers.value('Profile-Title') ??
            '';
        if (rawTitle.startsWith('base64:')) {
          try {
            parsedTitle = utf8.decode(base64.decode(rawTitle.substring(7).trim()));
          } catch (_) {}
        } else if (rawTitle.isNotEmpty) {
          parsedTitle = rawTitle.trim();
        }
      }
      final supportUrl = response.headers.value('support-url') ??
          response.headers.value('profile-web-page-url') ??
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
      final newSelected = updatedProfiles.any((p) => p.id == _settings.selectedProfileId)
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
    if (_tunnel.status.isActive) {
      await _restartActiveTunnel();
    }
  }

  /// Меняет режим по приложениям.
  Future<void> setAppsMode(AppsMode mode) async {
    await _update(_settings.copyWith(appsMode: mode));
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
  }

  /// Меняет параметры DNS.
  Future<void> setDns(DnsSettings dns) async {
    await _update(_settings.copyWith(dns: dns));
  }

  /// Включает или выключает список правил.
  Future<void> toggleRuleSet(String id) async {
    final sets = _settings.ruleSets.map((set) {
      if (set.id != id) return set;
      return set.copyWith(enabled: !set.enabled);
    }).toList();
    await _update(_settings.copyWith(ruleSets: sets));
  }

  /// Меняет действие списка: в туннель, напрямую или блокировать.
  Future<void> setRuleSetAction(String id, String action) async {
    final sets = _settings.ruleSets.map((set) {
      if (set.id != id) return set;
      return set.copyWith(action: action);
    }).toList();
    await _update(_settings.copyWith(ruleSets: sets));
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
      _tunnel = _tunnel.copyWith(
        status: VpnStatus.disconnected,
        clearStartedAt: true,
      );
      notifyListeners();
      return;
    }

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
    } else {
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
  List<String> get _disallowedApps {
    if (_settings.appsMode == AppsMode.deny) return _settings.appPackages;
    return const [];
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

  /// Проверяет реальный сквозной HTTP 204 пинг через текущий маршрут/туннель.
  Future<int> testUrlPing() async {
    if (_testingUrlPing) return _urlTestPing ?? -1;
    _testingUrlPing = true;
    notifyListeners();
    var result = -1;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final sw = Stopwatch()..start();
      final req = await client.getUrl(Uri.parse('http://cp.cloudflare.com/generate_204'));
      req.headers.set('Cache-Control', 'no-cache');
      final resp = await req.close().timeout(const Duration(seconds: 5));
      await resp.drain<void>();
      sw.stop();
      if (resp.statusCode == 204 || resp.statusCode == 200) {
        result = sw.elapsedMilliseconds;
      }
    } catch (_) {
      result = -1;
    } finally {
      client.close(force: true);
      _urlTestPing = result;
      _testingUrlPing = false;
      notifyListeners();
    }
    return result;
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
  }

  /// Переключает активность пользовательского правила.
  Future<void> toggleCustomRule(String id) async {
    final list = _settings.customRules
        .map((r) => r.id == id ? r.copyWith(enabled: !r.enabled) : r)
        .toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
  }

  /// Меняет действие пользовательского правила (proxy / direct / desync / block).
  Future<void> setCustomRuleAction(String id, String action) async {
    final list = _settings.customRules
        .map((r) => r.id == id ? r.copyWith(action: action) : r)
        .toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
  }

  /// Удаляет пользовательское правило.
  Future<void> removeCustomRule(String id) async {
    final list = _settings.customRules.where((r) => r.id != id).toList(growable: false);
    await _update(_settings.copyWith(customRules: list));
  }

  /// Автоподбор оптимального рецепта Desync путём проверки TLS-соединения с YouTube/Discord.
  Future<String> autoPickDesyncPreset() async {
    if (_testingDesync) return _settings.desync.preset;
    _testingDesync = true;
    _desyncTestStatus = 'Проверка доступности YouTube / GStatic...';
    notifyListeners();
    try {
      final probeHosts = [
        'rr1---sn-gvnuxaxjvh-n8me.googlevideo.com',
        'www.youtube.com',
        'discord.com',
      ];
      var directWorks = false;
      for (final host in probeHosts) {
        try {
          final sock = await SecureSocket.connect(
            host,
            443,
            timeout: const Duration(milliseconds: 1800),
          );
          await sock.close();
          directWorks = true;
          break;
        } catch (_) {}
      }
      final chosen = directWorks ? 'fake_split' : 'fake_disorder';
      final fool = directWorks ? 'autottl' : 'md5';
      await setDesync(_settings.desync.copyWith(
        enabled: true,
        preset: chosen,
        fooling: fool,
        autoTune: true,
      ));
      _desyncTestStatus = 'Выбран рецепт: $chosen ($fool)';
      return chosen;
    } finally {
      _testingDesync = false;
      notifyListeners();
    }
  }

  /// Глубокий сканер (Снайпер) стратегий Desync: тестирует 6 боевых связок
  /// `preset × fooling` с замером времени TLS/HTTPS рукопожатия.
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

    try {
      final netType = await bridge.networkType();
      _lastNetType = netType;

      for (var i = 0; i < candidates.length; i++) {
        final (preset, fooling, label) = candidates[i];
        _desyncTestStatus = '[${i + 1}/${candidates.length}] Тест $label...';
        notifyListeners();

        // Применяем кандидата
        await _update(_settings.copyWith(
          desync: _settings.desync.copyWith(
            enabled: true,
            preset: preset,
            fooling: fooling,
            autoTune: true,
          ),
        ));
        if (_tunnel.status.isActive) {
          await _restartActiveTunnel();
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }

        // Замеряем скорость TLS-рукопожатия к YouTube и Discord
        var ytMs = -1;
        var dcMs = -1;
        try {
          final sw = Stopwatch()..start();
          final s = await SecureSocket.connect(
            'www.youtube.com',
            443,
            timeout: const Duration(milliseconds: 2200),
          );
          sw.stop();
          await s.close();
          ytMs = sw.elapsedMilliseconds;
        } catch (_) {}

        try {
          final sw = Stopwatch()..start();
          final s = await SecureSocket.connect(
            'discord.com',
            443,
            timeout: const Duration(milliseconds: 2200),
          );
          sw.stop();
          await s.close();
          dcMs = sw.elapsedMilliseconds;
        } catch (_) {}

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
      await setDesync(_settings.desync.copyWith(
        enabled: true,
        preset: winnerPreset,
        fooling: winnerFooling,
        wifiPreset: netType == 'wifi' ? winnerPreset : _settings.desync.wifiPreset,
        cellularPreset: netType == 'cellular' ? winnerPreset : _settings.desync.cellularPreset,
      ));
      _desyncTestStatus = best != null
          ? 'Лучший: ${best.label} (${best.avgMs} мс)'
          : 'Применён надёжный профиль: $winnerPreset ($winnerFooling)';
      return best;
    } finally {
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
      return prev;
    }
    const ruKeywords = [
      'ru.sberbank',
      'com.idamob.tinkoff',
      'ru.alfabank',
      'ru.vtb24',
      'ru.rostel',
      'ru.gosuslugi',
      'com.vkontakte',
      'ru.yandex',
      'ru.ozon',
      'com.wildberries',
      'ru.avito',
      'ru.dublgis',
      'ru.pochta',
      'ru.nalog',
      'ru.mirpay',
      'com.sbp',
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
    return count;
  }

  /// Настройки MTU, Allow LAN, автозапуска и автообновления подписок.
  Future<void> setMtu(int mtu) => _update(_settings.copyWith(mtu: mtu));
  Future<void> setAllowLan(bool value) => _update(_settings.copyWith(allowLan: value));
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
  }

  /// Пингует сервер профиля TCP-соединением. Возвращает мс или -1 при ошибке.
  Future<int> pingProfile(String id) async {
    final profile = _settings.profiles.where((p) => p.id == id).firstOrNull;
    if (profile == null || profile.server.isEmpty) return -1;
    _pingingIds.add(id);
    notifyListeners();
    final sw = Stopwatch()..start();
    var result = -1;
    try {
      final socket = await Socket.connect(
        profile.server,
        profile.port,
        timeout: const Duration(seconds: 3),
      );
      sw.stop();
      await socket.close();
      result = sw.elapsedMilliseconds;
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
  Future<String> coreVersion() => bridge.coreVersion();

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
