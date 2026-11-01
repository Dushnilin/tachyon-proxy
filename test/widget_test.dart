import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_proxy/core/models/runtime_config.dart';
import 'package:tachyon_proxy/core/services/link_parser.dart';

void main() {
  const profile = Profile(
    id: 'vless-1',
    name: 'Тестовый сервер',
    type: 'vless',
    server: 'example.com',
    port: 443,
    uuid: '00000000-0000-0000-0000-000000000000',
    sni: 'example.com',
  );

  test('конфигурация собирается под требования ядра', () {
    final config = RuntimeConfig(
      profile: profile,
      routingMode: RoutingMode.rules,
      dns: const DnsSettings(),
      ruleSets: const [],
    ).toJson();

    // Ядро требует явный резолвер имён, когда DNS-серверов больше одного,
    // и уникальные теги у каждого сервера в dns.servers.
    expect(config['route']['default_domain_resolver'], isNotNull);
    final dnsServers = (config['dns']['servers'] as List).cast<Map>();
    final dnsTags = dnsServers.map((s) => s['tag'] as String).toList();
    expect(dnsTags.toSet().length, dnsTags.length);

    // DNS-запросы приложений перехватываются ядром.
    final rules = config['route']['rules'] as List;
    expect(
      rules.any((rule) => rule['action'] == 'hijack-dns'),
      isTrue,
      reason: 'без hijack-dns запросы к резолверам уходят мимо DNS-системы',
    );

    // Исходящие соединения ядра описаны явно.
    final outbounds = config['outbounds'] as List;
    expect(outbounds.any((outbound) => outbound['tag'] == 'proxy'), isTrue);
    expect(outbounds.any((outbound) => outbound['tag'] == 'direct'), isTrue);
  });

  test('списки правил попадают в route.rule_set в формате trs', () {
    final config = RuntimeConfig(
      profile: profile,
      routingMode: RoutingMode.rules,
      dns: const DnsSettings(),
      ruleSets: const [
        RuleSetEntry(
          id: 'russia_inside',
          title: 'Россия',
          path: '/data/lists/russia_inside.trs',
          action: 'direct',
          enabled: true,
        ),
      ],
    ).toJson();

    final ruleSets = config['route']['rule_set'] as List;
    expect(ruleSets, hasLength(1));
    expect(ruleSets.first['type'], 'local');
    expect(ruleSets.first['format'], 'trs');
    expect(ruleSets.first['tag'], 'russia_inside');

    // Прямой список разрешается прямым резолвером, иначе домены из него
    // не совпадут с правилом маршрутизации.
    final dnsRules = (config['dns']['rules'] as List).cast<Map>();
    expect(
      dnsRules.any((r) =>
          (r['rule_set'] as List?)?.contains('russia_inside') == true &&
          r['server'] == RuntimeConfig.directTag),
      isTrue,
    );
  });

  test('DoH-адрес превращается в типизированный сервер', () {
    final config = RuntimeConfig(
      profile: profile,
      routingMode: RoutingMode.global,
      dns: const DnsSettings(servers: ['https://dns.google/dns-query']),
      ruleSets: const [],
    ).toJson();

    final servers = config['dns']['servers'] as List;
    final doh = servers.firstWhere(
      (server) => server['type'] == 'https',
    );
    expect(doh['server'], 'dns.google');
    expect(doh['path'], '/dns-query');
  });

  test('все 19 протоколов подписки роутера Tachyon корректно парсятся и собираются в конфиг ядра', () {
    const routerLinks = '''
tewfai://0f8f7be7-2593-4e05-8de0-50ef29b036c4:d42fb465f8264e36bd4bd667978e3467@192.168.1.205:8443?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&transport=quic%2Ctcp&inner_cipher=aes-256-gcm#TewFai%20%28Tachyon%20Router%29
naive+https://Naive:e21d95da5e3c10282ca40eb851fd6d3a@192.168.1.205:8444?sni=192.168.1.205&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c#Naive%20%28Tachyon%20Router%29
vless://53663e0d-9aa2-4423-9aa7-0c876f2a6484@192.168.1.205:8445?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=-j20a4wX0aA1tD4p8lI8n_b-dY6E2vR0c9k3mZ1xX2A&sid=fc328ca2c4598c1e&type=tcp&flow=xtls-rprx-vision#VLESS%20%28Tachyon%20Router%29
vless://de335982-e2a1-4385-8162-215d26da9a43@192.168.1.205:8446?encryption=none&security=tls&sni=192.168.1.205&allowInsecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&fp=chrome&type=tcp#VLESS-TLS%20%28Tachyon%20Router%29
vmess://eyJ2IjoiMiIsInBzIjoiVk1lc3MgKFRhY2h5b24gUm91dGVyKSIsImFkZCI6IjE5Mi4xNjguMS4yMDUiLCJwb3J0IjoiODQ0NyIsImlkIjoiNTk3NzgwOTAtODRmNS00ZTBjLTg4MjQtNDk2NWU5MGQ0ZGIxIiwiYWlkIjoiMCIsInNjeSI6ImF1dG8iLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiIiLCJwYXRoIjoiIiwidGxzIjoidGxzIiwic25pIjoiMTkyLjE2OC4xLjIwNSIsImFsbG93SW5zZWN1cmUiOjEsInBjcyI6IjRjZDJkNjk1YjJmYjdkZWViOWEzY2E0NzliNzNhNTMzN2RhN2ExMTYzNWVkOTQyZmI3OWRlMzZmNDU1MjliMWMifQ==
trojan://4427b698a5f826444bf0d7be6f083e26@192.168.1.205:8458?security=tls&sni=192.168.1.205&allowInsecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&type=tcp#Trojan%20%28Tachyon%20Router%29
ss://MjAyMi1ibGFrZTMtYWVzLTEyOC1nY206WlRZeFl6WmhOamN5T1dWbVpXRTBObU5rTnpNNVlqWXc=@192.168.1.205:8388#Shadowsocks%20%28Tachyon%20Router%29
socks5://Socks5:a229cb7e823a0d16ce79a26d4cb0c82e@192.168.1.205:1080#Socks5%20%28Tachyon%20Router%29
http://HttpProxy:7c1e7608be1a3b2a9d37fc3a210f9d44@192.168.1.205:8080#HttpProxy%20%28Tachyon%20Router%29
socks5://MixedProxy:9f50be772e11ab42f592096444620a65@192.168.1.205:1081#MixedProxy%20%28Tachyon%20Router%29
hysteria2://38ee8451ec63222d04e6883164d14671@192.168.1.205:8448?sni=192.168.1.205&insecure=1&pinSHA256=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c#Hysteria2%20%28Tachyon%20Router%29
tuic://f29c469d-6097-4189-a2f2-6070580fd6c7:8750298283431e530e965d682221a98c@192.168.1.205:8449?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&congestion_control=bbr&alpn=h3#TUIC%20%28Tachyon%20Router%29
anytls://49a7490315219d2b2e9b399cf5351162@192.168.1.205:8450?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c#AnyTLS%20%28Tachyon%20Router%29
shadowtls://3be3b88851fd95d579434873e162cf22@192.168.1.205:8451?sni=www.microsoft.com&version=3#ShadowTLS%20%28Tachyon%20Router%29
mierus://Mieru:7d989872364516095747be888c426707@192.168.1.205?port=2012-2022&protocol=TCP&profile=Mieru%20%28Tachyon%20Router%29
fptn://eyAidmVyc2lvbiI6IDEsICJzZXJ2aWNlX25hbWUiOiAiRlBUTiAoVGFjaHlvbiBSb3V0ZXIpIiwgInVzZXJuYW1lIjogIkZQVE4iLCAicGFzc3dvcmQiOiAiZGIzZjg1ZTEzYzg5OTM2ZDBlZWE5NzQ3NGU2YzEyZmMiLCAic2VydmVycyI6IFt7ICJuYW1lIjogIkZQVE4gKFRhY2h5b24gUm91dGVyKSIsICJob3N0IjogIjE5Mi4xNjguMS4yMDUiLCAicG9ydCI6IDg0NTMsICJtZDVfZmluZ2VycHJpbnQiOiAiZjc4ZjAzZThmMzA1ZDdmNDI3NGI4OTk1NDkzMGI1MTMiLCAiaXNfY2Vuc29yZWQiOiBmYWxzZSB9XSB9#FPTN%20%28Tachyon%20Router%29
trusttunnel://TrustTunnel:64fd8d89c2e973ec3a4a6e393218993b@192.168.1.205:8454?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c#TrustTunnel%20%28Tachyon%20Router%29
masque://192.168.1.205:8455?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&profile=standard&uri=https%3A%2F%2F192.168.1.205%3A8455%2F.well-known%2Fmasque%2Fip%2F%2A%2F%2A%2F&ip=172.16.0.0%2F24&mtu=1400#MASQUE%20%28Tachyon%20Router%29
openconnect://0195b65f7017cf503857921ccca9278f@192.168.1.205:8456?sni=192.168.1.205&insecure=1&pcs=4cd2d695b2fb7deeb9a3ca479b73a5337da7a11635ed942fb79de36f45529b1c&flavor=anyconnect&cookie=0195b65f7017cf503857921ccca9278f&address=172.16.1.2%2F24&mtu=1400#OpenConnect%20%28Tachyon%20Router%29
https://t.me/proxy?server=192.168.1.205&port=8457&secret=daa0dc1ef3940ec586aa54e73b045fd1#MTProto%20%28Tachyon%20Router%29
amneziawg://W0ludGVyZmFjZV0KUHJpdmF0ZUtleSA9IGdHNEJ4T01yUDhuV1dIelZ6VGt2OXJ6T1lGUG93aG03SGhmN1Z5d0N5V2M9CkFkZHJlc3MgPSAxMC42Ni42Ni4yLzMyCkROUyA9IDEuMS4xLjEKSmMgPSA0CkptaW4gPSA0MApKbWF4ID0gNzAKU19xID0gMApTMiA9IDAKRDEgPSAxMjM0NTY3ODkKSDIgPSAyMzQ1Njc4OTEKSDMgPSAzNDU2Nzg5MTIKSDQgPSA0NTY3ODkxMjMKCltQZWVyXQpQdWJsaWNLZXkgPSBFdnpPMEtqMG1jU2Z1T1dXNWQ2TldkSDJ2OXI0T1lGUG93aG03SGhmN1Z5d0M9CkFsbG93ZWRJUHMgPSAwLjAuMC4wLzAsIDo6LzAKRW5kcG9pbnQgPSAxOTIuMTY4LjEuMjA1OjUxODIwCg==#AmneziaWG%20%28Tachyon%20Router%29
''';

    final parser = LinkParser();
    final b64Payload = base64.encode(utf8.encode(routerLinks.trim()));
    final profiles = parser.parseSubscription(b64Payload, subscriptionId: 'sub-router');
    expect(profiles, hasLength(21));

    for (final p in profiles) {
      final cfg = RuntimeConfig(
        profile: p,
        routingMode: RoutingMode.rules,
        dns: const DnsSettings(),
        ruleSets: const [],
      ).toJson();
      if (p.type == 'wireguard') {
        expect(cfg['endpoints'], isA<List>());
        expect((cfg['endpoints'] as List).first['type'], 'wireguard');
      } else {
        final outbounds = cfg['outbounds'] as List;
        expect(outbounds.first['type'], p.type);
      }
    }
  });
}
