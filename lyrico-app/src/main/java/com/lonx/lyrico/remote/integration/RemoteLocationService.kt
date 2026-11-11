package com.lonx.lyrico.remote.integration

import com.lonx.lyrico.data.model.log.AppLog
import com.lonx.lyrico.data.model.log.AppLogLevel
import com.lonx.lyrico.data.model.log.AppLogType
import com.lonx.lyrico.data.repository.LibraryFolderRepository
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import com.lonx.lyrico.utils.LibraryScanManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext

/**
 * High-level operations on saved remote locations used by the Folder Manager UI:
 * test / browse / save (registers folders and queues a scan) / delete / retry uploads.
 */
class RemoteLocationService(
    val configRepository: RemoteConfigRepository,
    private val storageManager: RemoteStorageManager,
    private val fileCache: RemoteFileCache,
    private val folderRepository: LibraryFolderRepository,
    private val scanManager: LibraryScanManager,
) {
    val configs: Flow<List<RemoteConfig>> = configRepository.configs

    /**
     * Resolves the config the editor is working on: when [newSecret] is null (password left blank while
     * editing) the stored secret is used.
     */
    suspend fun resolveForConnect(config: RemoteConfig, newSecret: String?): RemoteConfig {
        if (newSecret != null) return config.copy(secret = newSecret)
        val stored = configRepository.getWithSecret(config.id)?.secret.orEmpty()
        return config.copy(secret = stored)
    }

    /** Opens a throw-away connection for [config] and verifies it. Caller closes the result. */
    suspend fun connect(config: RemoteConfig): RemoteStorage = withContext(Dispatchers.IO) {
        val storage = storageManager.createTransient(config)
        try {
            storage.testConnection()
            storage
        } catch (e: Exception) {
            runCatching { storage.close() }
            throw e
        }
    }

    suspend fun listFolders(storage: RemoteStorage, path: String): List<RemoteEntry> = withContext(Dispatchers.IO) {
        storage.list(path)
            .filter { it.isDirectory }
            .map { entry ->
                val name = entry.name.ifBlank { RemoteUri.fileName(entry.path) }
                entry.copy(
                    name = name,
                    path = RemoteUri.normalizePath(entry.path.ifBlank { RemoteUri.childPath(path, name) })
                )
            }
            .filterNot { it.name.startsWith(".") }
            .sortedBy { it.name.lowercase() }
    }

    /**
     * Persists [config] ([newSecret] null = keep stored secret), syncs its folder rows and queues a scan
     * of its folders. Returns the registered root folder ids.
     */
    suspend fun save(config: RemoteConfig, newSecret: String?): List<Long> {
        val previous = configRepository.get(config.id)
        val folders = RemoteLibraryScanner.topLevelFolders(config.folders.ifEmpty { listOf("/") })
        val normalized = config.copy(folders = folders, secret = "")
        configRepository.save(normalized, newSecret)
        storageManager.invalidate(config.id)

        val newPaths = folders.map { RemoteUri.displayPath(config.id, it) }
        val removedPaths = previous?.folders.orEmpty()
            .map { RemoteUri.displayPath(config.id, RemoteUri.normalizePath(it)) }
            .filter { old -> newPaths.none { new -> old == new || old.startsWith("$new/") } }
        if (removedPaths.isNotEmpty()) folderRepository.removeRemoteFolders(removedPaths)

        val ids = newPaths.map { folderRepository.registerRemote(it) }.distinct()
        AppLog.record(
            AppLogType.APP, TAG, "Remote location saved",
            "id=${config.id}\ntype=${config.type}\nfolders=$folders\nremoved=$removedPaths\nfolderIds=$ids",
            level = AppLogLevel.INFO
        )
        scanManager.scanFolders(ids.toSet())
        return ids
    }

    /** Rescans every folder of a location. */
    fun rescan(folderIds: Set<Long>) {
        scanManager.scanFolders(folderIds, fullRescan = false)
    }

    /** Removes a location: its folder rows and songs (library only, remote files are untouched), secrets and cache. */
    suspend fun delete(configId: String) {
        folderRepository.removeRemoteFolders(listOf(RemoteUri.PREFIX + configId))
        configRepository.delete(configId)
        storageManager.invalidate(configId)
        withContext(Dispatchers.IO) { fileCache.clear(configId) }
        AppLog.record(AppLogType.APP, TAG, "Remote location deleted", "id=$configId", level = AppLogLevel.INFO)
    }

    fun pendingUploadCount(configId: String): Int = fileCache.pending(configId).size

    /** Uploads edits whose upload failed earlier. Returns (uploaded, failed messages). */
    suspend fun retryUploads(configId: String?): Pair<Int, List<String>> = withContext(Dispatchers.IO) {
        val (ok, failures) = fileCache.retryPending(configId)
        ok to failures.map { (item, error) -> "${RemoteUri.fileName(item.path)}: ${error.message ?: error::class.java.simpleName}" }
    }

    private companion object {
        const val TAG = "RemoteLocations"
    }
}
