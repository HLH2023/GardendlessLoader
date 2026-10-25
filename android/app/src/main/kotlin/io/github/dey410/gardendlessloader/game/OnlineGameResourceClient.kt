package io.github.dey410.gardendlessloader.game

import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.Locale

import org.json.JSONObject

import io.github.dey410.gardendlessloader.logging.AppLogStore

/**
 * 在线形态的资源抓取：把服务器上的游戏页 + 资源拉下来喂给 WebView。
 *
 * 为什么不直接让 WebView 访问远端：在线形态要走 Bearer 设备令牌（服务端
 * `/_save/online/` 用 authcheck 校验），而 WebView 只支持给**主文档**加请求头，
 * 子资源（wasm / js / 音频）拿不到 Authorization。所以子资源也由这里代理，
 * 统一带上令牌。
 *
 * HTML 需要注入存档桥（设备令牌 + shim + 面板）：服务端的 `/_save/online/`
 * 刻意不做 sub_filter 注入，避免 cookie 版 sync.js 与 App 的桥打架。
 */
class OnlineGameResourceClient(
    private val origin: String,
    private val token: String,
    bridgeScript: String,
) {
    private val originUrl = URL(origin)
    private val bridgeTag = run {
        require(!bridgeScript.contains("</script", ignoreCase = true) &&
            !bridgeScript.contains("<!--")) { "Bridge script cannot be inlined into HTML" }
        // 与本地资源路径同样的处理：桥必须是页面里的第一个脚本
        "<script>$bridgeScript</script>"
    }

    fun accepts(url: String): Boolean {
        val parsed = runCatching { URL(url) }.getOrNull() ?: return false
        return parsed.protocol == originUrl.protocol && parsed.host == originUrl.host
    }

    fun fetch(
        url: String,
        method: String,
        requestHeaders: Map<String, String>,
    ): GameResourceResponse {
        if (method != "GET" && method != "HEAD") {
            return error(405, "Method Not Allowed", mapOf("Allow" to "GET, HEAD"))
        }
        val connection = runCatching { URL(url).openConnection() as HttpURLConnection }
            .getOrElse { return error(502, "Bad Gateway") }
        try {
            connection.requestMethod = method
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            connection.setRequestProperty("Accept-Encoding", "identity")
            // Range 与条件请求原样透传：wasm/音频要靠它做流式与断点
            for (name in listOf("Range", "If-Range", "If-None-Match", "If-Modified-Since", "Accept")) {
                requestHeaders.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }
                    ?.let { connection.setRequestProperty(name, it.value) }
            }
            val status = connection.responseCode
            val contentType = connection.contentType ?: "application/octet-stream"
            val mime = contentType.substringBefore(';').trim().ifEmpty { "application/octet-stream" }
            val charset = Regex("charset=([^;]+)", RegexOption.IGNORE_CASE)
                .find(contentType)?.groupValues?.get(1)?.trim()?.trim('"')

            val passthrough = linkedMapOf<String, String>()
            for (name in listOf(
                "Content-Range", "Accept-Ranges", "ETag", "Last-Modified", "Cache-Control",
            )) {
                connection.getHeaderField(name)?.let { passthrough[name] = it }
            }

            val raw: InputStream = (if (status >= 400) connection.errorStream else connection.inputStream)
                ?: ByteArrayInputStream(ByteArray(0))

            // HTML：注入存档桥后再返回（服务端不再注入，这里必须做）
            if (mime == "text/html" && status in 200..299 && method == "GET") {
                val text = raw.bufferedReader(StandardCharsets.UTF_8).use { it.readText() }
                val patched = injectBridge(text) ?: text
                val bytes = patched.toByteArray(StandardCharsets.UTF_8)
                passthrough.remove("Content-Range")
                return GameResourceResponse(
                    statusCode = status,
                    reason = "OK",
                    mimeType = mime,
                    encoding = "UTF-8",
                    headers = passthrough + ("Cache-Control" to "no-store"),
                    body = ByteArrayInputStream(bytes),
                )
            }

            return GameResourceResponse(
                statusCode = status,
                reason = connection.responseMessage ?: "",
                mimeType = mime,
                encoding = charset,
                headers = passthrough,
                body = raw,
            )
        } catch (error: Exception) {
            AppLogStore.emit(
                source = "android",
                level = "WARN",
                category = "game.resource",
                event = "online_resource_fetch_failed",
                outcome = "failed",
                code = "online_fetch_failed",
                context = mapOf("path" to url, "error" to (error.message ?: error.javaClass.simpleName)),
            )
            return error(502, "Bad Gateway")
        }
    }

    /** 把桥脚本插到 `</head>` 之前；没有 head 就插到最前面。 */
    private fun injectBridge(html: String): String? {
        val index = html.indexOf("</head>", ignoreCase = true)
        return if (index >= 0) {
            html.substring(0, index) + bridgeTag + html.substring(index)
        } else {
            bridgeTag + html
        }
    }

    private fun error(status: Int, reason: String, headers: Map<String, String> = emptyMap()) =
        GameResourceResponse(
            statusCode = status,
            reason = reason,
            mimeType = "text/plain",
            encoding = "UTF-8",
            headers = headers,
            body = ByteArrayInputStream(reason.toByteArray(StandardCharsets.UTF_8)),
        )

    companion object {
        /**
         * 从桥脚本里取出 `base` 与 `token`。
         *
         * 令牌不经过会话 JSON 再传一遍：桥文件本来就在应用私有目录里，
         * 少一处拷贝就少一处泄漏面。
         */
        fun readBridgeCredentials(bridgeFile: File): Pair<String, String>? {
            val script = runCatching { bridgeFile.readText() }.getOrNull() ?: return null
            val base = Regex("""base\s*:\s*"([^"]+)"""").find(script)?.groupValues?.get(1)
            val token = Regex("""token\s*:\s*"([^"]+)"""").find(script)?.groupValues?.get(1)
            if (base.isNullOrBlank() || token.isNullOrBlank()) return null
            return base.trimEnd('/') to token
        }

        /**
         * 原生链路（心跳、在线资源代理）用的凭据：优先读宿主专用的
         * [GameActivity.NATIVE_TOKEN_FILE_NAME]（长期设备令牌），
         * 没有时回退到注入脚本里的短时会话令牌。
         *
         * 为什么要分开：页面里的会话令牌 3 小时过期，若原生也用它，
         * 长局心跳会在中途 401；设备令牌不注入页面，JS 读不到。
         */
        fun readHostCredentials(appRoot: String, bridgeFile: File): Pair<String, String>? {
            val bridge = readBridgeCredentials(bridgeFile) ?: return null
            val nativeFile = File(appRoot, GameActivity.NATIVE_TOKEN_FILE_NAME)
            val hostToken = runCatching {
                JSONObject(nativeFile.readText()).optString("token")
            }.getOrNull()?.takeIf { it.isNotBlank() }
            return bridge.first to (hostToken ?: bridge.second)
        }

        fun joinPath(base: String, path: String): String {
            val normalized = if (path.startsWith("/")) path else "/$path"
            return base.trimEnd('/') + normalized
        }

        fun mimeFor(path: String): String {
            val ext = path.substringAfterLast('.', "").lowercase(Locale.US)
            return when (ext) {
                "html", "htm" -> "text/html"
                "js", "mjs" -> "application/javascript"
                "json" -> "application/json"
                "css" -> "text/css"
                "wasm" -> "application/wasm"
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "svg" -> "image/svg+xml"
                "mp3" -> "audio/mpeg"
                "ogg" -> "audio/ogg"
                else -> "application/octet-stream"
            }
        }
    }
}
