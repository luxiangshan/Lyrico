package com.lonx.lyrico.remote.integration

import java.io.File
import java.security.MessageDigest

/**
 * Small disk cache of embedded front covers of remote songs, so song lists show covers right after a
 * scan without touching the network. Entries are keyed by song uri + file size + mtime; a song known to
 * have no embedded cover is recorded too (so lists don't re-read it). Pure JVM; thread-safe enough for
 * concurrent readers/writers (atomic rename on write).
 */
class RemoteCoverCache(
    private val dir: File,
    private val maxBytes: Long = DEFAULT_MAX_BYTES,
) {
    sealed interface Lookup {
        data class Hit(val bytes: ByteArray) : Lookup
        data object NoCover : Lookup
        data object Miss : Lookup
    }

    private val trimLock = Any()
    @Volatile private var writesSinceTrim = 0

    fun get(uri: String, size: Long, mtime: Long): Lookup {
        val base = baseName(uri, size, mtime)
        val img = File(dir, "$base$IMG")
        if (img.exists()) {
            return runCatching { img.readBytes() }.getOrNull()
                ?.takeIf { it.isNotEmpty() }
                ?.also { img.setLastModified(System.currentTimeMillis()) }
                ?.let { Lookup.Hit(it) }
                ?: Lookup.Miss
        }
        if (File(dir, "$base$NONE").exists()) return Lookup.NoCover
        return Lookup.Miss
    }

    /** True when either a cover or a "no cover" marker is stored. */
    fun has(uri: String, size: Long, mtime: Long): Boolean {
        val base = baseName(uri, size, mtime)
        return File(dir, "$base$IMG").exists() || File(dir, "$base$NONE").exists()
    }

    /** Stores [bytes] (null/empty = the song has no embedded cover). */
    fun put(uri: String, size: Long, mtime: Long, bytes: ByteArray?) {
        dir.mkdirs()
        val base = baseName(uri, size, mtime)
        val target = File(dir, base + if (bytes == null || bytes.isEmpty()) NONE else IMG)
        val tmp = File(dir, "${target.name}.${Thread.currentThread().id}.tmp")
        runCatching {
            tmp.writeBytes(bytes ?: ByteArray(0))
            if (!tmp.renameTo(target)) {
                target.delete()
                tmp.renameTo(target)
            }
        }
        tmp.delete()
        // Drop the opposite marker and entries of older versions of this song.
        File(dir, base + if (target.name.endsWith(IMG)) NONE else IMG).delete()
        val prefix = uriPrefix(uri)
        dir.listFiles { f -> f.name.startsWith(prefix) && f.name != "$base$IMG" && f.name != "$base$NONE" && !f.name.endsWith(".tmp") }?.forEach { it.delete() }
        if (++writesSinceTrim >= TRIM_EVERY) {
            writesSinceTrim = 0
            trim()
        }
    }

    /** Forgets every cached cover of [uri] (file changed / renamed / deleted). */
    fun invalidate(uri: String) {
        val prefix = uriPrefix(uri)
        dir.listFiles { f -> f.name.startsWith(prefix) }?.forEach { it.delete() }
    }

    fun clear() {
        dir.deleteRecursively()
    }

    fun trim() {
        synchronized(trimLock) {
            val files = dir.listFiles { f -> f.isFile && !f.name.endsWith(".tmp") }?.toList() ?: return
            var total = files.sumOf { it.length() }
            if (total <= maxBytes) return
            for (file in files.sortedBy { it.lastModified() }) {
                if (total <= maxBytes) break
                val len = file.length()
                if (file.delete()) total -= len
            }
        }
    }

    private fun uriPrefix(uri: String) = sha1(uri).take(32) + "_"

    private fun baseName(uri: String, size: Long, mtime: Long) = "${uriPrefix(uri)}${size}_$mtime"

    private fun sha1(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    companion object {
        private const val IMG = ".img"
        private const val NONE = ".none"
        private const val TRIM_EVERY = 50
        const val DEFAULT_MAX_BYTES = 64L * 1024 * 1024
    }
}

/** Picks the picture song lists show: the front cover, else the first embedded picture. */
object RemoteCoverPick {
    fun frontCover(pictures: List<com.lonx.audiotag.model.AudioPicture>): ByteArray? {
        val pic = pictures.firstOrNull {
            com.lonx.audiotag.model.AudioPictureType.fromTagLibName(it.pictureType) ==
                com.lonx.audiotag.model.AudioPictureType.FrontCover
        } ?: pictures.firstOrNull()
        return pic?.data?.takeIf { it.isNotEmpty() }
    }
}
