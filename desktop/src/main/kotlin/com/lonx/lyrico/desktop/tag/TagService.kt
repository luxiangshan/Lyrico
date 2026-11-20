package com.lonx.lyrico.desktop.tag

import java.io.File

object TagService {
    /** Extensions scanned into the library. */
    val audioExtensions = setOf(
        "mp3", "flac", "m4a", "mp4", "m4b", "ogg", "oga", "opus", "wav", "aif", "aiff", "aifc",
        "wma", "dsf", "ape", "wv",
    )

    fun isAudio(name: String): Boolean = name.substringAfterLast('.', "").lowercase() in audioExtensions

    fun backendFor(file: File): TagBackend = when (file.extension.lowercase()) {
        "opus" -> OpusBackend
        "ape", "wv" -> ApeBackend
        "ogg", "oga" -> if (isOggOpus(file)) OpusBackend else JaudiotaggerBackend
        else -> JaudiotaggerBackend
    }

    private fun isOggOpus(file: File): Boolean = try {
        file.inputStream().use { s ->
            val b = ByteArray(36)
            val n = s.readNBytes(b, 0, 36)
            n >= 36 && String(b, 28, 8, Charsets.US_ASCII) == "OpusHead"
        }
    } catch (_: Exception) {
        false
    }

    fun read(file: File, withCover: Boolean = false): TagData = backendFor(file).read(file, withCover)

    fun write(file: File, edit: TagEdit, options: TagWriteOptions = TagWriteOptions()) =
        backendFor(file).write(file, edit, options)
}
