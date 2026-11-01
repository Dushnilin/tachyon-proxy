import 'dart:convert';

import '../models/runtime_config.dart';

/// Разбор ссылок и подписок.
///
/// Поддерживаются форматы, которые встречаются в мобильных VPN-клиентах:
/// `vless://`, `trojan://`, `ss://`, `vmess://` и подписки в base64.
class LinkParser {
  const LinkParser();

  /// Разбирает список ссылок, по одной на строку.
  ///
  /// Некорректные строки пропускаются: подписка может содержать комментарии
  /// и служебные строки.
  List<Profile> parseMany(String content, {String subscriptionId = ""}) {
    final profiles = <Profile>[];
    for (final raw in content.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      final profile = parse(line, subscriptionId: subscriptionId);
      if (profile != null) profiles.add(profile);
    }
    return profiles;
  }

  /// Разбирает подписку: сначала пытается как base64, иначе — как обычный текст.
  List<Profile> parseSubscription(String content, {String subscriptionId = ''}) {
    final trimmed = content.trim();
    if (trimmed.contains('://')) {
      final direct = parseMany(trimmed, subscriptionId: subscriptionId);
      if (direct.isNotEmpty) return direct;
    }
    try {
      final decoded = utf8.decode(base64.decode(_normalizeBase64(trimmed)));
      final parsed = parseMany(decoded, subscriptionId: subscriptionId);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {}

    try {
      final decoded = latin1.decode(base64.decode(_normalizeBase64(trimmed)));
      final parsed = parseMany(decoded, subscriptionId: subscriptionId);
      if (parsed.isNotEmpty) return parsed;
    } catch (_) {}

    return parseMany(trimmed, subscriptionId: subscriptionId);
  }

  /// Разбирает одну ссылку.
  Profile? parse(String link, {String subscriptionId = ""}) {
    final value = link.trim();
    if (value.startsWith('vless://')) return _parseVless(value, subscriptionId: subscriptionId);
    if (value.startsWith('trojan://')) return _parseTrojan(value, subscriptionId: subscriptionId);
    if (value.startsWith('ss://')) return _parseShadowsocks(value, subscriptionId: subscriptionId);
    if (value.startsWith('vmess://')) return _parseVmess(value, subscriptionId: subscriptionId);
    if (value.startsWith('hysteria://')) return _parseHysteria1(value, subscriptionId: subscriptionId);
    if (value.startsWith('hysteria2://') || value.startsWith('hy2://')) {
      return _parseHysteria2(value, subscriptionId: subscriptionId);
    }
    if (value.startsWith('tuic://')) return _parseTuic(value, subscriptionId: subscriptionId);
    if (value.startsWith('anytls://')) return _parseAnytls(value, subscriptionId: subscriptionId);
    if (value.startsWith('socks5://') || value.startsWith('socks://')) {
      return _parseSocks(value, subscriptionId: subscriptionId);
    }
    // Сырой outbound sing-box: {"type":..., "server":..., ...} или список.
    if (value.startsWith('{') || value.startsWith('[')) {
      return _parseSingBoxJson(value, subscriptionId: subscriptionId);
    }
    return null;
  }

  /// hysteria://host:port?auth=...&upmbps=...&peer=sni&alpn=...
  Profile? _parseHysteria1(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final port = uri.port == 0 ? 443 : uri.port;

    return Profile(
      id: _id('hysteria', '${uri.host}:$port:${query['auth'] ?? ''}'),
      name: _name(query, uri.fragment, '${uri.host}:$port'),
      type: 'hysteria',
      server: uri.host,
      port: port,
      sni: query['peer'] ?? query['sni'] ?? '',
      alpn: (query['alpn'] ?? '').isEmpty
          ? const []
          : query['alpn']!.split(','),
      allowInsecure: query['insecure'] == '1',
      subscriptionId: subscriptionId,
      extra: {
        if ((query['auth'] ?? '').isNotEmpty) 'auth_str': query['auth'],
        if ((query['upmbps'] ?? '').isNotEmpty)
          'up_mbps': int.tryParse(query['upmbps']!) ?? 0,
        if ((query['downmbps'] ?? '').isNotEmpty)
          'down_mbps': int.tryParse(query['downmbps']!) ?? 0,
        if ((query['obfs'] ?? '').isNotEmpty) 'obfs': query['obfs'],
      },
    );
  }

  /// hysteria2://password@host:port?sni=...&obfs=salamander&obfs-password=...
  Profile? _parseHysteria2(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final port = uri.port == 0 ? 443 : uri.port;
    final extra = <String, dynamic>{};
    final obfs = query['obfs'] ?? '';
    if (obfs.isNotEmpty) {
      extra['obfs'] = obfs;
      final obfsPassword = query['obfs-password'] ?? '';
      if (obfsPassword.isNotEmpty) extra['obfs-password'] = obfsPassword;
    }
    final up = query['up'] ?? '';
    if (up.isNotEmpty) extra['up_mbps'] = int.tryParse(up) ?? 0;

    return Profile(
      id: _id('hysteria2', '${uri.host}:$port:${uri.userInfo}'),
      name: _name(query, uri.fragment, '${uri.host}:$port'),
      type: 'hysteria2',
      server: uri.host,
      port: port,
      password: uri.userInfo,
      sni: query['sni'] ?? '',
      alpn: (query['alpn'] ?? '').isEmpty
          ? const []
          : query['alpn']!.split(','),
      allowInsecure:
          query['insecure'] == '1' || query['allowInsecure'] == '1',
      subscriptionId: subscriptionId,
      extra: extra,
    );
  }

  /// tuic://uuid:password@host:port?congestion_control=bbr&...
  Profile? _parseTuic(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final port = uri.port == 0 ? 443 : uri.port;
    final userInfo = uri.userInfo;
    final separator = userInfo.indexOf(':');
    final uuid = separator < 0 ? userInfo : userInfo.substring(0, separator);
    final password = separator < 0 ? '' : userInfo.substring(separator + 1);

    return Profile(
      id: _id('tuic', '${uri.host}:$port:$userInfo'),
      name: _name(query, uri.fragment, '${uri.host}:$port'),
      type: 'tuic',
      server: uri.host,
      port: port,
      uuid: uuid,
      password: password,
      sni: query['sni'] ?? '',
      alpn: (query['alpn'] ?? '').isEmpty
          ? const []
          : query['alpn']!.split(','),
      allowInsecure:
          query['insecure'] == '1' || query['allowInsecure'] == '1',
      subscriptionId: subscriptionId,
      extra: {
        if ((query['congestion_control'] ?? '').isNotEmpty)
          'congestion_control': query['congestion_control'],
        if ((query['udp_relay_mode'] ?? '').isNotEmpty)
          'udp_relay_mode': query['udp_relay_mode'],
      },
    );
  }

  /// anytls://password@host:port?sni=...
  Profile? _parseAnytls(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final port = uri.port == 0 ? 443 : uri.port;

    return Profile(
      id: _id('anytls', '${uri.host}:$port:${uri.userInfo}'),
      name: _name(query, uri.fragment, '${uri.host}:$port'),
      type: 'anytls',
      server: uri.host,
      port: port,
      password: uri.userInfo,
      sni: query['sni'] ?? '',
      allowInsecure:
          query['insecure'] == '1' || query['allowInsecure'] == '1',
      subscriptionId: subscriptionId,
    );
  }

  /// socks://user:pass@host:port — версий 4/5 без различий в ссылке.
  Profile? _parseSocks(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null || uri.host.isEmpty) return null;
    final query = uri.queryParameters;
    final port = uri.port == 0 ? 1080 : uri.port;
    final userInfo = uri.userInfo;
    final separator = userInfo.indexOf(':');
    final username = separator < 0 ? userInfo : userInfo.substring(0, separator);
    final password = separator < 0 ? '' : userInfo.substring(separator + 1);

    return Profile(
      id: _id('socks', '${uri.host}:$port:$userInfo'),
      name: _name(query, uri.fragment, '${uri.host}:$port'),
      type: 'socks',
      server: uri.host,
      port: port,
      subscriptionId: subscriptionId,
      extra: {
        'version': '5',
        if (username.isNotEmpty) 'username': username,
        if (password.isNotEmpty) 'password': password,
      },
    );
  }

  /// Сырой JSON sing-box: один outbound или массив — берём proxy-подобные.
  Profile? _parseSingBoxJson(String value, {String subscriptionId = ''}) {
    final decoded = jsonDecode(value);
    final items = decoded is List ? decoded : [decoded];
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final type = item['type'] as String?;
      final server = item['server'] as String?;
      if (type == null || server == null) continue;
      final rest = Map<String, dynamic>.from(item)
        ..remove('type')
        ..remove('tag')
        ..remove('server');
      final port = (rest.remove('server_port') as num?)?.toInt() ?? 443;
      final tls = rest.remove('tls') as Map?;
      final reality = tls?['reality'] as Map?;
      final transportMap = rest['transport'] as Map?;
      final transportType = (transportMap?['type'] as String?) ?? 'tcp';
      if (transportMap is Map<String, dynamic> &&
          (transportType == 'xhttp' || transportType == 'splithttp')) {
        rest['transport'] = normalizeXhttpTransport(transportMap);
      }
      if (tls == null || tls['enabled'] == false) {
        rest['security'] = 'none';
      }
      return Profile(
        id: _id(type, '$server:$port:${item['uuid'] ?? item['password'] ?? ''}'),
        name: (item['tag'] as String?)?.isNotEmpty == true
            ? item['tag'] as String
            : '$server:$port',
        type: type,
        server: server,
        port: port,
        uuid: (rest.remove('uuid') as String?) ?? '',
        password: (rest.remove('password') as String?) ?? '',
        method: (rest.remove('method') as String?) ?? '',
        transport: transportType,
        sni: (tls?['server_name'] as String?) ?? '',
        alpn: ((tls?['alpn'] as List?) ?? const [])
            .map((entry) => entry.toString())
            .toList(growable: false),
        allowInsecure: tls?['insecure'] == true,
        publicKey: (reality?['public_key'] as String?) ?? '',
        shortId: (reality?['short_id'] as String?) ?? '',
        subscriptionId: subscriptionId,
        extra: rest,
      );
    }
    return null;
  }

  Profile? _parseVless(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final uuid = uri.userInfo;
    if (uuid.isEmpty) return null;

    final query = uri.queryParameters;
    final server = uri.host;
    final port = uri.port == 0 ? 443 : uri.port;

    final transportType = query['type'] ?? query['net'] ?? 'tcp';
    final rawSec = (query['security'] ?? '').trim().toLowerCase();
    final security = rawSec.isNotEmpty
        ? rawSec
        : ((query['pbk'] ?? '').isNotEmpty
            ? 'reality'
            : ((query['sni'] ?? query['peer'] ?? '').isNotEmpty ? 'tls' : 'none'));
    final extra = <String, dynamic>{
      'security': security,
      if ((query['fp'] ?? '').isNotEmpty) 'fp': query['fp'],
    };
    if (transportType != 'tcp') {
      final tMap = <String, dynamic>{'type': transportType};
      if (query.containsKey('path')) tMap['path'] = query['path'];
      if (query.containsKey('host')) tMap['host'] = query['host'];
      if (query.containsKey('mode')) tMap['mode'] = query['mode'];
      if (query.containsKey('serviceName')) tMap['service_name'] = query['serviceName'];
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
        if (decodedExtra != null) {
          tMap.addAll(decodedExtra);
        }
      }
      extra['transport'] = (transportType == 'xhttp' || transportType == 'splithttp')
          ? normalizeXhttpTransport(tMap)
          : tMap;
    }

    final resolvedName = _name(query, uri.fragment, '$server:$port');
    final profile = Profile(
      id: _id('vless', '$server:$port:$uuid:$resolvedName:${query['path'] ?? ''}'),
      name: resolvedName,
      type: 'vless',
      server: server,
      port: port,
      uuid: uuid,
      transport: transportType,
      sni: query['sni'] ?? query['peer'] ?? '',
      alpn: (query['alpn'] ?? '').isEmpty ? const [] : query['alpn']!.split(','),
      allowInsecure: query['allowInsecure'] == '1' || query['insecure'] == '1',
      flow: query['flow'] ?? '',
      publicKey: query['pbk'] ?? '',
      shortId: query['sid'] ?? '',
      subscriptionId: subscriptionId,
      extra: extra,
    );
    return profile;
  }

  Profile? _parseTrojan(String link, {String subscriptionId = ''}) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;
    final password = uri.userInfo;
    if (password.isEmpty) return null;

    final query = uri.queryParameters;
    final server = uri.host;
    final port = uri.port == 0 ? 443 : uri.port;
    final resolvedName = _name(query, uri.fragment, '$server:$port');

    return Profile(
      id: _id('trojan', '$server:$port:$password:$resolvedName:${query['path'] ?? ''}'),
      name: resolvedName,
      type: 'trojan',
      server: server,
      port: port,
      password: password,
      transport: query['type'] ?? query['net'] ?? 'tcp',
      sni: query['sni'] ?? query['peer'] ?? '',
      alpn: (query['alpn'] ?? '').isEmpty ? const [] : query['alpn']!.split(','),
      allowInsecure: query['allowInsecure'] == '1' || query['insecure'] == '1',
      subscriptionId: subscriptionId,
    );
  }

  Profile? _parseShadowsocks(String link, {String subscriptionId = ""}) {
    final uri = Uri.tryParse(link);
    if (uri == null) return null;

    // Две формы: ss://method:password@host:port и ss://base64(method:password)@host:port
    var userInfo = uri.userInfo;
    final host = uri.host;
    final port = uri.port == 0 ? 8388 : uri.port;

    if (!userInfo.contains(':')) {
      try {
        userInfo = utf8.decode(base64.decode(_normalizeBase64(userInfo)));
      } catch (_) {
        return null;
      }
    }
    final separator = userInfo.indexOf(':');
    if (separator <= 0) return null;

    final method = userInfo.substring(0, separator);
    final password = userInfo.substring(separator + 1);
    final query = uri.queryParameters;

    return Profile(
      id: _id('ss', '$host:$port:$method'),
      name: _name(query, uri.fragment, '$host:$port'),
      type: 'shadowsocks',
      server: host,
      port: port,
      method: method,
      password: password,
      subscriptionId: subscriptionId,
    );
  }

  Profile? _parseVmess(String link, {String subscriptionId = ''}) {
    final payload = link.substring('vmess://'.length);
    try {
      final decoded = utf8.decode(base64.decode(_normalizeBase64(payload)));
      final map = jsonDecode(decoded) as Map<String, dynamic>;
      final server = (map['add'] as String?) ?? '';
      if (server.isEmpty) return null;
      final port = (map['port'] as num?)?.toInt() ?? 443;
      return Profile(
        id: _id('vmess', '$server:$port:${map['id']}'),
        name: (map['ps'] as String?) ?? '$server:$port',
        type: 'vmess',
        server: server,
        port: port,
        uuid: (map['id'] as String?) ?? '',
        transport: (map['net'] as String?) ?? 'tcp',
        sni: (map['sni'] as String?) ?? (map['host'] as String?) ?? '',
        allowInsecure: map['tls'] == 'tls' &&
            ((map['verify_cert'] as bool?) ?? false) == false,
        subscriptionId: subscriptionId,
      );
    } catch (_) {
      return null;
    }
  }

  /// Имя сервера: из ссылки, иначе из фрагмента, иначе «адрес:порт».
  String _name(Map<String, String> query, String fragment, String fallback) {
    final remark = query['remarks'] ?? query['remark'] ?? query['name'];
    if (remark != null && remark.isNotEmpty) return remark;
    if (fragment.isNotEmpty) return Uri.decodeComponent(fragment);
    return fallback;
  }

  /// Стабильный идентификатор профиля.
  String _id(String type, String seed) {
    var hash = 0;
    for (final unit in seed.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return '$type-$hash';
  }

  /// Возвращает base64 без переносов и с восстановленным заполнением (стандартный и url-safe).
  String _normalizeBase64(String value) {
    var cleaned = value
        .replaceAll(RegExp(r'[^A-Za-z0-9+/=_-]'), '')
        .replaceAll('-', '+')
        .replaceAll('_', '/');
    final padding = cleaned.length % 4;
    if (padding != 0) {
      cleaned = cleaned.padRight(cleaned.length + (4 - padding), '=');
    }
    return cleaned;
  }
}
