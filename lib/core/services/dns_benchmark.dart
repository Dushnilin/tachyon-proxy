import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Кандидат резолвера для проверки.
class DnsCandidate {
  const DnsCandidate({
    required this.id,
    required this.provider,
    required this.type,
    required this.address,
    this.ip = '',
    this.tag = '',
  });

  final String id;
  final String provider;

  /// `udp` или `https` (DoH).
  final String type;

  /// Адрес резолвера: IP для UDP, URL для DoH.
  final String address;

  /// IP за DoH-именем — нужен, чтобы не уходить в системный DNS.
  final String ip;
  final String tag;

  String get display => ip.isNotEmpty ? ip : address;
}

/// Результат проверки одного кандидата.
class DnsResult {
  const DnsResult({
    required this.candidate,
    required this.ok,
    this.latencyMs = -1,
    this.lossPercent = 100,
    this.error = '',
  });

  final DnsCandidate candidate;

  /// Резолвер ответил хотя бы раз.
  final bool ok;

  /// Средняя задержка по успешным запросам, мс.
  final int latencyMs;

  /// Доля неудачных запросов, процентов.
  final int lossPercent;
  final String error;

  /// Оценка: задержка плюс штраф за потери.
  ///
  /// Порог взят из проекта `tachyon` (ucode-бенчмарк): пять процентов за
  /// каждый процент потерь — медленный, но стабильный резолвер проигрывает
  /// быстрому с потерями.
  double get score => ok ? latencyMs + lossPercent * 5 : 99999;

  /// Оценка качества для подписи в интерфейсе.
  String get grade {
    if (!ok) return 'не отвечает';
    if (latencyMs < 35 && lossPercent == 0) return 'отлично';
    if (latencyMs < 75 && lossPercent <= 25) return 'хорошо';
    if (latencyMs < 150 && lossPercent <= 50) return 'средне';
    if (lossPercent < 100) return 'медленно';
    return 'не отвечает';
  }
}

/// Пул кандидатов для автоподбора.
///
/// Список перенесён из проекта `tachyon`: это публичные резолверы, которые
/// там проверяются перед выбором. Порядок и содержимое сохранены, чтобы
/// результат совпадал с роутером.
abstract final class DnsCandidates {
  static const testDomains = <String>['google.com', 'yandex.ru'];

  static const List<DnsCandidate> all = [
    DnsCandidate(
      id: 'yandex_udp',
      provider: 'Yandex',
      type: 'udp',
      address: '77.88.8.8',
      ip: '77.88.8.8',
      tag: 'основной',
    ),
    DnsCandidate(
      id: 'yandex_udp2',
      provider: 'Yandex',
      type: 'udp',
      address: '77.88.8.1',
      ip: '77.88.8.1',
      tag: 'резервный',
    ),
    DnsCandidate(
      id: 'yandex_doh',
      provider: 'Yandex',
      type: 'https',
      address: 'https://common.dot.dns.yandex.net/dns-query',
      ip: '77.88.8.8',
      tag: 'DoH без фильтрации',
    ),
    DnsCandidate(
      id: 'cloudflare_udp',
      provider: 'Cloudflare',
      type: 'udp',
      address: '1.1.1.1',
      ip: '1.1.1.1',
      tag: 'основной',
    ),
    DnsCandidate(
      id: 'cloudflare_udp2',
      provider: 'Cloudflare',
      type: 'udp',
      address: '1.0.0.1',
      ip: '1.0.0.1',
      tag: 'резервный',
    ),
    DnsCandidate(
      id: 'cloudflare_doh',
      provider: 'Cloudflare',
      type: 'https',
      address: 'https://cloudflare-dns.com/dns-query',
      ip: '1.1.1.1',
      tag: 'DoH зашифрованный',
    ),
    DnsCandidate(
      id: 'google_udp',
      provider: 'Google',
      type: 'udp',
      address: '8.8.8.8',
      ip: '8.8.8.8',
      tag: 'основной',
    ),
    DnsCandidate(
      id: 'google_udp2',
      provider: 'Google',
      type: 'udp',
      address: '8.8.4.4',
      ip: '8.8.4.4',
      tag: 'резервный',
    ),
    DnsCandidate(
      id: 'google_doh',
      provider: 'Google',
      type: 'https',
      address: 'https://dns.google/dns-query',
      ip: '8.8.8.8',
      tag: 'DoH зашифрованный',
    ),
    DnsCandidate(
      id: 'adguard_udp',
      provider: 'AdGuard',
      type: 'udp',
      address: '94.140.14.14',
      ip: '94.140.14.14',
      tag: 'по умолчанию',
    ),
    DnsCandidate(
      id: 'adguard_doh',
      provider: 'AdGuard',
      type: 'https',
      address: 'https://dns.adguard-dns.com/dns-query',
      ip: '94.140.14.14',
      tag: 'DoH с блокировкой',
    ),
    DnsCandidate(
      id: 'comss_udp',
      provider: 'Comss.one',
      type: 'udp',
      address: '92.223.109.31',
      ip: '92.223.109.31',
      tag: 'обход блокировок',
    ),
    DnsCandidate(
      id: 'comss_doh',
      provider: 'Comss.one',
      type: 'https',
      address: 'https://dns.comss.one/dns-query',
      ip: '92.223.109.31',
      tag: 'DoH обход блокировок',
    ),
    DnsCandidate(
      id: 'controld_udp',
      provider: 'Control D',
      type: 'udp',
      address: '76.76.2.0',
      ip: '76.76.2.0',
      tag: 'без фильтрации',
    ),
    DnsCandidate(
      id: 'controld_doh',
      provider: 'Control D',
      type: 'https',
      address: 'https://freedns.controld.com/p0',
      ip: '76.76.2.0',
      tag: 'DoH зашифрованный',
    ),
    DnsCandidate(
      id: 'quad9_udp',
      provider: 'Quad9',
      type: 'udp',
      address: '9.9.9.9',
      ip: '9.9.9.9',
      tag: 'основной',
    ),
    DnsCandidate(
      id: 'quad9_doh',
      provider: 'Quad9',
      type: 'https',
      address: 'https://dns.quad9.net/dns-query',
      ip: '9.9.9.9',
      tag: 'DoH безопасный',
    ),
    DnsCandidate(
      id: 'mullvad_udp',
      provider: 'Mullvad',
      type: 'udp',
      address: '194.242.2.2',
      ip: '194.242.2.2',
      tag: 'приватный',
    ),
    DnsCandidate(
      id: 'mullvad_doh',
      provider: 'Mullvad',
      type: 'https',
      address: 'https://dns.mullvad.net/dns-query',
      ip: '194.242.2.2',
      tag: 'DoH приватный',
    ),
    DnsCandidate(
      id: 'opendns_udp',
      provider: 'OpenDNS',
      type: 'udp',
      address: '208.67.222.222',
      ip: '208.67.222.222',
      tag: 'стандартный',
    ),
    DnsCandidate(
      id: 'opendns_doh',
      provider: 'OpenDNS',
      type: 'https',
      address: 'https://doh.opendns.com/dns-query',
      ip: '208.67.222.222',
      tag: 'DoH зашифрованный',
    ),
    DnsCandidate(
      id: 'dnssb_doh',
      provider: 'DNS.SB',
      type: 'https',
      address: 'https://doh.dns.sb/dns-query',
      ip: '185.222.222.222',
      tag: 'DoH',
    ),
    DnsCandidate(
      id: 'dnspod_doh',
      provider: 'DNSPod',
      type: 'https',
      address: 'https://dns.pub/dns-query',
      tag: 'DoH',
    ),
    DnsCandidate(
      id: 'alidns_doh',
      provider: 'AliDNS',
      type: 'https',
      address: 'https://dns.alidns.com/dns-query',
      tag: 'DoH',
    ),
    DnsCandidate(
      id: 'nextdns_doh',
      provider: 'NextDNS',
      type: 'https',
      address: 'https://dns.nextdns.io',
      tag: 'DoH без настройки',
    ),
    DnsCandidate(
      id: 'dns4eu_doh',
      provider: 'DNS4EU',
      type: 'https',
      address: 'https://unfiltered.joindns4.eu/dns-query',
      ip: '86.54.11.100',
      tag: 'DoH без фильтрации',
    ),
    DnsCandidate(
      id: 'libredns_doh',
      provider: 'LibreDNS',
      type: 'https',
      address: 'https://doh.libredns.gr/dns-query',
      tag: 'DoH',
    ),
    DnsCandidate(
      id: 'rethinkdns_doh',
      provider: 'RethinkDNS',
      type: 'https',
      address: 'https://sky.rethinkdns.com/dns-query',
      tag: 'DoH',
    ),
  ];
}

/// Проверяет резолверы и выбирает лучшие.
///
/// Опрос идёт параллельно, но не одновременно для всех: ограничение в
/// несколько запросов держит мобильный интерфейс отзывчивым и не даёт
/// упереться в лимит сокетов.
class DnsBenchmark {
  DnsBenchmark({this.timeout = const Duration(seconds: 3), this.parallelism = 4});

  final Duration timeout;

  /// Сколько кандидатов проверяется одновременно.
  final int parallelism;

  /// Проверяет всех кандидатов и возвращает результаты, отсортированные по
  /// оценке.
  Future<List<DnsResult>> run({
    List<DnsCandidate> candidates = DnsCandidates.all,
    void Function(DnsResult result)? onResult,
  }) async {
    final results = <DnsResult>[];
    final queue = List<DnsCandidate>.from(candidates);

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final candidate = queue.removeAt(0);
        final result = await test(candidate);
        results.add(result);
        onResult?.call(result);
      }
    }

    final workers = List.generate(
      parallelism.clamp(1, candidates.length),
      (_) => worker(),
    );
    await Future.wait(workers);

    results.sort((a, b) => a.score.compareTo(b.score));
    return results;
  }

  /// Проверяет один кандидат по тестовым доменам.
  Future<DnsResult> test(DnsCandidate candidate) async {
    var total = 0;
    var success = 0;
    var lastError = '';

    for (final domain in DnsCandidates.testDomains) {
      final elapsed = candidate.type == 'https'
          ? await _probeDoh(candidate, domain)
          : await _probeUdp(candidate, domain);
      if (elapsed >= 0) {
        total += elapsed;
        success++;
      } else {
        lastError = 'нет ответа';
      }
    }

    if (success == 0) {
      return DnsResult(
        candidate: candidate,
        ok: false,
        error: lastError.isEmpty ? 'нет ответа' : lastError,
      );
    }

    final rounds = DnsCandidates.testDomains.length;
    return DnsResult(
      candidate: candidate,
      ok: true,
      latencyMs: total ~/ success,
      lossPercent: ((rounds - success) * 100) ~/ rounds,
    );
  }

  /// UDP-проба: один запрос A-записи, ответ — любая запись.
  Future<int> _probeUdp(DnsCandidate candidate, String domain) async {
    final address = candidate.ip.isNotEmpty ? candidate.ip : candidate.address;
    final port = int.tryParse(address.split(':').last) ?? 53;
    final host = address.split(':').first;

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final stopwatch = Stopwatch()..start();
    try {
      final completer = Completer<bool>();
      late final StreamSubscription<RawSocketEvent> subscription;
      subscription = socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        if (!completer.isCompleted) completer.complete(true);
      });

      socket.send(
        _query(domain),
        InternetAddress(host),
        port,
      );

      final answered = await completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
      stopwatch.stop();
      await subscription.cancel();
      if (!answered) return -1;
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      stopwatch.stop();
      return -1;
    } finally {
      socket.close();
    }
  }

  /// DoH-проба: запрос в формате RFC 8484 (`application/dns-message`).
  Future<int> _probeDoh(DnsCandidate candidate, String domain) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final uri = Uri.parse(candidate.address);
      final request = await client.postUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/dns-message');
      request.headers.contentType = ContentType('application', 'dns-message');
      request.add(_query(domain));

      final stopwatch = Stopwatch()..start();
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return -1;
      await response.drain<void>();
      stopwatch.stop();
      return stopwatch.elapsedMilliseconds;
    } catch (_) {
      return -1;
    } finally {
      client.close(force: true);
    }
  }

  /// Собирает DNS-запрос A-записи.
  static Uint8List _query(String domain) {
    final builder = BytesBuilder();
    void addByte(int value) => builder.addByte(value);
    void add16(int value) {
      addByte((value >> 8) & 0xff);
      addByte(value & 0xff);
    }

    add16(0x1234); // идентификатор запроса
    add16(0x0100); // рекурсия желательна
    add16(1); // один вопрос
    add16(0);
    add16(0);
    add16(0);

    for (final label in domain.split('.')) {
      if (label.isEmpty) continue;
      final bytes = utf8.encode(label);
      addByte(bytes.length);
      builder.add(bytes);
    }
    addByte(0);
    add16(1); // тип A
    add16(1); // класс IN

    return builder.toBytes();
  }
}

/// Рекомендация по итогам проверки.
class DnsRecommendation {
  const DnsRecommendation({
    required this.servers,
    required this.bootstrap,
    required this.reason,
    this.primary,
  });

  /// Резолверы, которые попадут в конфигурацию.
  final List<String> servers;

  /// Резолверы для bootstrap: ими разрешаются имена DoH-серверов.
  final List<String> bootstrap;

  /// Пояснение для интерфейса.
  final String reason;

  /// Лучший одиночный резолвер.
  final DnsResult? primary;

  /// Подбирает набор по результатам проверки.
  ///
  /// Логика перенесена из проекта `tachyon`: зашифрованные DoH всегда в
  /// приоритете, из UDP выбираются два сервера от разных провайдеров, а
  /// если не ответил ни один — применяются безопасные значения по умолчанию.
  factory DnsRecommendation.from(List<DnsResult> results) {
    final working = results.where((result) => result.ok).toList(growable: false);

    if (working.isEmpty) {
      return const DnsRecommendation(
        servers: ['77.88.8.8', '1.1.1.1'],
        bootstrap: ['77.88.8.8', '1.1.1.1'],
        reason: 'Ни один резолвер не ответил — применены безопасные значения.',
      );
    }

    final udp = working.where((r) => r.candidate.type == 'udp').toList();
    final doh = working.where((r) => r.candidate.type == 'https').toList();

    final bootstrap = _diverse(udp, 2, maxLatency: 250, maxLoss: 25);
    final bootstrapAddresses = bootstrap
        .map((result) => result.candidate.ip.isNotEmpty
            ? result.candidate.ip
            : result.candidate.address)
        .toList(growable: false);

    final dohPicked = _diverse(doh, 2, maxLatency: 350, maxLoss: 25);
    if (dohPicked.isNotEmpty) {
      final names = dohPicked
          .map((result) =>
              '${result.candidate.provider} (${result.latencyMs} мс)')
          .join(', ');
      return DnsRecommendation(
        servers: dohPicked.map((result) => result.candidate.address).toList(),
        bootstrap: bootstrapAddresses.isEmpty
            ? const ['77.88.8.8']
            : bootstrapAddresses,
        reason:
            'Выбраны зашифрованные DoH-серверы [$names] с bootstrap [$bootstrapAddresses].',
        primary: dohPicked.first,
      );
    }

    final udpPicked = _diverse(udp, 2, maxLatency: 200, maxLoss: 25);
    return DnsRecommendation(
      servers: udpPicked.map((result) => result.candidate.address).toList(),
      bootstrap: bootstrapAddresses.isEmpty
          ? const ['77.88.8.8']
          : bootstrapAddresses,
      reason: 'Зашифрованные DoH недоступны — выбраны быстрые UDP-серверы.',
      primary: udpPicked.isEmpty ? null : udpPicked.first,
    );
  }

  /// Выбирает до [count] серверов от разных провайдеров.
  static List<DnsResult> _diverse(
    List<DnsResult> candidates,
    int count, {
    required int maxLatency,
    required int maxLoss,
  }) {
    final sorted = List<DnsResult>.from(candidates)
      ..sort((a, b) => a.score.compareTo(b.score));

    final picked = <DnsResult>[];
    final providers = <String>{};

    for (final result in sorted) {
      if (result.latencyMs < 0 ||
          result.lossPercent > maxLoss ||
          result.latencyMs > maxLatency) {
        continue;
      }
      if (providers.add(result.candidate.provider)) {
        picked.add(result);
        if (picked.length >= count) return picked;
      }
    }

    if (picked.length < count) {
      for (final result in sorted) {
        if (picked.contains(result)) continue;
        if (result.latencyMs < 0 ||
            result.lossPercent > maxLoss ||
            result.latencyMs > maxLatency) {
          continue;
        }
        picked.add(result);
        if (picked.length >= count) break;
      }
    }

    return picked;
  }
}
