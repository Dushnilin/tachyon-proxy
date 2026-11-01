package org.tachyon.vpn

import java.io.File

/**
 * Мост к нативному ядру `tachyon-core` (libtachyon.so).
 *
 * Символы, экспортируемые Rust-библиотекой:
 *  - Java_org_tachyon_vpn_TachyonCore_start
 *  - Java_org_tachyon_vpn_TachyonCore_stop
 *  - Java_org_tachyon_vpn_TachyonCore_lastError
 *  - Java_org_tachyon_vpn_TachyonCore_version
 *  - Java_org_tachyon_vpn_TachyonCore_nativeStats
 *  - Java_org_tachyon_vpn_TachyonCore_check
 *  - Java_org_tachyon_vpn_TachyonCore_protectOpen
 *  - Java_org_tachyon_vpn_TachyonCore_protectLoop
 *  - Java_org_tachyon_vpn_TachyonCore_protectClose
 */
object TachyonCore {

    private const val LIBRARY = "tachyon"
    const val CUSTOM_SO_PATH = "/data/user/0/app.tachyon.tachyon_proxy/code_cache/engine/libtachyon.so"
    const val CUSTOM_STAMP_PATH = "/data/user/0/app.tachyon.tachyon_proxy/code_cache/engine/engine_v029_plus.stamp"

    @Volatile
    private var loaded = false

    @Volatile
    var isCustomSoLoaded = false
        private set

    @Volatile
    var loadError: String? = null
        private set

    init {
        val customSo = File(CUSTOM_SO_PATH)
        val stampFile = File(CUSTOM_STAMP_PATH)
        if (customSo.exists() && !stampFile.exists()) {
            // Удаляем устаревший кэшированный .so (например 0.1.6), скачанный до раздельного загрузчика v0.2.9+
            runCatching {
                customSo.setWritable(true, true)
                customSo.delete()
            }
        }
        if (customSo.exists() && stampFile.exists() && customSo.length() > 1_000_000L) {
            try {
                customSo.setWritable(false, false)
                customSo.setReadable(true, false)
                customSo.setExecutable(true, false)
                System.load(customSo.absolutePath)
                loaded = true
                isCustomSoLoaded = true
            } catch (_: Throwable) {
                runCatching {
                    customSo.setWritable(true, true)
                    customSo.delete()
                    stampFile.delete()
                }
            }
        }
        if (!loaded) {
            try {
                System.loadLibrary(LIBRARY)
                loaded = true
            } catch (error: UnsatisfiedLinkError) {
                loadError = error.message ?: "не удалось загрузить lib$LIBRARY.so"
            } catch (error: SecurityException) {
                loadError = error.message ?: "lib$LIBRARY.so: доступ запрещён"
            }
        }
    }

    val isAvailable: Boolean
        get() = loaded

    private fun requireLoaded() {
        if (!loaded) {
            throw IllegalStateException(loadError ?: "ядро не загружено")
        }
    }

    fun stats(): String? {
        if (!loaded) return null
        return nativeStats()
    }

    external fun check(config: String): String?
    external fun fetchSubscription(
        url: String,
        customUa: String,
        sendHwid: Boolean,
        customHwid: String,
        insecure: Boolean,
    ): String?
    external fun parseSubscription(payload: String): String?
    external fun start(config: String, tunFd: Int, protectPath: String, logPath: String): Int
    external fun stop(): Int
    external fun lastError(): String?
    external fun version(): String?
    external fun nativeStats(): String?
    external fun protectOpen(path: String): Int
    external fun protectLoop(service: TachyonVpnService): Int
    external fun protectClose(): Int
}
