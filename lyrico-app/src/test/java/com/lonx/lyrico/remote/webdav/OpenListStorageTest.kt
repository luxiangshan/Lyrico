package com.lonx.lyrico.remote.webdav

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteCredentialStore
import com.lonx.lyrico.remote.RemoteType
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.util.concurrent.TimeUnit

class OpenListStorageTest {

    private lateinit var server: MockWebServer
    private val store = object : RemoteCredentialStore {
        val map = HashMap<String, String?>()
        override fun loadExtra(configId: String, key: String) = map["$configId/$key"]
        override fun saveExtra(configId: String, key: String, value: String?) { map["$configId/$key"] = value }
    }

    @Before fun setUp() { server = MockWebServer(); server.start() }
    @After fun tearDown() { server.close() }

    private fun storage(user: String = "admin", pass: String = "pw") = OpenListStorage(
        RemoteConfig(id = "o", type = RemoteType.OPENLIST, displayName = "o",
            baseUrl = server.url("/").toString(), username = user, secret = pass),
        store,
    )

    private fun ok(data: String = "null") = json("""{"code":200,"message":"success","data":$data}""")
    private fun json(body: String) = MockResponse.Builder().code(200).setHeader("Content-Type", "application/json").body(body).build()
    private fun loginOk(token: String) = ok("""{"token":"$token"}""")
    private fun take(): RecordedRequest = server.takeRequest(5, TimeUnit.SECONDS)!!
    private fun bodyJson(r: RecordedRequest) = JSONObject(r.body!!.utf8())

    private fun item(name: String, dir: Boolean = false, size: Long = 10) =
        """{"name":"$name","size":$size,"is_dir":$dir,"modified":"2024-05-01T12:00:00.5+08:00","sign":"","thumb":"","type":0}"""

    @Test fun loginCachesTokenAndSendsIt() {
        server.enqueue(loginOk("T1"))
        server.enqueue(ok("""{"content":[${item("a.mp3")}],"total":1}"""))
        val list = storage().list("/Music")
        assertEquals("/Music/a.mp3", list.single().path)
        assertEquals(1714536000500L, list.single().modifiedMillis)
        val login = take()
        assertEquals("/api/auth/login", login.url.encodedPath)
        assertEquals("admin", bodyJson(login).getString("username"))
        val l = take()
        assertEquals("T1", l.headers["Authorization"])
        val b = bodyJson(l)
        assertEquals("/Music", b.getString("path"))
        assertEquals(false, b.getBoolean("refresh"))
        assertEquals(1, b.getInt("page"))
        assertEquals("T1", store.map["o/${OpenListStorage.TOKEN_KEY}"])
    }

    @Test fun expiredCachedTokenReloginsOnce() {
        store.map["o/${OpenListStorage.TOKEN_KEY}"] = "OLD"
        server.enqueue(json("""{"code":401,"message":"token is expired","data":null}"""))
        server.enqueue(loginOk("NEW"))
        server.enqueue(ok("""{"content":[],"total":0}"""))
        storage().list("/")
        assertEquals("OLD", take().headers["Authorization"])
        assertEquals("/api/auth/login", take().url.encodedPath)
        assertEquals("NEW", take().headers["Authorization"])
        assertEquals("NEW", store.map["o/${OpenListStorage.TOKEN_KEY}"])
    }

    @Test fun http401AlsoTriggersRelogin() {
        store.map["o/${OpenListStorage.TOKEN_KEY}"] = "OLD"
        server.enqueue(MockResponse.Builder().code(401).body("unauthorized").build())
        server.enqueue(loginOk("NEW"))
        server.enqueue(ok("""{"content":null,"total":0}"""))
        assertTrue(storage().list("/").isEmpty())
        assertEquals(3, server.requestCount)
    }

    @Test fun listPaginates() {
        server.enqueue(loginOk("T"))
        val page1 = (1..OpenListStorage.PAGE_SIZE).joinToString(",") { item("f$it.mp3") }
        server.enqueue(ok("""{"content":[$page1],"total":${OpenListStorage.PAGE_SIZE + 2}}"""))
        server.enqueue(ok("""{"content":[${item("x.mp3")},${item("sub", dir = true)}],"total":${OpenListStorage.PAGE_SIZE + 2}}"""))
        val list = storage().list("/")
        assertEquals(OpenListStorage.PAGE_SIZE + 2, list.size)
        assertTrue(list.last().isDirectory)
        assertEquals(-1L, list.last().size)
        take()
        assertEquals(1, bodyJson(take()).getInt("page"))
        assertEquals(2, bodyJson(take()).getInt("page"))
    }

    @Test fun guestSendsNoAuthAndNoLogin() {
        server.enqueue(ok("""{"content":[${item("a.mp3")}],"total":1}"""))
        storage(user = "", pass = "").list("/")
        val r = take()
        assertEquals("/api/fs/list", r.url.encodedPath)
        assertNull(r.headers["Authorization"])
    }

    @Test fun guestDeniedIsAuthException() {
        server.enqueue(json("""{"code":403,"message":"permission denied","data":null}"""))
        try { storage(user = "", pass = "").list("/"); fail() } catch (e: RemoteAuthException) {
            assertTrue(e.message!!.contains("guest"))
        }
    }

    @Test fun badPasswordIsAuthException() {
        server.enqueue(json("""{"code":400,"message":"password is incorrect","data":null}"""))
        try { storage().testConnection(); fail() } catch (e: RemoteAuthException) {
            assertTrue(e.message!!.contains("password is incorrect"))
        }
    }

    @Test fun uploadPutsWithHeaders() {
        server.enqueue(loginOk("T"))
        server.enqueue(ok())
        val f = File.createTempFile("upl", ".flac").apply { writeText("DATA!"); deleteOnExit() }
        storage().upload("/Music/周 杰.flac", f)
        take()
        val r = take()
        assertEquals("PUT", r.method)
        assertEquals("/api/fs/put", r.url.encodedPath)
        assertEquals("/Music/%E5%91%A8%20%E6%9D%B0.flac", r.headers["File-Path"])
        assertEquals("false", r.headers["As-Task"])
        assertEquals("true", r.headers["Overwrite"])
        assertEquals("5", r.headers["Content-Length"])
        assertEquals("T", r.headers["Authorization"])
        assertEquals("DATA!", r.body!!.utf8())
    }

    @Test fun uploadApiErrorSurfacesMessage() {
        server.enqueue(loginOk("T"))
        server.enqueue(json("""{"code":500,"message":"storage not found","data":null}"""))
        val f = File.createTempFile("upl", ".flac").apply { writeText("x"); deleteOnExit() }
        try { storage().upload("/a.flac", f); fail() } catch (e: java.io.IOException) {
            assertTrue(e.message!!.contains("storage not found"))
        }
    }

    @Test fun openRangeFollowsRawUrlRedirectWithRange() {
        server.enqueue(loginOk("T"))
        server.enqueue(ok("""{"name":"a.mp3","size":100,"is_dir":false,"modified":"2024-01-01T00:00:00Z","sign":"s1","raw_url":"${server.url("/p/a.mp3?sign=s1")}"}"""))
        server.enqueue(MockResponse.Builder().code(302).setHeader("Location", "/real/a.mp3").build())
        server.enqueue(MockResponse.Builder().code(206).body("0123").build())
        val data = storage().openRange("/a.mp3", 10, 4).use { it.readBytes() }
        assertEquals("0123", String(data))
        take()
        assertEquals("/api/fs/get", take().url.encodedPath)
        val raw = take()
        assertEquals("/p/a.mp3", raw.url.encodedPath)
        assertEquals("bytes=10-13", raw.headers["Range"])
        val real = take()
        assertEquals("/real/a.mp3", real.url.encodedPath)
        assertEquals("bytes=10-13", real.headers["Range"])
    }

    @Test fun openFallsBackToProxyDownload() {
        server.enqueue(loginOk("T"))
        server.enqueue(ok("""{"name":"a b.mp3","size":3,"is_dir":false,"sign":"sg","raw_url":""}"""))
        server.enqueue(MockResponse.Builder().code(200).body("abc").build())
        assertEquals("abc", String(storage().openRead("/x/a b.mp3").use { it.readBytes() }))
        take(); take()
        val d = take()
        assertEquals("/d/x/a%20b.mp3", d.url.encodedPath)
        assertEquals("sg", d.url.queryParameter("sign"))
    }

    @Test fun statNotFoundIsNull() {
        server.enqueue(loginOk("T"))
        server.enqueue(json("""{"code":500,"message":"failed get file: object not found","data":null}"""))
        assertNull(storage().stat("/nope"))
    }

    @Test fun renameAndDelete() {
        server.enqueue(loginOk("T"))
        server.enqueue(ok())
        server.enqueue(ok())
        val s = storage()
        assertEquals("/M/new.mp3", s.rename("/M/old.mp3", "new.mp3"))
        s.delete("/M/new.mp3")
        take()
        val rn = bodyJson(take())
        assertEquals("/M/old.mp3", rn.getString("path"))
        assertEquals("new.mp3", rn.getString("name"))
        val rm = take()
        assertEquals("/api/fs/remove", rm.url.encodedPath)
        val b = bodyJson(rm)
        assertEquals("/M", b.getString("dir"))
        assertEquals("new.mp3", b.getJSONArray("names").getString(0))
    }
}
