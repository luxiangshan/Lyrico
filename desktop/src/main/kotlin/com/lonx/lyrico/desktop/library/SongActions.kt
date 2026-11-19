package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.TagData
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagService
import java.io.File

/** What the editor shows for one song. */
class EditorData(
    val song: Song,
    val tag: TagData,
    /** Lyrics to display: tag lyrics, or the adjacent .lrc when the tag has none. */
    val displayLyrics: String,
    val lyricsFromLrc: Boolean,
)

class SaveResult(val song: Song, val messages: List<String>)

enum class LrcExportOutcome { EXPORTED, NO_LYRICS, EXISTS_SKIPPED, FAILED }

/** Blocking song operations shared by the UI; call off the UI thread. */
class SongActions(private val settings: () -> AppSettings, private val storeFor: (Song) -> SongStore) {

    fun load(song: Song): EditorData {
        val store = storeFor(song)
        val file = store.fileFor(song)
        val tag = TagService.read(file, withCover = true)
        var display = tag.lyrics
        var fromLrc = false
        if (display.isBlank() && settings().autoLoadAdjacentLrc) {
            val lrc = try { store.readLrc(song) } catch (_: Exception) { null }
            if (!lrc.isNullOrBlank()) { display = lrc; fromLrc = true }
        }
        val updated = store.refreshStat(song.withTag(tag), file).copy(hasLrc = song.hasLrc || fromLrc)
        return EditorData(updated, tag, display, fromLrc)
    }

    /**
     * Saves one song.
     * - Tag lyrics are written when [target] includes the tag and [lyrics] differs from [originalTagLyrics].
     * - The .lrc is written when [target] includes LRC and [lyrics] is not blank.
     */
    fun save(song: Song, edit: TagEdit, lyrics: String, originalTagLyrics: String, target: LyricsTarget): SaveResult {
        val s = settings()
        val store = storeFor(song)
        val messages = ArrayList<String>()
        val normalized = LrcFiles.normalize(lyrics)
        val tagLyrics = if (target.writesTag && normalized != LrcFiles.normalize(originalTagLyrics)) normalized else null
        val tagEdit = edit.copy(lyrics = tagLyrics)
        var updated = song
        if (!tagEdit.isEmpty) {
            val file = store.fileFor(song)
            TagService.write(file, tagEdit, s.tagOptions)
            store.commit(song, file)
            updated = store.refreshStat(song.withTag(TagService.read(file, false)), file)
            messages += "已保存标签"
        }
        if (target.writesLrc) {
            if (normalized.isBlank()) {
                messages += "歌词为空，未生成 LRC 文件"
            } else {
                val where = store.writeLrc(song, normalized, s.lrcOptions)
                updated = updated.copy(hasLrc = true)
                messages += "已保存 LRC：$where"
            }
        }
        if (messages.isEmpty()) messages += "没有需要保存的更改"
        return SaveResult(updated, messages)
    }

    /** Batch edit of common fields/cover (lyrics untouched). */
    fun applyEdit(song: Song, edit: TagEdit): Song {
        if (edit.isEmpty) return song
        val store = storeFor(song)
        val file = store.fileFor(song)
        TagService.write(file, edit, settings().tagOptions)
        store.commit(song, file)
        return store.refreshStat(song.withTag(TagService.read(file, false)), file)
    }

    /** Exports the tag lyrics of [song] to its .lrc. */
    fun exportLrc(song: Song, overwrite: Boolean): Pair<LrcExportOutcome, Song> {
        val store = storeFor(song)
        if (song.hasLrc && !overwrite) return LrcExportOutcome.EXISTS_SKIPPED to song
        val file = store.fileFor(song)
        val lyrics = TagService.read(file, false).lyrics
        if (lyrics.isBlank()) return LrcExportOutcome.NO_LYRICS to song
        store.writeLrc(song, LrcFiles.normalize(lyrics), settings().lrcOptions)
        return LrcExportOutcome.EXPORTED to song.copy(hasLrc = true)
    }

    /** Writes the adjacent .lrc (or [lrcText] when given) into the tag. Returns null when no .lrc exists. */
    fun importLrcToTag(song: Song, lrcText: String? = null): Song? {
        val store = storeFor(song)
        val text = lrcText ?: store.readLrc(song) ?: return null
        if (text.isBlank()) return null
        val file = store.fileFor(song)
        TagService.write(file, TagEdit(lyrics = LrcFiles.normalize(text)), settings().tagOptions)
        store.commit(song, file)
        return store.refreshStat(song.withTag(TagService.read(file, false)), file)
    }

    fun exportCover(song: Song, dest: File): Boolean {
        val tag = TagService.read(storeFor(song).fileFor(song), withCover = true)
        val c = tag.cover ?: return false
        dest.writeBytes(c.bytes)
        return true
    }
}
