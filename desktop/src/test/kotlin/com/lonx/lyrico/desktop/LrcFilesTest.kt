package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.lyrics.LineEnding
import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LrcWriteOptions
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.charset.Charset
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LrcFilesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private val text = "[00:01.00]你好\n[00:02.00]世界"

    @Test
    fun writesUtf8WithAndWithoutBom() {
        val f = File(tmp.root, "a.lrc")
        LrcFiles.write(f, text, LrcWriteOptions(bom = false))
        assertContentEquals(text.toByteArray(Charsets.UTF_8), f.readBytes())
        LrcFiles.write(f, text, LrcWriteOptions(bom = true, lineEnding = LineEnding.CRLF))
        val b = f.readBytes()
        assertEquals(0xEF.toByte(), b[0]); assertEquals(0xBB.toByte(), b[1]); assertEquals(0xBF.toByte(), b[2])
        assertTrue(String(b, 3, b.size - 3, Charsets.UTF_8).contains("\r\n"))
        assertEquals(text, LrcFiles.read(f))
    }

    @Test
    fun readsGbkAndUtf16() {
        val f = File(tmp.root, "g.lrc")
        f.writeBytes(text.toByteArray(Charset.forName("GBK")))
        assertEquals(text, LrcFiles.read(f))
        f.writeBytes(byteArrayOf(0xFF.toByte(), 0xFE.toByte()) + text.toByteArray(Charsets.UTF_16LE))
        assertEquals(text, LrcFiles.read(f))
    }

    @Test
    fun findsAdjacentCaseInsensitive() {
        val audio = File(tmp.root, "歌曲.flac").apply { writeText("x") }
        assertNull(LrcFiles.findAdjacent(audio))
        File(tmp.root, "歌曲.LRC").writeText(text)
        assertEquals("歌曲.LRC", LrcFiles.findAdjacent(audio)!!.name)
        assertEquals(File(tmp.root, "歌曲.lrc"), LrcFiles.lrcFileFor(audio))
        assertEquals("a.b.lrc", LrcFiles.lrcNameFor("a.b.mp3"))
        assertTrue(LrcFiles.isSynced(text))
    }
}
