import 'dart:convert';

import '../models/runtime_config.dart';

/// Разбор ссылок и подписок всех протоколов и форматов, поддерживаемых `tachyon-core`:
/// - URI: `vless://`, `vmess://` (URI и V2RayN Base64 JSON), `trojan://`,
///   `ss://` / `shadowsocks://` (SIP002, Legacy Base64, SS-2022, плагины, UoT),
///   `hy2://` / `hysteria2://`, `hysteria://`, `tuic://`,
///   `wg://` / `wireguard://` / `amneziawg://` / `awg://` (WireGuard + AmneziaWG),
///   `anytls://`, `naive+https://` / `naive+quic://` / `naive://`,
///   `snell://`, `shadowtls://`, `fptn:` / `fptnb:`,
///   `socks://` / `socks5://` / `socks5h://` / `socks4://`, `http://` / `https://` (прокси),
///   `ssh://`, `mtproto://` / `tg://proxy`, `mieru://`, `masque://`, `trusttunnel://`, `openconnect://`.
/// - Подписки и конфиги:
///   - Списки URI (сырые и в Base64 / URL-safe Base64)
///   - Sing-box JSON (`outbounds` или массив / одиночный аутбаунд)
///   - Xray / V2Ray JSON (`outbounds` с `protocol`, `settings`, `streamSettings`)
///   - SIP008 Shadowsocks JSON (`servers`)
///   - Clash / Mihomo YAML (`proxies:`)
///   - WireGuard / AmneziaWG `.conf` INI (`[Interface]` + `[Peer]`)
class LinkParser {
  const LinkParser();

  /// Разбирает список ссылок или многострочный конфиг.
  List<Profile> parseMany(String content, {String subscriptionId = ''}) {
    final trimmed = content.trim().replaceFirst('\uFEFF', '');
    if (trimmed.isEmpty) return const [];

    // 1. Токены FPTN (fptn: / fptnb: или JSON токена FPTN)
    if (isFptnPayload(trimmed)) {
      final fptnProfiles = _parseFptnToken(trimmed, subscriptionId: subscriptionId);
      if (fptnProfiles.isNotEmpty) return fptnProfiles;
    }

    // 2. JSON: sing-box, Xray/V2Ray, SIP008
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      final jsonProfiles = _parseJsonPayload(trimmed, subscriptionId: subscriptionId);
      if (jsonProfiles.isNotEmpty) return jsonProfiles;
    }

    // 3. WireGuard / AmneziaWG INI-конфиг ([Interface] ... [Peer])
    if (looksLikeWireGuardConf(trimmed)) {
      final wgProfiles = parseWireGuardConfAll(trimmed, subscriptionId: subscriptionId);
      if (wgProfiles.isNotEmpty) return wgProfiles;
    }

    // 4. Clash / Mihomo YAML (секция proxies:)
    if (RegExp(r'(^|\n)\s*proxies\s*:', multiLine: true).hasMatch(trimmed)) {
      final clashProfiles = _parseClashYaml(trimmed, subscriptionId: subscriptionId);
      if (clashProfiles.isNotEmpty) return clashProfiles;
    }

    // 5. Построчный разбор URI и одиночных JSON-строк
    final profiles = <Profile>[];
    for (final raw in trimmed.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      if (_isFptnToken(line)) {
        profiles.addAll(_parseFptnToken(line, subscriptionId: subscriptionId));
        continue;
      }
      final profile = parse(line, subscriptionId: subscriptionId);
      if (profile != null) profiles.add(profile);
    }
    return profiles;
  }

  /// Автоопределение и разбор любого содержимого подписки (URI, Base64, JSON, Clash YAML, WG .conf, FPTN).
  List<Profile> parseSubscription(String content, {String subscriptionId = ''}) {
    final trimmed = content.trim().replaceFirst('\uFEFF', '');
    if (trimmed.isEmpty) return const [];

    // Прямой разбор (JSON, YAML, WG .conf, FPTN, либо список URI)
    final direct = parseMany(trimmed, subscriptionId: subscriptionId);
    if (direct.isNotEmpty) return direct;

    // Попытка декодировать Base64 (внутри может быть список URI, JSON, Clash YAML или WG .conf)
    final normalized = _normalizeBase64(trimmed);
    if (normalized.isNotEmpty) {
      try {
        final decoded = utf8.decode(base64.decode(normalized), allowMalformed: true);
        final parsed = parseMany(decoded, subscriptionId: subscriptionId);
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {}

      try {
        final decoded = latin1.decode(base64.decode(normalized));
        final parsed = parseMany(decoded, subscriptionId: subscriptionId);
        if (parsed.isNotEmpty) return parsed;
      } catch (_) {}
    }

    return const [];
  }

  /// Конвертирует узлы `nodes` и `primary_tags`, разобранные нативным движком `tachyon-core`,
  /// в список `Profile` с сохранением транзитных цепочек `detour` (`chain_outbounds`).
  List<Profile> parseEngineNodes(
    List<dynamic> rawNodes,
    List<dynamic> rawPrimaryTags, {
    String subscriptionId = '',
  }) {
    final nodes = <Map<String, dynamic>>[];
    final byTag = <String, Map<String, dynamic>>{};
    for (final item in rawNodes) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      nodes.add(map);
      final tag = (map['tag'] ?? '').toString().trim();
      if (tag.isNotEmpty) {
        byTag[tag] = map;
      }
    }
    if (nodes.isEmpty) return const [];

    final primarySet = rawPrimaryTags
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toSet();

    final primaryNodes = primarySet.isNotEmpty
        ? nodes.where((n) => primarySet.contains((n['tag'] ?? '').toString().trim())).toList()
        : nodes;

    final out = <Profile>[];
    for (final rawNode in primaryNodes) {
      final mainNode = Map<String, dynamic>.from(rawNode);
      final firstHopTag = (mainNode['detour'] ?? '').toString().trim();
      if (firstHopTag.isNotEmpty && byTag.containsKey(firstHopTag)) {
        final chainOutbounds = <Map<String, dynamic>>[];
        final visited = <String>{};
        var currTag = firstHopTag;
        while (currTag.isNotEmpty && byTag.containsKey(currTag) && visited.add(currTag)) {
          final hop = Map<String, dynamic>.from(byTag[currTag]!);
          chainOutbounds.add(hop);
          final nextTag = (hop['detour'] ?? '').toString().trim();
          if (nextTag.isNotEmpty && byTag.containsKey(nextTag)) {
            currTag = nextTag;
          } else {
            hop.remove('detour');
            currTag = '';
          }
        }
        if (chainOutbounds.isNotEmpty) {
          mainNode['chain_outbounds'] = chainOutbounds;
        }
      }
      final profile = _outboundMapToProfile(mainNode, subscriptionId: subscriptionId);
      if (profile != null) {
        out.add(profile);
      }
    }
    return out;
  }

  /// Разбирает одну ссылку или одиночный JSON-объект.
  Profile? parse(String link, {String subscriptionId = ''}) {
    final value = link.trim().replaceFirst('\uFEFF', '');
    if (value.isEmpty) return null;

    if (isFptnPayload(value)) {
      final list = _parseFptnToken(value, subscriptionId: subscriptionId);
      return list.isNotEmpty ? list.first : null;
    }

    if (looksLikeWireGuardConf(value)) {
      return _parseWireGuardConf(value, subscriptionId: subscriptionId);
    }

    final lower = value.toLowerCase();
    if (lower.startsWith('vless://')) return _parseVless(value, subscriptionId: subscriptionId);
    if (lower.startsWith('vmess://')) return _parseVmess(value, subscriptionId: subscriptionId);
    if (lower.startsWith('trojan://')) return _parseTrojan(value, subscriptionId: subscriptionId);
    if (lower.startsWith('ss://') || lower.startsWith('shadowsocks://')) {
      return _parseShadowsocks(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('hysteria2://') || lower.startsWith('hy2://')) {
      return _parseHysteria2(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('hysteria://')) return _parseHysteria1(value, subscriptionId: subscriptionId);
    if (lower.startsWith('tuic://')) return _parseTuic(value, subscriptionId: subscriptionId);
    if (lower.startsWith('wg://') ||
        lower.startsWith('wireguard://') ||
        lower.startsWith('amneziawg://') ||
        lower.startsWith('awg://')) {
      return _parseWireGuardUri(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('anytls://')) return _parseAnytls(value, subscriptionId: subscriptionId);
    if (lower.startsWith('naive+https://') ||
        lower.startsWith('naive+http2://') ||
        lower.startsWith('naive+h2://') ||
        lower.startsWith('naive+quic://') ||
        lower.startsWith('naive+h3://') ||
        lower.startsWith('naive://')) {
      return _parseNaive(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('snell://')) return _parseSnell(value, subscriptionId: subscriptionId);
    if (lower.startsWith('shadowtls://')) return _parseShadowTls(value, subscriptionId: subscriptionId);
    if (lower.startsWith('socks5://') ||
        lower.startsWith('socks5h://') ||
        lower.startsWith('socks4://') ||
        lower.startsWith('socks://')) {
      return _parseSocks(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      if (lower.contains('://t.me/proxy') || lower.contains('://telegram.me/proxy')) {
        return _parseMtproto(value, subscriptionId: subscriptionId);
      }
      return _parseHttpProxy(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('ssh://')) return _parseSsh(value, subscriptionId: subscriptionId);
    if (lower.startsWith('mtproto://') || lower.startsWith('tg://proxy')) {
      return _parseMtproto(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('mieru://') || lower.startsWith('mierus://')) {
      return _parseMieru(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('tewfai://')) {
      return _parseTewfai(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('masque://')) return _parseMasque(value, subscriptionId: subscriptionId);
    if (lower.startsWith('trusttunnel://')) {
      return _parseTrustTunnel(value, subscriptionId: subscriptionId);
    }
    if (lower.startsWith('openconnect://') || lower.startsWith('anyconnect://')) {
      return _parseOpenConnect(value, subscriptionId: subscriptionId);
    }

    if (value.startsWith('{') || value.startsWith('[')) {
      final list = _parseJsonPayload(value, subscriptionId: subscriptionId);
      return list.isNotEmpty ? list.first : null;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // VLESS
  // ---------------------------------------------------------------------------

  Profile? _parseVless(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final uuid = Uri.decodeComponent(uri.userInfo);
    if (uuid.isEmpty) return null;

    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;

    final rawType = (query['type'] ?? query['net'] ?? 'tcp').toLowerCase();
    final transportType = _normalizeTransportName(rawType);
    final rawSec = (query['security'] ?? '').trim().toLowerCase();
    final pbk = query['pbk'] ?? query['publicKey'] ?? '';
    final sid = query['sid'] ?? query['shortId'] ?? '';
    final sni = query['sni'] ?? query['peer'] ?? query['serverName'] ?? '';
    final security = rawSec.isNotEmpty
        ? rawSec
        : (pbk.isNotEmpty ? 'reality' : (sni.isNotEmpty ? 'tls' : 'none'));

    final extra = <String, dynamic>{
      'security': security,
      if ((query['fp'] ?? query['fingerprint'] ?? '').isNotEmpty)
        'fp': normalizeUtlsFingerprint(query['fp'] ?? query['fingerprint'] ?? ''),
    };

    final encryption = query['encryption'] ?? '';
    if (encryption.isNotEmpty && encryption != 'none') {
      extra['encryption'] = encryption;
    }
    final packetEncoding = query['packetEncoding'] ?? query['packet_encoding'] ?? '';
    if (packetEncoding.isNotEmpty) {
      extra['packet_encoding'] = packetEncoding;
    }
    if (_isTruthy(query['pq'] ?? query['support_x25519mlkem768'] ?? query['support-x25519mlkem768'])) {
      extra['pq'] = true;
    }
    if (_isTruthy(query['fragment'] ?? query['tls_fragment'])) {
      extra['tls_fragment'] = true;
    }
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    final trMap = _buildTransportFromQuery(transportType, query);
    if (trMap != null) {
      extra['transport'] = trMap;
    }

    final resolvedName = _name(query, uri.fragment, '$server:$port');
    return Profile(
      id: _id('vless', '$server:$port:$uuid:$resolvedName:${query['path'] ?? ''}'),
      name: resolvedName,
      type: 'vless',
      server: server,
      port: port,
      uuid: uuid,
      transport: transportType,
      sni: sni,
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['allowInsecure'] ?? query['insecure']),
      flow: normalizeVlessFlow(query['flow'] ?? ''),
      publicKey: pbk.trim(),
      shortId: normalizeRealityShortId(sid),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  // ---------------------------------------------------------------------------
  // VMess (стандартный URI и V2RayN Base64 JSON)
  // ---------------------------------------------------------------------------

  Profile? _parseVmess(String link, {String subscriptionId = ''}) {
    final payload = link.substring('vmess://'.length).trim();
    if (payload.contains('@')) {
      final uri = Uri.tryParse(link);
      if (uri != null && uri.host.isNotEmpty && uri.userInfo.isNotEmpty) {
        final query = uri.queryParameters;
        final server = _cleanHost(uri.host);
        final port = uri.port == 0 ? 443 : uri.port;
        final uuid = Uri.decodeComponent(uri.userInfo);
        final transportType = _normalizeTransportName(query['type'] ?? query['net'] ?? 'tcp');
        final rawSec = (query['security'] ?? '').trim().toLowerCase();
        final sni = query['sni'] ?? query['peer'] ?? '';
        final pbk = query['pbk'] ?? '';
        final security = rawSec.isNotEmpty
            ? rawSec
            : (pbk.isNotEmpty ? 'reality' : (sni.isNotEmpty ? 'tls' : 'none'));
        final extra = <String, dynamic>{
          'security': security,
          'vmess_security': query['encryption'] ?? query['scy'] ?? 'auto',
          if ((query['fp'] ?? '').isNotEmpty) 'fp': query['fp'],
        };
        _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);
        final trMap = _buildTransportFromQuery(transportType, query);
        if (trMap != null) extra['transport'] = trMap;
        final resolvedName = _name(query, uri.fragment, '$server:$port');
        return Profile(
          id: _id('vmess', '$server:$port:$uuid:$resolvedName'),
          name: resolvedName,
          type: 'vmess',
          server: server,
          port: port,
          uuid: uuid,
          transport: transportType,
          sni: sni,
          alpn: _splitCsv(query['alpn']),
          allowInsecure: _isTruthy(query['allowInsecure'] ?? query['insecure']),
          publicKey: pbk,
          shortId: query['sid'] ?? '',
          subscriptionId: subscriptionId,
          extra: extra,
        );
      }
    }

    try {
      final rawB64 = payload.split('#').first;
      final decoded = utf8.decode(base64.decode(_normalizeBase64(rawB64)), allowMalformed: true);
      final map = jsonDecode(decoded);
      if (map is! Map) return null;
      final server = _cleanHost((map['add'] ?? '').toString());
      if (server.isEmpty) return null;
      final port = _toInt(map['port']) ?? 443;
      final uuid = (map['id'] ?? '').toString();
      if (uuid.isEmpty) return null;
      final aid = _toInt(map['aid']) ?? 0;
      final scy = (map['scy'] ?? map['security'] ?? 'auto').toString();
      final net = _normalizeTransportName((map['net'] ?? 'tcp').toString());
      final tlsVal = (map['tls'] ?? '').toString().toLowerCase();
      final useTls = tlsVal == 'tls' || tlsVal == 'true' || tlsVal == '1';
      final host = (map['host'] ?? '').toString();
      final path = (map['path'] ?? '').toString();
      final sni = (map['sni'] ?? '').toString().isNotEmpty
          ? map['sni'].toString()
          : (useTls ? host : '');
      final fp = (map['fp'] ?? '').toString();

      final extra = <String, dynamic>{
        'security': useTls ? 'tls' : 'none',
        'vmess_security': scy.isEmpty ? 'auto' : scy,
        if (aid > 0) 'alter_id': aid,
        if (fp.isNotEmpty) 'fp': fp,
      };
      _extractCertPin(extra, map['pcs']?.toString());

      final trMap = _buildTransportFromQuery(net, {
        if (path.isNotEmpty) 'path': path,
        if (host.isNotEmpty) 'host': host,
        if (net == 'grpc' && path.isNotEmpty) 'serviceName': path,
        if (map['mode'] != null) 'mode': map['mode'].toString(),
      });
      if (trMap != null) extra['transport'] = trMap;

      final ps = (map['ps'] ?? '').toString().trim();
      return Profile(
        id: _id('vmess', '$server:$port:$uuid:$ps'),
        name: ps.isNotEmpty ? ps : '$server:$port',
        type: 'vmess',
        server: server,
        port: port,
        uuid: uuid,
        transport: net,
        sni: sni,
        alpn: _splitCsv(map['alpn']?.toString()),
        allowInsecure: _isTruthy(map['allowInsecure']?.toString() ?? map['insecure']?.toString()) ||
            (useTls && map['verify_cert'] == false),
        subscriptionId: subscriptionId,
        extra: extra,
      );
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Trojan
  // ---------------------------------------------------------------------------

  Profile? _parseTrojan(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final password = Uri.decodeComponent(uri.userInfo);
    if (password.isEmpty) return null;

    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final transportType = _normalizeTransportName(query['type'] ?? query['net'] ?? 'tcp');
    final rawSec = (query['security'] ?? '').trim().toLowerCase();
    final pbk = query['pbk'] ?? query['publicKey'] ?? '';
    final sid = query['sid'] ?? query['shortId'] ?? '';
    final security = rawSec.isNotEmpty ? rawSec : (pbk.isNotEmpty ? 'reality' : 'tls');
    final sni = query['sni'] ?? query['peer'] ?? query['serverName'] ?? '';

    final extra = <String, dynamic>{
      'security': security,
      if ((query['fp'] ?? query['fingerprint'] ?? '').isNotEmpty)
        'fp': normalizeUtlsFingerprint(query['fp'] ?? query['fingerprint'] ?? ''),
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);
    final trMap = _buildTransportFromQuery(transportType, query);
    if (trMap != null) extra['transport'] = trMap;

    final resolvedName = _name(query, uri.fragment, '$server:$port');
    return Profile(
      id: _id('trojan', '$server:$port:$password:$resolvedName:${query['path'] ?? ''}'),
      name: resolvedName,
      type: 'trojan',
      server: server,
      port: port,
      password: password,
      transport: transportType,
      sni: sni,
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['allowInsecure'] ?? query['insecure']),
      publicKey: pbk,
      shortId: sid,
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  // ---------------------------------------------------------------------------
  // Shadowsocks (SIP002, Legacy Base64, SS-2022, плагины, UoT)
  // ---------------------------------------------------------------------------

  Profile? _parseShadowsocks(String link, {String subscriptionId = ''}) {
    final withoutScheme = link.startsWith('shadowsocks://')
        ? link.substring('shadowsocks://'.length)
        : link.substring('ss://'.length);

    final hashIdx = withoutScheme.indexOf('#');
    final bodyPart = hashIdx >= 0 ? withoutScheme.substring(0, hashIdx) : withoutScheme;
    final fragment = hashIdx >= 0 ? withoutScheme.substring(hashIdx + 1) : '';

    final qIdx = bodyPart.indexOf('?');
    final mainPart = qIdx >= 0 ? bodyPart.substring(0, qIdx) : bodyPart;
    final queryPart = qIdx >= 0 ? bodyPart.substring(qIdx + 1) : '';
    final query = _parseQuerySafe(queryPart);

    String userInfo;
    String hostPort;
    if (mainPart.contains('@')) {
      final atIdx = mainPart.lastIndexOf('@');
      userInfo = mainPart.substring(0, atIdx);
      hostPort = mainPart.substring(atIdx + 1);
      final decodedUser = Uri.decodeComponent(userInfo);
      if (decodedUser.contains(':')) {
        userInfo = decodedUser;
      } else {
        try {
          userInfo = utf8.decode(base64.decode(_normalizeBase64(decodedUser)));
        } catch (_) {
          return null;
        }
      }
    } else {
      // Legacy ss://base64(method:password@host:port)
      try {
        final decoded = utf8.decode(base64.decode(_normalizeBase64(mainPart.replaceAll('/', ''))));
        final atIdx = decoded.lastIndexOf('@');
        if (atIdx <= 0) return null;
        userInfo = decoded.substring(0, atIdx);
        hostPort = decoded.substring(atIdx + 1);
      } catch (_) {
        return null;
      }
    }

    final sep = userInfo.indexOf(':');
    if (sep <= 0) return null;
    final method = userInfo.substring(0, sep).trim();
    final password = userInfo.substring(sep + 1);

    final hp = _splitHostPort(hostPort.replaceAll('/', ''), 8388);
    if (hp == null) return null;

    final extra = <String, dynamic>{};
    final pluginRaw = query['plugin'] ?? '';
    if (pluginRaw.isNotEmpty) {
      final semi = pluginRaw.indexOf(';');
      if (semi >= 0) {
        extra['plugin'] = pluginRaw.substring(0, semi);
        extra['plugin_opts'] = pluginRaw.substring(semi + 1);
      } else {
        extra['plugin'] = pluginRaw;
      }
    }
    if (_isTruthy(query['uot'] ?? query['udp-over-tcp'])) {
      extra['udp_over_tcp'] = true;
    }

    final resolvedName = _name(query, fragment, '${hp.$1}:${hp.$2}');
    return Profile(
      id: _id('ss', '${hp.$1}:${hp.$2}:$method:$password'),
      name: resolvedName,
      type: 'shadowsocks',
      server: hp.$1,
      port: hp.$2,
      method: method,
      password: password,
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  // ---------------------------------------------------------------------------
  // Hysteria 2 & Hysteria v1
  // ---------------------------------------------------------------------------

  Profile? _parseHysteria2(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final password = Uri.decodeComponent(uri.userInfo.isNotEmpty ? uri.userInfo : (query['auth'] ?? ''));

    final extra = <String, dynamic>{};
    final obfs = query['obfs'] ?? '';
    if (obfs.isNotEmpty && obfs.toLowerCase() != 'none') {
      extra['obfs'] = {
        'type': obfs,
        'password': query['obfs-password'] ?? query['obfs_password'] ?? '',
      };
    }
    final up = _toInt(query['upmbps'] ?? query['up']);
    if (up != null && up > 0) extra['up_mbps'] = up;
    final down = _toInt(query['downmbps'] ?? query['down']);
    if (down != null && down > 0) extra['down_mbps'] = down;

    final mport = query['mport'] ?? query['ports'] ?? '';
    if (mport.isNotEmpty) {
      final ports = mport
          .split(',')
          .map((s) => s.trim().replaceAll('-', ':'))
          .where((s) => s.isNotEmpty)
          .toList();
      if (ports.isNotEmpty) extra['server_ports'] = ports;
    }
    if ((query['hop_interval'] ?? '').isNotEmpty) {
      extra['hop_interval'] = query['hop_interval'];
    }
    _extractCertPin(extra, query['pinSHA256'] ?? query['pcs']);

    return Profile(
      id: _id('hysteria2', '$server:$port:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'hysteria2',
      server: server,
      port: port,
      password: password,
      sni: query['sni'] ?? query['peer'] ?? '',
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseHysteria1(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final auth = query['auth'] ?? Uri.decodeComponent(uri.userInfo);

    return Profile(
      id: _id('hysteria', '$server:$port:$auth'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'hysteria',
      server: server,
      port: port,
      password: auth,
      sni: query['peer'] ?? query['sni'] ?? '',
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: {
        if (auth.isNotEmpty) 'auth_str': auth,
        if (_toInt(query['upmbps'] ?? query['up']) != null)
          'up_mbps': _toInt(query['upmbps'] ?? query['up']),
        if (_toInt(query['downmbps'] ?? query['down']) != null)
          'down_mbps': _toInt(query['downmbps'] ?? query['down']),
        if ((query['obfs'] ?? '').isNotEmpty) 'obfs': query['obfs'],
      },
    );
  }

  // ---------------------------------------------------------------------------
  // TUIC v5
  // ---------------------------------------------------------------------------

  Profile? _parseTuic(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final userInfo = uri.userInfo;
    final separator = userInfo.indexOf(':');
    final uuid = Uri.decodeComponent(separator < 0 ? userInfo : userInfo.substring(0, separator));
    final password = Uri.decodeComponent(separator < 0 ? (query['password'] ?? '') : userInfo.substring(separator + 1));

    final extra = <String, dynamic>{
      'congestion_control':
          query['congestion_control'] ?? query['congestion-control'] ?? 'bbr',
      if ((query['udp_relay_mode'] ?? query['udp-relay-mode'] ?? '').isNotEmpty)
        'udp_relay_mode': query['udp_relay_mode'] ?? query['udp-relay-mode'],
      if (_isTruthy(query['zero_rtt_handshake'] ?? query['reduce_rtt']))
        'zero_rtt_handshake': true,
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('tuic', '$server:$port:$uuid:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'tuic',
      server: server,
      port: port,
      uuid: uuid,
      password: password,
      sni: query['sni'] ?? '',
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  // ---------------------------------------------------------------------------
  // WireGuard & AmneziaWG (URI, amneziawg://<base64-ini>#name и .conf INI)
  // ---------------------------------------------------------------------------

  /// Проверяет, является ли текст конфигурационным файлом `.conf` WireGuard / AmneziaWG.
  bool looksLikeWireGuardConf(String s) {
    return RegExp(r'\[\s*interface\s*\]', caseSensitive: false).hasMatch(s) &&
        RegExp(r'\[\s*peer\s*\]', caseSensitive: false).hasMatch(s);
  }

  Profile? _parseWireGuardUri(String link, {String subscriptionId = ''}) {
    final schemeIdx = link.indexOf('://');
    if (schemeIdx > 0) {
      final afterScheme = link.substring(schemeIdx + 3).trim();
      final hashIdx = afterScheme.indexOf('#');
      final bodyPart = hashIdx >= 0 ? afterScheme.substring(0, hashIdx).trim() : afterScheme;
      final fragPart = hashIdx >= 0 ? afterScheme.substring(hashIdx + 1).trim() : '';
      // Формат роутера Tachyon: amneziawg://<base64-encoded-INI>#<name>
      if (!bodyPart.contains('@') && !bodyPart.contains('?')) {
        try {
          final decoded = utf8.decode(base64.decode(_normalizeBase64(bodyPart)), allowMalformed: true);
          if (looksLikeWireGuardConf(decoded)) {
            String? nameOverride;
            if (fragPart.isNotEmpty) {
              try {
                nameOverride = Uri.decodeComponent(fragPart);
              } catch (_) {
                nameOverride = fragPart;
              }
            }
            return _parseWireGuardConf(
              decoded,
              subscriptionId: subscriptionId,
              nameOverride: nameOverride,
            );
          }
        } catch (_) {}
      }
    }

    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 51820 : uri.port;

    final privKey = Uri.decodeComponent(
      uri.userInfo.isNotEmpty
          ? uri.userInfo
          : (query['privatekey'] ?? query['private_key'] ?? query['private-key'] ?? ''),
    );
    final pubKey = Uri.decodeComponent(
      query['publickey'] ?? query['public_key'] ?? query['peer_public_key'] ?? query['public-key'] ?? '',
    );
    if (privKey.isEmpty || pubKey.isEmpty) return null;

    bool isMasqueProto(String? v) {
      if (v == null) return false;
      final t = v.trim().toLowerCase();
      return t == 'dns' || t == 'stun' || t == 'sip' || t == 'quic';
    }

    final rawQueryIp = query['ip'];
    final addrsRaw = query['address'] ??
        query['local_address'] ??
        (!isMasqueProto(rawQueryIp) ? rawQueryIp : null) ??
        '10.0.0.2/32';
    final localAddress = addrsRaw
        .split(',')
        .map((s) => _formatWgCidr(s.trim()))
        .where((s) => s.isNotEmpty)
        .toList();

    final extra = <String, dynamic>{
      'private_key': privKey,
      'peer_public_key': pubKey,
      'local_address': localAddress.isEmpty ? ['10.0.0.2/32'] : localAddress,
    };

    final psk = query['psk'] ?? query['presharedkey'] ?? query['pre_shared_key'] ?? '';
    if (psk.isNotEmpty) extra['pre_shared_key'] = Uri.decodeComponent(psk);

    final mtu = _toInt(query['mtu']);
    if (mtu != null && mtu > 0) extra['mtu'] = mtu;

    final rawKeepalive = (query['keepalive'] ??
            query['persistent_keepalive'] ??
            query['persistent_keepalive_interval'] ??
            '')
        .trim();
    if (rawKeepalive.isNotEmpty) {
      final kaInt = _toInt(rawKeepalive);
      if (kaInt != null && kaInt > 0) {
        extra['persistent_keepalive_interval'] = kaInt;
      } else if (rawKeepalive.contains('-')) {
        extra['persistent_keepalive_interval'] = rawKeepalive;
      }
    }

    final reserved = _parseWgReserved(query['reserved']);
    if (reserved != null) extra['reserved'] = reserved;

    _extractAwgParams(query, extra, fromUriQuery: true);

    return Profile(
      id: _id('wireguard', '$server:$port:$privKey:$pubKey'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'wireguard',
      server: server,
      port: port,
      password: privKey,
      publicKey: pubKey,
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseWireGuardConf(
    String conf, {
    String subscriptionId = '',
    String? nameOverride,
  }) {
    final list = parseWireGuardConfAll(
      conf,
      subscriptionId: subscriptionId,
      nameOverride: nameOverride,
    );
    return list.isNotEmpty ? list.first : null;
  }

  /// Разбирает конфигурационный файл `.conf` WireGuard / AmneziaWG (1.5, 2.0, 3.0, 3.1)
  /// с поддержкой одной или нескольких секций `[Peer]`.
  List<Profile> parseWireGuardConfAll(
    String conf, {
    String subscriptionId = '',
    String? nameOverride,
  }) {
    var section = '';
    final iface = <String, String>{};
    final peers = <Map<String, String>>[];
    var ifaceCommentName = '';

    for (final rawLine in conf.split(RegExp(r'[\r\n]+'))) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('#') || trimmed.startsWith(';')) {
        final comment = trimmed.substring(1).trim();
        if (comment.isNotEmpty) {
          final eqIdx = comment.indexOf('=');
          if (eqIdx > 0) {
            final ck = comment.substring(0, eqIdx).trim().toLowerCase();
            final cv = comment.substring(eqIdx + 1).trim();
            if (cv.isNotEmpty &&
                (ck == 'name' || ck == 'description' || ck == 'title' || ck == 'tag')) {
              if (section == 'peer' && peers.isNotEmpty) {
                peers.last.putIfAbsent('_comment_name', () => cv);
              } else if (ifaceCommentName.isEmpty) {
                ifaceCommentName = cv;
              }
            }
          } else if (ifaceCommentName.isEmpty &&
              section.isEmpty &&
              comment.length <= 64 &&
              !comment.toLowerCase().startsWith('generated')) {
            ifaceCommentName = comment;
          }
        }
        continue;
      }

      // Срезаем inline-комментарий `# ...`, если он находится вне угловых скобок CPS `<...>`
      var line = trimmed;
      final hashIdx = line.indexOf('#');
      if (hashIdx > 0 && !line.substring(hashIdx).contains('>')) {
        line = line.substring(0, hashIdx).trim();
      }

      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1).trim().toLowerCase();
        if (section == 'peer') {
          peers.add(<String, String>{});
        }
        continue;
      }
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line
          .substring(0, eq)
          .trim()
          .toLowerCase()
          .replaceAll('-', '_');
      var val = line.substring(eq + 1).trim();
      if (val.length >= 2 &&
          ((val.startsWith('"') && val.endsWith('"')) ||
              (val.startsWith("'") && val.endsWith("'")))) {
        val = val.substring(1, val.length - 1).trim();
      }
      if (val.isEmpty) continue;

      if (section == 'interface') {
        if (key == 'address' && iface.containsKey('address')) {
          iface['address'] = '${iface['address']}, $val';
        } else {
          iface[key] = val;
        }
      } else if (section == 'peer' && peers.isNotEmpty) {
        if ((key == 'allowedips' || key == 'allowed_ips') &&
            peers.last.containsKey('allowed_ips')) {
          peers.last['allowed_ips'] = '${peers.last['allowed_ips']}, $val';
        } else {
          peers.last[key == 'allowedips' ? 'allowed_ips' : key] = val;
        }
      }
    }

    final privKey = iface['privatekey'] ?? iface['private_key'] ?? '';
    if (privKey.isEmpty || peers.isEmpty) return const [];

    final addrRaw = iface['address'] ?? '10.0.0.2/32';
    final localAddress = addrRaw
        .split(',')
        .map((s) => _formatWgCidr(s.trim()))
        .where((s) => s.isNotEmpty)
        .toList();
    final mtu = _toInt(iface['mtu']);

    final baseName = (nameOverride != null && nameOverride.trim().isNotEmpty)
        ? nameOverride.trim()
        : ifaceCommentName;

    final results = <Profile>[];
    final validPeers = peers.where((p) {
      final pk = p['publickey'] ?? p['public_key'] ?? '';
      final ep = p['endpoint'] ?? '';
      return pk.isNotEmpty && ep.isNotEmpty;
    }).toList();

    for (var i = 0; i < validPeers.length; i++) {
      final peer = validPeers[i];
      final pubKey = peer['publickey'] ?? peer['public_key'] ?? '';
      final endpoint = peer['endpoint'] ?? '';
      final hp = _splitHostPort(endpoint, 51820);
      if (hp == null) continue;

      final extra = <String, dynamic>{
        'private_key': privKey,
        'peer_public_key': pubKey,
        'local_address': localAddress.isEmpty ? ['10.0.0.2/32'] : localAddress,
      };
      final psk = peer['presharedkey'] ?? peer['pre_shared_key'] ?? '';
      if (psk.isNotEmpty) extra['pre_shared_key'] = psk;
      if (mtu != null && mtu > 0) extra['mtu'] = mtu;

      final allowedRaw = peer['allowed_ips'] ?? '';
      if (allowedRaw.isNotEmpty) {
        final allowedList = allowedRaw
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (allowedList.isNotEmpty) {
          extra['allowed_ips'] = allowedList;
        }
      }

      final kaRaw = (peer['persistentkeepalive'] ??
              peer['persistent_keepalive'] ??
              peer['persistent_keepalive_interval'] ??
              '')
          .trim();
      if (kaRaw.isNotEmpty) {
        final kaInt = _toInt(kaRaw);
        if (kaInt != null && kaInt > 0) {
          extra['persistent_keepalive_interval'] = kaInt;
        } else if (kaRaw.contains('-')) {
          extra['persistent_keepalive_interval'] = kaRaw;
        }
      }

      final reserved = _parseWgReserved(peer['reserved']);
      if (reserved != null) extra['reserved'] = reserved;

      _extractAwgParams(iface, extra);

      final peerComment = peer['_comment_name'] ?? '';
      final String resolvedName;
      if (peerComment.isNotEmpty) {
        resolvedName = peerComment;
      } else if (baseName.isNotEmpty) {
        resolvedName = validPeers.length > 1 ? '$baseName (${i + 1})' : baseName;
      } else {
        resolvedName = '${hp.$1}:${hp.$2}';
      }

      results.add(Profile(
        id: _id('wireguard', '${hp.$1}:${hp.$2}:$privKey:$pubKey'),
        name: resolvedName,
        type: 'wireguard',
        server: hp.$1,
        port: hp.$2,
        password: privKey,
        publicKey: pubKey,
        subscriptionId: subscriptionId,
        extra: extra,
      ));
    }
    return results;
  }

  Object _parseAwgIntOrRange(String raw) {
    final s = raw.trim();
    final asInt = int.tryParse(s);
    if (asInt != null) {
      if (asInt < 0 && asInt >= -2147483648) {
        return asInt + 4294967296;
      }
      return asInt;
    }
    return s;
  }

  void _extractAwgParams(
    Map<String, dynamic> src,
    Map<String, dynamic> dst, {
    bool fromUriQuery = false,
  }) {
    String? pickStr(List<String> keys) {
      for (final k in keys) {
        final v = src[k] ?? src[k.toUpperCase()] ?? src[k.toLowerCase()];
        if (v != null) {
          final s = v.toString().trim();
          if (s.isNotEmpty) return s;
        }
      }
      return null;
    }

    for (final k in const ['jc', 'jmin', 'jmax', 's1', 's2', 's3', 's4']) {
      final raw = pickStr([k]);
      final v = _toInt(raw);
      if (v != null && v >= 0) dst[k] = v;
    }

    for (final (target, aliases) in const [
      ('h1', ['h1']),
      ('h2', ['h2']),
      ('h3', ['h3']),
      ('h4', ['h4']),
      (
        'content_padding_addition',
        ['content_padding_addition', 'contentpaddingaddition', 'ContentPaddingAddition'],
      ),
      (
        'rekey_after_time',
        ['rekey_after_time', 'rekeyaftertime', 'RekeyAfterTime'],
      ),
      (
        'rekey_timeout',
        ['rekey_timeout', 'rekeytimeout', 'RekeyTimeout'],
      ),
      (
        'reject_after_time',
        ['reject_after_time', 'rejectaftertime', 'RejectAfterTime'],
      ),
      (
        'keepalive_timeout',
        ['keepalive_timeout', 'keepalivetimeout', 'KeepaliveTimeout', 'itime', 'ITime'],
      ),
      (
        'max_handshake_attempts',
        ['max_handshake_attempts', 'maxhandshakeattempts', 'MaxHandshakeAttempts'],
      ),
    ]) {
      final raw = pickStr(aliases);
      if (raw != null) {
        dst[target] = _parseAwgIntOrRange(raw);
      }
    }

    for (final (target, aliases) in const [
      ('i1', ['i1', 'j1']),
      ('i2', ['i2', 'j2']),
      ('i3', ['i3', 'j3']),
      ('i4', ['i4']),
      ('i5', ['i5']),
      ('id', ['id']),
      ('ib', ['ib']),
      (
        'header_protection_key',
        ['header_protection_key', 'headerprotectionkey', 'HeaderProtectionKey', 'hpk'],
      ),
    ]) {
      final raw = pickStr(aliases);
      if (raw != null) {
        dst[target] = raw;
      }
    }

    final rawIp = pickStr(fromUriQuery ? ['awg_ip', 'ip'] : ['ip', 'awg_ip']);
    if (rawIp != null) {
      final lowerIp = rawIp.toLowerCase();
      if (!fromUriQuery ||
          lowerIp == 'dns' ||
          lowerIp == 'stun' ||
          lowerIp == 'sip' ||
          lowerIp == 'quic') {
        // В Clash YAML `ip` может быть IPv4-адресом клиента (`10.0.0.2`), поэтому проверяем, что это не IP
        if (!RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(rawIp) && !rawIp.contains(':')) {
          dst['ip'] = lowerIp;
        }
      }
    }

    for (final (target, aliases) in const [
      ('random_trailers', ['random_trailers', 'randomtrailers', 'RandomTrailers']),
      ('disable_cookies', ['disable_cookies', 'disablecookies', 'DisableCookies']),
    ]) {
      final raw = pickStr(aliases);
      if (raw != null && (_isTruthy(raw) || raw.toLowerCase() == 'on')) {
        dst[target] = true;
      }
    }

    // AmneziaWG 3.0+: если задан header_protection_key, s1..s4 должны быть >= 12 (по умолчанию 20)
    if ((dst['header_protection_key']?.toString().trim() ?? '').isNotEmpty) {
      for (final sk in const ['s1', 's2', 's3', 's4']) {
        final cur = _toInt(dst[sk]) ?? 0;
        if (cur < 12) dst[sk] = 20;
      }
    }
    if ((dst['i1']?.toString().trim() ?? '').isNotEmpty) {
      dst
        ..remove('id')
        ..remove('ip')
        ..remove('ib');
    }
  }

  // ---------------------------------------------------------------------------
  // AnyTLS, NaiveProxy, Snell, ShadowTLS, FPTN
  // ---------------------------------------------------------------------------

  Profile? _parseAnytls(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final password = Uri.decodeComponent(uri.userInfo.isNotEmpty ? uri.userInfo : (query['password'] ?? ''));
    final pbk = query['pbk'] ?? query['publicKey'] ?? '';
    final sid = query['sid'] ?? query['shortId'] ?? '';

    final extra = <String, dynamic>{
      if ((query['fp'] ?? query['fingerprint'] ?? '').isNotEmpty)
        'fp': query['fp'] ?? query['fingerprint'],
      if ((query['idle_session_check_interval'] ?? '').isNotEmpty)
        'idle_session_check_interval': query['idle_session_check_interval'],
      if ((query['idle_session_timeout'] ?? '').isNotEmpty)
        'idle_session_timeout': query['idle_session_timeout'],
      if (_toInt(query['min_idle_session']) != null)
        'min_idle_session': _toInt(query['min_idle_session']),
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('anytls', '$server:$port:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'anytls',
      server: server,
      port: port,
      password: password,
      sni: query['sni'] ?? query['peer'] ?? '',
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      publicKey: pbk,
      shortId: sid,
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseNaive(String link, {String subscriptionId = ''}) {
    final lower = link.toLowerCase();
    final normalized = link.replaceFirst(
      RegExp(r'^naive(\+https|\+http2|\+h2|\+quic|\+h3)?://', caseSensitive: false),
      'https://',
    );
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final isQuic = lower.startsWith('naive+quic://') ||
        lower.startsWith('naive+h3://') ||
        _isTruthy(query['quic']);
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final (username, password) = _splitUserPass(uri.userInfo);

    final extra = <String, dynamic>{
      if (username.isNotEmpty) 'username': username,
      if (isQuic) 'quic': true,
      if ((query['quic_congestion_control'] ?? '').isNotEmpty)
        'quic_congestion_control': query['quic_congestion_control'],
      if (_toInt(query['insecure-concurrency'] ?? query['insecure_concurrency']) != null)
        'insecure_concurrency': _toInt(query['insecure-concurrency'] ?? query['insecure_concurrency']),
      if (_isTruthy(query['uot'] ?? query['udp_over_tcp'])) 'udp_over_tcp': true,
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('naive', '$server:$port:$username:$isQuic'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'naive',
      server: server,
      port: port,
      password: password,
      transport: isQuic ? 'quic' : 'tcp',
      sni: query['sni'] ?? server,
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseSnell(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final psk = Uri.decodeComponent(uri.userInfo.isNotEmpty ? uri.userInfo : (query['psk'] ?? ''));
    if (psk.isEmpty) return null;
    final rawVer = _toInt(query['version']) ?? 4;
    final version = (rawVer == 4 || rawVer == 6) ? rawVer : 4;
    final obfs = query['obfs'] ?? query['obfs_mode'] ?? '';
    final obfsHost = query['obfs-host'] ?? query['obfs_host'] ?? query['host'] ?? '';

    return Profile(
      id: _id('snell', '$server:$port:$psk:$version'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'snell',
      server: server,
      port: port,
      password: psk,
      subscriptionId: subscriptionId,
      extra: {
        'psk': psk,
        'version': version,
        if (version == 4 && obfs.isNotEmpty) 'obfs_mode': obfs,
        if (version == 4 && obfsHost.isNotEmpty) 'obfs_host': obfsHost,
        if (version == 6 && (query['mode'] ?? '').isNotEmpty) 'mode': query['mode'],
      },
    );
  }

  Profile? _parseShadowTls(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final password = Uri.decodeComponent(uri.userInfo.isNotEmpty ? uri.userInfo : (query['password'] ?? ''));
    final version = _toInt(query['version']) ?? 3;

    final extra = <String, dynamic>{
      'version': version,
      if ((query['fp'] ?? '').isNotEmpty) 'fp': query['fp'],
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('shadowtls', '$server:$port:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'shadowtls',
      server: server,
      port: port,
      password: password,
      sni: query['sni'] ?? query['peer'] ?? server,
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  /// Проверяет, является ли строка токеном или JSON-конфигом FPTN (`fptn:`, `fptnb:` или JSON с `servers` и `username`).
  bool isFptnPayload(String s) {
    final trimmed = s.trim();
    if (_isFptnToken(trimmed)) return true;
    if (trimmed.startsWith('{') &&
        trimmed.contains('"servers"') &&
        trimmed.contains('"username"') &&
        trimmed.contains('"password"')) {
      return true;
    }
    return false;
  }

  /// Извлекает название сервиса (`service_name` или `#fragment`) из токена FPTN.
  String extractFptnServiceName(String raw) {
    final trimmed = raw.trim();
    final hashIdx = trimmed.indexOf('#');
    if (hashIdx >= 0 && hashIdx + 1 < trimmed.length) {
      final rawFrag = trimmed.substring(hashIdx + 1).trim();
      if (rawFrag.isNotEmpty) {
        try {
          return Uri.decodeComponent(rawFrag);
        } catch (_) {
          return rawFrag;
        }
      }
    }
    try {
      Map<dynamic, dynamic>? map;
      if (trimmed.startsWith('{')) {
        final parsed = jsonDecode(trimmed);
        if (parsed is Map) map = parsed;
      } else if (trimmed.toLowerCase().startsWith('fptn:') ||
          trimmed.toLowerCase().startsWith('fptn://')) {
        final cleanToken = hashIdx >= 0 ? trimmed.substring(0, hashIdx).trim() : trimmed;
        final body = cleanToken
            .replaceFirst(RegExp(r'^fptn(://|:)', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+'), '');
        final decoded = utf8.decode(base64.decode(_normalizeBase64(body)));
        final parsed = jsonDecode(decoded);
        if (parsed is Map) map = parsed;
      }
      final svc = map?['service_name']?.toString().trim() ?? '';
      if (svc.isNotEmpty) return svc;
    } catch (_) {}
    return 'FPTN';
  }

  bool _isFptnToken(String s) {
    final lower = s.toLowerCase();
    return lower.startsWith('fptn:') ||
        lower.startsWith('fptn://') ||
        lower.startsWith('fptnb:') ||
        lower.startsWith('fptnb//') ||
        lower.startsWith('fptnb://');
  }

  List<Profile> _parseFptnToken(String raw, {String subscriptionId = ''}) {
    final trimmed = raw.trim();
    final hashIdx = trimmed.indexOf('#');
    final cleanToken = (!trimmed.startsWith('{') && hashIdx >= 0)
        ? trimmed.substring(0, hashIdx).trim()
        : trimmed;
    var fragName = '';
    if (!trimmed.startsWith('{') && hashIdx >= 0 && hashIdx + 1 < trimmed.length) {
      final rawFrag = trimmed.substring(hashIdx + 1).trim();
      try {
        fragName = Uri.decodeComponent(rawFrag);
      } catch (_) {
        fragName = rawFrag;
      }
    }

    final lower = cleanToken.toLowerCase();
    if (lower.startsWith('fptnb:') || lower.startsWith('fptnb//') || lower.startsWith('fptnb://')) {
      return [
        Profile(
          id: _id('fptn', cleanToken),
          name: fragName.isNotEmpty ? fragName : 'FPTN Server',
          type: 'fptn',
          server: 'fptn.token',
          port: 443,
          subscriptionId: subscriptionId,
          extra: {'token': cleanToken},
        ),
      ];
    }
    try {
      final String jsonStr;
      if (cleanToken.startsWith('{')) {
        jsonStr = cleanToken;
      } else {
        final body = cleanToken
            .replaceFirst(RegExp(r'^fptn(://|:)', caseSensitive: false), '')
            .replaceAll(RegExp(r'\s+'), '');
        jsonStr = utf8.decode(base64.decode(_normalizeBase64(body)));
      }
      final map = jsonDecode(jsonStr);
      if (map is! Map) return const [];
      final user = (map['username'] ?? '').toString();
      final pass = (map['password'] ?? '').toString();
      final service = (map['service_name'] ?? 'FPTN').toString();
      final servers = map['servers'];
      if (servers is! List) return const [];
      final out = <Profile>[];
      for (final srv in servers) {
        if (srv is! Map) continue;
        final host = (srv['host'] ?? '').toString();
        final port = _toInt(srv['port']) ?? 443;
        final srvName = (srv['name'] ?? (fragName.isNotEmpty ? fragName : '$service ($host)')).toString();
        final md5 = (srv['md5_fingerprint'] ?? '').toString();
        if (host.isEmpty) continue;
        out.add(Profile(
          id: _id('fptn', '$host:$port:$user'),
          name: srvName,
          type: 'fptn',
          server: host,
          port: port,
          password: pass,
          subscriptionId: subscriptionId,
          extra: {
            'username': user,
            if (md5.isNotEmpty) 'md5_fingerprint': md5,
          },
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // SOCKS, HTTP, SSH, MTProto, Mieru, TewFai, MASQUE, TrustTunnel, OpenConnect
  // ---------------------------------------------------------------------------

  Profile? _parseSocks(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 1080 : uri.port;
    final (username, password) = _splitUserPass(uri.userInfo);
    final isSocks4 = link.toLowerCase().startsWith('socks4');

    return Profile(
      id: _id('socks', '$server:$port:$username:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'socks',
      server: server,
      port: port,
      password: password,
      subscriptionId: subscriptionId,
      extra: {
        'version': isSocks4 ? '4' : '5',
        if (username.isNotEmpty) 'username': username,
        if (_isTruthy(query['uot'] ?? query['udp-over-tcp'])) 'udp_over_tcp': true,
      },
    );
  }

  /// Разбирает `http://user:pass@host:port#name` только если это именно прокси-сервер
  /// (есть учётные данные или явный порт без пути подписки).
  Profile? _parseHttpProxy(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final hasPath = uri.path.isNotEmpty && uri.path != '/';
    if (hasPath) return null;
    if (uri.userInfo.isEmpty && !uri.hasPort) return null;

    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? (uri.scheme == 'https' ? 443 : 8080) : uri.port;
    final (username, password) = _splitUserPass(uri.userInfo);
    final isHttps = uri.scheme.toLowerCase() == 'https';

    return Profile(
      id: _id('http', '$server:$port:$username:$isHttps'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'http',
      server: server,
      port: port,
      password: password,
      sni: isHttps ? (query['sni'] ?? server) : '',
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: {
        'security': isHttps ? 'tls' : 'none',
        if (username.isNotEmpty) 'username': username,
      },
    );
  }

  Profile? _parseSsh(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 22 : uri.port;
    final (user, password) = _splitUserPass(uri.userInfo);

    return Profile(
      id: _id('ssh', '$server:$port:$user'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'ssh',
      server: server,
      port: port,
      password: password,
      subscriptionId: subscriptionId,
      extra: {
        'user': user.isEmpty ? 'root' : user,
        if ((query['private_key'] ?? '').isNotEmpty) 'private_key': query['private_key'],
      },
    );
  }

  Profile? _parseMtproto(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final query = uri.queryParameters;
    final scheme = uri.scheme.toLowerCase();
    final isTgWeb = scheme == 'tg' || scheme == 'http' || scheme == 'https';
    final server = _cleanHost(
      isTgWeb
          ? (query['server'] ?? '')
          : (uri.host.isNotEmpty && uri.host != 'proxy' ? uri.host : (query['server'] ?? '')),
    );
    if (server.isEmpty) return null;
    final port = _toInt(query['port']) ?? (uri.port == 0 ? 443 : uri.port);
    var secret = (isTgWeb ? (query['secret'] ?? '') : (uri.userInfo.isNotEmpty ? Uri.decodeComponent(uri.userInfo) : (query['secret'] ?? ''))).trim();
    if (secret.isEmpty) return null;

    final normSecret = secret.toLowerCase();
    var paddedPrefix = false;
    if (normSecret.length >= 34 && RegExp(r'^(ee|dd)[0-9a-f]{32}').hasMatch(normSecret)) {
      paddedPrefix = normSecret.startsWith('dd');
      secret = normSecret.substring(2, 34);
    } else if (normSecret.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(normSecret)) {
      secret = normSecret;
    }

    final extra = <String, dynamic>{'secret': secret};
    final tr = (query['transport'] ?? '').trim().toLowerCase();
    if (const {'abridged', 'intermediate', 'padded_intermediate', 'full'}.contains(tr)) {
      extra['mtproto_transport'] = tr;
    } else if (paddedPrefix) {
      extra['mtproto_transport'] = 'padded_intermediate';
    }
    final mode = (query['mode'] ?? '').trim().toLowerCase();
    if (mode == 'mtproto' || mode == 'mtproxy') {
      extra['mode'] = mode;
    }
    final sni = query['sni'] ?? query['faketls'] ?? '';

    return Profile(
      id: _id('mtproto', '$server:$port:$secret'),
      name: _name(query, uri.fragment, 'MTProto $server:$port'),
      type: 'mtproto',
      server: server,
      port: port,
      password: secret,
      sni: sni,
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseMieru(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final (username, password) = _splitUserPass(uri.userInfo);
    if (username.isEmpty || password.isEmpty) return null;

    var port = uri.port;
    final portRanges = <String>[];
    final rawQueryPort = (query['port'] ?? '').trim();
    if (port == 0 && rawQueryPort.isNotEmpty) {
      final singlePort = int.tryParse(rawQueryPort);
      if (singlePort != null && singlePort >= 1 && singlePort <= 65535) {
        port = singlePort;
      } else {
        for (final token in rawQueryPort.split(RegExp(r'[,\s]+'))) {
          final norm = token.trim().replaceAll(':', '-');
          final m = RegExp(r'^(\d+)-(\d+)$').firstMatch(norm);
          if (m != null) {
            final lo = int.tryParse(m.group(1)!);
            final hi = int.tryParse(m.group(2)!);
            if (lo != null && hi != null && lo >= 1 && hi <= 65535 && lo <= hi) {
              portRanges.add('$lo-$hi');
              if (port == 0) port = lo;
            }
          } else {
            final p = int.tryParse(norm);
            if (p != null && p >= 1 && p <= 65535) {
              portRanges.add('$p');
              if (port == 0) port = p;
            }
          }
        }
      }
    }
    if (port == 0) port = 443;

    final rawTr = (query['protocol'] ?? query['transport'] ?? 'TCP').trim().toUpperCase();
    final transport = rawTr == 'UDP' ? 'UDP' : 'TCP';
    final fallbackName = (query['profile'] ?? '').trim().isNotEmpty
        ? query['profile']!.trim()
        : '$server:$port';

    return Profile(
      id: _id('mieru', '$server:$port:$username:$portRanges'),
      name: _name(query, uri.fragment, fallbackName),
      type: 'mieru',
      server: server,
      port: port,
      password: password,
      subscriptionId: subscriptionId,
      extra: {
        'username': username,
        'mieru_transport': transport,
        if (portRanges.isNotEmpty) 'server_ports': portRanges,
        if ((query['multiplexing'] ?? '').isNotEmpty) 'multiplexing': query['multiplexing'],
      },
    );
  }

  Profile? _parseTewfai(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final (uuid, password) = _splitUserPass(uri.userInfo);
    if (uuid.isEmpty) return null;

    final trList = <String>[];
    final rawTr = query['transport'] ?? '';
    if (rawTr.isNotEmpty) {
      for (final item in _splitCsv(rawTr)) {
        var norm = item.toLowerCase();
        if (norm == 'raw_tls' || norm == 'h2' || norm == 'ws') norm = 'tcp';
        if (norm == 'h3_stream' || norm == 'h3_datagram') norm = 'quic';
        if ((norm == 'tcp' || norm == 'quic') && !trList.contains(norm)) {
          trList.add(norm);
        }
      }
    }

    final rotateSecs = int.tryParse(query['rotate_secs'] ?? '');
    final rotateMb = int.tryParse(query['rotate_mb'] ?? '');
    final mtu = int.tryParse(query['mtu'] ?? '');
    final extra = <String, dynamic>{
      if (trList.isNotEmpty) 'tewfai_transport': trList,
      if ((query['inner_cipher'] ?? '').isNotEmpty) 'inner_cipher': query['inner_cipher'],
      if ((query['morph_profile'] ?? '').isNotEmpty) 'morph_profile': query['morph_profile'],
      if (_isTruthy(query['pqc'])) 'pqc': true,
      if (_isTruthy(query['handover']))
        'handover': {
          'enabled': true,
          if (rotateSecs != null && rotateSecs > 0) 'rotate_secs': rotateSecs,
          if (rotateMb != null && rotateMb > 0) 'rotate_mb': rotateMb,
        },
      if (_isTruthy(query['fec'])) 'fec': true,
      if (_isTruthy(query['desync'])) 'desync': true,
      if (_isTruthy(query['shaper']))
        'shaper': {
          'mode': const {'fixed', 'off'}.contains(query['shaper_profile'])
              ? query['shaper_profile']
              : 'adaptive',
        },
      if (mtu != null && mtu >= 256) 'mtu': mtu,
      if ((query['fp'] ?? query['fingerprint'] ?? '').isNotEmpty)
        'fp': query['fp'] ?? query['fingerprint'],
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('tewfai', '$server:$port:$uuid:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'tewfai',
      server: server,
      port: port,
      uuid: uuid,
      password: password,
      transport: trList.contains('quic') ? 'quic' : 'tcp',
      sni: query['sni'] ?? query['peer'] ?? server,
      alpn: _splitCsv(query['alpn']),
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      publicKey: query['pbk'] ?? '',
      shortId: query['sid'] ?? '',
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseMasque(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    final privKey = Uri.decodeComponent(
      (query['private_key'] ?? '').isNotEmpty
          ? query['private_key']!
          : (!uri.userInfo.contains(':') ? uri.userInfo : ''),
    );
    final pubKey = query['public_key'] ?? query['peer_public_key'] ?? '';
    final profileType = (query['profile'] ?? '').isNotEmpty
        ? query['profile']!
        : (privKey.isNotEmpty && pubKey.isNotEmpty ? 'cloudflare' : 'standard');
    final hostFmt = server.contains(':') ? '[$server]' : server;
    final masqueUri = (query['uri'] ?? '').isNotEmpty
        ? query['uri']!
        : (profileType == 'standard'
            ? 'https://$hostFmt:$port/.well-known/masque/ip/*/*/'
            : '');

    final extra = <String, dynamic>{
      'profile': profileType,
      if (privKey.isNotEmpty) 'private_key': privKey,
      if (pubKey.isNotEmpty) 'public_key': pubKey,
      if ((query['vhttp'] ?? '').isNotEmpty) 'vhttp': query['vhttp'],
      if ((query['ip'] ?? query['address'] ?? '').isNotEmpty)
        'ip': query['ip'] ?? query['address'],
      if ((query['ipv6'] ?? '').isNotEmpty) 'ipv6': query['ipv6'],
      if (masqueUri.isNotEmpty) 'uri': masqueUri,
      if (_toInt(query['mtu']) != null) 'mtu': _toInt(query['mtu']),
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('masque', '$server:$port:$privKey:$profileType'),
      name: _name(query, uri.fragment, 'MASQUE $server:$port'),
      type: 'masque',
      server: server,
      port: port,
      password: privKey,
      publicKey: pubKey,
      sni: query['sni'] ?? server,
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseTrustTunnel(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    String username = '';
    String password = '';
    if (uri.userInfo.contains(':')) {
      final split = _splitUserPass(uri.userInfo);
      username = split.$1;
      password = split.$2;
    } else if (uri.userInfo.isNotEmpty) {
      password = Uri.decodeComponent(uri.userInfo);
    }

    final extra = <String, dynamic>{
      if (username.isNotEmpty) 'username': username,
      if (_isTruthy(query['quic'])) 'quic': true,
      if ((query['quic_congestion_control'] ?? query['cc'] ?? '').isNotEmpty)
        'quic_congestion_control': query['quic_congestion_control'] ?? query['cc'],
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('trusttunnel', '$server:$port:$username:$password'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'trusttunnel',
      server: server,
      port: port,
      password: password,
      sni: query['sni'] ?? server,
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  Profile? _parseOpenConnect(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final server = _cleanHost(uri.host);
    final port = uri.port == 0 ? 443 : uri.port;
    var username = '';
    var password = '';
    var cookie = (query['cookie'] ?? '').trim();
    if (uri.userInfo.isNotEmpty) {
      if (uri.userInfo.contains(':')) {
        final split = _splitUserPass(uri.userInfo);
        username = split.$1;
        password = split.$2;
      } else if (cookie.isEmpty) {
        cookie = Uri.decodeComponent(uri.userInfo);
      } else {
        username = Uri.decodeComponent(uri.userInfo);
      }
    }

    final extra = <String, dynamic>{
      'flavor': query['flavor'] ?? 'anyconnect',
      if (username.isNotEmpty) 'username': username,
      if (cookie.isNotEmpty) 'cookie': cookie,
      if ((query['urlpath'] ?? '').isNotEmpty) 'urlpath': query['urlpath'],
      if ((query['realm'] ?? '').isNotEmpty) 'realm': query['realm'],
      if ((query['region'] ?? '').isNotEmpty) 'region': query['region'],
      if ((query['user_agent'] ?? '').isNotEmpty) 'user_agent': query['user_agent'],
      if ((query['local_hostname'] ?? '').isNotEmpty) 'local_hostname': query['local_hostname'],
      if ((query['server_cert_pin'] ?? '').isNotEmpty) 'server_cert_pin': query['server_cert_pin'],
      if ((query['address'] ?? '').isNotEmpty) 'address': query['address']!.split('/').first,
      if ((query['address_v6'] ?? '').isNotEmpty)
        'address_v6': query['address_v6']!.split('/').first,
      if (_isTruthy(query['ip'])) 'ip': true,
      if (_isTruthy(query['esp'])) 'esp': true,
      if (_isTruthy(query['dtls'])) 'dtls': true,
      if (_isTruthy(query['hip_report'])) 'hip_report': true,
      if ((query['mtu'] ?? '').isNotEmpty) 'mtu': query['mtu'],
    };
    _extractCertPin(extra, query['pcs'] ?? query['pinSHA256']);

    return Profile(
      id: _id('openconnect', '$server:$port:$username:$cookie'),
      name: _name(query, uri.fragment, '$server:$port'),
      type: 'openconnect',
      server: server,
      port: port,
      password: password,
      sni: query['sni'] ?? server,
      allowInsecure: _isTruthy(query['insecure'] ?? query['allowInsecure']),
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  // ---------------------------------------------------------------------------
  // Мультиформатный JSON: sing-box, Xray/V2Ray, SIP008
  // ---------------------------------------------------------------------------

  List<Profile> _parseJsonPayload(String raw, {String subscriptionId = ''}) {
    try {
      final decoded = jsonDecode(raw);
      final outbounds = _extractOutboundsFromJson(decoded);
      final profiles = <Profile>[];
      for (final item in outbounds) {
        final p = _outboundMapToProfile(item, subscriptionId: subscriptionId);
        if (p != null) profiles.add(p);
      }
      return profiles;
    } catch (_) {
      return const [];
    }
  }

  List<Map<String, dynamic>> _extractOutboundsFromJson(Object? val) {
    if (val is List) {
      final res = <Map<String, dynamic>>[];
      for (var i = 0; i < val.length; i++) {
        final item = val[i];
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        if (map.containsKey('protocol')) {
          res.addAll(_convertXrayOutbound(i, map));
        } else if (map['type'] is String) {
          final ty = (map['type'] as String).toLowerCase();
          if (!const {'direct', 'block', 'dns', 'selector', 'urltest'}.contains(ty)) {
            res.add(map);
          }
        } else if (map['outbounds'] is List || map['endpoints'] is List) {
          res.addAll(_extractFromFullConfigObject(i, map));
        }
      }
      return res;
    }
    if (val is Map) {
      final map = Map<String, dynamic>.from(val);
      // SIP008: {"version": 1, "servers": [...]}
      if (map['servers'] is List) {
        final servers = map['servers'] as List;
        final res = <Map<String, dynamic>>[];
        for (var i = 0; i < servers.length; i++) {
          final s = servers[i];
          if (s is! Map) continue;
          final srv = Map<String, dynamic>.from(s);
          if (srv['server'] != null && srv['password'] != null) {
            res.add({
              'type': 'shadowsocks',
              'tag': srv['remarks'] ?? srv['id'] ?? 'ss-${i + 1}',
              'server': srv['server'].toString(),
              'server_port': _toInt(srv['server_port']) ?? 8388,
              'method': (srv['method'] ?? 'aes-256-gcm').toString(),
              'password': srv['password'].toString(),
              if (srv['plugin'] != null && srv['plugin'].toString().isNotEmpty)
                'plugin': srv['plugin'].toString(),
              if (srv['plugin_opts'] != null && srv['plugin_opts'].toString().isNotEmpty)
                'plugin_opts': srv['plugin_opts'].toString(),
            });
          }
        }
        if (res.isNotEmpty) return res;
      }
      if (map['outbounds'] is List || map['endpoints'] is List) {
        return _extractFromFullConfigObject(0, map);
      }
      if (map.containsKey('type') || map.containsKey('protocol')) {
        return _extractOutboundsFromJson([map]);
      }
    }
    return const [];
  }

  /// Разбирает полный объект конфигурации Xray / sing-box (в т.ч. элемент массива из 40 конфигов),
  /// сохраняя верхнеуровневое имя (`remarks`/`name`/`ps`) и цепочки прокси (`dialerProxy` / `detour`).
  List<Map<String, dynamic>> _extractFromFullConfigObject(
    int cfgIdx,
    Map<String, dynamic> cfgMap,
  ) {
    final cfgRemarks = (cfgMap['remarks'] ??
            cfgMap['name'] ??
            cfgMap['ps'] ??
            (cfgMap['meta'] is Map ? (cfgMap['meta'] as Map)['name'] : null) ??
            '')
        .toString()
        .trim();

    final rawList = <Object?>[
      if (cfgMap['outbounds'] is List) ...(cfgMap['outbounds'] as List),
      if (cfgMap['endpoints'] is List) ...(cfgMap['endpoints'] as List),
    ];

    final nodes = <Map<String, dynamic>>[];
    for (var i = 0; i < rawList.length; i++) {
      final item = rawList[i];
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      if (map.containsKey('protocol')) {
        nodes.addAll(_convertXrayOutbound(i, map));
      } else if (map['type'] is String) {
        final ty = (map['type'] as String).toLowerCase();
        if (!const {'direct', 'block', 'dns', 'selector', 'urltest'}.contains(ty)) {
          nodes.add(map);
        }
      }
    }
    if (nodes.isEmpty) return const [];

    final byTag = <String, Map<String, dynamic>>{};
    for (final n in nodes) {
      final t = (n['tag'] ?? '').toString().trim();
      if (t.isNotEmpty) byTag[t] = n;
    }

    final detourTargets = <String>{};
    for (final n in nodes) {
      final dt = (n['detour'] ?? '').toString().trim();
      if (dt.isNotEmpty && byTag.containsKey(dt)) {
        detourTargets.add(dt);
      }
    }

    // Если в конфиге есть цепочка (один прокси ссылается через dialerProxy/detour на другой),
    // отделяем входные прокси от транзитных узлов цепочки.
    final entryNodes = detourTargets.isNotEmpty && nodes.length > detourTargets.length
        ? nodes
            .where((n) => !detourTargets.contains((n['tag'] ?? '').toString().trim()))
            .toList()
        : nodes;

    final result = <Map<String, dynamic>>[];
    for (var i = 0; i < entryNodes.length; i++) {
      final mainNode = Map<String, dynamic>.from(entryNodes[i]);
      final firstHopTag = (mainNode['detour'] ?? '').toString().trim();
      if (firstHopTag.isNotEmpty && byTag.containsKey(firstHopTag)) {
        final chainOutbounds = <Map<String, dynamic>>[];
        final visited = <String>{};
        var currTag = firstHopTag;
        while (currTag.isNotEmpty && byTag.containsKey(currTag) && visited.add(currTag)) {
          final hop = Map<String, dynamic>.from(byTag[currTag]!);
          final renamedCurr = 'chain-${cfgIdx + 1}-$currTag';
          hop['tag'] = renamedCurr;
          final nextHopTag = (hop['detour'] ?? '').toString().trim();
          if (nextHopTag.isNotEmpty && byTag.containsKey(nextHopTag)) {
            hop['detour'] = 'chain-${cfgIdx + 1}-$nextHopTag';
            currTag = nextHopTag;
          } else {
            hop.remove('detour');
            currTag = '';
          }
          chainOutbounds.add(hop);
        }
        if (chainOutbounds.isNotEmpty) {
          mainNode['detour'] = 'chain-${cfgIdx + 1}-$firstHopTag';
          mainNode['chain_outbounds'] = chainOutbounds;
        }
      }

      if (cfgRemarks.isNotEmpty) {
        final origTag = (mainNode['tag'] ?? '').toString().trim();
        mainNode['tag'] = entryNodes.length == 1
            ? cfgRemarks
            : (origTag.isEmpty ||
                    origTag == 'proxy' ||
                    origTag == 'out' ||
                    origTag.startsWith('xray-')
                ? '$cfgRemarks #${i + 1}'
                : '$cfgRemarks ($origTag)');
      }
      result.add(mainNode);
    }
    return result;
  }

  /// Конвертирует outbound формата Xray/V2Ray (`protocol` + `settings` + `streamSettings`)
  /// в канонический outbound `tachyon-core`.
  List<Map<String, dynamic>> _convertXrayOutbound(int idx, Map<String, dynamic> obj) {
    final proto = (obj['protocol'] ?? '').toString().toLowerCase();
    if (const {'freedom', 'blackhole', 'dns', 'loopback', 'dokodemo-door'}.contains(proto)) {
      return const [];
    }
    final baseTag = (obj['tag'] ?? '').toString().trim();
    final tag = baseTag.isNotEmpty ? baseTag : 'xray-$proto-${idx + 1}';
    final settings = obj['settings'] is Map
        ? Map<String, dynamic>.from(obj['settings'] as Map)
        : <String, dynamic>{};
    final stream = obj['streamSettings'] is Map
        ? Map<String, dynamic>.from(obj['streamSettings'] as Map)
        : null;
    final sockopt = stream?['sockopt'] is Map
        ? Map<String, dynamic>.from(stream!['sockopt'] as Map)
        : null;
    final proxySettings = obj['proxySettings'] is Map
        ? Map<String, dynamic>.from(obj['proxySettings'] as Map)
        : null;
    final dialerProxy = (sockopt?['dialerProxy'] ??
            sockopt?['dialer_proxy'] ??
            proxySettings?['tag'] ??
            proxySettings?['Tag'] ??
            obj['detour'] ??
            '')
        .toString()
        .trim();

    final out = <Map<String, dynamic>>[];

    void attachStream(Map<String, dynamic> node, String server) {
      if (dialerProxy.isNotEmpty) {
        node['detour'] = dialerProxy;
      }
      if (stream == null) return;
      final tls = _convertXrayTls(stream, server);
      if (tls != null) node['tls'] = tls;
      final tr = _convertXrayTransport(stream);
      if (tr != null) node['transport'] = tr;
    }

    switch (proto) {
      case 'vless':
        final vnext = settings['vnext'] is List ? settings['vnext'] as List : const [];
        for (final v in vnext) {
          if (v is! Map) continue;
          final addr = (v['address'] ?? '').toString();
          final port = _toInt(v['port']) ?? 443;
          final users = v['users'] is List ? v['users'] as List : const [];
          for (final u in users) {
            if (u is! Map) continue;
            final uuid = (u['id'] ?? '').toString();
            if (addr.isEmpty || uuid.isEmpty) continue;
            final node = <String, dynamic>{
              'type': 'vless',
              'tag': tag,
              'server': addr,
              'server_port': port,
              'uuid': uuid,
              if ((u['flow'] ?? '').toString().isNotEmpty &&
                  (u['flow'] ?? '').toString().toLowerCase() != 'none')
                'flow': u['flow'].toString(),
              if ((u['encryption'] ?? 'none').toString().isNotEmpty &&
                  (u['encryption'] ?? 'none').toString().toLowerCase() != 'none')
                'encryption': u['encryption'].toString(),
            };
            attachStream(node, addr);
            out.add(node);
          }
        }
      case 'vmess':
        final vnext = settings['vnext'] is List ? settings['vnext'] as List : const [];
        for (final v in vnext) {
          if (v is! Map) continue;
          final addr = (v['address'] ?? '').toString();
          final port = _toInt(v['port']) ?? 443;
          final users = v['users'] is List ? v['users'] as List : const [];
          for (final u in users) {
            if (u is! Map) continue;
            final uuid = (u['id'] ?? '').toString();
            if (addr.isEmpty || uuid.isEmpty) continue;
            final node = <String, dynamic>{
              'type': 'vmess',
              'tag': tag,
              'server': addr,
              'server_port': port,
              'uuid': uuid,
              'security': (u['security'] ?? 'auto').toString(),
              if ((_toInt(u['alterId']) ?? 0) > 0) 'alter_id': _toInt(u['alterId']),
            };
            attachStream(node, addr);
            out.add(node);
          }
        }
      case 'trojan':
        final servers = settings['servers'] is List ? settings['servers'] as List : const [];
        for (final s in servers) {
          if (s is! Map) continue;
          final addr = (s['address'] ?? '').toString();
          final port = _toInt(s['port']) ?? 443;
          final pass = (s['password'] ?? '').toString();
          if (addr.isEmpty || pass.isEmpty) continue;
          final node = <String, dynamic>{
            'type': 'trojan',
            'tag': tag,
            'server': addr,
            'server_port': port,
            'password': pass,
          };
          attachStream(node, addr);
          out.add(node);
        }
      case 'shadowsocks':
        final servers = settings['servers'] is List ? settings['servers'] as List : const [];
        for (final s in servers) {
          if (s is! Map) continue;
          final addr = (s['address'] ?? '').toString();
          final port = _toInt(s['port']) ?? 8388;
          final method = (s['method'] ?? s['cipher'] ?? 'aes-256-gcm').toString();
          final pass = (s['password'] ?? '').toString();
          if (addr.isEmpty) continue;
          final node = <String, dynamic>{
            'type': 'shadowsocks',
            'tag': tag,
            'server': addr,
            'server_port': port,
            'method': method,
            'password': pass,
            if (s['uot'] == true) 'udp_over_tcp': true,
          };
          if (dialerProxy.isNotEmpty) node['detour'] = dialerProxy;
          out.add(node);
        }
      case 'socks':
      case 'socks5':
        final servers = settings['servers'] is List
            ? settings['servers'] as List
            : (settings['address'] != null ? [settings] : const []);
        for (final s in servers) {
          if (s is! Map) continue;
          final addr = (s['address'] ?? '').toString();
          final port = _toInt(s['port']) ?? 1080;
          if (addr.isEmpty) continue;
          final users = s['users'] is List ? s['users'] as List : const [];
          final u = users.isNotEmpty && users.first is Map ? users.first as Map : null;
          final user = (u?['user'] ?? s['user'] ?? s['username'] ?? '').toString();
          final pass = (u?['pass'] ?? s['pass'] ?? s['password'] ?? '').toString();
          final node = <String, dynamic>{
            'type': 'socks',
            'tag': tag,
            'server': addr,
            'server_port': port,
            if (user.isNotEmpty) 'username': user,
            if (pass.isNotEmpty) 'password': pass,
            if (dialerProxy.isNotEmpty) 'detour': dialerProxy,
          };
          out.add(node);
        }
      case 'http':
        final servers = settings['servers'] is List
            ? settings['servers'] as List
            : (settings['address'] != null ? [settings] : const []);
        for (final s in servers) {
          if (s is! Map) continue;
          final addr = (s['address'] ?? '').toString();
          final port = _toInt(s['port']) ?? 8080;
          if (addr.isEmpty) continue;
          final users = s['users'] is List ? s['users'] as List : const [];
          final u = users.isNotEmpty && users.first is Map ? users.first as Map : null;
          final user = (u?['user'] ?? s['user'] ?? s['username'] ?? '').toString();
          final pass = (u?['pass'] ?? s['pass'] ?? s['password'] ?? '').toString();
          final node = <String, dynamic>{
            'type': 'http',
            'tag': tag,
            'server': addr,
            'server_port': port,
            if (user.isNotEmpty) 'username': user,
            if (pass.isNotEmpty) 'password': pass,
          };
          attachStream(node, addr);
          out.add(node);
        }
      case 'hysteria2':
      case 'hy2':
        final servers = settings['servers'] is List
            ? settings['servers'] as List
            : (settings['address'] != null ? [settings] : const []);
        for (final s in servers) {
          if (s is! Map) continue;
          final addr = (s['address'] ?? '').toString();
          final port = _toInt(s['port']) ?? 443;
          final pass = (s['password'] ?? settings['password'] ?? '').toString();
          if (addr.isEmpty) continue;
          final node = <String, dynamic>{
            'type': 'hysteria2',
            'tag': tag,
            'server': addr,
            'server_port': port,
            'password': pass,
          };
          attachStream(node, addr);
          out.add(node);
        }
      case 'wireguard':
        final peers = settings['peers'] is List ? settings['peers'] as List : const [];
        final peer = peers.isNotEmpty && peers.first is Map ? peers.first as Map : null;
        final privKey = (settings['secretKey'] ?? settings['privateKey'] ?? '').toString();
        final pubKey = (peer?['publicKey'] ?? '').toString();
        final endpoint = (peer?['endpoint'] ?? '').toString();
        final hp = _splitHostPort(endpoint, 51820);
        if (privKey.isNotEmpty && pubKey.isNotEmpty && hp != null) {
          final node = <String, dynamic>{
            'type': 'wireguard',
            'tag': tag,
            'server': hp.$1,
            'server_port': hp.$2,
            'private_key': privKey,
            'peer_public_key': pubKey,
            'local_address': settings['address'] is List
                ? (settings['address'] as List).map((e) => _formatWgCidr(e.toString())).toList()
                : ['10.0.0.2/32'],
            if (_toInt(settings['mtu']) != null) 'mtu': _toInt(settings['mtu']),
            if (dialerProxy.isNotEmpty) 'detour': dialerProxy,
          };
          _extractAwgParams(settings, node);
          out.add(node);
        }
    }
    return out;
  }

  Map<String, dynamic>? _convertXrayTls(Map<String, dynamic> stream, String defaultServer) {
    final sec = (stream['security'] ?? 'none').toString().toLowerCase();
    if (sec == 'tls' || sec == 'xtls') {
      final ts = stream['tlsSettings'] is Map ? stream['tlsSettings'] as Map : const {};
      final sni = (ts['serverName'] ?? defaultServer).toString();
      final fp = normalizeUtlsFingerprint((ts['fingerprint'] ?? '').toString());
      return {
        'enabled': true,
        if (sni.isNotEmpty) 'server_name': sni,
        if (ts['allowInsecure'] == true) 'insecure': true,
        if (ts['alpn'] is List) 'alpn': ts['alpn'],
        if (fp.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fp},
      };
    }
    if (sec == 'reality') {
      final rs = stream['realitySettings'] is Map ? stream['realitySettings'] as Map : const {};
      final sni = (rs['serverName'] ?? defaultServer).toString();
      final rawFp = (rs['fingerprint'] ?? '').toString();
      final fp = rawFp.isEmpty ? 'chrome' : normalizeUtlsFingerprint(rawFp);
      final sid = normalizeRealityShortId((rs['shortId'] ?? '').toString());
      return {
        'enabled': true,
        if (sni.isNotEmpty) 'server_name': sni,
        'utls': {'enabled': true, 'fingerprint': fp},
        'reality': {
          'enabled': true,
          'public_key': (rs['publicKey'] ?? '').toString().trim(),
          if (sid.isNotEmpty) 'short_id': sid,
        },
      };
    }
    return null;
  }

  Map<String, dynamic>? _convertXrayTransport(Map<String, dynamic> stream) {
    final net = _normalizeTransportName((stream['network'] ?? 'tcp').toString());
    switch (net) {
      case 'ws':
        final ws = stream['wsSettings'] is Map ? stream['wsSettings'] as Map : const {};
        return {
          'type': 'ws',
          if ((ws['path'] ?? '').toString().isNotEmpty) 'path': ws['path'].toString(),
          if (ws['headers'] is Map) 'headers': ws['headers'],
        };
      case 'grpc':
        final gs = stream['grpcSettings'] is Map ? stream['grpcSettings'] as Map : const {};
        return {
          'type': 'grpc',
          if ((gs['serviceName'] ?? '').toString().isNotEmpty)
            'service_name': gs['serviceName'].toString(),
        };
      case 'httpupgrade':
        final hs = stream['httpupgradeSettings'] is Map ? stream['httpupgradeSettings'] as Map : const {};
        return {
          'type': 'httpupgrade',
          if ((hs['path'] ?? '').toString().isNotEmpty) 'path': hs['path'].toString(),
          if ((hs['host'] ?? '').toString().isNotEmpty) 'host': hs['host'].toString(),
        };
      case 'http':
        final hs = stream['httpSettings'] is Map ? stream['httpSettings'] as Map : const {};
        return {
          'type': 'http',
          if ((hs['path'] ?? '').toString().isNotEmpty) 'path': hs['path'].toString(),
          if (hs['host'] != null) 'host': hs['host'],
        };
      case 'xhttp':
        final xs = (stream['xhttpSettings'] ?? stream['splithttpSettings']) is Map
            ? Map<String, dynamic>.from((stream['xhttpSettings'] ?? stream['splithttpSettings']) as Map)
            : <String, dynamic>{};
        xs['type'] = 'xhttp';
        if (xs['extra'] is Map) {
          xs.addAll(Map<String, dynamic>.from(xs.remove('extra') as Map));
        }
        return normalizeXhttpTransport(xs);
      default:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Clash / Mihomo YAML (proxies:)
  // ---------------------------------------------------------------------------

  List<Profile> _parseClashYaml(String yamlText, {String subscriptionId = ''}) {
    final entries = <Map<String, dynamic>>[];
    var inProxies = false;
    var proxiesIndent = 0;
    List<(int, String)>? currentBlock;
    var blockIndent = 0;

    void flushBlock() {
      if (currentBlock != null && currentBlock!.isNotEmpty) {
        final map = _parseYamlBlockLines(currentBlock!);
        if (map.isNotEmpty) entries.add(map);
      }
      currentBlock = null;
    }

    for (final rawLine in yamlText.split(RegExp(r'[\r\n]+'))) {
      final lineNoComment = _stripYamlComment(rawLine);
      final trimmed = lineNoComment.trim();
      if (trimmed.isEmpty) continue;
      final indent = lineNoComment.length - lineNoComment.trimLeft().length;

      if (!inProxies) {
        if (trimmed == 'proxies:' || trimmed.startsWith('proxies:')) {
          inProxies = true;
          proxiesIndent = indent;
        }
        continue;
      }

      if (indent <= proxiesIndent && !trimmed.startsWith('-')) {
        flushBlock();
        break;
      }

      if (trimmed.startsWith('-')) {
        final afterDash = trimmed.substring(1).trim();
        if (currentBlock != null && indent > blockIndent) {
          currentBlock!.add((indent, trimmed));
          continue;
        }
        flushBlock();
        if (afterDash.startsWith('{') && afterDash.endsWith('}')) {
          final flowMap = _parseYamlFlowMap(afterDash);
          if (flowMap.isNotEmpty) entries.add(flowMap);
        } else {
          blockIndent = indent;
          currentBlock = [];
          if (afterDash.isNotEmpty) {
            currentBlock!.add((indent + 2, afterDash));
          }
        }
      } else if (currentBlock != null) {
        currentBlock!.add((indent, trimmed));
      }
    }
    flushBlock();

    final out = <Profile>[];
    for (var i = 0; i < entries.length; i++) {
      final outbound = _convertClashProxy(i, entries[i]);
      if (outbound != null) {
        final profile = _outboundMapToProfile(outbound, subscriptionId: subscriptionId);
        if (profile != null) out.add(profile);
      }
    }
    return out;
  }

  String _stripYamlComment(String line) {
    var inSingle = false;
    var inDouble = false;
    var prevSpace = true;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '\\' && inDouble) {
        i++;
        continue;
      }
      if (ch == "'" && !inDouble) inSingle = !inSingle;
      if (ch == '"' && !inSingle) inDouble = !inDouble;
      if (ch == '#' && !inSingle && !inDouble && prevSpace) {
        return line.substring(0, i);
      }
      prevSpace = ch == ' ' || ch == '\t';
    }
    return line;
  }

  Map<String, dynamic> _parseYamlFlowMap(String text) {
    final inner = text.trim();
    if (!inner.startsWith('{') || !inner.endsWith('}')) return const {};
    final body = inner.substring(1, inner.length - 1);
    final map = <String, dynamic>{};
    for (final part in _splitYamlTopLevel(body, ',')) {
      final kv = _splitYamlKeyVal(part);
      if (kv == null) continue;
      map[_unquoteYaml(kv.$1)] = _parseYamlValue(kv.$2);
    }
    return map;
  }

  Object? _parseYamlValue(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('{') && s.endsWith('}')) return _parseYamlFlowMap(s);
    if (s.startsWith('[') && s.endsWith(']')) {
      final inner = s.substring(1, s.length - 1);
      return _splitYamlTopLevel(inner, ',')
          .map((e) => _parseYamlValue(e))
          .where((e) => e != null)
          .toList();
    }
    if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
      return _unquoteYaml(s);
    }
    final lower = s.toLowerCase();
    if (lower == 'true' || lower == 'yes') return true;
    if (lower == 'false' || lower == 'no') return false;
    final asInt = int.tryParse(s);
    if (asInt != null) return asInt;
    return s;
  }

  String _unquoteYaml(String raw) {
    final s = raw.trim();
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'")))) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  List<String> _splitYamlTopLevel(String s, String sep) {
    final parts = <String>[];
    var brace = 0;
    var bracket = 0;
    var inSingle = false;
    var inDouble = false;
    var start = 0;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '\\' && inDouble) {
        i++;
        continue;
      }
      if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (!inSingle && !inDouble) {
        if (ch == '{') brace++;
        if (ch == '}') brace--;
        if (ch == '[') bracket++;
        if (ch == ']') bracket--;
        if (ch == sep && brace == 0 && bracket == 0) {
          parts.add(s.substring(start, i).trim());
          start = i + 1;
        }
      }
    }
    final tail = s.substring(start).trim();
    if (tail.isNotEmpty) parts.add(tail);
    return parts;
  }

  (String, String)? _splitYamlKeyVal(String s) {
    var inSingle = false;
    var inDouble = false;
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (ch == '\\' && inDouble) {
        i++;
        continue;
      }
      if (ch == "'" && !inDouble) {
        inSingle = !inSingle;
      } else if (ch == '"' && !inSingle) {
        inDouble = !inDouble;
      } else if (ch == ':' && !inSingle && !inDouble) {
        if (i + 1 == s.length || s[i + 1] == ' ' || s[i + 1] == '\t') {
          return (s.substring(0, i).trim(), s.substring(i + 1).trim());
        }
      }
    }
    return null;
  }

  Map<String, dynamic> _parseYamlBlockLines(List<(int, String)> lines) {
    final map = <String, dynamic>{};
    var i = 0;
    while (i < lines.length) {
      final (indent, text) = lines[i];
      final kv = _splitYamlKeyVal(text);
      if (kv == null) {
        i++;
        continue;
      }
      final key = _unquoteYaml(kv.$1);
      final val = kv.$2;
      if (val.isNotEmpty) {
        map[key] = _parseYamlValue(val);
        i++;
      } else {
        final children = <(int, String)>[];
        var j = i + 1;
        while (j < lines.length && lines[j].$1 > indent) {
          children.add(lines[j]);
          j++;
        }
        if (children.isNotEmpty && children.first.$2.startsWith('-')) {
          final list = <Object?>[];
          for (final (_, itemText) in children) {
            if (itemText.startsWith('-')) {
              final v = _parseYamlValue(itemText.substring(1));
              if (v != null) list.add(v);
            }
          }
          map[key] = list;
        } else if (children.isNotEmpty) {
          map[key] = _parseYamlBlockLines(children);
        }
        i = j;
      }
    }
    return map;
  }

  Map<String, dynamic>? _convertClashProxy(int idx, Map<String, dynamic> p) {
    final ty = (p['type'] ?? '').toString().toLowerCase();
    final server = _cleanHost((p['server'] ?? '').toString());
    final port = _toInt(p['port']);
    if (ty.isEmpty || server.isEmpty || port == null) return null;
    final tag = (p['name'] ?? 'clash-$ty-${idx + 1}').toString();

    Map<String, dynamic>? buildTls(bool force) {
      final tlsOn = force || p['tls'] == true || p['reality-opts'] is Map;
      if (!tlsOn) return null;
      final sni = (p['servername'] ?? p['sni'] ?? server).toString();
      final fp = normalizeUtlsFingerprint(
        (p['client-fingerprint'] ?? p['fingerprint'] ?? '').toString(),
      );
      final tls = <String, dynamic>{
        'enabled': true,
        if (sni.isNotEmpty) 'server_name': sni,
        if (p['skip-cert-verify'] == true) 'insecure': true,
        if (p['alpn'] is List) 'alpn': p['alpn'],
        if (fp.isNotEmpty) 'utls': {'enabled': true, 'fingerprint': fp},
      };
      if (p['reality-opts'] is Map) {
        final ro = p['reality-opts'] as Map;
        final sid = normalizeRealityShortId((ro['short-id'] ?? '').toString());
        tls['reality'] = {
          'enabled': true,
          if (ro['public-key'] != null) 'public_key': ro['public-key'].toString().trim(),
          if (sid.isNotEmpty) 'short_id': sid,
        };
        tls.putIfAbsent('utls', () => {'enabled': true, 'fingerprint': 'chrome'});
      }
      return tls;
    }

    Map<String, dynamic>? buildTransport() {
      final net = _normalizeTransportName((p['network'] ?? 'tcp').toString());
      switch (net) {
        case 'ws':
          final wso = p['ws-opts'] is Map ? p['ws-opts'] as Map : const {};
          return {
            'type': 'ws',
            if (wso['path'] != null) 'path': wso['path'].toString(),
            if (wso['headers'] is Map) 'headers': wso['headers'],
          };
        case 'grpc':
          final go = p['grpc-opts'] is Map ? p['grpc-opts'] as Map : const {};
          return {
            'type': 'grpc',
            if (go['grpc-service-name'] != null)
              'service_name': go['grpc-service-name'].toString(),
          };
        case 'http':
          final ho = (p['h2-opts'] ?? p['http-opts']) is Map
              ? (p['h2-opts'] ?? p['http-opts']) as Map
              : const {};
          return {
            'type': 'http',
            if (ho['path'] != null)
              'path': ho['path'] is List ? (ho['path'] as List).first.toString() : ho['path'].toString(),
            if (ho['host'] != null) 'host': ho['host'],
          };
        case 'xhttp':
          final xo = (p['xhttp-opts'] ?? p['splithttp-opts']) is Map
              ? Map<String, dynamic>.from((p['xhttp-opts'] ?? p['splithttp-opts']) as Map)
              : <String, dynamic>{};
          xo['type'] = 'xhttp';
          return normalizeXhttpTransport(xo);
        default:
          return null;
      }
    }

    final tr = buildTransport();
    switch (ty) {
      case 'vless':
        final tls = buildTls(false);
        return {
          'type': 'vless',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': (p['uuid'] ?? '').toString(),
          if ((p['flow'] ?? '').toString().isNotEmpty) 'flow': p['flow'].toString(),
          'tls': ?tls,
          'transport': ?tr,
        };
      case 'vmess':
        final tls = buildTls(false);
        return {
          'type': 'vmess',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': (p['uuid'] ?? '').toString(),
          'security': (p['cipher'] ?? 'auto').toString(),
          'tls': ?tls,
          'transport': ?tr,
        };
      case 'trojan':
        final tls = buildTls(true);
        return {
          'type': 'trojan',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': (p['password'] ?? '').toString(),
          'tls': ?tls,
          'transport': ?tr,
        };
      case 'ss':
      case 'shadowsocks':
        return {
          'type': 'shadowsocks',
          'tag': tag,
          'server': server,
          'server_port': port,
          'method': (p['cipher'] ?? p['method'] ?? 'aes-256-gcm').toString(),
          'password': (p['password'] ?? '').toString(),
          if (p['udp-over-tcp'] == true) 'udp_over_tcp': true,
        };
      case 'hysteria2':
      case 'hy2':
        final tls = buildTls(true);
        return {
          'type': 'hysteria2',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': (p['password'] ?? '').toString(),
          if ((p['obfs'] ?? '').toString().toLowerCase() == 'salamander')
            'obfs': {
              'type': 'salamander',
              'password': (p['obfs-password'] ?? '').toString(),
            },
          'tls': ?tls,
        };
      case 'tuic':
        final tls = buildTls(true);
        return {
          'type': 'tuic',
          'tag': tag,
          'server': server,
          'server_port': port,
          'uuid': (p['uuid'] ?? '').toString(),
          'password': (p['password'] ?? '').toString(),
          if (p['congestion-controller'] != null)
            'congestion_control': p['congestion-controller'].toString(),
          if (p['udp-relay-mode'] != null)
            'udp_relay_mode': p['udp-relay-mode'].toString(),
          'tls': ?tls,
        };
      case 'wireguard':
        final addrs = <String>[];
        if ((p['ip'] ?? '').toString().isNotEmpty) {
          addrs.add(_formatWgCidr(p['ip'].toString()));
        }
        if ((p['ipv6'] ?? '').toString().isNotEmpty) {
          addrs.add(_formatWgCidr(p['ipv6'].toString()));
        }
        final node = <String, dynamic>{
          'type': 'wireguard',
          'tag': tag,
          'server': server,
          'server_port': port,
          'private_key': (p['private-key'] ?? '').toString(),
          'peer_public_key': (p['public-key'] ?? '').toString(),
          'local_address': addrs.isEmpty ? ['10.0.0.2/32'] : addrs,
          if (_toInt(p['mtu']) != null) 'mtu': _toInt(p['mtu']),
        };
        if (p['amnezia-wg-option'] is Map) {
          _extractAwgParams(Map<String, dynamic>.from(p['amnezia-wg-option'] as Map), node);
        }
        _extractAwgParams(p, node);
        return node;
      case 'anytls':
        final tls = buildTls(true);
        return {
          'type': 'anytls',
          'tag': tag,
          'server': server,
          'server_port': port,
          'password': (p['password'] ?? '').toString(),
          'tls': ?tls,
        };
      case 'socks5':
      case 'socks':
        return {
          'type': 'socks',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (p['username'] != null) 'username': p['username'].toString(),
          if (p['password'] != null) 'password': p['password'].toString(),
        };
      case 'http':
        return {
          'type': 'http',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (p['username'] != null) 'username': p['username'].toString(),
          if (p['password'] != null) 'password': p['password'].toString(),
          if (p['tls'] == true) 'tls': buildTls(true),
        };
      case 'snell':
        return {
          'type': 'snell',
          'tag': tag,
          'server': server,
          'server_port': port,
          'psk': (p['psk'] ?? '').toString(),
          'version': _toInt(p['version']) ?? 5,
        };
      case 'naive':
        final tls = buildTls(true);
        final isQuic = p['quic'] == true ||
            _isTruthy(p['quic']?.toString()) ||
            (p['network'] ?? '').toString().toLowerCase() == 'quic' ||
            (p['network'] ?? '').toString().toLowerCase() == 'h3' ||
            (p['network'] ?? '').toString().toLowerCase() == 'udp';
        return {
          'type': 'naive',
          'tag': tag,
          'server': server,
          'server_port': port,
          if (p['username'] != null) 'username': p['username'].toString(),
          if (p['password'] != null) 'password': p['password'].toString(),
          if (isQuic) 'quic': true,
          if (p['uot'] == true ||
              p['udp-over-tcp'] == true ||
              p['udp_over_tcp'] == true)
            'udp_over_tcp': true,
          'tls': ?tls,
        };
      default:
        return null;
    }
  }

  /// Превращает канонический JSON outbound `tachyon-core` в модель `Profile`.
  Profile? _outboundMapToProfile(
    Map<String, dynamic> item, {
    String subscriptionId = '',
  }) {
    final type = (item['type'] as String?)?.toLowerCase();
    if (type == null || type.isEmpty) return null;
    var server = (item['server'] as String?) ?? '';
    var port = (item['server_port'] as num?)?.toInt() ?? 443;

    // Для WireGuard-эндпоинтов с массивом peers[]
    String peerPubFromPeers = '';
    String pskFromPeers = '';
    Object? keepaliveFromPeers;
    Object? reservedFromPeers;
    List<String>? allowedIpsFromPeers;
    if (item['peers'] is List && (item['peers'] as List).isNotEmpty) {
      final peer = (item['peers'] as List).first;
      if (peer is Map) {
        if (server.isEmpty) {
          server = (peer['address'] ?? peer['server'] ?? '').toString();
        }
        port = _toInt(peer['port'] ?? peer['server_port']) ?? 51820;
        peerPubFromPeers = (peer['public_key'] ?? '').toString();
        pskFromPeers = (peer['pre_shared_key'] ?? '').toString();
        keepaliveFromPeers = peer['persistent_keepalive_interval'];
        reservedFromPeers = peer['reserved'];
        if (peer['allowed_ips'] is List) {
          allowedIpsFromPeers = (peer['allowed_ips'] as List)
              .map((e) => e.toString().trim())
              .where((s) => s.isNotEmpty)
              .toList();
        }
      }
    }
    if (server.isEmpty && item['token'] == null) return null;

    final rest = Map<String, dynamic>.from(item)
      ..remove('type')
      ..remove('tag')
      ..remove('server')
      ..remove('server_port')
      ..remove('peers');

    if (type == 'wireguard') {
      if (rest['address'] is List && !rest.containsKey('local_address')) {
        rest['local_address'] = rest.remove('address');
      } else {
        rest.remove('address');
      }
      if (peerPubFromPeers.isNotEmpty && !rest.containsKey('peer_public_key')) {
        rest['peer_public_key'] = peerPubFromPeers;
      }
      if (pskFromPeers.isNotEmpty && !rest.containsKey('pre_shared_key')) {
        rest['pre_shared_key'] = pskFromPeers;
      }
      if (keepaliveFromPeers != null && !rest.containsKey('persistent_keepalive_interval')) {
        rest['persistent_keepalive_interval'] = keepaliveFromPeers;
      }
      if (reservedFromPeers != null && !rest.containsKey('reserved')) {
        rest['reserved'] = reservedFromPeers;
      }
      if (allowedIpsFromPeers != null &&
          allowedIpsFromPeers.isNotEmpty &&
          !rest.containsKey('allowed_ips')) {
        rest['allowed_ips'] = allowedIpsFromPeers;
      }
    }

    final rawTls = rest.remove('tls');
    final tls = rawTls is Map ? Map<String, dynamic>.from(rawTls) : null;
    final reality = tls?['reality'] is Map ? Map<String, dynamic>.from(tls!['reality'] as Map) : null;
    final utls = tls?['utls'] is Map ? Map<String, dynamic>.from(tls!['utls'] as Map) : null;
    if (tls?['certificate_sha256'] is List) {
      rest['certificate_sha256'] = tls!['certificate_sha256'];
    }

    Map<String, dynamic>? transportMap;
    var transportType = 'tcp';
    if (type == 'tewfai') {
      final rawTr = rest.remove('transport');
      if (rawTr is List) {
        rest['tewfai_transport'] = rawTr.map((e) => e.toString()).toList();
        if (rawTr.contains('quic')) transportType = 'quic';
      } else if (rawTr is String && rawTr.isNotEmpty) {
        rest['tewfai_transport'] = [rawTr];
        if (rawTr == 'quic') transportType = 'quic';
      }
    } else if (type == 'naive') {
      final isQuic = rest['quic'] == true ||
          rest['network']?.toString().toLowerCase() == 'udp';
      if (isQuic) {
        rest['quic'] = true;
        transportType = 'quic';
      }
    } else if (type == 'hysteria2' ||
        type == 'hysteria' ||
        type == 'tuic' ||
        type == 'masque') {
      transportType = 'quic';
    } else if (type == 'wireguard') {
      transportType = 'udp';
    } else if (type == 'mieru') {
      final rawTr = rest.remove('transport');
      if (rawTr is String && rawTr.isNotEmpty) {
        rest['mieru_transport'] = rawTr.toUpperCase();
      }
    } else if (type == 'mtproto') {
      final rawTr = rest.remove('transport');
      if (rawTr is String && rawTr.isNotEmpty) {
        rest['mtproto_transport'] = rawTr.toLowerCase();
      }
    } else if (rest['transport'] is Map) {
      transportMap = Map<String, dynamic>.from(rest['transport'] as Map);
      transportType = _normalizeTransportName((transportMap['type'] ?? 'tcp').toString());
      if (transportType == 'xhttp') {
        rest['transport'] = normalizeXhttpTransport(transportMap);
      }
    }

    if (tls == null || tls['enabled'] == false) {
      rest['security'] = 'none';
    } else if (reality?['enabled'] == true) {
      rest['security'] = 'reality';
    } else {
      rest['security'] = 'tls';
    }
    if (utls?['fingerprint'] != null) {
      final normFp = normalizeUtlsFingerprint(utls!['fingerprint'].toString());
      if (normFp.isNotEmpty) {
        rest['fp'] = normFp;
      }
    }
    if (rest['chain_outbounds'] is List) {
      rest['chain_outbounds'] = (rest['chain_outbounds'] as List)
          .whereType<Map>()
          .map((h) => normalizeOutboundNode(Map<String, dynamic>.from(h)))
          .toList(growable: false);
    }

    final uuid = (rest.remove('uuid') ?? '').toString();
    final password = (rest.remove('password') ??
            rest['private_key'] ??
            rest['psk'] ??
            rest['secret'] ??
            '')
        .toString();
    final method = (rest.remove('method') ?? '').toString();
    final flow = normalizeVlessFlow((rest.remove('flow') ?? '').toString());
    final pubKey = (reality?['public_key'] ??
            rest['peer_public_key'] ??
            rest['public_key'] ??
            '')
        .toString()
        .trim();
    final shortId = normalizeRealityShortId((reality?['short_id'] ?? '').toString());
    final tag = (item['tag'] ?? '').toString().trim();

    return Profile(
      id: _id(type, '$server:$port:$uuid:$password:$tag'),
      name: tag.isNotEmpty ? tag : '$server:$port',
      type: type,
      server: server,
      port: port,
      uuid: uuid,
      password: password,
      method: method,
      transport: transportType,
      sni: (tls?['server_name'] ?? '').toString(),
      alpn: ((tls?['alpn'] as List?) ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      allowInsecure: tls?['insecure'] == true,
      flow: flow,
      publicKey: pubKey,
      shortId: shortId,
      subscriptionId: subscriptionId,
      extra: rest,
    );
  }

  // ---------------------------------------------------------------------------
  // Транспорты и вспомогательные функции
  // ---------------------------------------------------------------------------

  String _normalizeTransportName(String raw) {
    return switch (raw.trim().toLowerCase()) {
      'ws' || 'websocket' => 'ws',
      'grpc' || 'gun' => 'grpc',
      'httpupgrade' || 'http-upgrade' => 'httpupgrade',
      'h2' || 'http' || 'http2' => 'http',
      'xhttp' || 'splithttp' || 'xh' => 'xhttp',
      'quic' => 'quic',
      _ => 'tcp',
    };
  }

  Map<String, dynamic>? _buildTransportFromQuery(
    String transportType,
    Map<String, String> query,
  ) {
    if (transportType == 'tcp') return null;
    final tMap = <String, dynamic>{'type': transportType};
    var path = query['path'] ?? '';
    final host = query['host'] ?? '';

    if (transportType == 'ws') {
      // Обработка ?ed=2048 внутри пути WebSocket (Early Data)
      if (path.contains('?ed=')) {
        final idx = path.indexOf('?ed=');
        final edStr = path.substring(idx + 4).split('&').first;
        path = path.substring(0, idx);
        final ed = int.tryParse(edStr);
        if (ed != null && ed > 0) {
          tMap['max_early_data'] = ed;
          tMap['early_data_header_name'] = 'Sec-WebSocket-Protocol';
        }
      }
      final edParam = int.tryParse(query['ed'] ?? query['max_early_data'] ?? '');
      if (edParam != null && edParam > 0) {
        tMap['max_early_data'] = edParam;
        tMap['early_data_header_name'] =
            query['early_data_header_name'] ?? 'Sec-WebSocket-Protocol';
      }
      if (path.isNotEmpty) tMap['path'] = path;
      if (host.isNotEmpty) tMap['headers'] = {'Host': host};
      return tMap;
    }

    if (transportType == 'grpc') {
      final sn = query['serviceName'] ?? query['service_name'] ?? path;
      if (sn.isNotEmpty) tMap['service_name'] = sn;
      return tMap;
    }

    if (transportType == 'http') {
      if (path.isNotEmpty) tMap['path'] = path;
      if (host.isNotEmpty) {
        tMap['host'] = host.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }
      return tMap;
    }

    if (path.isNotEmpty) tMap['path'] = path;
    if (host.isNotEmpty) tMap['host'] = host;
    if ((query['mode'] ?? '').isNotEmpty) tMap['mode'] = query['mode'];
    if ((query['xPaddingBytes'] ?? query['x_padding_bytes'] ?? '').isNotEmpty) {
      tMap['x_padding_bytes'] = query['xPaddingBytes'] ?? query['x_padding_bytes'];
    }
    if (query.containsKey('extra')) {
      final rawExtra = query['extra']!;
      Map<String, dynamic>? decodedExtra;
      try {
        final parsed = jsonDecode(rawExtra);
        if (parsed is Map<String, dynamic>) decodedExtra = parsed;
      } catch (_) {
        try {
          final parsed = jsonDecode(Uri.decodeQueryComponent(rawExtra));
          if (parsed is Map<String, dynamic>) decodedExtra = parsed;
        } catch (_) {}
      }
      if (decodedExtra != null) tMap.addAll(decodedExtra);
    }

    return transportType == 'xhttp' ? normalizeXhttpTransport(tMap) : tMap;
  }

  String _cleanHost(String host) {
    var h = host.trim();
    if (h.startsWith('[') && h.endsWith(']')) {
      h = h.substring(1, h.length - 1);
    }
    return h;
  }

  (String, int)? _splitHostPort(String raw, int defaultPort) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('[')) {
      final close = s.indexOf(']');
      if (close <= 1) return null;
      final host = s.substring(1, close);
      final rest = s.substring(close + 1);
      final port = rest.startsWith(':')
          ? (int.tryParse(rest.substring(1)) ?? defaultPort)
          : defaultPort;
      return (host, port);
    }
    final colon = s.lastIndexOf(':');
    if (colon > 0 && !s.substring(0, colon).contains(':')) {
      final host = s.substring(0, colon);
      final port = int.tryParse(s.substring(colon + 1)) ?? defaultPort;
      return (host, port);
    }
    return (s, defaultPort);
  }

  (String, String) _splitUserPass(String userInfo) {
    if (userInfo.isEmpty) return ('', '');
    final sep = userInfo.indexOf(':');
    if (sep < 0) return (Uri.decodeComponent(userInfo), '');
    return (
      Uri.decodeComponent(userInfo.substring(0, sep)),
      Uri.decodeComponent(userInfo.substring(sep + 1)),
    );
  }

  Map<String, String> _parseQuerySafe(String query) {
    if (query.isEmpty) return const {};
    final out = <String, String>{};
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      final k = Uri.decodeQueryComponent(pair.substring(0, eq));
      final v = Uri.decodeQueryComponent(pair.substring(eq + 1));
      out[k] = v;
    }
    return out;
  }

  String _formatWgCidr(String addr) {
    final s = _cleanHost(addr);
    if (s.isEmpty) return '';
    if (s.contains('/')) return s;
    return s.contains(':') ? '$s/128' : '$s/32';
  }

  Object? _parseWgReserved(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final s = raw.trim().replaceAll('[', '').replaceAll(']', '');
    final nums = s.split(',').map((e) => int.tryParse(e.trim())).toList();
    if (nums.length == 3 && nums.every((n) => n != null)) {
      return nums.cast<int>();
    }
    return raw.trim();
  }

  List<String> _splitCsv(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(growable: false);
  }

  bool _isTruthy(String? val) {
    if (val == null) return false;
    final lower = val.trim().toLowerCase();
    return lower == '1' || lower == 'true' || lower == 'yes';
  }

  int? _toInt(Object? val) {
    if (val is int) return val;
    if (val is num) return val.toInt();
    if (val is String) return int.tryParse(val.trim());
    return null;
  }

  String _name(Map<String, String> query, String fragment, String fallback) {
    final remark = query['remarks'] ?? query['remark'] ?? query['name'] ?? query['description'];
    if (remark != null && remark.isNotEmpty) return remark;
    if (fragment.isNotEmpty) {
      try {
        return Uri.decodeComponent(fragment);
      } catch (_) {
        return fragment;
      }
    }
    return fallback;
  }

  String _id(String type, String seed) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return '$type-$hash';
  }

  String _normalizeBase64(String value) {
    var cleaned = value
        .replaceAll(RegExp(r'[^A-Za-z0-9+/=_-]'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    final padding = cleaned.length % 4;
    if (padding == 1) return '';
    if (padding != 0) {
      cleaned = cleaned.padRight(cleaned.length + (4 - padding), '=');
    }
    return cleaned;
  }

  void _extractCertPin(Map<String, dynamic> extra, String? rawPin) {
    if (rawPin == null || rawPin.trim().isEmpty) return;
    var pin = rawPin.trim().replaceFirst(RegExp(r'^sha256/', caseSensitive: false), '');
    final hexCandidate = pin.replaceAll(':', '');
    if (hexCandidate.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(hexCandidate)) {
      final bytes = <int>[];
      for (var i = 0; i < 64; i += 2) {
        bytes.add(int.parse(hexCandidate.substring(i, i + 2), radix: 16));
      }
      final b64 = base64.encode(bytes);
      extra['certificate_sha256'] = [b64];
      extra['pcs'] = hexCandidate.toLowerCase();
      return;
    }
    if (pin.isNotEmpty) {
      extra['certificate_sha256'] = [pin];
    }
  }
}
