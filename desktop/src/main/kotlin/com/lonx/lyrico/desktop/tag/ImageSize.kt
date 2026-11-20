package com.lonx.lyrico.desktop.tag

/** Width/height from image headers (JPEG, PNG, WebP, GIF, BMP) without decoding; ImageIO cannot read WebP. */
object ImageSize {
    fun of(b: ByteArray): Pair<Int, Int>? = try {
        when {
            b.size > 24 && b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte() -> be32(b, 16) to be32(b, 20)
            b.size > 30 && ascii(b, 0, 4) == "RIFF" && ascii(b, 8, 4) == "WEBP" -> webp(b)
            b.size > 10 && ascii(b, 0, 3) == "GIF" -> le16(b, 6) to le16(b, 8)
            b.size > 26 && ascii(b, 0, 2) == "BM" -> le32(b, 18) to kotlin.math.abs(le32(b, 22))
            b.size > 4 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte() -> jpeg(b)
            else -> null
        }?.takeIf { it.first > 0 && it.second > 0 }
    } catch (_: Exception) {
        null
    }

    private fun webp(b: ByteArray): Pair<Int, Int>? = when (ascii(b, 12, 4)) {
        "VP8X" -> (1 + u24(b, 24)) to (1 + u24(b, 27))
        "VP8L" -> {
            val bits = le32(b, 21)
            (1 + (bits and 0x3FFF)) to (1 + ((bits ushr 14) and 0x3FFF))
        }
        "VP8 " -> (le16(b, 26) and 0x3FFF) to (le16(b, 28) and 0x3FFF)
        else -> null
    }

    private fun jpeg(b: ByteArray): Pair<Int, Int>? {
        var i = 2
        while (i + 9 < b.size) {
            if (b[i] != 0xFF.toByte()) { i++; continue }
            val marker = b[i + 1].toInt() and 0xFF
            if (marker == 0xD8 || marker in 0xD0..0xD7 || marker == 0x01 || marker == 0xFF) { i++; continue }
            val len = be16(b, i + 2)
            if (marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC) return be16(b, i + 7) to be16(b, i + 5)
            i += 2 + len
        }
        return null
    }

    private fun ascii(b: ByteArray, o: Int, n: Int) = String(b, o, n, Charsets.US_ASCII)
    private fun u(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    private fun be16(b: ByteArray, i: Int) = (u(b, i) shl 8) or u(b, i + 1)
    private fun be32(b: ByteArray, i: Int) = (u(b, i) shl 24) or (u(b, i + 1) shl 16) or (u(b, i + 2) shl 8) or u(b, i + 3)
    private fun le16(b: ByteArray, i: Int) = u(b, i) or (u(b, i + 1) shl 8)
    private fun u24(b: ByteArray, i: Int) = u(b, i) or (u(b, i + 1) shl 8) or (u(b, i + 2) shl 16)
    private fun le32(b: ByteArray, i: Int) = u(b, i) or (u(b, i + 1) shl 8) or (u(b, i + 2) shl 16) or (u(b, i + 3) shl 24)
}
