package com.lonx.lyrico.desktop.lyrics

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/** Where lyrics go when saving. */
enum class LyricsTarget(val label: String) {
    TAG("写入标签"),
    LRC("保存为 LRC"),
    BOTH("两者都要");

    val writesTag get() = this != LRC
    val writesLrc get() = this != TAG
}

enum class LineEnding(val label: String, val value: String) {
    LF("LF（\\n）", "\n"),
    CRLF("CRLF（\\r\\n，Windows 记事本）", "\r\n"),
}

data class LrcWriteOptions(val bom: Boolean = false, val lineEnding: LineEnding = LineEnding.LF)

object LrcFiles {

    /** "song.mp3" -> "song.lrc" next to it. */
    fun lrcFileFor(audio: File): File = File(audio.parentFile, audio.nameWithoutExtension + ".lrc")

    fun lrcNameFor(audioName: String): String = audioName.substringBeforeLast('.', audioName) + ".lrc"

    /** Adjacent .lrc (exact name first, then case-insensitive). */
    fun findAdjacent(audio: File): File? {
        val exact = lrcFileFor(audio)
        if (exact.isFile) return exact
        val base = audio.nameWithoutExtension
        return audio.parentFile?.listFiles { f ->
            f.isFile && f.extension.equals("lrc", true) && f.nameWithoutExtension.equals(base, true)
        }?.firstOrNull()
    }

    fun read(file: File): String = decode(file.readBytes())

    /** Decodes LRC bytes: BOM aware, strict UTF-8, then GB18030 (common for Chinese LRC files). */
    fun decode(bytes: ByteArray): String {
        val text = when {
            bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() && bytes[2] == 0xBF.toByte() ->
                String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
            bytes.size >= 2 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xFE.toByte() ->
                String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
            bytes.size >= 2 && bytes[0] == 0xFE.toByte() && bytes[1] == 0xFF.toByte() ->
                String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
            else -> try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString()
            } catch (_: CharacterCodingException) {
                String(bytes, Charset.forName("GB18030"))
            }
        }
        return normalize(text)
    }

    fun normalize(text: String): String = text.replace("\r\n", "\n").replace('\r', '\n')

    fun encode(text: String, options: LrcWriteOptions): ByteArray {
        val body = normalize(text).replace("\n", options.lineEnding.value).toByteArray(Charsets.UTF_8)
        return if (options.bom) byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte()) + body else body
    }

    fun write(file: File, text: String, options: LrcWriteOptions) {
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, ".${file.name}.lyrico-tmp")
        tmp.writeBytes(encode(text, options))
        try {
            java.nio.file.Files.move(tmp.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        } catch (e: Exception) {
            tmp.delete()
            throw e
        }
    }

    private val timeTag = Regex("""\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?]""")

    /** True when the text contains LRC time tags. */
    fun isSynced(text: String): Boolean = timeTag.containsMatchIn(text)
}
