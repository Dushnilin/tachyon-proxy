package org.tachyon.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
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
 * Жизненный цикл:
 *  1. [establish] выдаёт дескриптор TUN, который передаётся ядру как
 *     нестандартное поле `fd` в tun-инбаунде. Ядро не создаёт интерфейс
 *     самостоятельно и не трогает маршруты — их настраивает система.
 *  2. До старта ядра поднимается unix-сокет защиты: каждый сокет, который
 *     ядро открывает наружу, передаётся сюда и защищается через
 *     [VpnService.protect], иначе трафик попадал бы в туннель рекурсивно.
 *  3. Ядро стартует в отдельном потоке: вызов блокирующий и держит сервис
 *     живым всё время работы туннеля.
 */
class TachyonVpnService : VpnService() {

    private var coreThread: Thread? = null
    private var protectThread: Thread? = null
    private var statsThread: Thread? = null

    /** Дескриптор TUN: должен жить дольше, чем ядро читает из него. */
    private var tunDescriptor: ParcelFileDescriptor? = null

    /** Конфигурация текущего запуска: нужна для перезапуска ядра. */
    private var currentConfig: String? = null
    private var currentServerName: String = ""

    /** Путь к сокету защиты и к файлу журнала. */
    private var protectPath: String? = null
    private var logPath: String? = null

    /** Следит за сетью: при смене ядро перезапускается. */
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    @Volatile
    private var activeNetworkHandle: Long? = null

    private val restarting = AtomicBoolean(false)

    @Volatile
    private var running = false

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopTunnel()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_NEXT_SERVER -> {
                TunnelStateHolder.dispatchCommand("next_server")
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
                    )
                    stopSelf()
                    return START_NOT_STICKY
                }
                // Повторный запуск: прошлая конфигурация снимается целиком.
                if (running) {
                    stopTunnel()
                }
                startTunnel(config!!, allowedPackages, disallowedPackages, serverName, mtu, proxyOnly)
            }
        }
        return START_STICKY
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
        TunnelStateHolder.update(TunnelStateHolder.State.Starting, null)
        runCatching { TachyonAppWidget.updateAll(this) }

        // Сохраняем последнюю сессию для запуска из Quick Settings Tile и при загрузке системы.
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

        // Уведомление поднимается сразу: после startForegroundService система
        // даёт несколько секунд на foreground-состояние.
        startForeground(NOTIFICATION_ID, buildNotification())
        currentConfig = config

        val coreTunFd: Int
        val activeProtectPath: String

        if (proxyOnly) {
            coreTunFd = -1
            activeProtectPath = ""
        } else {
            // `Builder` - внутренний класс VpnService: создаётся на этом сервисе.
            // `setSession` в API 36 удалён, поэтому имя сессии не задаём.
            val builder = Builder()
                .setMtu(mtu.coerceIn(1280, 9000))
                .addAddress(TUN_ADDRESS, TUN_PREFIX)
                .addDnsServer(DNS_SERVER)
                .addRoute("0.0.0.0", 0)

            if (allowedPackages.isNotEmpty()) {
                // В туннель попадают только перечисленные приложения (кроме самого VPN-клиента).
                allowedPackages.filter { it != packageName }.forEach { name ->
                    runCatching { builder.addAllowedApplication(name) }
                        .onFailure { Log.w(TAG, "не удалось разрешить пакет $name", it) }
                }
            } else {
                // Само приложение всегда исключается: иначе управляющий канал и
                // журнал ушли бы в туннель.
                runCatching { builder.addDisallowedApplication(packageName) }
                // Перечисленные приложения идут мимо туннеля.
                disallowedPackages.forEach { name ->
                    runCatching { builder.addDisallowedApplication(name) }
                        .onFailure { Log.w(TAG, "не удалось исключить пакет $name", it) }
                }
            }

            // `Builder.establish()` сам поднимает интерфейс и отдаёт null,
            // если система отказала (API 14+, доступен на всех наших версиях).
            val descriptor = runCatching { builder.establish() }.getOrNull()
            if (descriptor == null) {
                Log.e(TAG, "establish() не выдал дескриптор TUN")
                TunnelStateHolder.update(
                    TunnelStateHolder.State.Failed,
                    "система не выдала интерфейс VPN",
                )
                runCatching { TachyonAppWidget.updateAll(this) }
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            tunDescriptor = descriptor

            // Нативный `Tun` закрывает свой `fd` в `Drop` через `libc::close`.
            // Передача `descriptor.fd` напрямую вызывает SIGABRT от Android `fdsan`,
            // так как им владеет `ParcelFileDescriptor`. Дублируем и отвязываем (`detachFd`).
            val detachedFd = detachTunFd(descriptor)
            if (detachedFd == null) {
                TunnelStateHolder.update(
                    TunnelStateHolder.State.Failed,
                    "не удалось подготовить дескриптор TUN",
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
                )
                runCatching { TachyonAppWidget.updateAll(this) }
                closeTun()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return
            }
            activeProtectPath = protectSocket.absolutePath

            // Слушатель сокета защиты живёт весь сеанс: пока он работает, ядро
            // может передавать сокеты на protect().
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

        coreThread = Thread({
            val code = TachyonCore.start(
                config,
                coreTunFd,
                activeProtectPath,
                logFile.absolutePath,
            )
            if (code != 0) {
                val error = TachyonCore.lastError() ?: "ядро не стартовало (код $code)"
                Log.e(TAG, error)
                TunnelStateHolder.update(TunnelStateHolder.State.Failed, error)
                runCatching { TachyonAppWidget.updateAll(this) }
                stopSelf()
            } else {
                running = true
                TunnelStateHolder.update(TunnelStateHolder.State.Running, null)
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

    /**
     * Создаёт дубликат дескриптора TUN и снимает с него `fdsan`-владение
     * `ParcelFileDescriptor`, чтобы нативное ядро могло закрыть его в `Drop`.
     */
    private fun detachTunFd(descriptor: ParcelFileDescriptor): Int? =
        runCatching { ParcelFileDescriptor.dup(descriptor.fileDescriptor).detachFd() }
            .onFailure { Log.e(TAG, "не удалось клонировать дескриптор TUN", it) }
            .getOrNull()

    /**
     * Следит за системной сетью по умолчанию и обновляет underlying network
     * для VpnService без перезапуска ядра (защищённые через protect(fd) сокеты
     * автоматически маршрутизируются системой через активную сеть).
     */
    private fun watchNetwork() {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return
        activeNetworkHandle = null
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                activeNetworkHandle = network.networkHandle
                runCatching { setUnderlyingNetworks(arrayOf(network)) }
            }

            override fun onLost(network: Network) {
                if (activeNetworkHandle == network.networkHandle) {
                    activeNetworkHandle = null
                    runCatching { setUnderlyingNetworks(null) }
                }
            }
        }
        try {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        } catch (error: Throwable) {
            Log.w(TAG, "не удалось следить за сетью", error)
        }
    }

    /** Перезапускает ядро с той же конфигурацией. */
    private fun restartCore() {
        val config = currentConfig ?: return
        val descriptor = tunDescriptor ?: return
        val protect = protectPath ?: return
        val log = logPath ?: return
        if (!running) return
        if (!restarting.compareAndSet(false, true)) return

        Log.i(TAG, "сеть изменилась, ядро перезапускается")
        Thread({
            try {
                // Ядро держит один инстанс: сначала глушим, потом поднимаем с новым dup-fd.
                runCatching { TachyonCore.stop() }
                    .onFailure { Log.e(TAG, "остановка ядра не удалась", it) }
                Thread.sleep(200)
                if (!running) return@Thread
                val nextTunFd = detachTunFd(descriptor) ?: return@Thread
                val code = TachyonCore.start(config, nextTunFd, protect, log)
                if (code != 0) {
                    val error = TachyonCore.lastError() ?: "ядро не перезапустилось"
                    Log.e(TAG, error)
                    TunnelStateHolder.update(TunnelStateHolder.State.Failed, error)
                }
            } finally {
                restarting.set(false)
            }
        }, "tachyon-restart").apply {
            isDaemon = true
            start()
        }
    }

    /**
     * Защищает сокет ядра от захвата туннелем.
     *
     * Вызывается из нативного кода: тот открывает сокет, передаёт его дескриптор
     * через unix-сокет и ждёт ответа. Если сокет не защищён, исходящие
     * соединения ядра попадут обратно в туннель.
     *
     * @return true, если сокет защищён
     */
    @androidx.annotation.Keep
    fun protectFd(fd: Int): Boolean {
        return try {
            protect(fd)
        } catch (error: Throwable) {
            Log.e(TAG, "protect($fd) не удался", error)
            false
        }
    }

    /** Останавливает туннель и освобождает ресурсы. */
    fun stopTunnel() {
        if (!running && coreThread == null) {
            closeTun()
            return
        }
        running = false
        statsThread?.interrupt()
        statsThread = null

        networkCallback?.let { callback ->
            val manager = getSystemService(ConnectivityManager::class.java)
            runCatching { manager?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        activeNetworkHandle = null

        runCatching { TachyonCore.stop() }
            .onFailure { Log.e(TAG, "остановка ядра не удалась", it) }
        runCatching { TachyonCore.protectClose() }

        coreThread?.interrupt()
        coreThread = null
        protectThread?.interrupt()
        protectThread = null

        currentConfig = null
        closeTun()
        TunnelStateHolder.update(TunnelStateHolder.State.Stopped, null)
        runCatching { TachyonAppWidget.updateAll(this) }
        stopForeground(STOP_FOREGROUND_REMOVE)
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    override fun onRevoke() {
        stopTunnel()
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
            "Tachyon · $currentServerName"
        } else {
            getString(R.string.notification_title)
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
            .setSmallIcon(android.R.drawable.ic_lock_lock)
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
        private const val MTU = 9000
        private const val TUN_ADDRESS = "172.19.0.1"
        private const val TUN_PREFIX = 30
        private const val DNS_SERVER = "1.1.1.1"
        private const val PROTECT_SOCKET_NAME = "tachyon-protect.sock"
        private const val LOG_FILE_NAME = "tachyon.log"
        const val LAST_SESSION_FILE = "last-session.json"

        const val ACTION_START = "app.tachyon.proxy.START"
        const val ACTION_STOP = "app.tachyon.proxy.STOP"
        const val ACTION_NEXT_SERVER = "app.tachyon.proxy.NEXT_SERVER"

        const val EXTRA_CONFIG = "config"
        const val EXTRA_SERVER_NAME = "server_name"
        const val EXTRA_MTU = "mtu"
        const val EXTRA_PROXY_ONLY = "proxy_only"
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
