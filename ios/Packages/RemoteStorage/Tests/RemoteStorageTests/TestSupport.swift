import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import RemoteStorage

/// A request seen by the stub server.
struct RecordedRequest {
    let method: String
    let url: URL
    let headers: [String: String] // lower-cased names
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var path: String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path }
    var target: String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return path + (c?.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
    func query(_ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
    var text: String { String(decoding: body, as: UTF8.self) }
    var json: JSONValue { (try? JSONValue.parse(body)) ?? .null }
    /// application/x-www-form-urlencoded body.
    var form: [String: String] { formDecode(text) }
}

func formDecode(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") where pair.contains("=") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        func dec(_ x: Substring) -> String { RemotePaths.percentDecode(x.replacingOccurrences(of: "+", with: " ")) }
        out[dec(kv[0])] = dec(kv[1])
    }
    return out
}

struct StubReply {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ s: String, status: Int = 200) -> StubReply {
        StubReply(status: status, headers: ["Content-Type": "application/json"], body: Data(s.utf8))
    }
    static func json(_ v: JSONValue, status: Int = 200) -> StubReply { json(v.serializedString, status: status) }
    static func text(_ s: String, status: Int = 200, headers: [String: String] = [:]) -> StubReply {
        StubReply(status: status, headers: headers, body: Data(s.utf8))
    }
    static func data(_ d: Data, status: Int = 200, headers: [String: String] = [:]) -> StubReply {
        StubReply(status: status, headers: headers, body: d)
    }
    static func code(_ status: Int, headers: [String: String] = [:]) -> StubReply { StubReply(status: status, headers: headers) }
}

/// URLProtocol-based fake HTTP server: either a queue of replies (MockWebServer.enqueue) or a dispatcher.
final class StubURLProtocol: URLProtocol {
    private static let state = Locked<(queue: [StubReply], dispatcher: ((RecordedRequest) -> StubReply)?, log: [RecordedRequest])>(([], nil, []))

    static func reset() { state.withLock { $0 = ([], nil, []) } }
    static func enqueue(_ r: StubReply) { state.withLock { $0.queue.append(r) } }
    static func setDispatcher(_ d: @escaping (RecordedRequest) -> StubReply) { state.withLock { $0.dispatcher = d } }
    static var requests: [RecordedRequest] { state.current.log }
    static var requestCount: Int { state.current.log.count }

    static func configuration() -> URLSessionConfiguration {
        let c = RemoteHTTP.defaultConfiguration()
        c.protocolClasses = [StubURLProtocol.self]
        c.timeoutIntervalForRequest = 10
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let rec = RecordedRequest(method: request.httpMethod ?? "GET", url: request.url!, headers: headers, body: body)
        let reply: StubReply = Self.state.withLock { st in
            st.log.append(rec)
            if let d = st.dispatcher { return d(rec) }
            if !st.queue.isEmpty { return st.queue.removeFirst() }
            return StubReply(status: 599, body: Data("no reply queued".utf8))
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300..<400).contains(reply.status), let loc = reply.headers["Location"], let target = URL(string: loc, relativeTo: request.url) {
            var next = request
            next.url = target.absoluteURL
            // The loading system cancels this protocol and starts a new one for `next`.
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

class StubTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func take(_ i: Int) -> RecordedRequest {
        let r = StubURLProtocol.requests
        XCTAssertGreaterThan(r.count, i, "request #\(i) not made")
        return r[min(i, r.count - 1)]
    }

    func tempFile(_ data: Data, ext: String = "bin") throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString).\(ext)")
        try data.write(to: u)
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
}

func assertThrowsAsync<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line,
                          _ check: (Error) -> Void = { _ in }) async {
    do {
        _ = try await body()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        check(error)
    }
}
