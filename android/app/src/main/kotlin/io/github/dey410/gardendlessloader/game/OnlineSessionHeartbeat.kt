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
 * 任何失败都不能影响游玩（不弹窗、不重试风暴），但必须留下可诊断的日志：
 * 真机验收时要能从日志判断「心跳发出去没有 / 服务端认不认这个令牌」。
 */
class OnlineSessionHeartbeat(
    private val base: String,
    private val token: String,
    private val gameVersion: String,
    private val deviceId: String,
    private val onResult: (phase: String, statusCode: Int, durationMs: Long, error: Throwable?) -> Unit,
    private val onTokenRejected: () -> Unit,
) {
    private var scheduler: ScheduledExecutorService? = null
    private var rejected = false

    fun start() {
        if (scheduler != null) return
        val executor = Executors.newSingleThreadScheduledExecutor { runnable ->
            Thread(runnable, "pvz-online-heartbeat").apply { isDaemon = true }
        }
        scheduler = executor
        // 立刻登记一次，之后每 60 秒续期（服务端 TTL 120 秒，留一倍余量）
        executor.scheduleWithFixedDelay(
            { send("enter", "/_save/app/online/enter") },
            0,
            60,
            TimeUnit.SECONDS,
        )
    }

    fun stop() {
        val executor = scheduler ?: return
        scheduler = null
        // 令牌已被拒时不要再发 leave：服务端会继续回 401，日志只会变噪音。
        if (!rejected) {
            // 绝不能在这个线程上同步发网络请求：stop() 由 GameActivity.onDestroy()
            // 在主线程调用，而 post() 的连接/读取各 5 秒超时，网络不通时最坏把主线程
            // 卡住 10 秒直接 ANR。改成提交到心跳自己的执行器异步发送。
            // shutdown() 而不是 shutdownNow()：已提交的任务仍会执行完，周期任务会被取消。
            runCatching { executor.execute { send("leave", "/_save/app/online/leave") } }
        }
        runCatching { executor.shutdown() }
    }

    private fun send(phase: String, path: String) {
        val startedAt = System.nanoTime()
        var status = -1
        var error: Throwable? = null
        try {
            status = post(path)
        } catch (failure: Throwable) {
            error = failure
        }
        val elapsedMs = (System.nanoTime() - startedAt) / 1_000_000
        onResult(phase, status, elapsedMs, error)
        if (status == HTTP_UNAUTHORIZED || status == HTTP_FORBIDDEN) {
            // 令牌被吊销/过期：再发也不会成功，停掉周期任务并向宿主上报一次。
            if (!rejected) {
                rejected = true
                runCatching { scheduler?.shutdown() }
                onTokenRejected()
            }
        }
    }

    /** 返回 HTTP 状态码；网络层失败时抛出，由 [send] 记录。 */
    private fun post(path: String): Int {
        val url = URL(base.trimEnd('/') + path)
        var connection: HttpURLConnection? = null
        return try {
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
            val code = connection.responseCode
            // 读掉响应，否则连接不会复用/关闭
            (if (code >= 400) connection.errorStream else connection.inputStream)
                ?.use { it.readBytes() }
            code
        } finally {
            runCatching { connection?.disconnect() }
        }
    }

    companion object {
        private const val HTTP_UNAUTHORIZED = 401
        private const val HTTP_FORBIDDEN = 403

        /**
         * 从会话与桥文件构造心跳；缺少令牌时不登记（在线形态本来也进不去）。
         */
        fun fromSession(
            session: NativeGameSession,
            onResult: (phase: String, statusCode: Int, durationMs: Long, error: Throwable?) -> Unit,
            onTokenRejected: () -> Unit,
        ): OnlineSessionHeartbeat? {
            val bridge = File(session.appRoot, GameActivity.SAVE_BRIDGE_FILE_NAME)
            val credentials = OnlineGameResourceClient.readHostCredentials(
                session.appRoot,
                bridge,
            ) ?: return null
            return OnlineSessionHeartbeat(
                base = session.origin,
                token = credentials.second,
                gameVersion = session.gameVersion,
                deviceId = session.deviceId.ifBlank { "android" },
                onResult = onResult,
                onTokenRejected = onTokenRejected,
            )
        }
    }
}
