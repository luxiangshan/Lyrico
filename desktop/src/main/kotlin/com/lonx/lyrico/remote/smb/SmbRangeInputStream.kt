package com.lonx.lyrico.remote.smb

import java.io.IOException
import java.io.InputStream

/**
 * Sequential InputStream over a positional reader (smbj File.read(buf, fileOffset, off, len)), starting at
 * [offset] and stopping after [length] bytes (length < 0 = until EOF). Reads in [chunkSize] network requests
 * so small caller reads don't each cost a round trip. [onClose] releases the remote handle.
 */
internal class SmbRangeInputStream(
    private val reader: PositionalReader,
    offset: Long,
    length: Long,
    private val chunkSize: Int = DEFAULT_CHUNK,
    private val onClose: () -> Unit = {},
) : InputStream() {

    fun interface PositionalReader {
        /** Reads up to [len] bytes at [fileOffset] into [buf]@[off]; returns bytes read, or <= 0 / -1 at EOF. */
        fun read(buf: ByteArray, fileOffset: Long, off: Int, len: Int): Int
    }

    init {
        require(offset >= 0) { "offset must be >= 0" }
        require(chunkSize > 0) { "chunkSize must be > 0" }
    }

    private var position = offset
    /** Bytes still allowed to be returned; Long.MAX_VALUE when unbounded. */
    private var remaining = if (length < 0) Long.MAX_VALUE else length
    private val buffer = ByteArray(chunkSize)
    private var bufPos = 0
    private var bufLen = 0
    private var eof = false
    private var closed = false

    private fun ensureOpen() { if (closed) throw IOException("Stream closed") }

    /** Fills the buffer; returns false at EOF / range end. */
    private fun fill(): Boolean {
        if (eof || remaining <= 0) return false
        val want = minOf(chunkSize.toLong(), remaining).toInt()
        var n = reader.read(buffer, position, 0, want)
        if (n <= 0) { eof = true; return false }
        if (n > want) n = want
        position += n
        bufPos = 0
        bufLen = n
        return true
    }

    override fun read(): Int {
        ensureOpen()
        if (bufPos >= bufLen && !fill()) return -1
        remaining--
        return buffer[bufPos++].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        ensureOpen()
        if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException()
        if (len == 0) return 0
        if (bufPos >= bufLen && !fill()) return -1
        val n = minOf(len, bufLen - bufPos)
        System.arraycopy(buffer, bufPos, b, off, n)
        bufPos += n
        remaining -= n
        return n
    }

    override fun skip(n: Long): Long {
        ensureOpen()
        if (n <= 0) return 0
        val inBuf = (bufLen - bufPos).toLong()
        if (n <= inBuf) {
            bufPos += n.toInt(); remaining -= n; return n
        }
        // Drop the buffer and jump the file offset; we can't know EOF without reading, so cap by range only.
        val extra = minOf(n - inBuf, remaining - inBuf)
        bufPos = 0; bufLen = 0
        position += extra
        val skipped = inBuf + extra
        remaining -= skipped
        return skipped
    }

    override fun available(): Int = if (closed) 0 else bufLen - bufPos

    override fun close() {
        if (closed) return
        closed = true
        onClose()
    }

    companion object {
        const val DEFAULT_CHUNK = 64 * 1024
    }
}
