package com.lonx.lyrico.desktop.e2e

import com.lonx.lyrico.desktop.FakeRemote
import com.lonx.lyrico.desktop.TagSnapshot
import com.lonx.lyrico.desktop.library.BatchChange
import com.lonx.lyrico.desktop.library.BatchCover
import com.lonx.lyrico.desktop.library.BatchEdit
import com.lonx.lyrico.desktop.library.BatchField
import com.lonx.lyrico.desktop.library.LibraryScanner
import com.lonx.lyrico.desktop.library.LocalSongStore
import com.lonx.lyrico.desktop.library.Song
import com.lonx.lyrico.desktop.library.SongActions
import com.lonx.lyrico.desktop.lyrics.LyricsTarget
import com.lonx.lyrico.desktop.remote.RemoteScanner
import com.lonx.lyrico.desktop.remote.RemoteSongStore
import com.lonx.lyrico.desktop.settings.AppSettings
import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * Regression for "批量编辑把所有 ID3 信息清空，封面也是": realistic, heavily tagged files written by an independent tagger
 * (mutagen; see testdata/make_rich_fixtures.py): ID3v2.4, ID3v2.3+ID3v1, FLAC with 2 PICTUREs and 27 comments,
 * MP4 with freeform atoms and 2 covers, Ogg Vorbis/Opus with METADATA_BLOCK_PICTURE, APE/WavPack with binary covers.
 * Every frame (TXXX, APIC, USLT, COMM, TPE2, TCOM, TEXT, TPOS, replaygain, UFID, PRIV, POPM, WXXX…) is dumped before and
 * after; editing only 专辑 must change only the album entries.
 */
class TagPreservationTest {
    @get:Rule
    val tmp = TemporaryFolder()

    /** variant -> file name pattern ({i} = song 0..2) and the snapshot keys that hold the album. */
    private val variants = linkedMapOf(
        "ID3v2.4 mp3" to ("rich{i}_v24.mp3" to setOf("TALB")),
        "ID3v2.3+v1 mp3" to ("rich{i}_v23v1.mp3" to setOf("TALB", "v1.album")),
        "flac" to ("rich{i}.flac" to setOf("ALBUM")),
        "m4a" to ("rich{i}.m4a" to setOf("©alb")),
        "ogg" to ("rich{i}.ogg" to setOf("ALBUM")),
        "opus" to ("rich{i}.opus" to setOf("ALBUM")),
        "ape" to ("rich{i}.ape" to setOf("album")),
        "wv" to ("rich{i}.wv" to setOf("album")),
    )

    private fun copy(name: String, dir: File): File = E2E.resourceFile("/audio/rich/$name", dir)

    private fun library(dir: File): List<Song> = runBlocking { LibraryScanner.scan(listOf(dir.absolutePath), emptyMap(), 2) { _, _, _ -> } }.sortedBy { it.fileName }

    private fun assertOnlyAlbumChanged(what: String, before: List<String>, after: List<String>, albumKeys: Set<String>, album: String) {
        assertEquals(TagSnapshot.without(before, albumKeys), TagSnapshot.without(after, albumKeys), "$what: frames/fields other than the album changed")
        val primary = albumKeys.first()
        assertEquals(listOf(album), TagSnapshot.values(after, primary).map { it.substringBefore(" sha1:").removePrefix("Text=") }, "$what: album")
    }

    @Test
    fun batchEditOnlyAlbumOnThreeSongsKeepsEveryOtherFrameAndCoverBytes() {
        val settings = AppSettings() // default ID3 setting 2.3: an existing 2.4 tag must NOT be converted
        val actions = SongActions({ settings }, { LocalSongStore })
        for ((variant, spec) in variants) {
            val (pattern, keys) = spec
            val dir = File(tmp.root, variant.replace(' ', '_'))
            val files = (0..2).map { copy(pattern.replace("{i}", "$it"), dir) }
            val before = files.associateWith { TagSnapshot.of(it) }
            val covers = files.associateWith { TagService.read(it, withCover = true).cover!!.bytes }
            val id3v = if (pattern.endsWith(".mp3")) files.associateWith { TagSnapshot.id3Version(it) } else emptyMap()
            assertEquals(3, covers.values.map { it.toList() }.distinct().size, "$variant: fixtures have 3 different covers")
            val songs = library(dir)
            assertEquals(3, songs.size, variant)
            // The batch editor shows the 3 songs with differing artists/titles/covers; the user changes ONLY 专辑.
            val edit = BatchEdit.build(mapOf(BatchField.ALBUM to BatchChange.SetValue("批量新专辑")), BatchCover.Keep)
            assertEquals(TagEdit(mapOf(TagField.ALBUM to "批量新专辑")), edit)
            songs.forEach { actions.applyEdit(it, edit) }
            for (f in files) {
                val after = TagSnapshot.of(f)
                val albumKeys = if (variant == "ID3v2.3+v1 mp3") setOf("TALB", "v1.album") else keys
                assertOnlyAlbumChanged("$variant ${f.name}", before.getValue(f), after, albumKeys, "批量新专辑")
                assertContentEquals(covers.getValue(f), TagService.read(f, withCover = true).cover!!.bytes, "$variant ${f.name}: front cover bytes")
                if (f in id3v) assertEquals(id3v.getValue(f), TagSnapshot.id3Version(f), "${f.name}: ID3 version kept")
                // keep the edited files with the report so they can be re-checked with an independent tagger (mutagen)
                f.copyTo(File(System.getProperty("lyrico.e2eReport") ?: "build/e2e-report", "edited/${f.name}"), overwrite = true)
            }
            E2E.report("tag-preservation", "$variant: 3 songs, only 专辑 edited -> all ${before.values.first().size} other frames/fields + cover bytes identical (${E2E.os})")
        }
    }

    @Test
    fun singleSongEditorSaveKeepsUntouchedFrames() {
        val settings = AppSettings()
        val actions = SongActions({ settings }, { LocalSongStore })
        for ((variant, spec) in variants) {
            val dir = File(tmp.root, "single_" + variant.replace(' ', '_'))
            val f = copy(spec.first.replace("{i}", "1"), dir)
            val song = library(dir).single()
            val before = TagSnapshot.of(f)
            val data = actions.load(song)
            // what the editor does: EditorState.buildEdit() only carries fields whose text changed
            val e = com.lonx.lyrico.desktop.ui.EditorState(data, LyricsTarget.TAG)
            e.fields[TagField.ALBUM] = "编辑器新专辑"
            assertEquals(mapOf(TagField.ALBUM to "编辑器新专辑"), e.buildEdit().fields)
            actions.save(e.song, e.buildEdit(), e.lyrics, data.tag.lyrics, LyricsTarget.TAG)
            assertOnlyAlbumChanged("editor $variant", before, TagSnapshot.of(f), spec.second, "编辑器新专辑")
            // saving again without changes writes nothing at all
            val bytes = f.readBytes()
            val d2 = actions.load(library(dir).single())
            val e2 = com.lonx.lyrico.desktop.ui.EditorState(d2, LyricsTarget.TAG)
            actions.save(e2.song, e2.buildEdit(), e2.lyrics, d2.tag.lyrics, LyricsTarget.TAG)
            assertContentEquals(bytes, f.readBytes(), "editor $variant: unchanged save must not rewrite the file")
        }
        E2E.report("tag-preservation", "single-song editor: album-only save keeps all other frames on ${variants.keys.joinToString()}; no-change save leaves bytes identical")
    }

    @Test
    fun commentEditKeepsOtherCommFramesAndLanguage() {
        for (name in listOf("rich0_v24.mp3", "rich0_v23v1.mp3")) {
            val f = copy(name, File(tmp.root, "comm"))
            val before = TagSnapshot.of(f)
            TagService.write(f, TagEdit(mapOf(TagField.COMMENT to "新注释")))
            val after = TagSnapshot.of(f)
            assertEquals(TagSnapshot.without(before, setOf("COMM", "v1.comment")), TagSnapshot.without(after, setOf("COMM", "v1.comment")), name)
            val comm = TagSnapshot.values(after, "COMM")
            assertTrue(comm.any { it.contains("Language=chi") && it.contains("Description=;") && it.contains("Text=新注释") }, "$name language kept: $comm")
            assertTrue(comm.any { it.contains("iTunNORM") }, "$name iTunNORM kept: $comm")
            TagService.write(f, TagEdit(mapOf(TagField.COMMENT to "")))
            val comm2 = TagSnapshot.values(TagSnapshot.of(f), "COMM")
            assertEquals(1, comm2.size, "$name: clearing 注释 removes only the plain comment: $comm2")
            assertTrue(comm2.single().contains("iTunNORM"))
        }
        E2E.report("tag-preservation", "ID3 注释 edit keeps its language and the iTunNORM COMM; clearing it keeps iTunNORM")
    }

    @Test
    fun replacingFrontCoverKeepsBackCover() {
        val newCover = CoverArt.fromFile(E2E.resourceFile("/audio/cover.webp", File(tmp.root, "img")))
        val back = E2E.resourceBytes("/audio/rich/cover_back.png")
        for (name in listOf("rich0_v24.mp3", "rich0_v23v1.mp3", "rich0.flac", "rich0.ogg", "rich0.opus", "rich0.ape")) {
            val f = copy(name, File(tmp.root, "cov"))
            val before = TagSnapshot.of(f)
            TagService.write(f, TagEdit(cover = CoverChange.Replace(newCover)))
            assertContentEquals(newCover.bytes, TagService.read(f, withCover = true).cover!!.bytes, "$name new front cover")
            val snap = TagSnapshot.of(f).joinToString("\n")
            val backSha = java.security.MessageDigest.getInstance("SHA-1").digest(back).joinToString("") { "%02x".format(it) }
            if (name.endsWith(".opus") || name.endsWith(".ogg")) {
                // Vorbis comments: pictures are base64 METADATA_BLOCK_PICTURE entries; front replaced, back kept
                val pics = TagSnapshot.values(TagSnapshot.of(f), "METADATA_BLOCK_PICTURE")
                assertEquals(2, pics.size, "$name: front replaced, back kept: $pics")
            } else if (name.endsWith(".ape")) {
                assertEquals(TagSnapshot.values(before, "cover art (back)"), TagSnapshot.values(TagSnapshot.of(f), "cover art (back)"), "$name: back cover item kept")
            } else assertTrue(snap.contains(backSha), "$name: back cover (type 4) kept:\n$snap")
        }
        E2E.report("tag-preservation", "replacing the front cover keeps the back cover (mp3 v2.4/v2.3, flac, ogg, opus, ape)")
    }

    @Test
    fun remoteBatchEditKeepsFramesAndRefusesTruncatedDownload() {
        val remote = FakeRemote()
        for (i in 0..2) remote.files["/云盘/rich$i.mp3"] = E2E.resourceBytes("/audio/rich/rich${i}_v24.mp3")
        remote.files["/云盘/rich0.flac"] = E2E.resourceBytes("/audio/rich/rich0.flac")
        val store = RemoteSongStore({ remote }, File(tmp.root, "cache"))
        val actions = SongActions({ AppSettings() }, { store })
        // scan uses partial (head) downloads; editing must use a full download
        val songs = remote.list("/云盘").filter { !it.isDirectory }.map { e ->
            val s0 = RemoteScanner.songFor("r1", e, false)
            s0.withTag(RemoteScanner.readTags(remote, s0, store, File(tmp.root, "head")).first)
        }
        val before = songs.associate { s -> s.path to TagSnapshot.of(File(tmp.root, "b_" + s.fileName).apply { writeBytes(remote.files[s.path]!!) }) }
        val edit = BatchEdit.build(mapOf(BatchField.ALBUM to BatchChange.SetValue("远程新专辑")), BatchCover.Keep)
        songs.forEach { actions.applyEdit(it, edit) }
        for (s in songs) {
            val f = File(tmp.root, "a_" + s.fileName).apply { writeBytes(remote.files[s.path]!!) }
            val keys = if (s.fileName.endsWith(".mp3")) setOf("TALB") else setOf("ALBUM")
            assertOnlyAlbumChanged("remote ${s.fileName}", before.getValue(s.path), TagSnapshot.of(f), keys, "远程新专辑")
        }
        // A dropped connection must not lead to editing and uploading a truncated copy over the original.
        remote.files["/云盘/rich9.mp3"] = E2E.resourceBytes("/audio/rich/rich1_v24.mp3")
        val original = remote.files["/云盘/rich9.mp3"]!!.copyOf()
        val s9 = RemoteScanner.songFor("r1", remote.stat("/云盘/rich9.mp3")!!, false)
        remote.truncateReadsAt = 5000
        val ex = assertFailsWith<IOException> { actions.applyEdit(s9, edit) }
        assertTrue(ex.message!!.contains("不完整"), ex.message)
        assertContentEquals(original, remote.files["/云盘/rich9.mp3"], "remote file untouched")
        E2E.report("tag-preservation", "remote (fake WebDAV): album-only batch edit after partial scan keeps all frames; truncated download refused, remote untouched")
    }
}
