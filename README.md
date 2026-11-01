<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="tachyon-proxy — Android VPN и клиент обхода DPI на базе Rust-ядра tachyon-core">
</p>

<p align="center">
  <a href="https://github.com/Dushnilin/tachyon-core"><img src="https://img.shields.io/badge/engine-tachyon--core%20(Rust)-B9A8FF?style=flat-square&labelColor=141417" alt="Engine: tachyon-core"></a>
  <a href="https://github.com/Dushnilin/tachyon-lists"><img src="https://img.shields.io/badge/rules-tachyon--lists%20(.trs)-6FD08C?style=flat-square&labelColor=141417" alt="Rules: tachyon-lists"></a>
  <img src="https://img.shields.io/badge/Android-8.0%2B%20(API%2026)-A8A8AD?style=flat-square&labelColor=141417" alt="Android 8.0+">
  <img src="https://img.shields.io/badge/ABI-arm64--v8a%20%7C%20armeabi--v7a%20%7C%20x86__64-A8A8AD?style=flat-square&labelColor=141417" alt="ABI">
</p>

**`tachyon-proxy`** — самостоятельный Android VPN-клиент и пакетный десинхронизатор ТСПУ (DPI) на Flutter, построенный поверх нативного Rust-движка [`tachyon-core`](https://github.com/Dushnilin/tachyon-core).

Приложение формирует конфигурацию `sing-box`-совместимого ядра, поднимает системный `VpnService` (TUN), защищает исходящие сокеты от петель маршрутизации через локальный Unix-сокет `protect_path` и передаёт управление трафиком в `libtachyon.so` по JNI.

---

## Чем отличается

- **Два контура в одном ядре: Прокси + Нативный DPI Desync.** Можно работать через удалённый сервер (`VLESS`, `REALITY`, `XHTTP`, `Hysteria2`, `TUIC v5`, `Trojan`, `Shadowsocks-2022`, `AnyTLS`, `SOCKS5`), включить автономный режим **Обход DPI (Desync)** вообще без VPN-сервера (разрезание TLS ClientHello `fake_split` / `fake_disorder` / `tlsrec` с обманом `autottl` / `md5` и подавлением `UDP:443` QUIC), либо комбинировать их одновременно (например: YouTube и Discord идут через `Desync`, Instagram и ChatGPT — через `VLESS`, а банки и `.ru` — напрямую).
- **Честная обратная связь от движка.** Статус «Подключено» выставляется только после фактического старта `libtachyon.so` и валидации схемы. Живая скорость (`↑/↓`), график нагрузки (спарклайн), счётчик активных соединений и сквозной `HTTP 204` тест считываются напрямую из туннеля.
- **Полная интеграция с Android.** Плитка быстрых настроек в шторке (`Quick Settings Tile`), информативное уведомление с живой скоростью и кнопками **«Отключить»** / **«След. сервер»**, автозапуск при загрузке ОС (`BOOT_COMPLETED`) и раздача прокси в локальную сеть (`Allow LAN 0.0.0.0:2080`).

---

## Как устроен конвейер

<p align="center">
  <img src="./assets/readme/architecture.svg" width="100%" alt="Архитектура конвейера трафика tachyon-proxy: Flutter UI, Kotlin VpnService и Rust JNI-движок tachyon-core">
</p>

| Слой | Путь в репозитории | Задача |
| :--- | :--- | :--- |
| **UI и дизайн-система** | `lib/features/`, `lib/app/` | 4 основных экрана (Туннель, Профили, Правила, Настройки), монитор соединений, экран приложений, DNS и журнал; токены `Morphe` в `lib/app/theme/tokens.dart` |
| **Контроллер и конфигуратор** | `lib/core/app_controller.dart`, `lib/core/models/runtime_config.dart` | Парсинг подписок (`Subscription-Userinfo`, `Profile-Title`, Base64/URI), генерация JSON для ядра, TCP/HTTP пинг, автоподбор сервера |
| **Каналы связи** | `lib/core/services/core_bridge.dart` | `MethodChannel` + `EventChannel` между Flutter и Android-слоем |
| **Android VPN-сервис** | `android/app/src/main/kotlin/org/tachyon/vpn/` | `TachyonVpnService`, `TachyonTileService`, `BootReceiver`, Unix-сервер `protectSocket`, фоновый цикл статистики уведомления |
| **JNI FFI и ядро** | `native/core-ffi/`, `android/app/src/main/jniLibs/` | Обвязка `TachyonCore` (`start`, `stop`, `check`, `stats`, `version`) вокруг `tachyon-core` |

---

## Возможности по разделам

### 1. Туннель (Дашборд)
- Кольцевой индикатор состояния туннеля, таймер сессии и переключатель режимов в 1 тап (**По правилам**, **Обход DPI**, **Весь трафик**, **Исключения**).
- Карточка трафика с живой скоростью (`↑ КБ/с`, `↓ МБ/с`), мини-спарклайном и быстрым переходом в монитор активных соединений.
- Карточка текущего сервера с кнопкой сквозного `HTTP-теста` (`http://cp.cloudflare.com/generate_204`) и генерацией QR-кода.
- Поиск по серверам, кнопка **«Лучший»** (пакетный TCP-пинг и автовыбор минимальной задержки) и сворачиваемые группы подписок.

### 2. Профили и подписки
- Импорт ссылок `vless://`, `trojan://`, `ss://`, `vmess://`, `hysteria2://`, `hy2://`, `tuic://`, `anytls://`, `socks://`, `wg://`, `https://`-подписок (с передачей `X-Hwid`) и сырых JSON-аутбаундов.
- Отображение остатка трафика (прогресс-бар гигабайт) и даты окончания подписки из заголовка `Subscription-Userinfo`.
- Кнопка очистки недоступных серверов (`✗`) после пинга.
- Полноценный редактор сервера (протокол, транспорт `TCP`/`XHTTP`/`WS`/`gRPC`/`HTTPUpgrade`, безопасность `None`/`TLS`/`REALITY`, `SNI`, `Flow`, `pbk`, `sid`, `uTLS Fingerprint`).
- Встроенный векторный генератор QR-кодов (`ISO/IEC 18004`) без сторонних зависимостей, экспорт URI и системное меню «Поделиться».

### 3. Правила и обход ТСПУ (Desync)
- **Пользовательские правила**: быстрое добавление `domain_suffix`, `domain`, `domain_keyword` и `ip_cidr` с выбором действия (`ТУННЕЛЬ`, `НАПРЯМУЮ`, `ОБХОД DPI`, `БЛОК`).
- **Точечно по сервисам**: готовые пресеты для YouTube, Discord, Telegram, Instagram/Meta, ChatGPT/AI и российских сайтов/банков (`.ru`).
- **Настройка Desync**: выбор рецепта (`auto`, `fake_split`, `fake_disorder`, `tlsrec`, `multi_split`, `split`, `disorder`), метода обмана ТСПУ (`autottl`, `md5`, `timestamp`, `badseq`, `badsum`) и кнопка автоматического тестирования доступности YouTube/Discord.
- **Каталог [`tachyon-lists`](https://github.com/Dushnilin/tachyon-lists)**: скачивание бинарных `.trs`-списков с проверкой `SHA-256`, поиск и фильтрация активных наборов.

### 4. Приложения, DNS, Соединения и Настройки
- **Приложения**: реальные иконки установленных пакетов, закрепление настроенных приложений вверху списка, фильтр системных пакетов и шаблоны в 1 клик (*«Банки и РФ → Напрямую»*, *«YouTube / Discord → DPI»*).
- **DNS и анти-утечки**: режим **FakeIP (`198.18.0.0/15`)**, выбор стратегии маршрутизации DNS (*Раздельный `.ru` напрямую*, *Всегда через прокси*, *Напрямую*), чипы популярных DoH-резолверов (`Google`, `Cloudflare`, `Quad9`, `AdGuard`, `Comss`, `Яндекс`) и встроенный бенчмарк задержки.
- **Активные соединения**: живой список зафиксированных `TCP`/`UDP` узлов из ядра с созданием правила для любого домена или IP в один тап.
- **Журнал и резервное копирование**: `Live-tail` логов ядра с фильтрацией по уровням (`ERROR`, `WARN`, `INFO`), настройка `MTU` (`1360`..`9000`), `Allow LAN (:2080)` и полный экспорт/импорт настроек в `JSON`.

---

## Быстрая сборка

### На Windows (рекомендуется, ~15–25 сек)

Скрипт [`build.ps1`](./build.ps1) собирает APK локально через Flutter и Android SDK/NDK, а с флагом `-Native` предварительно компилирует свежий `libtachyon.so` из соседнего репозитория `G:\tachyon-core`:

```powershell
# Собрать APK с готовыми библиотеками libtachyon.so и сразу установить по ADB:
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Install

# Пересобрать Rust-ядро (libtachyon.so) из G:\tachyon-core + собрать и установить APK:
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Native -Install
```

Готовый релизный пакет сохраняется в `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.

### Сборка в Docker (Linux / CI)

```bash
# 1. Сборочный образ (Flutter + Android SDK/NDK r27 + Rust)
docker build -t tachyon-proxy-build -f docker/Dockerfile .

# 2. Кросс-компиляция libtachyon.so для arm64-v8a, armeabi-v7a и x86_64
docker run --rm -v "$PWD:/src" -v "/path/to/tachyon-core:/core:ro" \
    tachyon-proxy-build bash docker/build_native.sh

# 3. Сборка release APK
docker run --rm -v "$PWD:/src" -w /src \
    tachyon-proxy-build bash docker/build_apk.sh
```

---

## Проверка кода

```bash
flutter analyze
flutter test
```

## Системные требования

| Параметр | Значение |
| :--- | :--- |
| **Application ID** | `app.tachyon.tachyon_proxy` |
| **Минимальная ОС** | Android 8.0 Oreo (`API 26`) и новее |
| **Архитектуры (ABI)** | `arm64-v8a`, `armeabi-v7a`, `x86_64` |
| **Сетевой стек** | Системный `VpnService` (IPv4 TUN + локальный DNS/FakeIP перехват) |
