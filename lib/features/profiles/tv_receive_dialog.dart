import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/theme/tokens.dart';
import '../../app/widgets/morphe.dart';
import '../../app/widgets/qr_code_view.dart';
import '../../core/app_controller.dart';

/// Открывает диалог локального приёма подписки/серверов с телефона по Wi-Fi (для Android TV и приставок).
///
/// Поднимает встроенный HTTP-сервер в локальной сети, показывает QR-код и короткий адрес
/// `http://<ip>:<port>`. Пользователь сканирует QR телефоном, вставляет ссылку подписки
/// или ключ в браузере телефона и одним нажатием отправляет её прямо в Tachyon на ТВ.
Future<void> showTvReceiveDialog(
  BuildContext context,
  AppController controller,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _TvReceiveDialog(
      controller: controller,
      rootContext: context,
    ),
  );
}

class _TvReceiveDialog extends StatefulWidget {
  const _TvReceiveDialog({
    required this.controller,
    required this.rootContext,
  });

  final AppController controller;
  final BuildContext rootContext;

  @override
  State<_TvReceiveDialog> createState() => _TvReceiveDialogState();
}

class _TvReceiveDialogState extends State<_TvReceiveDialog> {
  HttpServer? _server;
  String? _serverUrl;
  String _statusText = 'Запуск локального приёмника Wi-Fi...';
  bool _importing = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  Future<String> _resolveLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      String? fallbackIp;
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('tun') ||
            name.contains('ppp') ||
            name.contains('wg') ||
            name.contains('lo')) {
          continue;
        }
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('127.') || ip.startsWith('10.10.0.')) continue;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
          fallbackIp ??= ip;
        }
      }
      if (fallbackIp != null) return fallbackIp;
    } catch (_) {}
    return '127.0.0.1';
  }

  Future<void> _startServer() async {
    try {
      final ip = await _resolveLanIp();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      if (!mounted) {
        await server.close(force: true);
        return;
      }
      final url = 'http://$ip:${server.port}';
      setState(() {
        _server = server;
        _serverUrl = url;
        _statusText =
            'Отсканируйте QR-код камерой телефона или откройте адрес в браузере в той же Wi-Fi сети';
      });

      server.listen((HttpRequest req) async {
        try {
          req.response.headers.set('Access-Control-Allow-Origin', '*');
          req.response.headers.set(
            'Access-Control-Allow-Methods',
            'GET, POST, OPTIONS',
          );
          req.response.headers.set(
            'Access-Control-Allow-Headers',
            'Content-Type',
          );

          if (req.method == 'OPTIONS') {
            req.response.statusCode = HttpStatus.noContent;
            await req.response.close();
            return;
          }

          if (req.method == 'POST' && req.uri.path == '/import') {
            final rawBody = await utf8.decoder.bind(req).join();
            var payload = rawBody.trim();
            if (payload.startsWith('{')) {
              try {
                final decoded = jsonDecode(payload);
                if (decoded is Map && decoded['payload'] != null) {
                  payload = decoded['payload'].toString().trim();
                }
              } catch (_) {}
            }

            if (payload.isEmpty) {
              req.response.statusCode = HttpStatus.badRequest;
              req.response.headers.contentType = ContentType.json;
              req.response.write(jsonEncode({
                'ok': false,
                'message': 'Пустая ссылка или конфигурация',
              }));
              await req.response.close();
              return;
            }

            if (mounted) {
              setState(() {
                _importing = true;
                _statusText = 'Получены данные с телефона, импортируем...';
              });
            }

            final added = await widget.controller.importProfiles(payload);
            final msg = switch (added) {
              -1 => 'Подписка успешно добавлена на ТВ — серверы загружены!',
              0 => widget.controller.lastError.isNotEmpty
                  ? widget.controller.lastError
                  : 'Не удалось распознать ссылку или профиль',
              _ => 'Успешно добавлено профилей на ТВ: $added',
            };
            final ok = added != 0;

            req.response.statusCode = HttpStatus.ok;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({
              'ok': ok,
              'added': added,
              'message': msg,
            }));
            await req.response.close();

            if (!mounted) return;
            if (ok) {
              Navigator.of(context).pop();
              if (widget.rootContext.mounted) {
                ScaffoldMessenger.maybeOf(widget.rootContext)?.showSnackBar(
                  SnackBar(content: Text(msg)),
                );
              }
            } else {
              setState(() {
                _importing = false;
                _statusText = msg;
              });
            }
            return;
          }

          req.response.statusCode = HttpStatus.ok;
          req.response.headers.contentType =
              ContentType('text', 'html', charset: 'utf-8');
          req.response.write(_buildReceiverHtml());
          await req.response.close();
        } catch (_) {
          try {
            await req.response.close();
          } catch (_) {}
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorText = 'Не удалось запустить локальный сервер: $e';
      });
    }
  }

  String _buildReceiverHtml() {
    return '''<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<title>Tachyon TV — Отправка подписки</title>
<style>
  :root {
    --bg: #0e0c15;
    --card: #161321;
    --line: #282338;
    --ink: #f4f1fa;
    --muted: #9e96b0;
    --accent: #a78bfa;
    --ok: #34d399;
    --err: #f87171;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    padding: 20px;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    background: var(--bg);
    color: var(--ink);
    display: flex;
    justify-content: center;
    align-items: center;
    min-height: 92vh;
  }
  .box {
    width: 100%;
    max-width: 460px;
    background: var(--card);
    border: 1px solid var(--line);
    border-radius: 18px;
    padding: 22px;
  }
  .brand {
    font-size: 18px;
    font-weight: 700;
    letter-spacing: 3px;
    margin-bottom: 6px;
    color: var(--ink);
  }
  .sub {
    font-size: 13px;
    color: var(--muted);
    line-height: 1.45;
    margin-bottom: 16px;
  }
  textarea {
    width: 100%;
    min-height: 120px;
    background: #0b0910;
    color: var(--ink);
    border: 1px solid var(--line);
    border-radius: 12px;
    padding: 12px;
    font-family: monospace;
    font-size: 13px;
    resize: vertical;
    outline: none;
  }
  textarea:focus { border-color: var(--accent); }
  .btn {
    width: 100%;
    margin-top: 12px;
    padding: 14px;
    border: none;
    border-radius: 12px;
    background: var(--accent);
    color: #15121f;
    font-size: 15px;
    font-weight: 700;
    cursor: pointer;
  }
  .btn:disabled { opacity: 0.6; }
  .status {
    margin-top: 14px;
    font-size: 13px;
    line-height: 1.4;
    display: none;
    padding: 10px 12px;
    border-radius: 10px;
  }
</style>
</head>
<body>
  <div class="box">
    <div class="brand">⚡ TACHYON TV</div>
    <div class="sub">
      Вставьте ссылку на подписку (https://...), ключ (vless://, vmess://, trojan://, hy2://, awg://) или конфиг — он мгновенно появится на телевизоре.
    </div>
    <textarea id="inp" placeholder="https://... или vless://..."></textarea>
    <button class="btn" id="sendBtn" onclick="sendToTv()">Отправить на телевизор ⚡</button>
    <div class="status" id="st"></div>
  </div>
  <script>
    async function sendToTv() {
      const inp = document.getElementById('inp');
      const btn = document.getElementById('sendBtn');
      const st = document.getElementById('st');
      const val = inp.value.trim();
      if (!val) return;
      btn.disabled = true;
      btn.textContent = 'Отправка и загрузка на ТВ...';
      st.style.display = 'none';
      try {
        const res = await fetch('/import', {
          method: 'POST',
          headers: {'Content-Type': 'application/json'},
          body: JSON.stringify({payload: val})
        });
        const data = await res.json();
        st.style.display = 'block';
        st.style.background = data.ok ? 'rgba(52,211,153,0.15)' : 'rgba(248,113,113,0.15)';
        st.style.color = data.ok ? '#34d399' : '#f87171';
        st.textContent = data.message || (data.ok ? 'Успешно отправлено!' : 'Ошибка импорта');
        if (data.ok) inp.value = '';
      } catch (e) {
        st.style.display = 'block';
        st.style.background = 'rgba(248,113,113,0.15)';
        st.style.color = '#f87171';
        st.textContent = 'Ошибка соединения с ТВ: ' + e;
      } finally {
        btn.disabled = false;
        btn.textContent = 'Отправить на телевизор ⚡';
      }
    }
  </script>
</body>
</html>''';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final url = _serverUrl;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.tv_rounded, color: tokens.accent, size: 22),
          const SizedBox(width: Space.sm),
          const Expanded(
            child: Text('Приём подписки на ТВ по Wi-Fi'),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: _errorText != null
            ? Text(_errorText!, style: TextStyle(color: tokens.danger))
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _statusText,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: Space.lg),
                  if (url != null) ...[
                    QrCodeView(data: url, size: 196),
                    const SizedBox(height: Space.md),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Space.md,
                        vertical: Space.sm,
                      ),
                      decoration: BoxDecoration(
                        color: tokens.surface,
                        borderRadius: BorderRadius.circular(Radii.control),
                        border: Border.all(
                          color: tokens.accent.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wifi_rounded,
                              size: 16, color: tokens.accent),
                          const SizedBox(width: Space.sm),
                          Flexible(
                            child: Text(
                              url,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: tokens.ink,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.all(Space.xl),
                      child: CircularProgressIndicator(),
                    ),
                  if (_importing) ...[
                    const SizedBox(height: Space.md),
                    const LinearProgressIndicator(),
                  ],
                  const SizedBox(height: Space.md),
                  const Pill(
                    label:
                        '1. Наведите камеру телефона на QR   2. Вставьте ссылку   3. Нажмите Отправить',
                    icon: Icons.phonelink_rounded,
                  ),
                ],
              ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
