package com.lonx.lyrico.remote.integration

import android.content.Context
import android.util.Log
import com.lonx.lyrico.remote.RemoteEntry
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap

/**
 * Local copies of remote audio files. TagLib needs a real file descriptor, so reading or editing a
 * remote song works on a cached copy:
 *  - [ensureLocal] downloads (or reuses, when remote size + mtime are unchanged) the copy.
 *  - [beginWrite] / [commitWrite] / [abortWrite] wrap a tag write: after the write the copy is uploaded
 *    back with [com.lonx.lyrico.remote.RemoteStorage.upload]. A failed upload keeps the copy marked
 *    "pending" so the user's edits are never lost; [retryPending] uploads it again, and a later read
 *    reuses the pending copy instead of re-downloading over it.
 *
 * Copies are kept under `cacheDir/remote-audio/<configId>/` and trimmed LRU to [maxBytes]
 * (pending copies are never trimmed). All methods block; call them on an IO thread.
 */
class RemoteFileCache(
    context: Context,
    private val storageManager: RemoteStorageManager,
    private val maxBytes: Long = DEFAULT_MAX_BYTES,
) {
    private val root = File(context.cacheDir, "remote-audio")
    private val pathLocks = ConcurrentHashMap<String, Any>()
    private val trimLock = Any()
    /** "configId|path" → whether the copy already held un-uploaded edits before the current write. */
    private val writesInProgress = ConcurrentHashMap<String, Boolean>()

    data class PendingUpload(val configId: String, val path: String, val file: File)

    class RemoteUploadException(message: String, cause: Throwable?) : IOException(message, cause)

    /** Returns an up-to-date local copy of [path], downloading it if needed. [known] avoids an extra stat. */
    fun ensureLocal(configId: String, path: String, known: RemoteEntry? = null): File {
        val normalized = RemoteUri.normalizePath(path)
        return withPathLock(configId, normalized) {
            val file = dataFile(configId, normalized)
            val meta = readMeta(configId, normalized)
            if (file.exists() && meta != null) {
                if (meta.pending) {
                    file.setLastModified(System.currentTimeMillis())
                    return@withPathLock file
                }
                val recentlyVerified = System.currentTimeMillis() - meta.verifiedAt < FRESH_WINDOW_MS
                if (known == null && recentlyVerified) {
                    file.setLastModified(System.currentTimeMillis())
                    return@withPathLock file
                }
                val remote = known ?: storageManager.storage(configId).stat(normalized)
                    ?: throw java.io.FileNotFoundException("Remote file not found: $normalized")
                if (matches(meta, remote) && file.length() == meta.localSize) {
                    writeMeta(configId, normalized, meta.copy(verifiedAt = System.currentTimeMillis()))
                    file.setLastModified(System.currentTimeMillis())
                    return@withPathLock file
                }
                download(configId, normalized, remote)
            } else {
                val remote = known ?: storageManager.storage(configId).stat(normalized)
                    ?: throw java.io.FileNotFoundException("Remote file not found: $normalized")
                download(configId, normalized, remote)
            }
        }.also { trim(exclude = it) }
    }

    /**
     * Lyrico Mod: called after a path's remote content changed through this cache (upload, rename,
     * delete) so partial-read block caches / entry hints can be dropped.
     */
    @Volatile var onPathChanged: ((configId: String, path: String) -> Unit)? = null

    /**
     * A cached full copy that can serve a read without downloading: a copy holding pending (not yet
     * uploaded) edits, a copy verified within the last minute, or one whose recorded remote size + mtime
     * match [known]. No network access; null when a fresh read from the server is needed.
     */
    fun reusableCopy(configId: String, path: String, known: RemoteEntry?): File? {
        val normalized = RemoteUri.normalizePath(path)
        return withPathLock(configId, normalized) {
            val file = dataFile(configId, normalized)
            val meta = readMeta(configId, normalized)
            if (!file.exists() || meta == null || file.length() != meta.localSize) return@withPathLock null
            val now = System.currentTimeMillis()
            val ok = meta.pending ||
                (known == null && now - meta.verifiedAt < FRESH_WINDOW_MS) ||
                (known != null && matches(meta, known))
            if (!ok) return@withPathLock null
            if (known != null && !meta.pending) writeMeta(configId, normalized, meta.copy(verifiedAt = now))
            file.setLastModified(now)
            file
        }
    }

    /** Local copy if one exists, without any network access (used for list cover thumbnails). */
    fun cachedCopy(configId: String, path: String): File? {
        val normalized = RemoteUri.normalizePath(path)
        val file = dataFile(configId, normalized)
        return file.takeIf { it.exists() && readMeta(configId, normalized) != null }
    }

    /**
     * Prepares the local copy for an in-place tag write. The copy is marked pending right away so that
     * a read-back during the write never re-downloads over the edited bytes.
     */
    fun beginWrite(configId: String, path: String): File {
        val normalized = RemoteUri.normalizePath(path)
        val file = ensureLocal(configId, normalized)
        withPathLock(configId, normalized) {
            val meta = readMeta(configId, normalized) ?: Meta(normalized, -1, 0, file.length(), 0, false)
            writesInProgress["$configId|$normalized"] = meta.pending
            if (!meta.pending) writeMeta(configId, normalized, meta.copy(pending = true))
        }
        return file
    }

    /**
     * Uploads the edited copy. On failure the copy is kept as pending and [RemoteUploadException] is thrown.
     */
    fun commitWrite(configId: String, path: String) {
        val normalized = RemoteUri.normalizePath(path)
        withPathLock(configId, normalized) {
            val file = dataFile(configId, normalized)
            if (!file.exists()) throw java.io.FileNotFoundException("Cached copy missing: $normalized")
            writesInProgress.remove("$configId|$normalized")
            val before = readMeta(configId, normalized) ?: Meta(normalized, -1, 0, file.length(), 0, false)
            writeMeta(configId, normalized, before.copy(pending = true, localSize = file.length()))
            uploadLocked(configId, normalized, file)
        }
    }

    /** A tag write failed before upload: drop the possibly half-written copy unless it holds older pending edits. */
    fun abortWrite(configId: String, path: String) {
        val normalized = RemoteUri.normalizePath(path)
        withPathLock(configId, normalized) {
            val wasPendingBefore = writesInProgress.remove("$configId|$normalized") ?: false
            if (!wasPendingBefore) {
                dataFile(configId, normalized).delete()
                metaFile(configId, normalized).delete()
            }
        }
    }

    fun pending(configId: String? = null): List<PendingUpload> {
        val dirs = if (configId != null) listOf(File(root, configId)) else root.listFiles()?.toList().orEmpty()
        return dirs.filter { it.isDirectory }.flatMap { dir ->
            dir.listFiles { f -> f.name.endsWith(META_SUFFIX) }.orEmpty().mapNotNull { metaFile ->
                val meta = parseMeta(metaFile) ?: return@mapNotNull null
                if (!meta.pending || writesInProgress.containsKey("${dir.name}|${meta.path}")) return@mapNotNull null
                val data = File(dir, metaFile.name.removeSuffix(META_SUFFIX))
                if (!data.exists()) return@mapNotNull null
                PendingUpload(dir.name, meta.path, data)
            }
        }
    }

    /** Uploads every pending copy (optionally of one location). Returns (succeeded, failures). */
    fun retryPending(configId: String? = null): Pair<Int, List<Pair<PendingUpload, Throwable>>> {
        var ok = 0
        val failures = mutableListOf<Pair<PendingUpload, Throwable>>()
        pending(configId).forEach { item ->
            try {
                withPathLock(item.configId, item.path) { uploadLocked(item.configId, item.path, item.file) }
                ok++
            } catch (e: Exception) {
                failures += item to e
            }
        }
        return ok to failures
    }

    /** Moves cache entries after a remote rename. */
    fun onRenamed(configId: String, oldPath: String, newPath: String) {
        val oldNorm = RemoteUri.normalizePath(oldPath)
        val newNorm = RemoteUri.normalizePath(newPath)
        onPathChanged?.invoke(configId, oldNorm)
        onPathChanged?.invoke(configId, newNorm)
        withPathLock(configId, oldNorm) {
            val oldData = dataFile(configId, oldNorm)
            val meta = readMeta(configId, oldNorm)
            if (oldData.exists() && meta != null) {
                val newData = dataFile(configId, newNorm)
                newData.parentFile?.mkdirs()
                if (oldData.renameTo(newData)) {
                    writeMeta(configId, newNorm, meta.copy(path = newNorm, verifiedAt = 0))
                }
            }
            oldData.delete()
            metaFile(configId, oldNorm).delete()
        }
    }

    fun onDeleted(configId: String, path: String) {
        val normalized = RemoteUri.normalizePath(path)
        onPathChanged?.invoke(configId, normalized)
        withPathLock(configId, normalized) {
            dataFile(configId, normalized).delete()
            metaFile(configId, normalized).delete()
        }
    }

    /**
     * Renames a remote file within its folder. Returns the new path, or null when a file with
     * [newName] already exists there.
     */
    fun renameRemote(configId: String, path: String, newName: String): String? {
        val normalized = RemoteUri.normalizePath(path)
        val storage = storageManager.storage(configId)
        val target = RemoteUri.childPath(RemoteUri.parentPath(normalized), newName)
        if (target != normalized && storage.stat(target) != null) return null
        val newPath = RemoteUri.normalizePath(storage.rename(normalized, newName))
        onRenamed(configId, normalized, newPath)
        return newPath
    }

    /** Deletes a remote file. Returns false when it was already missing. */
    fun deleteRemote(configId: String, path: String): Boolean {
        val normalized = RemoteUri.normalizePath(path)
        val storage = storageManager.storage(configId)
        val existed = storage.stat(normalized) != null
        if (existed) storage.delete(normalized)
        onDeleted(configId, normalized)
        return existed
    }

    /** Removes every cached copy of a location (location deleted). */
    fun clear(configId: String) {
        File(root, configId).deleteRecursively()
    }

    // ---------------------------------------------------------------------------------------------

    private fun uploadLocked(configId: String, path: String, file: File) {
        val storage = storageManager.storage(configId)
        try {
            storage.upload(path, file)
        } catch (e: Exception) {
            if (e is com.lonx.lyrico.remote.RemoteAuthException) storageManager.invalidate(configId)
            throw RemoteUploadException(e.message ?: e::class.java.simpleName, e)
        }
        onPathChanged?.invoke(configId, path)
        val remote = runCatching { storage.stat(path) }.getOrNull()
        writeMeta(
            configId, path,
            Meta(
                path = path,
                remoteSize = remote?.size ?: file.length(),
                remoteMtime = remote?.modifiedMillis ?: 0L,
                localSize = file.length(),
                verifiedAt = System.currentTimeMillis(),
                pending = false,
            )
        )
    }

    private fun download(configId: String, path: String, remote: RemoteEntry): File {
        val target = dataFile(configId, path)
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, target.name + ".part")
        try {
            storageManager.storage(configId).openRead(path).use { input ->
                tmp.outputStream().use { output -> input.copyTo(output, BUFFER_SIZE) }
            }
        } catch (e: Exception) {
            tmp.delete()
            if (e is com.lonx.lyrico.remote.RemoteAuthException) storageManager.invalidate(configId)
            throw e
        }
        if (remote.size >= 0 && tmp.length() != remote.size) {
            val got = tmp.length()
            tmp.delete()
            throw IOException("Incomplete download of $path: $got / ${remote.size} bytes")
        }
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IOException("Unable to store cached copy of $path")
        }
        writeMeta(
            configId, path,
            Meta(
                path = path,
                remoteSize = remote.size,
                remoteMtime = remote.modifiedMillis,
                localSize = target.length(),
                verifiedAt = System.currentTimeMillis(),
                pending = false,
            )
        )
        return target
    }

    private fun matches(meta: Meta, remote: RemoteEntry): Boolean {
        val sizeOk = remote.size < 0 || meta.remoteSize == remote.size
        val mtimeOk = remote.modifiedMillis <= 0L || meta.remoteMtime == remote.modifiedMillis
        return sizeOk && mtimeOk
    }

    private fun trim(exclude: File) {
        synchronized(trimLock) {
            val files = root.walkTopDown()
                .filter { it.isFile && !it.name.endsWith(META_SUFFIX) && !it.name.endsWith(".part") && !it.name.endsWith(".tmp") }
                .toList()
            var total = files.sumOf { it.length() }
            if (total <= maxBytes) return
            files.sortedBy { it.lastModified() }.forEach { file ->
                if (total <= maxBytes) return
                if (file == exclude) return@forEach
                val meta = parseMeta(File(file.parentFile, file.name + META_SUFFIX))
                if (meta?.pending == true) return@forEach
                val size = file.length()
                if (file.delete()) {
                    File(file.parentFile, file.name + META_SUFFIX).delete()
                    total -= size
                }
            }
        }
    }

    private inline fun <T> withPathLock(configId: String, path: String, block: () -> T): T {
        val lock = pathLocks.getOrPut("$configId|$path") { Any() }
        return synchronized(lock) { block() }
    }

    private fun baseName(path: String): String {
        val digest = MessageDigest.getInstance("SHA-1").digest(path.toByteArray(Charsets.UTF_8))
        val hex = digest.joinToString("") { "%02x".format(it) }.take(32)
        val ext = RemoteUri.fileName(path).substringAfterLast('.', "").lowercase().take(8)
        return if (ext.isEmpty()) hex else "$hex.$ext"
    }

    private fun dataFile(configId: String, path: String) = File(File(root, configId), baseName(path))

    private fun metaFile(configId: String, path: String) =
        File(File(root, configId), baseName(path) + META_SUFFIX)

    private data class Meta(
        val path: String,
        val remoteSize: Long,
        val remoteMtime: Long,
        val localSize: Long,
        val verifiedAt: Long,
        val pending: Boolean,
    )

    private fun readMeta(configId: String, path: String): Meta? = parseMeta(metaFile(configId, path))

    private fun parseMeta(file: File): Meta? {
        if (!file.exists()) return null
        return try {
            val lines = file.readLines()
            Meta(
                path = lines[0],
                remoteSize = lines[1].toLong(),
                remoteMtime = lines[2].toLong(),
                localSize = lines[3].toLong(),
                verifiedAt = lines[4].toLong(),
                pending = lines[5].toBoolean(),
            )
        } catch (e: Exception) {
            Log.w(TAG, "Corrupt cache meta ${file.name}", e)
            null
        }
    }

    private fun writeMeta(configId: String, path: String, meta: Meta) {
        val file = metaFile(configId, path)
        file.parentFile?.mkdirs()
        val tmp = File(file.parentFile, file.name + ".tmp")
        tmp.writeText(
            listOf(meta.path, meta.remoteSize, meta.remoteMtime, meta.localSize, meta.verifiedAt, meta.pending)
                .joinToString("\n")
        )
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    }

    companion object {
        private const val TAG = "RemoteFileCache"
        private const val META_SUFFIX = ".meta"
        private const val BUFFER_SIZE = 256 * 1024
        private const val FRESH_WINDOW_MS = 60_000L
        const val DEFAULT_MAX_BYTES = 1024L * 1024L * 1024L
    }
}
