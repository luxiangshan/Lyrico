import Foundation
import XCTest
@testable import RemoteStorage

final class WebDAVStorageTests: StubTestCase {
    private let host = "http://dav.test"

    private func storage(_ basePath: String = "/dav", user: String = "", pass: String = "") throws -> WebDAVStorage {
        try WebDAVStorage(config: RemoteLocationConfig(id: "w", type: .webdav, displayName: "w", baseURL: host + basePath, username: user),
                          password: pass, sessionConfiguration: StubURLProtocol.configuration())
    }

    private func ms(_ xml: String) -> StubReply { .text(xml, status: 207, headers: ["Content-Type": "application/xml; charset=utf-8"]) }

    func testListNextcloudStyle() async throws {
        StubURLProtocol.enqueue(ms("""
        <?xml version="1.0"?>
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
        </d:multistatus>
        """))
        let list = try await storage("/remote.php/dav/files/alice").list("/Music")
        let req = take(0)
        XCTAssertEqual("PROPFIND", req.method)
        XCTAssertEqual("1", req.header("Depth"))
        XCTAssertEqual("/remote.php/dav/files/alice/Music/", req.path)
        XCTAssertTrue(req.text.contains("propfind"))
        XCTAssertEqual(3, list.count)
        let song = try XCTUnwrap(list.first { !$0.isDirectory && $0.size == 12345 })
        XCTAssertEqual("/Music/My Song + 1.flac", song.path)
        XCTAssertEqual("My Song + 1.flac", song.name)
        XCTAssertEqual(1_699_351_200_000, song.modifiedMillis)
        XCTAssertEqual("/Music/周杰伦", list.first { $0.isDirectory }?.path)
        XCTAssertEqual("/Music/a+b.mp3", list.first { $0.size == 7 }?.path)
    }

    func testListApacheAbsoluteHrefsDefaultNamespace() async throws {
        StubURLProtocol.enqueue(ms("""
        <?xml version="1.0" encoding="utf-8"?>
        <multistatus xmlns="DAV:" xmlns:lp1="DAV:">
        <response><href>\(host)/dav/</href><propstat><prop><lp1:resourcetype><lp1:collection/></lp1:resourcetype></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        <response><href>\(host)/dav/x.mp3</href><propstat><prop><lp1:resourcetype/><lp1:getcontentlength>99</lp1:getcontentlength></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        <response><href>\(host)/dav/sub</href><propstat><prop><getcontenttype>httpd/unix-directory</getcontenttype><resourcetype/></prop><status>HTTP/1.1 200 OK</status></propstat></response>
        </multistatus>
        """))
        let list = try await storage().list("/")
        XCTAssertEqual(["/x.mp3", "/sub"], list.map(\.path))
        XCTAssertEqual(99, list[0].size)
        XCTAssertTrue(list[1].isDirectory)
    }

    func testListHrefsOutsideBaseFallBackToLastSegment() async throws {
        // e.g. reverse proxy maps https://host/webdav -> backend /dav without rewriting hrefs
        StubURLProtocol.enqueue(ms("""
        <D:multistatus xmlns:D="DAV:">
        <D:response><D:href>/backend/Music/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        <D:response><D:href>/backend/Music/b.ogg</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>5</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """))
        let list = try await storage("/webdav").list("/Music/")
        XCTAssertEqual(["/Music/b.ogg"], list.map(\.path))
    }

    func testStatFoundAndMissing() async throws {
        StubURLProtocol.enqueue(ms(#"<D:multistatus xmlns:D="DAV:"><D:response><D:href>/dav/a.mp3</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"#))
        StubURLProtocol.enqueue(.code(404))
        let s = try storage()
        let e = try await s.stat("/a.mp3")
        XCTAssertEqual(42, e?.size)
        XCTAssertEqual(false, e?.isDirectory)
        XCTAssertEqual("0", take(0).header("Depth"))
        let missing = try await s.stat("/nope.mp3")
        XCTAssertNil(missing)
    }

    func testReadRangeSendsRangeHeader() async throws {
        StubURLProtocol.enqueue(.text("cdef", status: 206))
        let bytes = try await storage().readRange("/a b.mp3", offset: 2, length: 4)
        XCTAssertEqual("cdef", String(decoding: bytes, as: UTF8.self))
        XCTAssertEqual("bytes=2-5", take(0).header("Range"))
        XCTAssertEqual("/dav/a%20b.mp3", take(0).path)
    }

    func testReadRangeHandlesServerIgnoringRange() async throws {
        StubURLProtocol.enqueue(.text("abcdefghij", status: 200))
        let bytes = try await storage().readRange("/a.mp3", offset: 3, length: 4)
        XCTAssertEqual("defg", String(decoding: bytes, as: UTF8.self))
    }

    func testDownloadWritesFile() async throws {
        StubURLProtocol.enqueue(.text("WHOLEFILE"))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("rs-dl-\(UUID().uuidString)/x.mp3")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        try await storage().download("/x.mp3", to: out)
        XCTAssertEqual("WHOLEFILE", try String(contentsOf: out, encoding: .utf8))
        XCTAssertNil(take(0).header("Range"))
    }

    func testUploadUsesTempThenMove() async throws {
        StubURLProtocol.enqueue(.code(201))
        StubURLProtocol.enqueue(.code(204))
        let f = try tempFile(Data("NEWDATA".utf8), ext: "mp3")
        try await storage().upload(from: f, to: "/Music/song.mp3")
        let put = take(0)
        XCTAssertEqual("PUT", put.method)
        XCTAssertEqual("/dav/Music/.song.mp3.lyrico-tmp", put.path)
        XCTAssertEqual("NEWDATA", put.text)
        let move = take(1)
        XCTAssertEqual("MOVE", move.method)
        XCTAssertEqual("/dav/Music/.song.mp3.lyrico-tmp", move.path)
        XCTAssertEqual("\(host)/dav/Music/song.mp3", move.header("Destination"))
        XCTAssertEqual("T", move.header("Overwrite"))
    }

    func testUploadFallsBackToDirectPutWhenMoveUnsupported() async throws {
        StubURLProtocol.enqueue(.code(201)) // PUT tmp
        StubURLProtocol.enqueue(.code(405)) // MOVE
        StubURLProtocol.enqueue(.code(204)) // PUT target
        StubURLProtocol.enqueue(.code(204)) // DELETE tmp
        let f = try tempFile(Data("X".utf8), ext: "mp3")
        try await storage().upload(from: f, to: "/song.mp3")
        XCTAssertEqual("PUT", take(2).method)
        XCTAssertEqual("/dav/song.mp3", take(2).path)
        XCTAssertEqual("DELETE", take(3).method)
        XCTAssertEqual("/dav/.song.mp3.lyrico-tmp", take(3).path)
    }

    func testUploadReplacesWhenOverwriteRefused() async throws {
        StubURLProtocol.enqueue(.code(201)) // PUT tmp
        StubURLProtocol.enqueue(.code(412)) // MOVE overwrite refused
        StubURLProtocol.enqueue(.code(204)) // DELETE target
        StubURLProtocol.enqueue(.code(201)) // MOVE again
        let f = try tempFile(Data("X".utf8))
        try await storage().upload(from: f, to: "/song.mp3")
        XCTAssertEqual("DELETE", take(2).method)
        XCTAssertEqual("/dav/song.mp3", take(2).path)
        XCTAssertEqual("F", take(3).header("Overwrite"))
    }

    func testRenameUsesMoveWithoutOverwrite() async throws {
        StubURLProtocol.enqueue(.code(201))
        let np = try await storage().rename("/Music/old.mp3", to: "new name.mp3")
        XCTAssertEqual("/Music/new name.mp3", np)
        XCTAssertEqual("MOVE", take(0).method)
        XCTAssertEqual("F", take(0).header("Overwrite"))
        XCTAssertEqual("\(host)/dav/Music/new%20name.mp3", take(0).header("Destination"))
    }

    func testRenameConflict() async throws {
        StubURLProtocol.enqueue(.code(412))
        await assertThrowsAsync({ try await self.storage().rename("/a.mp3", to: "b.mp3") }) { e in
            XCTAssertTrue((e as? RemoteStorageError)?.message.contains("already exists") == true)
        }
    }

    func testDeleteSendsDelete() async throws {
        StubURLProtocol.enqueue(.code(204))
        try await storage().delete("/x.mp3")
        XCTAssertEqual("DELETE", take(0).method)
    }

    func testBasicAuthChallengeThenPreemptive() async throws {
        StubURLProtocol.enqueue(.code(401, headers: ["WWW-Authenticate": "Basic realm=\"dav\""]))
        StubURLProtocol.enqueue(.code(204))
        StubURLProtocol.enqueue(.code(204))
        let s = try storage(user: "bob", pass: "pw")
        try await s.delete("/a")
        try await s.delete("/b")
        XCTAssertNil(take(0).header("Authorization"))
        let expected = "Basic " + Data("bob:pw".utf8).base64EncodedString()
        XCTAssertEqual(expected, take(1).header("Authorization"))
        XCTAssertEqual(expected, take(2).header("Authorization")) // preemptive, no extra 401 round trip
        XCTAssertEqual(3, StubURLProtocol.requestCount)
    }

    func testDigestAuth() async throws {
        StubURLProtocol.enqueue(.code(401, headers: ["WWW-Authenticate": "Digest realm=\"me@x\", qop=\"auth\", nonce=\"abc123\", opaque=\"op\", algorithm=MD5"]))
        StubURLProtocol.enqueue(.code(204))
        try await storage(user: "bob", pass: "pw").delete("/a.mp3")
        let h = try XCTUnwrap(take(1).header("Authorization"))
        XCTAssertTrue(h.hasPrefix("Digest "), h)
        func p(_ k: String) -> String {
            guard let r = h.range(of: "\(k)=") else { return "" }
            var v = h[r.upperBound...]
            if v.hasPrefix("\"") { v = v.dropFirst(); return String(v[..<v.firstIndex(of: "\"")!]) }
            return String(v.prefix { $0 != "," })
        }
        XCTAssertEqual("/dav/a.mp3", p("uri"))
        XCTAssertEqual("op", p("opaque"))
        let ha1 = HTTPAuth.h(.md5, "bob:me@x:pw")
        let ha2 = HTTPAuth.h(.md5, "DELETE:/dav/a.mp3")
        XCTAssertEqual(HTTPAuth.h(.md5, "\(ha1):abc123:\(p("nc")):\(p("cnonce")):auth:\(ha2)"), p("response"))
    }

    func testWrongPasswordGivesAuthError() async throws {
        for _ in 0..<3 { StubURLProtocol.enqueue(.code(401, headers: ["WWW-Authenticate": "Basic realm=\"dav\""])) }
        await assertThrowsAsync({ try await self.storage(user: "bob", pass: "bad").testConnection() }) { e in
            guard case .auth(let m)? = e as? RemoteStorageError else { return XCTFail("\(e)") }
            XCTAssertTrue(m.contains("401"))
        }
        XCTAssertEqual(2, StubURLProtocol.requestCount) // one challenge + one rejected attempt, no loop
    }

    func testGuest403OnPropfindIsAuth() async throws {
        StubURLProtocol.enqueue(.code(403))
        await assertThrowsAsync({ try await self.storage().testConnection() }) { e in
            XCTAssertTrue((e as? RemoteStorageError)?.isAuth == true)
        }
    }

    func testPathHelpers() {
        XCTAssertEqual("/a/b", RemotePaths.normalize("a//b/./"))
        XCTAssertEqual("/", RemotePaths.parent("/a"))
        XCTAssertEqual("a+b c", RemotePaths.percentDecode("a+b%20c"))
        XCTAssertEqual("100%", RemotePaths.percentDecode("100%"))
        XCTAssertEqual("/a%20b/%E4%B8%AD", RemotePaths.encodePath("/a b/中"))
        XCTAssertEqual("/x/y", WebDAVXML.hrefToPath("https://h:1/x/y/?q=1"))
    }

    func testChallengeParser() {
        let c = HTTPAuth.parseChallenges(#"Digest realm="a, b", nonce="n1", qop="auth,auth-int", Basic realm="x""#)
        XCTAssertEqual(2, c.count)
        XCTAssertEqual("Digest", c[0].scheme)
        XCTAssertEqual("a, b", c[0].params["realm"])
        XCTAssertEqual("auth,auth-int", c[0].params["qop"])
        XCTAssertEqual("Basic", c[1].scheme)
        XCTAssertEqual("x", c[1].params["realm"])
        XCTAssertEqual(["Negotiate"], HTTPAuth.parseChallenges("Negotiate abc==").map(\.scheme))
    }
}
