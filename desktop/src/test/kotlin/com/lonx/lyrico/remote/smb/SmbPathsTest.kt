package com.lonx.lyrico.remote.smb

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SmbPathsTest {
    @Test fun toSmbConvertsSeparators() {
        assertEquals("", SmbPaths.toSmb("/"))
        assertEquals("", SmbPaths.toSmb(""))
        assertEquals("Music", SmbPaths.toSmb("/Music"))
        assertEquals("Music\\Album\\01 a.flac", SmbPaths.toSmb("/Music/Album/01 a.flac"))
        assertEquals("Music\\Album", SmbPaths.toSmb("//Music//Album/"))
        assertEquals("a\\b", SmbPaths.toSmb("a/./b"))
    }

    @Test fun fromSmbConvertsBack() {
        assertEquals("/", SmbPaths.fromSmb(""))
        assertEquals("/Music/x.mp3", SmbPaths.fromSmb("Music\\x.mp3"))
        assertEquals("/Music/x.mp3", SmbPaths.fromSmb("\\Music\\x.mp3"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsDotDot() { SmbPaths.toSmb("/Music/../secret") }

    @Test fun childParentName() {
        assertEquals("/a", SmbPaths.child("/", "a"))
        assertEquals("/x/a", SmbPaths.child("/x/", "a"))
        assertEquals("/", SmbPaths.parent("/a"))
        assertEquals("/", SmbPaths.parent("/"))
        assertEquals("/x/y", SmbPaths.parent("/x/y/z.flac"))
        assertEquals("z.flac", SmbPaths.name("/x/y/z.flac"))
        assertEquals("", SmbPaths.name("/"))
    }

    @Test fun tempPath() {
        assertEquals("/x/.song.flac.lyrico-tmp", SmbPaths.tempPathFor("/x/song.flac"))
        assertEquals("x\\.song.flac.lyrico-tmp", SmbPaths.toSmb(SmbPaths.tempPathFor("/x/song.flac")))
        assertEquals("/.a.mp3.lyrico-tmp", SmbPaths.tempPathFor("/a.mp3"))
        assertTrue(SmbPaths.isTempName(".a.mp3.lyrico-tmp"))
        assertFalse(SmbPaths.isTempName("a.mp3"))
    }

    @Test fun parseHost() {
        assertEquals(SmbPaths.HostPort("nas", 445), SmbPaths.parseHost("nas"))
        assertEquals(SmbPaths.HostPort("192.168.1.2", 4445), SmbPaths.parseHost(" 192.168.1.2:4445 "))
        assertEquals(SmbPaths.HostPort("nas.local", 445), SmbPaths.parseHost("smb://nas.local/share/dir"))
        assertEquals(SmbPaths.HostPort("nas", 445), SmbPaths.parseHost("\\\\nas\\music"))
        assertEquals(SmbPaths.HostPort("fe80::1", 445), SmbPaths.parseHost("fe80::1"))
        assertEquals(SmbPaths.HostPort("fe80::1", 1445), SmbPaths.parseHost("[fe80::1]:1445"))
        assertEquals(SmbPaths.HostPort("nas", 445), SmbPaths.parseHost("nas:"))
    }

    @Test(expected = IllegalArgumentException::class)
    fun badPort() { SmbPaths.parseHost("nas:99999") }

    @Test(expected = IllegalArgumentException::class)
    fun emptyHost() { SmbPaths.parseHost("  ") }

    @Test fun validateName() {
        SmbPaths.validateName("01 - Song (Live).flac")
        SmbPaths.validateName("歌曲.mp3")
        for (bad in listOf("", " ", "a/b", "a\\b", "a:b", "a?", "..", "x.")) {
            try {
                SmbPaths.validateName(bad); throw AssertionError("accepted '$bad'")
            } catch (_: IllegalArgumentException) {}
        }
    }

    @Test fun splitUser() {
        assertEquals("bob" to "WORK", SmbStorage.splitUser("WORK\\bob", ""))
        assertEquals("bob" to "corp.local", SmbStorage.splitUser("bob@corp.local", ""))
        assertEquals("bob" to "D", SmbStorage.splitUser("bob", "D"))
        assertEquals("WORK\\bob" to "D", SmbStorage.splitUser("WORK\\bob", "D"))
    }
}
