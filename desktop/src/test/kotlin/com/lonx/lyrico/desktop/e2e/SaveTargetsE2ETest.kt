package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.FakeRemote
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.remote.RemoteScanner
import com.lonx.lyrico.desktop.remote.RemoteSongStore
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
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** (e) single-song save with 写入标签 / 保存为 LRC / 两者都要, every format, plus a remote song. */
class SaveTargetsE2ETest {
    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun everyFormatEveryTarget() {
        val actions = SongActions({ AppSettings() }, { LocalSongStore })
        for (ext in E2E.formats) {
            val dir = File(tmp.root, ext)
            val f = E2E.sample(ext, File(dir, "歌 曲.$ext"))
            var song = runBlocking { LibraryScanner.scan(listOf(dir.absolutePath), emptyMap(), 1) { _, _, _ -> } }.single()
            val lrc = File(dir, "歌 曲.lrc")
            // 写入标签
            song = actions.save(song, TagEdit(mapOf(TagField.TITLE to "标题$ext")), "[00:01.00]标签歌词", "", LyricsTarget.TAG).song
            assertEquals("[00:01.00]标签歌词", TagService.read(f).lyrics, ext)
            assertEquals("标题$ext", TagService.read(f)[TagField.TITLE], ext)
            assertFalse(lrc.exists(), "$ext: TAG must not create a .lrc")
            // 保存为 LRC: tag untouched
            song = actions.save(song, TagEdit(), "[00:02.00]只进LRC", "[00:01.00]标签歌词", LyricsTarget.LRC).song
            assertEquals("[00:01.00]标签歌词", TagService.read(f).lyrics, ext)
            assertEquals("[00:02.00]只进LRC", LrcFiles.read(lrc), ext)
            assertTrue(song.hasLrc)
            // 两者都要
            actions.save(song, TagEdit(), "[00:03.00]两者", "[00:01.00]标签歌词", LyricsTarget.BOTH)
            assertEquals("[00:03.00]两者", TagService.read(f).lyrics, ext)
            assertEquals("[00:03.00]两者", LrcFiles.read(lrc), ext)
            // clearing lyrics in the tag
            actions.save(song, TagEdit(), "", "[00:03.00]两者", LyricsTarget.TAG)
            assertEquals("", TagService.read(f).lyrics, ext)
        }
        E2E.report("save-targets", "写入标签/保存为LRC/两者都要 verified for ${E2E.formats.joinToString()} on ${E2E.os}")
    }

    @Test
    fun remoteSongEveryTarget() {
        val remote = FakeRemote()
        remote.files["/r/远程.m4a"] = E2E.resourceBytes("/audio/sample.m4a")
        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val actions = SongActions({ AppSettings() }, { store })
        var song = RemoteScanner.songFor("r1", remote.list("/r").single(), false)
        fun remoteTag() = TagService.read(File(tmp.root, "x.m4a").apply { writeBytes(remote.files["/r/远程.m4a"]!!) })
        song = actions.save(actions.load(song).song, TagEdit(), "[00:01.00]远程标签", "", LyricsTarget.TAG).song
        assertEquals("[00:01.00]远程标签", remoteTag().lyrics)
        assertNull(remote.files["/r/远程.lrc"])
        song = actions.save(song, TagEdit(), "[00:02.00]远程LRC", "[00:01.00]远程标签", LyricsTarget.LRC).song
        assertEquals("[00:01.00]远程标签", remoteTag().lyrics)
        assertEquals("[00:02.00]远程LRC", LrcFiles.decode(remote.files["/r/远程.lrc"]!!))
        actions.save(song, TagEdit(), "[00:03.00]都要", "[00:01.00]远程标签", LyricsTarget.BOTH)
        assertEquals("[00:03.00]都要", remoteTag().lyrics)
        assertEquals("[00:03.00]都要", LrcFiles.decode(remote.files["/r/远程.lrc"]!!))
        E2E.report("save-targets", "remote m4a (fake WebDAV): TAG/LRC/BOTH uploaded correctly")
    }
}
