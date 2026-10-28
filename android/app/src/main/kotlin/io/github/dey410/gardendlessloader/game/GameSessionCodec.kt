package io.github.dey410.gardendlessloader.game

import org.json.JSONArray
import org.json.JSONObject

/**
 * How the game viewport fits the screen. The game shows 16:10 to 17:9 without
 * distortion and its whole picture at 17:9.
 */
enum class GameScreenFit(val wireName: String) {
    /** Clamps the viewport to 16:10–17:9: trims some of the picture for smaller black bars. */
    BALANCED("balanced"),

    /** Keeps the viewport at 17:9 so the whole picture shows, with larger black bars. */
    SHOW_ALL("showAll"),

    /** Stretches the balanced viewport over the whole screen. */
    STRETCH("stretch"),
}

data class NativeGameSession(
    val sessionId: String,
    val resourceRoot: String,
    /** 启动器数据目录：存档桥文件放在这里（与资源槽分开，见 appendSaveBridge）。 */
    val appRootPath: String,
    val origin: String,
    val entryUrl: String,
    val activationGeneration: Long,
    val hasGpNext: Boolean,
    val gpNextCompatible: Boolean,
    val gpNextVersion: String?,
    val watermarkEnabled: Boolean,
    val autoCollectSunEnabled: Boolean,
    val detailedAudioDiagnosticsEnabled: Boolean = false,
    /**
     * 本次启动是否必须加载本机存档版本保护脚本。Dart 在有游戏版本时置 true，
     * 此时 guard 缺失/空白/读取失败必须失败关闭，不能无保护地打开游戏。
     * 旧 session JSON 没有该字段，默认 false（向后兼容旧启动器）。
     */
    val localSaveGuardRequired: Boolean = false,
    val renderScale: Double? = null,
    val screenFit: GameScreenFit = GameScreenFit.BALANCED,
    /** Records the touch adapter's trace into the logs. */
    val touchDiagnosticsEnabled: Boolean = false,
    /** Lines of the one-time gesture hint shown over the game; null shows none. */
    val gestureHint: List<String>? = null,
    val packageId: String = "unknown",
    val allowedRemoteHosts: Set<String>,
    val gpNextRoot: String,
    val exportTemporaryRoot: String,
) {
    val appRoot: String
        get() = appRootPath
}

object GameSessionCodec {
    const val ORIGIN = "https://appassets.androidplatform.net"

    fun decode(raw: String): NativeGameSession {
        require(raw.length <= 1024 * 1024) { "Game session is too large" }
        val json = JSONObject(raw)
        require(json.optInt("schemaVersion") == 1) { "Unsupported game session schema" }
        require(json.getString("platform") == "android") { "Game session platform mismatch" }
        val origin = json.getString("origin")
        val entryUrl = json.getString("entryUrl")
        require(origin == ORIGIN) { "Game session origin mismatch" }
        require(entryUrl.startsWith("$ORIGIN/")) { "Entry URL escaped the game origin" }
        val resourceRoot = json.requiredString("resourceRoot")
        val appRootPath = json.optionalString("appRoot")?.takeIf { it.isNotBlank() }
            ?: java.io.File(resourceRoot).parentFile?.absolutePath
            ?: throw IllegalArgumentException("Game session has no app root")
        val remoteHosts = json.optJSONArray("allowedRemoteHosts") ?: JSONArray()
        val packageId = json.optionalString("packageId") ?: "unknown"
        require(packageId == "unknown" || packageId.matches(Regex("sha256:[a-f0-9]{64}"))) { "Invalid package identity" }
        return NativeGameSession(
            sessionId = json.requiredString("sessionId"),
            resourceRoot = resourceRoot,
            appRootPath = appRootPath,
            origin = origin,
            entryUrl = entryUrl,
            activationGeneration = json.getLong("activationGeneration"),
            hasGpNext = json.getBoolean("hasGpNext"),
            gpNextCompatible = json.getBoolean("gpNextCompatible"),
            gpNextVersion = json.optionalString("gpNextVersion")?.takeIf { it.isNotBlank() },
            watermarkEnabled = json.getBoolean("watermarkEnabled"),
            autoCollectSunEnabled = json.getBoolean("autoCollectSunEnabled"),
            detailedAudioDiagnosticsEnabled = json.optBoolean("detailedAudioDiagnosticsEnabled", false),
            localSaveGuardRequired = json.optBoolean("localSaveGuardRequired", false),
            renderScale = if (json.isNull("renderScale")) null else {
                json.getDouble("renderScale").also {
                    require(it > 0) { "Invalid render scale" }
                }
            },
            screenFit = json.optString("screenFit", GameScreenFit.BALANCED.wireName).let { name ->
                requireNotNull(GameScreenFit.entries.firstOrNull { it.wireName == name }) { "Invalid screen fit" }
            },
            touchDiagnosticsEnabled = json.optBoolean("touchDiagnosticsEnabled", false),
            gestureHint = json.optJSONArray("gestureHint")?.let { lines ->
                List(lines.length()) { lines.getString(it) }
            },
            packageId = packageId,
            allowedRemoteHosts = buildSet {
                for (index in 0 until remoteHosts.length()) {
                    val host = remoteHosts.getString(index).lowercase()
                    require(isValidRemoteHost(host)) { "Invalid remote host" }
                    add(host)
                }
            },
            gpNextRoot = json.requiredString("gpNextRoot"),
            exportTemporaryRoot = json.requiredString("exportTemporaryRoot"),
        )
    }

    private fun JSONObject.requiredString(key: String): String {
        return getString(key).also { require(it.isNotBlank()) { "$key is empty" } }
    }

    /** Dart sends null for absent values, and Android's optString reads a JSON null as "null". */
    private fun JSONObject.optionalString(key: String): String? {
        return if (isNull(key)) null else getString(key)
    }
}

private fun isValidRemoteHost(host: String): Boolean {
    if (host.isEmpty() || host.length > 253) return false
    return host.split('.').all { label ->
        label.isNotEmpty() &&
            label.length <= 63 &&
            label.first().isLetterOrDigit() &&
            label.last().isLetterOrDigit() &&
            label.all { it.isLetterOrDigit() || it == '-' }
    }
}
