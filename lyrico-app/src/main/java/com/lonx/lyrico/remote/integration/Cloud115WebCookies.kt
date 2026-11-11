package com.lonx.lyrico.remote.integration

import android.webkit.CookieManager
import com.lonx.lyrico.remote.cloud115.Cloud115Credential

/**
 * Lyrico Mod: helpers for the 115 web (account/password) login, which runs 115's own login page in an
 * in-app WebView and picks the session cookies out of the WebView [CookieManager].
 *
 * The cookies are copied into our encrypted store; the WebView's copies are cleared before the page is
 * opened and again when the login screen closes, so they never outlive the login.
 */
object Cloud115WebCookies {
    /** 115's web login page (shows QR + "账号登录"; the desktop UA is needed for the password form). */
    const val LOGIN_URL = "https://115.com/?mode=login"

    /** Desktop Chrome UA: the mobile site of 115 pushes the app instead of offering a password form. */
    const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /** Hosts whose cookie jars are read / cleared (UID/CID/SEID/KID are set on `.115.com`). */
    private val HOSTS = listOf(
        "https://115.com/",
        "https://www.115.com/",
        "https://passport.115.com/",
        "https://passportapi.115.com/",
        "https://webapi.115.com/",
        "https://my.115.com/",
        "https://proapi.115.com/",
        "https://captchaapi.115.com/",
        "https://qrcodeapi.115.com/",
    )

    private val SESSION_KEYS = listOf("UID", "CID", "SEID", "KID")

    /** Reads the 115 session cookie from the WebView, or null when UID/CID/SEID are not all set yet. */
    fun readSession(manager: CookieManager = CookieManager.getInstance()): String? {
        val map = LinkedHashMap<String, String>()
        for (host in HOSTS) {
            val raw = manager.getCookie(host) ?: continue
            for (item in raw.split(';')) {
                val idx = item.indexOf('=')
                if (idx <= 0) continue
                val name = item.substring(0, idx).trim()
                val value = item.substring(idx + 1).trim()
                if (name.uppercase() in SESSION_KEYS && value.isNotEmpty()) map.putIfAbsent(name.uppercase(), value)
            }
        }
        val cookie = SESSION_KEYS.mapNotNull { k -> map[k]?.let { "$k=$it" } }.joinToString("; ")
        return Cloud115Credential.parse(cookie)?.toCookie()
    }

    /** Expires every cookie the WebView holds for the 115 hosts (other sites' cookies are kept). */
    fun clear(manager: CookieManager = CookieManager.getInstance()) {
        for (host in HOSTS) {
            val raw = manager.getCookie(host) ?: continue
            val names = raw.split(';').mapNotNull { item ->
                val idx = item.indexOf('=')
                if (idx <= 0) null else item.substring(0, idx).trim()
            }.distinct()
            for (name in names) {
                // Domain cookie (`.115.com`) and host-only cookie variants; Path "/" covers 115's cookies.
                manager.setCookie(host, "$name=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/; Domain=.115.com")
                manager.setCookie(host, "$name=; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/")
            }
        }
        manager.flush()
    }
}
