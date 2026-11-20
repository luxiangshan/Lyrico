package com.lonx.lyrico.remote.smb

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SmbRangeInputStreamTest {
    private val data = ByteArray(1000) { (it % 251).toByte() }
    private var calls = 0

    /** Fake remote file; returns at most [maxPerCall] bytes per request like a server may. */
    private fun reader(maxPerCall: Int = Int.MAX_VALUE) = SmbRangeInputStream.PositionalReader { buf, pos, off, len ->
        calls++
        if (pos >= data.size) -1 else {
            val n = minOf(len, maxPerCall, data.size - pos.toInt())
            System.arraycopy(data, pos.toInt(), buf, off, n); n
        }
    }

    @Test fun readsWholeFile() {
        val out = SmbRangeInputStream(reader(), 0, -1, chunkSize = 64).readBytes()
        assertArrayEquals(data, out)
    }

    @Test fun readsRange() {
        val out = SmbRangeInputStream(reader(), 100, 50, chunkSize = 16).readBytes()
        assertArrayEquals(data.copyOfRange(100, 150), out)
    }

    @Test fun rangePastEndStopsAtEof() {
        val out = SmbRangeInputStream(reader(), 990, 100).readBytes()
        assertArrayEquals(data.copyOfRange(990, 1000), out)
        assertEquals(0, SmbRangeInputStream(reader(), 2000, 10).readBytes().size)
    }

    @Test fun shortServerReads() {
        val out = SmbRangeInputStream(reader(maxPerCall = 7), 3, 500, chunkSize = 64).readBytes()
        assertArrayEquals(data.copyOfRange(3, 503), out)
    }

    @Test fun singleByteReadsAreBuffered() {
        val s = SmbRangeInputStream(reader(), 10, 100, chunkSize = 64)
        val got = ByteArray(100) { s.read().toByte() }
        assertEquals(-1, s.read())
        assertArrayEquals(data.copyOfRange(10, 110), got)
        assertTrue("expected buffered requests, got $calls", calls <= 3)
    }

    @Test fun skipJumpsOffset() {
        val s = SmbRangeInputStream(reader(), 0, 300, chunkSize = 32)
        assertEquals(data[0].toInt() and 0xFF, s.read())
        assertEquals(199L, s.skip(199))
        val rest = s.readBytes()
        assertArrayEquals(data.copyOfRange(200, 300), rest)
    }

    @Test fun zeroLength() {
        assertEquals(-1, SmbRangeInputStream(reader(), 5, 0).read())
        assertEquals(0, calls)
    }

    @Test fun closeCallsOnCloseOnce() {
        var closes = 0
        val s = SmbRangeInputStream(reader(), 0, -1, onClose = { closes++ })
        s.close(); s.close()
        assertEquals(1, closes)
    }
}
