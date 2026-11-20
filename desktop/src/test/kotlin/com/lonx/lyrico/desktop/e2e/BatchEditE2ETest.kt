package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.FakeRemote
import com.lonx.lyrico.desktop.library.BatchChange
import com.lonx.lyrico.desktop.library.BatchCover
import com.lonx.lyrico.desktop.library.BatchEdit
import com.lonx.lyrico.desktop.library.BatchField
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.remote.RemoteScanner
import com.lonx.lyrico.desktop.remote.RemoteSongStore
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.desktop.ui.ImageUtils
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** (b) batch cover over every format, local and remote; (c) batch fields with ticked / unticked checkboxes. */
class BatchEditE2ETest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val actions = SongActions({ AppSettings() }, { LocalSongStore })

    private fun library(): List<Song> {
        for ((i, ext) in E2E.formats.withIndex()) {
            val f = E2E.sample(ext, File(tmp.root, "lib/歌曲 $i.$ext"))
            TagService.write(f, TagEdit(mapOf(TagField.TITLE to "标题 $i", TagField.ARTIST to "歌手 $i", TagField.ALBUM to "同一张专辑",
                TagField.GENRE to "流行", TagField.COMMENT to "注释 $i"), "[00:0$i.00]原歌词 $i"))
        }
        return runBlocking { LibraryScanner.scan(listOf(File(tmp.root, "lib").absolutePath), emptyMap(), 2) { _, _, _ -> } }
            .sortedBy { it.fileName }
    }

    private fun art(name: String) = CoverArt.fromFile(E2E.resourceFile("/audio/$name", File(tmp.root, "img")))

    @Test
    fun batchCoverEveryFormatJpgPngWebpThenRemove() {
        val songs = library()
        assertEquals(E2E.formats.size, songs.size, songs.joinToString { it.fileName })
        for ((img, mime) in listOf("cover.jpg" to "image/jpeg", "cover.png" to "image/png", "cover.webp" to "image/webp")) {
            val a = art(img)
            assertEquals(mime, a.mime)
            assertNotNull(ImageUtils.decode(a.bytes), "$img must decode (the batch editor validates images)")
            val edit = BatchEdit.build(emptyMap(), BatchCover.Replace(a, img))
            val updated = songs.map { actions.applyEdit(it, edit) }
            for (s in updated) {
                val t = TagService.read(File(s.path), withCover = true)
                assertContentEquals(a.bytes, t.cover?.bytes, "${s.fileName} $img")
                assertTrue(s.hasCover, s.fileName)
                // untouched fields survive a cover-only batch edit
                assertEquals("同一张专辑", t[TagField.ALBUM], s.fileName)
                assertTrue(t.lyrics.contains("原歌词"), s.fileName)
            }
            E2E.report("batch-cover", "$img -> ${updated.size} files (${E2E.formats.joinToString()}): cover bytes read back identical on ${E2E.os}")
        }
        val removed = songs.map { actions.applyEdit(it, BatchEdit.build(emptyMap(), BatchCover.Remove)) }
        for (s in removed) {
            val t = TagService.read(File(s.path), withCover = true)
            assertNull(t.cover, s.fileName)
            assertFalse(t.hasCover, s.fileName)
            assertFalse(s.hasCover, s.fileName)
        }
        E2E.report("batch-cover", "移除封面 -> ${removed.size} files have no cover")
    }

    @Test
    fun batchCoverOnRemoteSongsDownloadsWritesUploads() {
        val remote = FakeRemote()
        for (ext in listOf("mp3", "flac", "m4a", "opus", "wv")) remote.files["/云盘/专辑/远程.$ext"] = E2E.resourceBytes("/audio/sample.$ext")
        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val remoteActions = SongActions({ AppSettings() }, { store })
        val songs = remote.list("/云盘/专辑").filter { !it.isDirectory }.map { RemoteScanner.songFor("r1", it, false) }
        val webp = art("cover.webp")
        val before = remote.files.mapValues { it.value.copyOf() }
        songs.forEach { remoteActions.applyEdit(it, BatchEdit.build(mapOf(BatchField.ALBUM to BatchChange.SetValue("远程专辑")), BatchCover.Replace(webp, "cover.webp"))) }
        for (s in songs) {
            val bytes = remote.files[s.path]!!
            assertFalse(bytes.contentEquals(before[s.path]), "${s.fileName} was uploaded")
            val f = File(tmp.root, "check/" + s.fileName).apply { parentFile.mkdirs(); writeBytes(bytes) }
            val t = TagService.read(f, withCover = true)
            assertContentEquals(webp.bytes, t.cover?.bytes, s.fileName)
            assertEquals("远程专辑", t[TagField.ALBUM], s.fileName)
        }
        E2E.report("batch-cover", "remote (fake WebDAV): ${songs.size} songs downloaded -> cover+album written -> uploaded; read back from uploaded bytes OK")
    }

    @Test
    fun batchFieldsOnlyChangedAreWrittenEmptyNeverClearsExplicitClearDoes() {
        val songs = library()
        val changes = mapOf(
            BatchField.ARTIST to BatchChange.SetValue("统一歌手"),
            BatchField.GENRE to BatchChange.Clear, // explicit 清空
            BatchField.TRACK to BatchChange.SetValue("7"),
            BatchField.YEAR to BatchChange.SetValue("2024"),
            BatchField.LYRICS to BatchChange.SetValue("[00:01.00]批量歌词"),
            BatchField.COMMENT to BatchChange.SetValue("   "), // empty text is NOT a clear
        )
        val edit = BatchEdit.build(changes, BatchCover.Keep)
        assertFalse(TagField.ALBUM in edit.fields)
        assertFalse(TagField.COMMENT in edit.fields, "empty text must never clear")
        assertEquals("", edit.fields[TagField.GENRE])
        assertEquals(com.lonx.lyrico.desktop.tag.CoverChange.Keep, edit.cover)
        assertEquals(listOf("艺术家 → 「统一歌手」", "音轨号 → 「7」", "年份 → 「2024」", "流派 → 清除", "歌词 → 「1 行歌词」"), BatchEdit.describe(changes, BatchCover.Keep))
        for (s in songs) actions.applyEdit(s, edit)
        val tags = songs.map { TagService.read(File(it.path)) }
        for ((s, t) in songs.zip(tags)) {
            val i = s.fileName.substringAfter("歌曲 ").substringBefore('.')
            assertEquals("统一歌手", t[TagField.ARTIST], s.fileName)
            assertEquals("", t[TagField.GENRE], "${s.fileName} genre cleared")
            assertEquals("7", t[TagField.TRACK], s.fileName)
            assertEquals("2024", t[TagField.YEAR], s.fileName)
            assertEquals("[00:01.00]批量歌词", t.lyrics, s.fileName)
            assertEquals("同一张专辑", t[TagField.ALBUM], "${s.fileName} unchanged album kept")
            assertEquals("标题 $i", t[TagField.TITLE], "${s.fileName} unchanged title kept")
            assertEquals("注释 $i", t[TagField.COMMENT], "${s.fileName} blank-text comment kept")
        }
        // shared values / 〈多个值〉 detection
        val shared = BatchEdit.shared(tags)
        assertEquals("统一歌手", shared[BatchField.ARTIST])
        assertEquals("同一张专辑", shared[BatchField.ALBUM])
        assertNull(shared[BatchField.TITLE]) // differs -> 〈多个值〉
        assertNull(shared[BatchField.COMMENT])
        assertEquals("[00:01.00]批量歌词", shared[BatchField.LYRICS])
        E2E.report("batch-fields", "${songs.size} files (${E2E.formats.joinToString()}): changed artist/track/year/lyrics written, explicit 清空 genre cleared, blank-text comment and unchanged album/title kept")
    }
}
