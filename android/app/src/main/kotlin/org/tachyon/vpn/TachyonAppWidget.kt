package org.tachyon.vpn

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.widget.RemoteViews
import app.tachyon.tachyon_proxy.MainActivity
import app.tachyon.tachyon_proxy.R
import org.json.JSONObject
import java.io.File

/**
 * Виджет рабочего стола Android (4x1) в стиле Morphe:
 * показывает статус туннеля, выбранный сервер, скорость и кнопку быстрого переключения.
 */
class TachyonAppWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            updateWidget(context, appWidgetManager, id)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_WIDGET_TOGGLE) {
            val active = TunnelStateHolder.state == TunnelStateHolder.State.Running ||
                TunnelStateHolder.state == TunnelStateHolder.State.Starting
            if (active) {
                val stop = Intent(context, TachyonVpnService::class.java).apply {
                    action = TachyonVpnService.ACTION_STOP
                }
                context.startService(stop)
            } else {
                val sessionFile = File(context.filesDir, "last-session.json")
                if (sessionFile.exists()) {
                    try {
                        val obj = JSONObject(sessionFile.readText())
                        val start = Intent(context, TachyonVpnService::class.java).apply {
                            action = TachyonVpnService.ACTION_START
                            putExtra(TachyonVpnService.EXTRA_CONFIG, obj.optString("config", ""))
                            putExtra(TachyonVpnService.EXTRA_SERVER_NAME, obj.optString("serverName", ""))
                            putExtra(TachyonVpnService.EXTRA_MTU, obj.optInt("mtu", 1400))
                            putExtra(TachyonVpnService.EXTRA_PROXY_ONLY, obj.optBoolean("proxyOnly", false))
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            context.startForegroundService(start)
                        } else {
                            context.startService(start)
                        }
                    } catch (_: Throwable) {}
                } else {
                    val open = Intent(context, MainActivity::class.java).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    context.startActivity(open)
                }
            }
            updateAll(context)
        }
    }

    companion object {
        const val ACTION_WIDGET_TOGGLE = "org.tachyon.vpn.action.WIDGET_TOGGLE"

        fun updateAll(context: Context, trafficLine: String? = null) {
            try {
                val mgr = AppWidgetManager.getInstance(context)
                val ids = mgr.getAppWidgetIds(ComponentName(context, TachyonAppWidget::class.java))
                for (id in ids) {
                    updateWidget(context, mgr, id, trafficLine)
                }
            } catch (_: Throwable) {}
        }

        private fun updateWidget(
            context: Context,
            mgr: AppWidgetManager,
            widgetId: Int,
            trafficLine: String? = null,
        ) {
            val connected = TunnelStateHolder.state == TunnelStateHolder.State.Running
            val srvName = TunnelStateHolder.serverName
            val views = RemoteViews(context.packageName, R.layout.tachyon_widget)

            views.setTextViewText(
                R.id.widget_status,
                if (connected) "⚡ TACHYON · ПОДКЛЮЧЕНО" else "⚡ TACHYON · ОТКЛЮЧЕНО",
            )
            views.setTextColor(
                R.id.widget_status,
                Color.parseColor(if (connected) "#6FD08C" else "#B9A8FF"),
            )
            views.setTextViewText(
                R.id.widget_server,
                if (srvName.isNotEmpty()) srvName else "Сервер по умолчанию",
            )
            views.setTextViewText(
                R.id.widget_traffic,
                trafficLine ?: if (connected) "Туннель активен" else "Нажмите ВКЛ для запуска",
            )
            views.setTextViewText(R.id.widget_toggle_btn, if (connected) "ВЫКЛ" else "ВКЛ")

            val openIntent = Intent(context, MainActivity::class.java)
            val openPi = PendingIntent.getActivity(
                context,
                10,
                openIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_root, openPi)

            val toggleIntent = Intent(context, TachyonAppWidget::class.java).apply {
                action = ACTION_WIDGET_TOGGLE
            }
            val togglePi = PendingIntent.getBroadcast(
                context,
                11,
                toggleIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widget_toggle_btn, togglePi)

            mgr.updateAppWidget(widgetId, views)
        }
    }
}
