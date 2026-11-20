package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField

/** Fields of the batch editor, in display order. Each one has its own "apply" checkbox. */
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

object BatchEdit {
    /**
     * Only [checked] fields are written. A checked text field that is empty deletes that tag; a checked cover
     * with no image ([cover] null) removes the cover. Lyrics go into the tag (not into .lrc files).
     */
    fun build(checked: Set<BatchField>, values: Map<BatchField, String>, cover: CoverArt?): TagEdit {
        val fields = checked.mapNotNull { f -> f.tag?.let { it to values[f].orEmpty().trim() } }.toMap()
        val lyrics = if (BatchField.LYRICS in checked) LrcFiles.normalize(values[BatchField.LYRICS].orEmpty()).trimEnd() else null
        val coverChange = when {
            BatchField.COVER !in checked -> CoverChange.Keep
            cover != null -> CoverChange.Replace(cover)
            else -> CoverChange.Remove
        }
        return TagEdit(fields, lyrics, coverChange)
    }

    /** Checked fields that will be cleared (empty value / no image). */
    fun cleared(checked: Set<BatchField>, values: Map<BatchField, String>, cover: CoverArt?): List<BatchField> =
        BatchField.entries.filter { f ->
            f in checked && if (f == BatchField.COVER) cover == null else values[f].orEmpty().isBlank()
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
