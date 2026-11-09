package org.tachyon.vpn

import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import app.tachyon.tachyon_proxy.MainActivity
import app.tachyon.tachyon_proxy.R
import java.io.File

/**
 * Плитка быстрых настроек (Quick Settings Tile) в шторке Android.
 * Позволяет включать и выключать VPN в один тап без открытия приложения.
 */
class TachyonTileService : TileService() {

    private val listener = TunnelStateHolder.Listener { _, _ ->
        updateTileState()
    }

    override fun onStartListening() {
        super.onStartListening()
        TunnelStateHolder.addListener(listener)
        updateTileState()
    }

    override fun onStopListening() {
        TunnelStateHolder.removeListener(listener)
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        when (TunnelStateHolder.state) {
            TunnelStateHolder.State.Running,
            TunnelStateHolder.State.Starting -> {
                val stopIntent = Intent(this, TachyonVpnService::class.java).setAction(
                    TachyonVpnService.ACTION_STOP,
                )
                startService(stopIntent)
            }
            TunnelStateHolder.State.Stopped,
            TunnelStateHolder.State.Failed -> {
                if (TunnelStateHolder.pausedByWifiSsid.isNotEmpty()) {
                    val resumeIntent = Intent(this, TachyonVpnService::class.java).setAction(
                        TachyonVpnService.ACTION_FORCE_RESUME,
                    )
                    startService(resumeIntent)
                    return
                }
                if (VpnService.prepare(this) == null && TunnelStateHolder.hasCommandListeners()) {
                    TunnelStateHolder.dispatchCommand("connect")
                    return
                }
                val sessionFile = File(filesDir, TachyonVpnService.LAST_SESSION_FILE)
                if (VpnService.prepare(this) == null && sessionFile.exists()) {
                    val startIntent = Intent(this, TachyonVpnService::class.java).setAction(
                        TachyonVpnService.ACTION_START,
                    )
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(startIntent)
                    } else {
                        startService(startIntent)
                    }
                } else {
                    val appIntent = Intent(this, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                        putExtra("cmd", "connect")
                    }
                    startActivity(appIntent)
                }
            }
        }
    }

    private fun updateTileState() {
        val tile = qsTile ?: return
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tachyon_bolt)
        when (TunnelStateHolder.state) {
            TunnelStateHolder.State.Running -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "Tachyon"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = TunnelStateHolder.serverName.ifEmpty { "Подключено" }
                }
            }
            TunnelStateHolder.State.Starting -> {
                tile.state = Tile.STATE_ACTIVE
                tile.label = "Tachyon"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Подключение..."
                }
            }
            TunnelStateHolder.State.Failed -> {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "Tachyon"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    tile.subtitle = "Ошибка"
                }
            }
            TunnelStateHolder.State.Stopped -> {
                tile.state = Tile.STATE_INACTIVE
                tile.label = "Tachyon"
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val pausedWifi = TunnelStateHolder.pausedByWifiSsid
                    tile.subtitle = if (pausedWifi.isNotEmpty()) {
                        "🏠 Пауза ($pausedWifi)"
                    } else {
                        "Отключено"
                    }
                }
            }
        }
        tile.updateTile()
    }
}
