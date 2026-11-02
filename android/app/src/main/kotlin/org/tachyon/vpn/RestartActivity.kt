package org.tachyon.vpn

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import kotlin.system.exitProcess

/**
 * Вспомогательная Activity в отдельном лёгком процессе `:restart`.
 *
 * Гарантирует чистый перезапуск основного процесса приложения после горячей замены
 * `libtachyon.so` в `code_cache/engine`, чтобы `TachyonCore` загрузил новую версию
 * нативного движка с нуля без гонок с `ActivityTaskManagerService`.
 */
class RestartActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mainIntent = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_MAIN_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_MAIN_INTENT)
        }

        Handler(Looper.getMainLooper()).postDelayed({
            if (mainIntent != null) {
                startActivity(mainIntent)
            }
            finish()
            Process.killProcess(Process.myPid())
            exitProcess(0)
        }, 160)
    }

    companion object {
        private const val EXTRA_MAIN_INTENT = "tachyon_restart_main_intent"

        fun triggerRebirth(context: Context) {
            val pm = context.packageManager
            val nextIntent = pm.getLaunchIntentForPackage(context.packageName)?.apply {
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TASK or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP,
                )
            } ?: return

            val restartIntent = Intent(context, RestartActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(EXTRA_MAIN_INTENT, nextIntent)
            }
            context.startActivity(restartIntent)
            if (context is Activity) {
                context.finish()
            }
            Process.killProcess(Process.myPid())
            exitProcess(0)
        }
    }
}
