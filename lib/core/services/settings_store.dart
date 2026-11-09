import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/app_rules.dart';
import '../models/runtime_config.dart';

/// Хранилище настроек приложения.
///
/// Файл лежит в приватном каталоге приложения: путь отдаёт нативный слой
/// (`filesDir`), поэтому внешние зависимости не нужны.
class SettingsStore {
  SettingsStore({required this.directory});

  /// Приватный каталог приложения.
  final String directory;

  File get _file => File('$directory/tachyon-settings.json');
  File get _tmpFile => File('$directory/tachyon-settings.json.tmp');
  File get _wifiFile => File('$directory/tachyon-wifi.json');
  File get _wifiTmpFile => File('$directory/tachyon-wifi.json.tmp');

  Future<void> _writeChain = Future<void>.value();
  Timer? _debounceTimer;
  AppSettings? _pendingSettings;
  bool? _lastSavedHomeWifiMode;
  String? _lastSavedTrustedWifiJson;

  /// Читает настройки; при отсутствии файла — значения по умолчанию.
  Future<AppSettings> load() async {
    try {
      if (await _file.exists()) {
        final raw = await _file.readAsString();
        if (raw.trim().isNotEmpty) {
          final parsed = AppSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
          _syncWifiFileIfNeeded(parsed);
          return parsed;
        }
      }
      if (await _tmpFile.exists()) {
        final raw = await _tmpFile.readAsString();
        if (raw.trim().isNotEmpty) {
          return AppSettings.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
        }
      }
      return const AppSettings();
    } catch (_) {
      // Повреждённый файл не должен мешать запуску: начинаем с умолчаний.
      return const AppSettings();
    }
  }

  /// Отложенное сохранение для частых UI-переключений (например, сворачивание групп).
  void saveDebounced(
    AppSettings settings, {
    Duration delay = const Duration(milliseconds: 350),
  }) {
    _pendingSettings = settings;
    _debounceTimer?.cancel();
    _debounceTimer = Timer(delay, () {
      final pending = _pendingSettings;
      _pendingSettings = null;
      if (pending != null) {
        unawaited(save(pending));
      }
    });
  }

  /// Сохраняет настройки последовательно и атомарно через временный файл.
  Future<void> save(AppSettings settings) {
    _debounceTimer?.cancel();
    _pendingSettings = null;
    _writeChain = _writeChain.then((_) => _writeAtomically(settings)).catchError((_) {});
    return _writeChain;
  }

  Future<void> _writeAtomically(AppSettings settings) async {
    if (directory.isEmpty) return;
    final encoded = jsonEncode(settings.toJson());
    await _tmpFile.parent.create(recursive: true);
    await _tmpFile.writeAsString(encoded, flush: true);
    try {
      await _tmpFile.rename(_file.path);
    } catch (_) {
      await _file.writeAsString(encoded, flush: true);
      try {
        await _tmpFile.delete();
      } catch (_) {}
    }
    await _syncWifiFileIfNeeded(settings);
  }

  Future<void> _syncWifiFileIfNeeded(AppSettings settings) async {
    if (directory.isEmpty) return;
    final trustedJson = jsonEncode(settings.trustedWifiSsids);
    if (_lastSavedHomeWifiMode == settings.homeWifiMode &&
        _lastSavedTrustedWifiJson == trustedJson &&
        _wifiFile.existsSync()) {
      return;
    }
    _lastSavedHomeWifiMode = settings.homeWifiMode;
    _lastSavedTrustedWifiJson = trustedJson;
    final payload = jsonEncode({
      'homeWifiMode': settings.homeWifiMode,
      'trustedWifiSsids': settings.trustedWifiSsids,
    });
    try {
      await _wifiTmpFile.writeAsString(payload, flush: true);
      await _wifiTmpFile.rename(_wifiFile.path);
    } catch (_) {
      try {
        await _wifiFile.writeAsString(payload, flush: true);
      } catch (_) {}
    }
  }
}

/// Все настройки приложения: профили, маршрутизация, DNS и списки.
class AppSettings {
  const AppSettings({
    this.profiles = const [],
    this.selectedProfileId = '',
    this.routingMode = RoutingMode.rules,
    this.dns = const DnsSettings(),
    this.ruleSets = const [],
    this.appsMode = AppsMode.all,
    this.appPackages = const [],
    this.appRoutes = const {},
    this.serviceRoutes = const {
      'youtube': 'desync',
      'discord': 'desync',
      'ru': 'direct',
    },
    this.themeMode = 'dark',
    this.logLevel = 'warn',
    this.mtu = 9000,
    this.desync = const DesyncSettings(),
    this.subscriptions = const [],
    this.hwid = '',
    this.customRules = const [],
    this.collapsedSubs = const [],
    this.autoStart = false,
    this.allowLan = false,
    this.autoUpdateSubs = true,
    this.autoUpdateIntervalMinutes = 360,
    this.proxyOnly = false,
    this.smartFailover = true,
    this.detourProfileId = '',
    this.perNetworkDesync = false,
    this.proxyTlsFragment = false,
    this.homeWifiMode = false,
    this.trustedWifiSsids = const [],
    this.balancer = const BalancerSettings(),
    this.wifiProfileId = '',
    this.cellularProfileId = '',
  });

  final List<Profile> profiles;

  /// Идентификатор выбранного профиля.
  final String selectedProfileId;

  final RoutingMode routingMode;
  final DnsSettings dns;
  final List<RuleSetEntry> ruleSets;

  /// Как приложения попадают в туннель.
  final AppsMode appsMode;

  /// Пакеты приложений, отмеченные пользователем (legacy).
  final List<String> appPackages;

  /// Точечная маршрутизация: packageName → outbound (proxy/direct/desync/block).
  /// Имеет приоритет над appsMode/appPackages.
  final Map<String, String> appRoutes;

  /// Точечная маршрутизация сервисов: serviceId → outbound (desync/proxy/direct/block).
  final Map<String, String> serviceRoutes;

  /// `dark` или `light`.
  final String themeMode;
  final String logLevel;
  final int mtu;

  /// Пакетная десинхронизация (Desync).
  final DesyncSettings desync;

  /// Подписки: URL, которые ядро качает и обновляет само.
  final List<SubscriptionEntry> subscriptions;

  /// Уникальный аппаратный ID для подписок с защитой HWID (Remnawave/Happ).
  final String hwid;

  /// Пользовательские правила маршрутизации.
  final List<CustomRule> customRules;

  /// Свёрнутые подписки на дашборде и в профилях.
  final List<String> collapsedSubs;

  /// Автозапуск туннеля при старте системы Android.
  final bool autoStart;

  /// Локальный HTTP/SOCKS5 прокси в локальную сеть на 0.0.0.0:2080.
  final bool allowLan;

  /// Автообновление подписок при запуске приложения и по расписанию.
  final bool autoUpdateSubs;

  /// Интервал автоматического обновления подписок в минутах (по умолчанию 360 = 6 ч).
  final int autoUpdateIntervalMinutes;

  /// Режим «Только прокси» (:2080 без поднятия системного VPN TUN).
  final bool proxyOnly;

  /// Умное автопереключение на следующий живой сервер при обрыве туннеля.
  final bool smartFailover;

  /// ID каскадного профиля (Proxy Chain / Detour).
  final String detourProfileId;

  /// Автовыбор разного рецепта Desync для Wi-Fi и мобильной сети.
  final bool perNetworkDesync;

  /// Дробить TLS ClientHello до прокси-сервера (record_fragment) против глушилок LTE.
  final bool proxyTlsFragment;

  /// Режим «Домашний интернет»: автоматически ставить маршрутизацию на паузу
  /// при подключении к доверенным Wi-Fi сетям и включать при выходе из них.
  final bool homeWifiMode;

  /// Список SSID доверенных Wi-Fi сетей (дом, офис, работа и т.д.).
  final List<String> trustedWifiSsids;

  /// Настройки нативного балансировщика `urltest` в `tachyon-core` 0.3.9+.
  final BalancerSettings balancer;

  /// Профиль / список автовыбора для автоматического включения в сети Wi-Fi (`''` = не менять).
  final String wifiProfileId;

  /// Профиль / список автовыбора для автоматического включения в мобильной сети (`''` = не менять).
  final String cellularProfileId;

  static bool isFreeSubId(String subId) =>
      subId == 'free-warp' || subId == 'free-shard';

  static final Expando<List<Profile>> _visibleProfilesCache =
      Expando<List<Profile>>('visibleProfiles');
  static final Expando<Map<String, List<Profile>>> _groupedProfilesCache =
      Expando<Map<String, List<Profile>>>('groupedProfiles');
  static final Expando<List<SubscriptionEntry>> _visibleSubsCache =
      Expando<List<SubscriptionEntry>>('visibleSubscriptions');

  List<Profile> get visibleProfiles {
    if (profiles.isEmpty) return const [];
    try {
      final cached = _visibleProfilesCache[profiles];
      if (cached != null) return cached;
      final computed =
          profiles.where((p) => !isFreeSubId(p.subscriptionId)).toList(growable: false);
      _visibleProfilesCache[profiles] = computed;
      return computed;
    } catch (_) {
      return profiles.where((p) => !isFreeSubId(p.subscriptionId)).toList(growable: false);
    }
  }

  /// Предварительно сгруппированные по `subscriptionId` видимые профили (`''` — пользовательские).
  Map<String, List<Profile>> get profilesBySubscription {
    final vis = visibleProfiles;
    if (vis.isEmpty) return const {};
    try {
      final cached = _groupedProfilesCache[vis];
      if (cached != null) return cached;
      final map = <String, List<Profile>>{};
      for (final p in vis) {
        (map[p.subscriptionId] ??= <Profile>[]).add(p);
      }
      _groupedProfilesCache[vis] = map;
      return map;
    } catch (_) {
      final map = <String, List<Profile>>{};
      for (final p in vis) {
        (map[p.subscriptionId] ??= <Profile>[]).add(p);
      }
      return map;
    }
  }

  List<Profile> profilesForSubscription(String subId) =>
      profilesBySubscription[subId] ?? const [];

  List<SubscriptionEntry> get visibleSubscriptions {
    if (subscriptions.isEmpty) return const [];
    try {
      final cached = _visibleSubsCache[subscriptions];
      if (cached != null) return cached;
      final computed =
          subscriptions.where((s) => !isFreeSubId(s.id)).toList(growable: false);
      _visibleSubsCache[subscriptions] = computed;
      return computed;
    } catch (_) {
      return subscriptions.where((s) => !isFreeSubId(s.id)).toList(growable: false);
    }
  }

  Profile? get detourProfile {
    if (detourProfileId.isEmpty) return null;
    for (final p in profiles) {
      if (p.id == detourProfileId) return p;
    }
    return null;
  }

  Profile? get selectedProfile {
    if (selectedProfileId.startsWith('auto:')) {
      final subId = selectedProfileId.substring(5);
      SubscriptionEntry? sub;
      for (final s in subscriptions) {
        if (s.id == subId) {
          sub = s;
          break;
        }
      }
      final subLabel = (sub != null && sub.name.isNotEmpty)
          ? sub.name
          : (sub != null ? (Uri.tryParse(sub.url)?.host ?? 'подписка') : 'все серверы');
      return Profile(
        id: selectedProfileId,
        name: '⚡ Автовыбор ($subLabel)',
        type: 'urltest',
        server: sub?.url ?? 'auto',
        port: 443,
        subscriptionId: subId == 'all' ? '' : subId,
      );
    }
      final pool = visibleProfiles;
      if (pool.isEmpty) return null;
      for (final profile in pool) {
        if (profile.id == selectedProfileId) return profile;
      }
      return pool.first;
    }

  AppSettings copyWith({
    List<Profile>? profiles,
    String? selectedProfileId,
    RoutingMode? routingMode,
    DnsSettings? dns,
    List<RuleSetEntry>? ruleSets,
    AppsMode? appsMode,
    List<String>? appPackages,
    Map<String, String>? appRoutes,
    Map<String, String>? serviceRoutes,
    String? themeMode,
    String? logLevel,
    int? mtu,
    DesyncSettings? desync,
    List<SubscriptionEntry>? subscriptions,
    String? hwid,
    List<CustomRule>? customRules,
    List<String>? collapsedSubs,
    bool? autoStart,
    bool? allowLan,
    bool? autoUpdateSubs,
    int? autoUpdateIntervalMinutes,
    bool? proxyOnly,
    bool? smartFailover,
    String? detourProfileId,
    bool? perNetworkDesync,
    bool? proxyTlsFragment,
    bool? homeWifiMode,
    List<String>? trustedWifiSsids,
    BalancerSettings? balancer,
    String? wifiProfileId,
    String? cellularProfileId,
  }) {
    return AppSettings(
      profiles: profiles ?? this.profiles,
      selectedProfileId: selectedProfileId ?? this.selectedProfileId,
      routingMode: routingMode ?? this.routingMode,
      dns: dns ?? this.dns,
      ruleSets: ruleSets ?? this.ruleSets,
      appsMode: appsMode ?? this.appsMode,
      appPackages: appPackages ?? this.appPackages,
      appRoutes: appRoutes ?? this.appRoutes,
      serviceRoutes: serviceRoutes ?? this.serviceRoutes,
      themeMode: themeMode ?? this.themeMode,
      desync: desync ?? this.desync,
      subscriptions: subscriptions ?? this.subscriptions,
      hwid: hwid ?? this.hwid,
      logLevel: logLevel ?? this.logLevel,
      mtu: mtu ?? this.mtu,
      customRules: customRules ?? this.customRules,
      collapsedSubs: collapsedSubs ?? this.collapsedSubs,
      autoStart: autoStart ?? this.autoStart,
      allowLan: allowLan ?? this.allowLan,
      autoUpdateSubs: autoUpdateSubs ?? this.autoUpdateSubs,
      autoUpdateIntervalMinutes:
          autoUpdateIntervalMinutes ?? this.autoUpdateIntervalMinutes,
      proxyOnly: proxyOnly ?? this.proxyOnly,
      smartFailover: smartFailover ?? this.smartFailover,
      detourProfileId: detourProfileId ?? this.detourProfileId,
      perNetworkDesync: perNetworkDesync ?? this.perNetworkDesync,
      proxyTlsFragment: proxyTlsFragment ?? this.proxyTlsFragment,
      homeWifiMode: homeWifiMode ?? this.homeWifiMode,
      trustedWifiSsids: trustedWifiSsids ?? this.trustedWifiSsids,
      balancer: balancer ?? this.balancer,
      wifiProfileId: wifiProfileId ?? this.wifiProfileId,
      cellularProfileId: cellularProfileId ?? this.cellularProfileId,
    );
  }

  Map<String, dynamic> toJson() => {
        'profiles': profiles.map((profile) => profile.toJson()).toList(),
        'selectedProfileId': selectedProfileId,
        'routingMode': routingMode.name,
        'dns': dns.toJson(),
        'ruleSets': ruleSets.map((set) => set.toJson()).toList(),
        'appsMode': appsMode.name,
        'appPackages': appPackages,
        'appRoutes': appRoutes,
        'serviceRoutes': serviceRoutes,
        'themeMode': themeMode,
        'logLevel': logLevel,
        'mtu': mtu,
        'desync': desync.toJson(),
        'subscriptions':
            subscriptions.map((sub) => sub.toJson()).toList(),
        'hwid': hwid,
        'customRules': customRules.map((r) => r.toJson()).toList(),
        'collapsedSubs': collapsedSubs,
        'autoStart': autoStart,
        'allowLan': allowLan,
        'autoUpdateSubs': autoUpdateSubs,
        'autoUpdateIntervalMinutes': autoUpdateIntervalMinutes,
        'proxyOnly': proxyOnly,
        'smartFailover': smartFailover,
        'detourProfileId': detourProfileId,
        'perNetworkDesync': perNetworkDesync,
        'proxyTlsFragment': proxyTlsFragment,
        'homeWifiMode': homeWifiMode,
        'trustedWifiSsids': trustedWifiSsids,
        'balancer': balancer.toJson(),
        if (wifiProfileId.isNotEmpty) 'wifiProfileId': wifiProfileId,
        if (cellularProfileId.isNotEmpty) 'cellularProfileId': cellularProfileId,
      };

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      profiles: ((json['profiles'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Profile.fromJson)
          .where((p) => !isFreeSubId(p.subscriptionId))
          .toList(growable: false),
      selectedProfileId: (json['selectedProfileId'] as String?) ?? '',
      routingMode: RoutingMode.fromName(json['routingMode'] as String?),
      dns: json['dns'] is Map<String, dynamic>
          ? DnsSettings.fromJson(json['dns'] as Map<String, dynamic>)
          : const DnsSettings(),
      ruleSets: ((json['ruleSets'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RuleSetEntry.fromJson)
          .toList(growable: false),
      appsMode: AppsMode.fromName(json['appsMode'] as String?),
      appPackages: ((json['appPackages'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      appRoutes: ((json['appRoutes'] as Map?) ?? const {})
          .map((k, v) => MapEntry(k.toString(), v.toString())),
      serviceRoutes: json['serviceRoutes'] is Map
          ? (json['serviceRoutes'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()))
          : const {
              'youtube': 'desync',
              'discord': 'desync',
              'ru': 'direct',
            },
      themeMode: (json['themeMode'] as String?) ?? 'dark',
      logLevel: (json['logLevel'] as String?) ?? 'warn',
      mtu: (json['mtu'] as num?)?.toInt() ?? 9000,
      desync: json['desync'] is Map<String, dynamic>
          ? DesyncSettings.fromJson(json['desync'] as Map<String, dynamic>)
          : const DesyncSettings(),
      subscriptions: ((json['subscriptions'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SubscriptionEntry.fromJson)
          .where((s) => !isFreeSubId(s.id))
          .toList(growable: false),
      hwid: (json['hwid'] as String?) ?? '',
      customRules: ((json['customRules'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CustomRule.fromJson)
          .toList(growable: false),
      collapsedSubs: ((json['collapsedSubs'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      autoStart: json['autoStart'] == true,
      allowLan: json['allowLan'] == true,
      autoUpdateSubs: json['autoUpdateSubs'] != false,
      autoUpdateIntervalMinutes:
          ((json['autoUpdateIntervalMinutes'] as num?)?.toInt() ?? 360).clamp(15, 10080),
      proxyOnly: json['proxyOnly'] == true,
      smartFailover: json['smartFailover'] != false,
      detourProfileId: (json['detourProfileId'] as String?) ?? '',
      perNetworkDesync: json['perNetworkDesync'] == true,
      proxyTlsFragment: json['proxyTlsFragment'] == true,
      homeWifiMode: json['homeWifiMode'] == true,
      trustedWifiSsids: ((json['trustedWifiSsids'] as List?) ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList(growable: false),
      balancer: json['balancer'] is Map<String, dynamic>
          ? BalancerSettings.fromJson(json['balancer'] as Map<String, dynamic>)
          : const BalancerSettings(),
      wifiProfileId: (json['wifiProfileId'] as String?) ?? '',
      cellularProfileId: (json['cellularProfileId'] as String?) ?? '',
    );
  }
}
