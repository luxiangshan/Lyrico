package com.lonx.lyrico.remote.cloud115

import com.lonx.lyrico.remote.RemoteAuthException
import com.lonx.lyrico.remote.RemoteConfig
import com.lonx.lyrico.remote.RemoteType
import mockwebserver3.Dispatcher
import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import mockwebserver3.RecordedRequest
import okio.Buffer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.URLDecoder
import java.util.Base64
import java.util.Collections
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Cloud115Storage against a fake 115 (MockWebServer) modelled on the real response shapes. */
class Cloud115StorageTest {
    private data class FNode(
        val id: String, var parent: String, var name: String, val isDir: Boolean,
        var data: ByteArray = ByteArray(0), val pc: String = "pc$id",
    ) {
        val sha get() = if (isDir) "" else Cloud115Hash.hexUpper(java.security.MessageDigest.getInstance("SHA-1").digest(data))
    }

    private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    private val aesKey = hex(V.aesKey)
    private val aesIv = hex(V.aesIv)

    private lateinit var server: MockWebServer
    private lateinit var storage: Cloud115Storage
    private val nodes = Collections.synchronizedList(ArrayList<FNode>())
    private val log = Collections.synchronizedList(ArrayList<RecordedRequest>())
    @Volatile private var loggedOut = false
    @Volatile private var initCalls = 0
    @Volatile private var initMode = "sign_then_oss" // or "rapid"
    @Volatile private var pendingUploadName = ""
    @Volatile private var lastInitForm = mapOf<String, String>()
    private val cdnBytes = ByteArray(1000) { (it % 251).toByte() }

    private fun form(r: RecordedRequest): Map<String, String> =
        (r.body?.utf8() ?: "").split('&').filter { it.contains('=') }.associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }

    private fun json(o: Any) = MockResponse.Builder().body(o.toString()).addHeader("Content-Type", "application/json").build()

    private fun nodeJson(n: FNode) = JSONObject().apply {
        if (n.isDir) { put("cid", n.id); put("pid", n.parent); put("t", "1700000000") }
        else { put("fid", n.id); put("cid", n.parent); put("s", n.data.size); put("pc", n.pc); put("sha", n.sha); put("t", "2023-11-15 06:13") }
        put("n", n.name)
    }

    private fun encryptInit(o: JSONObject): Buffer {
        val js = o.toString().toByteArray()
        // literal-only LZ4 block
        val lz = java.io.ByteArrayOutputStream()
        val lit = js.size
        if (lit >= 15) { lz.write(0xF0); var r = lit - 15; while (r >= 255) { lz.write(255); r -= 255 }; lz.write(r) } else lz.write(lit shl 4)
        lz.write(js)
        val blk = lz.toByteArray()
        val framed = java.io.ByteArrayOutputStream().apply { write(blk.size and 0xff); write(blk.size ushr 8); write(blk) }.toByteArray()
        val padded = framed.copyOf((framed.size + 15) / 16 * 16)
        val c = Cipher.getInstance("AES/CBC/NoPadding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(aesKey, "AES"), IvParameterSpec(aesIv)) }
        return Buffer().write(c.doFinal(padded))
    }

    private fun decryptInit(body: ByteArray): Map<String, String> {
        val c = Cipher.getInstance("AES/CBC/PKCS5Padding").apply { init(Cipher.DECRYPT_MODE, SecretKeySpec(aesKey, "AES"), IvParameterSpec(aesIv)) }
        return String(c.doFinal(body)).split('&').associate {
            URLDecoder.decode(it.substringBefore('='), "UTF-8") to URLDecoder.decode(it.substringAfter('='), "UTF-8")
        }
    }

    private val dispatcher = object : Dispatcher() {
        override fun dispatch(request: RecordedRequest): MockResponse {
            log += request
            val path = request.url.encodedPath
            if (loggedOut && path != "/cdn") return json(JSONObject("""{"state":false,"errNo":990001,"error":"登录超时，请重新登录"}"""))
            return when {
                path == "/status" -> json(JSONObject().put("state", true))
                path == "/files" -> {
                    val cid = request.url.queryParameter("cid")!!
                    val offset = request.url.queryParameter("offset")!!.toInt()
                    val exists = cid == "0" || nodes.any { it.isDir && it.id == cid }
                    if (!exists) return json(JSONObject().put("state", true).put("cid", 0).put("count", 0).put("offset", 0).put("data", JSONArray()))
                    val kids = synchronized(nodes) { nodes.filter { it.parent == cid } }
                    if (cid == "200") { // simulate a big folder split across pages
                        val page = if (offset == 0) kids.take(2) else kids.drop(2)
                        return json(JSONObject().put("state", true).put("cid", cid).put("count", 1500).put("offset", offset)
                            .put("data", JSONArray(page.map { nodeJson(it) })))
                    }
                    json(JSONObject().put("state", true).put("cid", cid).put("count", kids.size).put("offset", offset)
                        .put("data", JSONArray(kids.map { nodeJson(it) })))
                }
                path == "/rename" -> {
                    val f = form(request)
                    val id = f["fid"]!!
                    nodes.first { it.id == id }.name = f["files_new_name[$id]"]!!
                    json(JSONObject().put("state", true))
                }
                path == "/delete" -> {
                    val f = form(request)
                    val ids = f.filterKeys { it.startsWith("fid[") }.values.toSet()
                    nodes.removeIf { it.id in ids }
                    json(JSONObject().put("state", true))
                }
                path == "/downurl" -> MockResponse.Builder()
                    .addHeader("Set-Cookie", "acw_tc=tok123; path=/; HttpOnly")
                    .body("""{"state":true,"msg":"","errno":0,"data":"ENCRYPTED"}""").build()
                path == "/cdn" -> {
                    val range = request.headers["Range"]
                    if (range == null) MockResponse.Builder().body(Buffer().write(cdnBytes)).build()
                    else {
                        val (a, b) = range.removePrefix("bytes=").split('-')
                        val start = a.toInt(); val end = if (b.isEmpty()) cdnBytes.size - 1 else b.toInt()
                        MockResponse.Builder().code(206).addHeader("Content-Range", "bytes $start-$end/${cdnBytes.size}")
                            .body(Buffer().write(cdnBytes.copyOfRange(start, end + 1))).build()
                    }
                }
                path == "/uploadinfo" -> json(JSONObject("""{"state":true,"user_id":123,"userkey":"UKEY","size_limit":115000000000}"""))
                path == "/initupload" -> {
                    initCalls++
                    assertNotNull(request.url.queryParameter("k_ec"))
                    val f = decryptInit(request.body!!.toByteArray())
                    lastInitForm = f
                    pendingUploadName = f["filename"]!!
                    val sha = f["fileid"]!!
                    val resp = JSONObject().put("request", "").put("statuscode", 0).put("statusmsg", "").put("target", f["target"])
                    if (initMode == "rapid") {
                        nodes += FNode("901", f["target"]!!.removePrefix("U_1_"), pendingUploadName, false, ByteArray(0))
                        resp.put("status", 2).put("pickcode", "pcnew")
                    } else if (f["sign_val"] == null) {
                        resp.put("status", 7).put("sign_key", "SKEY").put("sign_check", "0-9")
                    } else {
                        resp.put("status", 1).put("bucket", "fhnfile").put("object", "obj/$sha")
                            .put("callback", JSONObject().put("callback", """{"callbackUrl":"https://uplb.115.com/3.0/callback.php"}""")
                                .put("callback_var", """{"x:scene":"0"}"""))
                    }
                    MockResponse.Builder().body(encryptInit(resp)).build()
                }
                path == "/osstoken" -> json(JSONObject("""{"StatusCode":"200","AccessKeyID":"AKID","AccessKeySecret":"SECRET","SecurityToken":"STOKEN","Expiration":"2030-01-01T00:00:00Z"}"""))
                path.startsWith("/oss/fhnfile/") -> {
                    val parent = lastInitForm["target"]!!.removePrefix("U_1_")
                    nodes += FNode("900", parent, pendingUploadName, false, request.body!!.toByteArray())
                    json(JSONObject("""{"state":true,"message":"","code":0,"data":{"aid":1,"cid":"$parent","file_name":"$pendingUploadName","file_ptime":1,"file_status":1,"file_id":"900","file_size":"1","pick_code":"pc900","sha1":"x","sp":1}}"""))
                }
                else -> MockResponse.Builder().code(404).body("no route $path").build()
            }
        }
    }

    @Before fun setUp() {
        nodes += FNode("100", "0", "Music", true)
        nodes += FNode("1", "0", "a.txt", false, "hello".toByteArray())
        nodes += FNode("200", "100", "Pop", true)
        nodes += FNode("10", "100", "song.flac", false, cdnBytes)
        nodes += FNode("21", "200", "p1.mp3", false)
        nodes += FNode("22", "200", "p2.mp3", false)
        nodes += FNode("23", "200", "p3.mp3", false)
        server = MockWebServer().apply { dispatcher = this@Cloud115StorageTest.dispatcher; start() }
        val base = server.url("/").toString()
        val endpoints = Cloud115Endpoints(
            statusCheck = base + "status", files = base + "files", rename = base + "rename", delete = base + "delete",
            downUrl = base + "downurl", uploadInfo = base + "uploadinfo", uploadInit = base + "initupload",
            ossToken = base + "osstoken", ossPathStyleBase = base + "oss",
        )
        storage = Cloud115Storage(
            RemoteConfig("c1", RemoteType.CLOUD115, "115", secret = "UID=123_R2_1700;CID=cc;SEID=ss;KID=kk"),
            endpoints = endpoints,
        )
        storage.retryDelayMs = 10
        storage.cipherFactory = { Ec115Cipher(aesKey, aesIv, hex(V.aesPub)) }
        storage.m115Decode = { s, key ->
            assertEquals("ENCRYPTED", s); assertEquals(16, key.size)
            """{"10":{"file_name":"song.flac","file_size":"1000","pick_code":"pc10","url":{"url":"${base}cdn?t=1","client":1,"oss_id":"x"}}}""".toByteArray()
        }
    }

    @After fun tearDown() = server.close()

    @Test fun listRootAndNested() {
        storage.testConnection()
        val root = storage.list("/")
        assertEquals(listOf("Music", "a.txt"), root.map { it.name })
        assertTrue(root[0].isDirectory)
        assertEquals("/Music", root[0].path)
        assertEquals(5L, root[1].size)
        assertEquals("1", root[1].providerId)
        // 2023-11-15 06:13 UTC+8 = 1700000000 - 20s rounded to minute
        assertEquals(1699999980000L, root[1].modifiedMillis)
        assertEquals(1700000000000L, root[0].modifiedMillis)
        val music = storage.list("/Music/")
        assertEquals(setOf("Pop", "song.flac"), music.map { it.name }.toSet())
        assertEquals("/Music/song.flac", music.first { !it.isDirectory }.path)
        val req = log.last { it.url.encodedPath == "/files" }
        assertEquals("100", req.url.queryParameter("cid"))
        assertEquals("1", req.url.queryParameter("show_dir"))
        assertTrue(req.headers["Cookie"]!!.contains("SEID=ss"))
        assertTrue(req.headers["User-Agent"]!!.contains("115Browser"))
    }

    @Test fun pagingCollectsAllPages() {
        val pop = storage.list("/Music/Pop")
        assertEquals(listOf("p1.mp3", "p2.mp3", "p3.mp3"), pop.map { it.name })
        val offsets = log.filter { it.url.queryParameter("cid") == "200" }.map { it.url.queryParameter("offset") }
        assertEquals(listOf("0", "1000"), offsets)
    }

    @Test fun statAndMissing() {
        assertEquals(1000L, storage.stat("/Music/song.flac")!!.size)
        assertTrue(storage.stat("/")!!.isDirectory)
        assertNull(storage.stat("/Music/nope.flac"))
        assertNull(storage.stat("/Nope/x.flac"))
        // path->cid is cached: resolving /Music/Pop again doesn't re-list root
        storage.list("/Music/Pop")
        val rootLists = log.count { it.url.queryParameter("cid") == "0" }
        storage.list("/Music/Pop")
        assertEquals(rootLists, log.count { it.url.queryParameter("cid") == "0" })
    }

    @Test fun rangeReadUsesDownurlCookiesAndUa() {
        val bytes = storage.openRange("/Music/song.flac", 10, 20).use { it.readBytes() }
        assertArrayEquals(cdnBytes.copyOfRange(10, 30), bytes)
        val cdn = log.last { it.url.encodedPath == "/cdn" }
        assertEquals("bytes=10-29", cdn.headers["Range"])
        assertTrue(cdn.headers["Cookie"]!!.contains("acw_tc=tok123"))
        assertTrue(cdn.headers["Cookie"]!!.contains("UID=123_R2_1700"))
        val down = log.last { it.url.encodedPath == "/downurl" }
        assertEquals(cdn.headers["User-Agent"], down.headers["User-Agent"])
        assertTrue(form(down)["data"]!!.isNotEmpty())
        assertNotNull(down.url.queryParameter("t"))
        // full read; download URL cached
        val all = storage.openRead("/Music/song.flac").use { it.readBytes() }
        assertArrayEquals(cdnBytes, all)
        assertEquals(1, log.count { it.url.encodedPath == "/downurl" })
        // tail read
        assertArrayEquals(cdnBytes.copyOfRange(990, 1000), storage.openRange("/Music/song.flac", 990, -1).use { it.readBytes() })
    }

    @Test fun renameAndDelete() {
        assertEquals("/Music/new.flac", storage.rename("/Music/song.flac", "new.flac"))
        val r = log.last { it.url.encodedPath == "/rename" }
        assertEquals("new.flac", form(r)["files_new_name[10]"])
        assertNotNull(storage.stat("/Music/new.flac"))
        storage.delete("/Music/new.flac")
        assertEquals("10", form(log.last { it.url.encodedPath == "/delete" })["fid[0]"])
        assertNull(storage.stat("/Music/new.flac"))
    }

    @Test fun uploadReplacesViaSignCheckOssDeleteAndRename() {
        val data = ByteArray(5000) { (it * 7).toByte() }
        val f = File.createTempFile("up115", ".flac").apply { deleteOnExit(); writeBytes(data) }
        storage.upload("/Music/song.flac", f)

        assertEquals(2, initCalls)
        val inits = log.filter { it.url.encodedPath == "/initupload" }
        val second = decryptInit(inits[1].body!!.toByteArray())
        val d = Cloud115Hash.digest(f)
        assertEquals("SKEY", second["sign_key"])
        assertEquals(Cloud115Hash.rangeSha1(f, "0-9"), second["sign_val"])
        assertEquals(d.sha1, second["fileid"])
        assertEquals("U_1_100", second["target"])
        assertEquals("5000", second["filesize"])
        assertEquals("123", second["userid"])
        assertEquals(Cloud115Hash.uploadSignature("123", "UKEY", d.sha1, "U_1_100"), second["sig"])
        assertEquals(Cloud115Hash.uploadToken("123", d.sha1, "5000", "SKEY", second["sign_val"]!!, second["t"]!!, "27.0.5.7"), second["token"])
        assertTrue(second["filename"]!!.startsWith(Cloud115Storage.TMP_PREFIX) && second["filename"]!!.endsWith("_song.flac"))

        val put = log.first { it.url.encodedPath.startsWith("/oss/") }
        assertEquals("PUT", put.method)
        assertEquals("/oss/fhnfile/obj/${d.sha1}", put.url.encodedPath)
        assertTrue(put.headers["Authorization"]!!.startsWith("OSS AKID:"))
        assertEquals("STOKEN", put.headers["x-oss-security-token"])
        assertEquals("""{"callbackUrl":"https://uplb.115.com/3.0/callback.php"}""", String(Base64.getDecoder().decode(put.headers["x-oss-callback"])))
        assertEquals(d.md5Base64, put.headers["Content-MD5"])
        // signature recomputable from what was sent
        val expected = Cloud115Oss.sign("SECRET", "PUT", d.md5Base64, "application/octet-stream", put.headers["Date"]!!,
            mapOf("x-oss-security-token" to "STOKEN", "x-oss-callback" to put.headers["x-oss-callback"]!!,
                "x-oss-callback-var" to put.headers["x-oss-callback-var"]!!), "/fhnfile/obj/${d.sha1}")
        assertEquals("OSS AKID:$expected", put.headers["Authorization"])

        // order: delete old (10) after upload, then rename new (900) to original name
        val paths = log.map { it.url.encodedPath }
        assertTrue(paths.indexOf("/delete") > paths.indexOf(put.url.encodedPath))
        assertTrue(paths.indexOf("/rename") > paths.indexOf("/delete"))
        assertEquals("10", form(log.first { it.url.encodedPath == "/delete" })["fid[0]"])
        assertEquals("song.flac", form(log.first { it.url.encodedPath == "/rename" })["files_new_name[900]"])
        val now = storage.stat("/Music/song.flac")!!
        assertEquals("900", now.providerId)
        assertEquals(5000L, now.size)
        assertEquals(1, storage.list("/Music").count { it.name.endsWith("song.flac") })
    }

    @Test fun rapidUploadNewFile() {
        initMode = "rapid"
        val f = File.createTempFile("up115", ".lrc").apply { deleteOnExit(); writeText("[00:00.00]hi") }
        storage.upload("/Music/new.lrc", f)
        assertFalse(log.any { it.url.encodedPath.startsWith("/oss/") })
        assertFalse(log.any { it.url.encodedPath == "/delete" })
        assertEquals("new.lrc", form(log.first { it.url.encodedPath == "/rename" })["files_new_name[901]"])
        assertNotNull(storage.stat("/Music/new.lrc"))
    }

    @Test fun unchangedUploadIsNoop() {
        val f = File.createTempFile("up115", ".flac").apply { deleteOnExit(); writeBytes(cdnBytes) }
        storage.upload("/Music/song.flac", f)
        assertEquals(0, initCalls)
        assertFalse(log.any { it.url.encodedPath == "/uploadinfo" })
    }

    @Test fun expiredCookieRaisesAuth() {
        loggedOut = true
        try {
            storage.list("/")
            throw AssertionError("expected RemoteAuthException")
        } catch (e: RemoteAuthException) {
            assertEquals("115 登录已失效，请重新扫码", e.message)
        }
        try { storage.testConnection(); throw AssertionError() } catch (_: RemoteAuthException) {}
    }

    @Test(expected = RemoteAuthException::class) fun missingCookieRaisesAuth() {
        Cloud115Storage(RemoteConfig("x", RemoteType.CLOUD115, "115", secret = "")).list("/")
    }

    @Test fun parsersHandleEdgeShapes() {
        try { Cloud115Storage.parseDownUrl("""{"1":{"file_size":"0","url":false}}"""); throw AssertionError() } catch (_: java.io.IOException) {}
        assertEquals("u", Cloud115Storage.parseDownUrl("""{"1":{"file_size":5,"url":{"url":"u"}}}"""))
        assertEquals("900", Cloud115Storage.parseCallback("""{"state":true,"data":{"file_id":"900"}}"""))
        assertEquals("", Cloud115Storage.parseCallback("OK"))
        try { Cloud115Storage.parseCallback("""{"state":false,"message":"x"}"""); throw AssertionError() } catch (_: java.io.IOException) {}
        assertEquals("/a/b", Cloud115Storage.normalize("a//b/"))
        assertEquals("/", Cloud115Storage.parentOf("/a"))
    }
}

class Cloud115OssMultipartTest {
    @Test fun multipartInitPartsComplete() {
        val server = MockWebServer().apply { start() }
        try {
            server.enqueue(MockResponse.Builder().body("<InitiateMultipartUploadResult><Bucket>b</Bucket><Key>k/o</Key><UploadId>UPID</UploadId></InitiateMultipartUploadResult>").build())
            server.enqueue(MockResponse.Builder().addHeader("ETag", "\"E1\"").build())
            server.enqueue(MockResponse.Builder().addHeader("ETag", "\"E2\"").build())
            server.enqueue(MockResponse.Builder().addHeader("ETag", "\"E3\"").build())
            server.enqueue(MockResponse.Builder().body("""{"state":true,"data":{"file_id":"77"}}""").build())
            val oss = Cloud115Oss(okhttp3.OkHttpClient(), Cloud115Endpoints(ossPathStyleBase = server.url("/").toString()))
            val data = ByteArray(250) { it.toByte() }
            val f = File.createTempFile("mp115", ".bin").apply { deleteOnExit(); writeBytes(data) }
            val body = oss.multipartUpload(OssTarget("b", "k/o", "{\"cb\":1}", "{\"v\":1}"), { OssToken("AK", "SK", "ST") }, f, partSize = 100)
            assertEquals("77", Cloud115Storage.parseCallback(body))
            val init = server.takeRequest()
            assertEquals("POST", init.method)
            assertEquals("/b/k/o?uploads", init.target)
            val parts = (1..3).map { server.takeRequest() }
            assertEquals(listOf(100L, 100L, 50L), parts.map { it.bodySize })
            assertEquals("/b/k/o?partNumber=2&uploadId=UPID", parts[1].target)
            assertArrayEquals(data.copyOfRange(200, 250), parts[2].body!!.toByteArray())
            val done = server.takeRequest()
            assertEquals("/b/k/o?uploadId=UPID", done.target)
            val xml = done.body!!.utf8()
            assertTrue(xml, xml.contains("<Part><PartNumber>3</PartNumber><ETag>\"E3\"</ETag></Part>"))
            assertEquals("{\"cb\":1}", String(Base64.getDecoder().decode(done.headers["x-oss-callback"])))
            val sig = Cloud115Oss.sign("SK", "POST", "", "application/xml", done.headers["Date"]!!,
                mapOf("x-oss-security-token" to "ST", "x-oss-callback" to done.headers["x-oss-callback"]!!,
                    "x-oss-callback-var" to done.headers["x-oss-callback-var"]!!), "/b/k/o?uploadId=UPID")
            assertEquals("OSS AK:$sig", done.headers["Authorization"])
        } finally {
            server.close()
        }
    }
}
