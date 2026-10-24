package io.github.dey410.gardendlessloader.login

import android.net.Uri

/**
 * The JSON the save server's token page hands to `window.GardendlessBridge`:
 *
 * ```json
 * {"token":"...","id":"...","base":"https://..."}
 * ```
 *
 *Parsing is separated from the WebView so a broken payload can be rejected
 * without finishing the sign-in screen, and so nothing here trusts the page
 * more than it has to: the token must look like an opaque credential and the
 * base URL must stay on the host the launcher opened the page on.
 */
object LoginTokenPayload {
    /** Opaque device token: printable ASCII, no whitespace, bounded length. */
    private val tokenPattern = Regex("^[A-Za-z0-9._~+/=-]{8,4096}$")

    data class Token(
        /** `pvz_…` credential; never logged by the launcher. */
        val token: String,
        /** Account identifier the server chose to publish; may be empty. */
        val id: String?,
        /** Origin the server says it issued the token for; may be empty. */
        val base: String?,
    )

    /** Returns the token, or null when [raw] is not a usable payload. */
    fun parse(raw: String?): Token? {
        val text = raw?.trim().orEmpty()
        if (text.isEmpty() || text.length > maxPayloadChars) return null
        val json = runCatching { org.json.JSONObject(text) }.getOrNull() ?: return null
        val token = json.optString("token").trim()
        if (!tokenPattern.matches(token)) return null
        val id = json.optString("id").trim().takeIf { it.isNotEmpty() && it.length <= 256 }
        val base = json.optString("base").trim().takeIf { it.isNotEmpty() }
        return Token(token = token, id = id, base = base)
    }

    /**
     * The origin the token belongs to. A payload may name its own base, but it
     * is only accepted when it is the same host and port the sign-in page was
     * opened on; otherwise [fallbackBase] wins.
     */
    fun resolveBase(candidate: String?, fallbackBase: String): String? {
        val fallback = runCatching { Uri.parse(fallbackBase) }.getOrNull() ?: return null
        val fallbackHost = fallback.host?.takeIf { it.isNotEmpty() } ?: return null
        if (!isAllowedScheme(fallback.scheme, fallbackHost)) return null

        val uri = candidate
            ?.takeIf { it.isNotEmpty() }
            ?.let { runCatching { Uri.parse(it) }.getOrNull() }
            ?: fallback
        val host = uri.host?.takeIf { it.isNotEmpty() } ?: return null
        if (!host.equals(fallbackHost, ignoreCase = true)) return null
        if (!isAllowedScheme(uri.scheme, host)) return null
        if (!uri.userInfo.isNullOrEmpty() || uri.query != null || uri.fragment != null) {
            return null
        }
        if (effectivePort(uri) != effectivePort(fallback)) return null
        return uri.toString().substringBefore('?').substringBefore('#').trimEnd('/')
    }

    /** HTTPS anywhere; plain HTTP only for a loopback development server. */
    fun isAllowedScheme(scheme: String?, host: String): Boolean = when (scheme) {
        "https" -> true
        "http" -> host == "localhost" || host == "127.0.0.1" || host == "::1"
        else -> false
    }

    private fun effectivePort(uri: Uri): Int = when {
        uri.port != -1 -> uri.port
        uri.scheme == "https" -> 443
        uri.scheme == "http" -> 80
        else -> -1
    }

    private const val maxPayloadChars = 8192
}
