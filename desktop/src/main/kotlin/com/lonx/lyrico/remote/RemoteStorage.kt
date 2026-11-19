package com.lonx.lyrico.remote

import java.io.File
import java.io.InputStream

/** Kind of remote location. */
enum class RemoteType { WEBDAV, OPENLIST, SMB, CLOUD115 }

/** A file or folder on a remote location. [path] is absolute within the location, '/'-separated, starting with '/'. */
data class RemoteEntry(
    val path: String,
    val name: String,
    val isDirectory: Boolean,
    val size: Long = -1,
    val modifiedMillis: Long = 0,
    /** Provider-specific id (e.g. 115 file id / pick code). Empty when unused. */
    val providerId: String = "",
)

/**
 * Connection settings for one remote location. Secrets (password, token, 115 cookie) live in
 * [secret] and are stored encrypted by the integration layer; providers never persist anything themselves
 * except through [RemoteCredentialStore].
 *  - WEBDAV:   baseUrl = "https://host:port/dav", username, secret = password
 *  - OPENLIST: baseUrl = "https://host:port", username (blank = guest), secret = password
 *  - SMB:      baseUrl = "host[:port]", share = share name, username, secret = password, domain optional
 *  - CLOUD115: secret = cookie string from QR login (UID=..; CID=..; SEID=..; KID=..)
 */
data class RemoteConfig(
    val id: String,
    val type: RemoteType,
    val displayName: String,
    val baseUrl: String = "",
    val share: String = "",
    val username: String = "",
    val secret: String = "",
    val domain: String = "",
    /** Folders on the remote chosen by the user to scan/edit. */
    val folders: List<String> = listOf("/"),
)

/** Lets a provider persist refreshed tokens/cookies (e.g. OpenList token cache, 115 cookie). */
interface RemoteCredentialStore {
    fun loadExtra(configId: String, key: String): String?
    fun saveExtra(configId: String, key: String, value: String?)
}

class RemoteAuthException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * One connected location. All methods are blocking and must be called off the main thread.
 * Implementations: WebDavStorage, OpenListStorage, SmbStorage, Cloud115Storage.
 */
interface RemoteStorage : AutoCloseable {
    val config: RemoteConfig

    /** Verifies credentials/reachability; throws RemoteAuthException or IOException with a readable message. */
    fun testConnection()

    /** Direct children of [dirPath]. */
    fun list(dirPath: String): List<RemoteEntry>

    /** Metadata of a single path, or null if it does not exist. */
    fun stat(path: String): RemoteEntry?

    /** Streams the whole file. Caller closes. */
    fun openRead(path: String): InputStream

    /** Streams [length] bytes from [offset] (length < 0 = to end). Used for fast tag-header reads. */
    fun openRange(path: String, offset: Long, length: Long): InputStream

    /**
     * Replaces the remote file at [path] with the contents of [source] (overwrite in place, same name).
     * Must not leave a truncated file on failure where the protocol allows (upload to temp + rename/move if supported).
     */
    fun upload(path: String, source: File)

    /** Renames a file within its folder; returns the new path. */
    fun rename(path: String, newName: String): String

    fun delete(path: String)

    override fun close() {}
}
