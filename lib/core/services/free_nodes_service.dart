import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../models/runtime_config.dart';
import 'link_parser.dart';

/// Сервис бесплатных туннелей и автоподбора (по аналогии с WARP + SHARD в MSN-GUARD):
/// 1. Автогенерация бесплатного аккаунта Cloudflare WARP с обфускацией AmneziaWG (Anti-DPI)
///    и сканированием живых эндпоинтов Cloudflare (`188.114.96.x–99.x`, `162.159.192.x–195.x`).
/// 2. Загрузка и размножение пула бесплатных узлов SHARD (`shard-nodes.txt` + `Free-Configs`)
///    по живым Cloudflare Edge IP с параллельной гонкой (Race) для выбора самого быстрого узла.
class FreeNodesService {
  static const String _warpPeerPublicKey =
      'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=';

  /// Кандидаты эндпоинтов Cloudflare WARP, устойчивые к фильтрации на транзитных узлах.
  static const List<(String host, int port, String label)> warpEndpoints = [
    ('188.114.97.6', 2408, 'CF Edge #1 (188.114.97.6)'),
    ('188.114.96.96', 890, 'CF Edge #2 (188.114.96.96)'),
    ('188.114.98.0', 2408, 'CF Edge #3 (188.114.98.0)'),
    ('188.114.99.224', 1701, 'CF Edge #4 (188.114.99.224)'),
    ('162.159.192.1', 2408, 'CF WARP #5 (162.159.192.1)'),
    ('162.159.193.10', 500, 'CF WARP #6 (162.159.193.10)'),
    ('162.159.195.1', 4500, 'CF WARP #7 (162.159.195.1)'),
    ('engage.cloudflareclient.com', 2408, 'CF Global Anycast'),
  ];

  /// Встроенные живые Cloudflare Edge IP для размножения CDN/WS нод (из MSN-GUARD RemotePolicy).
  static const List<String> defaultCfEdges = [
    '104.21.70.21',
    '104.21.33.59',
    '188.114.97.0',
    '188.114.97.6',
    '188.114.98.0',
    '172.67.154.85',
  ];

  /// Источники бесплатных проверенных конфигураций из MSN-GUARD (SHARD).
  static const List<String> shardSources = [
    'https://raw.githubusercontent.com/mbm110/MSN-GUARD/master/remote/shard-nodes.txt',
    'https://raw.githubusercontent.com/patterniha/Free-Configs/main/configs.txt',
  ];

  static const String policyUrl =
      'https://raw.githubusercontent.com/mbm110/MSN-GUARD/master/remote/policy.json';

  /// Генерирует пару ключей Curve25519 (X25519) в формате Base64.
  static ({String privateKey, String publicKey}) generateX25519KeyPair() {
    final rng = Random.secure();
    final priv = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      priv[i] = rng.nextInt(256);
    }
    // Clamping по RFC 7748
    priv[0] &= 248;
    priv[31] &= 127;
    priv[31] |= 64;

    final pub = _x25519BasePointMult(priv);
    return (
      privateKey: base64Encode(priv),
      publicKey: base64Encode(pub),
    );
  }

  /// Вычисляет публичный ключ X25519 (`scalar * 9 mod 2^255 - 19`).
  static Uint8List _x25519BasePointMult(Uint8List scalar) {
    final p = (BigInt.one << 255) - BigInt.from(19);
    final a24 = BigInt.from(121665);

    BigInt modP(BigInt x) {
      final r = x % p;
      return r.isNegative ? r + p : r;
    }

    BigInt powMod(BigInt base, BigInt exp) => base.modPow(exp, p);

    final k = Uint8List.fromList(scalar);
    k[0] &= 248;
    k[31] &= 127;
    k[31] |= 64;

    final x1 = BigInt.from(9);
    var x2 = BigInt.one;
    var z2 = BigInt.zero;
    var x3 = x1;
    var z3 = BigInt.one;
    var swap = 0;

    for (var t = 254; t >= 0; t--) {
      final kBit = (k[t >> 3] >> (t & 7)) & 1;
      swap ^= kBit;
      if (swap != 0) {
        final tx = x2;
        x2 = x3;
        x3 = tx;
        final tz = z2;
        z2 = z3;
        z3 = tz;
      }
      swap = kBit;

      final a = modP(x2 + z2);
      final aa = modP(a * a);
      final b = modP(x2 - z2);
      final bb = modP(b * b);
      final e = modP(aa - bb);
      final c = modP(x3 + z3);
      final d = modP(x3 - z3);
      final da = modP(d * a);
      final cb = modP(c * b);
      final dacbPlus = modP(da + cb);
      x3 = modP(dacbPlus * dacbPlus);
      final dacbMinus = modP(da - cb);
      z3 = modP(x1 * modP(dacbMinus * dacbMinus));
      x2 = modP(aa * bb);
      z2 = modP(e * modP(aa + modP(a24 * e)));
    }

    if (swap != 0) {
      final tx = x2;
      x2 = x3;
      x3 = tx;
      final tz = z2;
      z2 = z3;
      z3 = tz;
    }

    final res = modP(x2 * powMod(z2, p - BigInt.two));
    final out = Uint8List(32);
    var v = res;
    for (var i = 0; i < 32; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  /// Регистрирует новое бесплатное устройство Cloudflare WARP и подбирает живые эндпоинты
  /// с параметрами обфускации AmneziaWG (для работы через транзитные сетевые фильтры).
  Future<List<Profile>> generateWarpProfiles({
    bool useLocalProxy = false,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Генерация ключей X25519 для Cloudflare WARP...');
    final keys = generateX25519KeyPair();

    var v4Addr = '172.16.0.2/32';
    var v6Addr = '';
    var peerPub = _warpPeerPublicKey;
    List<int>? reserved;

    onStatus?.call('Регистрация бесплатного аккаунта Cloudflare WARP...');
    final reg = await _registerWarpIdentity(
      keys.publicKey,
      useLocalProxy: useLocalProxy,
    );
    if (reg != null) {
      v4Addr = reg.v4Address;
      v6Addr = reg.v6Address;
      peerPub = reg.peerPublicKey;
      reserved = reg.reserved;
    }

    onStatus?.call('Сканирование лучших эндпоинтов Cloudflare Edge...');
    final ranked = await _scanWarpEndpoints();

    final addresses = <String>[
      v4Addr,
      if (v6Addr.isNotEmpty) v6Addr,
    ];

    final profiles = <Profile>[];
    for (var i = 0; i < ranked.length; i++) {
      final ep = ranked[i];
      final latencySuffix = ep.ms > 0 ? ' [${ep.ms}ms]' : '';
      profiles.add(
        Profile(
          id: 'warp-awg-${ep.host.replaceAll('.', '-')}-${ep.port}',
          name: 'WARP AmneziaWG · ${ep.label}$latencySuffix',
          type: 'wireguard',
          server: ep.host,
          port: ep.port,
          password: keys.privateKey,
          publicKey: peerPub,
          subscriptionId: 'free-warp',
          extra: {
            'private_key': keys.privateKey,
            'peer_public_key': peerPub,
            'local_address': addresses,
            if (reserved != null && reserved.length == 3) 'reserved': reserved,
            'mtu': 1280,
            // Параметры обфускации AmneziaWG 1.5 для установки сессий Cloudflare WARP
            'jc': 4,
            'jmin': 40,
            'jmax': 70,
            's1': 0,
            's2': 0,
            'h1': 1,
            'h2': 2,
            'h3': 3,
            'h4': 4,
          },
        ),
      );
    }

    return profiles;
  }

  Future<
      ({
        String v4Address,
        String v6Address,
        String peerPublicKey,
        List<int>? reserved,
      })?> _registerWarpIdentity(
    String publicKey, {
    bool useLocalProxy = false,
  }) async {
    final endpoints = [
      'https://api.cloudflareclient.com/v0a2158/reg',
      'https://162.159.192.1/v0a2158/reg',
    ];

    for (final url in endpoints) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 6)
        ..badCertificateCallback = (_, _, _) => true;
      if (useLocalProxy) {
        client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
      }
      try {
        final req = await client.postUrl(Uri.parse(url)).timeout(
              const Duration(seconds: 6),
            );
        req.headers.set('Host', 'api.cloudflareclient.com');
        req.headers.set('Content-Type', 'application/json; charset=UTF-8');
        req.headers.set('Accept', 'application/json');
        req.headers.set('User-Agent', 'okhttp/3.12.1');
        req.headers.set('CF-Client-Version', 'a-6.11-2223');

        final payload = jsonEncode({
          'key': publicKey,
          'install_id': '',
          'fcm_token': '',
          'tos': DateTime.now().toUtc().toIso8601String(),
          'model': 'Android',
          'serial_number':
              List.generate(12, (_) => Random().nextInt(16).toRadixString(16))
                  .join(),
          'locale': 'en_US',
        });
        req.add(utf8.encode(payload));
        final resp = await req.close().timeout(const Duration(seconds: 6));
        if (resp.statusCode != 200) {
          await resp.drain<void>();
          continue;
        }
        final raw = await resp
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 6));
        final json = jsonDecode(raw);
        if (json is! Map) continue;
        final cfg = json['config'];
        if (cfg is! Map) continue;

        final iface = cfg['interface'];
        final addrs = iface is Map ? iface['addresses'] : null;
        var v4 = (addrs is Map ? addrs['v4']?.toString() : null) ?? '172.16.0.2';
        var v6 = (addrs is Map ? addrs['v6']?.toString() : null) ?? '';
        if (!v4.contains('/')) v4 = '$v4/32';
        if (v6.isNotEmpty && !v6.contains('/')) v6 = '$v6/128';

        var peerPub = _warpPeerPublicKey;
        final peers = cfg['peers'];
        if (peers is List && peers.isNotEmpty && peers.first is Map) {
          final pk = (peers.first as Map)['public_key']?.toString();
          if (pk != null && pk.isNotEmpty) peerPub = pk;
        }

        List<int>? reserved;
        final clientId = cfg['client_id']?.toString() ?? '';
        if (clientId.isNotEmpty) {
          try {
            final bytes = base64Decode(clientId);
            if (bytes.length >= 3) {
              reserved = [bytes[0], bytes[1], bytes[2]];
            }
          } catch (_) {}
        }

        return (
          v4Address: v4,
          v6Address: v6,
          peerPublicKey: peerPub,
          reserved: reserved,
        );
      } catch (_) {
        // Пробуем следующий адрес
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }

  Future<List<({String host, int port, String label, int ms})>>
      _scanWarpEndpoints() async {
    final results = await Future.wait(
      warpEndpoints.map((ep) async {
        final (host, port, label) = ep;
        var bestMs = -1;
        // Проверяем TCP-достижимость узла Cloudflare (443 или 80) как индикатор отсутствия blackhole IP
        for (final probePort in [443, 80, port]) {
          final sw = Stopwatch()..start();
          try {
            final sock = await Socket.connect(
              host,
              probePort,
              timeout: const Duration(milliseconds: 1100),
            );
            sw.stop();
            sock.destroy();
            bestMs = sw.elapsedMilliseconds;
            break;
          } catch (_) {}
        }
        return (host: host, port: port, label: label, ms: bestMs);
      }),
    );

    results.sort((a, b) {
      final aOk = a.ms >= 0;
      final bOk = b.ms >= 0;
      if (aOk != bOk) return aOk ? -1 : 1;
      return a.ms.compareTo(b.ms);
    });
    return results;
  }

  /// Загружает пул бесплатных узлов SHARD (как в MSN-GUARD), размножает CDN-ноды
  /// по живым Cloudflare Edge IP и возвращает отсортированные по отклику рабочие профили.
  Future<List<Profile>> fetchAndRaceShardNodes({
    bool useLocalProxy = false,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Загрузка списка живых Cloudflare Edge IP...');
    final edges = await _fetchLiveEdges(useLocalProxy: useLocalProxy);

    onStatus?.call('Загрузка пула бесплатных узлов SHARD...');
    final parser = const LinkParser();
    final rawProfiles = <Profile>[];

    for (final srcUrl in shardSources) {
      final body = await _fetchText(srcUrl, useLocalProxy: useLocalProxy);
      if (body == null || body.trim().isEmpty) continue;
      final parsed = parser.parseSubscription(body, subscriptionId: 'free-shard');
      if (parsed.isNotEmpty) {
        rawProfiles.addAll(parsed);
        break;
      }
    }

    if (rawProfiles.isEmpty) {
      return const [];
    }

    // Размножаем CDN WebSocket ноды по живым Cloudflare Edge IP (как ShardEdges.expand в MSN-GUARD)
    final expanded = _expandAcrossEdges(rawProfiles, edges);
    onStatus?.call(
      'Гонка узлов (проверка ${min(expanded.length, 32)} кандидатов)...',
    );

    // Берём первые 32 разнообразных кандидата и проводим быструю параллельную гонку
    final candidates = expanded.take(32).toList();
    final scored = <({Profile profile, int ms})>[];

    const batchSize = 12;
    for (var i = 0; i < candidates.length; i += batchSize) {
      final batch = candidates.skip(i).take(batchSize).toList();
      final batchRes = await Future.wait(
        batch.map((p) async {
          final sw = Stopwatch()..start();
          try {
            final s = await Socket.connect(
              p.server,
              p.port,
              timeout: const Duration(milliseconds: 1600),
            );
            sw.stop();
            s.destroy();
            return (profile: p, ms: sw.elapsedMilliseconds);
          } catch (_) {
            return (profile: p, ms: -1);
          }
        }),
      );
      for (final r in batchRes) {
        if (r.ms >= 0) scored.add(r);
      }
    }

    scored.sort((a, b) => a.ms.compareTo(b.ms));
    if (scored.isEmpty) {
      return candidates.take(12).toList();
    }

    return [
      for (final item in scored.take(16))
        item.profile.copyWithName(
          '⚡ ${item.profile.name} [${item.ms}ms]',
        ),
    ];
  }

  List<Profile> _expandAcrossEdges(List<Profile> nodes, List<String> edges) {
    const cdnPorts = {
      80,
      8080,
      8880,
      2052,
      2082,
      2086,
      2095,
      443,
      2053,
      2083,
      2087,
      2096,
      8443,
    };
    final out = <Profile>[];
    final seen = <String>{};

    for (final node in nodes) {
      final key0 = '${node.server}:${node.port}:${node.uuid}:${node.password}';
      if (seen.add(key0)) {
        out.add(node);
      }

      final tr = node.extra['transport'];
      final host = tr is Map
          ? (tr['host']?.toString() ??
              (tr['headers'] is Map
                  ? (tr['headers'] as Map)['Host']?.toString() ?? ''
                  : ''))
          : '';
      final hasHost = host.isNotEmpty || node.sni.isNotEmpty;
      if (!hasHost || !cdnPorts.contains(node.port)) continue;

      for (final edge in edges.take(3)) {
        if (edge == node.server) continue;
        final k = '$edge:${node.port}:${node.uuid}:${node.password}';
        if (!seen.add(k)) continue;
        out.add(
          Profile.fromJson({
            ...node.toJson(),
            'id': '${node.id}-${edge.replaceAll('.', '')}',
            'name': '${node.name} · CF $edge',
            'server': edge,
            'subscriptionId': 'free-shard',
          }),
        );
      }
    }
    return out;
  }

  Future<List<String>> _fetchLiveEdges({bool useLocalProxy = false}) async {
    final raw = await _fetchText(policyUrl, useLocalProxy: useLocalProxy);
    if (raw != null) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map && decoded['edges'] is List) {
          final list = (decoded['edges'] as List)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (list.isNotEmpty) return list;
        }
      } catch (_) {}
    }
    return defaultCfEdges;
  }

  Future<String?> _fetchText(String url, {bool useLocalProxy = false}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 7)
      ..badCertificateCallback = (_, _, _) => true;
    if (useLocalProxy) {
      client.findProxy = (_) => 'PROXY 127.0.0.1:2080';
    }
    try {
      final req = await client.getUrl(Uri.parse(url)).timeout(
            const Duration(seconds: 7),
          );
      req.headers.set('User-Agent', 'Mozilla/5.0');
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) {
        await resp.drain<void>();
        return null;
      }
      return await resp
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

extension _ProfileCopyName on Profile {
  Profile copyWithName(String newName) => Profile.fromJson({
        ...toJson(),
        'name': newName,
      });
}
