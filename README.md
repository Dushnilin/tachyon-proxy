<p align="center">
  <img src="./assets/readme/hero.svg" width="100%" alt="tachyon-proxy — Android VPN и клиент обхода DPI на базе Rust-ядра tachyon-core">
</p>

<p align="center">
  <a href="https://github.com/Dushnilin/tachyon-proxy/actions/workflows/build.yml"><img src="https://img.shields.io/github/actions/workflow/status/Dushnilin/tachyon-proxy/build.yml?branch=main&style=flat-square&label=APK%20Build&labelColor=141417&color=6FD08C" alt="Build Status"></a>
  <a href="https://github.com/Dushnilin/tachyon-proxy/releases"><img src="https://img.shields.io/badge/APK-Releases-B9A8FF?style=flat-square&labelColor=141417" alt="Releases"></a>
  <a href="https://github.com/Dushnilin/tachyon-core"><img src="https://img.shields.io/badge/engine-tachyon--core%20(Rust)-B9A8FF?style=flat-square&labelColor=141417" alt="Engine: tachyon-core"></a>
  <a href="https://github.com/Dushnilin/tachyon-lists"><img src="https://img.shields.io/badge/rules-tachyon--lists%20(.trs)-6FD08C?style=flat-square&labelColor=141417" alt="Rules: tachyon-lists"></a>
  <img src="https://img.shields.io/badge/Android-8.0%2B_%7C_Android_TV-A8A8AD?style=flat-square&labelColor=141417" alt="Android 8.0+ & Android TV">
  <img src="https://img.shields.io/badge/iOS-15.0%2B%20(arm64)-38BDF8?style=flat-square&labelColor=141417" alt="iOS 15.0+">
</p>

**`tachyon-proxy`** — самостоятельный VPN-клиент и пакетный десинхронизатор ТСПУ (DPI) для **Android**, **Android TV** и **iOS / iPadOS** на Flutter, построенный поверх нативного Rust-движка [`tachyon-core`](https://github.com/Dushnilin/tachyon-core).

Приложение формирует конфигурацию `sing-box`-совместимого ядра, поднимает системный туннель (`VpnService` на Android и `NEPacketTunnelProvider` на iOS), защищает исходящие сокеты от петель маршрутизации и передаёт управление трафиком в нативное ядро (`libtachyon.so` по JNI / `TachyonCore.xcframework` по C-ABI).

---

## Скачать APK и IPA

Готовые сборки автоматически публикуются через GitHub Actions в разделе **[Releases](https://github.com/Dushnilin/tachyon-proxy/releases)**:

- **`tachyon-proxy-ios.ipa`** — сборка для **iPhone и iPad (`iOS / iPadOS 15.0+`, `arm64`)** с вшитыми правами `NEPacketTunnelProvider` (установка через TrollStore, SideStore, AltStore, Sideloadly, ESign, Feather)
- **`tachyon-proxy-android-tv.apk`** — сборка для **Android TV / Google TV и ТВ-приставок** (`armeabi-v7a` + `arm64-v8a`, Leanback-лончер, управление пультом ДУ / D-pad, приём подписок по Wi-Fi QR)
- **`tachyon-proxy-arm64-v8a.apk`** — основной пакет для современных смартфонов Android (`64-bit ARM`)
- **`tachyon-proxy-armeabi-v7a.apk`** — для `32-bit ARM` устройств и ТВ-боксов
- **`tachyon-proxy-x86_64.apk`** — для эмуляторов и `x86_64` систем
- **`tachyon-proxy-universal.apk`** — универсальный APK со всеми архитектурами

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
| **iOS Network Extension** | `ios/Runner/`, `ios/PacketTunnelExtension/` | `PacketTunnelProvider` (`NEPacketTunnelProvider`), связка `utun` с `TachyonCore.xcframework`, IPC `sendProviderMessage` и `App Group` |
| **Нативное ядро** | `Dushnilin/tachyon-core` | Динамические библиотеки `libtachyon-*.so` (Android JNI) и `TachyonCore.xcframework` (iOS C-ABI) |

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

## Системные требования

| Параметр | Значение |
| :--- | :--- |
| **Application ID / Bundle ID** | `app.tachyon.tachyon_proxy` (Android) / `app.tachyon.tachyonProxy` (iOS) |
| **Минимальная ОС** | Android 8.0+ (`API 26`), Android TV / Google TV, iOS / iPadOS 15.0+ |
| **Архитектуры (ABI)** | `arm64-v8a`, `armeabi-v7a`, `x86_64` (Android) · `arm64` (iOS) |
| **Сетевой стек** | `VpnService` (Android) и `NEPacketTunnelProvider` (`utun`, iOS) + локальный DNS/FakeIP перехват |

---

## 💖 Поддержать разработку

Если Tachyon помогает вам и делает работу в сети комфортной, вы можете поддержать проект и автора! ☕ 🧀 🌭

⭐ **Boosty (подписки, донаты, эксклюзив):**  
👉 [**Поддержать на Boosty**](https://boosty.to/tachyon)

💳 **Карты РФ / СБП / Tinkoff Pay:**  
👉 [**Поддержать проект на CloudTips**](https://pay.cloudtips.ru/p/449c5ef9)

🪙 **Криптовалюта:**
* **Bitcoin (BTC):** `bc1q9ehdv7y9g948jejyflkq7xmau3tytgunxgh35h`
* **Ethereum (ETH / ERC-20):** `0x6CB7a4547eD62EF64990D5C6B5D9fdA58EB223E6`
* **TON:** `UQDPhLRjMz5KltDLACAT3YXXHDVEtIDOHky2i33ZIOtsMEoR`
* **Solana (SOL):** `3csTGaNeU9KjhCKHEKAU3XLS5UfVjEeBVhXihpsETZwh`
