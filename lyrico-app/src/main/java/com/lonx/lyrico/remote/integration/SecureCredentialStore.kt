package com.lonx.lyrico.remote.integration

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import com.lonx.lyrico.remote.RemoteCredentialStore
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Secrets for remote locations (passwords, 115 cookie, provider token caches), encrypted with an
 * AES-256-GCM key kept in the Android Keystore. Values are stored as base64(iv || ciphertext) in a private
 * SharedPreferences file which is excluded from backups (the Keystore key cannot be restored anyway).
 */
class SecureCredentialStore(context: Context) : RemoteCredentialStore {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val lock = Any()

    fun loadSecret(configId: String): String? = read(key(configId, SECRET_KEY))

    fun saveSecret(configId: String, secret: String?) = write(key(configId, SECRET_KEY), secret)

    override fun loadExtra(configId: String, key: String): String? = read(key(configId, "x:$key"))

    override fun saveExtra(configId: String, key: String, value: String?) = write(key(configId, "x:$key"), value)

    /** Removes the secret and every provider extra of [configId]. */
    fun deleteAll(configId: String) {
        synchronized(lock) {
            val prefix = "$configId|"
            val editor = prefs.edit()
            prefs.all.keys.filter { it.startsWith(prefix) }.forEach(editor::remove)
            editor.apply()
        }
    }

    private fun key(configId: String, name: String) = "$configId|$name"

    private fun read(prefKey: String): String? = synchronized(lock) {
        val stored = prefs.getString(prefKey, null) ?: return null
        try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            if (bytes.size <= IV_SIZE) return null
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_SIZE))
            String(cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE), Charsets.UTF_8)
        } catch (e: Exception) {
            Log.w(TAG, "Unable to decrypt remote secret $prefKey", e)
            null
        }
    }

    private fun write(prefKey: String, value: String?) {
        synchronized(lock) {
            if (value == null) {
                prefs.edit().remove(prefKey).apply()
                return
            }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            val iv = cipher.iv
            val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
            val payload = ByteArray(iv.size + encrypted.size)
            System.arraycopy(iv, 0, payload, 0, iv.size)
            System.arraycopy(encrypted, 0, payload, iv.size, encrypted.size)
            // commit(): credentials must be durable before a scan/upload uses them from another thread.
            prefs.edit().putString(prefKey, Base64.encodeToString(payload, Base64.NO_WRAP)).commit()
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return generator.generateKey()
    }

    private companion object {
        const val TAG = "SecureCredentialStore"
        const val PREFS_NAME = "remote_secrets"
        const val SECRET_KEY = "secret"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val KEY_ALIAS = "lyrico_mod_remote_secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
        const val TAG_BITS = 128
    }
}
