package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.FakeRemote
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.LrcExportOutcome
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.lyrics.LrcConflict
import com.lonx.lyrico.desktop.lyrics.LrcExportPlan
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.remote.RemoteScanner
import com.lonx.lyrico.desktop.remote.RemoteSongStore
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagService
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/** (d) LRC export to a chosen directory and to the song folder, with same-name collisions. */
class LrcExportE2ETest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val actions = SongActions({ AppSettings() }, { LocalSongStore })

    /** Three "晴天" in different folders (mp3/flac/m4a), plus one song without lyrics. */
    private fun library(): List<Song> {
        val lib = File(tmp.root, "lib")
        for ((i, ext) in listOf("mp3", "flac", "m4a").withIndex()) {
            val f = E2E.sample(ext, File(lib, "文件夹$i/晴天.$ext"))
            TagService.write(f, TagEdit(lyrics = "[00:01.00]来自文件夹$i"))
        }
        E2E.sample("opus", File(lib, "文件夹0/无歌词.opus"))
        return runBlocking { LibraryScanner.scan(listOf(lib.absolutePath), emptyMap(), 2) { _, _, _ -> } }.sortedBy { it.path }
    }

    private fun export(songs: List<Song>, plan: LrcExportPlan) = songs.map { actions.exportLrc(it, plan) }

    private fun names(dir: File) = dir.listFiles().orEmpty().map { it.name }.sorted()

    @Test
    fun chosenDirectoryAddNumber() {
        val songs = library()
        val out = File(tmp.root, "导出")
        out.mkdirs()
        val r = export(songs, LrcExportPlan(out, LrcConflict.NUMBER))
        assertEquals(listOf("晴天 (2).lrc", "晴天 (3).lrc", "晴天.lrc"), names(out))
        assertEquals(1, r.count { it.outcome == LrcExportOutcome.NO_LYRICS })
        assertEquals(2, r.count { it.outcome == LrcExportOutcome.RENAMED })
        val texts = names(out).map { LrcFiles.read(File(out, it)) }.toSet()
        assertEquals(setOf("[00:01.00]来自文件夹0", "[00:01.00]来自文件夹1", "[00:01.00]来自文件夹2"), texts)
        // nothing written next to the songs
        assertTrue(songs.none { LrcFiles.findAdjacent(File(it.path)) != null })
        // second run: existing files count as collisions too
        export(songs, LrcExportPlan(out, LrcConflict.NUMBER))
        assertEquals(6, names(out).size, names(out).toString())
        E2E.report("lrc-export", "chosen dir + 重名时加序号: ${names(out)}")
    }

    @Test
    fun chosenDirectorySkipAndOverwrite() {
        val songs = library()
        val out = File(tmp.root, "out").apply { mkdirs() }
        File(out, "晴天.LRC").writeText("[00:00.00]旧文件") // differently cased, pre-existing
        val skip = export(songs, LrcExportPlan(out, LrcConflict.SKIP))
        assertEquals(3, skip.count { it.outcome == LrcExportOutcome.EXISTS_SKIPPED })
        assertEquals(listOf("晴天.LRC"), names(out))
        assertEquals("[00:00.00]旧文件", LrcFiles.read(File(out, "晴天.LRC")))

        val over = export(songs, LrcExportPlan(out, LrcConflict.OVERWRITE))
        assertEquals(3, over.count { it.outcome == LrcExportOutcome.OVERWRITTEN })
        assertEquals(listOf("晴天.LRC"), names(out), "existing file reused (no second case-variant)")
        assertEquals("[00:01.00]来自文件夹2", LrcFiles.read(File(out, "晴天.LRC")), "last one wins")
        E2E.report("lrc-export", "chosen dir + 跳过: kept pre-existing 晴天.LRC; + 覆盖: overwrote it in place (${names(out)})")
    }

    @Test
    fun songFolderDefaultSkipAndOverwrite() {
        val songs = library()
        val first = export(songs, LrcExportPlan(null, LrcConflict.SKIP))
        assertEquals(3, first.count { it.outcome == LrcExportOutcome.EXPORTED })
        for (s in songs.filter { it.fileName.startsWith("晴天") }) {
            val lrc = File(File(s.path).parentFile, "晴天.lrc")
            assertTrue(lrc.isFile, lrc.path)
            assertTrue(LrcFiles.read(lrc).startsWith("[00:01.00]来自"))
            lrc.writeText("[00:00.00]用户改过")
        }
        val skipped = export(songs, LrcExportPlan(null, LrcConflict.SKIP))
        assertEquals(3, skipped.count { it.outcome == LrcExportOutcome.EXISTS_SKIPPED })
        // NUMBER is not used in song folders (falls back to skip, the .lrc must keep the song's name)
        val numbered = export(songs, LrcExportPlan(null, LrcConflict.NUMBER))
        assertEquals(3, numbered.count { it.outcome == LrcExportOutcome.EXISTS_SKIPPED })
        val over = export(songs, LrcExportPlan(null, LrcConflict.OVERWRITE))
        assertEquals(3, over.count { it.outcome == LrcExportOutcome.OVERWRITTEN })
        for (s in songs.filter { it.fileName.startsWith("晴天") }) {
            assertTrue(LrcFiles.read(File(File(s.path).parentFile, "晴天.lrc")).startsWith("[00:01.00]来自"))
            assertEquals(listOf("晴天.lrc"), File(s.path).parentFile.listFiles().orEmpty().filter { it.extension.equals("lrc", true) }.map { it.name })
        }
        E2E.report("lrc-export", "song folders: exported next to each song; 跳过 kept user edits; 覆盖 replaced them")
    }

    @Test
    fun remoteSongsLocalDirectoryAndRemoteFolder() {
        val remote = FakeRemote()
        val local = File(tmp.root, "seed.flac")
        E2E.sample("flac", local)
        TagService.write(local, TagEdit(lyrics = "[00:01.00]远程歌词"))
        remote.files["/网盘/A/晴天.flac"] = local.readBytes()
        remote.files["/网盘/B/晴天.flac"] = local.readBytes()
        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val ra = SongActions({ AppSettings() }, { store })
        val songs = listOf("/网盘/A", "/网盘/B").map { d -> RemoteScanner.songFor("r1", remote.list(d).single(), false) }
        val out = File(tmp.root, "本地导出").apply { mkdirs() }
        val r = songs.map { ra.exportLrc(it, LrcExportPlan(out, LrcConflict.NUMBER)) }
        assertEquals(listOf("晴天 (2).lrc", "晴天.lrc"), names(out))
        assertTrue(r.all { it.where!!.startsWith(out.absolutePath) })
        assertFalse(remote.files.keys.any { it.endsWith(".lrc") }, "nothing uploaded when exporting to a local directory")
        // no directory: uploaded next to the remote song
        val up = songs.map { ra.exportLrc(it, LrcExportPlan(null, LrcConflict.OVERWRITE)) }
        assertTrue(up.all { it.outcome == LrcExportOutcome.EXPORTED })
        assertEquals("[00:01.00]远程歌词", LrcFiles.decode(remote.files["/网盘/A/晴天.lrc"]!!))
        assertEquals("[00:01.00]远程歌词", LrcFiles.decode(remote.files["/网盘/B/晴天.lrc"]!!))
        E2E.report("lrc-export", "remote songs: local dir -> ${names(out)} (no upload); no dir -> uploaded /网盘/A/晴天.lrc, /网盘/B/晴天.lrc")
    }

    @Test
    fun editorLyricsOverride() {
        val songs = library()
        val s = songs.first { it.fileName == "晴天.mp3" }
        val out = File(tmp.root, "single").apply { mkdirs() }
        val r = actions.exportLrc(s, LrcExportPlan(out, LrcConflict.OVERWRITE), "[00:05.00]编辑框里的歌词\r\n[00:06.00]第二行")
        assertEquals(LrcExportOutcome.EXPORTED, r.outcome)
        assertEquals("[00:05.00]编辑框里的歌词\n[00:06.00]第二行", LrcFiles.read(File(out, "晴天.lrc")))
    }
}
