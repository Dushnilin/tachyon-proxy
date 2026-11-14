import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_proxy/core/models/app_rules.dart';
import 'package:tachyon_proxy/core/models/runtime_config.dart';
import 'package:tachyon_proxy/core/models/tunnel_state.dart';
import 'package:tachyon_proxy/core/services/dns_benchmark.dart';
import 'package:tachyon_proxy/core/services/link_parser.dart';
import 'package:tachyon_proxy/core/services/settings_store.dart';

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
      expect(awg.fullTransportLabel, 'AMNEZIAWG 2.0 · UDP');
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

    test('AmneziaWG 2.0, 3.0 и 3.1 .conf файлы разбираются и сериализуются в endpoints', () {
      const conf31 = '''
# Helsinki AWG 3.1
[Interface]
PrivateKey = priv31Key===
Address = 10.10.0.2/32, fd00::2/128
MTU = 1360
Jc = 6
Jmin = 60
Jmax = 500
S1 = 15
S2 = 25
S3 = 32
S4 = 16
H1 = 100000-200000
H2 = 300000-400000
H3 = 500000-600000
H4 = 700000-800000
I2 = <b 0xdeadbeef><r 8>
HeaderProtectionKey = aHBrMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=
ContentPaddingAddition = 64
ID = 0x1234
IP = dns
IB = dGVzdA==
RekeyAfterTime = 110-130
RekeyTimeout = 4-7
RejectAfterTime = 175-185
ITime = 20-35
MaxHandshakeAttempts = 12
RandomTrailers = true
DisableCookies = 1

[Peer]
PublicKey = pub31Key===
PresharedKey = psk31Key===
Endpoint = 198.51.100.77:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 15-30
''';

      const parser = LinkParser();
      expect(parser.looksLikeWireGuardConf(conf31), isTrue);
      final profiles = parser.parseWireGuardConfAll(conf31, nameOverride: 'Helsinki AWG 3.1');
      expect(profiles.length, 1);
      final p = profiles.first;
      expect(p.name, 'Helsinki AWG 3.1');
      expect(p.isAmneziaWg, isTrue);
      expect(p.awgVersionLabel, 'AMNEZIAWG 3.1');
      expect(p.fullTransportLabel, 'AMNEZIAWG 3.1 · UDP');
      expect(p.extra['s3'], 32);
      expect(p.extra['s4'], 16);
      expect(p.extra['h1'], '100000-200000');
      expect(p.extra['header_protection_key'], 'aHBrMTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=');
      expect(p.extra['content_padding_addition'], 64);
      expect(p.extra['random_trailers'], isTrue);
      expect(p.extra['disable_cookies'], isTrue);
      expect(p.extra['persistent_keepalive_interval'], '15-30');

      final endpoint = p.toWireGuardEndpoint(tag: 'proxy');
      expect(endpoint['type'], 'wireguard');
      expect(endpoint.containsKey('persistent_keepalive_interval'), isFalse);
      final peer = (endpoint['peers'] as List).single as Map<String, dynamic>;
      expect(peer['persistent_keepalive_interval'], '15-30');
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
      expect(endpoint['random_trailers'], isTrue);
      expect(endpoint['disable_cookies'], isTrue);
      // При наличии IP/ID/IB поле i1 исключается из сериализованного endpoint по спецификации AWG 3.0
      expect(endpoint['ip'], 'dns');
      expect(endpoint.containsKey('i1'), isFalse);
    });

    test('FPTN-токен распознаётся как групповая подписка с сохранением выбранных серверов', () {
      const fptnJson = '''
{
  "version": 1,
  "service_name": "MyFptnService",
  "username": "user1",
  "password": "pw1",
  "servers": [
    {"name": "NL-1", "host": "198.51.100.1", "port": 443, "md5_fingerprint": "aa"},
    {"name": "DE-1", "host": "198.51.100.2", "port": 443, "md5_fingerprint": "bb"}
  ]
}
''';
      final token = 'fptn:${_base64(fptnJson)}';
      const parser = LinkParser();
      expect(parser.isFptnPayload(token), isTrue);
      expect(parser.extractFptnServiceName(token), 'MyFptnService');

      final parsed = parser.parseSubscription(token, subscriptionId: 's_fptn');
      expect(parsed.length, 2);
      expect(parsed.every((p) => p.type == 'fptn' && p.subscriptionId == 's_fptn'), isTrue);

      final sub = SubscriptionEntry(
        id: 's_fptn',
        url: token,
        name: 'MyFptnService',
        selectedServerKeys: const ['198.51.100.1:443'],
      );
      expect(sub.isFptnToken, isTrue);
      final restored = SubscriptionEntry.fromJson(sub.toJson());
      expect(restored.isFptnToken, isTrue);
      expect(restored.selectedServerKeys, ['198.51.100.1:443']);
    });

    test('Фильтры исключения стран, протоколов и пользовательский URL балансировщика применяются корректно', () {
      const nlVless = Profile(
        id: 'n1',
        name: '🇳🇱 Нидерланды #1',
        type: 'vless',
        server: 'nl.example.com',
        port: 443,
        subscriptionId: 'sub1',
      );
      const ruVless = Profile(
        id: 'n2',
        name: '🇷🇺 Москва #1',
        type: 'vless',
        server: 'ru.example.com',
        port: 443,
        subscriptionId: 'sub1',
      );
      const deHy2 = Profile(
        id: 'n3',
        name: '🇩🇪 Франкфурт HY2',
        type: 'hysteria2',
        server: 'de.example.com',
        port: 443,
        subscriptionId: 'sub1',
      );

      expect(
        BalancerSettings.matchesFilter(
          ruVless,
          excludedCountries: const ['RU'],
          excludedProtocols: const [],
        ),
        isFalse,
      );
      expect(
        BalancerSettings.matchesFilter(
          deHy2,
          excludedCountries: const [],
          excludedProtocols: const ['hysteria2'],
        ),
        isFalse,
      );
      expect(
        BalancerSettings.matchesFilter(
          nlVless,
          excludedCountries: const ['RU'],
          excludedProtocols: const ['hysteria2'],
        ),
        isTrue,
      );

      const autoProfile = Profile(
        id: 'auto:sub1',
        name: 'Auto Sub1',
        type: 'urltest',
        server: 'auto',
        port: 0,
        subscriptionId: 'sub1',
      );
      const subs = [
        SubscriptionEntry(
          id: 'sub1',
          url: 'https://example.com/sub',
          excludedCountries: ['RU'],
        ),
      ];
      const balancer = BalancerSettings(
        url: 'https://cp.cloudflare.com/generate_204',
        excludedProtocols: ['hysteria2'],
      );

      final candidates = RuntimeConfig.resolveAutoCandidates(
        autoProfile,
        const [nlVless, ruVless, deHy2],
        subscriptions: subs,
        balancer: balancer,
      );
      expect(candidates.map((p) => p.id).toList(), ['n1']);

      final cfg = RuntimeConfig(
        profile: autoProfile,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        extraProfiles: const [nlVless, ruVless, deHy2],
        allSubscriptions: subs,
        balancer: balancer,
      );

      final json = cfg.toJson();
      final outbounds = (json['outbounds'] as List).cast<Map<String, dynamic>>();
      final proxyOut = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(proxyOut['url'], 'https://cp.cloudflare.com/generate_204');
      expect(proxyOut['outbounds'], ['auto-srv-0']);
    });

    test('Сервис ru -> direct добавляет package_name российских приложений и оба списка ru_domains / ru_only_inside', () {
      final tmpDir = Directory.systemTemp.createTempSync('tachyon_ru_test_');
      try {
        final listsDir = Directory('${tmpDir.path}/lists')..createSync(recursive: true);
        File('${listsDir.path}/ru_domains.trs').writeAsBytesSync([1, 2, 3, 4]);
        File('${listsDir.path}/ru_only_inside.trs').writeAsBytesSync([1, 2, 3, 4]);

        final cfg = RuntimeConfig(
          profile: _vlessProfile(),
          routingMode: RoutingMode.rules,
          dns: const DnsSettings(fakeIp: true),
          ruleSets: const [],
          filesDir: tmpDir.path,
          serviceRoutes: const {'ru': 'direct'},
        ).toJson();

        final ruleSets = ((cfg['route'] as Map)['rule_set'] as List).cast<Map<String, dynamic>>();
        expect(ruleSets.any((rs) => rs['tag'] == 'ru_domains'), isTrue);
        expect(ruleSets.any((rs) => rs['tag'] == 'ru_only_inside'), isTrue);

        final routeRules = ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
        expect(
          routeRules.any((r) =>
              r['outbound'] == 'direct' &&
              ((r['package_name'] as List?)?.contains('ru.sberbankmobile') ?? false)),
        isTrue,
        );
      } finally {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test('XHTTP sc_max_each_post_bytes и диапазоны с плавающей точкой ("1000000.0") нормализуются в целые строки', () {
      final tr = normalizeXhttpTransport({
        'type': 'xhttp',
        'sc_max_each_post_bytes': '1000000.0',
        'sc_min_posts_interval_ms': '30.0',
        'x_padding_bytes': '100.0-500.0',
        'sc_stream_up_server_secs': [20.0, 80.0],
        'sc_max_concurrent_posts': '4.0',
      });
      expect(tr['sc_max_each_post_bytes'], '1000000');
      expect(tr['sc_min_posts_interval_ms'], '30');
      expect(tr['x_padding_bytes'], '100-500');
      expect(tr['sc_stream_up_server_secs'], '20-80');
      expect(tr['sc_max_concurrent_posts'], 4);
    });

    test('Глобальный балансировщик auto:all строго разделяет подписки по networkScope (Wi-Fi vs LTE) и читает оба ключа subscriptionId', () {
      final fptnProfile = Profile.fromJson({
        'id': 'fptn-fi-1',
        'name': 'Russia-Premium (Finland)',
        'type': 'fptn',
        'server': '198.51.100.10',
        'port': 443,
        'subscription_id': 'sub_fptn',
      });
      expect(fptnProfile.subscriptionId, 'sub_fptn');

      const wifiProfile = Profile(
        id: 'wifi-nl-1',
        name: '🇳🇱 Netherlands Wi-Fi',
        type: 'vless',
        server: '203.0.113.20',
        port: 443,
        subscriptionId: 'sub_wifi',
      );
      const autoAll = Profile(
        id: 'auto:all',
        name: 'Global Auto',
        type: 'urltest',
        server: 'auto',
        port: 0,
      );
      const subs = [
        SubscriptionEntry(
          id: 'sub_fptn',
          url: 'fptn://FPTN',
          name: 'FPTN',
          networkScope: 'cellular',
        ),
        SubscriptionEntry(
          id: 'sub_wifi',
          url: 'https://example.com/sub',
          name: 'Main Sub',
          networkScope: 'wifi',
        ),
      ];

      final wifiCandidates = RuntimeConfig.resolveAutoCandidates(
        autoAll,
        [fptnProfile, wifiProfile],
        activeNetworkType: 'wifi',
        subscriptions: subs,
      );
      expect(wifiCandidates.map((p) => p.id).toList(), ['wifi-nl-1']);

      final lteCandidates = RuntimeConfig.resolveAutoCandidates(
        autoAll,
        [fptnProfile, wifiProfile],
        activeNetworkType: 'cellular',
        subscriptions: subs,
      );
      expect(lteCandidates.map((p) => p.id).toList(), ['fptn-fi-1']);
    });

    test('normalizeXhttpTransport очищает нулевой session_length и валидирует пространство ID', () {
      final zeroStr = normalizeXhttpTransport({
        'type': 'xhttp',
        'path': '/xhttp',
        'session_length': '0',
        'sc_max_each_post_bytes': '0-0',
        'sc_max_concurrent_posts': 0,
        'xmux': {
          'max_connections': '0',
          'h_keep_alive_period': 0,
        },
      });
      expect(zeroStr.containsKey('session_length'), isFalse);
      expect(zeroStr.containsKey('session_table'), isFalse);
      expect(zeroStr.containsKey('sc_max_each_post_bytes'), isFalse);
      expect(zeroStr.containsKey('sc_max_concurrent_posts'), isFalse);
      expect(zeroStr.containsKey('xmux'), isFalse);

      final zeroRange = normalizeXhttpTransport({
        'type': 'xhttp',
        'session_length': '0-14',
      });
      expect(zeroRange['session_length'], '1-14');
      expect(zeroRange['session_table'], 'hex');

      final smallHex = normalizeXhttpTransport({
        'type': 'xhttp',
        'session_length': 4,
      });
      expect(smallHex['session_length'], '4-6');
      expect(smallHex['session_table'], 'hex');
    });

    test('объединённая группа подписок включает профили из выбранных подписок и работает параллельно с ними', () {
      const pSub1 = Profile(
        id: 'p1',
        name: '🇳🇱 NL Sub1',
        type: 'vless',
        server: 'nl1.example.com',
        port: 443,
        uuid: '11111111-2222-3333-4444-555555555555',
        subscriptionId: 'sub1',
      );
      const pSub2De = Profile(
        id: 'p2',
        name: '🇩🇪 DE Sub2',
        type: 'vless',
        server: 'de2.example.com',
        port: 443,
        uuid: '11111111-2222-3333-4444-555555555555',
        subscriptionId: 'sub2',
      );
      const pSub2Fi = Profile(
        id: 'p3',
        name: '🇫🇮 FI Sub2',
        type: 'hysteria2',
        server: 'fi2.example.com',
        port: 443,
        password: 'pw',
        subscriptionId: 'sub2',
      );
      const pStandalone = Profile(
        id: 'p4',
        name: '🇸🇪 SE Standalone',
        type: 'vless',
        server: 'se.example.com',
        port: 443,
        uuid: '11111111-2222-3333-4444-555555555555',
        subscriptionId: '',
      );

      const subs = [
        SubscriptionEntry(
          id: 'group_1',
          url: 'group://merged',
          name: 'Общая группа',
          mergedSubscriptionIds: ['sub1', 'sub2', '__standalone__'],
          excludedCountries: ['DE'],
        ),
        SubscriptionEntry(
          id: 'sub1',
          url: 'https://example.com/1',
          name: 'Подписка 1',
          networkScope: 'wifi',
        ),
        SubscriptionEntry(
          id: 'sub2',
          url: 'https://example.com/2',
          name: 'Подписка 2',
          networkScope: 'cellular',
        ),
      ];

      final settings = AppSettings(
        profiles: const [pSub1, pSub2De, pSub2Fi, pStandalone],
        subscriptions: subs,
      );

      // Отдельные подписки продолжают возвращать свои профили
      expect(settings.profilesForSubscription('sub1').map((p) => p.id).toList(), ['p1']);
      expect(settings.profilesForSubscription('sub2').map((p) => p.id).toList(), ['p2', 'p3']);
      // Объединённая группа включает все входящие подписки и отдельные серверы
      expect(
        settings.profilesForSubscription('group_1').map((p) => p.id).toList(),
        ['p1', 'p2', 'p3', 'p4'],
      );

      // Автобалансировщик группы применяет собственные фильтры стран (исключена DE)
      // и игнорирует индивидуальный networkScope дочерних подписок при явном выборе группы
      const autoGroup = Profile(
        id: 'auto:group_1',
        name: 'Авто (Общая группа)',
        type: 'balancer',
        server: 'auto',
        port: 0,
        subscriptionId: 'group_1',
      );
      final groupCandidates = RuntimeConfig.resolveAutoCandidates(
        autoGroup,
        settings.profiles,
        activeNetworkType: 'wifi',
        subscriptions: subs,
      );
      expect(groupCandidates.map((p) => p.id).toList(), ['p1', 'p3', 'p4']);

      // Проверка фильтрации по регулярному выражению (includeRegex / excludeRegex)
      final regexCandidates = RuntimeConfig.resolveAutoCandidates(
        autoGroup,
        settings.profiles,
        activeNetworkType: 'cellular',
        subscriptions: [
          subs.first.copyWith(
            includeRegex: 'Sub2|Standalone',
            excludeRegex: 'FI',
          ),
          ...subs.skip(1),
        ],
      );
      expect(regexCandidates.map((p) => p.id).toList(), ['p4']);
    });

    test('NaiveProxy QUIC сохраняет транспорт quic при парсинге из ядра и JSON, а правила Списков и LAN маршрутизируются через подписку или напрямую', () {
      const parser = LinkParser();
      final parsedNodes = parser.parseEngineNodes([
        {
          'type': 'naive',
          'tag': '+Латвия',
          'server': 'edge.commonnet.work',
          'server_port': 12443,
          'username': 'u',
          'password': 'p',
          'quic': true,
          'tls': {'enabled': true, 'server_name': 'edge.commonnet.work'},
        },
      ], [
        '+Латвия',
      ], subscriptionId: 'sub_naive');

      expect(parsedNodes, hasLength(1));
      final naiveProf = parsedNodes.first;
      expect(naiveProf.type, 'naive');
      expect(naiveProf.transport, 'quic');
      expect(naiveProf.fullTransportLabel, 'NAIVE · TLS · QUIC');
      expect(naiveProf.toOutbound()['quic'], isTrue);

      // Даже если сохранённый профиль имел transport: tcp при extra.quic == true, Profile.fromJson восстанавливает quic
      final restored = Profile.fromJson({
        ...naiveProf.toJson(),
        'transport': 'tcp',
      });
      expect(restored.transport, 'quic');
      expect(restored.fullTransportLabel, 'NAIVE · TLS · QUIC');

      const mainProfile = Profile(
        id: 'main_vless',
        name: 'Main VLESS',
        type: 'vless',
        server: 'main.example.com',
        port: 443,
        uuid: '11111111-2222-3333-4444-555555555555',
      );
      const subs = [
        SubscriptionEntry(
          id: 'sub_naive',
          url: 'https://example.com/naive',
          name: 'Commonnet · Naive',
        ),
      ];
      final cfg = RuntimeConfig(
        profile: mainProfile,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [
          RuleSetEntry(
            id: 'ai_all',
            title: 'AI Services',
            path: '/tmp/ai_all.trs',
            action: 'sub:sub_naive',
            enabled: true,
          ),
        ],
        serviceRoutes: const {'lan': 'direct'},
        subscriptions: subs,
        allSubscriptions: subs,
        extraProfiles: [mainProfile, naiveProf],
      ).toJson();

      final outbounds = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      final subGrp = outbounds.firstWhere((o) => o['tag'] == 'sub-grp-sub_naive');
      expect(subGrp['type'], 'urltest');
      expect(subGrp['outbounds'], ['srv-${naiveProf.id}']);
      expect(outbounds.any((o) => o['tag'] == 'srv-${naiveProf.id}' && o['type'] == 'naive'), isTrue);

      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(
        rules.any((r) =>
            (r['rule_set'] as List?)?.contains('ai_all') == true &&
            r['outbound'] == 'sub-grp-sub_naive'),
        isTrue,
      );
      expect(
        rules.any((r) =>
            (r['ip_cidr'] as List?)?.contains('192.168.0.0/16') == true &&
            r['outbound'] == 'direct'),
        isTrue,
      );
    });

    test('LinkParser распознаёт naive+h3://, naive+http2:// и Clash YAML type: naive с QUIC', () {
      const parser = LinkParser();
      final h3 = parser.parse(
        'naive+h3://user:pass@edge.commonnet.work:12443?sni=edge.commonnet.work#%2B%D0%9B%D0%B0%D1%82%D0%B2%D0%B8%D1%8F',
      );
      expect(h3, isNotNull);
      expect(h3!.type, 'naive');
      expect(h3.transport, 'quic');
      expect(h3.extra['quic'], isTrue);
      expect(h3.toOutbound()['quic'], isTrue);

      final h2 = parser.parse(
        'naive+http2://user:pass@edge.commonnet.work:12443?sni=edge.commonnet.work#LatviaH2',
      );
      expect(h2, isNotNull);
      expect(h2!.type, 'naive');
      expect(h2.transport, 'tcp');
      expect(h2.toOutbound()['quic'], isNot(isTrue));

      final clashProfiles = parser.parseMany('''
proxies:
  - name: "+Латвия QUIC"
    type: naive
    server: edge.commonnet.work
    port: 12443
    username: u
    password: p
    quic: true
''');
      expect(clashProfiles, hasLength(1));
      expect(clashProfiles.first.type, 'naive');
      expect(clashProfiles.first.transport, 'quic');
      expect(clashProfiles.first.toOutbound()['quic'], isTrue);
    });

    test('Мульти-URL балансировщик создаёт urltest-svc-* группы, правила маршрутизации по сервисам и включает Clash API', () {
      const p1 = Profile(
        id: 'srv1',
        name: 'UAE #26',
        type: 'vless',
        server: 'uae.example.com',
        port: 443,
        uuid: '11111111-1111-1111-1111-111111111111',
        transport: 'grpc',
      );
      const p2 = Profile(
        id: 'srv2',
        name: 'CH #15',
        type: 'vless',
        server: 'ch.example.com',
        port: 443,
        uuid: '22222222-2222-2222-2222-222222222222',
        transport: 'xhttp',
      );
      const autoProfile = Profile(
        id: 'auto:all',
        name: 'Автовыбор',
        type: 'balancer',
        server: 'auto',
        port: 0,
      );

      const balancer = BalancerSettings(
        mode: 'stability',
        multiServiceEnabled: true,
        multiServices: ['youtube', 'telegram', 'instagram', 'https'],
      );
      final restoredBalancer = BalancerSettings.fromJson(balancer.toJson());
      expect(restoredBalancer.multiServiceEnabled, isTrue);
      expect(
        restoredBalancer.multiServices,
        ['youtube', 'telegram', 'instagram', 'https'],
      );

      final cfg = RuntimeConfig(
        profile: autoProfile,
        balancer: restoredBalancer,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        serviceRoutes: const {
          'instagram': 'profile:srv1',
        },
        extraProfiles: const [p1, p2],
      ).toJson();

      final outbounds = (cfg['outbounds'] as List).cast<Map<String, dynamic>>();
      final proxyPool = outbounds.firstWhere((o) => o['tag'] == 'proxy');
      expect(proxyPool['type'], 'urltest');
      expect(proxyPool['outbounds'], ['auto-srv-0', 'auto-srv-1']);

      final ytPool = outbounds.firstWhere((o) => o['tag'] == 'urltest-svc-youtube');
      expect(ytPool['type'], 'urltest');
      expect(ytPool['url'], 'https://www.youtube.com/generate_204');
      expect(ytPool['outbounds'], ['auto-srv-0', 'auto-srv-1']);

      final tgPool = outbounds.firstWhere((o) => o['tag'] == 'urltest-svc-telegram');
      expect(tgPool['type'], 'urltest');
      expect(tgPool['url'], 'https://core.telegram.org/favicon.ico');

      final igPool = outbounds.firstWhere((o) => o['tag'] == 'urltest-svc-instagram');
      expect(igPool['type'], 'urltest');
      expect(igPool['url'], 'https://www.instagram.com/robots.txt');

      final rules = ((cfg['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      // YouTube и Telegram маршрутизируются в свои urltest-svc-* пулы
      expect(
        rules.any((r) => r['outbound'] == 'urltest-svc-youtube'),
        isTrue,
      );
      expect(
        rules.any((r) => r['outbound'] == 'urltest-svc-telegram'),
        isTrue,
      );
      // Instagram закреплён вручную на profile:srv1 -> srv-srv1
      expect(
        rules.any((r) => r['outbound'] == 'srv-srv1'),
        isTrue,
      );

      final clashApi = (cfg['experimental'] as Map?)?['clash_api'] as Map?;
      expect(clashApi?['external_controller'], '127.0.0.1:19090');
    });

    test('По умолчанию YouTube и Discord идут через прокси-сервер (WireGuard / VLESS), WireGuard получает MTU 1280, а VLESS — xudp', () {
      const defaults = AppSettings();
      expect(defaults.serviceRoutes, {'ru': 'direct'});
      expect(defaults.mtu, 1400);

      // Миграция старых дефолтов (youtube/discord -> desync, mtu -> 9000) при обновлении приложения
      final migrated = AppSettings.fromJson({
        'serviceRoutes': {
          'youtube': 'desync',
          'discord': 'desync',
          'ru': 'direct',
        },
        'mtu': 9000,
      });
      expect(migrated.serviceRoutes, {'ru': 'direct'});
      expect(migrated.mtu, 1400);

      // Если пользователь явно сохранил настройки в v0.0.20+, его выбор сохраняется
      final explicit = AppSettings.fromJson({
        'serviceRoutes': {
          'youtube': 'desync',
          'discord': 'desync',
          'ru': 'direct',
        },
        'serviceRoutesV20': true,
        'mtu': 9000,
      });
      expect(explicit.serviceRoutes['youtube'], 'desync');
      expect(explicit.mtu, 9000);

      // Профиль WireGuard без явного MTU получает безопасный MTU 1280 и на endpoint, и на tun-in,
      // а YouTube не перехватывается в desync мимо WireGuard
      final wgProfile = const LinkParser().parse(
        'wireguard://privKey123@198.51.100.10:51820?publickey=pubKey456&address=10.8.0.2/32#WG-Server',
      )!;
      final wgConfig = RuntimeConfig(
        profile: wgProfile,
        routingMode: RoutingMode.rules,
        dns: defaults.dns,
        ruleSets: const [],
        mtu: defaults.mtu,
        serviceRoutes: defaults.serviceRoutes,
      );
      expect(wgConfig.effectiveTunMtu, 1280);
      final wgJson = wgConfig.toJson();
      final endpoints = (wgJson['endpoints'] as List).cast<Map<String, dynamic>>();
      expect(endpoints.single['mtu'], 1280);
      final inbounds = (wgJson['inbounds'] as List).cast<Map<String, dynamic>>();
      expect(inbounds.firstWhere((i) => i['tag'] == 'tun-in')['mtu'], 1280);
      final wgRules = ((wgJson['route'] as Map)['rules'] as List).cast<Map<String, dynamic>>();
      expect(wgRules.any((r) => r['outbound'] == 'desync'), isFalse);
      expect((wgJson['route'] as Map)['final'], 'proxy');

      // Профиль VLESS получает packet_encoding: xudp и MTU 1400
      final vlessOut = _vlessProfile().toOutbound();
      expect(vlessOut['packet_encoding'], 'xudp');
    });
  });

  group('интероп с tachyon-core', () {
    final parser = LinkParser();

    test('naive outbound не содержит tls.insecure и tls.disable_sni', () {
      final fromUri = parser.parse(
        'naive+https://u:p@edge.example:443?insecure=1&sni=edge.example#Naive1',
      );
      expect(fromUri, isNotNull);
      final uriTls = fromUri!.toOutbound()['tls'] as Map<String, dynamic>;
      expect(uriTls.containsKey('insecure'), isFalse);
      expect(uriTls.containsKey('disable_sni'), isFalse);

      final manual = Profile(
        id: 'n1',
        name: 'n1',
        type: 'naive',
        server: 'edge.example',
        port: 443,
        password: 'p',
        allowInsecure: true,
        extra: {
          'username': 'u',
          'tls': {'enabled': true, 'insecure': true, 'disable_sni': true},
        },
      );
      final out = manual.toOutbound();
      final tls = out['tls'] as Map<String, dynamic>;
      expect(tls['enabled'], isTrue);
      expect(tls.containsKey('insecure'), isFalse);
      expect(tls.containsKey('disable_sni'), isFalse);
    });

    test('snell сохраняет версии 4/5/6 и структурированный obfs для v4/v5', () {
      final v5 = parser.parse(
        'snell://psk-5@snell.example:6160?version=5&obfs=tls&obfs-host=bing.com&uot=1#Snell5',
      );
      expect(v5, isNotNull);
      final out5 = v5!.toOutbound();
      expect(out5['version'], 5);
      expect(out5['obfs'], {'mode': 'tls', 'host': 'bing.com'});
      expect(out5['udp_over_tcp'], isTrue);
      expect(out5.containsKey('tls'), isFalse);

      final v6 = parser.parse('snell://psk-6@snell.example:6161?version=6&mode=quic#Snell6');
      expect(v6, isNotNull);
      final out6 = v6!.toOutbound();
      expect(out6['version'], 6);
      expect(out6['mode'], 'quic');
      expect(out6.containsKey('obfs'), isFalse);
      expect(out6.containsKey('udp_over_tcp'), isFalse);
    });

    test('wdtt / qwdtt / csqtt / sudoku разбираются и сериализуются без невалидного tls', () {
      final qwdtt = parser.parse(
        'qwdtt://config?ip=198.51.100.10&dtls=56000&raw=56003&mode=wg&obfs=video&hashes=h1,h2&streams=8&pass=a&b@c#QWDTT',
      );
      expect(qwdtt, isNotNull);
      expect(qwdtt!.type, 'wdtt');
      expect(qwdtt.password, 'a&b@c');
      expect(qwdtt.hasTls, isFalse);
      final qOut = qwdtt.toOutbound();
      expect(qOut.containsKey('tls'), isFalse);
      expect(qOut['server_port'], 56000);
      expect(qOut['raw_port'], 56003);
      expect(qOut['obfs'], 'video');
      expect(qOut['hashes'], ['h1', 'h2']);
      expect(qOut['workers'], 8);

      final csqtt = parser.parse(
        'csqtt://connect?v=2&host=198.51.100.20&peer=46000&password=pw1&hashes=a+b&workers=4&srtp_mode=auto#CS',
      );
      expect(csqtt, isNotNull);
      expect(csqtt!.toOutbound()['mode'], 'csqtt');
      expect(csqtt.toOutbound()['hashes'], ['a', 'b']);

      final colonWdtt = parser.parse('wdtt://198.51.100.30:56000:51820:40000:pw2:h1,h2#Colon');
      expect(colonWdtt, isNotNull);
      expect(colonWdtt!.toOutbound()['wg_port'], 51820);
      expect(colonWdtt.toOutbound()['local_port'], 40000);

      final roundTrip = parser.parse(qwdtt.toShareUri());
      expect(roundTrip, isNotNull);
      expect(roundTrip!.type, 'wdtt');
      expect(roundTrip.password, 'a&b@c');

      final sudoku = parser.parse(
        'sudoku://key-123@srv.example:8443?table_type=prefer_ascii&disable_http_mask=true&http_mask_mode=auto&security=tls&sni=srv.example#Sudoku1',
      );
      expect(sudoku, isNotNull);
      expect(sudoku!.type, 'sudoku');
      final sOut = sudoku.toOutbound();
      expect(sOut['uuid'], 'key-123');
      expect(sOut['table_type'], 'prefer_ascii');
      expect(sOut['disable_http_mask'], isTrue);
      expect((sOut['tls'] as Map)['enabled'], isTrue);
    });

    test('vpn:// Amnezia qCompress контейнер корректно распаковывается', () {
      const wgIni = '[Interface]\n'
          'PrivateKey = privkey123=\n'
          'Address = 10.7.0.2/32\n'
          'MTU = 1360\n'
          'Jc = 4\n'
          '[Peer]\n'
          'PublicKey = pubkey456=\n'
          'Endpoint = 198.51.100.40:51820\n';
      final rawBytes = utf8.encode(wgIni);
      final compressed = zlib.encode(rawBytes);
      final header = ByteData(4)..setUint32(0, rawBytes.length, Endian.big);
      final payload = [...header.buffer.asUint8List(), ...compressed];
      final link = 'vpn://${base64Url.encode(payload).replaceAll('=', '')}#AmneziaNode';

      final list = parser.parseMany(link);
      expect(list, hasLength(1));
      expect(list.first.type, 'wireguard');
      expect(list.first.server, '198.51.100.40');
      expect(list.first.extra['jc'], 4);
      expect(list.first.extra['mtu'], 1360);
    });

    test('Surge и Quantumult X строки разбираются в профили', () {
      const text = 'HK-SS = ss, 203.0.113.1, 8388, encrypt-method=aes-256-gcm, password=secret, obfs=tls, obfs-host=cdn.example\n'
          'vmess = 203.0.113.2:443, method=chacha20-ietf-poly1305, password=uuid-qx, obfs=ws, obfs-host=ws.example, obfs-uri=/ws, tls=true, tag=QX-Node';
      final list = parser.parseMany(text);
      expect(list, hasLength(2));
      expect(list[0].type, 'shadowsocks');
      expect(list[0].name, 'HK-SS');
      expect(list[0].extra['plugin'], 'obfs-local');
      expect(list[1].type, 'vmess');
      expect(list[1].name, 'QX-Node');
      expect(list[1].transport, 'ws');
    });

    test('JSON-обёртки, Clash-в-JSON, удаление висячего detour и Clash YAML dialer-proxy + hy2 gecko', () {
      final wrappedJson = jsonEncode({
        'data': {
          'nodes': [
            {
              'name': 'ClashJson',
              'type': 'ss',
              'server': '203.0.113.5',
              'port': 8388,
              'cipher': '2022-blake3-aes-128-gcm',
              'password': 'pw',
            },
          ],
        },
      });
      final wrappedProfiles = parser.parseMany(wrappedJson);
      expect(wrappedProfiles, hasLength(1));
      expect(wrappedProfiles.first.type, 'shadowsocks');
      expect(wrappedProfiles.first.port, 8388);

      final danglingCfg = jsonEncode({
        'outbounds': [
          {
            'type': 'vless',
            'tag': 'Main',
            'server': '203.0.113.6',
            'server_port': 443,
            'uuid': 'u1',
            'detour': 'direct',
          },
          {'type': 'direct', 'tag': 'direct'},
        ],
      });
      final cleaned = parser.parseMany(danglingCfg);
      expect(cleaned, hasLength(1));
      expect(cleaned.first.toOutbound().containsKey('detour'), isFalse);

      const clashYaml = '''
proxies:
  - name: Relay
    type: socks5
    server: 198.51.100.1
    port: 1080
  - name: HyGecko
    type: hy2
    server: 198.51.100.2
    port: 443
    password: hy-pw
    obfs: gecko
    obfs-password: g-pw
    packet-size: 512-1200
    hop-interval: 30
    up: 100 Mbps
    down: 200 Mbps
    dialer-proxy: Relay
  - name: TuicNode
    type: tuic
    server: 198.51.100.3
    port: 443
    uuid: u-tuic
    password: p-tuic
    reduce-rtt: true
    heartbeat-interval: 10000
''';
      final clashList = parser.parseMany(clashYaml);
      expect(clashList, hasLength(3));
      final hy = clashList.firstWhere((p) => p.name == 'HyGecko');
      final hyOut = hy.toOutbound();
      expect(hyOut['hop_interval'], '30s');
      expect(hyOut['up_mbps'], 100);
      expect(hyOut['down_mbps'], 200);
      expect(hyOut['obfs'], {
        'type': 'gecko',
        'password': 'g-pw',
        'min_packet_size': 512,
        'max_packet_size': 1200,
      });
      expect(hyOut['detour'], isNotNull);
      expect(hy.extra['chain_outbounds'], isA<List>());

      final tuicOut = clashList.firstWhere((p) => p.name == 'TuicNode').toOutbound();
      expect(tuicOut['zero_rtt_handshake'], isTrue);
      expect(tuicOut['heartbeat'], '10s');
    });

    test('MTProto ee-префикс извлекает SNI и auto: группа с WireGuard ограничивает TUN MTU', () {
      const domainHex = '676f6f676c652e636f6d'; // google.com
      final mt = parser.parse(
        'tg://proxy?server=203.0.113.9&port=443&secret=ee00112233445566778899aabbccddeeff$domainHex#MT',
      );
      expect(mt, isNotNull);
      expect(mt!.sni, 'google.com');
      expect((mt.toOutbound()['tls'] as Map)['server_name'], 'google.com');

      const autoGroup = Profile(
        id: 'auto:wg',
        name: 'Автовыбор',
        type: 'urltest',
        server: 'auto',
        port: 443,
      );
      final wgNode = Profile(
        id: 'wg1',
        name: 'WG1',
        type: 'wireguard',
        server: '198.51.100.50',
        port: 51820,
        subscriptionId: 'wg',
        extra: const {
          'private_key': 'priv=',
          'peer_public_key': 'pub=',
          'local_address': ['10.0.0.2/32'],
          'mtu': 1340,
        },
      );
      final vlessNode = Profile(
        id: 'vl1',
        name: 'VL1',
        type: 'vless',
        server: '203.0.113.10',
        port: 443,
        uuid: 'u1',
        subscriptionId: 'wg',
      );
      final cfg = RuntimeConfig(
        profile: autoGroup,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
        mtu: 9000,
        subscriptions: const [
          SubscriptionEntry(id: 'wg', name: 'WG Sub', url: 'https://example.com/sub'),
        ],
        extraProfiles: [vlessNode, wgNode],
      );
      expect(cfg.effectiveTunMtu, 1340);
      final tun = (cfg.toJson()['inbounds'] as List).cast<Map<String, dynamic>>().firstWhere(
            (i) => i['tag'] == 'tun-in',
          );
      expect(tun['mtu'], 1340);
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
