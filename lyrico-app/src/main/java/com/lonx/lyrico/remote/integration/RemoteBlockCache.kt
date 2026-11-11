package com.lonx.lyrico.remote.integration

import java.io.IOException
import java.io.InputStream

/** Opens [length] bytes of a remote file starting at [offset] (see RemoteStorage.openRange). */
fun interface RemoteRangeSource {
    fun open(offset: Long, length: Long): InputStream
}

/**
 * Process-wide LRU of fixed-size blocks of remote files, shared by every [RemoteBlockReader].
 * A block is identified by `fileKey` (configId|path|size|mtime, so a changed file never hits stale
 * blocks) and its index. Pure JVM, thread-safe.
 */
class RemoteBlockCache(
    val blockSize: Int = DEFAULT_BLOCK_SIZE,
    private val maxBlocks: Int = DEFAULT_MAX_BLOCKS,
) {
    private data class Key(val fileKey: String, val index: Long)

    private val blocks = object : LinkedHashMap<Key, ByteArray>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, ByteArray>?): Boolean = size > maxBlocks
    }

    @Synchronized
    fun get(fileKey: String, index: Long): ByteArray? = blocks[Key(fileKey, index)]

    @Synchronized
    fun contains(fileKey: String, index: Long): Boolean = blocks.containsKey(Key(fileKey, index))

    @Synchronized
    fun put(fileKey: String, index: Long, data: ByteArray) {
        blocks[Key(fileKey, index)] = data
    }

    /** Drops every block whose file key starts with [prefix] (e.g. "configId|/path|" after an upload). */
    @Synchronized
    fun invalidatePrefix(prefix: String) {
        blocks.keys.removeAll { it.fileKey.startsWith(prefix) }
    }

    @Synchronized
    fun clear() = blocks.clear()

    @Synchronized
    fun size(): Int = blocks.size

    companion object {
        const val DEFAULT_BLOCK_SIZE = 256 * 1024
        /** 64 × 256 KB = 16 MB across all files (a tag read typically touches 1–3 blocks of a file). */
        const val DEFAULT_MAX_BLOCKS = 64

        fun fileKey(configId: String, path: String, size: Long, mtime: Long) = "$configId|$path|$size|$mtime"
        fun pathPrefix(configId: String, path: String) = "$configId|$path|"
    }
}

/**
 * Random-access reads of one remote file of known [size], served from [cache] in [RemoteBlockCache.blockSize]
 * blocks fetched with ranged requests. Once reads walk three consecutive blocks the access is treated as
 * sequential and a miss also fetches up to [readAhead] following blocks in the same request.
 * Thread-safe (reads of one reader are serialized).
 */
class RemoteBlockReader(
    val fileKey: String,
    val size: Long,
    private val source: RemoteRangeSource,
    private val cache: RemoteBlockCache,
    private val readAhead: Int = 1,
    private val maxAttempts: Int = 2,
) {
    private val blockSize = cache.blockSize
    private val blockCount = if (size <= 0) 0L else (size + blockSize - 1) / blockSize
    private var lastBlock = -2L
    private var sequentialRun = 0

    /** Bytes fetched from the network by this reader (for logging / tests). */
    @Volatile var bytesFetched = 0L
        private set
    @Volatile var requests = 0
        private set

    /** Copies up to [length] bytes at [offset] into [dst]; returns the number copied (0 at/after EOF). */
    @Synchronized
    @Throws(IOException::class)
    fun read(offset: Long, dst: ByteArray, dstOffset: Int, length: Int): Int {
        require(offset >= 0 && length >= 0 && dstOffset >= 0 && dstOffset + length <= dst.size)
        if (offset >= size || length == 0) return 0
        val wanted = minOf(length.toLong(), size - offset).toInt()
        var copied = 0
        while (copied < wanted) {
            val pos = offset + copied
            val index = pos / blockSize
            val block = block(index)
            val inBlock = (pos - index * blockSize).toInt()
            val n = minOf(wanted - copied, block.size - inBlock)
            if (n <= 0) break // file shorter than announced
            System.arraycopy(block, inBlock, dst, dstOffset + copied, n)
            copied += n
        }
        return copied
    }

    private fun block(index: Long): ByteArray {
        if (index == lastBlock + 1) sequentialRun++ else if (index != lastBlock) sequentialRun = 0
        cache.get(fileKey, index)?.let {
            lastBlock = index
            return it
        }
        var count = 1
        // Read ahead only once access is clearly streaming (third consecutive block), so a tag that
        // just spills into the second block doesn't pull a third one.
        if (sequentialRun >= 2) {
            while (count <= readAhead && index + count < blockCount && !cache.contains(fileKey, index + count)) count++
        }
        val blocks = fetch(index, count)
        lastBlock = index
        return blocks.first()
    }

    private fun fetch(first: Long, count: Int): List<ByteArray> {
        val start = first * blockSize
        val length = minOf(count.toLong() * blockSize, size - start).toInt()
        var lastError: IOException? = null
        repeat(maxAttempts) {
            try {
                val data = ByteArray(length)
                var got = 0
                requests++
                source.open(start, length.toLong()).use { input ->
                    while (got < length) {
                        val r = input.read(data, got, length - got)
                        if (r < 0) break
                        got += r
                    }
                }
                bytesFetched += got
                if (got == 0) throw IOException("No data at offset $start")
                val out = ArrayList<ByteArray>(count)
                var off = 0
                var index = first
                while (off < got) {
                    val n = minOf(blockSize, got - off)
                    val block = if (off == 0 && n == data.size) data else data.copyOfRange(off, off + n)
                    cache.put(fileKey, index, block)
                    out += block
                    off += n
                    index++
                }
                return out
            } catch (e: IOException) {
                lastError = e
            }
        }
        throw lastError ?: IOException("Read failed at $start")
    }
}
