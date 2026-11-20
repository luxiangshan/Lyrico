package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.remote.RemoteScanner
import com.lonx.lyrico.desktop.remote.RemoteSongStore
import com.lonx.lyrico.desktop.remote.RemoteUploadException
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import com.lonx.lyrico.remote.RemoteType
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/** In-memory remote with flat paths. */
class FakeRemote(var rejectUploads: Boolean = false) : RemoteStorage {
    /** Simulates a dropped connection: full reads stop after this many bytes (the stream just ends). */
    var truncateReadsAt: Int? = null
    val files = LinkedHashMap<String, ByteArray>()
    val mtimes = HashMap<String, Long>()
    var clock = 1000L
    var rangeReads = 0
    var fullReads = 0
    override val config = RemoteConfig("r1", RemoteType.WEBDAV, "fake")
    override fun testConnection() {}
    private fun dirs(): Set<String> = files.keys.flatMap { p ->
        val parts = p.trim('/').split('/'); (1 until parts.size).map { "/" + parts.take(it).joinToString("/") }
    }.toSet()
    override fun list(dirPath: String): List<RemoteEntry> {
        val d = dirPath.trimEnd('/')
        val out = ArrayList<RemoteEntry>()
        for ((p, b) in files) if (p.substringBeforeLast('/') == d) out += RemoteEntry(p, p.substringAfterLast('/'), false, b.size.toLong(), mtimes[p] ?: 0)
        for (sub in dirs()) if (sub.substringBeforeLast('/') == d) out += RemoteEntry(sub, sub.substringAfterLast('/'), true)
        return out
    }
    override fun stat(path: String) = files[path]?.let { RemoteEntry(path, path.substringAfterLast('/'), false, it.size.toLong(), mtimes[path] ?: 0) }
    override fun openRead(path: String): InputStream { fullReads++; val b = files[path] ?: throw IOException("HTTP 404"); return ByteArrayInputStream(truncateReadsAt?.let { b.copyOf(minOf(it, b.size)) } ?: b) }
    override fun openRange(path: String, offset: Long, length: Long): InputStream {
        rangeReads++
        val b = files[path]!!
        val end = if (length < 0) b.size else minOf(b.size.toLong(), offset + length).toInt()
        return ByteArrayInputStream(b.copyOfRange(offset.toInt(), end))
    }
    override fun upload(path: String, source: File) {
        if (rejectUploads) throw IOException("Upload $path failed: HTTP 405 Method Not Allowed")
        files[path] = source.readBytes(); mtimes[path] = ++clock
    }
    override fun rename(path: String, newName: String) = path
    override fun delete(path: String) { files.remove(path) }
}

class RemoteSongStoreTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun res(name: String) = javaClass.getResourceAsStream("/audio/$name")!!.readBytes()

    @Test
    fun downloadEditUploadAndLrcNextToFile() {
        val remote = FakeRemote()
        // big cover so the file exceeds the partial-read threshold
        val local = File(tmp.root, "seed.mp3").apply { writeBytes(res("sample.mp3")) }
        TagService.write(local, TagEdit(mapOf(TagField.TITLE to "远程歌"), "[00:01.00]远程", CoverChange.Replace(CoverArt(ByteArray(1_500_000) { 1 }, "image/jpeg"))))
        remote.files["/音乐/周杰伦/晴天.mp3"] = local.readBytes() + ByteArray(3_000_000) // trailing padding: file far bigger than its tag
        remote.files["/音乐/周杰伦/晴天.LRC"] = "[00:00.00]旧".toByteArray(Charsets.UTF_8)
        remote.files["/音乐/a.flac"] = res("sample.flac")

        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val (entries, lrc) = RemoteScanner.listAudio(remote, listOf("/音乐"), { false }) {}
        assertEquals(setOf("/音乐/周杰伦/晴天.mp3", "/音乐/a.flac"), entries.map { it.path }.toSet())
        val e = entries.first { it.name == "晴天.mp3" }
        val song0 = RemoteScanner.songFor("r1", e, "晴天" in lrc["/音乐/周杰伦"].orEmpty())
        assertTrue(song0.hasLrc)
        val (tag, _) = RemoteScanner.readTags(remote, song0, store, File(tmp.root, "head"))
        assertEquals("远程歌", tag[TagField.TITLE])
        assertEquals(2, remote.rangeReads) // 1 MiB head, then the whole 1.5 MB ID3 tag
        assertEquals(0, remote.fullReads)

        var settings = AppSettings()
        val actions = SongActions({ settings }, { store })
        val song = song0.withTag(tag)
        val data = actions.load(song)
        assertEquals(1, remote.fullReads)
        assertEquals("[00:01.00]远程", data.displayLyrics)
        val r = actions.save(data.song, TagEdit(mapOf(TagField.ARTIST to "周杰伦")), "[00:02.00]新歌词", data.tag.lyrics, LyricsTarget.BOTH)
        // audio uploaded with new tags
        val uploaded = File(tmp.root, "up.mp3").apply { writeBytes(remote.files["/音乐/周杰伦/晴天.mp3"]!!) }
        val t2 = TagService.read(uploaded)
        assertEquals("周杰伦", t2[TagField.ARTIST])
        assertEquals("[00:02.00]新歌词", t2.lyrics)
        // existing differently-cased LRC overwritten, no duplicate created
        assertEquals("[00:02.00]新歌词", LrcFiles.decode(remote.files["/音乐/周杰伦/晴天.LRC"]!!))
        assertTrue(remote.files.keys.none { it == "/音乐/周杰伦/晴天.lrc" })
        assertEquals(remote.mtimes["/音乐/周杰伦/晴天.mp3"], r.song.modified)
        // cache is reused for the next load (no new download)
        actions.load(r.song)
        assertEquals(1, remote.fullReads)

        // LRC export for a song without lrc creates "a.lrc" next to it
        val fl = RemoteScanner.songFor("r1", entries.first { it.name == "a.flac" }, false)
        settings = settings.copy(lrcBom = true)
        actions.save(actions.load(fl).song, TagEdit(), "[00:03.00]x", "", LyricsTarget.LRC)
        val bytes = remote.files["/音乐/a.lrc"]!!
        assertContentEquals(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()), bytes.copyOfRange(0, 3))
    }

    @Test
    fun http405OnUploadGivesFriendlyChineseMessage() {
        val remote = FakeRemote(rejectUploads = true)
        remote.files["/m/a.flac"] = res("sample.flac")
        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val actions = SongActions({ AppSettings() }, { store })
        val song = RemoteScanner.songFor("r1", remote.list("/m").first(), false)
        val data = actions.load(song)
        val ex = assertFailsWith<RemoteUploadException> {
            actions.save(data.song, TagEdit(mapOf(TagField.TITLE to "x")), "", "", LyricsTarget.TAG)
        }
        assertTrue(ex.message!!.contains("HTTP 405"), ex.message)
        assertTrue(ex.message!!.contains("不允许写入"), ex.message)
        val ex2 = assertFailsWith<RemoteUploadException> {
            actions.save(data.song, TagEdit(), "[00:01.00]a", "", LyricsTarget.LRC)
        }
        assertTrue(ex2.message!!.startsWith("上传 LRC 失败"), ex2.message)
    }
}
