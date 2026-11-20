package com.lonx.lyrico.desktop.tag

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * Ogg Opus tags (OpusTags = Vorbis comments, RFC 7845). jaudiotagger has no Opus support, so this
 * rewrites the comment header pages directly and renumbers/re-CRCs the following pages.
 */
object OpusBackend : TagBackend {

    internal class Page(
        val headerType: Int,
        val granule: Long,
        val serial: Int,
        val seq: Int,
        val segments: IntArray,
        val data: ByteArray,
        val offset: Int,
        val length: Int,
    )

    internal fun parsePages(bytes: ByteArray): List<Page> {
        val pages = ArrayList<Page>()
        var pos = 0
        val bb = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        while (pos + 27 <= bytes.size) {
            if (bytes[pos] != 'O'.code.toByte() || bytes[pos + 1] != 'g'.code.toByte() ||
                bytes[pos + 2] != 'g'.code.toByte() || bytes[pos + 3] != 'S'.code.toByte()
            ) throw TagException("不是有效的 Ogg 文件（偏移 $pos）")
            val headerType = bytes[pos + 5].toInt() and 0xff
            val granule = bb.getLong(pos + 6)
            val serial = bb.getInt(pos + 14)
            val seq = bb.getInt(pos + 18)
            val n = bytes[pos + 26].toInt() and 0xff
            if (pos + 27 + n > bytes.size) break
            val segs = IntArray(n) { bytes[pos + 27 + it].toInt() and 0xff }
            val dataLen = segs.sum()
            val start = pos + 27 + n
            if (start + dataLen > bytes.size) break
            pages += Page(headerType, granule, serial, seq, segs, bytes.copyOfRange(start, start + dataLen), pos, 27 + n + dataLen)
            pos = start + dataLen
        }
        return pages
    }

    private class Header(val pages: List<Page>, val tagPageEnd: Int, val tagsPacket: ByteArray, val headPacket: ByteArray)

    /** Returns the index (exclusive) of the last page holding the OpusTags packet, plus the packet. */
    private fun locate(pages: List<Page>): Header {
        if (pages.isEmpty()) throw TagException("Ogg 文件为空")
        val serial = pages[0].serial
        val head = pages[0].data
        if (head.size < 8 || String(head, 0, 8, Charsets.US_ASCII) != "OpusHead") throw TagException("不是 Opus 文件")
        val packet = ByteArrayOutputStream()
        var i = 1
        var done = false
        while (i < pages.size && !done) {
            val p = pages[i]
            if (p.serial != serial) { i++; continue }
            var off = 0
            for ((si, s) in p.segments.withIndex()) {
                packet.write(p.data, off, s)
                off += s
                if (s < 255) {
                    done = true
                    if (si != p.segments.lastIndex) throw TagException("OpusTags 之后的数据与标签在同一页，暂不支持")
                    break
                }
            }
            i++
        }
        if (!done) throw TagException("找不到 OpusTags")
        val tags = packet.toByteArray()
        if (tags.size < 8 || String(tags, 0, 8, Charsets.US_ASCII) != "OpusTags") throw TagException("OpusTags 头损坏")
        return Header(pages, i, tags, head)
    }

    override fun read(file: File, withCover: Boolean): TagData {
        val bytes = file.readBytes()
        val pages = parsePages(bytes)
        val h = locate(pages)
        val vc = VorbisComments.decode(h.tagsPacket, 8)
        val preSkip = ByteBuffer.wrap(h.headPacket).order(ByteOrder.LITTLE_ENDIAN).getShort(10).toInt() and 0xffff
        val channels = h.headPacket[9].toInt() and 0xff
        val lastGranule = pages.lastOrNull { it.serial == pages[0].serial && it.granule > 0 }?.granule ?: 0
        val seconds = ((lastGranule - preSkip).coerceAtLeast(0) / 48000).toInt()
        val kbps = if (seconds > 0) (bytes.size * 8L / seconds / 1000).toInt() else 0
        val audio = AudioInfo("Opus", seconds, kbps, 48000, if (channels == 1) "Mono" else if (channels == 2) "Stereo" else "$channels")
        return TagData(vc.toFields(), vc.lyrics(), if (withCover) vc.cover() else null, vc.hasCover(), audio)
    }

    override fun write(file: File, edit: TagEdit, options: TagWriteOptions) {
        if (edit.isEmpty) return
        if (!file.canWrite()) throw TagException("文件「${file.name}」是只读的，无法写入")
        val bytes = file.readBytes()
        val pages = parsePages(bytes)
        val h = locate(pages)
        val vc = VorbisComments.decode(h.tagsPacket, 8)
        vc.apply(edit)
        val oldTagPacketBytes = h.tagsPacket
        // Keep any trailing data after the comment list (RFC 7845 allows binary data with LSB of first byte set).
        val encoded = vc.encode()
        val consumed = 8 + VorbisComments.decode(oldTagPacketBytes, 8).encode().size
        val trailing = if (consumed < oldTagPacketBytes.size && (oldTagPacketBytes[consumed].toInt() and 1) == 1)
            oldTagPacketBytes.copyOfRange(consumed, oldTagPacketBytes.size) else ByteArray(0)
        val newPacket = "OpusTags".toByteArray(Charsets.US_ASCII) + encoded + trailing

        val serial = pages[0].serial
        val out = ByteArrayOutputStream(bytes.size + newPacket.size)
        out.write(bytes, 0, pages[0].offset + pages[0].length)
        // Pages between OpusHead and the end of OpusTags belonging to other streams are copied as-is (rare).
        val tagPages = buildPages(newPacket, serial, pages[1].seq)
        tagPages.forEach { out.write(it) }
        val oldTagPageCount = (1 until h.tagPageEnd).count { pages[it].serial == serial }
        val delta = tagPages.size - oldTagPageCount
        for (i in 1 until h.tagPageEnd) if (pages[i].serial != serial) out.write(bytes, pages[i].offset, pages[i].length)
        for (i in h.tagPageEnd until pages.size) {
            val p = pages[i]
            if (delta == 0 || p.serial != serial) {
                out.write(bytes, p.offset, p.length)
            } else {
                out.write(encodePage(p.headerType, p.granule, p.serial, p.seq + delta, p.segments, p.data))
            }
        }
        val last = pages.last()
        val tailStart = last.offset + last.length
        if (tailStart < bytes.size) out.write(bytes, tailStart, bytes.size - tailStart)
        replaceFile(file, out.toByteArray())
    }

    private fun buildPages(packet: ByteArray, serial: Int, firstSeq: Int): List<ByteArray> {
        val lacing = ArrayList<Int>()
        var rem = packet.size
        while (rem >= 255) { lacing += 255; rem -= 255 }
        lacing += rem // terminating value (<255; 0 when size is a multiple of 255)
        val result = ArrayList<ByteArray>()
        var li = 0
        var dataOff = 0
        var seq = firstSeq
        var first = true
        while (li < lacing.size) {
            val segs = lacing.subList(li, minOf(li + 255, lacing.size)).toIntArray()
            val len = segs.sum()
            val data = packet.copyOfRange(dataOff, dataOff + len)
            val endsPacket = li + segs.size == lacing.size
            val granule = if (endsPacket) 0L else -1L
            result += encodePage(if (first) 0 else 1, granule, serial, seq, segs, data)
            first = false
            seq++
            li += segs.size
            dataOff += len
        }
        return result
    }

    internal fun encodePage(headerType: Int, granule: Long, serial: Int, seq: Int, segments: IntArray, data: ByteArray): ByteArray {
        val buf = ByteBuffer.allocate(27 + segments.size + data.size).order(ByteOrder.LITTLE_ENDIAN)
        buf.put("OggS".toByteArray(Charsets.US_ASCII))
        buf.put(0)
        buf.put(headerType.toByte())
        buf.putLong(granule)
        buf.putInt(serial)
        buf.putInt(seq)
        buf.putInt(0)
        buf.put(segments.size.toByte())
        segments.forEach { buf.put(it.toByte()) }
        buf.put(data)
        val arr = buf.array()
        val crc = oggCrc(arr)
        ByteBuffer.wrap(arr).order(ByteOrder.LITTLE_ENDIAN).putInt(22, crc)
        return arr
    }

    private val crcTable = IntArray(256) { i ->
        var r = i shl 24
        repeat(8) { r = if (r and 0x80000000.toInt() != 0) (r shl 1) xor 0x04c11db7 else r shl 1 }
        r
    }

    internal fun oggCrc(data: ByteArray): Int {
        var crc = 0
        for (b in data) crc = (crc shl 8) xor crcTable[((crc ushr 24) xor (b.toInt() and 0xff)) and 0xff]
        return crc
    }
}

/** Writes [content] to a temp file next to [file] and atomically replaces it. */
internal fun replaceFile(file: File, content: ByteArray) {
    val tmp = File(file.parentFile, ".${file.name}.lyrico-tmp")
    try {
        tmp.writeBytes(content)
        try {
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        } catch (_: Exception) {
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    } catch (e: Exception) {
        tmp.delete()
        throw TagException("保存「${file.name}」失败：${e.message ?: e.javaClass.simpleName}", e)
    }
}
