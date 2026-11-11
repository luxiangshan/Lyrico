package com.lonx.lyrico.remote.smb

import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.security.bc.BCSecurityProvider
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.auth.NtlmAuthenticator
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File as SmbFile
import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteEntry
import com.lonx.lyrico.remote.RemoteStorage
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.io.InputStream
import java.util.EnumSet
import java.util.concurrent.TimeUnit

/**
 * SMB2/3 location backed by smbj. Connection, session and tree (share) are opened lazily on first use,
 * reused, and re-established once when an operation fails because the connection/session died.
 *
 * config.baseUrl = "host[:port]" (default 445), config.share = share name,
 * config.username (blank = guest, then anonymous), config.secret = password, config.domain optional.
 */
class SmbStorage(
    override val config: RemoteConfig,
    /** Unused: SMB has no tokens to refresh. Accepted so the factory can construct every provider the same way. */
    @Suppress("unused") private val credentialStore: RemoteCredentialStore? = null,
) : RemoteStorage {

    private val hostPort: SmbPaths.HostPort = SmbPaths.parseHost(config.baseUrl)
    private val hostDesc = "${hostPort.host}:${hostPort.port}"

    private val lock = Any()
    private var client: SMBClient? = null
    private var connection: Connection? = null
    private var session: Session? = null
    private var diskShare: DiskShare? = null
    @Volatile private var closed = false

    // ---- connection management ------------------------------------------------------------------

    /** Returns a live DiskShare, connecting/authenticating if needed. */
    private fun share(): DiskShare = synchronized(lock) {
        if (closed) throw IOException("SMB storage is closed")
        val current = diskShare
        if (current != null && current.isConnected && connection?.isConnected == true) return current
        if (current != null) closeQuietlyLocked()

        val shareName = config.share.trim().trim('\\', '/')
        if (shareName.isEmpty()) throw IOException("No SMB share selected")

        val c = client ?: SMBClient(buildSmbConfig()).also { client = it }
        val conn = c.connect(hostPort.host, hostPort.port)
        connection = conn
        try {
            val sess = authenticate(conn, config.username, config.secret, config.domain)
            session = sess
            val share = try {
                sess.connectShare(shareName)
            } catch (e: SMBApiException) {
                throw SmbErrors.map(e, "\"$shareName\" on $hostDesc", hostDesc)
            }
            if (share !is DiskShare) {
                runCatching { share.close() }
                throw IOException("\"$shareName\" on $hostDesc is not a file share")
            }
            diskShare = share
            share
        } catch (e: Exception) {
            closeQuietlyLocked()
            throw e
        }
    }

    /** Drops [failed] (only if it is still the current share) so the next share() reconnects. */
    private fun reset(failed: DiskShare?) = synchronized(lock) {
        if (failed == null || diskShare === failed) closeQuietlyLocked()
    }

    private fun closeQuietlyLocked() {
        runCatching { diskShare?.close() }
        runCatching { session?.close() }
        runCatching { connection?.close(true) }
        diskShare = null
        session = null
        connection = null
    }

    /**
     * Runs [block] against the share. If it fails because an *existing* connection died, reconnects once and
     * retries. All failures are mapped to RemoteAuthException / IOException.
     */
    private fun <T> op(what: String, block: (DiskShare) -> T): T {
        try {
            val s = share()
            return try {
                block(s)
            } catch (e: Exception) {
                if (!closed && SmbErrors.isBrokenConnection(e)) {
                    reset(s)
                    block(share())
                } else throw e
            }
        } catch (e: Exception) {
            throw SmbErrors.map(e, what, hostDesc)
        }
    }

    override fun close() {
        synchronized(lock) {
            closed = true
            closeQuietlyLocked()
            runCatching { client?.close() }
            client = null
        }
    }

    // ---- RemoteStorage --------------------------------------------------------------------------

    override fun testConnection() {
        op("share \"${config.share}\" on $hostDesc") { s ->
            s.list("") // forces a real round trip with the share's permissions
            Unit
        }
    }

    override fun list(dirPath: String): List<RemoteEntry> {
        val dir = SmbPaths.normalize(dirPath)
        return op(dir) { s ->
            s.list(SmbPaths.toSmb(dir))
                .asSequence()
                .filter { it.fileName != "." && it.fileName != ".." }
                .filterNot { SmbPaths.isTempName(it.fileName) }
                .map { info ->
                    val isDir = (info.fileAttributes and DIR_ATTR) != 0L
                    RemoteEntry(
                        path = SmbPaths.child(dir, info.fileName),
                        name = info.fileName,
                        isDirectory = isDir,
                        size = if (isDir) -1 else info.endOfFile,
                        modifiedMillis = info.lastWriteTime?.toEpochMillis() ?: 0L,
                    )
                }
                .sortedWith(compareBy<RemoteEntry>({ !it.isDirectory }, { it.name.lowercase() }))
                .toList()
        }
    }

    override fun stat(path: String): RemoteEntry? {
        val p = SmbPaths.normalize(path)
        return op(p) { s ->
            try {
                val info = s.getFileInformation(SmbPaths.toSmb(p))
                val isDir = info.standardInformation.isDirectory
                RemoteEntry(
                    path = p,
                    name = SmbPaths.name(p),
                    isDirectory = isDir,
                    size = if (isDir) -1 else info.standardInformation.endOfFile,
                    modifiedMillis = info.basicInformation.lastWriteTime?.toEpochMillis() ?: 0L,
                )
            } catch (e: SMBApiException) {
                if (SmbErrors.isNotFound(e)) null else throw e
            }
        }
    }

    override fun openRead(path: String): InputStream = openRange(path, 0, -1)

    override fun openRange(path: String, offset: Long, length: Long): InputStream {
        require(offset >= 0) { "offset must be >= 0" }
        val p = SmbPaths.normalize(path)
        val file = op(p) { s -> openForRead(s, SmbPaths.toSmb(p)) }
        return SmbRangeInputStream(
            reader = { buf, fileOffset, off, len ->
                try {
                    file.read(buf, fileOffset, off, len)
                } catch (e: Exception) {
                    throw SmbErrors.map(e, p, hostDesc)
                }
            },
            offset = offset,
            length = length,
            onClose = { runCatching { file.close() } },
        )
    }

    override fun upload(path: String, source: File) {
        val p = SmbPaths.normalize(path)
        require(p != "/") { "Cannot upload to the share root" }
        if (!source.isFile) throw IOException("Local file not found: ${source.path}")
        val target = SmbPaths.toSmb(p)
        val temp = SmbPaths.toSmb(SmbPaths.tempPathFor(p))
        op(p) { s ->
            try {
                uploadViaTemp(s, source, temp, target)
            } catch (e: SMBApiException) {
                // Temp+rename not possible here (no create/rename rights in the folder, server refuses
                // replace-on-rename, ...): fall back to overwriting the target in place.
                runCatching { s.rm(temp) }
                writeDirect(s, source, target)
            }
        }
    }

    override fun rename(path: String, newName: String): String {
        SmbPaths.validateName(newName)
        val p = SmbPaths.normalize(path)
        require(p != "/") { "Cannot rename the share root" }
        val newPath = SmbPaths.child(SmbPaths.parent(p), newName)
        if (newPath == p) return p
        op(p) { s ->
            val entry = s.open(
                SmbPaths.toSmb(p),
                EnumSet.of(AccessMask.DELETE, AccessMask.FILE_READ_ATTRIBUTES),
                null,
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                null,
            )
            entry.use { it.rename(SmbPaths.toSmb(newPath), false) }
        }
        return newPath
    }

    /** Deletes a file, or an empty folder (non-recursive on purpose). */
    override fun delete(path: String) {
        val p = SmbPaths.normalize(path)
        require(p != "/") { "Cannot delete the share root" }
        op(p) { s ->
            val smb = SmbPaths.toSmb(p)
            val isDir = s.getFileInformation(smb).standardInformation.isDirectory
            if (isDir) s.rmdir(smb, false) else s.rm(smb)
        }
    }

    // ---- helpers ------------------------------------------------------------------------------

    private fun openForRead(s: DiskShare, smbPath: String): SmbFile = s.openFile(
        smbPath,
        EnumSet.of(AccessMask.GENERIC_READ),
        null,
        SMB2ShareAccess.ALL,
        SMB2CreateDisposition.FILE_OPEN,
        EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
    )

    private fun uploadViaTemp(s: DiskShare, source: File, temp: String, target: String) {
        val f = s.openFile(
            temp,
            EnumSet.of(AccessMask.GENERIC_WRITE, AccessMask.DELETE, AccessMask.FILE_READ_ATTRIBUTES),
            EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
            EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
            SMB2CreateDisposition.FILE_OVERWRITE_IF,
            EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
        )
        var renamed = false
        try {
            writeAll(f, source)
            f.flush()
            f.rename(target, true) // atomic replace of the real file
            renamed = true
        } finally {
            if (!renamed) runCatching { f.deleteOnClose() }
            runCatching { f.close() }
        }
    }

    private fun writeDirect(s: DiskShare, source: File, target: String) {
        val f = s.openFile(
            target,
            EnumSet.of(AccessMask.GENERIC_WRITE),
            EnumSet.of(FileAttributes.FILE_ATTRIBUTE_NORMAL),
            EnumSet.of(SMB2ShareAccess.FILE_SHARE_READ),
            SMB2CreateDisposition.FILE_OVERWRITE_IF,
            EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
        )
        f.use {
            writeAll(it, source)
            it.flush()
        }
    }

    private fun writeAll(f: SmbFile, source: File) {
        val buf = ByteArray(WRITE_CHUNK)
        var pos = 0L
        FileInputStream(source).use { input ->
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                var written = 0
                while (written < n) {
                    val w = f.write(buf, pos + written, written, n - written).toInt()
                    if (w <= 0) throw IOException("SMB write returned $w")
                    written += w
                }
                pos += n
            }
        }
    }

    companion object {
        private const val DIR_ATTR = 0x10L // FILE_ATTRIBUTE_DIRECTORY
        private const val WRITE_CHUNK = 256 * 1024
        private const val TIMEOUT_SECONDS = 30L

        /**
         * smbj config tuned for Android: BouncyCastle lightweight crypto (Android's JCE lacks MD4 needed by
         * NTLM), NTLM only (Kerberos/GSS classes don't exist on Android), sane timeouts.
         */
        internal fun buildSmbConfig(): SmbConfig = SmbConfig.builder()
            .withSecurityProvider(BCSecurityProvider())
            .withAuthenticators(NtlmAuthenticator.Factory())
            .withTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withSoTimeout(TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .withDfsEnabled(false)
            .build()

        /**
         * Logs in. Blank username: guest first, then anonymous (servers differ in which they allow).
         * Auth failures become RemoteAuthException.
         */
        internal fun authenticate(conn: Connection, username: String, password: String, domain: String): Session {
            val user = username.trim()
            val hostDesc = conn.remoteHostname ?: "server"
            if (user.isNotEmpty()) {
                // Accept "DOMAIN\\user" and "user@domain" in the username field too.
                val (u, d) = splitUser(user, domain.trim())
                return try {
                    conn.authenticate(AuthenticationContext(u, password.toCharArray(), d.ifEmpty { null }))
                } catch (e: Exception) {
                    throw authError(e, hostDesc)
                }
            }
            val guestError = try {
                return conn.authenticate(AuthenticationContext.guest())
            } catch (e: Exception) {
                e
            }
            return try {
                conn.authenticate(AuthenticationContext.anonymous())
            } catch (e: Exception) {
                val mapped = authError(e, hostDesc)
                if (mapped is RemoteAuthException) {
                    throw RemoteAuthException(
                        "SMB server $hostDesc does not allow guest/anonymous access; enter a username and password",
                        guestError,
                    )
                }
                throw mapped
            }
        }

        private fun authError(e: Exception, hostDesc: String): Exception {
            val mapped = SmbErrors.map(e, "login to $hostDesc", hostDesc)
            if (mapped is RemoteAuthException) return mapped
            // smbj reports some NTLM/SPNEGO failures as plain SMBRuntimeException without an NT status.
            val msg = e.message.orEmpty()
            if (msg.contains("authenticat", ignoreCase = true) || msg.contains("logon", ignoreCase = true)) {
                return RemoteAuthException("SMB login to $hostDesc failed: $msg", e)
            }
            return mapped
        }

        /** "DOM\\user" -> (user, DOM); "user@dom" -> (user, dom) when [domain] is blank; else (user, domain). */
        internal fun splitUser(user: String, domain: String): Pair<String, String> {
            val bs = user.indexOf('\\')
            if (bs > 0 && domain.isEmpty()) return user.substring(bs + 1) to user.substring(0, bs)
            val at = user.lastIndexOf('@')
            if (at > 0 && domain.isEmpty()) return user.substring(0, at) to user.substring(at + 1)
            return user to domain
        }
    }
}
