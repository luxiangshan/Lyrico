package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.LrcExportOutcome
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.library.SongSorting
import com.lonx.lyrico.desktop.library.SortKey
import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcExportPlan
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SongActionsTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private var settings = AppSettings()
    private val actions = SongActions({ settings }, { LocalSongStore })
    private val lrc = "[00:01.00]第一行\n[00:02.00]第二行"

    private fun sample(ext: String, name: String): File {
        val f = File(tmp.root, name)
        javaClass.getResourceAsStream("/audio/sample.$ext")!!.use { i -> f.outputStream().use { i.copyTo(it) } }
        return f
    }

    private fun scan() = runBlocking { LibraryScanner.scan(listOf(tmp.root.absolutePath), emptyMap(), 2) { _, _, _ -> } }

    @Test
    fun saveTargets() {
        val f = sample("mp3", "a.mp3")
        val song = scan().single()
        // TAG only
        var r = actions.save(song, TagEdit(mapOf(TagField.TITLE to "标题")), lrc, "", LyricsTarget.TAG)
        assertEquals(lrc, TagService.read(f).lyrics)
        assertFalse(File(tmp.root, "a.lrc").exists())
        assertEquals("标题", r.song.title)
        assertTrue(r.song.hasTagLyrics)
        // LRC only: tag lyrics untouched, lrc created
        r = actions.save(r.song, TagEdit(), "$lrc\n[00:03.00]新", lrc, LyricsTarget.LRC)
        assertEquals(lrc, TagService.read(f).lyrics)
        assertEquals("$lrc\n[00:03.00]新", LrcFiles.read(File(tmp.root, "a.lrc")))
        assertTrue(r.song.hasLrc)
        // BOTH with BOM
        settings = settings.copy(lrcBom = true)
        actions.save(r.song, TagEdit(), "[00:00.00]x", lrc, LyricsTarget.BOTH)
        assertEquals("[00:00.00]x", TagService.read(f).lyrics)
        val bytes = File(tmp.root, "a.lrc").readBytes()
        assertEquals(0xEF.toByte(), bytes[0])
        assertEquals("[00:00.00]x", LrcFiles.read(File(tmp.root, "a.lrc")))
    }

    @Test
    fun adjacentLrcDisplayedButNotWrittenUnlessChanged() {
        val f = sample("flac", "b.flac")
        File(tmp.root, "b.lrc").writeText(lrc)
        val song = scan().single()
        assertTrue(song.hasLrc)
        val data = actions.load(song)
        assertTrue(data.lyricsFromLrc)
        assertEquals(lrc, data.displayLyrics)
        // save with TAG target and the displayed lrc text -> written into tag (text differs from tag lyrics "")
        actions.save(data.song, TagEdit(mapOf(TagField.ARTIST to "歌手")), data.displayLyrics, data.tag.lyrics, LyricsTarget.TAG)
        assertEquals(lrc, TagService.read(f).lyrics)
        settings = settings.copy(autoLoadAdjacentLrc = false)
        File(tmp.root, "c.lrc").writeText(lrc)
        sample("flac", "c.flac")
        val c = scan().first { it.fileName == "c.flac" }
        val d = actions.load(c)
        assertFalse(d.lyricsFromLrc)
        assertEquals("", d.displayLyrics)
    }

    @Test
    fun batchExportAndImport() {
        val a = sample("mp3", "a.mp3")
        sample("m4a", "b.m4a")
        TagService.write(a, TagEdit(lyrics = lrc))
        val songs = scan()
        val sa = songs.first { it.fileName == "a.mp3" }
        val sb = songs.first { it.fileName == "b.m4a" }
        val overwrite = LrcExportPlan(null, LrcConflict.OVERWRITE)
        assertEquals(LrcExportOutcome.EXPORTED, actions.exportLrc(sa, overwrite).outcome)
        assertEquals(LrcExportOutcome.NO_LYRICS, actions.exportLrc(sb, overwrite).outcome)
        assertEquals(lrc, LrcFiles.read(File(tmp.root, "a.lrc")))
        val rescanned = scan().first { it.fileName == "a.mp3" }
        assertTrue(rescanned.hasLrc)
        assertEquals(LrcExportOutcome.EXISTS_SKIPPED, actions.exportLrc(rescanned, LrcExportPlan(null, LrcConflict.SKIP)).outcome)

        assertNull(actions.importLrcToTag(sb))
        File(tmp.root, "b.lrc").writeText("[00:09.00]导入")
        val imported = actions.importLrcToTag(sb)
        assertNotNull(imported)
        assertTrue(imported.hasTagLyrics)
        assertEquals("[00:09.00]导入", TagService.read(File(tmp.root, "b.m4a")).lyrics)
    }

    @Test
    fun scanSortFilter() {
        sample("mp3", "z.mp3"); sample("flac", "y.flac"); sample("opus", "x.opus")
        File(tmp.root, "sub").mkdirs()
        sample("ogg", "sub/w.ogg")
        File(tmp.root, "notes.txt").writeText("x")
        val songs = scan()
        assertEquals(4, songs.size)
        actions.applyEdit(songs.first { it.fileName == "z.mp3" }, TagEdit(mapOf(TagField.TITLE to "阿", TagField.ARTIST to "B")))
        val again = runBlocking { LibraryScanner.scan(listOf(tmp.root.absolutePath), songs.associateBy { it.id }, 2) { _, _, _ -> } }
        val sorted = SongSorting.filterAndSort(again, "", SortKey.FILE_NAME, false, null)
        assertEquals(listOf("sub" + File.separator + "w.ogg", "x.opus", "y.flac", "z.mp3"), sorted.map { it.path.removePrefix(tmp.root.absolutePath + File.separator) })
        assertEquals(listOf("z.mp3"), SongSorting.filterAndSort(again, "阿", SortKey.TITLE, false, null).map { it.fileName })
        assertEquals(1, SongSorting.filterAndSort(again, "", SortKey.TITLE, false, File(tmp.root, "sub").absolutePath).size)
    }
}
