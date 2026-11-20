package com.lonx.lyrico.desktop.library

import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcExportPlan
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

enum class LrcExportOutcome(val label: String) {
    EXPORTED("已导出"),
    OVERWRITTEN("覆盖已有"),
    RENAMED("重名加序号"),
    NO_LYRICS("无歌词"),
    EXISTS_SKIPPED("已存在跳过"),
}

class LrcExportResult(val outcome: LrcExportOutcome, val song: Song, val where: String? = null)

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

    /**
     * Exports lyrics of [song] to a .lrc following [plan]: the tag lyrics, or [lyricsOverride] (the editor's text).
     * With a plan directory the file is written there locally (also for remote songs); otherwise next to the song.
     */
    fun exportLrc(song: Song, plan: LrcExportPlan, lyricsOverride: String? = null): LrcExportResult {
        val store = storeFor(song)
        if (plan.dir == null && plan.conflict == LrcConflict.SKIP && lyricsOverride == null && store.hasLrc(song)) {
            return LrcExportResult(LrcExportOutcome.EXISTS_SKIPPED, song) // skip before downloading a remote song
        }
        val lyrics = lyricsOverride ?: TagService.read(store.fileFor(song), false).lyrics
        if (lyrics.isBlank()) return LrcExportResult(LrcExportOutcome.NO_LYRICS, song)
        val text = LrcFiles.normalize(lyrics)
        val options = settings().lrcOptions
        if (plan.dir == null) {
            val exists = store.hasLrc(song)
            if (exists && plan.conflict == LrcConflict.SKIP) return LrcExportResult(LrcExportOutcome.EXISTS_SKIPPED, song)
            val where = store.writeLrc(song, text, options)
            return LrcExportResult(if (exists) LrcExportOutcome.OVERWRITTEN else LrcExportOutcome.EXPORTED, song.copy(hasLrc = true), where)
        }
        val target = plan.resolve(song.baseName) ?: return LrcExportResult(LrcExportOutcome.EXISTS_SKIPPED, song)
        LrcFiles.write(target.file, text, options)
        val outcome = when (target.kind) {
            LrcExportPlan.Kind.NEW -> LrcExportOutcome.EXPORTED
            LrcExportPlan.Kind.OVERWRITE -> LrcExportOutcome.OVERWRITTEN
            LrcExportPlan.Kind.RENAMED -> LrcExportOutcome.RENAMED
        }
        return LrcExportResult(outcome, song, target.file.absolutePath)
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
