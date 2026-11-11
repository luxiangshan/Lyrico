package com.lonx.lyrico.remote.webdav

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream

/**
 * WebDAV provider (RFC 4918 subset: PROPFIND, GET+Range, PUT, MOVE, DELETE) over OkHttp.
 * Tested shapes: Apache mod_dav, nginx dav(-ext), Nextcloud/ownCloud, rclone serve webdav, OpenList /dav.
 *
 * [RemoteConfig.baseUrl] is the WebDAV root, e.g. "https://host/remote.php/dav/files/alice".
 * Remote paths are relative to that root.
 */
class WebDavStorage(
    override val config: RemoteConfig,
    baseClient: OkHttpClient = HttpSupport.defaultClient,
) : RemoteStorage {

    private val baseUrlString: String = config.baseUrl.trim().trimEnd('/').also {
        require(it.startsWith("http://", true) || it.startsWith("https://", true)) {
            "WebDAV address must start with http:// or https://"
        }
    }
    private val basePath: String = RemotePaths.normalize(RemotePaths.percentDecode((baseUrlString + "/").toHttpUrl().encodedPath))

    private val client: OkHttpClient = HttpAuth(config.username, config.secret).let { auth ->
        baseClient.newBuilder().authenticator(auth).addInterceptor(auth).build()
    }

    // ---------------------------------------------------------------- URLs

    internal fun urlFor(path: String, directory: Boolean = false): String {
        val p = RemotePaths.normalize(path)
        if (p == "/") return "$baseUrlString/"
        return baseUrlString + RemotePaths.encodePath(p) + if (directory) "/" else ""
    }

    /** Decoded server path -> path relative to the WebDAV root, or null when outside it. */
    private fun relativize(hrefPath: String): String? = when {
        basePath == "/" -> hrefPath
        hrefPath == basePath -> "/"
        hrefPath.startsWith("$basePath/") -> hrefPath.substring(basePath.length)
        else -> null
    }

    // ---------------------------------------------------------------- operations

    override fun testConnection() {
        propfind("/", depth = 0, directory = true).use { r ->
            when {
                r.code == 207 -> WebDavXml.parseMultistatus(r.body.byteStream())
                r.code == 404 -> throw IOException("WebDAV folder not found at ${config.baseUrl}")
                r.code == 405 || r.code == 501 || r.isSuccessful ->
                    throw IOException("Server at ${config.baseUrl} does not look like WebDAV (HTTP ${r.code} to PROPFIND)")
                else -> throw HttpSupport.httpFailure("WebDAV connection", r)
            }
        }
    }

    override fun list(dirPath: String): List<RemoteEntry> {
        val dir = RemotePaths.normalize(dirPath)
        propfind(dir, depth = 1, directory = true).use { r ->
            if (r.code == 404) throw FileNotFoundException("Folder not found: $dir")
            if (r.code != 207) throw HttpSupport.httpFailure("List $dir", r)
            val requestPath = WebDavXml.hrefToPath(r.request.url.encodedPath)
            val out = ArrayList<RemoteEntry>()
            val resources = WebDavXml.parseMultistatus(r.body.byteStream())
            // For hrefs we cannot map onto the root, the requested folder itself is the shallowest href
            // (only meaningful when depths differ, i.e. the server did include the folder itself).
            val depths = resources.map { d -> d.hrefPath.count { it == '/' } }
            val selfDepth = if (depths.distinct().size > 1) depths.min() else -1
            for ((index, res) in resources.withIndex()) {
                val rel = relativize(res.hrefPath)
                val path: String = if (rel != null) {
                    if (rel == dir) continue
                    if (RemotePaths.parent(rel) == dir) rel else RemotePaths.join(dir, RemotePaths.name(rel))
                } else {
                    // Server reports hrefs outside the configured root (reverse proxy rewriting etc.):
                    // fall back to "last segment under the requested folder".
                    if (res.hrefPath == requestPath || depths[index] == selfDepth) continue
                    RemotePaths.join(dir, RemotePaths.name(res.hrefPath))
                }
                val name = RemotePaths.name(path)
                if (name.isEmpty() || path == dir) continue
                out.add(RemoteEntry(path, name, res.isCollection, res.contentLength, res.lastModifiedMillis))
            }
            return out.distinctBy { it.path }
        }
    }

    override fun stat(path: String): RemoteEntry? {
        val p = RemotePaths.normalize(path)
        propfind(p, depth = 0, directory = p == "/").use { r ->
            if (r.code == 404) return null
            if (r.code != 207) throw HttpSupport.httpFailure("Stat $p", r)
            val res = WebDavXml.parseMultistatus(r.body.byteStream()).firstOrNull() ?: return null
            return RemoteEntry(p, RemotePaths.name(p), res.isCollection, res.contentLength, res.lastModifiedMillis)
        }
    }

    override fun openRead(path: String): InputStream = openRange(path, 0, -1)

    override fun openRange(path: String, offset: Long, length: Long): InputStream {
        val p = RemotePaths.normalize(path)
        val b = Request.Builder().url(urlFor(p)).get()
        HttpSupport.rangeHeader(offset, length)?.let { b.header("Range", it) }
        val r = execute(b.build(), "Read $p")
        if (r.code == 404) { r.close(); throw FileNotFoundException("File not found: $p") }
        if (!r.isSuccessful && r.code != 416) r.use { throw HttpSupport.httpFailure("Read $p", it) }
        return HttpSupport.rangedBody(r, offset, length)
    }

    override fun upload(path: String, source: File) {
        val target = RemotePaths.normalize(path)
        val tmp = RemotePaths.join(RemotePaths.parent(target), ".${RemotePaths.name(target)}.lyrico-tmp")

        val tmpOk = put(tmp, source, failOnError = false)
        if (!tmpOk) { put(target, source, failOnError = true); return }

        val moveCode = move(tmp, target, overwrite = true)
        when {
            moveCode in 200..299 -> return
            moveCode == 412 -> {
                // Server refuses Overwrite:T; the new content is safe in tmp, so replace explicitly.
                delete(target)
                val retry = move(tmp, target, overwrite = false)
                if (retry in 200..299) return
                throw IOException("Upload of $target failed: MOVE from temp file returned HTTP $retry (new content kept at $tmp)")
            }
            moveCode == 405 || moveCode == 501 || moveCode == 403 || moveCode == 400 || moveCode == 502 -> {
                // MOVE not supported/allowed: plain overwrite, then clean up.
                put(target, source, failOnError = true)
                try { delete(tmp) } catch (_: IOException) {}
            }
            else -> {
                try { delete(tmp) } catch (_: IOException) {}
                throw IOException("Upload of $target failed: MOVE returned HTTP $moveCode")
            }
        }
    }

    override fun rename(path: String, newName: String): String {
        require(newName.isNotBlank() && !newName.contains('/')) { "Invalid file name: $newName" }
        val src = RemotePaths.normalize(path)
        val dst = RemotePaths.join(RemotePaths.parent(src), newName)
        if (dst == src) return src
        val code = move(src, dst, overwrite = false)
        when {
            code in 200..299 -> return dst
            code == 412 -> throw IOException("A file named \"$newName\" already exists")
            code == 404 -> throw FileNotFoundException("File not found: $src")
            else -> throw IOException("Rename $src failed: HTTP $code")
        }
    }

    override fun delete(path: String) {
        val p = RemotePaths.normalize(path)
        val r = execute(Request.Builder().url(urlFor(p)).delete().build(), "Delete $p")
        r.use { if (!it.isSuccessful && it.code != 404) throw HttpSupport.httpFailure("Delete $p", it) }
    }

    // ---------------------------------------------------------------- HTTP helpers

    private fun propfind(path: String, depth: Int, directory: Boolean): Response {
        val body = WebDavXml.PROPFIND_BODY.toRequestBody(XML)
        val req = Request.Builder()
            .url(urlFor(path, directory))
            .method("PROPFIND", body)
            .header("Depth", depth.toString())
            .build()
        return execute(req, "PROPFIND $path")
    }

    /** @return true on success; false (non-auth failure) when [failOnError] is false. */
    private fun put(path: String, source: File, failOnError: Boolean): Boolean {
        val req = Request.Builder().url(urlFor(path)).put(source.asRequestBody(OCTET)).build()
        execute(req, "Upload $path").use { r ->
            if (r.isSuccessful) return true
            if (failOnError) throw HttpSupport.httpFailure("Upload $path", r)
            return false
        }
    }

    private fun move(from: String, to: String, overwrite: Boolean): Int {
        val req = Request.Builder()
            .url(urlFor(from))
            .method("MOVE", null)
            .header("Destination", urlFor(to))
            .header("Overwrite", if (overwrite) "T" else "F")
            .build()
        return execute(req, "Move $from").use { it.code }
    }

    /** Executes; maps a final 401 (authenticator gave up) to [RemoteAuthException]. Caller closes the response. */
    private fun execute(request: Request, what: String): Response {
        val r = try {
            client.newCall(request).execute()
        } catch (e: IOException) {
            throw IOException("$what: cannot reach ${request.url.host} (${e.message ?: e.javaClass.simpleName})", e)
        }
        if (r.code == 401) {
            r.close()
            throw RemoteAuthException("$what: WebDAV login rejected (HTTP 401). Check username and password.")
        }
        if (r.code == 403 && request.method == "PROPFIND" && r.request.header("Authorization") == null &&
            config.username.isEmpty()
        ) {
            r.close()
            throw RemoteAuthException("$what: access denied (HTTP 403); this server probably needs a username and password.")
        }
        return r
    }

    companion object {
        private val XML = "application/xml; charset=utf-8".toMediaType()
        private val OCTET = "application/octet-stream".toMediaType()
    }
}
