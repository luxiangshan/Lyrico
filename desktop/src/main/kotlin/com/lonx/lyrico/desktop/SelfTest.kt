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
        check("webp-cover-and-lrc-export") {
            // Batch-edit path on the bundled runtime: WebP cover (no ImageIO support) into WAV + AIFF, then LRC export
            // into a chosen directory with a same-name collision.
            val fmt = AudioFormat(8000f, 16, 1, true, false)
            val files = listOf(AudioFileFormat.Type.WAVE to "wav", AudioFileFormat.Type.AIFF to "aiff").mapIndexed { i, (type, ext) ->
                val sub = File(dir, "f$i").apply { mkdirs() }
                File(sub, "晴天.$ext").also { AudioSystem.write(AudioInputStream(ByteArrayInputStream(ByteArray(8000)), fmt, 4000), type, it) }
            }
            // 1x1 lossless WebP
            val webp = java.util.Base64.getDecoder().decode("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
            files.forEach { TagService.write(it, com.lonx.lyrico.desktop.tag.TagEdit(mapOf(com.lonx.lyrico.desktop.tag.TagField.TITLE to "晴天", com.lonx.lyrico.desktop.tag.TagField.ARTIST to "周杰伦"))) }
            val edit = com.lonx.lyrico.desktop.library.BatchEdit.build(
                mapOf(com.lonx.lyrico.desktop.library.BatchField.LYRICS to com.lonx.lyrico.desktop.library.BatchChange.SetValue("[00:01.00]批量"),
                    com.lonx.lyrico.desktop.library.BatchField.ALBUM to com.lonx.lyrico.desktop.library.BatchChange.SetValue("")), // empty text = no change
                com.lonx.lyrico.desktop.library.BatchCover.Replace(com.lonx.lyrico.desktop.tag.CoverArt(webp, "image/webp"), "1x1.webp"))
            files.forEach { TagService.write(it, edit) }
            files.forEach { f ->
                val t = TagService.read(f, withCover = true)
                require(t.cover?.bytes?.contentEquals(webp) == true && t.lyrics == "[00:01.00]批量") { "${f.name}: cover=${t.cover?.mime} lyrics=${t.lyrics}" }
                require(t[com.lonx.lyrico.desktop.tag.TagField.TITLE] == "晴天" && t[com.lonx.lyrico.desktop.tag.TagField.ARTIST] == "周杰伦") { "${f.name}: untouched fields lost: ${t.fields}" }
            }
            val out = File(dir, "导出").apply { mkdirs() }
            val plan = com.lonx.lyrico.desktop.lyrics.LrcExportPlan(out, com.lonx.lyrico.desktop.lyrics.LrcConflict.NUMBER)
            files.forEach { f -> LrcFiles.write(plan.resolve(f.nameWithoutExtension)!!.file, TagService.read(f).lyrics, LrcWriteOptions()) }
            val names = out.list()!!.sorted()
            require(names == listOf("晴天 (2).lrc", "晴天.lrc")) { names.toString() }
            "wav+aiff webp cover ok, untouched title/artist kept, export $names"
        }
        check("tls-modules") { javax.net.ssl.SSLContext.getDefault().protocol }
        dir.deleteRecursively()
        out.appendLine(if (ok) "SELFTEST OK" else "SELFTEST FAILED")
        report.writeText(out.toString(), Charsets.UTF_8)
        return ok
    }
}
