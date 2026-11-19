package com.lonx.lyrico.remote.cloud115

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.io.IOException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException

/**
 * 115 QR-code login (blocking; call off the main thread).
 *
 * Flow (SheltonZhu/115driver qrcode.go, ChenyangGao/p115client p115qrcode):
 *  1. [start] -> [Session]; render [Session.qrContent] as a QR code in the UI.
 *  2. call [poll] repeatedly (it long-polls server side, ~tens of seconds) until it returns
 *     [Status.CONFIRMED], [Status.EXPIRED] or [Status.CANCELLED]; or use [awaitCookie].
 *  3. [login] exchanges the confirmed session for cookies; returns `UID=..; CID=..; SEID=..; KID=..`.
 *
 * [app] is the device slot the new session occupies. 115 allows one session per slot, so logging in
 * as "android"/"ios" would kick the user's phone app. Default "alipaymini" (115生活 支付宝小程序) is the
 * default of p115client and only kicks a session of that same mini-program.
 */
class Cloud115QrLogin(
    private val app: String = DEFAULT_APP,
    client: OkHttpClient? = null,
    private val endpoints: Cloud115Endpoints = Cloud115Endpoints(),
) {
    data class Session(val uid: String, val time: Long, val sign: String, val qrContent: String)

    enum class Status { WAITING, SCANNED, CONFIRMED, EXPIRED, CANCELLED }

    private val http = Cloud115Http(client ?: Cloud115Const.defaultClient(), cookie = "")

    /** Requests a new QR token. */
    fun start(): Session {
        val o = http.getJson(endpoints.qrToken.toHttpUrl(), "获取二维码")
        if (!J.truthy(o.opt("state"))) throw IOException("获取二维码失败: ${J.errorMessage(o)}")
        val d = o.optJSONObject("data") ?: throw IOException("获取二维码失败: 缺少 data")
        val uid = J.str(d, "uid")
        if (uid.isEmpty()) throw IOException("获取二维码失败: 缺少 uid")
        val content = J.str(d, "qrcode").ifEmpty { "https://115.com/scan/dg-$uid" }
        return Session(uid, J.long(d, "time"), J.str(d, "sign"), content)
    }

    /** One status check. Blocks while the server long-polls; a read timeout counts as [Status.WAITING]. */
    fun poll(session: Session): Status {
        val url = endpoints.qrStatus.toHttpUrl().newBuilder()
            .addQueryParameter("uid", session.uid)
            .addQueryParameter("time", session.time.toString())
            .addQueryParameter("sign", session.sign)
            .addQueryParameter("_", (System.currentTimeMillis() / 1000).toString())
            .build()
        val o = try {
            http.getJson(url, "查询扫码状态")
        } catch (e: SocketTimeoutException) {
            return Status.WAITING
        } catch (e: InterruptedIOException) {
            if (Thread.currentThread().isInterrupted) throw e
            return Status.WAITING
        }
        return parseStatus(o)
    }

    /** Exchanges a confirmed session for the cookie string. */
    fun login(session: Session): String {
        val url = endpoints.qrLogin.format(app).toHttpUrl()
        val o = http.postFormJson(url, listOf("account" to session.uid, "app" to app), "扫码登录")
        return parseLoginCookie(o)
    }

    /**
     * Convenience loop: polls until confirmed then logs in. Returns the cookie, or null if the code
     * expired/was cancelled, [isCancelled] returned true, or [timeoutMs] elapsed.
     */
    fun awaitCookie(
        session: Session,
        timeoutMs: Long = 5 * 60_000L,
        isCancelled: () -> Boolean = { false },
        onStatus: (Status) -> Unit = {},
    ): String? {
        val deadline = System.currentTimeMillis() + timeoutMs
        var last: Status? = null
        while (!isCancelled() && System.currentTimeMillis() < deadline) {
            val s = poll(session)
            if (s != last) { onStatus(s); last = s }
            when (s) {
                Status.CONFIRMED -> return login(session)
                Status.EXPIRED, Status.CANCELLED -> return null
                else -> Thread.sleep(POLL_GAP_MS)
            }
        }
        return null
    }

    companion object {
        const val DEFAULT_APP = "alipaymini"
        private const val POLL_GAP_MS = 1000L

        internal fun parseStatus(o: JSONObject): Status {
            val d = o.optJSONObject("data")
            if (d != null && d.has("status")) {
                return when (J.long(d, "status")) {
                    0L -> Status.WAITING
                    1L -> Status.SCANNED
                    2L -> Status.CONFIRMED
                    -1L -> Status.EXPIRED
                    -2L -> Status.CANCELLED
                    else -> Status.WAITING
                }
            }
            if (!J.truthy(o.opt("state"))) {
                val msg = J.errorMessage(o)
                if (msg.contains("过期") || msg.contains("expire", true)) return Status.EXPIRED
                throw IOException("查询扫码状态失败: $msg")
            }
            return Status.WAITING
        }

        internal fun parseLoginCookie(o: JSONObject): String {
            if (!J.truthy(o.opt("state"))) {
                throw IOException("扫码登录失败: ${J.errorMessage(o).ifEmpty { "code ${J.errorCode(o)}" }}")
            }
            val c = o.optJSONObject("data")?.optJSONObject("cookie")
                ?: throw IOException("扫码登录失败: 响应缺少 cookie")
            val cred = Cloud115Credential(J.str(c, "UID"), J.str(c, "CID"), J.str(c, "SEID"), J.str(c, "KID"))
            if (cred.uid.isEmpty() || cred.cid.isEmpty() || cred.seid.isEmpty()) {
                throw IOException("扫码登录失败: cookie 不完整")
            }
            return cred.toCookie()
        }
    }
}
