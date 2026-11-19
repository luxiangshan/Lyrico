package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.tag.CoverArt
import com.lonx.lyrico.desktop.tag.CoverChange
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import org.junit.Assume
import org.junit.Test
import java.io.File

/** Writes tagged samples to $LYRICO_VERIFY_DIR so they can be checked with ffprobe (skipped otherwise). */
class ExportForExternalCheck {
    @Test
    fun export() {
        val dir = System.getenv("LYRICO_VERIFY_DIR")
        Assume.assumeTrue(dir != null)
        File(dir!!).mkdirs()
        for (ext in listOf("mp3", "flac", "m4a", "ogg", "opus", "wav", "aiff", "wv")) {
            val f = File(dir, "out.$ext")
            javaClass.getResourceAsStream("/audio/sample.$ext")!!.use { i -> f.outputStream().use { i.copyTo(it) } }
            val art = CoverArt.fromFile(File(javaClass.getResource("/audio/cover.jpg")!!.toURI()))
            TagService.write(f, TagEdit(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦", TagField.TRACK to "3", TagField.TRACK_TOTAL to "11"), "[00:01.00]故事的小黄花\n[00:02.00]第二行", CoverChange.Replace(art)))
        }
    }
}
