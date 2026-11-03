package app.tachyon.tachyon_proxy

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.LruCache
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.tachyon.vpn.QrScannerActivity
import org.tachyon.vpn.TachyonCore
import org.tachyon.vpn.TachyonVpnService
import org.tachyon.vpn.TunnelStateHolder
import org.tachyon.vpn.WifiSsidHelper
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Мост между Flutter и нативным слоем.
 *
 * Два канала:
 *  - `app.tachyon.proxy/vpn` — команды: проверить конфигурацию, поднять и
 *    остановить туннель, узнать состояние, прочитать журнал;
 *  - `app.tachyon.proxy/events` — события: смена состояния туннеля.
 *
 * Нативные вызовы блокирующие, поэтому `check` и `version` уходят в
 * отдельный поток: главный поток Flutter ждать не должен.
 */
class MainActivity : FlutterFragmentActivity() {

    private var eventSink: EventChannel.EventSink? = null
    private var pendingCmd: String? = null
    private var pendingDeepLink: String? = null

    /** Запрос, ждущий разрешения на VPN. */
    private var pendingStart: PendingStart? = null
    private var pendingQrResult: MethodChannel.Result? = null
    private var pendingWifiPermResult: MethodChannel.Result? = null

    /** Запрос разрешения геолокации для чтения SSID Wi-Fi в режиме «Домашний интернет». */
    private val wifiPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { _ ->
            val res = pendingWifiPermResult
            pendingWifiPermResult = null
            res?.success(WifiSsidHelper.hasLocationPermission(this))
        }

    /**
     * Уведомление о туннеле нужно пользователю, но отказ на него не мешает
     * работе: сервис остаётся foreground-состоянием.
     */
    private val notificationPermission =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            if (!granted) {
                android.util.Log.i("Tachyon", "уведомления запрещены")
            }
        }

    /** Результат сканирования QR-кода (камера или галерея). */
    private val qrScannerLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { answer ->
            val res = pendingQrResult
            pendingQrResult = null
            if (res == null) return@registerForActivityResult
            if (answer.resultCode == RESULT_OK) {
                val text = answer.data?.getStringExtra(QrScannerActivity.EXTRA_QR_RESULT)
                res.success(text)
            } else {
                res.success(null)
            }
        }

    /** Запрос разрешения на VPN: `onActivityResult` в новых SDK удалён. */
    private val vpnPermission =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { answer ->
            val pending = pendingStart
            pendingStart = null
            if (pending == null) return@registerForActivityResult

            if (answer.resultCode == RESULT_OK) {
                startTunnel(
                    pending.config,
                    pending.allowedApps,
                    pending.disallowedApps,
                    pending.serverName,
                    pending.mtu,
                    pending.proxyOnly,
                )
                pending.result.success(null)
            } else {
                TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null)
                pending.result.success("разрешение VPN не выдано")
            }
        }

    private val stateListener = TunnelStateHolder.Listener { _, error ->
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "state",
                    "status" to TunnelStateHolder.stateName(),
                    "error" to (error ?: ""),
                    "pausedWifiSsid" to TunnelStateHolder.pausedByWifiSsid,
                ),
            )
        }
    }

    private val commandListener = TunnelStateHolder.CommandListener { cmd ->
        runOnUiThread {
            eventSink?.success(mapOf("type" to "cmd", "cmd" to cmd))
        }
    }

    private val iconCache = LruCache<String, ByteArray>(256)

    override fun onCreate(savedInstanceState: Bundle?) {
        runCatching {
            @Suppress("DEPRECATION")
            val pkgInfo = packageManager.getPackageInfo(packageName, 0)
            val customSo = File(TachyonCore.CUSTOM_SO_PATH)
            if (customSo.exists() && customSo.lastModified() < pkgInfo.lastUpdateTime) {
                customSo.setWritable(true, true)
                customSo.delete()
                File(TachyonCore.CUSTOM_STAMP_PATH).delete()
            }
        }
        super.onCreate(savedInstanceState)
        WifiSsidHelper.ensureRegistered(applicationContext)
        intent?.getStringExtra("cmd")?.let { cmd ->
            if (cmd == "dump_log") {
                dumpDiagnostics()
            } else {
                pendingCmd = cmd
            }
        }
        extractIncomingLink(intent)?.let { link ->
            pendingDeepLink = link
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(android.Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        intent.getStringExtra("cmd")?.let { cmd ->
            if (cmd == "dump_log") {
                dumpDiagnostics()
                return
            }
            val sink = eventSink
            if (sink != null) {
                runOnUiThread { sink.success(mapOf("type" to "cmd", "cmd" to cmd)) }
            } else {
                pendingCmd = cmd
            }
        }
        extractIncomingLink(intent)?.let { link ->
            val sink = eventSink
            if (sink != null) {
                runOnUiThread { sink.success(mapOf("type" to "deeplink", "url" to link)) }
            } else {
                pendingDeepLink = link
            }
        }
    }

    private fun extractIncomingLink(intent: Intent?): String? {
        if (intent == null) return null
        when (intent.action) {
            Intent.ACTION_VIEW -> {
                val data = intent.dataString?.trim()
                if (!data.isNullOrEmpty()) return data
            }
            Intent.ACTION_SEND -> {
                val text = intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()
                if (!text.isNullOrEmpty()) return text
            }
        }
        return null
    }

    private fun dumpDiagnostics() {
        Thread({
            try {
                val ver = runCatching { TachyonCore.version() }.getOrNull()
                android.util.Log.i("TachyonDump", "ENGINE VERSION: $ver (customSo=${TachyonCore.isCustomSoLoaded})")
                val stats = runCatching { TachyonCore.stats() }.getOrNull()
                android.util.Log.i("TachyonDump", "STATS: $stats")
                val logFile = File(filesDir, LOG_FILE_NAME)
                if (logFile.exists()) {
                    val lines = logFile.readLines()
                    val tail = if (lines.size > 150) lines.subList(lines.size - 150, lines.size) else lines
                    android.util.Log.i("TachyonDump", "=== TACHYON.LOG (${lines.size} lines) ===")
                    for (line in tail) {
                        android.util.Log.i("TachyonDump", "LOG: $line")
                    }
                } else {
                    android.util.Log.i("TachyonDump", "TACHYON.LOG does not exist")
                }
            } catch (e: Throwable) {
                android.util.Log.e("TachyonDump", "dump failed", e)
            }
        }, "tachyon-dump").start()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_VPN)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "check" -> handleCheck(call, result)
                    "fetchSubscription" -> handleFetchSubscription(call, result)
                    "parseSubscription" -> handleParseSubscription(call, result)
                    "start" -> handleStart(call, result)
                    "stop" -> handleStop(result)
                    "status" -> result.success(currentStatus())
                    "version" -> handleVersion(result)
                    "stats" -> handleStats(result)
                    "logs" -> handleLogs(call, result)
                    "clearLogs" -> handleClearLogs(result)
                    "apps" -> handleApps(result)
                    "appIcon" -> handleAppIcon(call, result)
                    "shareText" -> handleShareText(call, result)
                    "openUrl" -> handleOpenUrl(call, result)
                    "scanQr" -> handleScanQr(call, result)
                    "networkInfo" -> result.success(currentNetworkType())
                    "wifiInfo" -> result.success(currentWifiInfo())
                    "requestWifiPermission" -> handleRequestWifiPermission(result)
                    "openLocationSettings" -> handleOpenLocationSettings(result)
                    "recheckHomeWifi" -> handleRecheckHomeWifi(result)
                    "forceResumeFromWifi" -> handleForceResumeFromWifi(result)
                    "filesDir" -> result.success(filesDir.absolutePath)
                    "deviceAbi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                    "installEngineSo" -> handleInstallEngineSo(call, result)
                    "installApk" -> handleInstallApk(call, result)
                    "consumeLaunchLink" -> {
                        val link = pendingDeepLink
                        pendingDeepLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_EVENTS)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                        eventSink = events
                        TunnelStateHolder.addListener(stateListener)
                        TunnelStateHolder.addCommandListener(commandListener)
                        pendingCmd?.let { cmd ->
                            pendingCmd = null
                            runOnUiThread { events?.success(mapOf("type" to "cmd", "cmd" to cmd)) }
                        }
                        pendingDeepLink?.let { link ->
                            pendingDeepLink = null
                            runOnUiThread { events?.success(mapOf("type" to "deeplink", "url" to link)) }
                        }
                    }

                    override fun onCancel(arguments: Any?) {
                        TunnelStateHolder.removeListener(stateListener)
                        TunnelStateHolder.removeCommandListener(commandListener)
                        eventSink = null
                    }
                },
            )
    }

    override fun onDestroy() {
        TunnelStateHolder.removeListener(stateListener)
        TunnelStateHolder.removeCommandListener(commandListener)
        super.onDestroy()
    }

    /** Проверяет конфигурацию движком: ответ приходит из отдельного потока. */
    private fun handleCheck(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.success("""{"ok":false,"error":"пустая конфигурация"}""")
            return
        }
        Thread({
            val response = runCatching { TachyonCore.check(config) }
                .getOrElse { error -> """{"ok":false,"error":"${escape(error.message)}"}""" }
            runOnUiThread { result.success(response) }
        }, "tachyon-check").start()
    }

    /** Адаптивная загрузка подписки напрямую через движок tachyon-core. */
    private fun handleFetchSubscription(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url").orEmpty()
        val customUa = call.argument<String>("customUa").orEmpty()
        val sendHwid = call.argument<Boolean>("sendHwid") ?: true
        val customHwid = call.argument<String>("customHwid").orEmpty()
        val insecure = call.argument<Boolean>("insecure") ?: false
        if (url.isBlank()) {
            result.success("""{"ok":false,"error":"пустой URL"}""")
            return
        }
        Thread({
            val response = runCatching {
                TachyonCore.fetchSubscription(url, customUa, sendHwid, customHwid, insecure)
            }.getOrElse { error -> """{"ok":false,"error":"${escape(error.message)}"}""" }
            runOnUiThread { result.success(response) }
        }, "tachyon-sub-fetch").start()
    }

    /** Разбор любого текста/JSON/YAML подписки напрямую через движок tachyon-core. */
    private fun handleParseSubscription(call: MethodCall, result: MethodChannel.Result) {
        val payload = call.argument<String>("payload").orEmpty()
        if (payload.isBlank()) {
            result.success("""{"ok":false,"error":"пустой ответ"}""")
            return
        }
        Thread({
            val response = runCatching {
                TachyonCore.parseSubscription(payload)
            }.getOrElse { error -> """{"ok":false,"error":"${escape(error.message)}"}""" }
            runOnUiThread { result.success(response) }
        }, "tachyon-sub-parse").start()
    }

    /**
     * Поднимает туннель.
     *
     * Перед стартом проверяется разрешение VPN: без него система покажет свой
     * диалог, и ответ придёт в [onActivityResult].
     */
    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.success("пустая конфигурация")
            return
        }
        val allowedApps = call.argument<List<String>>("allowedApps").orEmpty()
        val disallowedApps = call.argument<List<String>>("disallowedApps").orEmpty()
        val serverName = call.argument<String>("serverName").orEmpty()
        val mtu = call.argument<Int>("mtu") ?: 9000
        val proxyOnly = call.argument<Boolean>("proxyOnly") ?: false

        // Проверяем конфигурацию до запроса разрешения: если она невалидна,
        // пользователю незачем показывать диалог VPN.
        val check = runCatching { TachyonCore.check(config) }.getOrNull()
        if (check == null) {
            result.success("движок недоступен: ${TachyonCore.lastError()}")
            return
        }
        val verdict = runCatching { JSONObject(check) }.getOrNull()
        val accepted = verdict?.optBoolean("ok", false) ?: false
        if (!accepted) {
            val reason = verdict?.optString("error").orEmpty().ifEmpty { check }
            result.success("конфигурация отклонена движком: $reason")
            return
        }

        if (!proxyOnly) {
            val prepare = VpnService.prepare(this)
            if (prepare != null) {
                pendingStart = PendingStart(config, allowedApps, disallowedApps, serverName, mtu, proxyOnly, result)
                vpnPermission.launch(prepare)
                return
            }
        }
        startTunnel(config, allowedApps, disallowedApps, serverName, mtu, proxyOnly)
        result.success(null)
    }

    /** Останавливает туннель. */
    private fun handleStop(result: MethodChannel.Result) {
        val intent = Intent(this, TachyonVpnService::class.java).setAction(
            TachyonVpnService.ACTION_STOP,
        )
        startService(intent)
        result.success(null)
    }

    /** Текущее состояние туннеля. */
    private fun currentStatus(): Map<String, Any?> = mapOf(
        "status" to TunnelStateHolder.stateName(),
        "error" to (TunnelStateHolder.error ?: ""),
        "server" to TunnelStateHolder.serverName,
        "pausedWifiSsid" to TunnelStateHolder.pausedByWifiSsid,
    )

    /** Версия нативного ядра. */
    private fun handleVersion(result: MethodChannel.Result) {
        Thread({
            val version = runCatching { TachyonCore.version() }.getOrNull()
            runOnUiThread { result.success(version ?: "неизвестно") }
        }, "tachyon-version").start()
    }

    /** Статистика трафика: байты и число соединений. */
    private fun handleStats(result: MethodChannel.Result) {
        Thread({
            val stats = TachyonCore.stats()
            runOnUiThread { result.success(stats) }
        }, "tachyon-stats").start()
    }

    /** Хвост журнала ядра. */
    private fun handleLogs(call: MethodCall, result: MethodChannel.Result) {
        val limit = call.argument<Int>("limit") ?: 400
        Thread({
            val file = File(filesDir, LOG_FILE_NAME)
            val lines = if (file.exists()) {
                runCatching { file.readLines() }.getOrDefault(emptyList())
            } else {
                emptyList()
            }
            val tail = if (lines.size > limit) lines.subList(lines.size - limit, lines.size) else lines
            runOnUiThread { result.success(tail) }
        }, "tachyon-logs").start()
    }

    /** Очищает журнал ядра. */
    private fun handleClearLogs(result: MethodChannel.Result) {
        Thread({
            val file = File(filesDir, LOG_FILE_NAME)
            runCatching { if (file.exists()) file.writeText("") }
            runOnUiThread { result.success(true) }
        }, "tachyon-clear-logs").start()
    }

    /** Возвращает PNG-иконку приложения (64x64) с кэшированием в память. */
    private fun handleAppIcon(call: MethodCall, result: MethodChannel.Result) {
        val pkg = call.argument<String>("package")
        if (pkg.isNullOrBlank()) {
            result.success(null)
            return
        }
        iconCache.get(pkg)?.let { cached ->
            result.success(cached)
            return
        }
        Thread({
            val bytes = runCatching {
                val drawable = packageManager.getApplicationIcon(pkg)
                val size = 64
                val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(bitmap)
                drawable.setBounds(0, 0, size, size)
                drawable.draw(canvas)
                val stream = ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG, 90, stream)
                bitmap.recycle()
                stream.toByteArray()
            }.getOrNull()
            if (bytes != null) {
                iconCache.put(pkg, bytes)
            }
            runOnUiThread { result.success(bytes) }
        }, "tachyon-icon").start()
    }

    /** Открывает системное меню «Поделиться» для текста/ссылки/резервной копии. */
    private fun handleShareText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text").orEmpty()
        val subject = call.argument<String>("subject").orEmpty()
        if (text.isEmpty()) {
            result.success(false)
            return
        }
        runCatching {
            val sendIntent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
                if (subject.isNotEmpty()) putExtra(Intent.EXTRA_SUBJECT, subject)
            }
            startActivity(Intent.createChooser(sendIntent, subject.ifEmpty { "Поделиться" }))
        }
        result.success(true)
    }

    /** Открывает внешнюю ссылку в браузере (или приложении по умолчанию). */
    private fun handleOpenUrl(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url").orEmpty().trim()
        if (url.isEmpty()) {
            result.success(false)
            return
        }
        val opened = runCatching {
            val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        }.getOrDefault(false)
        result.success(opened)
    }

    /** Запускает нативный сканер QR-кода (камера или выбор из галереи). */
    private fun handleScanQr(call: MethodCall, result: MethodChannel.Result) {
        val fromGallery = call.argument<Boolean>("fromGallery") ?: false
        pendingQrResult?.success(null)
        pendingQrResult = result
        val intent = Intent(this, QrScannerActivity::class.java).apply {
            putExtra(QrScannerActivity.EXTRA_GALLERY_ONLY, fromGallery)
        }
        qrScannerLauncher.launch(intent)
    }

    /** Определяет активный тип сети: wifi / cellular / ethernet / none (игнорируя VPN поверх сети). */
    @Suppress("DEPRECATION")
    private fun currentNetworkType(): String {
        if (WifiSsidHelper.isWifiConnected(this)) return "wifi"
        val cm = getSystemService(ConnectivityManager::class.java) ?: return "none"
        for (net in cm.allNetworks) {
            val caps = cm.getNetworkCapabilities(net) ?: continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) return "cellular"
            if (caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return "ethernet"
        }
        val active = cm.activeNetwork ?: return "none"
        val caps = cm.getNetworkCapabilities(active) ?: return "none"
        return when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }

    /** Возвращает информацию о текущем Wi-Fi подключении и видимых рядом сетях. */
    private fun currentWifiInfo(): Map<String, Any?> = mapOf(
        "ssid" to WifiSsidHelper.getCurrentWifiSsid(this),
        "isWifi" to WifiSsidHelper.isWifiConnected(this),
        "hasPermission" to WifiSsidHelper.hasLocationPermission(this),
        "locationEnabled" to WifiSsidHelper.isLocationEnabled(this),
        "nearbySsids" to WifiSsidHelper.getNearbySsids(this),
        "pausedWifiSsid" to TunnelStateHolder.pausedByWifiSsid,
    )

    private fun handleRequestWifiPermission(result: MethodChannel.Result) {
        if (WifiSsidHelper.hasLocationPermission(this)) {
            result.success(true)
            return
        }
        pendingWifiPermResult?.success(false)
        pendingWifiPermResult = result
        wifiPermissionLauncher.launch(
            arrayOf(
                android.Manifest.permission.ACCESS_FINE_LOCATION,
                android.Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
        )
    }

    private fun handleOpenLocationSettings(result: MethodChannel.Result) {
        runCatching {
            startActivity(
                Intent(android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
        }
        result.success(true)
    }

    private fun handleRecheckHomeWifi(result: MethodChannel.Result) {
        if (TunnelStateHolder.state == TunnelStateHolder.State.Running ||
            TunnelStateHolder.state == TunnelStateHolder.State.Starting ||
            TunnelStateHolder.pausedByWifiSsid.isNotEmpty()
        ) {
            runCatching {
                val intent = Intent(this, TachyonVpnService::class.java).setAction(
                    TachyonVpnService.ACTION_RECHECK_WIFI,
                )
                startService(intent)
            }
        }
        result.success(true)
    }

    private fun handleForceResumeFromWifi(result: MethodChannel.Result) {
        runCatching {
            val intent = Intent(this, TachyonVpnService::class.java).setAction(
                TachyonVpnService.ACTION_FORCE_RESUME,
            )
            startService(intent)
        }
        result.success(true)
    }

    /**
     * Пробует установить обновлённый бинарник движка `libtachyon.so` в `code_cache/engine`.
     * Если SELinux текущей версии Android блокирует `dlopen` из директории данных приложения,
     * возвращает `"requires_apk"`, чтобы приложение автоматически запустило обновление через APK.
     */
    private fun handleInstallEngineSo(call: MethodCall, result: MethodChannel.Result) {
        val srcPath = call.argument<String>("path")
        if (srcPath.isNullOrBlank()) {
            result.success("error: пустой путь к файлу")
            return
        }
        Thread({
            try {
                val srcFile = File(srcPath)
                if (!srcFile.exists() || srcFile.length() < 1_000_000L) {
                    runOnUiThread { result.success("error: файл ядра повреждён или не найден") }
                    return@Thread
                }
                val engineDir = File(codeCacheDir, "engine")
                engineDir.mkdirs()
                val targetSo = File(engineDir, "libtachyon.so")
                if (targetSo.exists()) {
                    targetSo.setWritable(true, true)
                    targetSo.delete()
                }
                srcFile.copyTo(targetSo, overwrite = true)
                srcFile.delete()
                targetSo.setWritable(false, false)
                targetSo.setReadable(true, false)
                targetSo.setExecutable(true, false)

                // Проверяем, разрешает ли SELinux прошивки dlopen из code_cache
                val probeSo = File(engineDir, "libtachyon_probe.so")
                if (probeSo.exists()) {
                    probeSo.setWritable(true, true)
                    probeSo.delete()
                }
                targetSo.copyTo(probeSo, overwrite = true)
                probeSo.setWritable(false, false)
                probeSo.setReadable(true, false)
                probeSo.setExecutable(true, false)

                var dlopenAllowed = false
                try {
                    System.load(probeSo.absolutePath)
                    dlopenAllowed = true
                } catch (e: Throwable) {
                    val msg = e.message.orEmpty()
                    if (msg.contains("already opened") || msg.contains("already loaded")) {
                        dlopenAllowed = true
                    }
                } finally {
                    runCatching {
                        probeSo.setWritable(true, true)
                        probeSo.delete()
                    }
                }

                if (!dlopenAllowed) {
                    runCatching {
                        targetSo.setWritable(true, true)
                        targetSo.delete()
                        File(TachyonCore.CUSTOM_STAMP_PATH).delete()
                    }
                    runOnUiThread { result.success("requires_apk") }
                    return@Thread
                }

                runCatching {
                    File(TachyonCore.CUSTOM_STAMP_PATH).writeText(System.currentTimeMillis().toString())
                }

                runOnUiThread {
                    result.success("ok")
                    // Перезапускаем процесс через RestartActivity (:restart), чтобы TachyonCore загрузил новый .so с нуля
                    window.decorView.postDelayed({
                        runCatching { stopService(Intent(this, TachyonVpnService::class.java)) }
                        org.tachyon.vpn.RestartActivity.triggerRebirth(this)
                    }, 300)
                }
            } catch (e: Throwable) {
                runOnUiThread { result.success("requires_apk") }
            }
        }, "tachyon-install-so").start()
    }

    /** Запускает системный установщик пакетов Android для обновления APK. */
    private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
        val fileName = call.argument<String>("fileName") ?: "tachyon-update.apk"
        try {
            val apkFile = File(File(filesDir, "update"), fileName)
            if (!apkFile.exists()) {
                result.success("error: APK не найден (${apkFile.absolutePath})")
                return
            }
            if (!packageManager.canRequestPackageInstalls()) {
                val permIntent = Intent(
                    android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    android.net.Uri.parse("package:$packageName"),
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(permIntent)
            }
            val uri = android.net.Uri.parse("content://${org.tachyon.vpn.ApkFileProvider.AUTHORITY}/$fileName")
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                putExtra(Intent.EXTRA_NOT_UNKNOWN_SOURCE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(installIntent)
            result.success("ok")
        } catch (e: Throwable) {
            result.success("error: ${e.message}")
        }
    }

    /** Список установленных приложений — для правил по пакетам. */
    private fun handleApps(result: MethodChannel.Result) {
        val manager = packageManager
        @Suppress("DEPRECATION")
        val packages = manager.getInstalledPackages(0)
        val ownPackage = packageName
        val apps = packages
            .filter { it.packageName != ownPackage }
            .mapNotNull { info ->
                // У части пакетов информации о приложении нет.
                val application = info.applicationInfo ?: return@mapNotNull null
                mapOf(
                    "package" to info.packageName,
                    "label" to runCatching {
                        manager.getApplicationLabel(application).toString()
                    }.getOrDefault(info.packageName),
                    "system" to ((application.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedBy { (it["label"] as String).lowercase() }
        result.success(apps)
    }

    /** Запускает сервис с готовой конфигурацией. */
    private fun startTunnel(
        config: String,
        allowedApps: List<String>,
        disallowedApps: List<String>,
        serverName: String,
        mtu: Int,
        proxyOnly: Boolean = false,
    ) {
        val intent = Intent(this, TachyonVpnService::class.java).apply {
            action = TachyonVpnService.ACTION_START
            putExtra(TachyonVpnService.EXTRA_CONFIG, config)
            putExtra(TachyonVpnService.EXTRA_SERVER_NAME, serverName)
            putExtra(TachyonVpnService.EXTRA_MTU, mtu)
            putExtra(TachyonVpnService.EXTRA_PROXY_ONLY, proxyOnly)
            putStringArrayListExtra(
                TachyonVpnService.EXTRA_ALLOWED_PACKAGES,
                ArrayList(allowedApps),
            )
            putStringArrayListExtra(
                TachyonVpnService.EXTRA_DISALLOWED_PACKAGES,
                ArrayList(disallowedApps),
            )
        }
        TunnelStateHolder.serverName = serverName
        TunnelStateHolder.update(TunnelStateHolder.State.Starting, null)
        startForegroundService(intent)
    }

    /** Отложенный запуск: ждём разрешения VPN от системы. */
    private class PendingStart(
        val config: String,
        val allowedApps: List<String>,
        val disallowedApps: List<String>,
        val serverName: String,
        val mtu: Int,
        val proxyOnly: Boolean,
        val result: MethodChannel.Result,
    )

    /** Экранирует текст ошибки для вставки в JSON. */
    private fun escape(value: String?): String =
        (value ?: "ошибка").replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ")

    companion object {
        private const val CHANNEL_VPN = "app.tachyon.proxy/vpn"
        private const val CHANNEL_EVENTS = "app.tachyon.proxy/events"
        private const val REQUEST_VPN_PERMISSION = 4711
        private const val LOG_FILE_NAME = "tachyon.log"
    }
}
