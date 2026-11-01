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

  bool get isReality =>
      publicKey.isNotEmpty && type != 'wireguard' && type != 'masque';

  bool get isAmneziaWg =>
      type == 'wireguard' &&
      ((extra['jc'] is num && (extra['jc'] as num) > 0) ||
          (extra['i1']?.toString().isNotEmpty ?? false));

  bool get hasTls {
    if (const {'wireguard', 'shadowsocks', 'socks', 'ssh', 'snell', 'mtproto', 'mieru'}.contains(type)) {
      return false;
    }
    if (const {'hysteria2', 'hysteria', 'tuic', 'anytls', 'naive', 'shadowtls', 'masque', 'trusttunnel', 'openconnect', 'tewfai'}.contains(type)) {
      return true;
    }
    final sec = extra['security']?.toString().toLowerCase() ?? '';
    if (sec == 'none') return false;
    return isReality || sni.isNotEmpty || alpn.isNotEmpty || sec == 'tls' || sec == 'reality';
  }

  /// Полное описание для бейджа: протокол, безопасность, flow, транспорт.
  String get fullTransportLabel {
    if (type == 'urltest') {
      return 'URLTEST · АВТОВЫБОР';
    }
    final parts = <String>[];
    if (isAmneziaWg) {
      parts.add('AMNEZIAWG');
    } else if (type == 'hysteria2') {
      parts.add('HYSTERIA 2');
    } else {
      parts.add(type.toUpperCase());
    }

    if (type == 'wireguard' || type == 'masque') {
      parts.add('UDP');
      return parts.join(' · ');
    }
    if (type == 'hysteria2' || type == 'hysteria' || type == 'tuic') {
      parts.add('QUIC');
      return parts.join(' · ');
    }
    if (type == 'tewfai') {
      parts.add(isReality ? 'Reality' : 'TLS');
      final trList = extra['tewfai_transport'];
      if (trList is List && trList.isNotEmpty) {
        parts.add(trList.map((e) => e.toString().toUpperCase()).join('+'));
      } else {
        parts.add(transport.toUpperCase());
      }
      return parts.join(' · ');
    }
    if (type == 'mieru') {
      final mtr = (extra['mieru_transport'] ?? 'TCP').toString().toUpperCase();
      parts.add(mtr);
      return parts.join(' · ');
    }
    if (type == 'shadowsocks') {
      if (method.startsWith('2022-')) {
        parts.add('SS-2022');
      } else if (method.isNotEmpty) {
        parts.add(method.toUpperCase());
      }
      return parts.join(' · ');
    }

    final sec = extra['security']?.toString().toLowerCase() ?? '';
    if (isReality || sec == 'reality') {
      parts.add('Reality');
    } else if (hasTls) {
      parts.add('TLS');
    }
    if (flow.isNotEmpty) {
      parts.add(flow.replaceAll('xtls-rprx-', ''));
    }
    final trFromExtra = (extra['transport'] is Map)
        ? ((extra['transport'] as Map)['type']?.toString() ?? '')
        : '';
    final effectiveTransport = (transport.isNotEmpty && transport != 'tcp')
        ? transport
        : (trFromExtra.isNotEmpty ? trFromExtra : (transport.isNotEmpty ? transport : 'tcp'));
    parts.add(effectiveTransport.toUpperCase());
    return parts.join(' · ');
  }

  /// Собирает канонический WireGuard/AmneziaWG эндпоинт для массива `endpoints` ядра.
  Map<String, dynamic> toWireGuardEndpoint({String tag = 'proxy'}) {
    final cleanExtra = Map<String, dynamic>.from(extra);
    final privKey = (cleanExtra.remove('private_key') ?? password).toString();
    final pubKey = (cleanExtra.remove('peer_public_key') ??
            cleanExtra.remove('public_key') ??
            publicKey)
        .toString();
    final psk = cleanExtra.remove('pre_shared_key')?.toString() ?? '';
    final reserved = cleanExtra.remove('reserved');
    final localAddr = cleanExtra.remove('local_address') ?? cleanExtra.remove('address');
    final addrs = localAddr is List && localAddr.isNotEmpty
        ? localAddr.map((e) => e.toString()).toList()
        : <String>['10.0.0.2/32'];
    cleanExtra
      ..remove('tls')
      ..remove('transport')
      ..remove('security')
      ..remove('pcs')
      ..remove('certificate_sha256')
      ..remove('chain_outbounds');
    return {
      'type': 'wireguard',
      'tag': tag,
      'address': addrs,
      'private_key': privKey,
      'peers': [
        {
          'address': server,
          'port': port,
          'public_key': pubKey,
          if (psk.isNotEmpty) 'pre_shared_key': psk,
          'allowed_ips': ['0.0.0.0/0', '::/0'],
          'reserved': ?reserved,
        },
      ],
      ...cleanExtra,
    };
  }

  /// Собирает канонический outbound `tachyon-core` для этого профиля.
  ///
  /// `tag` переопределяется, когда `proxy` занят группой подписки.
  Map<String, dynamic> toOutbound({String tag = 'proxy'}) {
    if (type == 'wireguard') {
      return toWireGuardEndpoint(tag: tag);
    }
    final cleanExtra = Map<String, dynamic>.from(extra);
    final security = cleanExtra.remove('security')?.toString().toLowerCase() ?? '';
    final vmessSecurity = cleanExtra.remove('vmess_security')?.toString() ?? '';
    final rawFp = cleanExtra.remove('fp')?.toString() ?? '';
    final fp = normalizeUtlsFingerprint(rawFp);
    final pq = cleanExtra.remove('pq') == true;
    cleanExtra
      ..remove('pcs')
      ..remove('chain_outbounds');
    final certSha256 = cleanExtra.remove('certificate_sha256');
    if (cleanExtra['transport'] is Map) {
      final tr = cleanExtra['transport'] as Map;
      final trType = tr['type']?.toString().toLowerCase();
      if (trType == 'xhttp' || trType == 'splithttp') {
        cleanExtra['transport'] = normalizeXhttpTransport(Map<String, dynamic>.from(tr));
      }
    }

    Map<String, dynamic> buildTlsObject({
      bool forceEnabled = false,
      bool allowInsecureFlag = true,
    }) {
      final existingTls = cleanExtra.remove('tls');
      final tls = existingTls is Map
          ? Map<String, dynamic>.from(existingTls)
          : <String, dynamic>{};
      tls['enabled'] = true;
      if (sni.isNotEmpty) {
        tls['server_name'] = sni;
      } else if (!tls.containsKey('server_name') &&
          server.isNotEmpty &&
          (forceEnabled || cleanExtra['transport'] != null)) {
        tls['server_name'] = server;
      }
      if (alpn.isNotEmpty) tls['alpn'] = alpn;
      if (allowInsecure && allowInsecureFlag) tls['insecure'] = true;
      if (certSha256 is List && certSha256.isNotEmpty) {
        tls['certificate_sha256'] = certSha256;
      }
      if (pq) tls['pq'] = true;
      if (fp.isNotEmpty) {
        tls['utls'] = {'enabled': true, 'fingerprint': fp};
      } else if (tls['utls'] is Map) {
        final u = Map<String, dynamic>.from(tls['utls'] as Map);
        final existingFp = u['fingerprint']?.toString() ?? '';
        u['enabled'] = u['enabled'] ?? true;
        u['fingerprint'] = existingFp.isNotEmpty
            ? normalizeUtlsFingerprint(existingFp)
            : 'chrome';
        tls['utls'] = u;
      } else if (isReality) {
        tls['utls'] = {'enabled': true, 'fingerprint': 'chrome'};
      }
      if (isReality) {
        final cleanSid = normalizeRealityShortId(shortId);
        tls['reality'] = {
          'enabled': true,
          'public_key': publicKey.trim(),
          if (cleanSid.isNotEmpty) 'short_id': cleanSid,
          if (pq) 'support_x25519mlkem768': true,
        };
      }
      return tls;
    }

    final shouldUseTls = security != 'none' &&
        (isReality ||
            security == 'tls' ||
            security == 'reality' ||
            security == 'xtls' ||
            sni.isNotEmpty ||
            alpn.isNotEmpty ||
            allowInsecure ||
            certSha256 != null ||
            cleanExtra['tls'] is Map);

    switch (type) {
      case 'vless':
        final outbound = <String, dynamic>{
          'type': 'vless',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': uuid,
        };
        if (shouldUseTls || (security != 'none' && cleanExtra['transport'] == null)) {
          outbound['tls'] = buildTlsObject();
        }
        final cleanFlow = normalizeVlessFlow(flow);
        if (cleanFlow.isNotEmpty) outbound['flow'] = cleanFlow;
        if (cleanExtra['packet_encoding'] != null) {
          final pe = cleanExtra['packet_encoding'].toString();
          if (pe != 'packetaddr' && pe != 'xudp') {
            cleanExtra.remove('packet_encoding');
          }
        }
        return outbound..addAll(cleanExtra);

      case 'vmess':
        final outbound = <String, dynamic>{
          'type': 'vmess',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': uuid,
          'security': vmessSecurity.isNotEmpty ? vmessSecurity : 'auto',
        };
        if (shouldUseTls) {
          outbound['tls'] = buildTlsObject();
        }
        return outbound..addAll(cleanExtra);

      case 'trojan':
        final outbound = <String, dynamic>{
          'type': 'trojan',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': password,
        };
        if (security != 'none') {
          outbound['tls'] = buildTlsObject(forceEnabled: true);
        }
        return outbound..addAll(cleanExtra);

      case 'shadowsocks':
        return {
          'type': 'shadowsocks',
          'tag': tag,
          'server': server,
          'server_port': port,
          'method': method.isEmpty ? 'aes-256-gcm' : method,
          'password': password,
        }..addAll(cleanExtra);

      case 'hysteria2':
        final rawObfs = cleanExtra.remove('obfs');
        final obfsPw = cleanExtra.remove('obfs-password')?.toString() ?? '';
        Map<String, dynamic>? obfsObj;
        if (rawObfs is Map) {
          obfsObj = Map<String, dynamic>.from(rawObfs);
        } else if (rawObfs is String && rawObfs.isNotEmpty && rawObfs != 'none') {
          obfsObj = {'type': rawObfs, 'password': obfsPw};
        }
        return {
          'type': 'hysteria2',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': password,
          'obfs': ?obfsObj,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'hysteria':
        return {
          'type': 'hysteria',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty && !cleanExtra.containsKey('auth_str'))
            'auth_str': password,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'tuic':
        return {
          'type': 'tuic',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': uuid,
          'password': password,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'anytls':
        return {
          'type': 'anytls',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': password,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'naive':
        return {
          'type': 'naive',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty) 'password': password,
          'tls': buildTlsObject(forceEnabled: true, allowInsecureFlag: false),
        }..addAll(cleanExtra);

      case 'snell':
        final psk = (cleanExtra.remove('psk') ?? password).toString();
        final rawVer = (cleanExtra.remove('version') as num?)?.toInt() ?? 4;
        final ver = (rawVer == 4 || rawVer == 6) ? rawVer : 4;
        cleanExtra.remove('tls');
        cleanExtra.remove('obfs');
        return {
          'type': 'snell',
          'tag': tag,
          'server': server,
          'server_port': port,
          'psk': psk,
          'version': ver,
        }..addAll(cleanExtra);

      case 'shadowtls':
        return {
          'type': 'shadowtls',
          'tag': tag,
          'server': server,
          'server_port': port,
          'version': (cleanExtra.remove('version') as num?)?.toInt() ?? 3,
          'password': password,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'fptn':
        cleanExtra.remove('tls');
        if (cleanExtra.containsKey('token')) {
          return {
            'type': 'fptn',
            'tag': tag,
            'token': cleanExtra['token'],
          };
        }
        return {
          'type': 'fptn',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty) 'password': password,
        }..addAll(cleanExtra);

      case 'socks':
        cleanExtra.remove('tls');
        return {
          'type': 'socks',
          'tag': tag,
          'server': server,
          'server_port': port,
          'version': (cleanExtra.remove('version') ?? '5').toString(),
          if (password.isNotEmpty) 'password': password,
        }..addAll(cleanExtra);

      case 'http':
        final outbound = <String, dynamic>{
          'type': 'http',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty) 'password': password,
        };
        if (shouldUseTls) outbound['tls'] = buildTlsObject(forceEnabled: true);
        return outbound..addAll(cleanExtra);

      case 'ssh':
        cleanExtra.remove('tls');
        return {
          'type': 'ssh',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty) 'password': password,
        }..addAll(cleanExtra);

      case 'mtproto':
        cleanExtra.remove('tls');
        final mtTr = cleanExtra.remove('mtproto_transport')?.toString() ?? '';
        return {
          'type': 'mtproto',
          'tag': tag,
          'server': server,
          'server_port': port,
          'secret': (cleanExtra.remove('secret') ?? password).toString(),
          if (mtTr.isNotEmpty) 'transport': mtTr,
          if (sni.isNotEmpty) 'tls': {'enabled': true, 'server_name': sni},
        }..addAll(cleanExtra);

      case 'mieru':
        cleanExtra.remove('tls');
        final mieruTr = (cleanExtra.remove('mieru_transport') ?? 'TCP').toString().toUpperCase();
        final hasPortRanges = cleanExtra['server_ports'] is List &&
            (cleanExtra['server_ports'] as List).isNotEmpty;
        return {
          'type': 'mieru',
          'tag': tag,
          'server': server,
          if (!hasPortRanges) 'server_port': port,
          'transport': mieruTr == 'UDP' ? 'UDP' : 'TCP',
          if (password.isNotEmpty) 'password': password,
        }..addAll(cleanExtra);

      case 'tewfai':
        final tewfaiTr = cleanExtra.remove('tewfai_transport');
        return {
          'type': 'tewfai',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (uuid.isNotEmpty) 'uuid': uuid,
          if (password.isNotEmpty) 'password': password,
          'transport': ?tewfaiTr,
          if (security != 'none') 'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      case 'masque':
        final privKey = (cleanExtra.remove('private_key') ?? password).toString();
        final pubKey = (cleanExtra.remove('public_key') ??
                cleanExtra.remove('peer_public_key') ??
                publicKey)
            .toString();
        final outbound = <String, dynamic>{
          'type': 'masque',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (privKey.isNotEmpty) 'private_key': privKey,
          if (pubKey.isNotEmpty) 'public_key': pubKey,
        };
        if (shouldUseTls || cleanExtra['profile'] == 'standard') {
          outbound['tls'] = buildTlsObject(forceEnabled: true);
        }
        return outbound..addAll(cleanExtra);

      case 'trusttunnel':
      case 'openconnect':
        return {
          'type': type,
          'tag': tag,
          'server': server,
          'server_port': port,
          if (password.isNotEmpty) 'password': password,
          'tls': buildTlsObject(forceEnabled: true),
        }..addAll(cleanExtra);

      default:
        final outbound = <String, dynamic>{
          'type': type,
          'tag': tag,
          'server': server,
          'server_port': port,
          if (uuid.isNotEmpty) 'uuid': uuid,
          if (password.isNotEmpty) 'password': password,
        };
        if (shouldUseTls) {
          outbound['tls'] = buildTlsObject();
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
    final trFromExtra = (rawExtra['transport'] is Map)
        ? ((rawExtra['transport'] as Map)['type']?.toString() ?? '')
        : '';
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

  /// Собирает стандартную ссылку (`vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://`,
  /// `tuic://`, `wg://`, `anytls://`, `naive+https://`, `snell://`, `socks5://`)
  /// или JSON-строку для экспорта и генерации QR-кода.
  String toShareUri() {
    final encodedName = Uri.encodeComponent(name.isNotEmpty ? name : '$server:$port');
    final hostFmt = server.contains(':') && !server.startsWith('[') ? '[$server]' : server;
    final trMap = extra['transport'] is Map
        ? Map<String, dynamic>.from(extra['transport'] as Map)
        : null;
    final net = (trMap?['type']?.toString() ?? transport).toLowerCase();

    void appendTransportParams(Map<String, String> params) {
      params['type'] = net.isEmpty ? 'tcp' : net;
      if (trMap == null) return;
      if (trMap['path'] != null && trMap['path'].toString().isNotEmpty) {
        params['path'] = trMap['path'].toString();
      }
      if (trMap['host'] != null) {
        final h = trMap['host'];
        params['host'] = h is List ? h.join(',') : h.toString();
      } else if (trMap['headers'] is Map && (trMap['headers'] as Map)['Host'] != null) {
        params['host'] = (trMap['headers'] as Map)['Host'].toString();
      }
      if (trMap['mode'] != null && trMap['mode'].toString().isNotEmpty) {
        params['mode'] = trMap['mode'].toString();
      }
      if (trMap['service_name'] != null && trMap['service_name'].toString().isNotEmpty) {
        params['serviceName'] = trMap['service_name'].toString();
      }
    }

    switch (type) {
      case 'vless':
        final params = <String, String>{};
        if (extra['encryption'] != null && extra['encryption'].toString().isNotEmpty) {
          params['encryption'] = extra['encryption'].toString();
        } else {
          params['encryption'] = 'none';
        }
        appendTransportParams(params);
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
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'vless://$uuid@$hostFmt:$port?$q#$encodedName';

      case 'vmess':
        final v2 = <String, dynamic>{
          'v': '2',
          'ps': name.isNotEmpty ? name : '$server:$port',
          'add': server,
          'port': port.toString(),
          'id': uuid,
          'aid': (extra['alter_id'] ?? 0).toString(),
          'scy': (extra['vmess_security'] ?? 'auto').toString(),
          'net': net.isEmpty ? 'tcp' : net,
          'type': 'none',
          'host': (trMap?['host'] ?? '').toString(),
          'path': (trMap?['path'] ?? trMap?['service_name'] ?? '').toString(),
          'tls': hasTls ? 'tls' : '',
          if (sni.isNotEmpty) 'sni': sni,
          if (alpn.isNotEmpty) 'alpn': alpn.join(','),
          if (extra['fp'] != null) 'fp': extra['fp'].toString(),
        };
        final encoded = base64.encode(utf8.encode(jsonEncode(v2)));
        return 'vmess://$encoded';

      case 'trojan':
        final params = <String, String>{};
        appendTransportParams(params);
        if (isReality) {
          params['security'] = 'reality';
          if (publicKey.isNotEmpty) params['pbk'] = publicKey;
          if (shortId.isNotEmpty) params['sid'] = shortId;
        }
        if (sni.isNotEmpty) params['sni'] = sni;
        if (alpn.isNotEmpty) params['alpn'] = alpn.join(',');
        if (allowInsecure) params['allowInsecure'] = '1';
        if (extra['fp'] != null && extra['fp'].toString().isNotEmpty) {
          params['fp'] = extra['fp'].toString();
        }
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'trojan://${Uri.encodeComponent(password)}@$hostFmt:$port?$q#$encodedName';

      case 'shadowsocks':
        final creds = base64Url
            .encode(utf8.encode('${method.isEmpty ? "aes-256-gcm" : method}:$password'))
            .replaceAll('=', '');
        final params = <String, String>{
          if (extra['udp_over_tcp'] == true) 'uot': '1',
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'ss://$creds@$hostFmt:$port${q.isEmpty ? "" : "?$q"}#$encodedName';

      case 'hysteria2':
        final obfsMap = extra['obfs'] is Map ? extra['obfs'] as Map : null;
        final obfsType = obfsMap != null ? obfsMap['type']?.toString() : extra['obfs']?.toString();
        final obfsPw = obfsMap != null
            ? obfsMap['password']?.toString()
            : extra['obfs-password']?.toString();
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (alpn.isNotEmpty) 'alpn': alpn.join(','),
          if (allowInsecure) 'insecure': '1',
          if (obfsType != null && obfsType.isNotEmpty) 'obfs': obfsType,
          if (obfsPw != null && obfsPw.isNotEmpty) 'obfs-password': obfsPw,
          if (extra['server_ports'] is List && (extra['server_ports'] as List).isNotEmpty)
            'mport': (extra['server_ports'] as List).join(','),
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'hy2://${Uri.encodeComponent(password)}@$hostFmt:$port${q.isEmpty ? "" : "?$q"}#$encodedName';

      case 'tuic':
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (alpn.isNotEmpty) 'alpn': alpn.join(','),
          if (allowInsecure) 'allowInsecure': '1',
          if (extra['congestion_control'] != null)
            'congestion_control': extra['congestion_control'].toString(),
          if (extra['udp_relay_mode'] != null)
            'udp_relay_mode': extra['udp_relay_mode'].toString(),
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'tuic://$uuid:${Uri.encodeComponent(password)}@$hostFmt:$port${q.isEmpty ? "" : "?$q"}#$encodedName';

      case 'wireguard':
        final privKey = (extra['private_key'] ?? password).toString();
        final pubKey = (extra['peer_public_key'] ?? publicKey).toString();
        final addrs = extra['local_address'] is List
            ? (extra['local_address'] as List).join(',')
            : '10.0.0.2/32';
        final params = <String, String>{
          'publickey': pubKey,
          'address': addrs,
          if (extra['pre_shared_key'] != null) 'psk': extra['pre_shared_key'].toString(),
          if (extra['mtu'] != null) 'mtu': extra['mtu'].toString(),
        };
        for (final k in ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4', 'h1', 'h2', 'h3', 'h4', 'i1']) {
          if (extra[k] != null && extra[k].toString().isNotEmpty) {
            params[k] = extra[k].toString();
          }
        }
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        final scheme = isAmneziaWg ? 'amneziawg' : 'wg';
        return '$scheme://${Uri.encodeComponent(privKey)}@$hostFmt:$port?$q#$encodedName';

      case 'anytls':
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (allowInsecure) 'insecure': '1',
          if (isReality) 'security': 'reality',
          if (publicKey.isNotEmpty) 'pbk': publicKey,
          if (shortId.isNotEmpty) 'sid': shortId,
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'anytls://${Uri.encodeComponent(password)}@$hostFmt:$port${q.isEmpty ? "" : "?$q"}#$encodedName';

      case 'naive':
        final scheme = extra['quic'] == true ? 'naive+quic' : 'naive+https';
        final user = (extra['username'] ?? '').toString();
        return '$scheme://${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@$hostFmt:$port#$encodedName';

      case 'snell':
        final psk = (extra['psk'] ?? password).toString();
        final ver = (extra['version'] ?? 5).toString();
        return 'snell://${Uri.encodeComponent(psk)}@$hostFmt:$port?version=$ver#$encodedName';

      case 'socks':
        final user = (extra['username'] ?? '').toString();
        final auth = user.isNotEmpty
            ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@'
            : '';
        return 'socks5://$auth$hostFmt:$port#$encodedName';

      case 'http':
        final user = (extra['username'] ?? '').toString();
        final auth = user.isNotEmpty
            ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@'
            : '';
        final scheme = hasTls ? 'https' : 'http';
        return '$scheme://$auth$hostFmt:$port#$encodedName';

      case 'ssh':
        final user = (extra['user'] ?? 'root').toString();
        final auth = password.isNotEmpty
            ? '${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@'
            : '${Uri.encodeComponent(user)}@';
        return 'ssh://$auth$hostFmt:$port#$encodedName';

      case 'tewfai':
        final trList = extra['tewfai_transport'];
        final trStr = trList is List ? trList.join(',') : transport;
        final params = <String, String>{
          if (sni.isNotEmpty) 'sni': sni,
          if (allowInsecure) 'insecure': '1',
          if (extra['pcs'] != null) 'pcs': extra['pcs'].toString(),
          if (trStr.isNotEmpty) 'transport': trStr,
          if (extra['inner_cipher'] != null) 'inner_cipher': extra['inner_cipher'].toString(),
          if (extra['morph_profile'] != null) 'morph_profile': extra['morph_profile'].toString(),
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'tewfai://$uuid:${Uri.encodeComponent(password)}@$hostFmt:$port${q.isEmpty ? "" : "?$q"}#$encodedName';

      case 'mieru':
        final user = (extra['username'] ?? '').toString();
        final mtr = (extra['mieru_transport'] ?? 'TCP').toString().toUpperCase();
        final portRanges = extra['server_ports'] is List
            ? (extra['server_ports'] as List).join(',')
            : '$port';
        final params = <String, String>{
          'port': portRanges,
          'protocol': mtr,
          'profile': name.isNotEmpty ? name : '$server:$port',
        };
        final q = params.entries
            .map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
            .join('&');
        return 'mierus://${Uri.encodeComponent(user)}:${Uri.encodeComponent(password)}@$hostFmt?$q';

      case 'mtproto':
        return 'https://t.me/proxy?server=${Uri.encodeQueryComponent(server)}&port=$port&secret=${Uri.encodeQueryComponent(password)}#$encodedName';

      case 'shadowtls':
        final ver = (extra['version'] ?? 3).toString();
        return 'shadowtls://${Uri.encodeComponent(password)}@$hostFmt:$port?sni=${Uri.encodeQueryComponent(sni.isNotEmpty ? sni : server)}&version=$ver#$encodedName';

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
    this.proxyTlsFragment = false,
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

  /// Включать ли `tls.record_fragment: true` на исходящих прокси-соединениях (против глушилок LTE).
  final bool proxyTlsFragment;

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
    final isAutoGroup = routingMode != RoutingMode.desync &&
        (profile.type == 'urltest' || profile.id.startsWith('auto:'));
    final autoCandidates = isAutoGroup
        ? extraProfiles
            .where((p) =>
                p.server.isNotEmpty &&
                p.type != 'wireguard' &&
                p.type != 'urltest' &&
                p.type != 'direct' &&
                (profile.subscriptionId.isEmpty || p.subscriptionId == profile.subscriptionId))
            .take(50)
            .toList(growable: false)
        : const <Profile>[];

    final hasStatic = routingMode != RoutingMode.desync &&
        !isAutoGroup &&
        profile.server.isNotEmpty &&
        profile.type != 'direct';
    final enabledSubs = (routingMode == RoutingMode.desync || hasStatic || autoCandidates.isNotEmpty)
        ? const <SubscriptionEntry>[]
        : subscriptions.where((sub) => sub.enabled).toList(growable: false);
    final hasProxy = hasStatic || autoCandidates.isNotEmpty || enabledSubs.isNotEmpty;

    final dedicatedOutbounds = <String, Map<String, dynamic>>{};
    final dedicatedEndpoints = <String, Map<String, dynamic>>{};

    String resolveOutbound(String raw) {
      final target = raw.isEmpty ? 'proxy' : raw;
      if (target.startsWith('profile:')) {
        final profId = target.substring('profile:'.length);
        for (final p in extraProfiles) {
          if (p.id == profId && p.server.isNotEmpty) {
            final tag = 'srv-${p.id}';
            if (p.type == 'wireguard') {
              dedicatedEndpoints.putIfAbsent(tag, () => p.toWireGuardEndpoint(tag: tag));
            } else {
              dedicatedOutbounds.putIfAbsent(tag, () => p.toOutbound(tag: tag));
            }
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

    final isMainWg = hasStatic && profile.type == 'wireguard';
    final isDetourWg = hasDetour && detourProfile!.type == 'wireguard';

    Map<String, dynamic> buildMainProfileOutbound({String tag = 'proxy'}) {
      final out = profile.toOutbound(tag: tag);
      if (hasDetour) {
        out['detour'] = 'detour-proxy';
      }
      return out;
    }

    Map<String, dynamic> buildMainProfileEndpoint({String tag = 'proxy'}) {
      final ep = profile.toWireGuardEndpoint(tag: tag);
      if (hasDetour) {
        ep['detour'] = 'detour-proxy';
      }
      return ep;
    }

    final chainOutbounds = <Map<String, dynamic>>[];
    final chainEndpoints = <Map<String, dynamic>>[];
    if (hasStatic && !hasDetour && profile.extra['chain_outbounds'] is List) {
      for (final rawHop in profile.extra['chain_outbounds'] as List) {
        if (rawHop is! Map) continue;
        final hop = normalizeOutboundNode(Map<String, dynamic>.from(rawHop));
        if ((hop['type'] ?? '').toString().toLowerCase() == 'wireguard') {
          if (!hop.containsKey('peers') && hop['server'] != null) {
            hop['address'] = hop.remove('local_address') ?? ['10.0.0.2/32'];
            hop['peers'] = [
              {
                'address': hop.remove('server'),
                'port': hop.remove('server_port') ?? 51820,
                'public_key': hop.remove('peer_public_key') ?? '',
                'allowed_ips': ['0.0.0.0/0', '::/0'],
              },
            ];
          }
          chainEndpoints.add(hop);
        } else {
          chainOutbounds.add(hop);
        }
      }
    }

    final autoMemberTags = <String>[];
    final autoMemberOutbounds = <Map<String, dynamic>>[];
    if (autoCandidates.isNotEmpty) {
      for (var i = 0; i < autoCandidates.length; i++) {
        final cand = autoCandidates[i];
        final memberTag = 'auto-srv-$i';
        final node = cand.toOutbound(tag: memberTag);
        if (cand.extra['chain_outbounds'] is List && (cand.extra['chain_outbounds'] as List).isNotEmpty) {
          final rawHops = cand.extra['chain_outbounds'] as List;
          final tagMap = <String, String>{};
          for (var h = 0; h < rawHops.length; h++) {
            final hopMap = rawHops[h];
            if (hopMap is Map && hopMap['tag'] != null) {
              tagMap[hopMap['tag'].toString()] = 'auto-hop-$i-$h';
            }
          }
          if (node['detour'] != null && tagMap.containsKey(node['detour'].toString())) {
            node['detour'] = tagMap[node['detour'].toString()];
          }
          for (var h = 0; h < rawHops.length; h++) {
            final rawHop = rawHops[h];
            if (rawHop is! Map) continue;
            final hop = normalizeOutboundNode(Map<String, dynamic>.from(rawHop));
            if ((hop['type'] ?? '').toString().toLowerCase() == 'wireguard') continue;
            final oldTag = hop['tag']?.toString() ?? '';
            hop['tag'] = tagMap[oldTag] ?? 'auto-hop-$i-$h';
            if (hop['detour'] != null && tagMap.containsKey(hop['detour'].toString())) {
              hop['detour'] = tagMap[hop['detour'].toString()];
            }
            autoMemberOutbounds.add(hop);
          }
        }
        autoMemberTags.add(memberTag);
        autoMemberOutbounds.insert(autoMemberTags.length - 1, node);
      }
    }

    final endpoints = <Map<String, dynamic>>[
      if (subTags.isEmpty && isMainWg) buildMainProfileEndpoint(),
      if (subTags.isNotEmpty && isMainWg) buildMainProfileEndpoint(tag: 'profile'),
      if (isDetourWg) detourProfile!.toWireGuardEndpoint(tag: 'detour-proxy'),
      ...chainEndpoints,
      ...dedicatedEndpoints.values,
    ];

    final outbounds = <Map<String, dynamic>>[
      if (autoMemberTags.isNotEmpty) ...[
        {
          'type': 'urltest',
          'tag': 'proxy',
          'outbounds': autoMemberTags,
          'url': 'https://www.gstatic.com/generate_204',
          'interval': '3m',
          'tolerance': 50,
        },
        ...autoMemberOutbounds,
      ],
      if (autoMemberTags.isEmpty && subTags.isEmpty && hasStatic && !isMainWg)
        buildMainProfileOutbound(),
      if (autoMemberTags.isEmpty && subTags.isNotEmpty)
        {
          'type': 'selector',
          'tag': 'proxy',
          'outbounds': [
            if (hasStatic) 'profile',
            ...subTags,
          ],
          'default': hasStatic ? 'profile' : subTags.first,
        },
      if (autoMemberTags.isEmpty && subTags.isNotEmpty && hasStatic && !isMainWg)
        buildMainProfileOutbound(tag: 'profile'),
      if (hasDetour && !isDetourWg) detourProfile!.toOutbound(tag: 'detour-proxy'),
      ...chainOutbounds,
      ...dedicatedOutbounds.values,
      {'type': 'direct', 'tag': 'direct'},
      {'type': 'block', 'tag': 'block'},
    ];

    if (proxyTlsFragment) {
      for (final out in outbounds) {
        final outType = (out['type'] ?? '').toString().toLowerCase();
        if (outType == 'naive') continue;
        if (out['tls'] is Map) {
          final tls = Map<String, dynamic>.from(out['tls'] as Map);
          if (tls['enabled'] == true) {
            tls['record_fragment'] = true;
            out['tls'] = tls;
          }
        }
      }
    }

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
      if (endpoints.isNotEmpty) 'endpoints': endpoints,
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

/// Приводит uTLS-отпечатки Xray / Go (`hellochrome_120`, `chrome_120`, `hellofirefox_auto`,
/// `hellosafari_16_0`, `helloios_14`, `helloandroid_11_okhttp`, `randomizedalpn` и др.)
/// к строгому списку `UTLS_FINGERPRINTS` валидатора `tachyon-core`.
String normalizeUtlsFingerprint(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return '';
  const valid = {
    'chrome',
    'chrome_psk',
    'chrome_psk_shuffle',
    'chrome_padding_psk_shuffle',
    'chrome_pq',
    'chrome_pq_psk',
    'firefox',
    'safari',
    'edge',
    '360',
    'qq',
    'ios',
    'android',
    'randomized',
    'random',
  };
  if (valid.contains(s)) return s;
  final stripped = s.startsWith('hello')
      ? s.substring(5).replaceFirst(RegExp(r'^_+'), '')
      : s;
  if (valid.contains(stripped)) return stripped;
  if (stripped.startsWith('chrome')) {
    if (stripped.contains('padding') &&
        stripped.contains('psk') &&
        stripped.contains('shuffle')) {
      return 'chrome_padding_psk_shuffle';
    }
    if (stripped.contains('pq') && stripped.contains('psk')) {
      return 'chrome_pq_psk';
    }
    if (stripped.contains('pq')) return 'chrome_pq';
    if (stripped.contains('psk') && stripped.contains('shuffle')) {
      return 'chrome_psk_shuffle';
    }
    if (stripped.contains('psk')) return 'chrome_psk';
    return 'chrome';
  }
  if (stripped.startsWith('firefox') || stripped.startsWith('ff')) {
    return 'firefox';
  }
  if (stripped.startsWith('safari')) return 'safari';
  if (stripped.startsWith('edge')) return 'edge';
  if (stripped.startsWith('ios')) return 'ios';
  if (stripped.startsWith('android') || stripped.contains('okhttp')) {
    return 'android';
  }
  if (stripped.startsWith('360')) return '360';
  if (stripped.startsWith('qq')) return 'qq';
  if (stripped.startsWith('randomized')) return 'randomized';
  if (stripped.startsWith('random')) return 'random';
  return 'chrome';
}

/// Очищает `short_id` Reality до допустимых 1..16 hex-символов.
String normalizeRealityShortId(String raw) {
  final hex = raw.trim().replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (hex.isEmpty) return '';
  return hex.length > 16 ? hex.substring(0, 16) : hex;
}

/// Нормализует `flow` для VLESS (`xtls-rprx-vision-udp443` → `xtls-rprx-vision`).
String normalizeVlessFlow(String raw) {
  final f = raw.trim();
  if (f.isEmpty || f.toLowerCase() == 'none') return '';
  if (f.toLowerCase().startsWith('xtls-rprx-vision')) {
    return 'xtls-rprx-vision';
  }
  return f;
}

/// Нормализует произвольный узел outbound (включая транзитные `chain_outbounds`).
Map<String, dynamic> normalizeOutboundNode(Map<String, dynamic> rawNode) {
  final node = Map<String, dynamic>.from(rawNode);
  if (node['flow'] != null) {
    final cleanFlow = normalizeVlessFlow(node['flow'].toString());
    if (cleanFlow.isEmpty) {
      node.remove('flow');
    } else {
      node['flow'] = cleanFlow;
    }
  }
  if (node['packet_encoding'] != null) {
    final pe = node['packet_encoding'].toString();
    if (pe != 'packetaddr' && pe != 'xudp') {
      node.remove('packet_encoding');
    }
  }
  if (node['tls'] is Map) {
    final tls = Map<String, dynamic>.from(node['tls'] as Map);
    if (tls['utls'] is Map) {
      final utls = Map<String, dynamic>.from(tls['utls'] as Map);
      final rawFp = utls['fingerprint']?.toString() ?? '';
      utls['enabled'] = utls['enabled'] ?? true;
      utls['fingerprint'] = rawFp.isNotEmpty
          ? normalizeUtlsFingerprint(rawFp)
          : 'chrome';
      tls['utls'] = utls;
    }
    if (tls['reality'] is Map) {
      final reality = Map<String, dynamic>.from(tls['reality'] as Map);
      if (reality['short_id'] != null) {
        final sid = normalizeRealityShortId(reality['short_id'].toString());
        if (sid.isEmpty) {
          reality.remove('short_id');
        } else {
          reality['short_id'] = sid;
        }
      }
      tls['reality'] = reality;
      if (reality['enabled'] == true && tls['utls'] == null) {
        tls['utls'] = {'enabled': true, 'fingerprint': 'chrome'};
      }
    }
    node['tls'] = tls;
  }
  if (node['transport'] is Map) {
    final tr = Map<String, dynamic>.from(node['transport'] as Map);
    final trType = tr['type']?.toString().toLowerCase() ?? '';
    if (trType == 'xhttp' || trType == 'splithttp') {
      node['transport'] = normalizeXhttpTransport(tr);
    }
  }
  return node;
}

String? _formatXhttpRange(Object? val) {
  if (val == null) return null;
  if (val is num) return val.toInt().toString();
  if (val is String) {
    final s = val.trim();
    return s.isEmpty ? null : s;
  }
  if (val is List && val.length == 2) {
    final a = int.tryParse(val[0].toString().trim());
    final b = int.tryParse(val[1].toString().trim());
    if (a != null && b != null) {
      return a == b ? '$a' : '$a-$b';
    }
  }
  if (val is Map && (val.containsKey('from') || val.containsKey('to'))) {
    final from = int.tryParse((val['from'] ?? 0).toString().trim()) ?? 0;
    final to = int.tryParse((val['to'] ?? from).toString().trim()) ?? from;
    return from == to ? '$from' : '$from-$to';
  }
  return null;
}

/// Приводит параметры XHTTP-транспорта к строгому каноническому формату ядpa
/// (snake_case, правильные типы, отсечение неизвестных camelCase полей Xray).
Map<String, dynamic> normalizeXhttpTransport(Map<String, dynamic> rawInput) {
  final raw = Map<String, dynamic>.from(rawInput);
  while (raw['extra'] != null) {
    final extraVal = raw.remove('extra');
    if (extraVal is Map) {
      for (final entry in extraVal.entries) {
        raw.putIfAbsent(entry.key.toString(), () => entry.value);
      }
    } else if (extraVal is String && extraVal.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(extraVal);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            raw.putIfAbsent(entry.key.toString(), () => entry.value);
          }
        }
      } catch (_) {}
    } else {
      break;
    }
  }

  final out = <String, dynamic>{'type': 'xhttp'};

  void setStr(String targetKey, List<String> sourceKeys) {
    for (final k in sourceKeys) {
      if (raw.containsKey(k) && raw[k] != null) {
        final v = raw[k];
        if (v is Map || v is List) continue;
        final val = v.toString().trim();
        if (val.isNotEmpty) {
          out[targetKey] = val;
          return;
        }
      }
    }
  }

  void setRange(String targetKey, List<String> sourceKeys) {
    for (final k in sourceKeys) {
      if (raw.containsKey(k) && raw[k] != null) {
        final formatted = _formatXhttpRange(raw[k]);
        if (formatted != null && formatted.isNotEmpty) {
          out[targetKey] = formatted;
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
          final parsed = int.tryParse(val.trim());
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
  setStr('session_placement', ['session_placement', 'sessionPlacement', 'sessionIDPlacement', 'sessionIdPlacement', 'session_id_placement']);
  setStr('session_key', ['session_key', 'sessionKey', 'sessionIDKey', 'sessionIdKey', 'session_id_key']);
  setStr('seq_placement', ['seq_placement', 'seqPlacement']);
  setStr('seq_key', ['seq_key', 'seqKey']);
  setStr('session_table', ['session_table', 'sessionTable', 'sessionIDTable', 'sessionIdTable', 'session_id_table']);
  setRange('session_length', ['session_length', 'sessionLength', 'sessionIDLength', 'sessionIdLength', 'session_id_length']);
  setStr('uplink_data_placement', ['uplink_data_placement', 'uplinkDataPlacement']);
  setStr('uplink_data_key', ['uplink_data_key', 'uplinkDataKey']);
  setRange('uplink_chunk_size', ['uplink_chunk_size', 'uplinkChunkSize']);
  setStr('uplink_http_method', ['uplink_http_method', 'uplinkHttpMethod', 'uplinkHTTPMethod']);
  setRange('x_padding_bytes', ['x_padding_bytes', 'xPaddingBytes', 'xpaddingbytes']);
  setStr('x_padding_key', ['x_padding_key', 'xPaddingKey']);
  setStr('x_padding_header', ['x_padding_header', 'xPaddingHeader']);
  setStr('x_padding_placement', ['x_padding_placement', 'xPaddingPlacement']);
  setStr('x_padding_method', ['x_padding_method', 'xPaddingMethod']);
  setRange('sc_max_each_post_bytes', ['sc_max_each_post_bytes', 'scMaxEachPostBytes']);
  setRange('sc_min_posts_interval_ms', ['sc_min_posts_interval_ms', 'scMinPostsIntervalMs']);
  setRange('sc_stream_up_server_secs', ['sc_stream_up_server_secs', 'scStreamUpServerSecs']);

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
          final r = _formatXhttpRange(v);
          if (r != null && r != '0' && r != '0-0') {
            muxOut['max_concurrency'] = r;
          }
          break;
        case 'max_connections':
        case 'maxConnections':
          final r = _formatXhttpRange(v);
          if (r != null && r != '0' && r != '0-0') {
            muxOut['max_connections'] = int.tryParse(r) ?? r;
          }
          break;
        case 'c_max_reuse_times':
        case 'cMaxReuseTimes':
          final r = _formatXhttpRange(v);
          if (r != null) muxOut['c_max_reuse_times'] = r;
          break;
        case 'h_max_request_times':
        case 'hMaxRequestTimes':
          final r = _formatXhttpRange(v);
          if (r != null) muxOut['h_max_request_times'] = r;
          break;
        case 'h_max_reusable_secs':
        case 'hMaxReusableSecs':
        case 'maxReusableSecs':
          final r = _formatXhttpRange(v);
          if (r != null) muxOut['h_max_reusable_secs'] = r;
          break;
        case 'h_keep_alive_period':
        case 'hKeepAlivePeriod':
          final n = v is num ? v.toInt() : int.tryParse(v.toString().trim());
          if (n != null) muxOut['h_keep_alive_period'] = n;
          break;
      }
    }
    if (muxOut.containsKey('max_concurrency') && muxOut.containsKey('max_connections')) {
      muxOut.remove('max_connections');
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
