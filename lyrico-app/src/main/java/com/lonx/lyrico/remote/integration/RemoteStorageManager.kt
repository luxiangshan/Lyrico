package com.lonx.lyrico.remote.integration

import android.util.Log
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteStorage
import kotlinx.coroutines.runBlocking
import java.io.FileNotFoundException

/**
 * Keeps one connected [RemoteStorage] per saved location. All methods are blocking: call them off the
 * main thread (Dispatchers.IO).
 */
class RemoteStorageManager(
    private val configRepository: RemoteConfigRepository,
    private val factory: RemoteStorageFactory,
) {
    private val storages = HashMap<String, RemoteStorage>()
    private val lock = Any()

    /** Returns the storage for [configId], connecting lazily. Throws FileNotFoundException if the location was deleted. */
    fun storage(configId: String): RemoteStorage {
        synchronized(lock) { storages[configId]?.let { return it } }
        val config = runBlocking { configRepository.getWithSecret(configId) }
            ?: throw FileNotFoundException("Remote location $configId no longer exists")
        val created = factory.create(config)
        synchronized(lock) {
            val existing = storages[configId]
            if (existing != null) {
                runCatching { created.close() }
                return existing
            }
            storages[configId] = created
            return created
        }
    }

    /** A throw-away storage for a config that is not saved yet (connection test / folder browsing in the editor). */
    fun createTransient(config: RemoteConfig): RemoteStorage = factory.create(config)

    /** Drops the cached connection so the next call reconnects with fresh settings. */
    fun invalidate(configId: String) {
        val removed = synchronized(lock) { storages.remove(configId) }
        try {
            removed?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to close remote storage $configId", e)
        }
    }

    fun invalidateAll() {
        val all = synchronized(lock) { storages.values.toList().also { storages.clear() } }
        all.forEach { runCatching { it.close() } }
    }

    private companion object {
        const val TAG = "RemoteStorageManager"
    }
}
