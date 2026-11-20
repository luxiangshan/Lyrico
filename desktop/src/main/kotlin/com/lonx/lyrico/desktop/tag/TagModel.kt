package com.lonx.lyrico.desktop.tag

import java.io.File

/** Editable text fields, in editor order. */
enum class TagField(val label: String) {
    TITLE("标题"),
    ARTIST("艺术家"),
    ALBUM("专辑"),
    ALBUM_ARTIST("专辑艺术家"),
    TRACK("音轨号"),
    TRACK_TOTAL("音轨总数"),
    DISC("碟号"),
    DISC_TOTAL("碟片总数"),
    YEAR("年份"),
    GENRE("流派"),
    COMPOSER("作曲"),
    LYRICIST("作词"),
    COMMENT("注释"),
}

class CoverArt(val bytes: ByteArray, val mime: String) {
    val extension: String
        get() = when {
            mime.contains("png", true) -> "png"
            mime.contains("webp", true) -> "webp"
            mime.contains("gif", true) -> "gif"
            mime.contains("bmp", true) -> "bmp"
            else -> "jpg"
        }

    companion object {
        fun sniffMime(bytes: ByteArray): String = when {
            bytes.size > 8 && bytes[0] == 0x89.toByte() && bytes[1] == 'P'.code.toByte() -> "image/png"
            bytes.size > 12 && bytes[0] == 'R'.code.toByte() && bytes[8] == 'W'.code.toByte() -> "image/webp"
            bytes.size > 3 && bytes[0] == 'G'.code.toByte() && bytes[1] == 'I'.code.toByte() -> "image/gif"
            bytes.size > 2 && bytes[0] == 'B'.code.toByte() && bytes[1] == 'M'.code.toByte() -> "image/bmp"
            else -> "image/jpeg"
        }

        fun fromFile(file: File): CoverArt {
            val bytes = file.readBytes()
            return CoverArt(bytes, sniffMime(bytes))
        }
    }
}

data class AudioInfo(
    val format: String = "",
    val durationSeconds: Int = 0,
    val bitrateKbps: Int = 0,
    val sampleRate: Int = 0,
    val channels: String = "",
)

class TagData(
    val fields: Map<TagField, String>,
    /** Lyrics stored inside the tag ("" when none). */
    val lyrics: String,
    /** Cover bytes; only loaded when requested. */
    val cover: CoverArt?,
    val hasCover: Boolean,
    val audio: AudioInfo,
) {
    operator fun get(field: TagField): String = fields[field].orEmpty()
}

sealed interface CoverChange {
    data object Keep : CoverChange
    data object Remove : CoverChange
    class Replace(val art: CoverArt) : CoverChange
}

/**
 * Changes to apply. Only fields present in [fields] are touched; an empty value deletes the field.
 * [lyrics] null = keep, "" = delete the lyrics stored in the tag.
 */
data class TagEdit(
    val fields: Map<TagField, String> = emptyMap(),
    val lyrics: String? = null,
    val cover: CoverChange = CoverChange.Keep,
) {
    val isEmpty: Boolean get() = fields.isEmpty() && lyrics == null && cover == CoverChange.Keep
}

data class TagWriteOptions(
    /** "2.3" (best Windows Explorer compatibility) or "2.4". */
    val id3Version: String = "2.3",
    /** ISO-639-2 language of the ID3 USLT frame: "chi", "XXX", "eng"… */
    val usltLanguage: String = "chi",
)

class TagException(message: String, cause: Throwable? = null) : Exception(message, cause)

interface TagBackend {
    fun read(file: File, withCover: Boolean): TagData
    fun write(file: File, edit: TagEdit, options: TagWriteOptions)
}

/** Splits "3/12" into ("3","12"). */
internal fun splitNumberPair(value: String): Pair<String, String> {
    val v = value.trim()
    val i = v.indexOf('/')
    return if (i < 0) v to "" else v.substring(0, i).trim() to v.substring(i + 1).trim()
}
