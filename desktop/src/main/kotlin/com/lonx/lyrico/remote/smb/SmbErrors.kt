package com.lonx.lyrico.remote.smb

import com.hierynomus.mserref.NtStatus
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.protocol.transport.TransportException
import com.hierynomus.smbj.common.SMBRuntimeException
import com.lonx.lyrico.remote.RemoteAuthException
import java.io.FileNotFoundException
import java.io.IOException
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Maps smbj failures to RemoteAuthException / IOException with readable messages. */
internal object SmbErrors {

    private val AUTH_STATUSES = setOf(
        NtStatus.STATUS_LOGON_FAILURE,
        NtStatus.STATUS_ACCESS_DENIED,
        NtStatus.STATUS_ACCOUNT_DISABLED,
        NtStatus.STATUS_PASSWORD_EXPIRED,
        NtStatus.STATUS_LOGON_TYPE_NOT_GRANTED,
    )

    /** Statuses meaning the connection/session/tree is gone and a reconnect may help. */
    private val BROKEN_STATUSES = setOf(
        NtStatus.STATUS_NETWORK_NAME_DELETED,
        NtStatus.STATUS_USER_SESSION_DELETED,
        NtStatus.STATUS_NETWORK_SESSION_EXPIRED,
        NtStatus.STATUS_CONNECTION_DISCONNECTED,
        NtStatus.STATUS_CONNECTION_RESET,
    )

    private val NOT_FOUND_STATUSES = setOf(
        NtStatus.STATUS_OBJECT_NAME_NOT_FOUND,
        NtStatus.STATUS_OBJECT_PATH_NOT_FOUND,
        NtStatus.STATUS_NO_SUCH_FILE,
        NtStatus.STATUS_BAD_NETWORK_PATH,
    )

    fun isNotFound(e: Throwable): Boolean = e is SMBApiException && e.status in NOT_FOUND_STATUSES

    fun isAuth(e: Throwable): Boolean = e is SMBApiException && e.status in AUTH_STATUSES

    /** True when the failure looks like a dead transport/session that one reconnect could fix. */
    fun isBrokenConnection(e: Throwable): Boolean {
        var t: Throwable? = e
        var depth = 0
        while (t != null && depth < 8) {
            if (t is SMBApiException) return t.status in BROKEN_STATUSES
            if (t is TransportException) return true
            if (t is java.net.SocketException) return true
            if (t is java.io.EOFException) return true
            t = t.cause
            depth++
        }
        return false
    }

    /** Readable text for an NT status, used in messages. */
    fun describe(status: NtStatus?, what: String): String = when (status) {
        NtStatus.STATUS_LOGON_FAILURE -> "SMB login failed: wrong username or password"
        NtStatus.STATUS_ACCESS_DENIED -> "Access denied on the SMB server for $what (check the account's share/file permissions)"
        NtStatus.STATUS_ACCOUNT_DISABLED -> "SMB account is disabled"
        NtStatus.STATUS_PASSWORD_EXPIRED -> "SMB account password has expired"
        NtStatus.STATUS_LOGON_TYPE_NOT_GRANTED -> "This SMB account is not allowed to log on over the network"
        NtStatus.STATUS_BAD_NETWORK_NAME -> "SMB share not found: $what"
        NtStatus.STATUS_OBJECT_NAME_NOT_FOUND, NtStatus.STATUS_NO_SUCH_FILE -> "Not found on SMB share: $what"
        NtStatus.STATUS_OBJECT_PATH_NOT_FOUND, NtStatus.STATUS_BAD_NETWORK_PATH -> "Folder not found on SMB share: $what"
        NtStatus.STATUS_OBJECT_NAME_COLLISION -> "A file with that name already exists: $what"
        NtStatus.STATUS_OBJECT_NAME_INVALID -> "Invalid file name: $what"
        NtStatus.STATUS_SHARING_VIOLATION -> "File is in use by another program: $what"
        NtStatus.STATUS_DIRECTORY_NOT_EMPTY -> "Folder is not empty: $what"
        NtStatus.STATUS_FILE_IS_A_DIRECTORY -> "Expected a file but found a folder: $what"
        NtStatus.STATUS_NOT_A_DIRECTORY -> "Expected a folder but found a file: $what"
        NtStatus.STATUS_DISK_FULL -> "SMB server disk is full"
        NtStatus.STATUS_NOT_SUPPORTED -> "Operation not supported by this SMB server ($what)"
        null -> "SMB error for $what"
        else -> "SMB error ${status.name} for $what"
    }

    /** Converts any failure to the exception the RemoteStorage contract promises. */
    fun map(e: Throwable, what: String, hostDesc: String = ""): Exception {
        if (e is RemoteAuthException) return e
        if (e is SMBApiException) {
            val msg = describe(e.status, what)
            return when (e.status) {
                in AUTH_STATUSES -> RemoteAuthException(msg, e)
                in NOT_FOUND_STATUSES -> FileNotFoundException(msg).apply { initCause(e) }
                else -> IOException(msg, e)
            }
        }
        val root = rootCause(e)
        val target = hostDesc.ifEmpty { what }
        return when (root) {
            is UnknownHostException -> IOException("Unknown SMB host: $target", e)
            is ConnectException -> IOException("Cannot connect to SMB server $target (is it running and is port open?)", e)
            is NoRouteToHostException -> IOException("No route to SMB server $target", e)
            is SocketTimeoutException -> IOException("SMB server $target timed out", e)
            else -> when (e) {
                is IOException -> e
                is SMBRuntimeException -> IOException("SMB error for $what: ${e.message ?: e.javaClass.simpleName}", e)
                else -> IOException("SMB error for $what: ${e.message ?: e.javaClass.simpleName}", e)
            }
        }
    }

    private fun rootCause(e: Throwable): Throwable {
        var t = e
        var depth = 0
        while (t.cause != null && t.cause !== t && depth < 10) {
            t = t.cause!!
            depth++
        }
        return t
    }
}
