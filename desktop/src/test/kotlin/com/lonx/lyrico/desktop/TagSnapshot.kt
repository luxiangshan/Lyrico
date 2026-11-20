package com.lonx.lyrico.desktop

import com.lonx.lyrico.desktop.tag.OpusBackend
import com.lonx.lyrico.desktop.tag.VorbisComments
import org.jaudiotagger.audio.AudioFileIO
import org.jaudiotagger.audio.mp3.MP3File
import org.jaudiotagger.tag.flac.FlacTag
import org.jaudiotagger.tag.id3.AbstractID3v2Frame
import org.jaudiotagger.tag.id3.AbstractID3v2Tag
import org.jaudiotagger.tag.id3.ID3v22Tag
import org.jaudiotagger.tag.id3.ID3v23Tag
import org.jaudiotagger.tag.id3.ID3v24Tag
import org.jaudiotagger.tag.mp4.Mp4Tag
import org.jaudiotagger.tag.mp4.Mp4TagField
import org.jaudiotagger.tag.vorbiscomment.VorbisCommentTag
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * Low-level, format-specific dump of EVERYTHING in a file's tag: every ID3 frame (all body values, binary values as
 * SHA-1) and the ID3v1 tag, every Vorbis comment, every FLAC PICTURE block, every MP4 atom, every APEv2 item.
 * Each entry is "key|value" where key names the field (frame id, comment key, atom id, item key).
 * Used to prove that editing one field leaves every other frame/field and the cover bytes identical.
 */
object TagSnapshot {
    private fun sha(b: ByteArray) = "sha1:" + MessageDigest.getInstance("SHA-1").digest(b).joinToString("") { "%02x".format(it) } + "/${b.size}"

    private fun frameLine(f: AbstractID3v2Frame): String {
        val parts = ArrayList<String>()
        val it = f.body.iterator()
        while (it.hasNext()) {
            val d = it.next()
            if (d.identifier == "TextEncoding") continue // re-encoding (UTF-16/UTF-8) is allowed; the value is what matters
            val v = d.value
            parts += d.identifier + "=" + when (v) {
                is ByteArray -> sha(v)
                is List<*> -> v.joinToString("\u0001") { x -> if (x is ByteArray) sha(x) else x.toString() }
                null -> ""
                else -> v.toString().trimEnd('\u0000') // a NUL terminator written by some taggers is not part of the value
            }
        }
        return f.identifier + "|" + parts.joinToString("; ")
    }

    private fun id3(tag: AbstractID3v2Tag): List<String> {
        val out = ArrayList<String>()
        val it = tag.fields
        while (it.hasNext()) {
            when (val v: Any? = it.next()) {
                is AbstractID3v2Frame -> out += frameLine(v)
                is List<*> -> v.filterIsInstance<AbstractID3v2Frame>().forEach { out += frameLine(it) }
                is org.jaudiotagger.tag.id3.AggregatedFrame -> v.frames.forEach { out += frameLine(it) }
                else -> out += "?|$v"
            }
        }
        return out
    }

    fun id3Version(file: File): String {
        val t = (AudioFileIO.read(file) as MP3File).iD3v2Tag
        return when (t) { is ID3v24Tag -> "2.4"; is ID3v23Tag -> "2.3"; is ID3v22Tag -> "2.2"; null -> "none"; else -> "?" }
    }

    fun of(file: File): List<String> = when (file.extension.lowercase()) {
        "mp3" -> {
            val mp3 = AudioFileIO.read(file) as MP3File
            val out = ArrayList<String>()
            mp3.iD3v2Tag?.let { out += id3(it) }
            mp3.iD3v1Tag?.let { v1 ->
                out += "v1.title|" + v1.firstTitle; out += "v1.artist|" + v1.firstArtist; out += "v1.album|" + v1.firstAlbum
                out += "v1.year|" + v1.firstYear; out += "v1.comment|" + v1.firstComment; out += "v1.genre|" + v1.firstGenre
                out += "v1.track|" + runCatching { v1.getFirst(org.jaudiotagger.tag.FieldKey.TRACK) }.getOrDefault("")
            }
            out.sorted()
        }
        "flac" -> {
            val t = AudioFileIO.read(file).tag as FlacTag
            (vorbis(t.vorbisCommentTag) + t.images.map { p ->
                "PICTURE|type=${p.pictureType} mime=${p.mimeType} desc=${p.description} ${sha(p.imageData)}"
            }).sorted()
        }
        "ogg" -> vorbis(AudioFileIO.read(file).tag as VorbisCommentTag).sorted()
        "m4a" -> {
            val t = AudioFileIO.read(file).tag as Mp4Tag
            val out = ArrayList<String>()
            val it = t.fields
            while (it.hasNext()) {
                val f = it.next()
                out += f.id + "|" + (if (f.isBinary) "" else f.toString() + " ") + sha((f as Mp4TagField).rawContentDataOnly)
            }
            out.sorted()
        }
        "opus" -> {
            val bytes = file.readBytes()
            val pages = OpusBackend.parsePages(bytes)
            // OpusTags packet = pages after OpusHead until a page that does not continue the packet
            val serial = pages[0].serial
            val packet = java.io.ByteArrayOutputStream()
            for (p in pages.drop(1).filter { it.serial == serial }) {
                packet.write(p.data)
                if (p.segments.last() < 255) break
            }
            val vc = VorbisComments.decode(packet.toByteArray(), 8)
            vc.entries.map { (k, v) -> k.uppercase() + "|" + if (k.equals("METADATA_BLOCK_PICTURE", true)) sha(v.toByteArray()) else v }.sorted()
        }
        "ape", "wv" -> ape(file).sorted()
        else -> error("no snapshot for ${file.name}")
    }

    private fun vorbis(t: VorbisCommentTag): List<String> {
        val out = ArrayList<String>()
        val it = t.fields
        while (it.hasNext()) {
            val f = it.next()
            val v = f.toString()
            out += f.id.uppercase() + "|" + if (f.id.equals("METADATA_BLOCK_PICTURE", true)) sha(v.toByteArray()) else v
        }
        return out
    }

    /** Independent APEv2 parser (footer at the end, before an optional ID3v1). */
    private fun ape(file: File): List<String> {
        val b = file.readBytes()
        var end = b.size
        val out = ArrayList<String>()
        if (end >= 128 && String(b, end - 128, 3, Charsets.ISO_8859_1) == "TAG") { out += "ID3v1|" + sha(b.copyOfRange(end - 128, end)); end -= 128 }
        check(String(b, end - 32, 8, Charsets.US_ASCII) == "APETAGEX") { "no APE footer in ${file.name}" }
        val bb = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
        val size = bb.getInt(end - 32 + 12); val count = bb.getInt(end - 32 + 16)
        var pos = end - size
        repeat(count) {
            val len = bb.getInt(pos); val flags = bb.getInt(pos + 4)
            var k = pos + 8
            while (b[k] != 0.toByte()) k++
            val key = String(b, pos + 8, k - pos - 8, Charsets.US_ASCII)
            val v = b.copyOfRange(k + 1, k + 1 + len)
            out += key.lowercase() + "|" + (if ((flags ushr 1) and 3 == 1) sha(v) else String(v, Charsets.UTF_8))
            pos = k + 1 + len
        }
        return out
    }

    /** Entries whose key is one of [keys] (case-insensitive) removed. */
    fun without(s: List<String>, keys: Set<String>): List<String> = s.filter { it.substringBefore('|').lowercase() !in keys.map { k -> k.lowercase() } }

    fun values(s: List<String>, key: String): List<String> = s.filter { it.substringBefore('|').equals(key, true) }.map { it.substringAfter('|') }
}
