package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.lyrics.LrcFiles
import com.lonx.lyrico.desktop.lyrics.LrcWriteOptions
import com.lonx.lyrico.desktop.plugin.GraalJsRuntime
import com.lonx.lyrico.desktop.plugin.HostApi
import com.lonx.lyrico.desktop.tag.TagEdit
import com.lonx.lyrico.desktop.tag.TagField
import com.lonx.lyrico.desktop.tag.TagService
import java.io.ByteArrayInputStream
import java.io.File
import javax.sound.sampled.AudioFileFormat
import javax.sound.sampled.AudioFormat
import javax.sound.sampled.AudioInputStream
import javax.sound.sampled.AudioSystem

/**
 * `Lyrico Mod.exe --selftest <report.txt>`: exercises the bundled runtime without a window
 * (tag write/read with Chinese text, LRC encoding, GraalJS plugin host). Used by CI on Windows.
 */
object SelfTest {
    fun run(report: File): Boolean {
        val out = StringBuilder()
        var ok = true
        fun check(name: String, block: () -> String) {
            try { out.appendLine("PASS $name: ${block()}") } catch (e: Throwable) { ok = false; out.appendLine("FAIL $name: $e") }
        }
        val dir = File(System.getProperty("java.io.tmpdir"), "lyrico-selftest-${System.nanoTime()}").apply { mkdirs() }
        check("runtime") { "${System.getProperty("java.version")} ${System.getProperty("os.name")} ${System.getProperty("os.arch")} file.encoding=${System.getProperty("file.encoding")}" }
        check("wav-id3-lyrics") {
            val wav = File(dir, "测试 歌曲.wav")
            val fmt = AudioFormat(8000f, 16, 1, true, false)
            val pcm = ByteArray(8000)
            AudioSystem.write(AudioInputStream(ByteArrayInputStream(pcm), fmt, 4000), AudioFileFormat.Type.WAVE, wav)
            TagService.write(wav, TagEdit(mapOf(TagField.TITLE to "晴天", TagField.ARTIST to "周杰伦"), "[00:01.00]故事的小黄花"))
            val t = TagService.read(wav)
            require(t[TagField.TITLE] == "晴天" && t.lyrics == "[00:01.00]故事的小黄花") { "read back ${t.fields} ${t.lyrics}" }
            "title=${t[TagField.TITLE]} lyrics=${t.lyrics}"
        }
        check("lrc-utf8-bom") {
            val f = File(dir, "歌词.lrc")
            LrcFiles.write(f, "[00:01.00]你好", LrcWriteOptions(bom = true))
            require(LrcFiles.read(f) == "[00:01.00]你好")
            "${f.length()} bytes"
        }
        check("graaljs-plugin-host") {
            GraalJsRuntime(HostApi()).use { rt ->
                rt.eval("function searchSongs(r){ return [{ title: r.keyword, md5: Platform.crypto.md5('hello'), s: [...new Set([1,1,2])].length }]; }")
                val res = rt.call("searchSongs", """{"keyword":"晴天"}""")
                require(res.contains("5d41402abc4b2a76b9719d911017c592") && res.contains("晴天")) { res }
                res
            }
        }
        check("tls-modules") { javax.net.ssl.SSLContext.getDefault().protocol }
        dir.deleteRecursively()
        out.appendLine(if (ok) "SELFTEST OK" else "SELFTEST FAILED")
        report.writeText(out.toString(), Charsets.UTF_8)
        return ok
    }
}
