package com.lonx.lyrico.remote.integration

import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.Locale

/**
 * Song / folder addressing for remote locations.
 *
 *  - Song uri (stored in SongEntity.uri):   `remote://<configId>/<percent-encoded path segments>`
 *    e.g. `remote://a1b2c3/My%20Music/%E6%AD%8C.flac`. Encoding keeps `android.net.Uri.parse` happy
 *    (`#`, `?`, spaces) so existing code that calls `toUri()` on song uris does not break.
 *  - Display paths (SongEntity.filePath, FolderEntity.path):  `remote://<configId>/My Music/歌.flac`
 *    (not encoded, human readable, used as folder-tree prefix).
 *
 * Pure Kotlin (no android.net.Uri) so it is unit-testable on the JVM.
 */
object RemoteUri {
    const val SCHEME = "remote"
    const val PREFIX = "remote://"
    const val SOURCE = "REMOTE"

    data class Parsed(val configId: String, val path: String)

    fun isRemote(uriOrPath: String?): Boolean = uriOrPath?.startsWith(PREFIX) == true

    /** Encoded song uri. [path] must start with '/'. */
    fun build(configId: String, path: String): String {
        val normalized = normalizePath(path)
        val encoded = normalized.split('/').joinToString("/") { encodeSegment(it) }
        return PREFIX + configId + encoded
    }

    /** Human-readable path (folder path / filePath). */
    fun displayPath(configId: String, path: String): String {
        val normalized = normalizePath(path)
        return if (normalized == "/") PREFIX + configId else PREFIX + configId + normalized
    }

    /** Parses either an encoded uri or a display path. */
    fun parse(uriOrPath: String): Parsed? {
        if (!isRemote(uriOrPath)) return null
        val rest = uriOrPath.removePrefix(PREFIX)
        val slash = rest.indexOf('/')
        val configId = if (slash < 0) rest else rest.substring(0, slash)
        if (configId.isBlank()) return null
        val rawPath = if (slash < 0) "/" else rest.substring(slash)
        val decoded = rawPath.split('/').joinToString("/") { decodeSegment(it) }
        return Parsed(configId, normalizePath(decoded))
    }

    /** Parses a human-readable display path (FolderEntity.path / SongEntity.filePath); no percent-decoding. */
    fun parseDisplayPath(displayPath: String): Parsed? {
        if (!isRemote(displayPath)) return null
        val rest = displayPath.removePrefix(PREFIX)
        val slash = rest.indexOf('/')
        val configId = if (slash < 0) rest else rest.substring(0, slash)
        if (configId.isBlank()) return null
        return Parsed(configId, normalizePath(if (slash < 0) "/" else rest.substring(slash)))
    }

    fun configIdOf(uriOrPath: String): String? = parse(uriOrPath)?.configId

    fun normalizePath(path: String): String {
        val cleaned = path.replace('\\', '/').split('/').filter { it.isNotEmpty() && it != "." }
        return "/" + cleaned.joinToString("/")
    }

    fun parentPath(path: String): String {
        val normalized = normalizePath(path)
        if (normalized == "/") return "/"
        val parent = normalized.substringBeforeLast('/')
        return parent.ifEmpty { "/" }
    }

    fun childPath(dir: String, name: String): String {
        val normalized = normalizePath(dir)
        return if (normalized == "/") "/$name" else "$normalized/$name"
    }

    fun fileName(path: String): String = normalizePath(path).substringAfterLast('/')

    /** Same extension set as MediaScanner (local SAF scan). */
    val SUPPORTED_AUDIO_EXTENSIONS = setOf(
        "mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "wma", "ape"
    )

    fun isSupportedAudio(name: String): Boolean =
        name.substringAfterLast('.', "").lowercase(Locale.ROOT) in SUPPORTED_AUDIO_EXTENSIONS

    private fun encodeSegment(segment: String): String {
        if (segment.isEmpty()) return segment
        val bytes = segment.toByteArray(StandardCharsets.UTF_8)
        val sb = StringBuilder()
        for (b in bytes) {
            val c = b.toInt() and 0xFF
            val ch = c.toChar()
            if (ch in 'a'..'z' || ch in 'A'..'Z' || ch in '0'..'9' || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
                sb.append(ch)
            } else {
                sb.append('%').append(HEX[c shr 4]).append(HEX[c and 0x0F])
            }
        }
        return sb.toString()
    }

    private fun decodeSegment(segment: String): String {
        if (!segment.contains('%')) return segment
        // URLDecoder turns '+' into ' '; protect literal plus signs first.
        return try {
            URLDecoder.decode(segment.replace("+", "%2B"), "UTF-8")
        } catch (_: IllegalArgumentException) {
            segment
        }
    }

    private val HEX = "0123456789ABCDEF".toCharArray()
}
