package com.lonx.lyrico.remote.webdav

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteType
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class WebDavStorageTest {

    private lateinit var server: MockWebServer

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.close() }

    private fun storage(basePath: String = "/dav", user: String = "", pass: String = "") = WebDavStorage(
        RemoteConfig(id = "w", type = RemoteType.WEBDAV, displayName = "w",
            baseUrl = server.url(basePath).toString(), username = user, secret = pass)
    )

    private fun ms(xml: String) = MockResponse.Builder().code(207)
        .setHeader("Content-Type", "application/xml; charset=utf-8").body(xml).build()

    private fun take(): RecordedRequest = server.takeRequest(5, TimeUnit.SECONDS)!!

    @Test fun listNextcloudStyle() {
        server.enqueue(ms("""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:s="http://sabredav.org/ns" xmlns:oc="http://owncloud.org/ns">
 <d:response><d:href>/remote.php/dav/files/alice/Music/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getlastmodified>Tue, 07 Nov 2023 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Music/My%20Song%20%2B%201.flac</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12345</d:getcontentlength><d:getlastmodified>Tue, 07 Nov 2023 10:00:00 GMT</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Music/%E5%91%A8%E6%9D%B0%E4%BC%A6/</d:href>
  <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
 <d:response><d:href>/remote.php/dav/files/alice/Music/a+b.mp3</d:href>
  <d:propstat><d:prop><d:resourcetype/><d:getcontentlength>7</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
</d:multistatus>"""))
        val list = storage("/remote.php/dav/files/alice").list("/Music")
        val req = take()
        assertEquals("PROPFIND", req.method)
        assertEquals("1", req.headers["Depth"])
        assertEquals("/remote.php/dav/files/alice/Music/", req.url.encodedPath)
        assertEquals(3, list.size)
        val song = list.first { !it.isDirectory && it.size == 12345L }
        assertEquals("/Music/My Song + 1.flac", song.path)
        assertEquals("My Song + 1.flac", song.name)
        assertEquals(1699351200000L, song.modifiedMillis)
        val dir = list.first { it.isDirectory }
        assertEquals("/Music/周杰伦", dir.path)
        assertEquals("/Music/a+b.mp3", list.first { it.size == 7L }.path)
    }

    @Test fun listApacheAbsoluteHrefsDefaultNamespace() {
        val host = "http://" + server.hostName + ":" + server.port
        server.enqueue(ms("""<?xml version="1.0" encoding="utf-8"?>
<multistatus xmlns="DAV:" xmlns:lp1="DAV:">
<response><href>$host/dav/</href><propstat><prop><lp1:resourcetype><lp1:collection/></lp1:resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response><href>$host/dav/x.mp3</href><propstat><prop><lp1:resourcetype/><lp1:getcontentlength>99</lp1:getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response>
<response><href>$host/dav/sub</href><propstat><prop><getcontenttype>httpd/unix-directory</getcontenttype><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response>
</multistatus>"""))
        val list = storage().list("/")
        assertEquals(listOf("/x.mp3", "/sub"), list.map { it.path })
        assertEquals(99L, list[0].size)
        assertTrue(list[1].isDirectory)
    }

    @Test fun listHrefsOutsideBaseFallBackToLastSegment() {
        // e.g. reverse proxy maps https://host/webdav -> backend /dav without rewriting hrefs
        server.enqueue(ms("""<D:multistatus xmlns:D="DAV:">
<D:response><D:href>/backend/Music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
<D:response><D:href>/backend/Music/b.ogg</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>5</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
</D:multistatus>"""))
        val list = storage("/webdav").list("/Music/")
        assertEquals(listOf("/Music/b.ogg"), list.map { it.path })
    }

    @Test fun statFoundAndMissing() {
        server.enqueue(ms("""<D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/a.mp3</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"""))
        server.enqueue(MockResponse.Builder().code(404).build())
        val s = storage()
        val e = s.stat("/a.mp3")!!
        assertEquals(42L, e.size)
        assertFalse(e.isDirectory)
        assertEquals("0", take().headers["Depth"])
        assertNull(s.stat("/nope.mp3"))
    }

    @Test fun openRangeSendsRangeHeader() {
        server.enqueue(MockResponse.Builder().code(206).body("cdef").build())
        val bytes = storage().openRange("/a b.mp3", 2, 4).use { it.readBytes() }
        assertEquals("cdef", String(bytes))
        val r = take()
        assertEquals("bytes=2-5", r.headers["Range"])
        assertEquals("/dav/a%20b.mp3", r.url.encodedPath)
    }

    @Test fun openRangeHandlesServerIgnoringRange() {
        server.enqueue(MockResponse.Builder().code(200).body("abcdefghij").build())
        val bytes = storage().openRange("/a.mp3", 3, 4).use { it.readBytes() }
        assertEquals("defg", String(bytes))
    }

    @Test fun uploadUsesTempThenMove() {
        server.enqueue(MockResponse.Builder().code(201).build())
        server.enqueue(MockResponse.Builder().code(204).build())
        val f = File.createTempFile("upl", ".mp3").apply { writeText("NEWDATA"); deleteOnExit() }
        storage().upload("/Music/song.mp3", f)
        val put = take()
        assertEquals("PUT", put.method)
        assertEquals("/dav/Music/.song.mp3.lyrico-tmp", put.url.encodedPath)
        assertEquals("NEWDATA", put.body!!.utf8())
        val move = take()
        assertEquals("MOVE", move.method)
        assertEquals("/dav/Music/.song.mp3.lyrico-tmp", move.url.encodedPath)
        assertEquals(server.url("/dav/Music/song.mp3").toString(), move.headers["Destination"])
        assertEquals("T", move.headers["Overwrite"])
    }

    @Test fun uploadFallsBackToDirectPutWhenMoveUnsupported() {
        server.enqueue(MockResponse.Builder().code(201).build())   // PUT tmp
        server.enqueue(MockResponse.Builder().code(405).build())   // MOVE
        server.enqueue(MockResponse.Builder().code(204).build())   // PUT target
        server.enqueue(MockResponse.Builder().code(204).build())   // DELETE tmp
        val f = File.createTempFile("upl", ".mp3").apply { writeText("X"); deleteOnExit() }
        storage().upload("/song.mp3", f)
        take(); take()
        val put = take()
        assertEquals("PUT", put.method)
        assertEquals("/dav/song.mp3", put.url.encodedPath)
        val del = take()
        assertEquals("DELETE", del.method)
        assertEquals("/dav/.song.mp3.lyrico-tmp", del.url.encodedPath)
    }

    @Test fun renameUsesMoveWithoutOverwrite() {
        server.enqueue(MockResponse.Builder().code(201).build())
        val np = storage().rename("/Music/old.mp3", "new name.mp3")
        assertEquals("/Music/new name.mp3", np)
        val r = take()
        assertEquals("MOVE", r.method)
        assertEquals("F", r.headers["Overwrite"])
        assertEquals(server.url("/dav/Music/new%20name.mp3").toString(), r.headers["Destination"])
    }

    @Test fun deleteSendsDelete() {
        server.enqueue(MockResponse.Builder().code(204).build())
        storage().delete("/x.mp3")
        assertEquals("DELETE", take().method)
    }

    @Test fun basicAuthChallengeThenPreemptive() {
        server.enqueue(MockResponse.Builder().code(401).setHeader("WWW-Authenticate", "Basic realm=\"dav\"").build())
        server.enqueue(MockResponse.Builder().code(204).build())
        server.enqueue(MockResponse.Builder().code(204).build())
        val s = storage(user = "bob", pass = "pw")
        s.delete("/a")
        s.delete("/b")
        assertNull(take().headers["Authorization"])
        val expected = "Basic " + java.util.Base64.getEncoder().encodeToString("bob:pw".toByteArray())
        assertEquals(expected, take().headers["Authorization"])
        assertEquals(expected, take().headers["Authorization"]) // preemptive, no extra 401 round trip
        assertEquals(3, server.requestCount)
    }

    @Test fun digestAuth() {
        server.enqueue(MockResponse.Builder().code(401)
            .setHeader("WWW-Authenticate", "Digest realm=\"me@x\", qop=\"auth\", nonce=\"abc123\", opaque=\"op\", algorithm=MD5").build())
        server.enqueue(MockResponse.Builder().code(204).build())
        storage(user = "bob", pass = "pw").delete("/a.mp3")
        take()
        val h = take().headers["Authorization"]!!
        assertTrue(h, h.startsWith("Digest "))
        fun p(k: String) = Regex("$k=\"?([^\",]*)\"?").find(h)!!.groupValues[1]
        assertEquals("/dav/a.mp3", p("uri"))
        assertEquals("op", p("opaque"))
        val ha1 = HttpAuth.h("MD5", "bob:me@x:pw")
        val ha2 = HttpAuth.h("MD5", "DELETE:/dav/a.mp3")
        val expected = HttpAuth.h("MD5", "$ha1:abc123:${p("nc")}:${p("cnonce")}:auth:$ha2")
        assertEquals(expected, p("response"))
    }

    @Test fun wrongPasswordGivesRemoteAuthException() {
        repeat(3) { server.enqueue(MockResponse.Builder().code(401).setHeader("WWW-Authenticate", "Basic realm=\"dav\"").build()) }
        try {
            storage(user = "bob", pass = "bad").testConnection()
            fail("expected RemoteAuthException")
        } catch (e: RemoteAuthException) {
            assertTrue(e.message!!.contains("401"))
        }
        assertEquals(2, server.requestCount) // one challenge + one rejected attempt, no loop
    }

    @Test fun pathHelpers() {
        assertEquals("/a/b", RemotePaths.normalize("a//b/./"))
        assertEquals("/", RemotePaths.parent("/a"))
        assertEquals("a+b c", RemotePaths.percentDecode("a+b%20c"))
        assertEquals("100%", RemotePaths.percentDecode("100%"))
        assertEquals("/a%20b/%E4%B8%AD", RemotePaths.encodePath("/a b/中"))
        assertEquals("/x/y", WebDavXml.hrefToPath("https://h:1/x/y/?q=1"))
    }
}
