package com.lonx.lyrico.remote.webdav

import com.lonx.lyrico.remote.RemoteAuthException
import okhttp3.OkHttpClient
import okhttp3.Response
import java.io.ByteArrayOutputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.TimeUnit

/** Path helpers shared by the WebDAV and OpenList providers. Remote paths are '/'-separated and start with '/'. */
internal object RemotePaths {

    /** Collapses duplicate slashes, removes "." segments and any trailing slash; always starts with '/'. */
    fun normalize(path: String): String {
        val parts = path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
        val out = ArrayList<String>(parts.size)
        for (p in parts) {
            if (p == "..") { if (out.isNotEmpty()) out.removeAt(out.size - 1) } else out.add(p)
        }
        return "/" + out.joinToString("/")
    }

    fun join(dir: String, name: String): String {
        val d = normalize(dir)
        return if (d == "/") "/$name" else "$d/$name"
    }

    fun parent(path: String): String {
        val p = normalize(path)
        val i = p.lastIndexOf('/')
        return if (i <= 0) "/" else p.substring(0, i)
    }

    fun name(path: String): String = normalize(path).substringAfterLast('/')

    /** Percent-encodes one path segment (RFC 3986 unreserved chars kept). */
    fun encodeSegment(segment: String): String {
        val sb = StringBuilder()
        for (b in segment.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            val ch = c.toChar()
            if (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '-' || ch == '.' || ch == '_' || ch == '~') {
                sb.append(ch)
            } else {
                sb.append('%').append(HEX[c shr 4]).append(HEX[c and 0xf])
            }
        }
        return sb.toString()
    }

    /** Encodes every segment of an absolute path, keeping the '/' separators. */
    fun encodePath(path: String): String =
        normalize(path).split('/').joinToString("/") { if (it.isEmpty()) "" else encodeSegment(it) }

    /**
     * Strict percent-decoding (UTF-8). Unlike URLDecoder, '+' stays '+'. Malformed escapes are kept literally.
     */
    fun percentDecode(s: String): String {
        if (s.indexOf('%') < 0) return s
        val out = ByteArrayOutputStream(s.length)
        var i = 0
        while (i < s.length) {
            val c = s[i]
            if (c == '%' && i + 2 < s.length) {
                val hi = Character.digit(s[i + 1], 16)
                val lo = Character.digit(s[i + 2], 16)
                if (hi >= 0 && lo >= 0) {
                    out.write((hi shl 4) or lo)
                    i += 3
                    continue
                }
            }
            val n = if (Character.isHighSurrogate(c) && i + 1 < s.length) 2 else 1
            out.write(s.substring(i, i + n).toByteArray(Charsets.UTF_8))
            i += n
        }
        return out.toString("UTF-8")
    }

    private val HEX = "0123456789ABCDEF".toCharArray()
}

internal object HttpSupport {

    /** Default client for providers; the app may pass its own (e.g. with logging) instead. */
    val defaultClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS)
            .followRedirects(true)
            .followSslRedirects(true)
            .build()
    }

    /** Range header value for [offset]/[length] (length < 0 = to end), or null when the whole file is wanted. */
    fun rangeHeader(offset: Long, length: Long): String? {
        if (offset <= 0 && length < 0) return null
        val start = maxOf(0, offset)
        return if (length < 0) "bytes=$start-" else "bytes=$start-${start + length - 1}"
    }

    /**
     * Turns a GET response (already checked for success or 416) into a stream positioned at [offset] and limited
     * to [length] bytes. Handles servers that ignore Range and answer 200 with the full body.
     */
    fun rangedBody(response: Response, offset: Long, length: Long): InputStream {
        if (response.code == 416 || length == 0L) {
            response.close()
            return java.io.ByteArrayInputStream(ByteArray(0))
        }
        val raw = response.body.byteStream()
        val closer = ResponseClosingStream(raw, response)
        if (response.code == 206) {
            return if (length < 0) closer else LimitedStream(closer, length)
        }
        // 200: server ignored the Range header -> skip and limit ourselves.
        if (offset > 0) skipFully(closer, offset)
        return if (length < 0) closer else LimitedStream(closer, length)
    }

    private fun skipFully(input: InputStream, n: Long) {
        var left = n
        val buf = ByteArray(8192)
        while (left > 0) {
            val skipped = input.skip(left)
            if (skipped > 0) { left -= skipped; continue }
            val r = input.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (r < 0) return
            left -= r
        }
    }

    /** Short readable snippet of an error body (for messages). */
    fun bodySnippet(response: Response): String = try {
        val t = response.peekBody(2048).string().replace(Regex("\\s+"), " ").trim()
        if (t.isEmpty()) "" else ": " + t.take(200)
    } catch (_: Exception) { "" }

    fun authFailure(what: String, response: Response): RemoteAuthException =
        RemoteAuthException("$what: authentication failed (HTTP ${response.code}). Check username and password.")

    fun httpFailure(what: String, response: Response): IOException =
        IOException("$what failed: HTTP ${response.code} ${response.message}".trim() + bodySnippet(response))
}

private class ResponseClosingStream(input: InputStream, private val response: Response) : FilterInputStream(input) {
    override fun close() {
        try { super.close() } finally { response.close() }
    }
}

private class LimitedStream(input: InputStream, private var remaining: Long) : FilterInputStream(input) {
    override fun read(): Int {
        if (remaining <= 0) return -1
        val r = super.read()
        if (r >= 0) remaining--
        return r
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (remaining <= 0) return -1
        val r = super.read(b, off, minOf(len.toLong(), remaining).toInt())
        if (r > 0) remaining -= r
        return r
    }

    override fun skip(n: Long): Long {
        val s = super.skip(minOf(n, remaining))
        if (s > 0) remaining -= s
        return s
    }

    override fun available(): Int = minOf(super.available().toLong(), remaining).toInt()
    override fun markSupported(): Boolean = false
}
