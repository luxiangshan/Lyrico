package com.lonx.lyrico.remote.webdav

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.time.OffsetDateTime

/**
 * OpenList / Alist v3 provider using the REST API (/api/auth/login, /api/fs/{list,get,put,rename,remove}).
 *
 * [RemoteConfig.baseUrl] is the site root ("https://host:5244", or with a sub-path if served under one).
 * A blank username means guest access: no login, no Authorization header.
 * The JWT token is cached via [credentialStore] under key [TOKEN_KEY] and refreshed once on 401/403.
 */
class OpenListStorage(
    override val config: RemoteConfig,
    private val credentialStore: RemoteCredentialStore? = null,
    baseClient: OkHttpClient = HttpSupport.defaultClient,
) : RemoteStorage {

    private val base: String = config.baseUrl.trim().trimEnd('/').also {
        require(it.startsWith("http://", true) || it.startsWith("https://", true)) {
            "OpenList address must start with http:// or https://"
        }
    }
    private val baseHost = "$base/".toHttpUrl().host
    private val client: OkHttpClient = baseClient.newBuilder().followRedirects(true).followSslRedirects(true).build()
    private val guest get() = config.username.isBlank()

    @Volatile private var token: String? = null

    // ---------------------------------------------------------------- auth

    private fun currentToken(): String? {
        if (guest) return null
        token?.let { return it }
        val cached = credentialStore?.loadExtra(config.id, TOKEN_KEY)
        if (!cached.isNullOrBlank()) { token = cached; return cached }
        return login()
    }

    @Synchronized
    private fun login(): String {
        val body = JSONObject().put("username", config.username).put("password", config.secret)
        val req = Request.Builder().url("$base/api/auth/login").post(body.toString().toRequestBody(JSON)).build()
        val json = rawCall(req, "OpenList login")
        val code = json.optInt("code", -1)
        if (code != 200) {
            token = null
            credentialStore?.saveExtra(config.id, TOKEN_KEY, null)
            val msg = message(json)
            if (code in setOf(400, 401, 403) || msg.contains("password", true) || msg.contains("user", true)) {
                throw RemoteAuthException("OpenList login failed: $msg")
            }
            throw IOException("OpenList login failed (code $code): $msg")
        }
        val t = json.optJSONObject("data")?.let { str(it, "token") }
        if (t.isNullOrEmpty()) throw IOException("OpenList login returned no token")
        token = t
        credentialStore?.saveExtra(config.id, TOKEN_KEY, t)
        return t
    }

    private fun invalidateToken() {
        token = null
        credentialStore?.saveExtra(config.id, TOKEN_KEY, null)
    }

    private fun isAuthError(httpCode: Int, json: JSONObject?): Boolean {
        if (httpCode == 401 || httpCode == 403) return true
        val c = json?.optInt("code", 200) ?: return false
        return c == 401 || c == 403
    }

    /**
     * Calls an API endpoint with the token, re-logging in once on an auth error.
     * Returns the "data" member (JSONObject.NULL possible) after checking code == 200.
     */
    private fun api(what: String, buildRequest: (token: String?) -> Request): Any? {
        var attempt = 0
        while (true) {
            val tok = currentToken()
            val req = buildRequest(tok)
            val (httpCode, json) = rawCallWithStatus(req, what)
            if (isAuthError(httpCode, json)) {
                if (!guest && attempt == 0) {
                    attempt++
                    invalidateToken()
                    login()
                    continue
                }
                val msg = json?.let { message(it) } ?: "HTTP $httpCode"
                throw RemoteAuthException(
                    if (guest) "$what: guest access denied ($msg). Enter an OpenList username and password."
                    else "$what: OpenList rejected the login ($msg)"
                )
            }
            if (json == null) throw IOException("$what failed: HTTP $httpCode (not an OpenList API response)")
            val code = json.optInt("code", -1)
            if (code != 200) throw ApiException(code, "$what failed: ${message(json)}")
            return if (json.has("data")) json.get("data") else null
        }
    }

    private fun postApi(what: String, endpoint: String, body: JSONObject): Any? = api(what) { tok ->
        Request.Builder().url("$base$endpoint").post(body.toString().toRequestBody(JSON)).apply {
            if (tok != null) header("Authorization", tok)
        }.build()
    }

    private class ApiException(val code: Int, message: String) : IOException(message)

    // ---------------------------------------------------------------- operations

    override fun testConnection() {
        if (!guest) { invalidateToken(); login() }
        postApi("OpenList connection", "/api/fs/list", listBody("/", 1, 1))
    }

    override fun list(dirPath: String): List<RemoteEntry> {
        val dir = RemotePaths.normalize(dirPath)
        val out = ArrayList<RemoteEntry>()
        var page = 1
        while (true) {
            val data = try {
                postApi("List $dir", "/api/fs/list", listBody(dir, page, PAGE_SIZE)) as? JSONObject
            } catch (e: ApiException) {
                if (isNotFound(e)) throw FileNotFoundException("Folder not found: $dir") else throw e
            } ?: break
            val content = data.optJSONArray("content") ?: JSONArray()
            for (i in 0 until content.length()) {
                val o = content.optJSONObject(i) ?: continue
                val name = str(o, "name") ?: continue
                out.add(entryOf(RemotePaths.join(dir, name), o))
            }
            val total = data.optLong("total", -1)
            if (content.length() == 0 || total < 0 || out.size >= total || content.length() < PAGE_SIZE) break
            page++
            if (page > 10_000) break
        }
        return out
    }

    override fun stat(path: String): RemoteEntry? {
        val p = RemotePaths.normalize(path)
        val data = try {
            postApi("Stat $p", "/api/fs/get", JSONObject().put("path", p).put("password", "")) as? JSONObject
        } catch (e: ApiException) {
            if (isNotFound(e)) return null else throw e
        } ?: return null
        return entryOf(p, data)
    }

    override fun openRead(path: String): InputStream = openRange(path, 0, -1)

    override fun openRange(path: String, offset: Long, length: Long): InputStream {
        val p = RemotePaths.normalize(path)
        // Partial reads issue many ranged requests per file: reuse the resolved download URLs for a while
        // instead of calling /api/fs/get before every range; re-resolve once if a cached URL fails.
        downloadUrls[p]?.let { cached ->
            if (System.currentTimeMillis() - cached.second < DOWNLOAD_URL_TTL_MS) {
                try {
                    return downloadFirst(cached.first, p, offset, length)
                } catch (e: IOException) {
                    downloadUrls.remove(p)
                }
            }
        }
        val candidates = resolveDownloadUrls(p)
        downloadUrls[p] = candidates to System.currentTimeMillis()
        return downloadFirst(candidates, p, offset, length)
    }

    private val downloadUrls = java.util.concurrent.ConcurrentHashMap<String, Pair<List<String>, Long>>()

    private fun resolveDownloadUrls(p: String): List<String> {
        val data = try {
            postApi("Read $p", "/api/fs/get", JSONObject().put("path", p).put("password", "")) as? JSONObject
        } catch (e: ApiException) {
            if (isNotFound(e)) throw FileNotFoundException("File not found: $p") else throw e
        } ?: throw IOException("Read $p: empty response")
        if (data.optBoolean("is_dir")) throw IOException("$p is a folder")

        val sign = str(data, "sign") ?: ""
        val proxyUrl = "$base/d" + RemotePaths.encodePath(p) + if (sign.isNotEmpty()) "?sign=" + RemotePaths.encodeSegment(sign) else ""
        val rawUrl = str(data, "raw_url")?.takeIf { it.isNotBlank() }?.let { absolutize(it) }
        return listOfNotNull(rawUrl, proxyUrl).distinct()
    }

    private fun downloadFirst(candidates: List<String>, p: String, offset: Long, length: Long): InputStream {
        var lastError: IOException? = null
        for (url in candidates) {
            try {
                return download(url, p, offset, length)
            } catch (e: IOException) {
                lastError = e
            }
        }
        throw lastError ?: IOException("Read $p failed")
    }

    private fun download(url: String, p: String, offset: Long, length: Long): InputStream {
        val b = Request.Builder().url(url).get()
        HttpSupport.rangeHeader(offset, length)?.let { b.header("Range", it) }
        // Token only for our own host; OkHttp also strips it on cross-host redirects.
        val httpUrl = url.toHttpUrlOrNull()
        if (httpUrl != null && httpUrl.host == baseHost) currentToken()?.let { b.header("Authorization", it) }
        val r = try {
            client.newCall(b.build()).execute()
        } catch (e: IOException) {
            throw IOException("Read $p: cannot reach ${httpUrl?.host ?: url} (${e.message})", e)
        }
        if (r.code == 401 || r.code == 403) r.use { throw HttpSupport.authFailure("Read $p", it) }
        if (!r.isSuccessful && r.code != 416) r.use { throw HttpSupport.httpFailure("Read $p", it) }
        return HttpSupport.rangedBody(r, offset, length)
    }

    override fun upload(path: String, source: File) {
        val p = RemotePaths.normalize(path)
        downloadUrls.remove(p)
        val body: RequestBody = source.asRequestBody(OCTET)
        api("Upload $p") { tok ->
            Request.Builder().url("$base/api/fs/put").put(body)
                .header("File-Path", RemotePaths.encodePath(p))
                .header("As-Task", "false")
                .header("Overwrite", "true")
                .header("Content-Length", source.length().toString())
                .apply { if (tok != null) header("Authorization", tok) }
                .build()
        }
    }

    override fun rename(path: String, newName: String): String {
        require(newName.isNotBlank() && !newName.contains('/')) { "Invalid file name: $newName" }
        val p = RemotePaths.normalize(path)
        downloadUrls.remove(p)
        val dst = RemotePaths.join(RemotePaths.parent(p), newName)
        if (dst == p) return p
        postApi("Rename $p", "/api/fs/rename", JSONObject().put("path", p).put("name", newName))
        return dst
    }

    override fun delete(path: String) {
        val p = RemotePaths.normalize(path)
        downloadUrls.remove(p)
        val body = JSONObject().put("dir", RemotePaths.parent(p)).put("names", JSONArray().put(RemotePaths.name(p)))
        try {
            postApi("Delete $p", "/api/fs/remove", body)
        } catch (e: ApiException) {
            if (!isNotFound(e)) throw e
        }
    }

    // ---------------------------------------------------------------- helpers

    private fun listBody(dir: String, page: Int, perPage: Int) = JSONObject()
        .put("path", dir).put("password", "").put("page", page).put("per_page", perPage).put("refresh", false)

    private fun entryOf(path: String, o: JSONObject) = RemoteEntry(
        path = path,
        name = RemotePaths.name(path),
        isDirectory = o.optBoolean("is_dir"),
        size = if (o.optBoolean("is_dir")) -1 else o.optLong("size", -1),
        modifiedMillis = parseIso(str(o, "modified")),
    )

    private fun isNotFound(e: ApiException) =
        e.message?.contains("not found", true) == true || e.message?.contains("not exist", true) == true

    private fun absolutize(url: String): String = when {
        url.startsWith("http://", true) || url.startsWith("https://", true) -> url
        url.startsWith("//") -> "$base/".toHttpUrl().scheme + ":" + url
        url.startsWith("/") -> base + url
        else -> "$base/$url"
    }

    private fun rawCall(req: Request, what: String): JSONObject {
        val (http, json) = rawCallWithStatus(req, what)
        return json ?: throw IOException("$what failed: HTTP $http (not an OpenList API response)")
    }

    private fun rawCallWithStatus(req: Request, what: String): Pair<Int, JSONObject?> {
        val r = try {
            client.newCall(req).execute()
        } catch (e: IOException) {
            throw IOException("$what: cannot reach ${req.url.host} (${e.message ?: e.javaClass.simpleName})", e)
        }
        r.use {
            val text = try { it.body.string() } catch (e: IOException) { throw IOException("$what: ${e.message}", e) }
            val json = try { JSONObject(text) } catch (_: Exception) { null }
            return it.code to json
        }
    }

    private fun message(json: JSONObject) = str(json, "message")?.takeIf { it.isNotBlank() } ?: "code ${json.optInt("code")}"

    companion object {
        private const val DOWNLOAD_URL_TTL_MS = 4 * 60_000L
        const val TOKEN_KEY = "openlist_token"
        internal const val PAGE_SIZE = 200
        private val JSON = "application/json; charset=utf-8".toMediaType()
        private val OCTET = "application/octet-stream".toMediaType()

        /** org.json on Android returns "null" from optString for JSON null; avoid that. */
        internal fun str(o: JSONObject, key: String): String? =
            if (!o.has(key) || o.isNull(key)) null else o.optString(key)

        internal fun parseIso(s: String?): Long {
            if (s.isNullOrBlank()) return 0
            return try { OffsetDateTime.parse(s).toInstant().toEpochMilli() } catch (_: Exception) { 0 }
        }
    }
}
