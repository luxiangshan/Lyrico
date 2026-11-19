package com.lonx.lyrico.remote.cloud115

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Base64

class Cloud115HashTest {
    private fun sha1(b: ByteArray) = Cloud115Hash.hexUpper(MessageDigest.getInstance("SHA-1").digest(b))

    @Test fun smallFilePreIdEqualsSha1() {
        val f = File.createTempFile("h115", ".bin").apply { deleteOnExit(); writeBytes(ByteArray(0)) }
        val d = Cloud115Hash.digest(f)
        assertEquals("DA39A3EE5E6B4B0D3255BFEF95601890AFD80709", d.sha1)
        assertEquals(d.sha1, d.preId)
        assertEquals(0L, d.size)
        assertEquals("1B2M2Y8AsgTpgAmY7PhCfg==", d.md5Base64)
    }

    @Test fun largeFileDigests() {
        val data = ByteArray(300_000) { (it * 31 + 7).toByte() }
        val f = File.createTempFile("h115", ".bin").apply { deleteOnExit(); writeBytes(data) }
        val d = Cloud115Hash.digest(f)
        assertEquals(sha1(data), d.sha1)
        assertEquals(sha1(data.copyOfRange(0, 128 * 1024)), d.preId)
        assertEquals(300_000L, d.size)
        assertEquals(Base64.getEncoder().encodeToString(MessageDigest.getInstance("MD5").digest(data)), d.md5Base64)
        // exactly 128 KiB: preId == sha1
        val g = File.createTempFile("h115", ".bin").apply { deleteOnExit(); writeBytes(data.copyOfRange(0, 131072)) }
        val e = Cloud115Hash.digest(g)
        assertEquals(e.sha1, e.preId)
    }

    @Test fun rangeSha1IsInclusive() {
        val data = ByteArray(5000) { it.toByte() }
        val f = File.createTempFile("h115", ".bin").apply { deleteOnExit(); writeBytes(data) }
        assertEquals(sha1(data.copyOfRange(100, 2001)), Cloud115Hash.rangeSha1(f, "100-2000"))
        assertEquals(sha1(data.copyOfRange(0, 1)), Cloud115Hash.rangeSha1(f, "0-0"))
        try { Cloud115Hash.rangeSha1(f, "4000-6000"); throw AssertionError() } catch (_: IOException) {}
    }

    @Test fun credentialParsing() {
        val c = Cloud115Credential.parse("uid=123_R2_17000; CID=abc;SEID=def ; KID=k")!!
        assertEquals("UID=123_R2_17000; CID=abc; SEID=def; KID=k", c.toCookie())
        assertEquals("123", c.userId)
        assertNull(Cloud115Credential.parse("UID=1; CID=2"))
    }

    @Test fun credentialParsingPastedAndWebSession() {
        // Pasted from browser dev tools: header name, line breaks, quotes, extra cookies.
        val pasted = "Cookie: USERSESSIONID=x; UID=\"9_A1_1\";\nCID=c\r\nSEID=s; acw_tc=zz"
        assertEquals("UID=9_A1_1; CID=c; SEID=s", Cloud115Credential.parse(pasted)!!.toCookie())
        // Web-login session without KID is accepted.
        assertEquals("", Cloud115Credential.parse("UID=1_A1_2; CID=c; SEID=s")!!.kid)
    }
}

class Cloud115QrLoginTest {
    private lateinit var server: MockWebServer
    private lateinit var login: Cloud115QrLogin

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
        val base = server.url("/").toString()
        login = Cloud115QrLogin(
            endpoints = Cloud115Endpoints(
                qrToken = base + "api/1.0/web/1.0/token",
                qrStatus = base + "get/status/",
                qrLogin = base + "app/1.0/%s/1.0/login/qrcode",
            ),
        )
    }

    @After fun tearDown() = server.close()

    private fun json(s: String) = MockResponse.Builder().body(s).addHeader("Content-Type", "application/json").build()

    @Test fun fullFlow() {
        server.enqueue(json("""{"state":1,"code":0,"data":{"uid":"u123","time":1700000000,"sign":"sg","qrcode":"https://115.com/scan/dg-u123"}}"""))
        val s = login.start()
        assertEquals("u123", s.uid)
        assertEquals("https://115.com/scan/dg-u123", s.qrContent)

        server.enqueue(json("""{"state":1,"code":0,"data":{"msg":"","status":0,"version":""}}"""))
        server.enqueue(json("""{"state":1,"code":0,"data":{"msg":"扫码成功","status":1}}"""))
        server.enqueue(json("""{"state":1,"code":0,"data":{"msg":"登录成功","status":2}}"""))
        server.enqueue(json("""{"state":1,"code":0,"data":{"user_id":123,"cookie":{"UID":"123_R2_1700","CID":"c1","SEID":"s1","KID":"k1"}}}"""))
        val seen = ArrayList<Cloud115QrLogin.Status>()
        val cookie = login.awaitCookie(s, onStatus = { seen += it })
        assertEquals("UID=123_R2_1700; CID=c1; SEID=s1; KID=k1", cookie)
        assertEquals(listOf(Cloud115QrLogin.Status.WAITING, Cloud115QrLogin.Status.SCANNED, Cloud115QrLogin.Status.CONFIRMED), seen)

        server.takeRequest() // token
        val st = server.takeRequest()
        assertEquals("u123", st.url.queryParameter("uid"))
        assertEquals("1700000000", st.url.queryParameter("time"))
        assertEquals("sg", st.url.queryParameter("sign"))
        server.takeRequest(); server.takeRequest()
        val lr = server.takeRequest()
        assertEquals("POST", lr.method)
        assertEquals("/app/1.0/alipaymini/1.0/login/qrcode", lr.url.encodedPath)
        val body = lr.body!!.utf8()
        assertTrue(body, body.contains("account=u123") && body.contains("app=alipaymini"))
    }

    @Test fun missingQrContentFallsBack() {
        server.enqueue(json("""{"state":1,"data":{"uid":"zz","time":1,"sign":"x"}}"""))
        assertEquals("https://115.com/scan/dg-zz", login.start().qrContent)
    }

    @Test fun statusParsing() {
        fun st(s: String) = Cloud115QrLogin.parseStatus(JSONObject(s))
        assertEquals(Cloud115QrLogin.Status.EXPIRED, st("""{"state":1,"data":{"status":-1}}"""))
        assertEquals(Cloud115QrLogin.Status.CANCELLED, st("""{"state":1,"data":{"status":-2}}"""))
        assertEquals(Cloud115QrLogin.Status.CONFIRMED, st("""{"state":1,"data":{"status":"2"}}"""))
        assertEquals(Cloud115QrLogin.Status.EXPIRED, st("""{"state":0,"message":"二维码已过期"}"""))
    }

    @Test fun expiredReturnsNull() {
        server.enqueue(json("""{"state":1,"data":{"status":-1}}"""))
        assertNull(login.awaitCookie(Cloud115QrLogin.Session("u", 1, "s", "q")))
    }

    @Test(expected = IOException::class) fun loginFailure() {
        Cloud115QrLogin.parseLoginCookie(JSONObject("""{"state":0,"code":40101017,"message":"登录失败"}"""))
    }
}
