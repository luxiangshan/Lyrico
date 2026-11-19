package com.lonx.lyrico.remote.smb

import com.hierynomus.mserref.NtStatus
import com.hierynomus.mssmb2.SMB2MessageCommandCode
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.protocol.transport.TransportException
import com.lonx.lyrico.remote.RemoteAuthException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.FileNotFoundException
import java.io.IOException
import java.net.ConnectException

class SmbErrorsTest {
    private fun api(s: NtStatus) = SMBApiException(s.value, SMB2MessageCommandCode.SMB2_CREATE, null)

    @Test fun logonFailureIsAuth() {
        val e = SmbErrors.map(api(NtStatus.STATUS_LOGON_FAILURE), "login")
        assertTrue(e is RemoteAuthException)
        assertEquals("SMB login failed: wrong username or password", e.message)
    }

    @Test fun accessDeniedIsAuth() {
        val e = SmbErrors.map(api(NtStatus.STATUS_ACCESS_DENIED), "/Music")
        assertTrue(e is RemoteAuthException)
        assertTrue(e.message!!.contains("Access denied"))
    }

    @Test fun notFound() {
        assertTrue(SmbErrors.map(api(NtStatus.STATUS_OBJECT_NAME_NOT_FOUND), "/x") is FileNotFoundException)
        assertTrue(SmbErrors.isNotFound(api(NtStatus.STATUS_OBJECT_PATH_NOT_FOUND)))
    }

    @Test fun badShareIsIo() {
        val e = SmbErrors.map(api(NtStatus.STATUS_BAD_NETWORK_NAME), "\"music\"")
        assertTrue(e is IOException && e !is FileNotFoundException)
        assertEquals("SMB share not found: \"music\"", e.message)
    }

    @Test fun connectRefusedReadable() {
        val e = SmbErrors.map(TransportException(ConnectException("refused")), "x", "nas:445")
        assertTrue(e.message!!.startsWith("Cannot connect to SMB server nas:445"))
    }

    @Test fun brokenDetection() {
        assertTrue(SmbErrors.isBrokenConnection(TransportException("gone")))
        assertTrue(SmbErrors.isBrokenConnection(RuntimeException(TransportException("gone"))))
        assertTrue(SmbErrors.isBrokenConnection(api(NtStatus.STATUS_NETWORK_SESSION_EXPIRED)))
        assertFalse(SmbErrors.isBrokenConnection(api(NtStatus.STATUS_ACCESS_DENIED)))
        assertFalse(SmbErrors.isBrokenConnection(IllegalStateException("x")))
    }
}
