package com.lonx.lyrico.remote.smb

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Runs against a real SMB server only when SMB_TEST_HOST is set (skipped in normal unit test runs):
 * SMB_TEST_HOST=host[:port] SMB_TEST_SHARE=share SMB_TEST_USER=u SMB_TEST_PASS=p [SMB_TEST_GUEST_SHARE=share]
 */
class SmbStorageIntegrationTest {
    private val host = System.getenv("SMB_TEST_HOST").orEmpty()
    private fun cfg(user: String = env("SMB_TEST_USER"), pass: String = env("SMB_TEST_PASS"), share: String = env("SMB_TEST_SHARE")) =
        RemoteConfig(id = "t", type = RemoteType.SMB, displayName = "t", baseUrl = host, share = share, username = user, secret = pass)
    private fun env(k: String) = System.getenv(k).orEmpty()

    @Test fun roundTrip() {
        assumeTrue(host.isNotEmpty())
        SmbStorage(cfg()).use { s ->
            s.testConnection()
            val dir = "/it-${System.nanoTime()}"
            s.upload("$dir-x.bin", tmp(byteArrayOf(1))) // file at root
            s.delete("$dir-x.bin")

            val data = ByteArray(300_000) { (it * 31).toByte() }
            val path = "/song ${System.nanoTime()}.flac"
            s.upload(path, tmp(data))
            assertEquals(data.size.toLong(), s.stat(path)!!.size)
            assertArrayEquals(data, s.openRead(path).use { it.readBytes() })
            assertArrayEquals(data.copyOfRange(1000, 1100), s.openRange(path, 1000, 100).use { it.readBytes() })
            assertArrayEquals(data.copyOfRange(299_990, 300_000), s.openRange(path, 299_990, -1).use { it.readBytes() })

            // overwrite via temp+rename
            val data2 = ByteArray(1234) { 7 }
            s.upload(path, tmp(data2))
            assertArrayEquals(data2, s.openRead(path).use { it.readBytes() })
            val names = s.list("/").map { it.name }
            assertTrue(path.removePrefix("/") in names)
            assertFalse(names.any { it.endsWith(".lyrico-tmp") })
            assertTrue(s.stat("/")!!.isDirectory)

            val renamed = s.rename(path, "renamed ${System.nanoTime()}.flac")
            assertNull(s.stat(path))
            assertNotNull(s.stat(renamed))
            s.delete(renamed)
            assertNull(s.stat(renamed))
        }
    }

    @Test fun badPasswordIsAuth() {
        assumeTrue(host.isNotEmpty())
        SmbStorage(cfg(pass = "definitely-wrong")).use { s ->
            try { s.testConnection(); throw AssertionError("no error") } catch (e: RemoteAuthException) {
                assertTrue(e.message!!, e.message!!.contains("SMB login failed") || e.message!!.contains("guest"))
            }
        }
    }

    @Test fun guestAccess() {
        val share = env("SMB_TEST_GUEST_SHARE")
        assumeTrue(host.isNotEmpty() && share.isNotEmpty())
        SmbStorage(cfg(user = "", pass = "", share = share)).use { it.testConnection(); it.list("/") }
    }

    @Test fun listShares() {
        assumeTrue(host.isNotEmpty())
        val shares = SmbStorage.listShares(host, env("SMB_TEST_USER"), env("SMB_TEST_PASS"))
        assertTrue(shares.toString(), shares.any { it.name.equals(env("SMB_TEST_SHARE"), true) })
    }

    @Test fun reconnectsAfterDrop() {
        assumeTrue(host.isNotEmpty())
        SmbStorage(cfg()).use { s ->
            s.list("/")
            // Simulate a dead connection by closing the underlying smbj connection behind the storage's back.
            val f = SmbStorage::class.java.getDeclaredField("connection").apply { isAccessible = true }
            (f.get(s) as com.hierynomus.smbj.connection.Connection).close(true)
            s.list("/") // must transparently reconnect
        }
    }

    private fun tmp(b: ByteArray) = java.io.File.createTempFile("smbit", ".bin").apply { writeBytes(b); deleteOnExit() }
}
