package com.lonx.lyrico.desktop.tag

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** APEv2 tags for Monkey's Audio (.ape) and WavPack (.wv); jaudiotagger does not handle these. */
object ApeBackend : TagBackend {

    private val keys = mapOf(
        TagField.TITLE to "Title",
        TagField.ARTIST to "Artist",
        TagField.ALBUM to "Album",
        TagField.ALBUM_ARTIST to "Album Artist",
        TagField.TRACK to "Track",
        TagField.DISC to "Disc",
        TagField.YEAR to "Year",
        TagField.GENRE to "Genre",
        TagField.COMPOSER to "Composer",
        TagField.LYRICIST to "Lyricist",
        TagField.COMMENT to "Comment",
    )
    private const val COVER_KEY = "Cover Art (Front)"
    private const val LYRICS_KEY = "Lyrics"

    internal class Item(val key: String, val flags: Int, val value: ByteArray) {
        val isBinary get() = (flags ushr 1) and 3 == 1
        val text get() = String(value, Charsets.UTF_8).replace('\u0000', '/')
    }

    private class Layout(val tagStart: Long, val tagEnd: Long, val items: List<Item>)

    private fun locate(raf: RandomAccessFile): Layout {
        val len = raf.length()
        var end = len
        if (len >= 128) {
            val b = ByteArray(3)
            raf.seek(len - 128); raf.readFully(b)
            if (String(b, Charsets.ISO_8859_1) == "TAG") end = len - 128
        }
        if (end < 32) return Layout(end, end, emptyList())
        val footer = ByteArray(32)
        raf.seek(end - 32); raf.readFully(footer)
        if (String(footer, 0, 8, Charsets.US_ASCII) != "APETAGEX") return Layout(end, end, emptyList())
        val fb = ByteBuffer.wrap(footer).order(ByteOrder.LITTLE_ENDIAN)
        val tagSize = fb.getInt(12).toLong() and 0xffffffffL
        val count = fb.getInt(16)
        val flags = fb.getInt(20)
        val hasHeader = flags and (1 shl 31) != 0
        val itemsStart = end - tagSize
        if (itemsStart < 0) throw TagException("APE 标签损坏")
        val body = ByteArray((tagSize - 32).toInt())
        raf.seek(itemsStart); raf.readFully(body)
        val bb = ByteBuffer.wrap(body).order(ByteOrder.LITTLE_ENDIAN)
        val items = ArrayList<Item>()
        repeat(count) {
            if (bb.remaining() < 9) return@repeat
            val size = bb.int
            val f = bb.int
            val ks = bb.position()
            while (bb.hasRemaining() && bb.get() != 0.toByte()) Unit
            val key = String(body, ks, bb.position() - ks - 1, Charsets.US_ASCII)
            if (size < 0 || size > bb.remaining()) return@repeat
            val v = ByteArray(size); bb.get(v)
            items += Item(key, f, v)
        }
        return Layout(if (hasHeader) itemsStart - 32 else itemsStart, end, items)
    }

    private fun wavPackInfo(raf: RandomAccessFile): AudioInfo {
        return try {
            val h = ByteArray(32)
            raf.seek(0); raf.readFully(h)
            if (String(h, 0, 4, Charsets.US_ASCII) != "wvpk") return AudioInfo("WavPack")
            val bb = ByteBuffer.wrap(h).order(ByteOrder.LITTLE_ENDIAN)
            val total = bb.getInt(12).toLong() and 0xffffffffL
            val flags = bb.getInt(24)
            val rates = intArrayOf(6000, 8000, 9600, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000, 192000)
            val idx = (flags ushr 23) and 0xf
            val rate = rates.getOrElse(idx) { 0 }
            val secs = if (rate > 0 && total != 0xffffffffL) (total / rate).toInt() else 0
            val kbps = if (secs > 0) (raf.length() * 8 / secs / 1000).toInt() else 0
            AudioInfo("WavPack", secs, kbps, rate, if (flags and 4 != 0) "Mono" else "Stereo")
        } catch (_: Exception) {
            AudioInfo("WavPack")
        }
    }

    override fun read(file: File, withCover: Boolean): TagData = RandomAccessFile(file, "r").use { raf ->
        val layout = locate(raf)
        val audio = if (file.extension.equals("wv", true)) wavPackInfo(raf) else AudioInfo("Monkey's Audio")
        fun text(key: String) = layout.items.firstOrNull { it.key.equals(key, true) && !it.isBinary }?.text.orEmpty()
        val fields = LinkedHashMap<TagField, String>()
        for ((f, k) in keys) {
            var v = text(k)
            if (f == TagField.ALBUM_ARTIST && v.isEmpty()) v = text("AlbumArtist")
            if (f == TagField.TRACK || f == TagField.DISC) {
                val (n, t) = splitNumberPair(v)
                v = n
                if (t.isNotEmpty()) fields[if (f == TagField.TRACK) TagField.TRACK_TOTAL else TagField.DISC_TOTAL] = t
            }
            if (v.isNotEmpty()) fields[f] = v
        }
        val coverItem = layout.items.firstOrNull { it.key.equals(COVER_KEY, true) && it.isBinary }
        val cover = if (withCover && coverItem != null) {
            val z = coverItem.value.indexOf(0)
            val data = coverItem.value.copyOfRange(z + 1, coverItem.value.size)
            CoverArt(data, CoverArt.sniffMime(data))
        } else null
        TagData(fields, text(LYRICS_KEY).ifEmpty { text("Unsynced lyrics") }, cover, coverItem != null, audio)
    }

    override fun write(file: File, edit: TagEdit, options: TagWriteOptions) {
        if (edit.isEmpty) return
        if (!file.canWrite()) throw TagException("文件「${file.name}」是只读的，无法写入")
        val current = read(file, withCover = false)
        val items = RandomAccessFile(file, "r").use { locate(it).items }.toMutableList()
        fun setText(key: String, value: String) {
            val idx = items.indexOfFirst { it.key.equals(key, true) }
            items.removeAll { it.key.equals(key, true) }
            if (value.isEmpty()) return
            val item = Item(key, 0, value.toByteArray(Charsets.UTF_8))
            if (idx >= 0 && idx <= items.size) items.add(idx, item) else items.add(item)
        }
        val merged = current.fields.toMutableMap()
        for ((f, v) in edit.fields) merged[f] = v.trim()
        for ((f, k) in keys) {
            val touched = edit.fields.containsKey(f) ||
                (f == TagField.TRACK && edit.fields.containsKey(TagField.TRACK_TOTAL)) ||
                (f == TagField.DISC && edit.fields.containsKey(TagField.DISC_TOTAL))
            if (!touched) continue
            val value = when (f) {
                TagField.TRACK -> pair(merged[TagField.TRACK].orEmpty(), merged[TagField.TRACK_TOTAL].orEmpty())
                TagField.DISC -> pair(merged[TagField.DISC].orEmpty(), merged[TagField.DISC_TOTAL].orEmpty())
                else -> merged[f].orEmpty()
            }
            if (f == TagField.ALBUM_ARTIST) items.removeAll { it.key.equals("AlbumArtist", true) }
            setText(k, value)
        }
        edit.lyrics?.let { setText(LYRICS_KEY, it) }
        when (val c = edit.cover) {
            CoverChange.Keep -> Unit
            CoverChange.Remove -> items.removeAll { it.key.equals(COVER_KEY, true) }
            is CoverChange.Replace -> {
                items.removeAll { it.key.equals(COVER_KEY, true) }
                val name = "cover.${c.art.extension}".toByteArray(Charsets.UTF_8)
                items += Item(COVER_KEY, 2, name + byteArrayOf(0) + c.art.bytes)
            }
        }
        val bytes = file.readBytes()
        val layout = RandomAccessFile(file, "r").use { locate(it) }
        val out = ByteArrayOutputStream(bytes.size + 1024)
        out.write(bytes, 0, layout.tagStart.toInt())
        if (items.isNotEmpty()) out.write(encodeTag(items))
        out.write(bytes, layout.tagEnd.toInt(), (bytes.size - layout.tagEnd).toInt())
        replaceFile(file, out.toByteArray())
    }

    private fun pair(n: String, t: String) = if (n.isEmpty()) "" else if (t.isEmpty()) n else "$n/$t"

    internal fun encodeTag(items: List<Item>): ByteArray {
        val body = ByteArrayOutputStream()
        for (it in items) {
            val k = it.key.toByteArray(Charsets.US_ASCII)
            body.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putInt(it.value.size).putInt(it.flags).array())
            body.write(k); body.write(0); body.write(it.value)
        }
        val b = body.toByteArray()
        fun block(isHeader: Boolean): ByteArray {
            val flags = (1 shl 31) or (if (isHeader) 1 shl 29 else 0)
            return ByteBuffer.allocate(32).order(ByteOrder.LITTLE_ENDIAN)
                .put("APETAGEX".toByteArray(Charsets.US_ASCII)).putInt(2000).putInt(b.size + 32)
                .putInt(items.size).putInt(flags).putLong(0).array()
        }
        return block(true) + b + block(false)
    }
}
