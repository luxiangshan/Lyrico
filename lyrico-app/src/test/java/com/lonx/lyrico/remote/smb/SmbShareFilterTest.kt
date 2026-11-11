package com.lonx.lyrico.remote.smb

import org.junit.Assert.assertEquals
import org.junit.Test

class SmbShareFilterTest {
    @Test fun keepsOnlyPlainDiskShares() {
        val rows = listOf(
            Triple<String?, Int, String?>("music", 0, "Music"),
            Triple("IPC$", 0x80000003.toInt(), "IPC"),
            Triple("ADMIN$", 0x80000000.toInt(), null),
            Triple("C$", 0, null),
            Triple("printer", 1, null),
            Triple("Backup", 0, null),
            Triple(null, 0, null),
        )
        assertEquals(
            listOf(SmbShareInfo("Backup", ""), SmbShareInfo("music", "Music")),
            SmbShareFilter.diskShares(rows),
        )
    }
}
