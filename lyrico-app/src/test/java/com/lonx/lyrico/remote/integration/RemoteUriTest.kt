package com.lonx.lyrico.remote.integration

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteUriTest {

    @Test
    fun buildAndParseRoundTrip() {
        val path = "/My Music/周杰伦 #1/a+b?.flac"
        val uri = RemoteUri.build("abc123", path)
        assertTrue(uri.startsWith("remote://abc123/My%20Music/"))
        assertFalse(uri.contains('#'))
        assertFalse(uri.contains('?'))
        val parsed = RemoteUri.parse(uri)!!
        assertEquals("abc123", parsed.configId)
        assertEquals(path, parsed.path)
    }

    @Test
    fun displayPaths() {
        assertEquals("remote://cfg", RemoteUri.displayPath("cfg", "/"))
        assertEquals("remote://cfg/A/B", RemoteUri.displayPath("cfg", "A/B/"))
        assertEquals(RemoteUri.Parsed("cfg", "/"), RemoteUri.parseDisplayPath("remote://cfg"))
        assertEquals(RemoteUri.Parsed("cfg", "/50%20off"), RemoteUri.parseDisplayPath("remote://cfg/50%20off"))
        assertNull(RemoteUri.parse("content://media/external/audio/media/1"))
    }

    @Test
    fun pathHelpers() {
        assertEquals("/", RemoteUri.parentPath("/a"))
        assertEquals("/a", RemoteUri.parentPath("/a/b"))
        assertEquals("/x", RemoteUri.childPath("/", "x"))
        assertEquals("/a/x", RemoteUri.childPath("/a/", "x"))
        assertTrue(RemoteUri.isSupportedAudio("song.FLAC"))
        assertFalse(RemoteUri.isSupportedAudio("cover.jpg"))
    }

    @Test
    fun topLevelFoldersDropsNested() {
        assertEquals(listOf("/Music", "/Other"), RemoteLibraryScanner.topLevelFolders(listOf("/Music", "/Music/Rock", "/Other/")))
        assertEquals(listOf("/"), RemoteLibraryScanner.topLevelFolders(listOf("/", "/Music")))
    }
}
