import 'package:flutter_test/flutter_test.dart';
import 'package:tachyon_proxy/core/models/runtime_config.dart';

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
    final dnsRules = config['dns']['rules'] as List;
    expect(dnsRules, hasLength(1));
    expect(dnsRules.first['server'], RuntimeConfig.directTag);
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
}
