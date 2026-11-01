package org.tachyon.vpn

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import org.json.JSONObject
import java.io.File

/**
 * Автозапуск VPN-туннеля при старте Android, если в настройках включён `autoStart`.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val settingsFile = File(context.filesDir, "tachyon-settings.json")
        val sessionFile = File(context.filesDir, TachyonVpnService.LAST_SESSION_FILE)
        if (!settingsFile.exists() || !sessionFile.exists()) return

        val autoStart = runCatching {
            JSONObject(settingsFile.readText()).optBoolean("autoStart", false)
        }.getOrDefault(false)

        if (!autoStart) return
        if (VpnService.prepare(context) != null) return

        val startIntent = Intent(context, TachyonVpnService::class.java).setAction(
            TachyonVpnService.ACTION_START,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(startIntent)
        } else {
            context.startService(startIntent)
        }
    }
}
