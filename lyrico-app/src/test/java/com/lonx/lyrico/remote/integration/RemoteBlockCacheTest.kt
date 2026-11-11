package com.lonx.lyrico.remote.integration

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import kotlin.random.Random

class RemoteBlockCacheTest {

    /** Fake remote file: counts bytes actually served by ranged requests. */
    private class FakeRemote(val data: ByteArray, var failNext: Int = 0) : RemoteRangeSource {
        var bytesServed = 0L
        var requests = 0
        override fun open(offset: Long, length: Long): InputStream {
            requests++
            if (failNext > 0) { failNext--; throw IOException("boom") }
            val start = offset.toInt().coerceAtMost(data.size)
            val end = if (length < 0) data.size else minOf(data.size.toLong(), offset + length).toInt()
            bytesServed += (end - start)
            return ByteArrayInputStream(data, start, end - start)
        }
    }

    private fun file(size: Int) = Random(42).nextBytes(size)

    /** Mimics TagLib reading through a stdio FILE* (4 KB buffered reads) at the given positions. */
    private fun stdioRead(reader: RemoteBlockReader, offset: Long, length: Int): ByteArray {
        val out = ByteArray(length)
        var pos = offset
        var done = 0
        while (done < length) {
            val chunk = minOf(4096, length - done)
            val n = reader.read(pos, out, done, chunk)
            if (n <= 0) break
            done += n
            pos += n
        }
        return out.copyOf(done)
    }

    @Test
    fun readsReturnExactBytes() {
        val data = file(3 * 1024 * 1024 + 123)
        val remote = FakeRemote(data)
        val reader = RemoteBlockReader("k", data.size.toLong(), remote, RemoteBlockCache())
        val rnd = Random(1)
        repeat(200) {
            val off = rnd.nextLong(data.size.toLong())
            val len = rnd.nextInt(1, 300_000)
            val got = stdioRead(reader, off, len)
            val expected = data.copyOfRange(off.toInt(), minOf(data.size, (off + len).toInt()))
            assertArrayEquals(expected, got)
        }
        // Past EOF
        assertEquals(0, reader.read(data.size.toLong(), ByteArray(10), 0, 10))
        assertEquals(0, reader.read(data.size + 100L, ByteArray(10), 0, 10))
    }

    @Test
    fun typicalMp3TagReadFetchesWellUnderOneMegabyte() {
        // 9 MB MP3 with a 180 KB ID3v2 tag (cover art) at the front, ID3v1 at the end.
        val size = 9 * 1024 * 1024
        val data = file(size)
        val remote = FakeRemote(data)
        val cache = RemoteBlockCache()
        val reader = RemoteBlockReader(RemoteBlockCache.fileKey("c", "/a.mp3", size.toLong(), 1L), size.toLong(), remote, cache)
        val tagSize = 180 * 1024
        // getAudioProperties + getMetadata each open the file: TagLib reads the header, the ID3v2 tag,
        // the first MPEG frame / Xing header, then the tail (ID3v1, APE footer, last frame).
        repeat(2) {
            stdioRead(reader, 0, 10)
            stdioRead(reader, 10, tagSize)
            stdioRead(reader, tagSize + 10L, 4096)
            stdioRead(reader, size - 128L, 128)
            stdioRead(reader, size - 160L, 32)
            var pos = size - 128L - 4096
            repeat(4) { stdioRead(reader, pos, 4096); pos -= 4096 }
        }
        assertTrue("fetched ${remote.bytesServed} bytes", remote.bytesServed < 1024 * 1024)
        assertEquals(remote.bytesServed, reader.bytesFetched)
    }

    @Test
    fun typicalFlacTagReadFetchesWellUnderOneMegabyte() {
        // 30 MB FLAC, metadata blocks incl. a 400 KB picture at the front.
        val size = 30 * 1024 * 1024
        val data = file(size)
        val remote = FakeRemote(data)
        val reader = RemoteBlockReader("flac", size.toLong(), remote, RemoteBlockCache())
        stdioRead(reader, 0, 4)
        var pos = 4L
        listOf(34, 2_000, 400 * 1024, 8_000).forEach { blockLen ->
            stdioRead(reader, pos, 4); pos += 4
            stdioRead(reader, pos, blockLen); pos += blockLen
        }
        stdioRead(reader, size - 128L, 128) // ID3v1 probe
        assertTrue("fetched ${remote.bytesServed} bytes", remote.bytesServed < 1024 * 1024)
    }

    @Test
    fun sequentialMissReadsAheadAndRandomMissDoesNot() {
        val bs = 256 * 1024
        val data = file(bs * 10)
        val remote = FakeRemote(data)
        val reader = RemoteBlockReader("k", data.size.toLong(), remote, RemoteBlockCache(), readAhead = 1)
        reader.read(0, ByteArray(10), 0, 10)                 // block 0 only
        assertEquals(bs.toLong(), remote.bytesServed)
        reader.read(bs.toLong(), ByteArray(10), 0, 10)       // block 1: still no read-ahead
        assertEquals(2L * bs, remote.bytesServed)
        reader.read(2L * bs, ByteArray(10), 0, 10)           // block 2: streaming -> blocks 2+3
        assertEquals(4L * bs, remote.bytesServed)
        reader.read(3L * bs + 5, ByteArray(10), 0, 10)       // block 3 already cached
        assertEquals(4L * bs, remote.bytesServed)
        reader.read(7L * bs, ByteArray(10), 0, 10)           // random -> block 7 only
        assertEquals(5L * bs, remote.bytesServed)
        assertEquals(4, remote.requests)
    }

    @Test
    fun cacheIsSharedBetweenReadersOfTheSameFileAndInvalidatedByPrefix() {
        val data = file(600_000)
        val remote = FakeRemote(data)
        val cache = RemoteBlockCache()
        val key = RemoteBlockCache.fileKey("cfg", "/x.flac", data.size.toLong(), 7L)
        RemoteBlockReader(key, data.size.toLong(), remote, cache).read(0, ByteArray(100), 0, 100)
        val served = remote.bytesServed
        RemoteBlockReader(key, data.size.toLong(), remote, cache).read(0, ByteArray(100), 0, 100)
        assertEquals(served, remote.bytesServed)
        cache.invalidatePrefix(RemoteBlockCache.pathPrefix("cfg", "/x.flac"))
        RemoteBlockReader(key, data.size.toLong(), remote, cache).read(0, ByteArray(100), 0, 100)
        assertTrue(remote.bytesServed > served)
    }

    @Test
    fun lruEvictsOldBlocks() {
        val bs = 256 * 1024
        val data = file(bs * 8)
        val cache = RemoteBlockCache(maxBlocks = 3)
        val reader = RemoteBlockReader("k", data.size.toLong(), FakeRemote(data), cache, readAhead = 0)
        for (i in 0 until 8 step 2) reader.read(i.toLong() * bs, ByteArray(1), 0, 1)
        assertEquals(3, cache.size())
    }

    @Test
    fun transientFailureIsRetriedOnce() {
        val data = file(1000)
        val remote = FakeRemote(data, failNext = 1)
        val reader = RemoteBlockReader("k", data.size.toLong(), remote, RemoteBlockCache())
        val out = ByteArray(1000)
        assertEquals(1000, reader.read(0, out, 0, 1000))
        assertArrayEquals(data, out)
        assertEquals(2, remote.requests)
    }

    @Test(expected = IOException::class)
    fun persistentFailurePropagates() {
        val data = file(1000)
        val reader = RemoteBlockReader("k", data.size.toLong(), FakeRemote(data, failNext = 5), RemoteBlockCache())
        reader.read(0, ByteArray(10), 0, 10)
    }

    @Test
    fun coverCacheStoresHitsMissesAndNoCoverMarkers() {
        val dir = Files.createTempDirectory("covers").toFile()
        try {
            val cache = RemoteCoverCache(dir)
            val uri = "remote://c/a.mp3"
            assertEquals(RemoteCoverCache.Lookup.Miss, cache.get(uri, 10, 1))
            cache.put(uri, 10, 1, byteArrayOf(1, 2, 3))
            assertArrayEquals(byteArrayOf(1, 2, 3), (cache.get(uri, 10, 1) as RemoteCoverCache.Lookup.Hit).bytes)
            assertTrue(cache.has(uri, 10, 1))
            // New version of the file replaces the old entry.
            cache.put(uri, 11, 2, null)
            assertEquals(RemoteCoverCache.Lookup.NoCover, cache.get(uri, 11, 2))
            assertEquals(RemoteCoverCache.Lookup.Miss, cache.get(uri, 10, 1))
            cache.invalidate(uri)
            assertEquals(RemoteCoverCache.Lookup.Miss, cache.get(uri, 11, 2))
        } finally {
            dir.deleteRecursively()
        }
    }
}
