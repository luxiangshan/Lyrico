package com.lonx.lyrico.desktop.remote

import com.lonx.lyrico.desktop.settings.AppDirs
import com.lonx.lyrico.desktop.settings.appJson
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteType
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Protects secrets at rest: Windows DPAPI (bound to the Windows user) when available,
 * otherwise AES-GCM with a random key file in the app data folder.
 */
object SecretBox {
    private val isWindows = System.getProperty("os.name").orEmpty().startsWith("Windows")

    private val aesKey: ByteArray by lazy {
        val f = File(AppDirs.root, ".key")
        if (f.isFile && f.length() == 32L) f.readBytes() else ByteArray(32).also { SecureRandom().nextBytes(it); f.writeBytes(it) }
    }

    fun seal(plain: String): String {
        if (plain.isEmpty()) return ""
        val bytes = plain.toByteArray(Charsets.UTF_8)
        if (isWindows) {
            try {
                return "dpapi:" + Base64.getEncoder().encodeToString(com.sun.jna.platform.win32.Crypt32Util.cryptProtectData(bytes))
            } catch (_: Throwable) {
            }
        }
        val iv = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, iv))
        return "aes:" + Base64.getEncoder().encodeToString(iv + c.doFinal(bytes))
    }

    fun open(sealed: String): String = try {
        when {
            sealed.isEmpty() -> ""
            sealed.startsWith("dpapi:") -> String(
                com.sun.jna.platform.win32.Crypt32Util.cryptUnprotectData(Base64.getDecoder().decode(sealed.removePrefix("dpapi:"))),
                Charsets.UTF_8,
            )
            sealed.startsWith("aes:") -> {
                val all = Base64.getDecoder().decode(sealed.removePrefix("aes:"))
                val c = Cipher.getInstance("AES/GCM/NoPadding")
                c.init(Cipher.DECRYPT_MODE, SecretKeySpec(aesKey, "AES"), GCMParameterSpec(128, all, 0, 12))
                String(c.doFinal(all, 12, all.size - 12), Charsets.UTF_8)
            }
            else -> sealed
        }
    } catch (_: Throwable) {
        ""
    }
}

@Serializable
private data class StoredRemote(
    val id: String,
    val type: RemoteType,
    val displayName: String,
    val baseUrl: String = "",
    val share: String = "",
    val username: String = "",
    val secret: String = "",
    val domain: String = "",
    val folders: List<String> = listOf("/"),
)

object RemoteConfigStore : RemoteCredentialStore {
    private val file get() = File(AppDirs.root, "remotes.json")
    private val extrasFile get() = File(AppDirs.root, "remote-extras.json")
    private val lock = Any()

    fun load(): List<RemoteConfig> = synchronized(lock) {
        try {
            if (!file.isFile) return emptyList()
            appJson.decodeFromString(ListSerializer(StoredRemote.serializer()), file.readText()).map {
                RemoteConfig(it.id, it.type, it.displayName, it.baseUrl, it.share, it.username, SecretBox.open(it.secret), it.domain, it.folders)
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun save(list: List<RemoteConfig>) = synchronized(lock) {
        val stored = list.map {
            StoredRemote(it.id, it.type, it.displayName, it.baseUrl, it.share, it.username, SecretBox.seal(it.secret), it.domain, it.folders)
        }
        file.writeText(appJson.encodeToString(ListSerializer(StoredRemote.serializer()), stored))
    }

    private val mapSer = MapSerializer(String.serializer(), String.serializer())

    private fun extras(): MutableMap<String, String> = try {
        if (extrasFile.isFile) appJson.decodeFromString(mapSer, extrasFile.readText()).toMutableMap() else mutableMapOf()
    } catch (_: Exception) {
        mutableMapOf()
    }

    override fun loadExtra(configId: String, key: String): String? = synchronized(lock) {
        extras()["$configId/$key"]?.let { SecretBox.open(it) }?.takeIf { it.isNotEmpty() }
    }

    override fun saveExtra(configId: String, key: String, value: String?) = synchronized(lock) {
        val m = extras()
        if (value == null) m.remove("$configId/$key") else m["$configId/$key"] = SecretBox.seal(value)
        extrasFile.writeText(appJson.encodeToString(mapSer, m))
    }

    fun dropExtras(configId: String) = synchronized(lock) {
        val m = extras()
        m.keys.removeAll { it.startsWith("$configId/") }
        extrasFile.writeText(appJson.encodeToString(mapSer, m))
    }
}
