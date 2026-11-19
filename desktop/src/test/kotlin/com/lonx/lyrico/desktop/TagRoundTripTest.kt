package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import com.lonx.lyrico.desktop.tag.TagWriteOptions
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.audio.mp3.MP3File
import org.jaudiotagger.tag.id3.ID3v23Tag
import org.jaudiotagger.tag.id3.framebody.FrameBodyUSLT
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

class TagRoundTripTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val lrc = "[ti:晴天]\n[ar:周杰伦]\n[00:01.00]故事的小黄花\n[00:05.50]从出生那年就飘着\n"

    private fun sample(ext: String, name: String = "测试 歌曲.$ext"): File {
        val src = javaClass.getResourceAsStream("/audio/sample.$ext")!!
        val f = File(tmp.root, name)
        f.outputStream().use { src.copyTo(it) }
        return f
    }

    private fun cover(name: String): CoverArt = CoverArt.fromFile(File(javaClass.getResource("/audio/$name")!!.toURI()))

    private val fields = mapOf(
        TagField.TITLE to "晴天",
        TagField.ARTIST to "周杰伦",
        TagField.ALBUM to "叶惠美",
        TagField.ALBUM_ARTIST to "周杰伦",
        TagField.TRACK to "3",
        TagField.TRACK_TOTAL to "11",
        TagField.DISC to "1",
        TagField.DISC_TOTAL to "2",
        TagField.YEAR to "2003",
        TagField.GENRE to "流行",
        TagField.COMPOSER to "周杰伦",
        TagField.LYRICIST to "周杰伦",
        TagField.COMMENT to "备注 ✓",
    )

    private fun roundTrip(ext: String) {
        val f = sample(ext)
        val art = cover("cover.jpg")
        TagService.write(f, TagEdit(fields, lrc, CoverChange.Replace(art)))
        val t = TagService.read(f, withCover = true)
        for ((k, v) in fields) assertEquals(v, t[k], "$ext $k")
        assertEquals(lrc, t.lyrics, "$ext lyrics")
        assertNotNull(t.cover, "$ext cover")
        assertContentEquals(art.bytes, t.cover!!.bytes, "$ext cover bytes")
        assertTrue(t.hasCover)

        // partial edit keeps other fields; delete a field; remove lyrics and cover
        TagService.write(f, TagEdit(mapOf(TagField.TITLE to "晴天 (Live)", TagField.COMMENT to ""), "", CoverChange.Remove))
        val t2 = TagService.read(f, withCover = true)
        assertEquals("晴天 (Live)", t2[TagField.TITLE], ext)
        assertEquals("周杰伦", t2[TagField.ARTIST], ext)
        assertEquals("", t2[TagField.COMMENT], "$ext comment deleted")
        assertEquals("", t2.lyrics, "$ext lyrics deleted")
        assertNull(t2.cover, "$ext cover removed")
        assertFalse(t2.hasCover, ext)

        // png cover replace
        TagService.write(f, TagEdit(cover = CoverChange.Replace(cover("cover.png"))))
        val t3 = TagService.read(f, withCover = true)
        assertEquals("image/png", t3.cover?.mime, ext)
    }

    @Test fun mp3() = roundTrip("mp3")
    @Test fun flac() = roundTrip("flac")
    @Test fun m4a() = roundTrip("m4a")
    @Test fun oggVorbis() = roundTrip("ogg")
    @Test fun opus() = roundTrip("opus")
    @Test fun wav() = roundTrip("wav")
    @Test fun aiff() = roundTrip("aiff")
    @Test fun wavPack() = roundTrip("wv")

    @Test
    fun mp3LyricsAreId3v23UsltWithLanguage() {
        val f = sample("mp3")
        TagService.write(f, TagEdit(mapOf(TagField.TITLE to "x"), lrc), TagWriteOptions(id3Version = "2.3", usltLanguage = "chi"))
        val mp3 = AudioFileIO.read(f) as MP3File
        val tag = mp3.iD3v2Tag
        assertTrue(tag is ID3v23Tag, "ID3v2.3 expected, got ${tag?.javaClass}")
        val frame = tag.getFirstField("USLT") as org.jaudiotagger.tag.id3.AbstractID3v2Frame
        val body = frame.body as FrameBodyUSLT
        assertEquals("chi", body.language)
        assertEquals(lrc, body.lyric)

        TagService.write(f, TagEdit(lyrics = "[00:00.00]x"), TagWriteOptions(id3Version = "2.4", usltLanguage = "XXX"))
        val mp3b = AudioFileIO.read(f) as MP3File
        val body2 = (mp3b.iD3v2Tag.getFirstField("USLT") as org.jaudiotagger.tag.id3.AbstractID3v2Frame).body as FrameBodyUSLT
        assertEquals("XXX", body2.language)
        assertEquals("[00:00.00]x", body2.lyric)
        assertEquals(1, mp3b.iD3v2Tag.getFields("USLT").size)
    }

    @Test
    fun flacUsesVorbisLyricsField() {
        val f = sample("flac")
        TagService.write(f, TagEdit(lyrics = lrc))
        val flac = AudioFileIO.read(f).tag as org.jaudiotagger.tag.flac.FlacTag
        assertEquals(lrc, flac.vorbisCommentTag.getFirst("LYRICS"))
    }

    @Test
    fun m4aUsesLyrAtom() {
        val f = sample("m4a")
        TagService.write(f, TagEdit(lyrics = lrc))
        val mp4 = AudioFileIO.read(f).tag as org.jaudiotagger.tag.mp4.Mp4Tag
        assertEquals(lrc, mp4.getFirst("\u00A9lyr"))
    }

    @Test
    fun opusFileStaysValidAfterLargeTag() {
        val f = sample("opus")
        val big = ByteArray(200_000) { (it % 251).toByte() }
        TagService.write(f, TagEdit(mapOf(TagField.TITLE to "大封面"), lrc, CoverChange.Replace(CoverArt(big, "image/jpeg"))))
        val t = TagService.read(f, withCover = true)
        assertEquals("大封面", t[TagField.TITLE])
        assertContentEquals(big, t.cover!!.bytes)
        assertTrue(t.audio.durationSeconds in 0..2)
        // every page CRC valid
        val pages = com.lonx.lyrico.desktop.tag.OpusBackend.parsePages(f.readBytes())
        val bytes = f.readBytes()
        var lastSeq = -1
        for (p in pages) {
            val copy = bytes.copyOfRange(p.offset, p.offset + p.length)
            val stored = java.nio.ByteBuffer.wrap(copy).order(java.nio.ByteOrder.LITTLE_ENDIAN).getInt(22)
            java.nio.ByteBuffer.wrap(copy).order(java.nio.ByteOrder.LITTLE_ENDIAN).putInt(22, 0)
            assertEquals(stored, com.lonx.lyrico.desktop.tag.OpusBackend.oggCrc(copy))
            assertEquals(lastSeq + 1, p.seq)
            lastSeq = p.seq
        }
        // shrink again
        TagService.write(f, TagEdit(cover = CoverChange.Remove))
        assertNull(TagService.read(f, true).cover)
        assertEquals(lrc, TagService.read(f).lyrics)
    }
}
