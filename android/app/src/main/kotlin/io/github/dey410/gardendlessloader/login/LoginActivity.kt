package io.github.dey410.gardendlessloader.login

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import java.util.Locale

/**
 * Shows the save server's authentik-protected token page inside the app.
 *
 * The page posts the token to `window.GardendlessBridge.onToken(...)` once the
 * user has signed in; that result is handed back to `MainActivity`, which
 * answers the Flutter `cloud_login` channel. Nothing is typed or pasted.
 *
 * The WebView only follows links on the server host it was opened for. Any
 * other link leaves the app and opens in the system browser, so the embedded
 * session can never be steered onto an unrelated origin.
 */
class LoginActivity : Activity() {
    private lateinit var webView: WebView
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView

    private var pageHost: String = ""
    private var baseUrl: String = ""

    /**
     * Hosts the sign-in flow may visit inside the WebView.
     *
     * The authentik UI usually lives on its own host (a different subdomain from
     * the save server), and the flow bounces there and back. Without this set
     * every hop would be handed to the system browser, the flow would finish
     * outside the app and the token bridge would never fire.
     */
    private val loginHosts = mutableSetOf<String>()
    private var delivered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val requestedBase = intent.getStringExtra(EXTRA_BASE_URL)?.trim().orEmpty()
        val requestedPage = intent.getStringExtra(EXTRA_PAGE_URL)?.trim().orEmpty()
        val normalizedBase = LoginTokenPayload.resolveBase(requestedBase, requestedBase)
        val page = runCatching { Uri.parse(requestedPage) }.getOrNull()
        if (normalizedBase == null || page?.host.isNullOrEmpty() ||
            !page.host.equals(Uri.parse(normalizedBase).host, ignoreCase = true) ||
            !LoginTokenPayload.isAllowedScheme(page.scheme, page.host.orEmpty())
        ) {
            finishWithError(ERROR_INVALID_BASE, "登录地址无效，无法打开登录页")
            return
        }
        baseUrl = normalizedBase
        pageHost = Uri.parse(normalizedBase).host.orEmpty().lowercase(Locale.ROOT)
        intent.getStringArrayListExtra(EXTRA_ALLOWED_HOSTS)?.forEach { raw ->
            val cleaned = raw.trim().lowercase(Locale.ROOT)
            if (cleaned.isNotEmpty()) loginHosts.add(cleaned)
        }
        loginHosts.add(pageHost)

        buildContent(intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() } ?: defaultTitle())
        configureWebView()
        webView.loadUrl(requestedPage)
    }

    private fun buildContent(title: String) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
        }
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(10), dp(8), dp(10))
            setBackgroundColor(Color.parseColor("#F4F1E8"))
        }
        val heading = TextView(this).apply {
            text = title
            setTextColor(Color.parseColor("#2B2B23"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
        }
        header.addView(
            heading,
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
        val cancel = TextView(this).apply {
            text = if (isChinese()) "取消" else "Cancel"
            setTextColor(Color.parseColor("#2F6B3A"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            isClickable = true
            setOnClickListener { finish() }
        }
        header.addView(cancel)
        root.addView(header)

        progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            max = 100
            progress = 0
            isIndeterminate = false
        }
        root.addView(progress, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(3)))

        webView = WebView(this)
        root.addView(
            webView,
            LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f),
        )

        status = TextView(this).apply {
            setTextColor(Color.parseColor("#6B6B5F"))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding(dp(16), dp(8), dp(16), dp(8))
            visibility = View.GONE
        }
        root.addView(status)

        setContentView(root)
    }

    private fun configureWebView() {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            // The token page is always served over HTTPS; never allow a
            // downgrade to plain HTTP inside the embedded session.
            mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            // authentik keeps its session cookie on the flow origin, which the
            // WebView treats as third-party during the redirect back.
            setAcceptThirdPartyCookies(webView, true)
        }
        webView.addJavascriptInterface(TokenBridge(this), BRIDGE_NAME)
        webView.webViewClient = LoginClient()
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                super.onProgressChanged(view, newProgress)
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) View.GONE else View.VISIBLE
            }
        }
    }

    private inner class LoginClient : WebViewClient() {
        override fun shouldOverrideUrlLoading(
            view: WebView,
            request: WebResourceRequest,
        ): Boolean = intercept(request.url)

        @Deprecated("Kept for API levels below 24")
        override fun shouldOverrideUrlLoading(view: WebView, url: String?): Boolean {
            val uri = url?.let { runCatching { Uri.parse(it) }.getOrNull() } ?: return false
            return intercept(uri)
        }

        override fun onPageFinished(view: WebView, url: String?) {
            super.onPageFinished(view, url)
            progress.visibility = View.GONE
            // authentik's session cookie must survive the activity finishing.
            CookieManager.getInstance().flush()
        }

        override fun onReceivedError(
            view: WebView,
            request: WebResourceRequest,
            error: WebResourceError,
        ) {
            super.onReceivedError(view, request, error)
            if (request.isForMainFrame) {
                setStatus(if (isChinese()) "无法加载登录页，请检查网络后重试" else "Could not load the sign-in page; check the network and retry")
            }
        }

        override fun onReceivedHttpError(
            view: WebView,
            request: WebResourceRequest,
            errorResponse: WebResourceResponse,
        ) {
            super.onReceivedHttpError(view, request, errorResponse)
            if (request.isForMainFrame && errorResponse.statusCode >= 400) {
                setStatus(
                    if (isChinese()) {
                        "登录页返回 HTTP ${errorResponse.statusCode}"
                    } else {
                        "The sign-in page returned HTTP ${errorResponse.statusCode}"
                    },
                )
            }
        }
    }

    private fun intercept(uri: Uri): Boolean {
        val host = uri.host?.lowercase(Locale.ROOT) ?: return true
        // The sign-in flow legitimately hops to the identity provider's host;
        // only hosts discovered from the redirect chain are allowed in.
        if (host != pageHost && host !in loginHosts) {
            openExternally(uri)
            return true
        }
        if (!LoginTokenPayload.isAllowedScheme(uri.scheme, host)) {
            setStatus(if (isChinese()) "已阻止不安全的跳转" else "Blocked an insecure navigation")
            return true
        }
        return false
    }

    /** Links off the server host belong to the system browser. */
    private fun openExternally(uri: Uri) {
        if (uri.scheme != "http" && uri.scheme != "https" &&
            uri.scheme != "mailto" && uri.scheme != "tel"
        ) {
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        } catch (_: ActivityNotFoundException) {
            setStatus(if (isChinese()) "无法打开外部链接" else "Could not open the external link")
        } catch (_: SecurityException) {
            setStatus(if (isChinese()) "无法打开外部链接" else "Could not open the external link")
        }
    }

    /**
     * Called from the page's JavaScript thread; the token is only accepted
     * while the top-level document is still on the server host.
     */
    internal fun deliverTokenFromBridge(payload: String) {
        if (delivered) return
        val currentHost = webView.url
            ?.let { runCatching { Uri.parse(it).host }.getOrNull() }
            ?.lowercase(Locale.ROOT)
        if (currentHost != pageHost) {
            setStatus(if (isChinese()) "登录页已离开服务器，令牌已被忽略" else "The page left the server; the token was ignored")
            return
        }
        val parsed = LoginTokenPayload.parse(payload)
        if (parsed == null) {
            setStatus(if (isChinese()) "登录页返回的令牌无效，请重试" else "The sign-in page returned an invalid token; try again")
            return
        }
        val base = LoginTokenPayload.resolveBase(parsed.base, baseUrl)
        if (base == null) {
            setStatus(if (isChinese()) "登录页返回的服务器地址无效" else "The sign-in page returned an invalid server address")
            return
        }
        delivered = true
        setResult(
            RESULT_OK,
            Intent()
                .putExtra(EXTRA_TOKEN, parsed.token)
                .putExtra(EXTRA_ACCOUNT_ID, parsed.id.orEmpty())
                .putExtra(EXTRA_BASE_URL, base),
        )
        finish()
    }

    private fun finishWithError(code: String, message: String) {
        if (delivered) return
        delivered = true
        setResult(
            RESULT_CANCELED,
            Intent().putExtra(EXTRA_ERROR_CODE, code).putExtra(EXTRA_ERROR_MESSAGE, message),
        )
        finish()
    }

    private fun setStatus(message: String) {
        status.text = message
        status.visibility = View.VISIBLE
    }

    private fun isChinese(): Boolean =
        Locale.getDefault().language.lowercase(Locale.ROOT).startsWith("zh")

    private fun defaultTitle(): String =
        if (isChinese()) "登录云存档服务器" else "Sign in to the save server"

    private fun dp(value: Int): Int =
        TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            value.toFloat(),
            resources.displayMetrics,
        ).toInt()

    override fun onDestroy() {
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.removeJavascriptInterface(BRIDGE_NAME)
            webView.webViewClient = WebViewClient()
            webView.destroy()
        }
        super.onDestroy()
    }

    /**
     * The object the token page calls as `window.GardendlessBridge`.
     *
     * Methods reachable from JavaScript must be annotated; without
     * `@JavascriptInterface` the WebView exposes nothing on API 17+.
     */
    class TokenBridge(private val activity: LoginActivity) {
        @JavascriptInterface
        fun onToken(payload: String) {
            activity.runOnUiThread { activity.deliverTokenFromBridge(payload) }
        }
    }

    companion object {
        const val EXTRA_BASE_URL = "io.github.dey410.gardendlessloader.extra.LOGIN_BASE_URL"
        const val EXTRA_PAGE_URL = "io.github.dey410.gardendlessloader.extra.LOGIN_PAGE_URL"
        const val EXTRA_TITLE = "io.github.dey410.gardendlessloader.extra.LOGIN_TITLE"

        /** Extra hosts (e.g. the identity provider) the flow may visit in-app. */
        const val EXTRA_ALLOWED_HOSTS = "io.github.dey410.gardendlessloader.extra.LOGIN_ALLOWED_HOSTS"
        const val EXTRA_TOKEN = "io.github.dey410.gardendlessloader.extra.LOGIN_TOKEN"
        const val EXTRA_ACCOUNT_ID = "io.github.dey410.gardendlessloader.extra.LOGIN_ACCOUNT_ID"
        const val EXTRA_ERROR_CODE = "io.github.dey410.gardendlessloader.extra.LOGIN_ERROR_CODE"
        const val EXTRA_ERROR_MESSAGE = "io.github.dey410.gardendlessloader.extra.LOGIN_ERROR_MESSAGE"
        const val ERROR_INVALID_BASE = "login_invalid_base"

        /** JavaScript name of the bridge, matching the server's token page. */
        const val BRIDGE_NAME = "GardendlessBridge"
    }
}
