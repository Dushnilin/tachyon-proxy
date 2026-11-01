import 'dart:convert';

/// Профиль подключения: сервер и параметры исходящего соединения.
///
/// Минимальный набор MVP — `vless` и `shadowsocks`: оба умещаются в одну
/// строку JSON, которое собирает ядро.
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.type,
    required this.server,
    required this.port,
    this.uuid = '',
    this.password = '',
    this.method = '',
    this.transport = 'tcp',
    this.sni = '',
    this.alpn = const [],
    this.allowInsecure = false,
    this.flow = '',
    this.publicKey = '',
    this.shortId = '',
    this.subscriptionId = '',
    this.extra = const {},
  });

  final String id;
  final String name;

  /// `vless`, `vmess`, `trojan`, `shadowsocks`, `hysteria2`, `tuic`, etc.
  final String type;
  final String server;
  final int port;

  final String uuid;
  final String password;
  final String method;

  /// Транспорт: `tcp`, `ws`, `grpc`, `http`, `xhttp`, `h2`.
  final String transport;

  /// TLS: имя сервера в сертификате.
  final String sni;
  final List<String> alpn;
  final bool allowInsecure;
  final String flow;

  /// Reality: публичный ключ сервера и short id.
  final String publicKey;
  final String shortId;

  /// Принадлежность к подписке (если импортирован по ссылке).
  final String subscriptionId;

  /// Прочие поля аутбаунда sing-box как есть.
  final Map<String, dynamic> extra;

  bool get isReality => publicKey.isNotEmpty;
  bool get hasTls {
    final sec = extra['security']?.toString().toLowerCase() ?? '';
    if (sec == 'none') return false;
    return isReality || sni.isNotEmpty || alpn.isNotEmpty || sec == 'tls' || sec == 'reality';
  }

  /// Полное описание для бейджа: протокол, безопасность, flow, транспорт.
  String get fullTransportLabel {
    final parts = <String>[];
    parts.add(type.toUpperCase());
    final sec = extra['security']?.toString().toLowerCase() ?? '';
    if (isReality || sec == 'reality') {
      parts.add('Reality');
    } else if (sec != 'none' && (sni.isNotEmpty || alpn.isNotEmpty || sec == 'tls')) {
      parts.add('TLS');
    }
    if (flow.isNotEmpty) {
      parts.add(flow.replaceAll('xtls-rprx-', ''));
    }
    final trFromExtra = (extra['transport'] as Map?)?['type']?.toString() ?? '';
    final effectiveTransport = (transport.isNotEmpty && transport != 'tcp')
        ? transport
        : (trFromExtra.isNotEmpty ? trFromExtra : (transport.isNotEmpty ? transport : 'tcp'));
    parts.add(effectiveTransport.toUpperCase());
    return parts.join(' · ');
  }

  /// Собирает outbound для этого профиля.
  ///
  /// `tag` переопределяется, когда `proxy` занят группой подписки.
  Map<String, dynamic> toOutbound({String tag = 'proxy'}) {
    final cleanExtra = Map<String, dynamic>.from(extra);
    final security = cleanExtra.remove('security')?.toString().toLowerCase() ?? '';
    final fp = cleanExtra.remove('fp')?.toString() ?? '';
    if (cleanExtra['transport'] is Map) {
      final tr = cleanExtra['transport'] as Map;
      final trType = tr['type']?.toString().toLowerCase();
      if (trType == 'xhttp' || trType == 'splithttp') {
        cleanExtra['transport'] = normalizeXhttpTransport(Map<String, dynamic>.from(tr));
      }
    }

    switch (type) {
      case 'vless':
        final outbound = <String, dynamic>{
          'type': 'vless',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': uuid,
        };
        final useTls = security != 'none' &&
            (isReality ||
                security == 'tls' ||
                security == 'reality' ||
                security == 'xtls' ||
                sni.isNotEmpty ||
                alpn.isNotEmpty ||
                allowInsecure ||
                cleanExtra['transport'] == null);
        if (useTls) {
          final tls = <String, dynamic>{'enabled': true};
          if (sni.isNotEmpty) {
            tls['server_name'] = sni;
          } else if (server.isNotEmpty && cleanExtra['transport'] != null) {
            tls['server_name'] = server;
          }
          if (alpn.isNotEmpty) tls['alpn'] = alpn;
          if (allowInsecure) tls['insecure'] = true;
          if (fp.isNotEmpty) {
            tls['utls'] = {'enabled': true, 'fingerprint': fp};
          } else if (isReality) {
            tls['utls'] = {'enabled': true, 'fingerprint': 'chrome'};
          }
          if (isReality) {
            tls['reality'] = {
              'enabled': true,
              'public_key': publicKey,
              'short_id': shortId,
            };
          }
          outbound['tls'] = tls;
        }
        if (flow.isNotEmpty) outbound['flow'] = flow;
        return outbound..addAll(cleanExtra);
      case 'shadowsocks':
        return {
          'type': 'shadowsocks',
          'tag': tag,
          'server': server,
          'server_port': port,
          'method': method,
          'password': password,
        }..addAll(cleanExtra);
      default:
        // Остальные типы движка собираются из типа, адреса и `extra`.
        // TLS-поля модели (sni/alpn/insecure/reality) прикладываются сами,
        // если тип их ожидает и они заполнены.
        final outbound = <String, dynamic>{
          'type': type,
          'tag': tag,
          'server': server,
          'server_port': port,
        };
        if (security != 'none' &&
            (sni.isNotEmpty || alpn.isNotEmpty || allowInsecure || isReality)) {
          final tls = <String, dynamic>{'enabled': true};
          if (sni.isNotEmpty) tls['server_name'] = sni;
          if (alpn.isNotEmpty) tls['alpn'] = alpn;
          if (allowInsecure) tls['insecure'] = true;
          if (fp.isNotEmpty) {
            tls['utls'] = {'enabled': true, 'fingerprint': fp};
          }
          if (isReality) {
            tls['reality'] = {
              'enabled': true,
              'public_key': publicKey,
              'short_id': shortId,
            };
          }
          outbound['tls'] = tls;
        }
        return outbound..addAll(cleanExtra);
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'server': server,
        'port': port,
        'uuid': uuid,
        'password': password,
        'method': method,
        'transport': transport,
        'sni': sni,
        'alpn': alpn,
        'allowInsecure': allowInsecure,
        'flow': flow,
        'publicKey': publicKey,
        'shortId': shortId,
        'subscriptionId': subscriptionId,
        if (extra.isNotEmpty) 'extra': extra,
      };

  static Profile fromJson(Map<String, dynamic> json) {
    final rawExtra = ((json['extra'] as Map?) ?? const {})
        .map((key, value) => MapEntry(key.toString(), value));
    if (rawExtra['transport'] is Map) {
      final tr = Map<String, dynamic>.from(rawExtra['transport'] as Map);
      final trType = tr['type']?.toString().toLowerCase() ?? '';
      if (trType == 'xhttp' || trType == 'splithttp') {
        rawExtra['transport'] = normalizeXhttpTransport(tr);
      }
    }
    final savedTransport = (json['transport'] as String?) ?? '';
    final trFromExtra = (rawExtra['transport'] as Map?)?['type']?.toString() ?? '';
    final effectiveTransport = (savedTransport.isNotEmpty && savedTransport != 'tcp')
        ? savedTransport
        : (trFromExtra.isNotEmpty ? trFromExtra : 'tcp');

    return Profile(
      id: (json['id'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      type: (json['type'] as String?) ?? 'vless',
      server: (json['server'] as String?) ?? '',
      port: (json['port'] as num?)?.toInt() ?? 443,
      uuid: (json['uuid'] as String?) ?? '',
      password: (json['password'] as String?) ?? '',
      method: (json['method'] as String?) ?? '',
      transport: effectiveTransport,
      sni: (json['sni'] as String?) ?? '',
      alpn: ((json['alpn'] as List?) ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      allowInsecure: json['allowInsecure'] == true,
      flow: (json['flow'] as String?) ?? '',
      publicKey: (json['publicKey'] as String?) ?? '',
      shortId: (json['shortId'] as String?) ?? '',
      subscriptionId: (json['subscriptionId'] as String?) ?? '',
      extra: rawExtra,
    );
  }

  /// Собирает стандартную ссылку (`vless://`, `trojan://`, `ss://`, `hy2://`, `tuic://`, `anytls://`, `socks5://`)
  /// или JSON-строку для экспорта и генерации QR-кода.
  String toShareUri() {
    final encodedName = Uri.encodeComponent(name.isNotEmpty ? name : '$server:$port');
    switch (type) {
      case 'vless':
        final params = <String, String>{};
        final trMap = extra['transport'] is Map ? Map<String, dynamic>.from(extra['transport'] as Map) : null;
        final net = (trMap?['type']?.toString() ?? transport).toLowerCase();
        params['type'] = net.isEmpty ? 'tcp' : net;
        final sec = extra['security']?.toString().toLowerCase() ?? '';
        if (isReality || sec == 'reality') {
          params['security'] = 'reality';
          if (publicKey.isNotEmpty) params['pbk'] = publicKey;
          if (shortId.isNotEmpty) params['sid'] = shortId;
        } else if (hasTls) {
          params['security'] = 'tls';
        } else {
          params['security'] = 'none';
        }
        if (sni.isNotEmpty) params['sni'] = sni;
        if (flow.isNotEmpty) params['flow'] = flow;
        final fp = extra['fp']?.toString() ?? '';
        if (fp.isNotEmpty) {
          params['fp'] = fp;
        } else if (isReality) {
          params['fp'] = 'chrome';
        }
        if (alpn.isNotEmpty) params['alpn'] = alpn.join(',');
        if (allowInsecure) params['allowInsecure'] = '1';
        if (trMap != null) {
          if (trMap['path'] != null && trMap['path'].toString().isNotEmpty) {
            params['path'] = trMap['path'].toString();
          }
          if (trMap['host'] != null && trMap['host'].toString().isNotEmpty) {
            params['host'] = trMap['host'].toString();
          }
          if (trMap['mode'] != null && trMap['mode'].toString().isNotEmpty) {
            params['mode'] = trMap['mode'].toString();
          }
          if (trMap['service_name'] != null && trMap['service_name'].toString().isNotEmpty) {
            params['serviceName'] = trMap['service_name'].toString();
          }
        }
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'vless://$uuid@$server:$port?$q#$encodedName';
      case 'trojan':
        final params = <String, String>{
          'type': transport.isEmpty ? 'tcp' : transport,
          if (sni.isNotEmpty) 'sni': sni,
          if (alpn.isNotEmpty) 'alpn': alpn.join(','),
          if (allowInsecure) 'allowInsecure': '1',
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'trojan://${Uri.encodeComponent(password)}@$server:$port?$q#$encodedName';
      case 'shadowsocks':
        final creds = base64Url.encode(utf8.encode('${method.isEmpty ? "aes-256-gcm" : method}:$password'));
        return 'ss://$creds@$server:$port#$encodedName';
      case 'hysteria2':
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (allowInsecure) 'insecure': '1',
          if (extra['obfs'] != null) 'obfs': extra['obfs'].toString(),
          if (extra['obfs-password'] != null) 'obfs-password': extra['obfs-password'].toString(),
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'hysteria2://${Uri.encodeComponent(password)}@$server:$port${q.isEmpty ? "" : "?$q"}#$encodedName';
      case 'tuic':
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (allowInsecure) 'allowInsecure': '1',
          if (extra['congestion_control'] != null)
            'congestion_control': extra['congestion_control'].toString(),
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'tuic://$uuid:${Uri.encodeComponent(password)}@$server:$port${q.isEmpty ? "" : "?$q"}#$encodedName';
      case 'anytls':
        final q = sni.isNotEmpty ? '?sni=${Uri.encodeQueryComponent(sni)}' : '';
        return 'anytls://${Uri.encodeComponent(password)}@$server:$port$q#$encodedName';
      default:
        return jsonEncode(toOutbound(tag: name.isNotEmpty ? name : type));
    }
  }
}

/// Пользовательское правило маршрутизации (домен, суффикс, ключевое слово или IP/CIDR).
class CustomRule {
  const CustomRule({
    required this.id,
    required this.type,
    required this.value,
    required this.action,
    this.enabled = true,
  });

  final String id;

  /// `domain_suffix`, `domain`, `domain_keyword`, `ip_cidr`.
  final String type;

  /// Значение (например `example.com` или `192.168.1.0/24`).
  final String value;

  /// `proxy`, `direct`, `desync`, `block`.
  final String action;
  final bool enabled;

  CustomRule copyWith({
    String? type,
    String? value,
    String? action,
    bool? enabled,
  }) =>
      CustomRule(
        id: id,
        type: type ?? this.type,
        value: value ?? this.value,
        action: action ?? this.action,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type,
        'value': value,
        'action': action,
        'enabled': enabled,
      };

  static CustomRule fromJson(Map<String, dynamic> json) => CustomRule(
        id: (json['id'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'domain_suffix',
        value: (json['value'] as String?) ?? '',
        action: (json['action'] as String?) ?? 'proxy',
        enabled: json['enabled'] != false,
      );
}

/// Режим маршрутизации: что уходит в туннель, что через обход DPI, что напрямую.
enum RoutingMode {
  /// Гибкая маршрутизация: сервисы, списки и приложения по своим правилам.
  rules,

  /// Только обход DPI (Desync) без прокси-сервера или точечно для сервисов.
  desync,

  /// Весь трафик — в туннель.
  global,

  /// Ничего не уходит в туннель, кроме явных исключений.
  bypass;

  String get label => switch (this) {
        RoutingMode.rules => 'По правилам',
        RoutingMode.desync => 'Обход DPI',
        RoutingMode.global => 'Весь трафик',
        RoutingMode.bypass => 'Только исключения',
      };

  static RoutingMode fromName(String? name) => switch (name) {
        'global' => RoutingMode.global,
        'desync' => RoutingMode.desync,
        'bypass' => RoutingMode.bypass,
        _ => RoutingMode.rules,
      };
}

/// Встроенный пресет популярного сервиса для быстрой точечной настройки
/// (например: YouTube -> Desync, Discord -> Desync, остальное -> Прокси).
class BuiltInService {
  const BuiltInService({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.domains,
    this.packages = const [],
  });

  final String id;
  final String title;
  final String subtitle;
  final List<String> domains;
  final List<String> packages;

  static const List<BuiltInService> catalog = [
    BuiltInService(
      id: 'youtube',
      title: 'YouTube',
      subtitle: 'Видео, Shorts, YouTube Music (googlevideo.com, youtube.com)',
      domains: [
        'youtube.com',
        'youtu.be',
        'googlevideo.com',
        'ytimg.com',
        'ggpht.com',
        'youtubei.googleapis.com',
        'youtube-nocookie.com',
        'withyoutube.com',
      ],
      packages: [
        'com.google.android.youtube',
        'com.google.android.apps.youtube.music',
        'app.revanced.android.youtube',
        'app.rvx.android.youtube',
      ],
    ),
    BuiltInService(
      id: 'discord',
      title: 'Discord',
      subtitle: 'Сообщения, медиа и голосовые каналы',
      domains: [
        'discord.com',
        'discordapp.com',
        'discordapp.net',
        'discord.gg',
        'discord.media',
        'discordcdn.com',
        'discordstatus.com',
      ],
      packages: ['com.discord'],
    ),
    BuiltInService(
      id: 'telegram',
      title: 'Telegram',
      subtitle: 'Мессенджер, звонки и веб-версия',
      domains: [
        'telegram.org',
        't.me',
        'telegra.ph',
        'telesco.pe',
        'tdesktop.com',
      ],
      packages: [
        'org.telegram.messenger',
        'org.telegram.messenger.web',
        'nu.gpu.nagram',
      ],
    ),
    BuiltInService(
      id: 'instagram',
      title: 'Instagram / Meta',
      subtitle: 'Instagram, Facebook, Threads',
      domains: [
        'instagram.com',
        'cdninstagram.com',
        'facebook.com',
        'fbcdn.net',
        'threads.net',
      ],
      packages: ['com.instagram.android', 'com.instagram.barcelona'],
    ),
    BuiltInService(
      id: 'openai',
      title: 'ChatGPT / AI',
      subtitle: 'OpenAI, Claude, Gemini',
      domains: [
        'openai.com',
        'chatgpt.com',
        'oaistatic.com',
        'oaiusercontent.com',
        'anthropic.com',
        'claude.ai',
      ],
      packages: ['com.openai.chatgpt'],
    ),
    BuiltInService(
      id: 'ru',
      title: 'Сайты РФ (.ru / Банки / Госуслуги)',
      subtitle: 'Прямой доступ без прокси для российских сервисов',
      domains: [
        'ru',
        'su',
        'xn--p1ai',
        'yandex.net',
        'vk.com',
        'userapi.com',
        'gosuslugi.ru',
        'sberbank.ru',
        'tbank.ru',
        'ozon.ru',
        'wb.ru',
        'wildberries.ru',
        'avito.ru',
      ],
    ),
  ];
}

/// Параметры DNS.
class DnsSettings {
  const DnsSettings({
    this.autoSelect = true,
    this.servers = const [],
    this.bootstrap = const ['77.88.8.8', '1.1.1.1'],
    this.checkedAt = 0,
    this.ttlHours = 6,
    this.fakeIp = false,
    this.routeMode = 'split_ru',
  });

  /// Автоподбор по задержке.
  final bool autoSelect;

  /// Ручной список: `udp` или `https` с полным адресом.
  final List<String> servers;

  /// Серверы для разрешения имён DoH-резолверов и прямых запросов.
  final List<String> bootstrap;

  /// Момент последней проверки в Unix-миллисекундах.
  final int checkedAt;

  /// Сколько часов результат проверки считается свежим.
  final int ttlHours;

  /// Выдавать мгновенные виртуальные IP (198.18.0.0/15).
  final bool fakeIp;

  /// Режим маршрутизации DNS: `split_ru`, `proxy`, `direct`.
  final String routeMode;

  DnsSettings copyWith({
    bool? autoSelect,
    List<String>? servers,
    List<String>? bootstrap,
    int? checkedAt,
    int? ttlHours,
    bool? fakeIp,
    String? routeMode,
  }) {
    return DnsSettings(
      autoSelect: autoSelect ?? this.autoSelect,
      servers: servers ?? this.servers,
      bootstrap: bootstrap ?? this.bootstrap,
      checkedAt: checkedAt ?? this.checkedAt,
      ttlHours: ttlHours ?? this.ttlHours,
      fakeIp: fakeIp ?? this.fakeIp,
      routeMode: routeMode ?? this.routeMode,
    );
  }

  /// �� �� �� �� �� �� ������ �� �� ��.
  bool isStale(DateTime now) {
    if (!autoSelect) return false;
    if (checkedAt == 0) return true;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(checkedAt));
    return age.inHours >= ttlHours;
  }

  Map<String, dynamic> toJson() => {
        'autoSelect': autoSelect,
        'servers': servers,
        'bootstrap': bootstrap,
        'checkedAt': checkedAt,
        'ttlHours': ttlHours,
        'fakeIp': fakeIp,
        'routeMode': routeMode,
      };

  static DnsSettings fromJson(Map<String, dynamic> json) => DnsSettings(
        autoSelect: json['autoSelect'] != false,
        servers: ((json['servers'] as List?) ?? const [])
            .map((item) => item.toString())
            .toList(growable: false),
        bootstrap: ((json['bootstrap'] as List?) ?? const ['77.88.8.8', '1.1.1.1'])
            .map((item) => item.toString())
            .toList(growable: false),
        checkedAt: (json['checkedAt'] as num?)?.toInt() ?? 0,
        ttlHours: (json['ttlHours'] as num?)?.toInt() ?? 6,
        fakeIp: json['fakeIp'] == true,
        routeMode: (json['routeMode'] as String?) ?? 'split_ru',
      );
}

/// Локальный список правил `tachyon-lists` в формате `.trs`.
class RuleSetEntry {
  const RuleSetEntry({
    required this.id,
    required this.title,
    required this.path,
    this.action = 'proxy',
    this.enabled = false,
    this.sizeBytes = 0,
    this.updatedAt = 0,
    this.ttlHours = 24,
  });

  /// Идентификатор списка в каталоге `tachyon-lists`.
  final String id;
  final String title;

  /// Путь к скачанному файлу `.trs` в приватном каталоге приложения.
  final String path;

  /// `proxy` или `direct` — куда уходит трафик, попавший под список.
  final String action;
  final bool enabled;
  final int sizeBytes;

  /// ������ ���������� �� Unix-������ ��.
  final int updatedAt;

  /// ��ࠡ�� �� ������ �� ��, ��� �� �� ������ �� �� ��.
  final int ttlHours;

  RuleSetEntry copyWith({
    String? action,
    bool? enabled,
    String? path,
    int? sizeBytes,
    int? updatedAt,
    int? ttlHours,
  }) {
    return RuleSetEntry(
      id: id,
      title: title,
      path: path ?? this.path,
      action: action ?? this.action,
      enabled: enabled ?? this.enabled,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      updatedAt: updatedAt ?? this.updatedAt,
      ttlHours: ttlHours ?? this.ttlHours,
    );
  }

  /// �� �� �� �� �� ������ �� �� ��.
  bool isStale(DateTime now) {
    if (!enabled) return false;
    if (updatedAt == 0) return true;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(updatedAt));
    return age.inHours >= ttlHours;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'path': path,
        'action': action,
        'enabled': enabled,
        'sizeBytes': sizeBytes,
        'updatedAt': updatedAt,
        'ttlHours': ttlHours,
      };

  static RuleSetEntry fromJson(Map<String, dynamic> json) => RuleSetEntry(
        id: (json['id'] as String?) ?? '',
        title: (json['title'] as String?) ?? '',
        path: (json['path'] as String?) ?? '',
        action: (json['action'] as String?) ?? 'proxy',
        enabled: json['enabled'] == true,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        ttlHours: (json['ttlHours'] as num?)?.toInt() ?? 24,
      );
}

/// Обход DPI: нативный desync-аутбаунд движка.
class DesyncSettings {
  const DesyncSettings({
    this.enabled = false,
    this.preset = 'auto',
    this.fooling = 'autottl',
    this.autoTune = true,
    this.wifiPreset = 'fake_disorder',
    this.cellularPreset = 'fake_split',
    this.customSni = 'www.google.com',
  });

  /// Включён ли обход DPI.
  final bool enabled;

  /// Рецепт: `auto`, `fake_split`, `fake_disorder`, `multi_split`, `split`,
  /// `disorder`, `tlsrec`, `fake`, `oob`.
  final String preset;

  /// Способ «одурачивания» DPI: `md5`, `timestamp`, `badseq`, `badsum`,
  /// `autottl`.
  final String fooling;

  /// Адаптивная подстройка рецепта под провайдера (кэш состояния).
  final bool autoTune;

  /// Запомненный рецепт для Wi-Fi сети.
  final String wifiPreset;

  /// Запомненный рецепт для мобильной сети (LTE/5G).
  final String cellularPreset;

  /// Фейковый SNI для пакетов приманки.
  final String customSni;

  DesyncSettings copyWith({
    bool? enabled,
    String? preset,
    String? fooling,
    bool? autoTune,
    String? wifiPreset,
    String? cellularPreset,
    String? customSni,
  }) {
    return DesyncSettings(
      enabled: enabled ?? this.enabled,
      preset: preset ?? this.preset,
      fooling: fooling ?? this.fooling,
      autoTune: autoTune ?? this.autoTune,
      wifiPreset: wifiPreset ?? this.wifiPreset,
      cellularPreset: cellularPreset ?? this.cellularPreset,
      customSni: customSni ?? this.customSni,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'preset': preset,
        'fooling': fooling,
        'autoTune': autoTune,
        'wifiPreset': wifiPreset,
        'cellularPreset': cellularPreset,
        'customSni': customSni,
      };

  static DesyncSettings fromJson(Map<String, dynamic> json) => DesyncSettings(
        enabled: json['enabled'] == true,
        preset: (json['preset'] as String?) ?? 'auto',
        fooling: (json['fooling'] as String?) ?? 'autottl',
        autoTune: json['autoTune'] != false,
        wifiPreset: (json['wifiPreset'] as String?) ?? 'fake_disorder',
        cellularPreset: (json['cellularPreset'] as String?) ?? 'fake_split',
        customSni: (json['customSni'] as String?) ?? 'www.google.com',
      );
}

/// Подписка: URL, который ядро качает и обновляет само.
///
/// Заголовки железа (`X-HWID` и компания) ядро добавляет само - панели,
/// привязывающие подписку к устройству, отдают содержимое без ручных
/// подделок клиента.
class SubscriptionEntry {
  const SubscriptionEntry({
    required this.id,
    required this.url,
    this.name = '',
    this.group = '',
    this.enabled = true,
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireUnix = 0,
    this.updatedAt = 0,
    this.supportUrl = '',
  });

  /// Идентификатор: стабилен, участвует в тегах аутбаундов и файлах кэша.
  final String id;
  final String url;
  final String name;
  final String group;
  final bool enabled;

  /// Трафик и срок действия из заголовка `Subscription-Userinfo`.
  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final int expireUnix;
  final int updatedAt;
  final String supportUrl;

  bool get hasTrafficInfo => totalBytes > 0 || uploadBytes > 0 || downloadBytes > 0;
  int get usedBytes => uploadBytes + downloadBytes;
  double get usageRatio => totalBytes > 0 ? (usedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  SubscriptionEntry copyWith({
    String? url,
    bool? enabled,
    String? name,
    String? group,
    int? uploadBytes,
    int? downloadBytes,
    int? totalBytes,
    int? expireUnix,
    int? updatedAt,
    String? supportUrl,
  }) =>
      SubscriptionEntry(
        id: id,
        url: url ?? this.url,
        name: name ?? this.name,
        group: group ?? this.group,
        enabled: enabled ?? this.enabled,
        uploadBytes: uploadBytes ?? this.uploadBytes,
        downloadBytes: downloadBytes ?? this.downloadBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        expireUnix: expireUnix ?? this.expireUnix,
        updatedAt: updatedAt ?? this.updatedAt,
        supportUrl: supportUrl ?? this.supportUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'name': name,
        'group': group,
        'enabled': enabled,
        if (uploadBytes > 0) 'uploadBytes': uploadBytes,
        if (downloadBytes > 0) 'downloadBytes': downloadBytes,
        if (totalBytes > 0) 'totalBytes': totalBytes,
        if (expireUnix > 0) 'expireUnix': expireUnix,
        if (updatedAt > 0) 'updatedAt': updatedAt,
        if (supportUrl.isNotEmpty) 'supportUrl': supportUrl,
      };

  static SubscriptionEntry fromJson(Map<String, dynamic> json) =>
      SubscriptionEntry(
        id: (json['id'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        group: (json['group'] as String?) ?? '',
        enabled: json['enabled'] != false,
        uploadBytes: (json['uploadBytes'] as num?)?.toInt() ?? 0,
        downloadBytes: (json['downloadBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
        expireUnix: (json['expireUnix'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
        supportUrl: (json['supportUrl'] as String?) ?? '',
      );
}

/// Всё, что нужно ядру для запуска туннеля.
class RuntimeConfig {
  const RuntimeConfig({
    required this.profile,
    required this.routingMode,
    required this.dns,
    required this.ruleSets,
    this.logLevel = 'warn',
    this.mtu = 9000,
    this.desync = const DesyncSettings(),
    this.subscriptions = const [],
    this.filesDir = '',
    this.appRoutes = const {},
    this.serviceRoutes = const {},
    this.customRules = const [],
    this.allowLan = false,
    this.proxyOnly = false,
    this.detourProfile,
    this.extraProfiles = const [],
  });

  final Profile profile;
  final RoutingMode routingMode;
  final DnsSettings dns;
  final List<RuleSetEntry> ruleSets;
  final String logLevel;
  final int mtu;

  /// Обход DPI: настройки нативного desync-аутбаунда.
  final DesyncSettings desync;

  /// Подписки: ядро качает их само и строит urltest-группы.
  final List<SubscriptionEntry> subscriptions;

  /// Приватный каталог приложения: кэш подписок и логи ядра.
  final String filesDir;

  /// Точечная маршрутизация приложений: packageName → outbound tag.
  final Map<String, String> appRoutes;

  /// Точечная маршрутизация сервисов: serviceId → outbound tag (`desync`, `proxy`, `direct`, `block`, `profile:<id>`).
  final Map<String, String> serviceRoutes;

  /// Пользовательские правила (домен, суффикс, ключевое слово, IP/CIDR).
  final List<CustomRule> customRules;

  /// Раздавать локальный HTTP/SOCKS5 прокси на 0.0.0.0:2080 в локальную сеть.
  final bool allowLan;

  /// Режим «Только прокси» (:2080) без поднятия системного VPN TUN.
  final bool proxyOnly;

  /// Каскадный сервер (Proxy Chain / Detour), через который идёт основной прокси.
  final Profile? detourProfile;

  /// Все доступные профили для привязки конкретных сервисов (`profile:<id>`).
  final List<Profile> extraProfiles;

  /// Есть ли хоть один источник серверов или активный режим DPI.
  bool get hasSources =>
      routingMode == RoutingMode.desync ||
      desync.enabled ||
      serviceRoutes.values.contains('desync') ||
      appRoutes.values.contains('desync') ||
      subscriptions.any((sub) => sub.enabled) ||
      profile.server.isNotEmpty;

  /// Тег резолвера, который разрешает имена DoH-серверов.
  ///
  /// Ядро требует его явно, когда DNS-серверов больше одного: иначе нечем
  /// разрешить имя `dns.google`, а сам он ходит через прокси.
  static const bootstrapTag = 'dns-bootstrap';

  /// Тег прямого резолвера — для доменов, которые идут без туннеля.
  static const directTag = 'dns-direct';

  /// Собирает конфигурацию sing-box, которую принимает ядро.
  ///
  /// Платформенные поля (`fd`, `protect_path`, путь лога) добавляет нативная
  /// обвязка после проверки — здесь их быть не должно.
  Map<String, dynamic> toJson() {
    final enabledSets = ruleSets.where((set) => set.enabled).toList(growable: false);
    final hasStatic = routingMode != RoutingMode.desync &&
        profile.server.isNotEmpty &&
        profile.type != 'direct';
    final enabledSubs = (routingMode == RoutingMode.desync || hasStatic)
        ? const <SubscriptionEntry>[]
        : subscriptions.where((sub) => sub.enabled).toList(growable: false);
    final hasProxy = hasStatic || enabledSubs.isNotEmpty;

    final dedicatedOutbounds = <String, Map<String, dynamic>>{};

    String resolveOutbound(String raw) {
      final target = raw.isEmpty ? 'proxy' : raw;
      if (target.startsWith('profile:')) {
        final profId = target.substring('profile:'.length);
        for (final p in extraProfiles) {
          if (p.id == profId && p.server.isNotEmpty) {
            final tag = 'srv-${p.id}';
            dedicatedOutbounds.putIfAbsent(tag, () => p.toOutbound(tag: tag));
            return tag;
          }
        }
        return hasProxy ? 'proxy' : 'direct';
      }
      if (target == 'proxy' && !hasProxy) {
        return (routingMode == RoutingMode.desync || desync.enabled) ? 'desync' : 'direct';
      }
      return target;
    }

    final dnsServers = <Map<String, dynamic>>[];
    final bootstrapServers = dns.bootstrap.isEmpty
        ? const ['77.88.8.8']
        : dns.bootstrap;

    final usedDnsTags = <String>{bootstrapTag, directTag};
    for (var i = 0; i < bootstrapServers.length; i++) {
      final tag = i == 0 ? bootstrapTag : '$bootstrapTag-${i + 1}';
      usedDnsTags.add(tag);
      dnsServers.add(_dnsServer(bootstrapServers[i], tag: tag));
    }

    final primary = dns.servers.isEmpty ? const <String>[] : dns.servers;
    for (final address in primary) {
      final srv = _dnsServer(address);
      var tag = srv['tag'] as String;
      var suffix = 2;
      while (usedDnsTags.contains(tag)) {
        tag = '${srv['tag']}-$suffix';
        suffix++;
      }
      srv['tag'] = tag;
      usedDnsTags.add(tag);
      dnsServers.add(srv);
    }

    // Прямой резолвер нужен спискам с действием `direct`: их домены должны
    // разрешаться мимо туннеля, иначе они не попадут в правило.
    dnsServers.add(_dnsServer(bootstrapServers.first, tag: directTag));

    if (dns.fakeIp) {
      dnsServers.add({
        'type': 'fakeip',
        'tag': 'dns-fakeip',
        'inet4_range': '198.18.0.0/15',
      });
    }

    final dnsRules = <Map<String, dynamic>>[];
    final routeRules = <Map<String, dynamic>>[];

    // Сниффинг TLS SNI / HTTP Host / DNS обязателен для работы доменных правил,
    // перехвата DNS и передачи имени хоста в desync-движок.
    routeRules.add({'action': 'sniff'});

    // Перехват DNS: запросы приложений к резолверам из VpnService уходят в
    // DNS-подсистему ядра, а не в сеть напрямую.
    routeRules.add({'protocol': 'dns', 'action': 'hijack-dns'});

    if (dns.routeMode == 'split_ru') {
      dnsRules.add({
        'domain_suffix': ['ru', 'su', 'xn--p1ai'],
        'action': 'route',
        'server': directTag,
      });
    }

    // Per-app маршруты — самый высокий приоритет, идут до общих правил.
    // Группируем пакеты по outbound-тегу для компактности конфига.
    final appRouteGroups = <String, List<String>>{};
    appRoutes.forEach((pkg, outbound) {
      if (outbound.isEmpty) return;
      final resolved = resolveOutbound(outbound);
      appRouteGroups.putIfAbsent(resolved, () => []).add(pkg);
    });
    appRouteGroups.forEach((outbound, packages) {
      routeRules.add({
        'package_name': packages,
        'action': 'route',
        'outbound': outbound,
      });
    });

    // Пользовательские правила (Custom Rules) имеют высокий приоритет.
    for (final rule in customRules) {
      if (!rule.enabled || rule.value.trim().isEmpty) continue;
      final val = rule.value.trim();
      final action = resolveOutbound(rule.action);
      final key = switch (rule.type) {
        'domain' => 'domain',
        'domain_keyword' => 'domain_keyword',
        'ip_cidr' => 'ip_cidr',
        _ => 'domain_suffix',
      };
      if (key != 'ip_cidr' && (action == 'direct' || action == 'desync')) {
        dnsRules.add({
          key: [val],
          'action': 'route',
          'server': directTag,
        });
      }
      routeRules.add({
        key: [key == 'ip_cidr' && !val.contains('/') ? '$val/32' : val],
        'action': 'route',
        'outbound': action,
      });
    }

    // Резолверы, работающие по обычному UDP, должны ходить напрямую, иначе
    // они попадут в туннель и окажутся в петле.
    for (final address in bootstrapServers) {
      final ip = address.split(':').first;
      if (int.tryParse(ip.split('.').length == 4 ? ip : '') != null ||
          ip.contains('.')) {
        routeRules.add({
          'ip_cidr': ['$ip/32'],
          'action': 'route',
          'outbound': 'direct',
        });
      }
    }

    // Точечные правила сервисов (YouTube, Discord, Telegram, Сайты РФ и др.).
    for (final service in BuiltInService.catalog) {
      final rawAction = serviceRoutes[service.id];
      if (rawAction == null || rawAction.isEmpty || rawAction == 'off') continue;
      if (routingMode == RoutingMode.desync &&
          rawAction != 'desync' &&
          rawAction != 'block') {
        continue;
      }
      final action = resolveOutbound(rawAction);
      final isDirectOrDesync = action == 'direct' || action == 'desync';
      if (isDirectOrDesync && service.domains.isNotEmpty) {
        dnsRules.add({
          'domain_suffix': service.domains,
          'action': 'route',
          'server': directTag,
        });
      }
      if (service.domains.isNotEmpty) {
        routeRules.add({
          'domain_suffix': service.domains,
          'action': 'route',
          'outbound': action,
        });
      }
    }

    for (final set in enabledSets) {
      final action = resolveOutbound(set.action.isEmpty ? 'proxy' : set.action);
      final isDirectOrDesync = action == 'direct' || action == 'desync';
      if (isDirectOrDesync) {
        // Домены прямого списка и обхода DPI разрешаются прямым резолвером
        dnsRules.add({
          'rule_set': [set.id],
          'action': 'route',
          'server': directTag,
        });
      }
      routeRules.add({
        'rule_set': [set.id],
        'action': 'route',
        'outbound': action,
      });
    }

    if (dns.fakeIp) {
      dnsRules.add({
        'query_type': ['A', 'AAAA'],
        'action': 'route',
        'server': 'dns-fakeip',
      });
    }

    final finalTag = (!hasProxy || dns.routeMode == 'direct')
        ? directTag
        : dnsServers
            .map((server) => server['tag'] as String)
            .firstWhere(
              (tag) =>
                  !tag.startsWith(bootstrapTag) &&
                  tag != directTag &&
                  tag != 'dns-fakeip',
              orElse: () => bootstrapTag,
            );

    final subEntries = <Map<String, dynamic>>[];
    final subTags = <String>[];
    for (final sub in enabledSubs) {
      final subTag = 'sub-${sub.id}';
      subTags.add(subTag);
      subEntries.add({
        'tag': subTag,
        'url': sub.url,
        'path': filesDir.isEmpty ? null : '$filesDir/subs/${sub.id}.txt',
        'interval': '12h',
        'group': {'type': 'urltest', 'tag': subTag},
      });
    }

    final hasDetour = detourProfile != null &&
        detourProfile!.server.isNotEmpty &&
        detourProfile!.id != profile.id;

    Map<String, dynamic> buildMainProfileOutbound({String tag = 'proxy'}) {
      final out = profile.toOutbound(tag: tag);
      if (hasDetour) {
        out['detour'] = 'detour-proxy';
      }
      return out;
    }

    final outbounds = <Map<String, dynamic>>[
      if (subTags.isEmpty && hasStatic) buildMainProfileOutbound(),
      if (subTags.isNotEmpty)
        {
          'type': 'selector',
          'tag': 'proxy',
          'outbounds': [
            if (hasStatic) 'profile',
            ...subTags,
          ],
          'default': hasStatic ? 'profile' : subTags.first,
        },
      if (subTags.isNotEmpty && hasStatic) buildMainProfileOutbound(tag: 'profile'),
      if (hasDetour) detourProfile!.toOutbound(tag: 'detour-proxy'),
      ...dedicatedOutbounds.values,
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ];

    final hasDesyncRules = routeRules.any((r) => r['outbound'] == 'desync');
    final needDesync = routingMode == RoutingMode.desync ||
        desync.enabled ||
        hasDesyncRules;
    if (needDesync) {
      final insertIdx =
          outbounds.isNotEmpty && outbounds.first['tag'] == 'proxy' ? 1 : 0;
      outbounds.insert(insertIdx, {
        'type': 'desync',
        'tag': 'desync',
        'preset': desync.preset,
        'fooling': desync.fooling,
        'auto_tune': desync.autoTune,
      });
    }

    String finalOutbound;
    if (routingMode == RoutingMode.bypass) {
      finalOutbound = 'direct';
    } else if (routingMode == RoutingMode.desync) {
      finalOutbound = (desync.enabled || !hasDesyncRules) ? 'desync' : 'direct';
    } else if (hasProxy) {
      finalOutbound = 'proxy';
    } else if (desync.enabled || needDesync) {
      finalOutbound = hasDesyncRules ? 'direct' : 'desync';
    } else {
      finalOutbound = 'direct';
    }

    return {
      'log': {'level': logLevel, 'timestamp': true},
      'dns': {
        'servers': dnsServers,
        'rules': dnsRules,
        'final': finalTag,
        'strategy': 'prefer_ipv4',
      },
      'inbounds': [
        if (!proxyOnly)
          {
            'type': 'tun',
            'tag': 'tun-in',
            'address': ['172.19.0.1/30'],
            'mtu': mtu,
            'auto_route': false,
            'strict_route': false,
            'stack': 'system',
          },
        if (allowLan || proxyOnly)
          {
            'type': 'mixed',
            'tag': 'lan-in',
            'listen': allowLan ? '0.0.0.0' : '127.0.0.1',
            'listen_port': 2080,
          },
      ],
      'outbounds': outbounds,
      if (subEntries.isNotEmpty)
        'subscriptions': [
          for (final entry in subEntries)
            entry..removeWhere((key, value) => value == null),
        ],
      'route': {
        'rules': routeRules,
        'rule_set': [
          for (final set in enabledSets)
            {
              'type': 'local',
              'tag': set.id,
              'format': 'trs',
              'path': set.path,
            },
        ],
        'final': finalOutbound,
        'auto_detect_interface': false,
        'default_domain_resolver': bootstrapTag,
      },
    };
  }

  /// Приводит адрес резолвера к типизированному объекту.
  ///
  /// Ядро требует форму `{type, tag, server}`; DoH-адрес приходит строкой
  /// `https://host/dns-query` и превращается в `https`-сервер с путём.
  static Map<String, dynamic> _dnsServer(String raw, {String? tag}) {
    final value = raw.trim();
    if (value.startsWith('https://')) {
      final uri = Uri.parse(value);
      final resolvedTag = tag ?? 'dns-${uri.host.replaceAll('.', '-')}';
      return {
        'type': 'https',
        'tag': resolvedTag,
        'server': uri.host,
        'path': uri.path.isEmpty ? '/dns-query' : uri.path,
        if (!resolvedTag.startsWith(bootstrapTag))
          'domain_resolver': bootstrapTag,
      };
    }
    if (value.startsWith('tls://')) {
      final uri = Uri.parse(value);
      final resolvedTag = tag ?? 'dns-${uri.host.replaceAll('.', '-')}';
      return {
        'type': 'tls',
        'tag': resolvedTag,
        'server': uri.host,
        if (!resolvedTag.startsWith(bootstrapTag))
          'domain_resolver': bootstrapTag,
      };
    }
    return {
      'type': 'udp',
      'tag': tag ?? 'dns-${value.replaceAll('.', '-')}',
      'server': value,
    };
  }

  /// Готовая строка конфигурации для передачи в ядро.
  String encode() => jsonEncode(toJson());
}

/// Приводит параметры XHTTP-транспорта к строгому каноническому формату ядpa
/// (snake_case, правильные типы, отсечение неизвестных camelCase полей Xray).
Map<String, dynamic> normalizeXhttpTransport(Map<String, dynamic> raw) {
  final out = <String, dynamic>{'type': 'xhttp'};

  void setStr(String targetKey, List<String> sourceKeys) {
    for (final k in sourceKeys) {
      if (raw.containsKey(k) && raw[k] != null) {
        final val = raw[k].toString();
        if (val.isNotEmpty) {
          out[targetKey] = val;
          return;
        }
      }
    }
  }

  void setBool(String targetKey, List<String> sourceKeys) {
    for (final k in sourceKeys) {
      if (raw.containsKey(k) && raw[k] != null) {
        final val = raw[k];
        if (val is bool) {
          out[targetKey] = val;
          return;
        }
        if (val is String) {
          out[targetKey] = val == 'true' || val == '1';
          return;
        }
        if (val is num) {
          out[targetKey] = val == 1;
          return;
        }
      }
    }
  }

  void setInt(String targetKey, List<String> sourceKeys) {
    for (final k in sourceKeys) {
      if (raw.containsKey(k) && raw[k] != null) {
        final val = raw[k];
        if (val is num) {
          out[targetKey] = val.toInt();
          return;
        }
        if (val is String) {
          final parsed = int.tryParse(val);
          if (parsed != null) {
            out[targetKey] = parsed;
            return;
          }
        }
      }
    }
  }

  setStr('host', ['host']);
  setStr('path', ['path']);
  setStr('mode', ['mode']);
  setStr('session_placement', ['session_placement', 'sessionPlacement', 'sessionIDPlacement']);
  setStr('session_key', ['session_key', 'sessionKey', 'sessionIDKey']);
  setStr('seq_placement', ['seq_placement', 'seqPlacement']);
  setStr('seq_key', ['seq_key', 'seqKey']);
  setStr('session_table', ['session_table', 'sessionTable', 'sessionIDTable', 'session_id_table']);
  setStr('session_length', ['session_length', 'sessionLength', 'sessionIDLength', 'session_id_length']);
  setStr('uplink_data_placement', ['uplink_data_placement', 'uplinkDataPlacement']);
  setStr('uplink_data_key', ['uplink_data_key', 'uplinkDataKey']);
  setStr('uplink_chunk_size', ['uplink_chunk_size', 'uplinkChunkSize']);
  setStr('uplink_http_method', ['uplink_http_method', 'uplinkHttpMethod']);
  setStr('x_padding_bytes', ['x_padding_bytes', 'xPaddingBytes', 'xpaddingbytes']);
  setStr('x_padding_key', ['x_padding_key', 'xPaddingKey']);
  setStr('x_padding_header', ['x_padding_header', 'xPaddingHeader']);
  setStr('x_padding_placement', ['x_padding_placement', 'xPaddingPlacement']);
  setStr('x_padding_method', ['x_padding_method', 'xPaddingMethod']);
  setStr('sc_max_each_post_bytes', ['sc_max_each_post_bytes', 'scMaxEachPostBytes']);
  setStr('sc_min_posts_interval_ms', ['sc_min_posts_interval_ms', 'scMinPostsIntervalMs']);
  setStr('sc_stream_up_server_secs', ['sc_stream_up_server_secs', 'scStreamUpServerSecs']);

  setBool('no_grpc_header', ['no_grpc_header', 'noGRPCHeader']);
  setBool('x_padding_obfs_mode', ['x_padding_obfs_mode', 'xPaddingObfsMode']);
  setBool('no_sse_header', ['no_sse_header', 'noSSEHeader']);

  setInt('sc_max_concurrent_posts', ['sc_max_concurrent_posts', 'scMaxConcurrentPosts']);
  setInt('server_max_header_bytes', ['server_max_header_bytes', 'serverMaxHeaderBytes']);
  setInt('sc_max_buffered_posts', ['sc_max_buffered_posts', 'scMaxBufferedPosts']);

  if (raw['headers'] is Map) {
    out['headers'] = Map<String, dynamic>.from(raw['headers'] as Map);
  }

  if (raw['xmux'] is Map) {
    final rawMux = raw['xmux'] as Map;
    final muxOut = <String, dynamic>{};
    for (final entry in rawMux.entries) {
      final k = entry.key.toString();
      final v = entry.value;
      switch (k) {
        case 'max_concurrency':
        case 'maxConcurrency':
          muxOut['max_concurrency'] = v;
          break;
        case 'max_connections':
        case 'maxConnections':
          muxOut['max_connections'] = v is num ? v.toInt() : (int.tryParse(v.toString()) ?? v);
          break;
        case 'c_max_reuse_times':
        case 'cMaxReuseTimes':
          muxOut['c_max_reuse_times'] = v;
          break;
        case 'h_max_request_times':
        case 'hMaxRequestTimes':
          muxOut['h_max_request_times'] = v;
          break;
        case 'h_max_reusable_secs':
        case 'hMaxReusableSecs':
        case 'maxReusableSecs':
          muxOut['h_max_reusable_secs'] = v;
          break;
        case 'h_keep_alive_period':
        case 'hKeepAlivePeriod':
          muxOut['h_keep_alive_period'] = v is num ? v.toInt() : (int.tryParse(v.toString()) ?? v);
          break;
      }
    }
    if (muxOut.isNotEmpty) {
      out['xmux'] = muxOut;
    }
  }

  if (out.containsKey('session_table') && !out.containsKey('session_length')) {
    out['session_length'] = '8-14';
  } else if (out.containsKey('session_length') && !out.containsKey('session_table')) {
    out['session_table'] = 'Base62';
  }

  return out;
}
