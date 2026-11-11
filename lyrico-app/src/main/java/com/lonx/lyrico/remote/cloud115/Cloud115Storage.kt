package com.lonx.lyrico.remote.cloud115

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.URLEncoder
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.ConcurrentHashMap

/**
 * 115 cloud storage using a 115 session cookie (`config.secret`): from [Cloud115QrLogin], the in-app web
 * (account/password) login, or pasted manually. UID, CID and SEID are required; KID is optional.
 *
 * Protocol follows SheltonZhu/115driver (used by OpenList's 115 driver):
 *  - listing: `webapi.115.com/files` (paged), path -> cid resolved by walking folders, cached
 *  - download: `proapi.115.com/app/chrome/downurl` with m115-encrypted payload; the CDN URL is fetched
 *    with the same User-Agent and cookies (incl. Set-Cookie from downurl)
 *  - upload: rapid upload (`initupload.php` 4.0, ECDH/AES, sha1 + sign_check) else Aliyun OSS
 *    (simple PUT, multipart above 100 MiB) with 115's callback. 115 has no overwrite, so the new file is
 *    uploaded under a temporary name, then the old file is deleted (to recycle bin) and the new one renamed.
 *  - rename `files/batch_rename`, delete `rb/delete`.
 * Cookie expiry -> [RemoteAuthException] ("115 登录已失效，请重新登录").
 */
class Cloud115Storage(
    override val config: RemoteConfig,
    @Suppress("unused") private val credentialStore: RemoteCredentialStore? = null,
    client: OkHttpClient? = null,
    private val endpoints: Cloud115Endpoints = Cloud115Endpoints(),
) : RemoteStorage {

    /** Internal node: the public entry plus 115 ids. */
    internal data class Node(
        val entry: RemoteEntry,
        /** fid for files, cid for folders. */
        val id: String,
        val parentId: String,
        val pickCode: String,
        val sha1: String,
    )

    private data class Listing(val at: Long, val nodes: List<Node>)
    private data class DownUrl(val url: String, val cookie: String, val at: Long)

    private val okHttp = client ?: Cloud115Const.defaultClient()
    private val credential: Cloud115Credential? = Cloud115Credential.parse(config.secret)
    private val http = Cloud115Http(okHttp, credential?.toCookie() ?: "")
    private val oss = Cloud115Oss(okHttp, endpoints)

    private val dirIds = ConcurrentHashMap<String, String>().apply { put("/", ROOT_ID) }
    private val listings = ConcurrentHashMap<String, Listing>()
    private val downUrls = ConcurrentHashMap<String, DownUrl>()

    @Volatile private var uploadUserId: String? = null
    @Volatile private var uploadUserKey: String? = null
    @Volatile private var uploadSizeLimit: Long = 0

    internal var listingTtlMs = 30_000L
    internal var downUrlTtlMs = 10 * 60_000L
    internal var retryDelayMs = 1000L
    internal var nowMillis: () -> Long = { System.currentTimeMillis() }
    /** Test seams: the server side of m115/ECDH can't be reproduced without 115's private keys. */
    internal var m115Decode: (String, ByteArray) -> ByteArray = { s, k -> M115.decode(s, k) }
    internal var cipherFactory: () -> Ec115Cipher = { Ec115Cipher.create() }

    private fun requireCredential() {
        if (credential == null) throw RemoteAuthException("115 未登录或 Cookie 不完整（需要 UID、CID、SEID），请重新登录")
    }

    // ---------------------------------------------------------------- RemoteStorage

    override fun testConnection() {
        requireCredential()
        try {
            val o = http.getJson(endpoints.statusCheck.toHttpUrl(), "检查登录状态")
            J.checkAuth(o)
            if (o.has("state") && !J.truthy(o.opt("state"))) throw RemoteAuthException(Cloud115Const.AUTH_EXPIRED_MSG)
        } catch (e: RemoteAuthException) {
            throw e
        } catch (e: IOException) {
            // status page unreachable/non-JSON: fall through to the files API, which is authoritative
        }
        fetchPage(ROOT_ID, 0, 1)
    }

    override fun list(dirPath: String): List<RemoteEntry> {
        val p = normalize(dirPath)
        return listNodes(p, fresh = true).map { it.entry }
    }

    override fun stat(path: String): RemoteEntry? = findNode(normalize(path), fresh = false)?.entry

    override fun openRead(path: String): InputStream = openRange(path, 0, -1)

    override fun openRange(path: String, offset: Long, length: Long): InputStream {
        require(offset >= 0) { "offset < 0" }
        val node = requireFile(normalize(path))
        if (length == 0L) return ByteArrayInputStream(ByteArray(0))
        if (offset > 0 && node.entry.size in 0..offset) return ByteArrayInputStream(ByteArray(0))
        var attempt = 0
        while (true) {
            val du = downloadUrl(node.pickCode, fresh = attempt > 0)
            val rb = http.newRequest(du.url.toHttpUrl())
            rb.header("Cookie", du.cookie)
            if (offset > 0 || length > 0) {
                val end = if (length > 0) (offset + length - 1).toString() else ""
                rb.header("Range", "bytes=$offset-$end")
            }
            val resp = http.execute(rb.get().build())
            if ((resp.code == 403 || resp.code == 404 || resp.code == 410) && attempt == 0) {
                resp.close(); attempt++; continue // signed URL expired: fetch a fresh one once
            }
            if (resp.code == 416) { resp.close(); return ByteArrayInputStream(ByteArray(0)) }
            if (resp.code != 200 && resp.code != 206) {
                val msg = resp.body.string().take(200); resp.close()
                throw IOException("115 下载失败: HTTP ${resp.code} $msg")
            }
            var stream: InputStream = resp.body.byteStream()
            if (resp.code == 200 && offset > 0) skipFully(stream, offset) // server ignored Range
            if (length > 0) stream = LimitedInputStream(stream, length)
            return stream
        }
    }

    override fun upload(path: String, source: File) {
        requireCredential()
        val p = normalize(path)
        require(p != "/") { "cannot upload to root path" }
        if (!source.isFile) throw FileNotFoundException(source.path)
        val name = baseName(p)
        val parentPath = parentOf(p)
        val cid = resolveDirId(parentPath)
        val old = listNodes(parentPath, fresh = true).firstOrNull { it.entry.name == name }
        if (old != null && old.entry.isDirectory) throw IOException("目标是文件夹: $p")

        val digest = Cloud115Hash.digest(source)
        if (old != null && old.sha1.equals(digest.sha1, true) && old.entry.size == digest.size) return // unchanged

        ensureUploadInfo()
        if (uploadSizeLimit > 0 && digest.size > uploadSizeLimit) throw IOException("文件超过 115 上传大小限制")

        val tmpName = TMP_PREFIX + nowMillis() + "_" + name
        val init = initUpload(cid, tmpName, digest, source)
        var newFileId = ""
        when (J.long(init, "status")) {
            2L -> Unit // rapid upload hit
            1L -> {
                val cb = init.optJSONObject("callback") ?: JSONObject()
                val target = OssTarget(
                    J.str(init, "bucket"), J.str(init, "object"),
                    J.str(cb, "callback"), J.str(cb, "callback_var"),
                )
                if (target.bucket.isEmpty() || target.objectKey.isEmpty()) throw IOException("115 上传初始化缺少 OSS 参数")
                val body = if (digest.size > Cloud115Oss.MULTIPART_THRESHOLD) {
                    oss.multipartUpload(target, { ossToken() }, source)
                } else {
                    oss.putObject(target, ossToken(), source, digest.md5Base64)
                }
                newFileId = parseCallback(body)
            }
            else -> throw IOException("115 上传初始化返回未知状态: ${init.optString("status")} ${J.errorMessage(init)}")
        }

        // Locate the new file (fresh listing; tolerate a little server-side lag)
        invalidate(parentPath)
        var newNode: Node? = null
        for (i in 0 until 4) {
            newNode = listNodes(parentPath, fresh = true).firstOrNull {
                (newFileId.isNotEmpty() && it.id == newFileId) || it.entry.name == tmpName
            }
            if (newNode != null) break
            Thread.sleep(retryDelayMs)
        }
        if (newNode == null) throw IOException("115 上传后未找到新文件 $tmpName")

        if (old != null) {
            try {
                deleteIds(listOf(old.id))
            } catch (e: Exception) {
                runCatching { deleteIds(listOf(newNode.id)) } // keep the original intact, drop the temp copy
                throw e
            }
        }
        try {
            renameId(newNode.id, name)
        } catch (e: Exception) {
            throw IOException("新文件已上传为 $tmpName，但重命名为 $name 失败: ${e.message}", e)
        } finally {
            invalidate(parentPath)
        }
    }

    override fun rename(path: String, newName: String): String {
        require(newName.isNotBlank() && !newName.contains('/')) { "invalid name" }
        val p = normalize(path)
        val node = findNode(p, fresh = true) ?: throw FileNotFoundException(p)
        if (node.entry.name == newName) return p
        renameId(node.id, newName)
        val parent = parentOf(p)
        val newPath = join(parent, newName)
        invalidate(parent)
        if (node.entry.isDirectory) dropSubtree(p)
        return newPath
    }

    override fun delete(path: String) {
        val p = normalize(path)
        require(p != "/") { "cannot delete root" }
        val node = findNode(p, fresh = true) ?: throw FileNotFoundException(p)
        deleteIds(listOf(node.id))
        invalidate(parentOf(p))
        if (node.entry.isDirectory) dropSubtree(p)
    }

    override fun close() {
        listings.clear(); downUrls.clear()
    }

    // ---------------------------------------------------------------- listing / resolve

    internal fun resolveDirId(dirPath: String): String {
        val p = normalize(dirPath)
        dirIds[p]?.let { return it }
        val parent = parentOf(p)
        val name = baseName(p)
        resolveDirId(parent)
        var child = listNodes(parent, fresh = false).firstOrNull { it.entry.isDirectory && it.entry.name == name }
        if (child == null) child = listNodes(parent, fresh = true).firstOrNull { it.entry.isDirectory && it.entry.name == name }
        if (child == null) throw FileNotFoundException("115 目录不存在: $p")
        dirIds[p] = child.id
        return child.id
    }

    internal fun findNode(p: String, fresh: Boolean): Node? {
        if (p == "/") return Node(RemoteEntry("/", "", true, providerId = ROOT_ID), ROOT_ID, "", "", "")
        val parent = parentOf(p)
        val name = baseName(p)
        val nodes = try {
            listNodes(parent, fresh)
        } catch (e: FileNotFoundException) {
            return null
        }
        return nodes.firstOrNull { it.entry.name == name }
    }

    private fun requireFile(p: String): Node {
        val n = findNode(p, fresh = false) ?: findNode(p, fresh = true) ?: throw FileNotFoundException(p)
        if (n.entry.isDirectory) throw IOException("是文件夹: $p")
        if (n.pickCode.isEmpty()) throw IOException("115 文件缺少 pick code: $p")
        return n
    }

    internal fun listNodes(dirPath: String, fresh: Boolean): List<Node> {
        requireCredential()
        val p = normalize(dirPath)
        if (!fresh) listings[p]?.let { if (nowMillis() - it.at < listingTtlMs) return it.nodes }
        val cid = resolveDirId(p)
        val out = ArrayList<Node>()
        var offset = 0
        while (true) {
            val page = try {
                fetchPage(cid, offset, PAGE_LIMIT)
            } catch (e: FileNotFoundException) {
                dropSubtree(p); throw FileNotFoundException("115 目录不存在: $p")
            }
            val data = page.optJSONArray("data")
            val n = data?.length() ?: 0
            for (i in 0 until n) {
                val node = parseNode(data!!.getJSONObject(i), p) ?: continue
                out += node
            }
            val count = J.long(page, "count").toInt()
            offset = J.long(page, "offset").toInt() + PAGE_LIMIT
            if (n == 0 || offset >= count) break
        }
        for (node in out) if (node.entry.isDirectory) dirIds[node.entry.path] = node.id
        listings[p] = Listing(nowMillis(), out)
        return out
    }

    /** One page of `webapi.115.com/files`; throws FileNotFoundException if the cid doesn't exist. */
    internal fun fetchPage(cid: String, offset: Int, limit: Int): JSONObject {
        val url = endpoints.files.toHttpUrl().newBuilder()
            .addQueryParameter("aid", "1")
            .addQueryParameter("cid", cid)
            .addQueryParameter("o", "user_ptime")
            .addQueryParameter("asc", "1")
            .addQueryParameter("offset", offset.toString())
            .addQueryParameter("show_dir", "1")
            .addQueryParameter("limit", limit.toString())
            .addQueryParameter("snap", "0")
            .addQueryParameter("natsort", "0")
            .addQueryParameter("record_open_time", "1")
            .addQueryParameter("format", "json")
            .addQueryParameter("fc_mix", "0")
            .build()
        val o = J.requireOk(http.getJson(url, "列出目录"), "列出目录")
        // 115 silently falls back to root for an unknown cid (115driver GetFiles checks this)
        val got = J.str(o, "cid")
        if (got.isNotEmpty() && got != cid) throw FileNotFoundException("115 目录 id 不存在: $cid")
        return o
    }

    // ---------------------------------------------------------------- download

    private fun downloadUrl(pickCode: String, fresh: Boolean): DownUrl {
        if (!fresh) downUrls[pickCode]?.let { if (nowMillis() - it.at < downUrlTtlMs) return it }
        requireCredential()
        val key = M115.generateKey()
        val payload = JSONObject().put("pickcode", pickCode).toString().toByteArray(Charsets.UTF_8)
        val url = endpoints.downUrl.toHttpUrl().newBuilder()
            .addQueryParameter("t", (nowMillis() / 1000).toString()).build()
        val form = "data=" + URLEncoder.encode(M115.encode(payload, key), "UTF-8")
        val req = http.newRequest(url)
            .post(form.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
            .build()
        val (o, setCookies) = http.execute(req).use { resp ->
            http.readJson(resp, "获取下载链接") to resp.headers("Set-Cookie").map { it.substringBefore(';').trim() }
        }
        J.requireOk(o, "获取下载链接")
        val enc = o.opt("data") as? String ?: throw IOException("获取下载链接失败: 无数据")
        val decoded = String(m115Decode(enc, key), Charsets.UTF_8)
        val du = parseDownUrl(decoded)
        val cookie = (listOf(http.cookie) + setCookies).filter { it.isNotBlank() }.joinToString("; ")
        return DownUrl(du, cookie, nowMillis()).also { downUrls[pickCode] = it }
    }

    // ---------------------------------------------------------------- upload

    private fun ensureUploadInfo() {
        if (uploadUserId != null && !uploadUserKey.isNullOrEmpty()) return
        val o = J.requireOk(http.postFormJson(endpoints.uploadInfo.toHttpUrl(), emptyList(), "获取上传信息"), "获取上传信息")
        val uid = J.long(o, "user_id")
        val key = J.str(o, "userkey")
        if (uid == 0L || key.isEmpty()) throw IOException("获取上传信息失败: 缺少 user_id/userkey")
        uploadUserId = uid.toString()
        uploadUserKey = key
        uploadSizeLimit = J.long(o, "size_limit")
    }

    /** initupload.php 4.0 with the sign_check second round (status 7). */
    private fun initUpload(cid: String, fileName: String, d: Cloud115Hash.Digest, file: File): JSONObject {
        val userId = uploadUserId!!
        val userKey = uploadUserKey!!
        val target = "U_1_$cid"
        val sizeStr = d.size.toString()
        var signKey = ""
        var signVal = ""
        val cipher = cipherFactory()
        for (round in 0 until 4) {
            val t = nowMillis().toString()
            val form = ArrayList<Pair<String, String>>().apply {
                add("appid" to "0"); add("appversion" to Cloud115Const.APP_VER); add("userid" to userId)
                add("filename" to fileName); add("filesize" to sizeStr); add("fileid" to d.sha1)
                add("target" to target); add("sig" to Cloud115Hash.uploadSignature(userId, userKey, d.sha1, target))
                add("topupload" to "true"); add("t" to t)
                add("token" to Cloud115Hash.uploadToken(userId, d.sha1, sizeStr, signKey, signVal, t, Cloud115Const.APP_VER))
                if (signKey.isNotEmpty() && signVal.isNotEmpty()) { add("sign_key" to signKey); add("sign_val" to signVal) }
            }
            val encoded = form.joinToString("&") { (k, v) -> enc(k) + "=" + enc(v) }
            val url = endpoints.uploadInit.toHttpUrl().newBuilder()
                .addQueryParameter("k_ec", cipher.encodeToken(t.toLong())).build()
            val req = http.newRequest(url)
                .post(cipher.encrypt(encoded.toByteArray(Charsets.UTF_8)).toRequestBody(null))
                .header("Content-Type", "application/x-www-form-urlencoded")
                .build()
            val o = http.execute(req).use { resp ->
                val bytes = resp.body.bytes()
                if (resp.code == 401 && round < 3) null // p115client: occasional 401, just retry
                else if (resp.code !in 200..299) throw IOException("115 上传初始化失败: HTTP ${resp.code}")
                else J.parse(String(cipher.decrypt(bytes), Charsets.UTF_8), "上传初始化")
            } ?: continue
            J.checkAuth(o)
            val code = J.long(o, "statuscode")
            if (code != 0L && code != 701L) throw Cloud115Exception("115 上传初始化失败: ${J.errorMessage(o)} ($code)", code)
            if (J.long(o, "status") == 7L) {
                signKey = J.str(o, "sign_key")
                signVal = Cloud115Hash.rangeSha1(file, J.str(o, "sign_check"))
                continue
            }
            return o
        }
        throw IOException("115 上传初始化失败: 校验轮次过多")
    }

    private fun ossToken(): OssToken {
        val o = http.getJson(endpoints.ossToken.toHttpUrl(), "获取 OSS 令牌")
        J.checkAuth(o)
        if (J.str(o, "StatusCode") != "200") throw IOException("获取 OSS 令牌失败: ${o.toString().take(200)}")
        return OssToken(J.str(o, "AccessKeyID"), J.str(o, "AccessKeySecret"), J.str(o, "SecurityToken"))
    }

    // ---------------------------------------------------------------- mutations

    private fun renameId(id: String, newName: String) {
        J.requireOk(
            http.postFormJson(
                endpoints.rename.toHttpUrl(),
                listOf("fid" to id, "file_name" to newName, "files_new_name[$id]" to newName),
                "重命名",
            ),
            "重命名",
        )
    }

    private fun deleteIds(ids: List<String>) {
        J.requireOk(
            http.postFormJson(endpoints.delete.toHttpUrl(), ids.mapIndexed { i, id -> "fid[$i]" to id }, "删除"),
            "删除",
        )
    }

    // ---------------------------------------------------------------- cache helpers

    private fun invalidate(dirPath: String) {
        listings.remove(normalize(dirPath))
    }

    private fun dropSubtree(p: String) {
        val prefix = if (p == "/") "/" else "$p/"
        dirIds.keys.removeIf { it != "/" && (it == p || it.startsWith(prefix)) }
        listings.keys.removeIf { it == p || it.startsWith(prefix) }
    }

    companion object {
        const val ROOT_ID = "0"
        internal const val PAGE_LIMIT = 1000 // 115driver MaxDirPageLimit = 1150
        internal const val TMP_PREFIX = ".lyrico_upload_"

        private fun enc(s: String) = URLEncoder.encode(s, "UTF-8")

        fun normalize(path: String): String {
            val parts = path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
            return "/" + parts.joinToString("/")
        }

        fun parentOf(p: String): String {
            val n = normalize(p)
            val i = n.lastIndexOf('/')
            return if (i <= 0) "/" else n.substring(0, i)
        }

        fun baseName(p: String): String = normalize(p).substringAfterLast('/')

        fun join(dir: String, name: String): String = normalize("$dir/$name")

        private val cst = TimeZone.getTimeZone("GMT+08:00")

        /** File: has "fid" (its parent is "cid"); folder: no "fid", own id "cid", parent "pid". */
        internal fun parseNode(o: JSONObject, dirPath: String): Node? {
            val name = J.str(o, "n", "file_name")
            if (name.isEmpty()) return null
            val fid = J.str(o, "fid")
            val isDir = fid.isEmpty()
            val id = if (isDir) J.str(o, "cid") else fid
            val parent = if (isDir) J.str(o, "pid") else J.str(o, "cid")
            val entry = RemoteEntry(
                path = join(dirPath, name),
                name = name,
                isDirectory = isDir,
                size = if (isDir) -1 else J.long(o, "s"),
                modifiedMillis = parseTime(o),
                providerId = id,
            )
            return Node(entry, id, parent, J.str(o, "pc"), J.str(o, "sha"))
        }

        /** "te"/"tu" are unix seconds when present; "t" is unix seconds or "yyyy-MM-dd HH:mm" (UTC+8). */
        internal fun parseTime(o: JSONObject): Long {
            for (k in arrayOf("te", "tu", "t")) {
                val s = J.str(o, k).trim()
                if (s.isEmpty()) continue
                s.toLongOrNull()?.let { if (it > 0) return it * 1000 }
                for (fmt in arrayOf("yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm")) {
                    try {
                        val f = SimpleDateFormat(fmt, Locale.US).apply { timeZone = cst; isLenient = false }
                        return f.parse(s)!!.time
                    } catch (_: Exception) {
                    }
                }
            }
            return 0
        }

        /** Decoded downurl data: `{"<fid>":{"file_name":..,"file_size":..,"pick_code":..,"url":{"url":..}|false}}`. */
        internal fun parseDownUrl(decoded: String): String {
            val root = J.parse(decoded, "下载链接")
            val keys = root.keys()
            while (keys.hasNext()) {
                val info = root.optJSONObject(keys.next()) ?: continue
                if (J.long(info, "file_size") < 0) continue
                val u = info.opt("url")
                val url = when (u) {
                    is JSONObject -> J.str(u, "url")
                    is String -> u
                    else -> ""
                }
                if (url.isNotEmpty()) return url
            }
            throw IOException("115 无法获取下载链接（文件可能已删除或违规）")
        }

        /** OSS callback body -> new file id ("" if absent). Throws if 115 reports failure. */
        internal fun parseCallback(body: String): String {
            val t = body.trim()
            if (!t.startsWith("{")) return ""
            val o = J.parse(t, "上传回调")
            if (o.has("state") && !J.truthy(o.opt("state"))) {
                throw IOException("115 上传回调失败: ${J.errorMessage(o)} (code ${J.errorCode(o)})")
            }
            return o.optJSONObject("data")?.let { J.str(it, "file_id") } ?: ""
        }

        private fun skipFully(input: InputStream, n: Long) {
            var left = n
            while (left > 0) {
                val s = input.skip(left)
                if (s <= 0) {
                    if (input.read() < 0) throw IOException("unexpected EOF while skipping")
                    left--
                } else left -= s
            }
        }
    }

    private class LimitedInputStream(input: InputStream, private var left: Long) : FilterInputStream(input) {
        override fun read(): Int {
            if (left <= 0) return -1
            val b = super.read()
            if (b >= 0) left--
            return b
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (left <= 0) return -1
            val n = super.read(b, off, minOf(len.toLong(), left).toInt())
            if (n > 0) left -= n
            return n
        }

        override fun skip(n: Long): Long {
            val s = super.skip(minOf(n, left))
            left -= s
            return s
        }

        override fun available(): Int = minOf(super.available().toLong(), left).toInt()
    }
}
