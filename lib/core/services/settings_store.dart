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

  /// Читает настройки; при отсутствии файла — значения по умолчанию.
  Future<AppSettings> load() async {
    try {
      if (!await _file.exists()) return const AppSettings();
      final raw = await _file.readAsString();
      return AppSettings.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      // Повреждённый файл не должен мешать запуску: начинаем с умолчаний.
      return const AppSettings();
    }
  }

  /// Сохраняет настройки.
  Future<void> save(AppSettings settings) async {
    await _file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
      flush: true,
    );
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
    this.proxyOnly = false,
    this.smartFailover = true,
    this.detourProfileId = '',
    this.perNetworkDesync = false,
    this.proxyTlsFragment = false,
    this.homeWifiMode = false,
    this.trustedWifiSsids = const [],
    this.showFreeNodes = true,
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

  /// Автообновление подписок при запуске приложения.
  final bool autoUpdateSubs;

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

  /// Показывать ли карточку и списки бесплатных резервных узлов (WARP AmneziaWG и SHARD).
  final bool showFreeNodes;

  static bool isFreeSubId(String subId) =>
      subId == 'free-warp' || subId == 'free-shard';

  List<Profile> get visibleProfiles => showFreeNodes
      ? profiles
      : profiles.where((p) => !isFreeSubId(p.subscriptionId)).toList(growable: false);

  List<SubscriptionEntry> get visibleSubscriptions => showFreeNodes
      ? subscriptions
      : subscriptions.where((s) => !isFreeSubId(s.id)).toList(growable: false);

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
    bool? proxyOnly,
    bool? smartFailover,
    String? detourProfileId,
    bool? perNetworkDesync,
    bool? proxyTlsFragment,
    bool? homeWifiMode,
    List<String>? trustedWifiSsids,
    bool? showFreeNodes,
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
      proxyOnly: proxyOnly ?? this.proxyOnly,
      smartFailover: smartFailover ?? this.smartFailover,
      detourProfileId: detourProfileId ?? this.detourProfileId,
      perNetworkDesync: perNetworkDesync ?? this.perNetworkDesync,
      proxyTlsFragment: proxyTlsFragment ?? this.proxyTlsFragment,
      homeWifiMode: homeWifiMode ?? this.homeWifiMode,
      trustedWifiSsids: trustedWifiSsids ?? this.trustedWifiSsids,
      showFreeNodes: showFreeNodes ?? this.showFreeNodes,
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
        'proxyOnly': proxyOnly,
        'smartFailover': smartFailover,
        'detourProfileId': detourProfileId,
        'perNetworkDesync': perNetworkDesync,
        'proxyTlsFragment': proxyTlsFragment,
        'homeWifiMode': homeWifiMode,
        'trustedWifiSsids': trustedWifiSsids,
        'showFreeNodes': showFreeNodes,
      };

  static AppSettings fromJson(Map<String, dynamic> json) {
    return AppSettings(
      profiles: ((json['profiles'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(Profile.fromJson)
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
      showFreeNodes: json['showFreeNodes'] != false,
    );
  }
}
