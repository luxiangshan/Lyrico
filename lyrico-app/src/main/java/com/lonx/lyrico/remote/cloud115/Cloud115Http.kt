package com.lonx.lyrico.remote.cloud115

import com.lonx.lyrico.remote.RemoteAuthException
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * All 115 endpoints. Overridable so unit tests can point them at a MockWebServer.
 * Values follow SheltonZhu/115driver pkg/driver/api.go.
 */
data class Cloud115Endpoints(
    val qrToken: String = "https://qrcodeapi.115.com/api/1.0/web/1.0/token",
    val qrStatus: String = "https://qrcodeapi.115.com/get/status/",
    /** `%s` = login app, e.g. alipaymini. */
    val qrLogin: String = "https://passportapi.115.com/app/1.0/%s/1.0/login/qrcode",
    val statusCheck: String = "https://my.115.com/?ct=guide&ac=status",
    val files: String = "https://webapi.115.com/files",
    val rename: String = "https://webapi.115.com/files/batch_rename",
    val delete: String = "https://webapi.115.com/rb/delete",
    val downUrl: String = "https://proapi.115.com/app/chrome/downurl",
    val uploadInfo: String = "https://proapi.115.com/app/uploadinfo",
    val uploadInit: String = "https://uplb.115.com/4.0/initupload.php",
    val ossToken: String = "https://uplb.115.com/3.0/gettoken.php",
    /** Virtual-hosted OSS object base; `%s` = bucket. */
    val ossHost: String = "https://%s.oss-cn-shenzhen.aliyuncs.com",
    /** Tests only: path-style base (`<base>/<bucket>/<object>`) instead of [ossHost]. */
    val ossPathStyleBase: String? = null,
) {
    fun ossObjectUrl(bucket: String, objectKey: String): HttpUrl {
        val b = ossPathStyleBase
        val base = if (b != null) b.trimEnd('/').toHttpUrl().newBuilder().addPathSegment(bucket)
        else ossHost.format(bucket).toHttpUrl().newBuilder()
        for (seg in objectKey.split('/')) if (seg.isNotEmpty()) base.addPathSegment(seg)
        return base.build()
    }
}

internal object Cloud115Const {
    const val APP_VER = "27.0.5.7"
    /** UA OpenList's 115 driver uses for every API call (proapi rejects plain browser UAs). */
    const val UA = "Mozilla/5.0 115Browser/$APP_VER"
    const val OSS_UA = "aliyun-sdk-android/2.9.1"
    const val AUTH_EXPIRED_MSG = "115 登录已失效，请重新扫码"

    /** 115driver error.go: 99/990001 not login; 40101035 kicked out; 40101037 session exited. */
    val AUTH_CODES = setOf(99L, 990001L, 990002L, 40101035L, 40101037L, 40101032L)

    fun defaultClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS) // QR status endpoint long-polls
        .writeTimeout(120, TimeUnit.SECONDS)
        .connectionPool(okhttp3.ConnectionPool(8, 5, TimeUnit.MINUTES))
        .build()
}

/** JSON helpers tolerant of 115's mixed bool/int/string fields. */
internal object J {
    fun parse(body: String, what: String): JSONObject = try {
        JSONObject(body)
    } catch (e: JSONException) {
        throw IOException("$what: 非 JSON 响应: ${body.take(200)}", e)
    }

    fun truthy(v: Any?): Boolean = when (v) {
        is Boolean -> v
        is Number -> v.toLong() != 0L
        is String -> v == "1" || v.equals("true", true)
        else -> false
    }

    fun long(o: JSONObject, vararg keys: String): Long {
        for (k in keys) {
            val v = o.opt(k) ?: continue
            when (v) {
                is Number -> return v.toLong()
                is String -> v.trim().toLongOrNull()?.let { return it }
            }
        }
        return 0L
    }

    fun str(o: JSONObject, vararg keys: String): String {
        for (k in keys) {
            val v = o.opt(k)
            if (v != null && v != JSONObject.NULL) {
                val s = v.toString()
                if (s.isNotEmpty()) return s
            }
        }
        return ""
    }

    fun errorCode(o: JSONObject): Long = long(o, "errno", "errNo", "errcode", "code", "statuscode")

    fun errorMessage(o: JSONObject): String = str(o, "error", "msg", "message", "statusmsg", "errtype")

    /** Throws [RemoteAuthException] when the payload says the cookie is no longer valid. */
    fun checkAuth(o: JSONObject) {
        val ok = truthy(o.opt("state"))
        val code = errorCode(o)
        val msg = errorMessage(o)
        if (code in Cloud115Const.AUTH_CODES || (!ok && (msg.contains("登录") || msg.contains("login", true)))) {
            throw RemoteAuthException(Cloud115Const.AUTH_EXPIRED_MSG)
        }
    }

    /** `state` true or throws (auth-aware). */
    fun requireOk(o: JSONObject, what: String): JSONObject {
        checkAuth(o)
        if (!truthy(o.opt("state"))) {
            val msg = errorMessage(o).ifEmpty { "未知错误" }
            throw Cloud115Exception("$what 失败: $msg (code ${errorCode(o)})", errorCode(o))
        }
        return o
    }
}

class Cloud115Exception(message: String, val code: Long = 0) : IOException(message)

/** Thin OkHttp wrapper that attaches the 115 cookie and UA. */
internal class Cloud115Http(
    val client: OkHttpClient,
    @Volatile var cookie: String,
    val userAgent: String = Cloud115Const.UA,
) {
    fun newRequest(url: HttpUrl): Request.Builder = Request.Builder().url(url)
        .header("User-Agent", userAgent)
        .header("Accept", "application/json, text/plain, */*")
        .also { if (cookie.isNotBlank()) it.header("Cookie", cookie) }

    fun execute(request: Request): Response = client.newCall(request).execute()

    fun getJson(url: HttpUrl, what: String): JSONObject =
        execute(newRequest(url).get().build()).use { readJson(it, what) }

    fun postFormJson(url: HttpUrl, form: List<Pair<String, String>>, what: String): JSONObject {
        val body = FormBody.Builder().apply { form.forEach { (k, v) -> add(k, v) } }.build()
        return execute(newRequest(url).post(body).build()).use { readJson(it, what) }
    }

    fun readJson(resp: Response, what: String): JSONObject {
        val text = resp.body.string()
        val trimmed = text.trimStart()
        if (!trimmed.startsWith("{")) {
            val finalUrl = resp.request.url.toString()
            if (resp.code == 401 && what != "上传初始化" || finalUrl.contains("login", true) || finalUrl.contains("passport", true)) {
                throw RemoteAuthException(Cloud115Const.AUTH_EXPIRED_MSG)
            }
            throw IOException("$what: HTTP ${resp.code} ${text.take(200)}")
        }
        return J.parse(text, what)
    }
}

/** Parsed `UID=..; CID=..; SEID=..; KID=..` credential. */
data class Cloud115Credential(val uid: String, val cid: String, val seid: String, val kid: String) {
    fun toCookie(): String = buildString {
        append("UID=").append(uid).append("; CID=").append(cid).append("; SEID=").append(seid)
        if (kid.isNotEmpty()) append("; KID=").append(kid)
    }

    /** First UID segment is the numeric user id (e.g. "123456_A1_1700000000"). */
    val userId: String get() = uid.substringBefore('_')

    companion object {
        /** Tolerant parse (115driver Credential.FromCookie); returns null if UID/CID/SEID missing. */
        fun parse(cookie: String): Cloud115Credential? {
            val map = HashMap<String, String>()
            for (item in cookie.split(';')) {
                val idx = item.indexOf('=')
                if (idx <= 0) continue
                map[item.substring(0, idx).trim().uppercase()] = item.substring(idx + 1).trim()
            }
            val uid = map["UID"].orEmpty()
            val cid = map["CID"].orEmpty()
            val seid = map["SEID"].orEmpty()
            if (uid.isEmpty() || cid.isEmpty() || seid.isEmpty()) return null
            return Cloud115Credential(uid, cid, seid, map["KID"].orEmpty())
        }
    }
}
