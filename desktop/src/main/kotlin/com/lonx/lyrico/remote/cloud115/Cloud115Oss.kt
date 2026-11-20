package com.lonx.lyrico.remote.cloud115

import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okio.BufferedSink
import okio.source
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.text.SimpleDateFormat
import java.util.Base64
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** STS credentials from `uplb.115.com/3.0/gettoken.php`. */
data class OssToken(val accessKeyId: String, val accessKeySecret: String, val securityToken: String)

/** Target returned by upload init when the rapid upload missed. */
data class OssTarget(val bucket: String, val objectKey: String, val callback: String, val callbackVar: String)

/**
 * Minimal Aliyun OSS client (V1 header signature) for 115 uploads: simple PutObject and sequential
 * multipart, both with 115's callback headers. Mirrors what 115driver does via aliyun-oss-go-sdk
 * (UploadByOSS / UploadByMultipart). The OSS response body is 115's callback JSON.
 */
internal class Cloud115Oss(
    private val client: OkHttpClient,
    private val endpoints: Cloud115Endpoints,
    private val clock: () -> Date = { Date() },
) {
    /** Returns the callback response body (115 JSON). */
    fun putObject(target: OssTarget, token: OssToken, file: File, md5Base64: String): String {
        val url = endpoints.ossObjectUrl(target.bucket, target.objectKey)
        val body = fileBody(file, 0, file.length())
        val headers = callbackHeaders(target, token)
        val req = signed("PUT", url, target, "", OCTET, md5Base64, headers, token, body)
        return client.newCall(req).execute().use { resp ->
            val text = resp.body.string()
            if (resp.code !in 200..299) throw IOException("OSS 上传失败: HTTP ${resp.code} ${text.take(300)}")
            text
        }
    }

    /** Sequential multipart upload, parts of [partSize] bytes. Returns callback response body. */
    fun multipartUpload(
        target: OssTarget, tokenProvider: () -> OssToken, file: File, partSize: Long = DEFAULT_PART_SIZE,
    ): String {
        var token = tokenProvider()
        var tokenAt = System.currentTimeMillis()
        val url = endpoints.ossObjectUrl(target.bucket, target.objectKey)
        // Initiate
        val initUrl = url.newBuilder().addQueryParameter("uploads", null).build()
        val initReq = signed(
            "POST", initUrl, target, "?uploads", OCTET, "", sts(token), token,
            ByteArray(0).toRequestBody(OCTET.toMediaType()),
        )
        val uploadId = client.newCall(initReq).execute().use { resp ->
            val text = resp.body.string()
            if (resp.code !in 200..299) throw IOException("OSS 初始化分片失败: HTTP ${resp.code} ${text.take(300)}")
            xmlTag(text, "UploadId") ?: throw IOException("OSS 初始化分片失败: 无 UploadId")
        }
        val etags = ArrayList<String>()
        val total = file.length()
        var offset = 0L
        var part = 1
        while (offset < total) {
            val len = minOf(partSize, total - offset)
            var lastErr: IOException? = null
            var etag: String? = null
            for (attempt in 0 until 3) {
                if (System.currentTimeMillis() - tokenAt > TOKEN_REFRESH_MS) {
                    token = tokenProvider(); tokenAt = System.currentTimeMillis()
                }
                try {
                    val partUrl = url.newBuilder()
                        .addQueryParameter("partNumber", part.toString())
                        .addQueryParameter("uploadId", uploadId).build()
                    val req = signed(
                        "PUT", partUrl, target, "?partNumber=$part&uploadId=$uploadId", OCTET, "",
                        sts(token), token, fileBody(file, offset, len),
                    )
                    etag = client.newCall(req).execute().use { resp ->
                        if (resp.code !in 200..299) throw IOException("OSS 分片 $part 失败: HTTP ${resp.code}")
                        resp.header("ETag") ?: throw IOException("OSS 分片 $part 无 ETag")
                    }
                    break
                } catch (e: IOException) {
                    lastErr = e
                    Thread.sleep(1000L * (attempt + 1))
                }
            }
            etags += etag ?: throw (lastErr ?: IOException("OSS 分片 $part 失败"))
            offset += len
            part++
        }
        // Complete (with callback)
        val xml = buildString {
            append("<CompleteMultipartUpload>")
            etags.forEachIndexed { i, e -> append("<Part><PartNumber>${i + 1}</PartNumber><ETag>$e</ETag></Part>") }
            append("</CompleteMultipartUpload>")
        }.toByteArray()
        val doneUrl = url.newBuilder().addQueryParameter("uploadId", uploadId).build()
        val req = signed(
            "POST", doneUrl, target, "?uploadId=$uploadId", XML, "", callbackHeaders(target, token), token,
            xml.toRequestBody(XML.toMediaType()),
        )
        return client.newCall(req).execute().use { resp ->
            val text = resp.body.string()
            if (resp.code !in 200..299) throw IOException("OSS 完成分片失败: HTTP ${resp.code} ${text.take(300)}")
            text
        }
    }

    private fun sts(token: OssToken) = sortedMapOf("x-oss-security-token" to token.securityToken)

    private fun callbackHeaders(target: OssTarget, token: OssToken) = sortedMapOf(
        "x-oss-security-token" to token.securityToken,
        "x-oss-callback" to b64(target.callback),
        "x-oss-callback-var" to b64(target.callbackVar),
    )

    private fun signed(
        method: String, url: HttpUrl, target: OssTarget, subResource: String, contentType: String,
        contentMd5: String, ossHeaders: Map<String, String>, token: OssToken, body: RequestBody,
    ): Request {
        val date = httpDate(clock())
        val resource = "/${target.bucket}/${target.objectKey.trimStart('/')}$subResource"
        val auth = "OSS ${token.accessKeyId}:" +
            sign(token.accessKeySecret, method, contentMd5, contentType, date, ossHeaders, resource)
        val b = Request.Builder().url(url).method(method, body)
            .header("Date", date)
            .header("Content-Type", contentType)
            .header("User-Agent", Cloud115Const.OSS_UA)
            .header("Authorization", auth)
        if (contentMd5.isNotEmpty()) b.header("Content-MD5", contentMd5)
        ossHeaders.forEach { (k, v) -> b.header(k, v) }
        return b.build()
    }

    companion object {
        const val OCTET = "application/octet-stream"
        const val XML = "application/xml"
        const val DEFAULT_PART_SIZE = 8L * 1024 * 1024
        /** Above this, use multipart (simple PUT is fine for typical audio files). */
        const val MULTIPART_THRESHOLD = 100L * 1024 * 1024
        private const val TOKEN_REFRESH_MS = 50 * 60_000L

        /** OSS V1 signature: base64(HMAC-SHA1(secret, VERB\nMD5\nType\nDate\nOssHeaders+Resource)). */
        internal fun sign(
            secret: String, method: String, contentMd5: String, contentType: String, date: String,
            ossHeaders: Map<String, String>, resource: String,
        ): String {
            val canonHeaders = ossHeaders.entries
                .map { it.key.lowercase(Locale.ROOT) to it.value.trim() }
                .filter { it.first.startsWith("x-oss-") }
                .sortedBy { it.first }
                .joinToString("") { "${it.first}:${it.second}\n" }
            val toSign = "$method\n$contentMd5\n$contentType\n$date\n$canonHeaders$resource"
            val mac = Mac.getInstance("HmacSHA1")
            mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA1"))
            return Base64.getEncoder().encodeToString(mac.doFinal(toSign.toByteArray(Charsets.UTF_8)))
        }

        internal fun httpDate(d: Date): String =
            SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US)
                .apply { timeZone = TimeZone.getTimeZone("GMT") }.format(d)

        private fun b64(s: String) = Base64.getEncoder().encodeToString(s.toByteArray(Charsets.UTF_8))

        internal fun xmlTag(xml: String, tag: String): String? =
            Regex("<$tag>([^<]*)</$tag>").find(xml)?.groupValues?.get(1)

        private fun fileBody(file: File, offset: Long, length: Long): RequestBody = object : RequestBody() {
            override fun contentType() = OCTET.toMediaType()
            override fun contentLength() = length
            override fun writeTo(sink: BufferedSink) {
                RandomAccessFile(file, "r").use { raf ->
                    raf.seek(offset)
                    val input = java.nio.channels.Channels.newInputStream(raf.channel)
                    input.source().use { src ->
                        var remaining = length
                        val buffer = okio.Buffer()
                        while (remaining > 0) {
                            val n = src.read(buffer, minOf(remaining, 64 * 1024L))
                            if (n < 0) throw IOException("文件在上传中被截断")
                            sink.write(buffer, n)
                            remaining -= n
                        }
                    }
                }
            }
        }
    }
}
