package com.lonx.lyrico.remote.integration

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.util.UUID

internal val Context.remoteLocationsDataStore by preferencesDataStore(name = "remote_locations")

/**
 * Persists remote locations (without secrets) in DataStore as JSON. Secrets live in [SecureCredentialStore].
 * Configs returned by [configs] / [get] carry an empty [RemoteConfig.secret]; use [getWithSecret] to connect.
 */
class RemoteConfigRepository(
    private val context: Context,
    private val credentials: SecureCredentialStore,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val key = stringPreferencesKey("locations_json")

    val configs: Flow<List<RemoteConfig>> = context.remoteLocationsDataStore.data.map { prefs ->
        decode(prefs[key]).map { it.toConfig() }
    }

    suspend fun getAll(): List<RemoteConfig> = configs.first()

    suspend fun get(id: String): RemoteConfig? = getAll().firstOrNull { it.id == id }

    suspend fun getWithSecret(id: String): RemoteConfig? {
        val config = get(id) ?: return null
        val secret = withContext(Dispatchers.IO) { credentials.loadSecret(id) }.orEmpty()
        return config.copy(secret = secret)
    }

    /**
     * Inserts or replaces [config]. [newSecret] == null keeps the stored secret unchanged
     * (password field left blank while editing); "" clears it.
     */
    suspend fun save(config: RemoteConfig, newSecret: String?) {
        withContext(Dispatchers.IO) {
            if (newSecret != null) credentials.saveSecret(config.id, newSecret)
        }
        context.remoteLocationsDataStore.edit { prefs ->
            val current = decode(prefs[key]).toMutableList()
            val stored = StoredRemoteConfig.from(config)
            val index = current.indexOfFirst { it.id == config.id }
            if (index >= 0) current[index] = stored.copy(createdAt = current[index].createdAt) else current += stored
            prefs[key] = json.encodeToString(current)
        }
    }

    suspend fun delete(id: String) {
        context.remoteLocationsDataStore.edit { prefs ->
            prefs[key] = json.encodeToString(decode(prefs[key]).filterNot { it.id == id })
        }
        withContext(Dispatchers.IO) { credentials.deleteAll(id) }
    }

    private fun decode(raw: String?): List<StoredRemoteConfig> {
        if (raw.isNullOrBlank()) return emptyList()
        return try {
            json.decodeFromString<List<StoredRemoteConfig>>(raw)
        } catch (_: Exception) {
            emptyList()
        }
    }

    companion object {
        /** Short id; used inside song uris (`remote://<id>/...`) so it must stay uri-safe. */
        fun newId(): String = UUID.randomUUID().toString().replace("-", "").take(12)
    }
}

@Serializable
internal data class StoredRemoteConfig(
    val id: String,
    val type: String,
    val name: String,
    val url: String = "",
    val share: String = "",
    val username: String = "",
    val domain: String = "",
    val folders: List<String> = listOf("/"),
    val createdAt: Long = System.currentTimeMillis(),
) {
    fun toConfig(): RemoteConfig = RemoteConfig(
        id = id,
        type = runCatching { RemoteType.valueOf(type) }.getOrDefault(RemoteType.WEBDAV),
        displayName = name,
        baseUrl = url,
        share = share,
        username = username,
        secret = "",
        domain = domain,
        folders = folders,
    )

    companion object {
        fun from(config: RemoteConfig) = StoredRemoteConfig(
            id = config.id,
            type = config.type.name,
            name = config.displayName,
            url = config.baseUrl,
            share = config.share,
            username = config.username,
            domain = config.domain,
            folders = config.folders,
        )
    }
}
