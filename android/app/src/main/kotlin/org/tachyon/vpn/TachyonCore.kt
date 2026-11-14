package org.tachyon.vpn

import android.content.Context
import android.os.Build
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
    private const val SO_FILE_NAME = "libtachyon.so"
    private const val PROBE_SO_FILE_NAME = "libtachyon_probe.so"
    private const val STAMP_FILE_NAME = "engine_v039_plus.stamp"
    const val CUSTOM_SO_PATH = "/data/user/0/app.tachyon.tachyon_proxy/code_cache/engine/$SO_FILE_NAME"
    const val CUSTOM_STAMP_PATH = "/data/user/0/app.tachyon.tachyon_proxy/code_cache/engine/$STAMP_FILE_NAME"

    @Volatile
    private var loaded = false

    @Volatile
    var isCustomSoLoaded = false
        private set

    @Volatile
    var loadError: String? = null
        private set

    fun engineDir(context: Context): File = File(context.codeCacheDir, "engine")

    fun customSoFile(context: Context): File = File(engineDir(context), SO_FILE_NAME)

    fun customStampFile(context: Context): File = File(engineDir(context), STAMP_FILE_NAME)

    fun probeSoFile(context: Context): File = File(engineDir(context), PROBE_SO_FILE_NAME)

    private fun deleteWritable(file: File) {
        runCatching {
            if (file.exists()) {
                file.setWritable(true, true)
                file.delete()
            }
        }
    }

    private fun readApkMetadata(context: Context): Pair<String, Long>? {
        return runCatching {
            @Suppress("DEPRECATION")
            val pkgInfo = context.packageManager.getPackageInfo(context.packageName, 0)
            val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkgInfo.longVersionCode
            } else {
                @Suppress("DEPRECATION")
                pkgInfo.versionCode.toLong()
            }
            val updatedAt = pkgInfo.lastUpdateTime
            "$versionCode:$updatedAt" to updatedAt
        }.getOrNull()
    }

    /** Сохраняет привязку загруженного `.so` к текущей версии и времени установки APK. */
    fun writeCustomStamp(context: Context) {
        runCatching {
            val dir = engineDir(context)
            dir.mkdirs()
            val stamp = readApkMetadata(context)?.first ?: System.currentTimeMillis().toString()
            customStampFile(context).writeText(stamp)
        }
    }

    /** Удаляет внешний бинарник движка и его служебные файлы. */
    fun clearCustomEngine(context: Context? = null) {
        if (context != null) {
            deleteWritable(customSoFile(context))
            deleteWritable(customStampFile(context))
            deleteWritable(probeSoFile(context))
        }
        deleteWritable(File(CUSTOM_SO_PATH))
        deleteWritable(File(CUSTOM_STAMP_PATH))
    }

    /**
     * Инициализирует и загружает `libtachyon.so` один раз на процесс.
     *
     * Перед загрузкой проверяет, что кэшированный `code_cache/engine/libtachyon.so`
     * принадлежит текущей установленной сборке APK; иначе удаляет его и загружает
     * встроенную библиотеку из APK.
     */
    @Synchronized
    fun ensureInitialized(context: Context): Boolean {
        if (loaded) return true
        loadError = null

        val appCtx = context.applicationContext ?: context
        val customSo = customSoFile(appCtx)
        val stampFile = customStampFile(appCtx)
        deleteWritable(probeSoFile(appCtx))

        if (customSo.absolutePath != CUSTOM_SO_PATH) {
            deleteWritable(File(CUSTOM_SO_PATH))
            deleteWritable(File(CUSTOM_STAMP_PATH))
        }

        if (customSo.exists()) {
            val apkMeta = readApkMetadata(appCtx)
            val actualStamp = runCatching {
                if (stampFile.exists()) stampFile.readText().trim() else ""
            }.getOrDefault("")
            // Учитываем возможное округление mtime до секунд на некоторых ФС.
            val validForCurrentApk = apkMeta != null &&
                actualStamp == apkMeta.first &&
                customSo.lastModified() + 2_000L >= apkMeta.second
            if (!validForCurrentApk) {
                deleteWritable(customSo)
                deleteWritable(stampFile)
            }
        } else if (stampFile.exists()) {
            deleteWritable(stampFile)
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
                deleteWritable(customSo)
                deleteWritable(stampFile)
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
        return loaded
    }

    val isAvailable: Boolean
        get() = loaded

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
