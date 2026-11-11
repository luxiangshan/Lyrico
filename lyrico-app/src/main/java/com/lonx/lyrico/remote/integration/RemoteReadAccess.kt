package com.lonx.lyrico.remote.integration

import android.content.Context
import android.os.ParcelFileDescriptor
import android.util.Log
import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteEntry
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only access to remote songs without downloading them whole (Lyrico Mod).
 *
 * [openRead] returns, in order of preference:
 *  1. the full cached copy when it is still valid (pending edits, or remote size + mtime unchanged);
 *  2. a partial-read proxy descriptor ([RemoteProxyFd]) whose reads are served by ranged requests
 *     through the shared [RemoteBlockCache];
 *  3. a freshly downloaded full copy (fallback when the proxy can't be opened, or [allowPartial] = false).
 *
 * Writes, playback and ReplayGain keep using [RemoteFileCache.ensureLocal] (full copy).
 * Blocking; call off the main thread.
 */
class RemoteReadAccess(
    private val context: Context,
    private val storageManager: RemoteStorageManager,
    private val fileCache: RemoteFileCache,
    val coverCache: RemoteCoverCache = RemoteCoverCache(File(context.cacheDir, "remote-covers")),
    private val blockCache: RemoteBlockCache = RemoteBlockCache(),
) {
    private data class Hint(val entry: RemoteEntry, val at: Long)

    /** Entries seen by the latest listing ("configId|path" → entry), so reads don't need a stat each. */
    private val hints = object : LinkedHashMap<String, Hint>(256, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Hint>?): Boolean = size > MAX_HINTS
    }

    init {
        fileCache.onPathChanged = { configId, path -> onPathChanged(configId, path) }
    }

    /** Remembers [entry] (from a listing) so the next read of it skips the stat. */
    fun remember(configId: String, entry: RemoteEntry) {
        if (entry.isDirectory) return
        val path = RemoteUri.normalizePath(entry.path)
        synchronized(hints) { hints["$configId|$path"] = Hint(entry.copy(path = path), System.currentTimeMillis()) }
    }

    /** Metadata of a remote file: a fresh listing hint, else a stat. */
    fun entry(configId: String, path: String): RemoteEntry {
        val normalized = RemoteUri.normalizePath(path)
        synchronized(hints) {
            hints["$configId|$normalized"]?.let {
                if (System.currentTimeMillis() - it.at < HINT_TTL_MS) return it.entry
            }
        }
        val entry = try {
            storageManager.storage(configId).stat(normalized)
        } catch (e: RemoteAuthException) {
            storageManager.invalidate(configId)
            throw e
        } ?: throw FileNotFoundException("Remote file not found: $normalized")
        remember(configId, entry.copy(path = normalized))
        return entry.copy(path = normalized)
    }

    fun openRead(uriString: String, allowPartial: Boolean = true, trace: (String) -> Unit = {}): ParcelFileDescriptor {
        val parsed = RemoteUri.parse(uriString) ?: throw FileNotFoundException(uriString)
        return openRead(parsed.configId, parsed.path, allowPartial, trace)
    }

    fun openRead(
        configId: String,
        path: String,
        allowPartial: Boolean = true,
        trace: (String) -> Unit = {},
    ): ParcelFileDescriptor {
        val normalized = RemoteUri.normalizePath(path)
        // Pending edits / just-verified copy: no network at all.
        fileCache.reusableCopy(configId, normalized, null)?.let {
            trace("remoteRead localCopy(fresh)=${it.name}")
            return ParcelFileDescriptor.open(it, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        val entry = entry(configId, normalized)
        fileCache.reusableCopy(configId, normalized, entry)?.let {
            trace("remoteRead localCopy(valid)=${it.name}")
            return ParcelFileDescriptor.open(it, ParcelFileDescriptor.MODE_READ_ONLY)
        }
        if (allowPartial && entry.size > 0) {
            try {
                val reader = newReader(configId, normalized, entry)
                trace("remoteRead partial size=${entry.size}")
                return RemoteProxyFd.open(context, reader, RemoteUri.fileName(normalized))
            } catch (e: Exception) {
                Log.w(TAG, "Partial read unavailable for $normalized, downloading whole file", e)
                trace("remoteRead partialFailed=${e.message}")
            }
        }
        val file = fileCache.ensureLocal(configId, normalized, entry)
        trace("remoteRead downloaded=${file.name} size=${file.length()}")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    /** A block reader for [entry] (exposed for diagnostics/tests). */
    fun newReader(configId: String, path: String, entry: RemoteEntry): RemoteBlockReader {
        val normalized = RemoteUri.normalizePath(path)
        return RemoteBlockReader(
            fileKey = RemoteBlockCache.fileKey(configId, normalized, entry.size, entry.modifiedMillis),
            size = entry.size,
            source = { offset, length ->
                try {
                    storageManager.storage(configId).openRange(normalized, offset, length)
                } catch (e: RemoteAuthException) {
                    storageManager.invalidate(configId)
                    throw java.io.IOException(e.message, e)
                }
            },
            cache = blockCache,
            readAhead = READ_AHEAD_BLOCKS,
        )
    }

    private fun onPathChanged(configId: String, path: String) {
        val normalized = RemoteUri.normalizePath(path)
        blockCache.invalidatePrefix(RemoteBlockCache.pathPrefix(configId, normalized))
        synchronized(hints) { hints.remove("$configId|$normalized") }
        coverCache.invalidate(RemoteUri.build(configId, normalized))
    }

    /** Drops in-memory blocks and hints of a location (location edited / deleted). */
    fun clear(configId: String) {
        blockCache.invalidatePrefix("$configId|")
        synchronized(hints) { hints.keys.removeAll { it.startsWith("$configId|") } }
    }

    companion object {
        private const val TAG = "RemoteReadAccess"
        private const val MAX_HINTS = 8192
        private const val HINT_TTL_MS = 10 * 60_000L
        const val READ_AHEAD_BLOCKS = 1
    }
}
