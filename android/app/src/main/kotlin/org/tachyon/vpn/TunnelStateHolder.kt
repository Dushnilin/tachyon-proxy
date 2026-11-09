package org.tachyon.vpn

import java.util.concurrent.CopyOnWriteArrayList

/**
 * Общее состояние туннеля между сервисом и Flutter.
 *
 * Сервис пишет сюда, Dart читает по подписке. Нужен именно потому, что
 * сервис живёт своей жизнью: Flutter может пересоздаться при повороте
 * экрана, а туннель — нет.
 */
object TunnelStateHolder {

    /** Состояния, которые видит интерфейс. */
    enum class State {
        Stopped,
        Starting,
        Running,
        Failed,
    }

    /** Подписчик на изменение состояния. */
    fun interface Listener {
        fun onStateChanged(state: State, error: String?)
    }

    /** Подписчик на команды от уведомления или шторки (например, next_server). */
    fun interface CommandListener {
        fun onCommand(cmd: String)
    }

    private val listeners = CopyOnWriteArrayList<Listener>()
    private val commandListeners = CopyOnWriteArrayList<CommandListener>()

    @Volatile
    var state: State = State.Stopped
        private set

    @Volatile
    var error: String? = null
        private set

    @Volatile
    var serverName: String = ""

    /** Имя домашней Wi-Fi сети, в которой маршрутизация сейчас поставлена на авто-паузу. */
    @Volatile
    var pausedByWifiSsid: String = ""

    /** Последний JSON статистики ядра, обновляемый сервисом раз в 2 с, чтобы Flutter не опрашивал JNI повторно. */
    @Volatile
    var latestStatsJson: String = ""
        private set

    @Volatile
    var latestStatsAtMs: Long = 0L
        private set

    fun updateStats(rawJson: String?) {
        if (!rawJson.isNullOrEmpty()) {
            latestStatsJson = rawJson
            latestStatsAtMs = System.currentTimeMillis()
        }
    }

    /** Подписка на изменения состояния. */
    fun addListener(listener: Listener) {
        listeners.add(listener)
        listener.onStateChanged(state, error)
    }

    /** Отписка от изменений состояния. */
    fun removeListener(listener: Listener) {
        listeners.remove(listener)
    }

    fun addCommandListener(listener: CommandListener) {
        commandListeners.add(listener)
    }

    fun removeCommandListener(listener: CommandListener) {
        commandListeners.remove(listener)
    }

    fun hasCommandListeners(): Boolean = commandListeners.isNotEmpty()

    fun dispatchCommand(cmd: String) {
        commandListeners.forEach { listener ->
            runCatching { listener.onCommand(cmd) }
        }
    }

    /**
     * Обновляет состояние и уведомляет подписчиков.
     *
     * @param newState новое состояние
     * @param newError текст ошибки; `null` — ошибки нет
     */
    fun update(newState: State, newError: String?, pausedWifi: String = pausedByWifiSsid) {
        state = newState
        error = newError
        pausedByWifiSsid = pausedWifi
        if (newState == State.Stopped || newState == State.Failed) {
            latestStatsJson = ""
            latestStatsAtMs = 0L
        }
        listeners.forEach { listener ->
            runCatching { listener.onStateChanged(newState, newError) }
        }
    }

    /** Имя состояния для Dart: значение из [State] в нижнем регистре. */
    fun stateName(): String = when (state) {
        State.Stopped -> "disconnected"
        State.Starting -> "connecting"
        State.Running -> "connected"
        State.Failed -> "failed"
    }
}
