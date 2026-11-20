package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField

/** Fields of the batch editor, in display order. */
enum class BatchField(val label: String, val tag: TagField?) {
    TITLE("标题", TagField.TITLE),
    ARTIST("艺术家", TagField.ARTIST),
    ALBUM("专辑", TagField.ALBUM),
    ALBUM_ARTIST("专辑艺术家", TagField.ALBUM_ARTIST),
    TRACK("音轨号", TagField.TRACK),
    TRACK_TOTAL("音轨总数", TagField.TRACK_TOTAL),
    DISC("碟号", TagField.DISC),
    DISC_TOTAL("碟片总数", TagField.DISC_TOTAL),
    YEAR("年份", TagField.YEAR),
    GENRE("流派", TagField.GENRE),
    COMPOSER("作曲", TagField.COMPOSER),
    LYRICIST("作词", TagField.LYRICIST),
    COMMENT("注释", TagField.COMMENT),
    LYRICS("歌词", null),
    COVER("封面", null);

    val isText get() = this != COVER
}

/** What the batch editor will do to one field. Fields without a change are never written. */
sealed interface BatchChange {
    /** Write this (non-empty) value to every selected song. */
    data class SetValue(val value: String) : BatchChange
    /** Remove the field from every selected song (only via the explicit 清空 button). */
    data object Clear : BatchChange
}

/** Cover action of the batch editor: Keep unless an image was chosen or 移除封面 was pressed. */
sealed interface BatchCover {
    data object Keep : BatchCover
    class Replace(val art: CoverArt, val name: String?) : BatchCover
    data object Remove : BatchCover
}

object BatchEdit {
    /**
     * Builds the edit from the fields the user actually changed. A field missing from [changes] is not touched, so every
     * song keeps its own value; an empty text is never treated as "clear" (only [BatchChange.Clear] clears).
     * Lyrics go into the tag (not into .lrc files).
     */
    fun build(changes: Map<BatchField, BatchChange>, cover: BatchCover): TagEdit {
        val fields = LinkedHashMap<TagField, String>()
        var lyrics: String? = null
        for ((f, c) in changes) {
            if (f == BatchField.COVER) continue
            val value = when (c) {
                BatchChange.Clear -> ""
                is BatchChange.SetValue -> c.value.trim().ifEmpty { null } ?: continue // empty text = no change
            }
            if (f == BatchField.LYRICS) lyrics = if (value.isEmpty()) "" else LrcFiles.normalize(value).trimEnd()
            else fields[f.tag!!] = value
        }
        val coverChange = when (cover) {
            BatchCover.Keep -> CoverChange.Keep
            BatchCover.Remove -> CoverChange.Remove
            is BatchCover.Replace -> CoverChange.Replace(cover.art)
        }
        return TagEdit(fields, lyrics, coverChange)
    }

    /** One line per change for the confirmation dialog, e.g. "专辑 → 「叶惠美」", "流派 → 清除". */
    fun describe(changes: Map<BatchField, BatchChange>, cover: BatchCover): List<String> {
        val out = ArrayList<String>()
        for (f in BatchField.entries) {
            if (f == BatchField.COVER) continue
            when (val c = changes[f]) {
                BatchChange.Clear -> out += "${f.label} → 清除"
                is BatchChange.SetValue -> c.value.trim().takeIf { it.isNotEmpty() }?.let { v ->
                    out += "${f.label} → 「${if (f == BatchField.LYRICS) "${v.lines().size} 行歌词" else v.take(60)}」"
                }
                null -> Unit
            }
        }
        when (cover) {
            BatchCover.Keep -> Unit
            BatchCover.Remove -> out += "封面 → 移除"
            is BatchCover.Replace -> out += "封面 → 替换为「${cover.name ?: "所选图片"}」"
        }
        return out
    }

    /** Value shared by every song, or null when they differ or a song could not be read. */
    fun shared(tags: List<TagData?>): Map<BatchField, String?> {
        val out = LinkedHashMap<BatchField, String?>()
        for (f in BatchField.entries) {
            if (!f.isText) continue
            val vals = tags.map { t ->
                when {
                    t == null -> null
                    f == BatchField.LYRICS -> LrcFiles.normalize(t.lyrics).trimEnd()
                    else -> t[f.tag!!]
                }
            }
            out[f] = if (vals.any { it == null }) null else vals.distinct().singleOrNull()
        }
        return out
    }

    /** Values known from the library index alone (used until the tags are read). */
    fun fromIndex(songs: List<Song>): Map<BatchField, String?> {
        fun common(get: (Song) -> String) = songs.map(get).distinct().singleOrNull()
        return mapOf(
            BatchField.TITLE to common { it.title }, BatchField.ARTIST to common { it.artist }, BatchField.ALBUM to common { it.album },
            BatchField.ALBUM_ARTIST to common { it.albumArtist }, BatchField.TRACK to common { it.track }, BatchField.DISC to common { it.disc },
            BatchField.YEAR to common { it.year }, BatchField.GENRE to common { it.genre },
        )
    }
}
