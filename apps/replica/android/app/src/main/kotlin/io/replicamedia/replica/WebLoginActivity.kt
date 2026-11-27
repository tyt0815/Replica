package io.replicamedia.replica

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.view.WindowManager
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import org.json.JSONObject
import org.json.JSONTokener

class WebLoginActivity : Activity() {
    private lateinit var browser: WebView
    private var desktop = false
    private var checking = false

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)

        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val address = TextView(this).apply { setPadding(24, 24, 24, 16) }
        val connect = Button(this).apply {
            text = "로그인 연결 확인"
            isAllCaps = false
            setTextColor(Color.WHITE)
            backgroundTintList = ColorStateList.valueOf(Color.rgb(255, 0, 53))
        }

        browser = WebView(this)
        browser.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
        }
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(browser, true)
        }
        browser.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!request.isForMainFrame) return false
                val host = request.url.host.orEmpty()
                val allowed = request.url.scheme == "https" && (
                    host == "youtube.com" || host.endsWith(".youtube.com") ||
                    host == "google.com" || host.endsWith(".google.com") ||
                    host == "accounts.google.co.kr"
                )
                return !allowed
            }

            override fun onPageFinished(view: WebView, url: String?) {
                address.text = Uri.parse(url.orEmpty()).host.orEmpty()
                CookieManager.getInstance().flush()
                inspectSession(false)
            }
        }
        connect.setOnClickListener { inspectSession(true) }

        layout.addView(address)
        layout.addView(browser, LinearLayout.LayoutParams(-1, 0, 1f))
        layout.addView(connect)
        setContentView(layout)
        browser.loadUrl("https://m.youtube.com/signin?app=mobile&persist_app=1")
    }

    private fun inspectSession(manual: Boolean) {
        if (checking || isFinishing || isDestroyed) return
        val currentUrl = browser.url.orEmpty()
        val uri = Uri.parse(currentUrl)
        val host = uri.host
        if (uri.scheme != "https" || host !in setOf("m.youtube.com", "www.youtube.com")) {
            if (manual) {
                Toast.makeText(this, "Google 로그인을 먼저 완료하세요.", Toast.LENGTH_SHORT).show()
            }
            return
        }
        checking = true
        browser.evaluateJavascript(
            """
            (function(){
                var cfg = window.ytcfg;
                if (!cfg) return null;
                function get(k){
                    var v = typeof cfg.get === 'function' ? cfg.get(k) : undefined;
                    return v == null && cfg.data_ ? cfg.data_[k] : v;
                }
                var client = (get('INNERTUBE_CONTEXT') || {}).client || {};
                return JSON.stringify({
                    logged_in: get('LOGGED_IN') === true,
                    client_version: get('INNERTUBE_CLIENT_VERSION') || client.clientVersion || '',
                    visitor_data: get('VISITOR_DATA') || client.visitorData || '',
                    auth_user: Number(get('SESSION_INDEX') || 0),
                    delegated_session_id: get('DELEGATED_SESSION_ID') || null
                });
            })()
            """.trimIndent(),
        ) { raw ->
            checking = false
            if (isFinishing || isDestroyed) return@evaluateJavascript
            try {
                val decoded = JSONTokener(raw).nextValue() as? String
                val config = JSONObject(decoded ?: "{}")
                val cookies = CookieManager.getInstance()
                val cookie = cookies.getCookie(ORIGIN).orEmpty()
                val hasAuthCookie = cookie.contains("SAPISID=") || cookie.contains("__Secure-3PAPISID=")
                val loggedIn = config.optBoolean("logged_in")
                val clientVersion = config.optString("client_version")
                val visitorData = config.optString("visitor_data")

                if (!desktop && (loggedIn || hasAuthCookie) && host == "m.youtube.com") {
                    desktop = true
                    browser.settings.userAgentString = DESKTOP_UA
                    browser.loadUrl("$ORIGIN/?app=desktop&persist_app=1")
                    return@evaluateJavascript
                }
                if (loggedIn && hasAuthCookie && clientVersion.isNotBlank() && visitorData.isNotBlank()) {
                    cookies.flush()
                    getSharedPreferences(PREFS, MODE_PRIVATE)
                        .edit()
                        .putString("config", config.toString())
                        .apply()
                    setResult(RESULT_OK)
                    finish()
                } else if (manual) {
                    Toast.makeText(this, "YouTube 세션 정보를 확인하는 중입니다. 잠시 후 다시 눌러주세요.", Toast.LENGTH_SHORT).show()
                }
            } catch (_: Exception) {
                if (manual) {
                    Toast.makeText(this, "로그인 정보를 읽지 못했습니다.", Toast.LENGTH_SHORT).show()
                }
            }
        }
    }

    companion object {
        const val ORIGIN = "https://www.youtube.com"
        const val PREFS = "replica_music_web_session"
        private const val DESKTOP_UA =
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

        fun readSession(context: Context): Map<String, Any?>? {
            val raw = context.getSharedPreferences(PREFS, MODE_PRIVATE).getString("config", null)
                ?: return null
            val cookie = CookieManager.getInstance().getCookie(ORIGIN).orEmpty()
            if (!cookie.contains("SAPISID=") && !cookie.contains("__Secure-3PAPISID=")) {
                return null
            }
            return try {
                val cfg = JSONObject(raw)
                val clientVersion = cfg.optString("client_version")
                val visitorData = cfg.optString("visitor_data")
                if (clientVersion.isBlank() || visitorData.isBlank()) {
                    null
                } else {
                    val delegated = if (cfg.isNull("delegated_session_id")) {
                        null
                    } else {
                        cfg.optString("delegated_session_id").takeIf { it.isNotBlank() && it != "null" }
                    }
                    mapOf(
                        "cookie" to cookie,
                        "client_version" to clientVersion,
                        "visitor_data" to visitorData,
                        "auth_user" to cfg.optInt("auth_user", 0),
                        "delegated_session_id" to delegated,
                    )
                }
            } catch (_: Exception) {
                null
            }
        }

        fun clearSession(context: Context) {
            context.getSharedPreferences(PREFS, MODE_PRIVATE).edit().clear().apply()
            CookieManager.getInstance().removeAllCookies(null)
            CookieManager.getInstance().flush()
            WebStorage.getInstance().deleteAllData()
        }
    }
}
