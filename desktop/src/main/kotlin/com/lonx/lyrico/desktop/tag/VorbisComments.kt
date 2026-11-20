package com.lonx.lyrico.desktop.tag

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64

/** A Vorbis comment block (used by Ogg Opus "OpusTags"). Keys are compared case-insensitively. */
class VorbisComments(var vendor: String = "Lyrico Mod", val entries: MutableList<Pair<String, String>> = mutableListOf()) {

    fun first(key: String): String = entries.firstOrNull { it.first.equals(key, true) }?.second.orEmpty()
    fun all(key: String): List<String> = entries.filter { it.first.equals(key, true) }.map { it.second }
    fun remove(key: String) { entries.removeAll { it.first.equals(key, true) } }
    fun set(key: String, value: String) {
        val idx = entries.indexOfFirst { it.first.equals(key, true) }
        remove(key)
        if (value.isEmpty()) return
        val pair = key.uppercase() to value
        if (idx in 0..entries.size) entries.add(idx, pair) else entries.add(pair)
    }

    fun encode(): ByteArray {
        val out = ByteArrayOutputStream()
        fun int(v: Int) = out.write(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(v).array())
        val vb = vendor.toByteArray(Charsets.UTF_8)
        int(vb.size); out.write(vb)
        int(entries.size)
        for ((k, v) in entries) {
            val b = "$k=$v".toByteArray(Charsets.UTF_8)
            int(b.size); out.write(b)
        }
        return out.toByteArray()
    }

    companion object {
        fun decode(data: ByteArray, offset: Int): VorbisComments {
            val bb = ByteBuffer.wrap(data).order(ByteOrder.LITTLE_ENDIAN)
            bb.position(offset)
            fun str(): String {
                val n = bb.int
                require(n >= 0 && n <= bb.remaining()) { "bad comment length" }
                val b = ByteArray(n); bb.get(b); return String(b, Charsets.UTF_8)
            }
            val vendor = str()
            val count = bb.int
            val list = mutableListOf<Pair<String, String>>()
            repeat(count) {
                val s = str()
                val i = s.indexOf('=')
                if (i > 0) list += s.substring(0, i) to s.substring(i + 1)
            }
            return VorbisComments(vendor, list)
        }

        /** FLAC METADATA_BLOCK_PICTURE, base64 encoded for a Vorbis comment. */
        fun encodePicture(art: CoverArt): String {
            val out = ByteArrayOutputStream()
            fun int(v: Int) = out.write(ByteBuffer.allocate(4).putInt(v).array())
            val mime = art.mime.toByteArray(Charsets.US_ASCII)
            int(3); int(mime.size); out.write(mime)
            int(0) // description
            val size = ImageSize.of(art.bytes)
            int(size?.first ?: 0); int(size?.second ?: 0); int(if (size != null) 24 else 0); int(0) // width, height, depth, colors
            int(art.bytes.size); out.write(art.bytes)
            return Base64.getEncoder().encodeToString(out.toByteArray())
        }

        fun decodePicture(b64: String): CoverArt? = try {
            val bb = ByteBuffer.wrap(Base64.getMimeDecoder().decode(b64))
            bb.int
            val mime = ByteArray(bb.int).also { bb.get(it) }
            val descLen = bb.int
            bb.position(bb.position() + descLen) // description
            bb.position(bb.position() + 16)
            val data = ByteArray(bb.int).also { bb.get(it) }
            val m = String(mime, Charsets.US_ASCII).ifBlank { CoverArt.sniffMime(data) }
            CoverArt(data, m)
        } catch (_: Exception) {
            null
        }

        val fieldKeys: Map<TagField, String> = mapOf(
            TagField.TITLE to "TITLE",
            TagField.ARTIST to "ARTIST",
            TagField.ALBUM to "ALBUM",
            TagField.ALBUM_ARTIST to "ALBUMARTIST",
            TagField.TRACK to "TRACKNUMBER",
            TagField.TRACK_TOTAL to "TRACKTOTAL",
            TagField.DISC to "DISCNUMBER",
            TagField.DISC_TOTAL to "DISCTOTAL",
            TagField.YEAR to "DATE",
            TagField.GENRE to "GENRE",
            TagField.COMPOSER to "COMPOSER",
            TagField.LYRICIST to "LYRICIST",
            TagField.COMMENT to "COMMENT",
        )
    }

    fun toFields(): Map<TagField, String> {
        val m = LinkedHashMap<TagField, String>()
        for ((f, k) in fieldKeys) {
            var v = first(k)
            if (v.isEmpty()) v = when (f) {
                TagField.ALBUM_ARTIST -> first("ALBUM ARTIST")
                TagField.TRACK_TOTAL -> first("TOTALTRACKS")
                TagField.DISC_TOTAL -> first("TOTALDISCS")
                TagField.YEAR -> first("YEAR")
                TagField.COMMENT -> first("DESCRIPTION")
                else -> ""
            }
            if (f == TagField.TRACK || f == TagField.DISC) {
                val (n, t) = splitNumberPair(v)
                v = n
                if (t.isNotEmpty()) {
                    val tf = if (f == TagField.TRACK) TagField.TRACK_TOTAL else TagField.DISC_TOTAL
                    if (m[tf].isNullOrEmpty()) m[tf] = t
                }
            }
            if (v.isNotEmpty()) m[f] = v
        }
        return m
    }

    fun lyrics(): String = first("LYRICS").ifEmpty { first("UNSYNCEDLYRICS") }

    fun cover(): CoverArt? = first("METADATA_BLOCK_PICTURE").takeIf { it.isNotEmpty() }?.let { decodePicture(it) }

    fun hasCover(): Boolean = first("METADATA_BLOCK_PICTURE").isNotEmpty()

    fun apply(edit: TagEdit) {
        for ((f, v) in edit.fields) {
            val key = fieldKeys.getValue(f)
            when (f) {
                TagField.ALBUM_ARTIST -> remove("ALBUM ARTIST")
                TagField.TRACK_TOTAL -> remove("TOTALTRACKS")
                TagField.DISC_TOTAL -> remove("TOTALDISCS")
                TagField.YEAR -> remove("YEAR")
                else -> Unit
            }
            set(key, v.trim())
        }
        edit.lyrics?.let { remove("UNSYNCEDLYRICS"); set("LYRICS", it) }
        when (val c = edit.cover) {
            CoverChange.Keep -> Unit
            CoverChange.Remove -> { remove("METADATA_BLOCK_PICTURE"); remove("COVERART"); remove("COVERARTMIME") }
            is CoverChange.Replace -> {
                remove("COVERART"); remove("COVERARTMIME")
                set("METADATA_BLOCK_PICTURE", encodePicture(c.art))
            }
        }
    }
}
