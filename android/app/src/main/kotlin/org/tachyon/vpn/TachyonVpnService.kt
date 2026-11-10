package org.tachyon.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import app.tachyon.tachyon_proxy.MainActivity
import app.tachyon.tachyon_proxy.R
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * VPN-сервис: держит TUN-интерфейс и запускает в нём ядро `tachyon-core`.
 *
 * Поддерживает фоновый режим «Домашний интернет» (авто-пауза маршрутизации
 * при подключении к доверенным Wi-Fi сетям из списка и автоматическое
 * включение туннеля при выходе из домашней сети).
 */
class TachyonVpnService : VpnService() {

    private var coreThread: Thread? = null
    private var protectThread: Thread? = null
    private var statsThread: Thread? = null
    private var wifiWatchThread: Thread? = null

    /** Дескриптор TUN: должен жить дольше, чем ядро читает из него. */
    private var tunDescriptor: ParcelFileDescriptor? = null

    /** Конфигурация текущего запуска: нужна для перезапуска ядра и возврата из авто-паузы Wi-Fi. */
    private var currentConfig: String? = null
    private var currentServerName: String = ""
    private var currentAllowedPackages: List<String> = emptyList()
    private var currentDisallowedPackages: List<String> = emptyList()
    private var currentMtu: Int = MTU
    private var currentProxyOnly: Boolean = false

    /** Путь к сокету защиты и к файлу журнала. */
    private var protectPath: String? = null
    private var logPath: String? = null

    /** Следит за сетью. */
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var activeNetworkHandle: Long? = null

    @Volatile
    private var underlyingNetwork: Network? = null

    private val mainHandler = Handler(Looper.getMainLooper())

    private val restarting = AtomicBoolean(false)

    @Volatile
    private var running = false

    /** Флаг активности фонового наблюдателя Wi-Fi (живёт всё время, пока сервис не остановлен пользователем). */
    @Volatile
    private var watcherActive = false

    /** Сервис находится в режиме авто-паузы в домашней Wi-Fi сети. */
    @Volatile
    private var pausedByWifi = false

    /** Если пользователь нажал «Включить принудительно» в домашней сети, игнорируем авто-паузу для этого SSID до отключения от него. */
    @Volatile
    private var forceOverrideWifiSsid: String = ""

    /** Последовательный фоновый исполнитель для запуска и остановки ядра без блокировки главного потока Android. */
    private val lifecycleExecutor = java.util.concurrent.Executors.newSingleThreadExecutor { r ->
        Thread(r, "tachyon-vpn-ctl").apply { isDaemon = true }
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        WifiSsidHelper.ensureRegistered(applicationContext)
        WifiSsidHelper.setOnWifiEventListener {
            if (watcherActive || running || pausedByWifi) {
                lifecycleExecutor.execute { runCatching { evaluateHomeWifiState() } }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                forceOverrideWifiSsid = ""
                pausedByWifi = false
                stopWifiWatcher()
                TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null, pausedWifi = "")
                lifecycleExecutor.execute {
                    stopTunnel()
                    stopSelf()
                }
                return START_NOT_STICKY
            }
            ACTION_NEXT_SERVER -> {
                TunnelStateHolder.dispatchCommand("next_server")
                return START_STICKY
            }
            ACTION_RECHECK_WIFI -> {
                if (watcherActive || running || pausedByWifi) {
                    lifecycleExecutor.execute { runCatching { evaluateHomeWifiState() } }
                    return START_STICKY
                } else {
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            ACTION_FORCE_RESUME -> {
                val ssid = WifiSsidHelper.getCurrentWifiSsid(this)
                    .ifEmpty { TunnelStateHolder.pausedByWifiSsid }
                forceOverrideWifiSsid = ssid
                if (pausedByWifi) {
                    lifecycleExecutor.execute { resumeFromHomeWifi() }
                }
                return START_STICKY
            }
            else -> {
                var config = intent?.getStringExtra(EXTRA_CONFIG)
                var allowedPackages =
                    intent?.getStringArrayListExtra(EXTRA_ALLOWED_PACKAGES).orEmpty()
                var disallowedPackages =
                    intent?.getStringArrayListExtra(EXTRA_DISALLOWED_PACKAGES).orEmpty()
                var serverName = intent?.getStringExtra(EXTRA_SERVER_NAME).orEmpty()
                var mtu = intent?.getIntExtra(EXTRA_MTU, MTU) ?: MTU
                var proxyOnly = intent?.getBooleanExtra(EXTRA_PROXY_ONLY, false) ?: false
                val forceStart = intent?.getBooleanExtra(EXTRA_FORCE_START, false) ?: false

                if (config.isNullOrBlank()) {
                    val savedFile = File(filesDir, LAST_SESSION_FILE)
                    if (savedFile.exists()) {
                        runCatching {
                            val obj = JSONObject(savedFile.readText())
                            config = obj.optString("config")
                            serverName = obj.optString("serverName")
                            mtu = obj.optInt("mtu", MTU)
                            proxyOnly = obj.optBoolean("proxyOnly", false)
                            allowedPackages = jsonArrayToList(obj.optJSONArray("allowed"))
                            disallowedPackages = jsonArrayToList(obj.optJSONArray("disallowed"))
                        }
                    }
                }

                if (config.isNullOrBlank()) {
                    Log.e(TAG, "конфигурация не передана")
                    TunnelStateHolder.update(
                        TunnelStateHolder.State.Failed,
                        "конфигурация не передана",
                        pausedWifi = "",
                    )
                    stopSelf()
                    return START_NOT_STICKY
                }

                val resolvedConfig = config!!
                val resolvedAllowed = allowedPackages
                val resolvedDisallowed = disallowedPackages
                val resolvedServerName = serverName
                val resolvedMtu = mtu
                val resolvedProxyOnly = proxyOnly

                currentConfig = resolvedConfig
                currentServerName = resolvedServerName
                currentAllowedPackages = resolvedAllowed
                currentDisallowedPackages = resolvedDisallowed
                currentMtu = resolvedMtu
                currentProxyOnly = resolvedProxyOnly

                // Сразу переводим сервис в foreground в главном потоке, чтобы избежать ForegroundServiceDidNotStartInTimeException.
                startVpnForeground(buildNotification())

                lifecycleExecutor.execute {
                    saveSessionToDisk(
                        resolvedConfig,
                        resolvedAllowed,
                        resolvedDisallowed,
                        resolvedServerName,
                        resolvedMtu,
                        resolvedProxyOnly,
                    )

                    val currentSsid = WifiSsidHelper.getCurrentWifiSsid(this)
                    if (forceStart && currentSsid.isNotEmpty()) {
                        forceOverrideWifiSsid = currentSsid
                    }

                    val (homeWifiMode, trustedSsids) = WifiSsidHelper.readHomeWifiConfig(filesDir)
                    val shouldPauseNow = homeWifiMode &&
                        currentSsid.isNotEmpty() &&
                        WifiSsidHelper.matchesTrustedWifi(currentSsid, trustedSsids) &&
                        !currentSsid.equals(forceOverrideWifiSsid, ignoreCase = true)

                    if (running) {
                        stopCoreAndTunOnly()
                    }

                    if (shouldPauseNow) {
                        enterHomeWifiPause(currentSsid)
                        startWifiWatcher()
                    } else {
                        pausedByWifi = false
                        TunnelStateHolder.pausedByWifiSsid = ""
                        startTunnel(
                            resolvedConfig,
                            resolvedAllowed,
                            resolvedDisallowed,
                            resolvedServerName,
                            resolvedMtu,
                            resolvedProxyOnly,
                        )
                        startWifiWatcher()
                    }
                }
            }
        }
        return START_STICKY
    }

    private fun saveSessionToDisk(
        config: String,
        allowedPackages: List<String>,
        disallowedPackages: List<String>,
        serverName: String,
        mtu: Int,
        proxyOnly: Boolean,
    ) {
        runCatching {
            val sessionJson = JSONObject().apply {
                put("config", config)
                put("serverName", serverName)
                put("mtu", mtu)
                put("proxyOnly", proxyOnly)
                put("allowed", JSONArray(allowedPackages))
                put("disallowed", JSONArray(disallowedPackages))
            }
            File(filesDir, LAST_SESSION_FILE).writeText(sessionJson.toString())
        }
    }

    private fun jsonArrayToList(arr: JSONArray?): List<String> {
        if (arr == null) return emptyList()
        val list = ArrayList<String>(arr.length())
        for (i in 0 until arr.length()) {
            val s = arr.optString(i)
            if (s.isNotEmpty()) list.add(s)
        }
        return list
    }

    private fun startVpnForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val types = if (WifiSsidHelper.hasLocationPermission(this)) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE or
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            } else {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            try {
                startForeground(NOTIFICATION_ID, notification, types)
                return
            } catch (_: Throwable) {
                runCatching {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
                    )
                }
                return
            }
        }
        startForeground(NOTIFICATION_ID, notification)
    }

    /**
     * Переводит сервис в режим ожидания домашней Wi-Fi сети:
     * закрывает TUN и останавливает ядро, но оставляет фоновый наблюдатель.
     */
    private fun enterHomeWifiPause(ssid: String) {
        stopCoreAndTunOnly()
        pausedByWifi = true
        TunnelStateHolder.serverName = currentServerName
        TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null, pausedWifi = ssid)
        startVpnForeground(buildHomeWifiStandbyNotification(ssid))
        runCatching { TachyonAppWidget.updateAll(this, "🏠 Пауза в Wi-Fi: $ssid") }
    }

    /**
     * Автоматически поднимает туннель после выхода из доверенной домашней Wi-Fi сети.
     */
    private fun resumeFromHomeWifi() {
        val cfg = currentConfig ?: return
        pausedByWifi = false
        TunnelStateHolder.pausedByWifiSsid = ""
        startTunnel(
            cfg,
            currentAllowedPackages,
            currentDisallowedPackages,
            currentServerName,
            currentMtu,
            currentProxyOnly,
        )
        startWifiWatcher()
    }

    /**
     * Фоновый наблюдатель за текущим SSID Wi-Fi и настройками «Домашнего интернета».
     */
    private fun startWifiWatcher() {
        watcherActive = true
        WifiSsidHelper.ensureRegistered(applicationContext)
        watchNetwork()
        if (wifiWatchThread?.isAlive == true) return
        wifiWatchThread = Thread({
            while (watcherActive && !Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(1500)
                } catch (_: InterruptedException) {
                    break
                }
                if (!watcherActive) break
                runCatching { evaluateHomeWifiState() }
            }
        }, "tachyon-wifi-watch").apply {
            isDaemon = true
            start()
        }
    }

    private fun stopWifiWatcher() {
        watcherActive = false
        wifiWatchThread?.interrupt()
        wifiWatchThread = null
        networkCallback?.let { callback ->
            val manager = getSystemService(ConnectivityManager::class.java)
            runCatching { manager?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        activeNetworkHandle = null
    }

    @Synchronized
    private fun evaluateHomeWifiState() {
        if (!watcherActive && !running && !pausedByWifi) return
        val (homeWifiMode, trustedSsids) = WifiSsidHelper.readHomeWifiConfig(filesDir)
        val currentSsid = WifiSsidHelper.getCurrentWifiSsid(this)

        if (forceOverrideWifiSsid.isNotEmpty() &&
            !currentSsid.equals(forceOverrideWifiSsid, ignoreCase = true)
        ) {
            forceOverrideWifiSsid = ""
        }

        val shouldPause = homeWifiMode &&
            currentSsid.isNotEmpty() &&
            WifiSsidHelper.matchesTrustedWifi(currentSsid, trustedSsids) &&
            !currentSsid.equals(forceOverrideWifiSsid, ignoreCase = true)

        if (shouldPause) {
            if (running || !pausedByWifi) {
                Log.i(TAG, "Домашний Wi-Fi '$currentSsid' обнаружен — ставим маршрутизацию на авто-паузу")
                enterHomeWifiPause(currentSsid)
            } else if (pausedByWifi && TunnelStateHolder.pausedByWifiSsid != currentSsid) {
                TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null, pausedWifi = currentSsid)
                val manager = getSystemService(NotificationManager::class.java)
                manager?.notify(NOTIFICATION_ID, buildHomeWifiStandbyNotification(currentSsid))
            }
        } else if (pausedByWifi) {
            Log.i(TAG, "Выход из домашнего Wi-Fi — автоматически включаем маршрутизацию")
            resumeFromHomeWifi()
        }
    }

    /**
     * Поднимает туннель.
     */
    private fun startTunnel(
        config: String,
        allowedPackages: List<String>,
        disallowedPackages: List<String>,
        serverName: String = "",
        mtu: Int = MTU,
        proxyOnly: Boolean = false,
    ) {
        if (running) return

        currentServerName = serverName
        TunnelStateHolder.serverName = serverName
        TunnelStateHolder.update(TunnelStateHolder.State.Starting, null, pausedWifi = "")
        runCatching { TachyonAppWidget.updateAll(this) }

        saveSessionToDisk(config, allowedPackages, disallowedPackages, serverName, mtu, proxyOnly)

        // Уведомление поднимается сразу: после startForegroundService система
        // даёт несколько секунд на foreground-состояние.
        startVpnForeground(buildNotification())
        currentConfig = config

        val coreTunFd: Int
        val activeProtectPath: String

        if (proxyOnly) {
            coreTunFd = -1
            activeProtectPath = ""
        } else {
            val builder = Builder()
                .setMtu(mtu.coerceIn(1280, 9000))
                .addAddress(TUN_ADDRESS, TUN_PREFIX)
                .addDnsServer(DNS_SERVER)
                .addRoute("0.0.0.0", 0)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            val cm = getSystemService(ConnectivityManager::class.java)
            val physNet = if (cm != null) resolvePhysicalNetwork(cm) else null
            if (physNet != null) {
                underlyingNetwork = physNet
                activeNetworkHandle = physNet.networkHandle
                runCatching { builder.setUnderlyingNetworks(arrayOf(physNet)) }
            }

            if (allowedPackages.isNotEmpty()) {
                allowedPackages.filter { it != packageName }.forEach { name ->
                    runCatching { builder.addAllowedApplication(name) }
                        .onFailure { Log.w(TAG, "не удалось разрешить пакет $name", it) }
                }
            } else {
                runCatching { builder.addDisallowedApplication(packageName) }
                disallowedPackages.forEach { name ->
                    runCatching { builder.addDisallowedApplication(name) }
                        .onFailure { Log.w(TAG, "не удалось исключить пакет $name", it) }
                }
            }

            val descriptor = runCatching { builder.establish() }.getOrNull()
            if (descriptor == null) {
                Log.e(TAG, "establish() не выдал дескриптор TUN")
                TunnelStateHolder.update(
                    TunnelStateHolder.State.Failed,
                    "система не выдала интерфейс VPN",
                    pausedWifi = "",
                )
                runCatching { TachyonAppWidget.updateAll(this) }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            tunDescriptor = descriptor
            if (physNet != null) {
                runCatching { setUnderlyingNetworks(arrayOf(physNet)) }
            } else {
                runCatching { setUnderlyingNetworks(null) }
            }

            val detachedFd = detachTunFd(descriptor)
            if (detachedFd == null) {
                TunnelStateHolder.update(
                    TunnelStateHolder.State.Failed,
                    "не удалось подготовить дескриптор TUN",
                    pausedWifi = "",
                )
                runCatching { TachyonAppWidget.updateAll(this) }
                closeTun()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            coreTunFd = detachedFd

            val protectSocket = File(filesDir, PROTECT_SOCKET_NAME)
            protectSocket.delete()
            val opened = TachyonCore.protectOpen(protectSocket.absolutePath)
            if (opened != 0) {
                Log.e(TAG, "protectOpen вернул $opened: ${TachyonCore.lastError()}")
                runCatching { ParcelFileDescriptor.adoptFd(coreTunFd).close() }
                TunnelStateHolder.update(
                    TunnelStateHolder.State.Failed,
                    "не удалось открыть канал защиты сокетов",
                    pausedWifi = "",
                )
                runCatching { TachyonAppWidget.updateAll(this) }
                closeTun()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            activeProtectPath = protectSocket.absolutePath

            protectThread = Thread({
                try {
                    TachyonCore.protectLoop(this)
                } catch (error: Throwable) {
                    Log.e(TAG, "protectLoop прерван", error)
                }
            }, "tachyon-protect").apply {
                isDaemon = true
                start()
            }
        }

        val logFile = File(filesDir, LOG_FILE_NAME)
        runCatching { logFile.writeText("") }
        protectPath = activeProtectPath
        logPath = logFile.absolutePath
        Log.i(TAG, "CONFIG: $config")

        running = true
        pausedByWifi = false
        coreThread = Thread({
            val code = TachyonCore.start(
                config,
                coreTunFd,
                activeProtectPath,
                logFile.absolutePath,
            )
            if (code != 0) {
                running = false
                val error = TachyonCore.lastError() ?: "ядро не стартовало (код $code)"
                Log.e(TAG, error)
                TunnelStateHolder.update(TunnelStateHolder.State.Failed, error, pausedWifi = "")
                runCatching { TachyonAppWidget.updateAll(this) }
                stopSelf()
            } else {
                running = true
                pausedByWifi = false
                TunnelStateHolder.update(TunnelStateHolder.State.Running, null, pausedWifi = "")
                runCatching { TachyonAppWidget.updateAll(this) }
                startStatsLoop()
            }
        }, "tachyon-core").apply {
            isDaemon = true
            start()
        }
    }

    /** Фоновый поток обновления живой статистики в уведомлении раз в 2 секунды. */
    private fun startStatsLoop() {
        statsThread?.interrupt()
        statsThread = Thread({
            var prevUp = 0L
            var prevDown = 0L
            var prevAt = System.currentTimeMillis()
            val manager = getSystemService(NotificationManager::class.java)
            while (running && !Thread.currentThread().isInterrupted) {
                try {
                    Thread.sleep(2000)
                } catch (_: InterruptedException) {
                    break
                }
                if (!running) break
                runCatching {
                    val raw = TachyonCore.stats()
                    TunnelStateHolder.updateStats(raw)
                    val obj = JSONObject(raw)
                    val up = obj.optLong("up", 0L)
                    val down = obj.optLong("down", 0L)
                    val conns = obj.optInt("connections", 0)
                    val now = System.currentTimeMillis()
                    val elapsedSec = ((now - prevAt) / 1000.0).coerceAtLeast(0.5)
                    val upRate = ((up - prevUp).coerceAtLeast(0L) / elapsedSec).toLong()
                    val downRate = ((down - prevDown).coerceAtLeast(0L) / elapsedSec).toLong()
                    prevUp = up
                    prevDown = down
                    prevAt = now
                    val line = "↑ ${formatBytes(upRate)}/с · ↓ ${formatBytes(downRate)}/с  |  ↑ ${formatBytes(up)} ↓ ${formatBytes(down)} ($conns)"
                    manager?.notify(NOTIFICATION_ID, buildNotification(line))
                    runCatching { TachyonAppWidget.updateAll(this@TachyonVpnService, "↑ ${formatBytes(upRate)}/с · ↓ ${formatBytes(downRate)}/с") }
                }
            }
        }, "tachyon-notif-stats").apply {
            isDaemon = true
            start()
        }
    }

    private fun formatBytes(bytes: Long): String = when {
        bytes < 1024L -> "$bytes Б"
        bytes < 1024L * 1024L -> String.format("%.1f КБ", bytes / 1024.0)
        bytes < 1024L * 1024L * 1024L -> String.format("%.1f МБ", bytes / (1024.0 * 1024.0))
        else -> String.format("%.2f ГБ", bytes / (1024.0 * 1024.0 * 1024.0))
    }

    private fun detachTunFd(descriptor: ParcelFileDescriptor): Int? =
        runCatching { ParcelFileDescriptor.dup(descriptor.fileDescriptor).detachFd() }
            .onFailure { Log.e(TAG, "не удалось клонировать дескриптор TUN", it) }
            .getOrNull()

    /**
     * Находит активную физическую сеть (Wi-Fi / Ethernet / Cellular), строго исключая
     * виртуальный интерфейс самого VPN (`TRANSPORT_VPN`), чтобы `ConnectivityService`
     * и `SystemUI` сохраняли индикацию Wi-Fi в статус-баре Android.
     */
    @Suppress("DEPRECATION")
    private fun resolvePhysicalNetwork(
        manager: ConnectivityManager,
        exclude: Network? = null,
    ): Network? {
        underlyingNetwork?.let { cached ->
            if (cached != exclude) {
                val caps = runCatching { manager.getNetworkCapabilities(cached) }.getOrNull()
                if (caps != null &&
                    !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                    (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                        caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                ) {
                    return cached
                }
            }
        }
        var cellularFallback: Network? = null
        runCatching {
            for (net in manager.allNetworks) {
                if (net == exclude) continue
                val caps = manager.getNetworkCapabilities(net) ?: continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
                ) {
                    return net
                }
                if (cellularFallback == null &&
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                ) {
                    cellularFallback = net
                }
            }
        }
        return cellularFallback
    }

    /**
     * Следит за физической сетью (`NET_CAPABILITY_NOT_VPN`), обновляет `underlyingNetworks`
     * и мгновенно проверяет условие «Домашний интернет» и переключение списков при смене Wi-Fi / LTE.
     */
    private fun watchNetwork() {
        if (networkCallback != null) return
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .build()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val caps = runCatching { manager.getNetworkCapabilities(network) }.getOrNull()
                if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                val prevHandle = activeNetworkHandle
                underlyingNetwork = network
                activeNetworkHandle = network.networkHandle
                if (running) {
                    runCatching { setUnderlyingNetworks(arrayOf(network)) }
                    if (prevHandle != network.networkHandle) {
                        TunnelStateHolder.dispatchCommand("network_restored")
                    }
                }
                TunnelStateHolder.dispatchCommand("network_changed")
                lifecycleExecutor.execute { runCatching { evaluateHomeWifiState() } }
            }

            override fun onCapabilitiesChanged(
                network: Network,
                networkCapabilities: NetworkCapabilities,
            ) {
                if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                underlyingNetwork = network
                activeNetworkHandle = network.networkHandle
                if (running) {
                    runCatching { setUnderlyingNetworks(arrayOf(network)) }
                }
                TunnelStateHolder.dispatchCommand("network_changed")
                lifecycleExecutor.execute { runCatching { evaluateHomeWifiState() } }
            }

            override fun onLost(network: Network) {
                if (activeNetworkHandle == network.networkHandle) {
                    val nextPhys = resolvePhysicalNetwork(manager, exclude = network)
                    underlyingNetwork = nextPhys
                    activeNetworkHandle = nextPhys?.networkHandle
                    if (running) {
                        runCatching {
                            setUnderlyingNetworks(if (nextPhys != null) arrayOf(nextPhys) else null)
                        }
                    }
                }
                TunnelStateHolder.dispatchCommand("network_changed")
                lifecycleExecutor.execute { runCatching { evaluateHomeWifiState() } }
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                manager.registerBestMatchingNetworkCallback(request, callback, mainHandler)
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                manager.requestNetwork(request, callback, mainHandler)
            } else {
                manager.registerNetworkCallback(request, callback)
            }
            networkCallback = callback
        } catch (error: Throwable) {
            runCatching {
                manager.registerNetworkCallback(request, callback)
                networkCallback = callback
            }.onFailure {
                Log.w(TAG, "не удалось следить за сетью", it)
            }
        }
    }

    @androidx.annotation.Keep
    fun protectFd(fd: Int): Boolean {
        return try {
            protect(fd)
        } catch (error: Throwable) {
            Log.e(TAG, "protect($fd) не удался", error)
            false
        }
    }

    /** Останавливает только ядро и закрывает TUN, не завершая сам сервис. */
    private fun stopCoreAndTunOnly() {
        running = false
        statsThread?.interrupt()
        statsThread = null

        runCatching { coreThread?.join(2000) }
        coreThread = null

        runCatching { TachyonCore.stop() }
            .onFailure { Log.e(TAG, "остановка ядра не удалась", it) }
        runCatching { TachyonCore.protectClose() }

        protectThread?.interrupt()
        runCatching { protectThread?.join(300) }
        protectThread = null

        closeTun()
    }

    /** Полностью останавливает туннель, фоновый наблюдатель и освобождает ресурсы. */
    fun stopTunnel() {
        pausedByWifi = false
        stopWifiWatcher()
        if (!running && coreThread == null) {
            closeTun()
            TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null, pausedWifi = "")
            runCatching { TachyonAppWidget.updateAll(this) }
            stopForeground(STOP_FOREGROUND_REMOVE)
            return
        }
        stopCoreAndTunOnly()
        currentConfig = null
        TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null, pausedWifi = "")
        runCatching { TachyonAppWidget.updateAll(this) }
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        pausedByWifi = false
        stopWifiWatcher()
        lifecycleExecutor.execute { stopTunnel() }
        super.onDestroy()
    }

    override fun onRevoke() {
        pausedByWifi = false
        stopWifiWatcher()
        lifecycleExecutor.execute {
            stopTunnel()
            stopSelf()
        }
        super.onRevoke()
    }

    private fun closeTun() {
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.notification_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildHomeWifiStandbyNotification(ssid: String): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, TachyonVpnService::class.java).setAction(ACTION_STOP)
        val stopPending = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val forceIntent = Intent(this, TachyonVpnService::class.java).setAction(ACTION_FORCE_RESUME)
        val forcePending = PendingIntent.getService(
            this,
            3,
            forceIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val forceAction = Notification.Action.Builder(
            android.R.drawable.ic_media_play,
            "Включить сейчас",
            forcePending,
        ).build()

        val stopAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Отключить",
            stopPending,
        ).build()

        return builder
            .setContentTitle("🏠 Домашний интернет · $ssid")
            .setContentText("Маршрутизация на паузе в домашней сети · Включится вне Wi-Fi")
            .setSmallIcon(R.drawable.ic_tachyon_bolt)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPending)
            .addAction(forceAction)
            .addAction(stopAction)
            .build()
    }

    private fun buildNotification(statsLine: String? = null): Notification {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val openPending = PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val stopIntent = Intent(this, TachyonVpnService::class.java).setAction(ACTION_STOP)
        val stopPending = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val nextIntent = Intent(this, TachyonVpnService::class.java).setAction(ACTION_NEXT_SERVER)
        val nextPending = PendingIntent.getService(
            this,
            2,
            nextIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        val title = if (currentServerName.isNotEmpty()) {
            "⚡ Tachyon · $currentServerName"
        } else {
            "⚡ ${getString(R.string.notification_title)}"
        }

        val stopAction = Notification.Action.Builder(
            android.R.drawable.ic_menu_close_clear_cancel,
            "Отключить",
            stopPending,
        ).build()

        val nextAction = Notification.Action.Builder(
            android.R.drawable.ic_media_next,
            "След. сервер",
            nextPending,
        ).build()

        return builder
            .setContentTitle(title)
            .setContentText(statsLine ?: getString(R.string.notification_text))
            .setSmallIcon(R.drawable.ic_tachyon_bolt)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openPending)
            .addAction(stopAction)
            .addAction(nextAction)
            .build()
    }

    companion object {
        private const val TAG = "TachyonVpnService"
        private const val CHANNEL_ID = "tachyon_vpn"
        private const val NOTIFICATION_ID = 4711
        private const val MTU = 1400
        private const val TUN_ADDRESS = "172.19.0.1"
        private const val TUN_PREFIX = 30
        private const val DNS_SERVER = "1.1.1.1"
        private const val PROTECT_SOCKET_NAME = "tachyon-protect.sock"
        private const val LOG_FILE_NAME = "tachyon.log"
        const val LAST_SESSION_FILE = "last-session.json"

        const val ACTION_START = "app.tachyon.proxy.START"
        const val ACTION_STOP = "app.tachyon.proxy.STOP"
        const val ACTION_NEXT_SERVER = "app.tachyon.proxy.NEXT_SERVER"
        const val ACTION_RECHECK_WIFI = "app.tachyon.proxy.RECHECK_WIFI"
        const val ACTION_FORCE_RESUME = "app.tachyon.proxy.FORCE_RESUME"

        const val EXTRA_CONFIG = "config"
        const val EXTRA_SERVER_NAME = "server_name"
        const val EXTRA_MTU = "mtu"
        const val EXTRA_PROXY_ONLY = "proxy_only"
        const val EXTRA_FORCE_START = "force_start"
        const val EXTRA_ALLOWED_PACKAGES = "allowed_packages"
        const val EXTRA_DISALLOWED_PACKAGES = "disallowed_packages"

        /** Создаёт Intent для запуска сервиса с готовой конфигурацией. */
        fun startIntent(context: android.content.Context, config: String): Intent =
            Intent(context, TachyonVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, config)
            }
    }
}
