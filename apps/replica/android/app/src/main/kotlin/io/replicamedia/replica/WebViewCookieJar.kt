package io.replicamedia.replica

import android.webkit.CookieManager
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.HttpUrl

class WebViewCookieJar : CookieJar {
    private val manager: CookieManager = CookieManager.getInstance().apply { setAcceptCookie(true) }

    override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
        val u = url.toString()
        for (cookie in cookies) {
            val host = url.host
            val ownDomain = host == cookie.domain || host.endsWith(".${cookie.domain}")
            manager.setCookie(if (ownDomain) u else "https://${cookie.domain}${cookie.path}", cookie.toString())
        }
        manager.flush()
    }

    override fun loadForRequest(url: HttpUrl): List<Cookie> {
        val header = manager.getCookie(url.toString()) ?: return emptyList()
        return header.split(';').mapNotNull { pair ->
            val eq = pair.indexOf('=')
            if (eq <= 0) return@mapNotNull null
            val name = pair.substring(0, eq).trim()
            val value = pair.substring(eq + 1).trim()
            if (name.isEmpty()) null
            else Cookie.Builder().name(name).value(value).domain(url.host).build()
        }
    }

    fun youtubeCookieHeader(): String =
        manager.getCookie("https://www.youtube.com").orEmpty()
}
