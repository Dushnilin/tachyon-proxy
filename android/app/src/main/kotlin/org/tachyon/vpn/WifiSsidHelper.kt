package org.tachyon.vpn

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * Помощник определения текущего SSID Wi-Fi, сканирования доступных сетей
 * и проверки списка доверенных домашних/офисных Wi-Fi сетей.
 */
object WifiSsidHelper {

    @Volatile
    private var registered = false

    @Volatile
    private var cachedCallbackSsid: String = ""

    @Volatile
    private var cachedCallbackBssid: String = ""

    @Volatile
    private var onWifiEvent: (() -> Unit)? = null

    @Volatile
    private var lastDispatchedSignature: String = ""

    @Volatile
    private var lastDispatchAtMs: Long = 0L

    /** Кэш BSSID -> SSID, чтобы мгновенно узнавать сеть даже при задержке выдачи SSID в фоне. */
    private val bssidToSsid = ConcurrentHashMap<String, String>()

    fun setOnWifiEventListener(listener: (() -> Unit)?) {
        onWifiEvent = listener
    }

    private fun notifyNetworkEvent(context: Context) {
        onWifiEvent?.invoke()
        try {
            val wifi = isWifiConnected(context)
            val sig = "$wifi|$cachedCallbackSsid|$cachedCallbackBssid"
            val now = android.os.SystemClock.elapsedRealtime()
            if (sig != lastDispatchedSignature || now - lastDispatchAtMs >= 350L) {
                lastDispatchedSignature = sig
                lastDispatchAtMs = now
                TunnelStateHolder.dispatchCommand("network_changed")
            }
        } catch (_: Throwable) {}
    }

    fun cleanSsid(raw: String?): String {
        if (raw.isNullOrBlank()) return ""
        var s = raw.trim()
        if (s.length >= 2 && s.startsWith("\"") && s.endsWith("\"")) {
            s = s.substring(1, s.length - 1).trim()
        }
        if (s.isEmpty() ||
            s.equals("<unknown ssid>", ignoreCase = true) ||
            s.equals("0x", ignoreCase = true)
        ) {
            return ""
        }
        return s
    }

    private fun cleanBssid(raw: String?): String {
        val b = raw?.trim()?.lowercase().orEmpty()
        if (b.isEmpty() || b == "02:00:00:00:00:00" || b == "00:00:00:00:00:00") return ""
        return b
    }

    private fun rememberWifiInfo(ssidRaw: String?, bssidRaw: String?): String {
        val ssid = cleanSsid(ssidRaw)
        val bssid = cleanBssid(bssidRaw)
        if (bssid.isNotEmpty()) {
            cachedCallbackBssid = bssid
        }
        if (ssid.isNotEmpty()) {
            cachedCallbackSsid = ssid
            if (bssid.isNotEmpty()) {
                bssidToSsid[bssid] = ssid
            }
            return ssid
        }
        if (bssid.isNotEmpty()) {
            bssidToSsid[bssid]?.let { known ->
                cachedCallbackSsid = known
                return known
            }
        }
        return ""
    }

    /**
     * Подписывается на системные события Wi-Fi с флагом `FLAG_INCLUDE_LOCATION_INFO` (Android 12+),
     * чтобы получать реальный SSID и BSSID без маскирования синхронного `getNetworkCapabilities`.
     */
    @Suppress("DEPRECATION", "MissingPermission")
    @Synchronized
    fun ensureRegistered(context: Context) {
        if (registered) return
        val appCtx = context.applicationContext ?: context
        try {
            val cm = appCtx.getSystemService(ConnectivityManager::class.java)
            if (cm != null) {
                val request = NetworkRequest.Builder()
                    .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build()

                val callback = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                        override fun onAvailable(network: Network) {
                            notifyNetworkEvent(appCtx)
                        }

                        override fun onCapabilitiesChanged(
                            network: Network,
                            networkCapabilities: NetworkCapabilities,
                        ) {
                            if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                            val info = networkCapabilities.transportInfo as? WifiInfo
                            rememberWifiInfo(info?.ssid, info?.bssid)
                            notifyNetworkEvent(appCtx)
                        }

                        override fun onLost(network: Network) {
                            if (!isWifiConnected(appCtx)) {
                                cachedCallbackSsid = ""
                                cachedCallbackBssid = ""
                            }
                            notifyNetworkEvent(appCtx)
                        }
                    }
                } else {
                    object : ConnectivityManager.NetworkCallback() {
                        override fun onAvailable(network: Network) {
                            notifyNetworkEvent(appCtx)
                        }

                        override fun onCapabilitiesChanged(
                            network: Network,
                            networkCapabilities: NetworkCapabilities,
                        ) {
                            if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                val info = networkCapabilities.transportInfo as? WifiInfo
                                rememberWifiInfo(info?.ssid, info?.bssid)
                            }
                            notifyNetworkEvent(appCtx)
                        }

                        override fun onLost(network: Network) {
                            if (!isWifiConnected(appCtx)) {
                                cachedCallbackSsid = ""
                                cachedCallbackBssid = ""
                            }
                            notifyNetworkEvent(appCtx)
                        }
                    }
                }
                cm.registerNetworkCallback(request, callback)

                val physRequest = NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                    .build()
                val physCallback = object : ConnectivityManager.NetworkCallback() {
                    override fun onAvailable(network: Network) {
                        notifyNetworkEvent(appCtx)
                    }

                    override fun onCapabilitiesChanged(
                        network: Network,
                        networkCapabilities: NetworkCapabilities,
                    ) {
                        if (networkCapabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return
                        notifyNetworkEvent(appCtx)
                    }

                    override fun onLost(network: Network) {
                        if (!isWifiConnected(appCtx)) {
                            cachedCallbackSsid = ""
                            cachedCallbackBssid = ""
                        }
                        notifyNetworkEvent(appCtx)
                    }
                }
                cm.registerNetworkCallback(physRequest, physCallback)
            }
        } catch (_: Throwable) {}

        try {
            val filter = IntentFilter().apply {
                addAction(WifiManager.NETWORK_STATE_CHANGED_ACTION)
                addAction(WifiManager.SUPPLICANT_STATE_CHANGED_ACTION)
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent?.getParcelableExtra(WifiManager.EXTRA_WIFI_INFO, WifiInfo::class.java)
                    } else {
                        @Suppress("DEPRECATION")
                        intent?.getParcelableExtra(WifiManager.EXTRA_WIFI_INFO) as? WifiInfo
                    }
                    if (info != null) {
                        rememberWifiInfo(info.ssid, info.bssid)
                    }
                    notifyNetworkEvent(appCtx)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                appCtx.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                appCtx.registerReceiver(receiver, filter)
            }
        } catch (_: Throwable) {}

        registered = true
    }

    fun hasLocationPermission(context: Context): Boolean {
        val fine = context.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        return fine || coarse
    }

    fun isLocationEnabled(context: Context): Boolean {
        return try {
            val lm = context.getSystemService(LocationManager::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && lm != null) {
                lm.isLocationEnabled
            } else {
                @Suppress("DEPRECATION")
                val mode = Settings.Secure.getInt(
                    context.contentResolver,
                    Settings.Secure.LOCATION_MODE,
                    Settings.Secure.LOCATION_MODE_OFF,
                )
                mode != Settings.Secure.LOCATION_MODE_OFF
            }
        } catch (_: Throwable) {
            true
        }
    }

    /**
     * Проверяет, подключено ли устройство к реальной сети Wi-Fi
     * (игнорируя поверх поднятый интерфейс VPN).
     */
    @Suppress("DEPRECATION")
    fun isWifiConnected(context: Context): Boolean {
        return try {
            val cm = context.getSystemService(ConnectivityManager::class.java) ?: return false
            val active = cm.activeNetwork
            if (active != null) {
                val activeCaps = cm.getNetworkCapabilities(active)
                if (activeCaps != null && !activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    return activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
                }
            }
            for (net in cm.allNetworks) {
                val caps = cm.getNetworkCapabilities(net) ?: continue
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                    !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                ) {
                    return true
                }
            }
            false
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Возвращает SSID текущей подключённой Wi-Fi сети, либо пустую строку,
     * если Wi-Fi отключён или разрешение на чтение SSID ещё не выдано.
     */
    @Suppress("DEPRECATION", "MissingPermission")
    fun getCurrentWifiSsid(context: Context): String {
        ensureRegistered(context)
        if (!isWifiConnected(context)) {
            cachedCallbackSsid = ""
            cachedCallbackBssid = ""
            return ""
        }
        return try {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            var activeBssid = cachedCallbackBssid
            if (cm != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                for (net in cm.allNetworks) {
                    val caps = cm.getNetworkCapabilities(net) ?: continue
                    if (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
                        !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                    ) {
                        val info = caps.transportInfo as? WifiInfo
                        val b = cleanBssid(info?.bssid)
                        if (b.isNotEmpty()) activeBssid = b
                        val fromCaps = rememberWifiInfo(info?.ssid, info?.bssid)
                        if (fromCaps.isNotEmpty()) return fromCaps
                    }
                }
            }

            val wm = context.applicationContext.getSystemService(WifiManager::class.java)
            val conn = runCatching { wm?.connectionInfo }.getOrNull()
            val connBssid = cleanBssid(conn?.bssid)
            if (connBssid.isNotEmpty()) activeBssid = connBssid
            val fromConn = rememberWifiInfo(conn?.ssid, conn?.bssid)
            if (fromConn.isNotEmpty()) return fromConn

            if (cachedCallbackSsid.isNotEmpty()) {
                return cachedCallbackSsid
            }

            if (activeBssid.isNotEmpty()) {
                bssidToSsid[activeBssid]?.let { return it }
            }

            // Фоллбэк по BSSID через результаты сканирования Wi-Fi (актуально для ряда прошивок HyperOS/MIUI)
            if (wm != null && hasLocationPermission(context)) {
                val scans = runCatching { wm.scanResults }.getOrNull().orEmpty()
                for (sr in scans) {
                    val srSsid = cleanSsid(sr.SSID)
                    val srBssid = cleanBssid(sr.BSSID)
                    if (srSsid.isNotEmpty() && srBssid.isNotEmpty()) {
                        bssidToSsid[srBssid] = srSsid
                    }
                }
                if (activeBssid.isNotEmpty()) {
                    bssidToSsid[activeBssid]?.let { found ->
                        cachedCallbackSsid = found
                        return found
                    }
                }
            }
            ""
        } catch (_: Throwable) {
            cachedCallbackSsid
        }
    }

    /**
     * Возвращает список видимых рядом Wi-Fi сетей (отсортированных по уровню сигнала),
     * включая текущую подключённую сеть первой в списке.
     */
    @Suppress("DEPRECATION", "MissingPermission")
    fun getNearbySsids(context: Context): List<String> {
        ensureRegistered(context)
        val result = LinkedHashSet<String>()
        val current = getCurrentWifiSsid(context)
        if (current.isNotEmpty()) {
            result.add(current)
        }
        if (!hasLocationPermission(context)) {
            return result.toList()
        }
        try {
            val wm = context.applicationContext.getSystemService(WifiManager::class.java)
            val scans = runCatching { wm?.scanResults }.getOrNull().orEmpty()
            scans.sortedByDescending { it.level }.forEach { sr ->
                val ssid = cleanSsid(sr.SSID)
                val bssid = cleanBssid(sr.BSSID)
                if (ssid.isNotEmpty()) {
                    result.add(ssid)
                    if (bssid.isNotEmpty()) {
                        bssidToSsid[bssid] = ssid
                    }
                }
            }
        } catch (_: Throwable) {}
        return result.take(20)
    }

    @Volatile
    private var lastWifiFilePath: String = ""

    @Volatile
    private var lastWifiFileMtime: Long = -1L

    @Volatile
    private var lastWifiFileSize: Long = -1L

    @Volatile
    private var cachedHomeWifiConfig: Pair<Boolean, List<String>> = false to emptyList()

    /**
     * Читает настройки режима «Домашний интернет» из облегчённого `tachyon-wifi.json`
     * (с откатом на `tachyon-settings.json`) и кэширует результат по `(mtime, size)`.
     * При ошибке чтения/парсинга сохраняет последнюю валидную конфигурацию.
     */
    fun readHomeWifiConfig(filesDir: File): Pair<Boolean, List<String>> {
        val wifiFile = File(filesDir, "tachyon-wifi.json")
        val file = if (wifiFile.exists()) wifiFile else File(filesDir, "tachyon-settings.json")
        if (!file.exists()) return cachedHomeWifiConfig
        val path = file.absolutePath
        val mtime = file.lastModified()
        val size = file.length()
        if (path == lastWifiFilePath && mtime == lastWifiFileMtime && size == lastWifiFileSize && mtime > 0L) {
            return cachedHomeWifiConfig
        }
        return try {
            val raw = file.readText()
            if (raw.isBlank()) return cachedHomeWifiConfig
            val obj = JSONObject(raw)
            val enabled = obj.optBoolean("homeWifiMode", false)
            val arr = obj.optJSONArray("trustedWifiSsids")
            val list = ArrayList<String>()
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val s = cleanSsid(arr.optString(i))
                    if (s.isNotEmpty()) list.add(s)
                }
            }
            val parsed = enabled to list
            cachedHomeWifiConfig = parsed
            lastWifiFilePath = path
            lastWifiFileMtime = mtime
            lastWifiFileSize = size
            parsed
        } catch (_: Throwable) {
            cachedHomeWifiConfig
        }
    }

    fun matchesTrustedWifi(currentSsid: String, trustedSsids: Collection<String>): Boolean {
        val clean = cleanSsid(currentSsid)
        if (clean.isEmpty()) return false
        return trustedSsids.any { it.trim().equals(clean, ignoreCase = true) }
    }
}
