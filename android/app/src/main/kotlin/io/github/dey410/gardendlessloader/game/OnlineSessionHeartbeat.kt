package io.github.dey410.gardendlessloader.game

import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * 在线游玩会话心跳。
 *
 * 为什么必须在原生侧：`MainActivity` 拉起 `GameActivity` 后会 `finish()`，
 * Flutter 引擎随之销毁，Dart 的定时器一个 tick 都活不过去。之前心跳写在
 * Dart 里，等于「刚登记就注销」——服务端永远认为没人在线游玩，资源更新
 * 让路逻辑形同虚设。
 *
 * 服务端侧：`POST /_save/app/online/enter` 登记（TTL 120s），
 * 每 60s 续一次；`POST /_save/app/online/leave` 注销。
 * 任何失败都静默：心跳只服务于「能不能安全换资源」，不能影响游玩。
 */
class OnlineSessionHeartbeat(
    private val base: String,
    private val token: String,
    private val gameVersion: String,
    private val deviceId: String,
) {
    private var scheduler: ScheduledExecutorService? = null

    fun start() {
        if (scheduler != null) return
        val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "pvz-online-heartbeat").apply { isDaemon = true }
        }
        scheduler = executor
        // 立刻登记一次，之后每 60 秒续期（服务端 TTL 120 秒，留一倍余量）
        executor.scheduleWithFixedDelay(
            { runCatching { post("/_save/app/online/enter") } },
            0,
            60,
            TimeUnit.SECONDS,
        )
    }

    fun stop() {
        val executor = scheduler ?: return
        scheduler = null
        runCatching { post("/_save/app/online/leave") }
        executor.shutdownNow()
    }

    private fun post(path: String) {
        val url = runCatching { URL(base.trimEnd('/') + path) }.getOrNull() ?: return
        var connection: HttpURLConnection? = null
        try {
            connection = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 5_000
                readTimeout = 5_000
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Authorization", "Bearer $token")
            }
            val body = """{"gameVersion":"$gameVersion","device":{"id":"$deviceId","label":"android"}}"""
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            // 读掉响应，否则连接不会复用/关闭
            connection.inputStream?.use { it.readBytes() }
                ?: connection.errorStream?.use { it.readBytes() }
        } catch (_: Exception) {
            // 静默：心跳失败不影响游玩
        } finally {
            runCatching { connection?.disconnect() }
        }
    }

    companion object {
        /**
         * 从会话与桥文件构造心跳；缺少令牌时不登记（在线形态本来也进不去）。
         */
        fun fromSession(session: NativeGameSession): OnlineSessionHeartbeat? {
            val bridge = File(session.appRoot, GameActivity.SAVE_BRIDGE_FILE_NAME)
            val credentials = OnlineGameResourceClient.readBridgeCredentials(bridge) ?: return null
            return OnlineSessionHeartbeat(
                base = session.origin,
                token = credentials.second,
                gameVersion = session.gameVersion,
                deviceId = session.deviceId.ifBlank { "android" },
            )
        }
    }
}
