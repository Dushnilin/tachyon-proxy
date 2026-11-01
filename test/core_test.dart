import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_proxy/core/models/app_rules.dart';
import 'package:tachyon_proxy/core/models/runtime_config.dart';
import 'package:tachyon_proxy/core/models/tunnel_state.dart';
import 'package:tachyon_proxy/core/services/dns_benchmark.dart';
import 'package:tachyon_proxy/core/services/link_parser.dart';

Profile _vlessProfile() => const Profile(
      id: 'p',
      name: 'p',
      type: 'vless',
      server: 's.example',
      port: 443,
      uuid: 'uuid-1',
    );

void main() {
  group('импорт ссылок', () {
    final parser = LinkParser();

    test('vless-ссылка разбирается в профиль', () {
      final profile = parser.parse(
        'vless://11111111-2222-3333-4444-555555555555@example.com:443'
        '?type=ws&security=tls&sni=example.com&path=%2Fws#Мой сервер',
      );

      expect(profile, isNotNull);
      expect(profile!.type, 'vless');
      expect(profile.server, 'example.com');
      expect(profile.port, 443);
      expect(profile.uuid, '11111111-2222-3333-4444-555555555555');
      expect(profile.name, 'Мой сервер');
    });

    test('vless xhttp ссылка с camelCase extra нормализуется в snake_case', () {
      const link =
          'vless://9e9623ea-a3c8-43f6-8fac-ee0d5e7eb8d9@exchange-l60.itxtech.surf:443'
          '?security=tls&type=xhttp&path=%2Fapi%2Fsource&host=exchange-l60.itxtech.surf'
          '&mode=packet-up&extra=%7B%22scMaxEachPostBytes%22%3A+%2216384-32768%22%2C+'
          '%22scMaxConcurrentPosts%22%3A+100%2C+%22xPaddingBytes%22%3A+%2216-28%22%2C+'
          '%22sessionIDTable%22%3A+%22Base62%22%2C+%22xmux%22%3A+%7B%22maxConnections%22%3A+3%2C+'
          '%22cMaxReuseTimes%22%3A+%2232-64%22%7D%7D#XHTTP Server';

      final profile = parser.parse(link);
      expect(profile, isNotNull);
      expect(profile!.transport, 'xhttp');

      final outbound = profile.toOutbound();
      final transport = outbound['transport'] as Map<String, dynamic>;
      expect(transport['type'], 'xhttp');
      expect(transport['sc_max_each_post_bytes'], '16384-32768');
      expect(transport.containsKey('scMaxEachPostBytes'), isFalse);
      expect(transport['sc_max_concurrent_posts'], 100);
      expect(transport.containsKey('scMaxConcurrentPosts'), isFalse);
      expect(transport['session_table'], 'Base62');
      expect(transport.containsKey('sessionIDTable'), isFalse);

      final xmux = transport['xmux'] as Map<String, dynamic>;
      expect(xmux['max_connections'], 3);
      expect(xmux['c_max_reuse_times'], '32-64');
    });

    test('trojan-ссылка разбирается в профиль', () {
      final profile = parser.parse(
        'trojan://secret@example.org:8443?sni=example.org#Trojan',
      );

      expect(profile, isNotNull);
      expect(profile!.type, 'trojan');
      expect(profile.server, 'example.org');
      expect(profile.port, 8443);
    });

    test('подписка в base64 даёт несколько профилей', () {
      final link =
          'vless://11111111-2222-3333-4444-555555555555@a.example:443#A\n'
          'trojan://secret@b.example:443#B';

      final profiles = parser.parseSubscription(_base64(link));
      expect(profiles.length, 2);
      expect(profiles.map((profile) => profile.name), containsAll(['A', 'B']));
      expect(profiles.map((profile) => profile.type), contains('vless'));
    });

    test('https-ссылка не разбирается как профиль напрямую', () {
      // Раньше парсер молча принимал URL подписки и терял её: проверяем,
      // что чистый парсер URL не превращает в профиль - загрузку делает
      // контроллер, парсер получает уже текст подписки.
      final profiles = parser.parse('https://s.example/sub?token=abc');
      expect(profiles, isNull);
    });

    test('подписка обычным текстом тоже разбирается', () {
      final profiles = parser.parseSubscription(
        'vless://11111111-2222-3333-4444-555555555555@a.example:443#A',
      );
      expect(profiles.length, 1);
      expect(profiles.first.name, 'A');
    });

    test('мусор не превращается в профиль', () {
      expect(parser.parse('https://example.com/page'), isNull);
      expect(parser.parse('vless://'), isNull);
    });
  });

  group('выбор DNS', () {
    test('приоритет у зашифрованных DoH', () {
      final recommendation = DnsRecommendation.from([
        _result('udp', 'Yandex', '77.88.8.8', 20),
        _result('https', 'Cloudflare', 'https://cloudflare-dns.com/dns-query', 60),
      ]);

      expect(
        recommendation.servers,
        ['https://cloudflare-dns.com/dns-query'],
      );
      expect(recommendation.primary!.candidate.provider, 'Cloudflare');
    });

    test('без DoH берутся быстрые UDP-серверы', () {
      final recommendation = DnsRecommendation.from([
        _result('udp', 'Yandex', '77.88.8.8', 20),
        _result('udp', 'Cloudflare', '1.1.1.1', 30),
      ]);

      expect(recommendation.servers, containsAll(['77.88.8.8', '1.1.1.1']));
      expect(recommendation.reason, contains('UDP'));
    });

    test('когда не ответил никто - применяются безопасные значения', () {
      final recommendation = DnsRecommendation.from([
        _result('udp', 'Yandex', '77.88.8.8', -1, ok: false),
      ]);

      expect(recommendation.servers, isNotEmpty);
      expect(recommendation.reason, contains('Ни один резолвер'));
      expect(recommendation.primary, isNull);
    });
  });

  group('свежесть настроек', () {
    test('DNS без проверки считается устаревшим', () {
      const dns = DnsSettings();
      expect(dns.isStale(DateTime.now()), isTrue);
    });

    test('свежая проверка не устаревает', () {
      final dns = DnsSettings(
        checkedAt: DateTime.now().millisecondsSinceEpoch,
      );
      expect(dns.isStale(DateTime.now()), isFalse);
    });

    test('старая проверка устаревает', () {
      final dns = DnsSettings(
        checkedAt: DateTime.now()
            .subtract(const Duration(hours: 8))
            .millisecondsSinceEpoch,
      );
      expect(dns.isStale(DateTime.now()), isTrue);
    });

    test('выключенный список не требует обновления', () {
      final set = RuleSetEntry(
        id: 'x',
        title: 'x',
        path: '/tmp/x.trs',
        enabled: false,
        updatedAt: 0,
      );
      expect(set.isStale(DateTime.now()), isFalse);
    });
  });

  group('состояние туннеля', () {
    test('после остановки длительность обнуляется', () {
      final state = TunnelState(
        status: VpnStatus.connected,
        startedAt: DateTime.now().subtract(
          const Duration(minutes: 5, seconds: 30),
        ),
      );
      // 5:30 минус дельта выполнения теста - до 5 минут с небольшим.
      expect(state.connectedFor.inSeconds, inInclusiveRange(325, 331));

      final stopped = state.copyWith(
        status: VpnStatus.disconnected,
        clearStartedAt: true,
      );
      expect(stopped.startedAt, isNull);
      expect(stopped.connectedFor, Duration.zero);
    });

    test('при новом подключении отсчёт начинается заново', () {
      final stopped = TunnelState(
        status: VpnStatus.disconnected,
        startedAt: DateTime.now().subtract(const Duration(hours: 1)),
      ).copyWith(clearStartedAt: true);

      final started = stopped.copyWith(
        status: VpnStatus.connected,
        startedAt: DateTime.now(),
      );
      expect(started.connectedFor.inSeconds.abs(), lessThan(5));
    });
  });

  group('обход DPI', () {
    test('выключенный desync не попадает в конфиг', () {
      final config = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.global,
        dns: const DnsSettings(),
        ruleSets: const [],
      ).toJson();
      final outbounds = config['outbounds'] as List;
      expect(outbounds.where((o) => o['type'] == 'desync'), isEmpty);
      expect(config['route']['final'], 'proxy');
    });

    test('включённый desync создаёт самостоятельный прямой аутбаунд', () {
      final config = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.global,
        dns: const DnsSettings(),
        ruleSets: const [],
        desync: const DesyncSettings(
          enabled: true,
          preset: 'fake_split',
          fooling: 'autottl',
        ),
      ).toJson();
      final outbounds = (config['outbounds'] as List).cast<Map>();
      final desync = outbounds.where((o) => o['type'] == 'desync').single;
      expect(desync.containsKey('detour'), isFalse);
      expect(desync['preset'], 'fake_split');
      expect(config['route']['final'], 'desync');
    });

    test('режим RoutingMode.desync работает без прокси-сервера чисто на YouTube', () {
      final config = RuntimeConfig(
        profile: const Profile(id: '', name: '', type: 'direct', server: '', port: 0),
        routingMode: RoutingMode.desync,
        dns: const DnsSettings(),
        ruleSets: const [],
        serviceRoutes: const {'youtube': 'desync'},
      ).toJson();

      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(outbounds.any((o) => o['tag'] == 'desync'), isTrue);
      expect(outbounds.any((o) => o['tag'] == 'proxy'), isFalse);
      expect(config['route']['final'], 'direct');

      final rules = (config['route']['rules'] as List).cast<Map>();
      expect(rules.first['action'], 'sniff');
      expect(
        rules.any((r) =>
            r['outbound'] == 'desync' &&
            ((r['domain_suffix'] as List?)?.contains('googlevideo.com') ?? false)),
        isTrue,
      );
    });
  });

  group('протоколы движка', () {
    test('hysteria2-ссылка разбирается с obfs', () {
      final profile = const LinkParser().parse(
        'hysteria2://pass@hy.example:8443?sni=cdn.example&obfs=salamander'
        '&obfs-password=ob123#HY2',
      );
      expect(profile, isNotNull);
      expect(profile!.type, 'hysteria2');
      expect(profile.server, 'hy.example');
      expect(profile.port, 8443);
      expect(profile.password, 'pass');
      expect(profile.sni, 'cdn.example');
      expect(profile.extra['obfs'], 'salamander');
      expect(profile.extra['obfs-password'], 'ob123');
    });

    test('hy2:// — то же самое, что hysteria2://', () {
      final profile = const LinkParser().parse('hy2://pass@hy.example#X');
      expect(profile, isNotNull);
      expect(profile!.type, 'hysteria2');
    });

    test('tuic-ссылка разбирается с congestion control', () {
      final profile = const LinkParser().parse(
        'tuic://uuid-abc:secret@tu.example:443'
        '?congestion_control=bbr&udp_relay_mode=native&sni=tls.example#TUIC',
      );
      expect(profile, isNotNull);
      expect(profile!.type, 'tuic');
      expect(profile.uuid, 'uuid-abc');
      expect(profile.password, 'secret');
      expect(profile.extra['congestion_control'], 'bbr');
      expect(profile.extra['udp_relay_mode'], 'native');
    });

    test('anytls и socks разбираются', () {
      final anytls = const LinkParser().parse('anytls://pw@a.example:443#A');
      expect(anytls!.type, 'anytls');
      expect(anytls.password, 'pw');

      final socks = const LinkParser().parse(
        'socks://user:pw@s.example:1080#S',
      );
      expect(socks!.type, 'socks');
      expect(socks.extra['username'], 'user');
      expect(socks.extra['version'], '5');
    });

    test('сырой outbound sing-box импортируется целиком', () {
      const json = '{"type":"tewfai","tag":"Экзотика","server":"t.example",'
          '"server_port":443,"uuid":"u1","password":"p1","pqc":true,'
          '"tls":{"enabled":true,"server_name":"sni.example"}}';
      final profile = const LinkParser().parse(json);
      expect(profile, isNotNull);
      expect(profile!.type, 'tewfai');
      expect(profile.name, 'Экзотика');
      expect(profile.extra['pqc'], true);
      expect(profile.sni, 'sni.example');
      // В outbound экстра-поля уходят как есть.
      final outbound = profile.toOutbound();
      expect(outbound['pqc'], true);
      expect(outbound['server_port'], 443);
    });

    test('extra переживает сериализацию', () {
      const base = Profile(
        id: 'x',
        name: 'x',
        type: 'socks',
        server: 's',
        port: 1080,
        extra: {'version': '5', 'username': 'u'},
      );
      final restored = Profile.fromJson(base.toJson());
      expect(restored.extra['version'], '5');
      expect(restored.extra['username'], 'u');
    });
  });

  group('подписки', () {
    test('подписка попадает в корень конфига и строит селектор', () {
      final config = RuntimeConfig(
        profile: const Profile(
          id: 'p', name: 'p', type: 'vless',
          server: 's.example', port: 443, uuid: 'u',
        ),
        routingMode: RoutingMode.global,
        dns: const DnsSettings(),
        ruleSets: const [],
        filesDir: '/data/app',
        subscriptions: const [
          SubscriptionEntry(id: 'a', url: 'https://sub.example/list'),
        ],
      ).toJson();

      final subs = config['subscriptions'] as List;
      expect(subs, hasLength(1));
      final sub = subs.first as Map;
      expect(sub['tag'], 'sub-a');
      expect(sub['url'], 'https://sub.example/list');
      expect(sub['path'], '/data/app/subs/a.txt');
      expect(sub['group']['type'], 'urltest');

      final outbounds = (config['outbounds'] as List).cast<Map>();
      final selector = outbounds.first;
      expect(selector['type'], 'selector');
      expect(selector['tag'], 'proxy');
      expect((selector['outbounds'] as List), containsAll(['sub-a', 'profile']));
      // Статический профиль переименован в 'profile'.
      expect(
        outbounds.any((o) => o['tag'] == 'profile' && o['type'] == 'vless'),
        isTrue,
      );
      expect(config['route']['final'], 'proxy');
    });

    test('без подписок конфиг как раньше', () {
      final config = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.global,
        dns: const DnsSettings(),
        ruleSets: const [],
      ).toJson();
      expect(config.containsKey('subscriptions'), isFalse);
      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(outbounds.first['tag'], 'proxy');
      expect(outbounds.first['type'], 'vless');
    });
  });

  group('разделение трафика по приложениям', () {
    test('режимы названы по-русски и разбираются обратно', () {
      expect(AppsMode.fromName('allow'), AppsMode.allow);
      expect(AppsMode.fromName('deny'), AppsMode.deny);
      expect(AppsMode.fromName(null), AppsMode.all);
      expect(AppsMode.allow.label, isNotEmpty);
    });
  });

  group('точечная маршрутизация и DPI', () {
    test('приложение направляется в desync, когда назначено', () {
      final config = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        appRoutes: const {'com.google.android.youtube': 'desync'},
      ).toJson();

      final rules = (config['route']['rules'] as List).cast<Map>();
      final ytRule = rules.firstWhere(
        (r) => (r['package_name'] as List?)?.contains('com.google.android.youtube') ?? false,
      );
      expect(ytRule['action'], 'route');
      expect(ytRule['outbound'], 'desync');

      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(outbounds.any((o) => o['tag'] == 'desync'), isTrue);
    });

    test('список правил с действием desync попадает в outbound desync', () {
      final config = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [
          RuleSetEntry(
            id: 'youtube',
            title: 'YouTube',
            path: '/cache/youtube.trs',
            action: 'desync',
            enabled: true,
          ),
        ],
      ).toJson();

      final rules = (config['route']['rules'] as List).cast<Map>();
      final ytSetRule = rules.firstWhere(
        (r) => (r['rule_set'] as List?)?.contains('youtube') ?? false,
      );
      expect(ytSetRule['action'], 'route');
      expect(ytSetRule['outbound'], 'desync');
    });
  });
}

DnsResult _result(
  String type,
  String provider,
  String address,
  int latency, {
  bool ok = true,
}) {
  return DnsResult(
    candidate: DnsCandidate(
      id: provider,
      provider: provider,
      type: type,
      address: address,
      ip: type == 'udp' ? address : '',
    ),
    ok: ok,
    latencyMs: ok ? latency : -1,
    lossPercent: ok ? 0 : 100,
  );
}

String _base64(String value) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  final bytes = value.codeUnits;
  final buffer = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final b0 = bytes[i];
    final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
    final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    buffer.write(chars[b0 >> 2]);
    buffer.write(chars[((b0 & 0x03) << 4) | (b1 >> 4)]);
    buffer.write(i + 1 < bytes.length ? chars[((b1 & 0x0f) << 2) | (b2 >> 6)] : '=');
    buffer.write(i + 2 < bytes.length ? chars[b2 & 0x3f] : '=');
  }
  return buffer.toString();
}
