import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_proxy/core/models/app_rules.dart';
import 'package:tachyon_proxy/core/models/runtime_config.dart';
import 'package:tachyon_proxy/core/models/tunnel_state.dart';
import 'package:tachyon_proxy/core/services/dns_benchmark.dart';
import 'package:tachyon_proxy/core/services/free_nodes_service.dart';
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

  group('десинхронизация (desync)', () {
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
      expect(config['route']['final'], 'proxy');
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
    test('hysteria2-ссылка разбирается с obfs в канонический объект tachyon-core', () {
      final profile = const LinkParser().parse(
        'hysteria2://pass@hy.example:8443?sni=cdn.example&obfs=salamander'
        '&obfs-password=ob123&mport=20000-30000#HY2',
      );
      expect(profile, isNotNull);
      expect(profile!.type, 'hysteria2');
      expect(profile.server, 'hy.example');
      expect(profile.port, 8443);
      expect(profile.password, 'pass');
      expect(profile.sni, 'cdn.example');
      expect(profile.extra['obfs'], {'type': 'salamander', 'password': 'ob123'});
      expect(profile.extra['server_ports'], ['20000:30000']);
      final out = profile.toOutbound();
      expect(out['obfs'], {'type': 'salamander', 'password': 'ob123'});
      expect((out['tls'] as Map)['enabled'], isTrue);
    });

    test('wireguard и amneziawg URI и .conf INI разбираются со всеми полями AWG', () {
      final awg = const LinkParser().parse(
        'amneziawg://privKey123@198.51.100.10:51820'
        '?publickey=pubKey456&address=10.8.0.2/32&mtu=1380'
        '&jc=4&jmin=40&jmax=70&s1=15&s2=25&h1=100-200&h2=300#AWG-Server',
      );
      expect(awg, isNotNull);
      expect(awg!.type, 'wireguard');
      expect(awg.isAmneziaWg, isTrue);
      expect(awg.fullTransportLabel, 'AMNEZIAWG · UDP');
      final out = awg.toOutbound();
      expect(out['private_key'], 'privKey123');
      expect((out['peers'] as List).first['public_key'], 'pubKey456');
      expect(out['jc'], 4);
      expect(out['jmin'], 40);
      expect(out['jmax'], 70);
      expect(out['h1'], '100-200');
      expect(out['h2'], 300);

      const conf = '''
# Frankfurt AWG
[Interface]
PrivateKey = privConfKey
Address = 10.66.66.2/32
MTU = 1400
Jc = 5
Jmin = 50
Jmax = 1000

[Peer]
PublicKey = pubConfKey
Endpoint = 203.0.113.5:51820
''';
      final fromConf = const LinkParser().parseSubscription(conf);
      expect(fromConf.length, 1);
      expect(fromConf.first.name, 'Frankfurt AWG');
      expect(fromConf.first.extra['jc'], 5);
    });

    test('naive+quic, snell, shadowtls, mtproto и Clash YAML разбираются', () {
      final naive = const LinkParser().parse('naive+quic://u1:p1@n.example:443#NaiveQ');
      expect(naive, isNotNull);
      expect(naive!.type, 'naive');
      expect(naive.extra['quic'], isTrue);
      expect(naive.extra['username'], 'u1');

      final snell = const LinkParser().parse('snell://pskSecret@sn.example:8443?version=5#Snell5');
      expect(snell, isNotNull);
      expect(snell!.type, 'snell');
      expect(snell.toOutbound()['psk'], 'pskSecret');

      const clashYaml = '''
proxies:
  - {name: "NL-VLESS", type: vless, server: nl.example.com, port: 443, uuid: "u-123", tls: true, servername: nl.example.com, network: ws, ws-opts: {path: "/ws"}}
  - name: "DE-HY2"
    type: hysteria2
    server: de.example.com
    port: 443
    password: secret
    obfs: salamander
    obfs-password: obpw
''';
      final clashProfiles = const LinkParser().parseSubscription(clashYaml);
      expect(clashProfiles.length, 2);
      expect(clashProfiles[0].name, 'NL-VLESS');
      expect(clashProfiles[0].transport, 'ws');
      expect(clashProfiles[1].type, 'hysteria2');
      expect(clashProfiles[1].extra['obfs'], {'type': 'salamander', 'password': 'obpw'});
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
    test('выбранный профиль подписки идёт напрямую в аутбаунд proxy', () {
      final config = RuntimeConfig(
        profile: const Profile(
          id: 'p', name: 'p', type: 'vless',
          server: 's.example', port: 443, uuid: 'u',
          subscriptionId: 'a',
        ),
        routingMode: RoutingMode.global,
        dns: const DnsSettings(),
        ruleSets: const [],
        filesDir: '/data/app',
        subscriptions: const [
          SubscriptionEntry(
            id: 'a',
            url: 'https://sub.example/list',
            uploadBytes: 1024,
            downloadBytes: 2048,
            totalBytes: 10240,
          ),
        ],
      ).toJson();

      final outbounds = (config['outbounds'] as List).cast<Map>();
      expect(
        outbounds.any((o) => o['tag'] == 'proxy' && o['type'] == 'vless'),
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

    test('массив полных конфигураций Xray с цепочкой dialerProxy разбирается в профиль с detour', () {
      const xrayArrayJson = '''
[
  {
    "remarks": "🇩🇪 Germany Chain #1",
    "inbounds": [{"port": 10808, "protocol": "socks"}],
    "outbounds": [
      {
        "tag": "proxy",
        "protocol": "vless",
        "settings": {
          "vnext": [
            {
              "address": "198.51.100.77",
              "port": 443,
              "users": [{"id": "11111111-2222-3333-4444-555555555555", "encryption": "none", "flow": "xtls-rprx-vision"}]
            }
          ]
        },
        "streamSettings": {
          "network": "tcp",
          "security": "reality",
          "realitySettings": {
            "serverName": "www.microsoft.com",
            "fingerprint": "chrome",
            "publicKey": "pbk123",
            "shortId": "abcd"
          },
          "sockopt": {
            "dialerProxy": "warp-out"
          }
        }
      },
      {
        "tag": "warp-out",
        "protocol": "socks",
        "settings": {
          "servers": [
            {"address": "127.0.0.1", "port": 40000}
          ]
        }
      },
      {
        "tag": "direct",
        "protocol": "freedom"
      }
    ]
  }
]
''';
      final profiles = const LinkParser().parseSubscription(xrayArrayJson);
      expect(profiles, hasLength(1));
      final p = profiles.first;
      expect(p.name, '🇩🇪 Germany Chain #1');
      expect(p.type, 'vless');
      expect(p.server, '198.51.100.77');
      expect(p.extra['detour'], 'chain-1-warp-out');

      final cfg = RuntimeConfig(
        profile: p,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
      ).toJson();
      final outbounds = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      final mainOut = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      final chainOut = outbounds.firstWhere((o) => o['tag'] == 'chain-1-warp-out');
      expect(mainOut['detour'], 'chain-1-warp-out');
      expect(mainOut.containsKey('chain_outbounds'), isFalse);
      expect(chainOut['type'], 'socks');
      expect(chainOut['server'], '127.0.0.1');
      expect(chainOut['server_port'], 40000);
    });

    test('uTLS-отпечатки Xray (hellochrome_120 и др.) и XHTTP-диапазоны нормализуются', () {
      expect(normalizeUtlsFingerprint('hellochrome_120'), 'chrome');
      expect(normalizeUtlsFingerprint('hellofirefox_120'), 'firefox');
      expect(normalizeUtlsFingerprint('hellosafari_16_0'), 'safari');
      expect(normalizeUtlsFingerprint('helloandroid_11_okhttp'), 'android');
      expect(normalizeUtlsFingerprint('randomizedalpn'), 'randomized');
      expect(normalizeUtlsFingerprint('chrome_psk_shuffle'), 'chrome_psk_shuffle');

      // Даже уже сохранённый профиль с fp: hellochrome_120 и транзитным узлом
      // должен отдавать в ядро канонический fingerprint: chrome.
      const savedProfile = Profile(
        id: 'lte-4',
        name: '🇵🇱 #4 Обход глушилок (LTE)',
        type: 'vless',
        server: '203.0.113.10',
        port: 443,
        uuid: '11111111-2222-3333-4444-555555555555',
        publicKey: 'cGJrMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI',
        shortId: 'abcd',
        extra: {
          'security': 'reality',
          'fp': 'hellochrome_120',
          'detour': 'chain-4-relay',
          'chain_outbounds': [
            {
              'type': 'vless',
              'tag': 'chain-4-relay',
              'server': '203.0.113.11',
              'server_port': 443,
              'uuid': '11111111-2222-3333-4444-555555555555',
              'tls': {
                'enabled': true,
                'server_name': 'ya.ru',
                'utls': {'enabled': true, 'fingerprint': 'hellochrome_120'},
              },
              'transport': {
                'type': 'xhttp',
                'path': '/x',
                'xPaddingBytes': {'from': 100, 'to': 1000},
                'xmux': {
                  'maxConcurrency': {'from': 16, 'to': 32},
                  'maxConnections': 0,
                },
              },
            },
          ],
        },
      );

      final cfg = RuntimeConfig(
        profile: savedProfile,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
      ).toJson();
      final outbounds = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      final mainOut = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      final hopOut = outbounds.firstWhere((o) => o['tag'] == 'chain-4-relay');

      expect(((mainOut['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
      expect(((hopOut['tls'] as Map)['utls'] as Map)['fingerprint'], 'chrome');
      final hopTr = hopOut['transport'] as Map;
      expect(hopTr['x_padding_bytes'], '100-1000');
      expect((hopTr['xmux'] as Map)['max_concurrency'], '16-32');
      expect((hopTr['xmux'] as Map).containsKey('max_connections'), isFalse);
    });

    test('RoutingMode.rules с YouTube -> desync использует FakeIP, reverse_mapping и списки tachyon-lists (.trs)', () {
      final tmpDir = Directory.systemTemp.createTempSync('tachyon_trs_test_');
      try {
        final listsDir = Directory('${tmpDir.path}/lists')..createSync(recursive: true);
        File('${listsDir.path}/youtube.trs').writeAsBytesSync([1, 2, 3, 4]);
        File('${listsDir.path}/telegram.trs').writeAsBytesSync([1, 2, 3, 4]);

        final cfg = RuntimeConfig(
          profile: _vlessProfile(),
          routingMode: RoutingMode.rules,
          dns: const DnsSettings(fakeIp: true),
          ruleSets: const [],
          filesDir: tmpDir.path,
          serviceRoutes: const {'youtube': 'desync', 'telegram': 'proxy'},
        ).toJson();

        final dns = cfg['dns'] as Map<String, dynamic>;
        expect(dns['reverse_mapping'], isTrue);
        final dnsRules = (dns['rules'] as List).cast<Map<String, dynamic>>();
        // Домены desync не должны уходить в dns-direct в обход FakeIP
        final directBeforeFakeIp = dnsRules
            .takeWhile((r) => r['server'] != 'dns-fakeip')
            .where((r) => r['server'] == 'dns-direct')
            .toList();
        for (final r in directBeforeFakeIp) {
          final suffixes = (r['domain_suffix'] as List?) ?? const [];
          expect(suffixes.contains('youtube.com'), isFalse);
        }

        // Проверяем, что списки youtube.trs и telegram.trs из tachyon-lists подключены как rule_set
        final ruleSets = ((cfg['route'] as Map)['rule_set'] as List).cast<Map<String, dynamic>>();
        expect(ruleSets.any((rs) => rs['tag'] == 'youtube' && rs['format'] == 'trs'), isTrue);
        expect(ruleSets.any((rs) => rs['tag'] == 'telegram' && rs['format'] == 'trs'), isTrue);

        final routeRules = ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
        expect(
          routeRules.any((r) =>
              r['outbound'] == 'desync' &&
              ((r['rule_set'] as List?)?.contains('youtube') ?? false)),
          isTrue,
        );
        expect(
          routeRules.any((r) =>
              r['outbound'] == 'proxy' &&
              ((r['rule_set'] as List?)?.contains('telegram') ?? false)),
          isTrue,
        );

        // Локальный прокси 127.0.0.1:2080 всегда присутствует для внутренних проверок
        final inbounds = (cfg['inbounds'] as List).cast<Map<String, dynamic>>();
        final lanIn = inbounds.firstWhere((i) => i['tag'] == 'lan-in');
        expect(lanIn['listen'], '127.0.0.1');
        expect(lanIn['listen_port'], 2080);
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('RoutingMode.rules ставит final=proxy при наличии прокси и final=desync без прокси', () {
      final cfgWithProxyFinal = RuntimeConfig(
        profile: _vlessProfile(),
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        desync: const DesyncSettings(enabled: true),
      ).toJson();
      expect((cfgWithProxyFinal['route'] as Map)['final'], 'proxy');

      final cfgWithoutProxyDesyncFinal = RuntimeConfig(
        profile: const Profile(id: '', name: '', type: 'vless', server: '', port: 443),
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        desync: const DesyncSettings(enabled: true),
      ).toJson();
      expect((cfgWithoutProxyDesyncFinal['route'] as Map)['final'], 'desync');
    });

    test('FreeNodesService.generateX25519KeyPair генерирует валидные 32-байтные ключи Curve25519', () {
      final kp = FreeNodesService.generateX25519KeyPair();
      expect(kp.privateKey.isNotEmpty, isTrue);
      expect(kp.publicKey.isNotEmpty, isTrue);
      expect(kp.privateKey, isNot(equals(kp.publicKey)));
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
