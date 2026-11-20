import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Request body.
enum HTTPBody {
    case none
    case data(Data)
    /// Streamed from a local file (Content-Length is set from the file size).
    case file(URL)
    /// Streamed from a byte range of a local file.
    case fileRange(URL, offset: Int64, length: Int64)
}

/// Where the response body goes.
enum HTTPSink {
    /// Whole body in memory.
    case memory
    /// Ranged read: on 206 the body is taken as is, on 200 (server ignored Range) the first `skip` bytes are
    /// dropped. At most `limit` bytes are kept (nil = to end); the transfer is cancelled once enough arrived.
    case range(skip: Int64, limit: Int64?)
    /// Body streamed into a local file (only for 2xx responses; error bodies stay in memory).
    case file(URL)
}

struct HTTPResponse {
    let status: Int
    /// Header names lower-cased.
    let headers: [String: String]
    let body: Data
    /// Final URL after redirects.
    let url: URL?
    /// `name=value` of every Set-Cookie header.
    let setCookies: [String]

    var isSuccess: Bool { (200..<300).contains(status) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
    var text: String { String(decoding: body, as: UTF8.self) }

    /// Short readable snippet of the body for error messages.
    var snippet: String {
        let t = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return t.isEmpty ? "" : ": " + String(t.prefix(200))
    }
}

/// Default URLSession configuration for providers: no cookie jar, no cache, no credential storage
/// (every provider manages Authorization / Cookie headers itself).
public enum RemoteHTTP {
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpMaximumConnectionsPerHost = 8
        return c
    }
}

/// URLSession wrapper with streaming sinks, header-preserving redirects and Swift-concurrency cancellation.
/// Works with Foundation on Apple platforms and FoundationNetworking on Linux.
final class HTTPClient: @unchecked Sendable {
    private let session: URLSession
    private let delegate: SessionDelegate

    init(configuration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration(), followRedirects: Bool = true) {
        let d = SessionDelegate(followRedirects: followRedirects)
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "RemoteStorage.HTTPClient"
        delegate = d
        session = URLSession(configuration: configuration, delegate: d, delegateQueue: q)
    }

    deinit { session.finishTasksAndInvalidate() }

    func invalidate() { session.invalidateAndCancel() }

    /// Sends a request. Transport failures throw `URLError` (callers wrap them with context).
    func send(_ request: URLRequest, body: HTTPBody = .none, sink: HTTPSink = .memory) async throws -> HTTPResponse {
        var req = request
        var bodyFile: URL?
        switch body {
        case .none:
            break
        case .data(let d):
            req.httpBody = d
            if req.value(forHTTPHeaderField: "Content-Length") == nil { req.setValue(String(d.count), forHTTPHeaderField: "Content-Length") }
        case .file(let url):
            let size = try Self.fileSize(url)
            guard let stream = InputStream(url: url) else { throw RemoteStorageError.io("Cannot read \(url.path)") }
            req.httpBodyStream = stream
            req.setValue(String(size), forHTTPHeaderField: "Content-Length")
            bodyFile = url
        case .fileRange(let url, let off, let len):
            let d = try Self.readRange(url, offset: off, length: len)
            req.httpBody = d
            req.setValue(String(d.count), forHTTPHeaderField: "Content-Length")
        }
        let state = TaskState(sink: sink, bodyFile: bodyFile)
        let task = session.dataTask(with: req)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPResponse, Error>) in
                state.continuation = cont
                delegate.register(task, state)
                if Task.isCancelled {
                    task.cancel()
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    static func readRange(_ url: URL, offset: Int64, length: Int64) throws -> Data {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(offset))
        let d = fh.readData(ofLength: Int(length))
        if Int64(d.count) != length { throw RemoteStorageError.io("File was truncated while uploading") }
        return d
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? Int64((attrs[.size] as? Int) ?? 0)
    }
}

// MARK: - Delegate

private final class TaskState {
    let sink: HTTPSink
    let bodyFile: URL?
    var continuation: CheckedContinuation<HTTPResponse, Error>?
    var response: HTTPURLResponse?
    var buffer = Data()
    var fileHandle: FileHandle?
    var skipRemaining: Int64 = 0
    var limitRemaining: Int64?
    var collecting = true
    var finished = false

    init(sink: HTTPSink, bodyFile: URL?) {
        self.sink = sink
        self.bodyFile = bodyFile
    }
}

private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Int: TaskState] = [:]
    private let followRedirects: Bool

    init(followRedirects: Bool) { self.followRedirects = followRedirects }

    func register(_ task: URLSessionTask, _ state: TaskState) {
        lock.lock(); states[task.taskIdentifier] = state; lock.unlock()
    }

    private func state(_ task: URLSessionTask) -> TaskState? {
        lock.lock(); defer { lock.unlock() }
        return states[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) {
        lock.lock(); states[task.taskIdentifier] = nil; lock.unlock()
    }

    private static let maxErrorBody = 64 * 1024

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let st = state(dataTask) else { completionHandler(.cancel); return }
        let http = response as? HTTPURLResponse
        st.response = http
        let status = http?.statusCode ?? 0
        let ok = (200..<300).contains(status)
        switch st.sink {
        case .memory:
            break
        case .range(let skip, let limit):
            if status == 206 { st.skipRemaining = 0; st.limitRemaining = limit }
            else if status == 200 { st.skipRemaining = skip; st.limitRemaining = limit }
            else { st.skipRemaining = 0; st.limitRemaining = Int64(Self.maxErrorBody) }
            if st.limitRemaining == 0 && ok {
                completionHandler(.cancel)
                finish(dataTask, st, error: nil)
                return
            }
        case .file(let url):
            if ok {
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                        throw RemoteStorageError.io("Cannot create \(url.path)")
                    }
                    st.fileHandle = try FileHandle(forWritingTo: url)
                } catch {
                    completionHandler(.cancel)
                    finish(dataTask, st, error: error)
                    return
                }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let st = state(dataTask), !st.finished else { return }
        var chunk = data
        if st.skipRemaining > 0 {
            if Int64(chunk.count) <= st.skipRemaining {
                st.skipRemaining -= Int64(chunk.count)
                return
            }
            chunk = chunk.subdata(in: Int(st.skipRemaining)..<chunk.count)
            st.skipRemaining = 0
        }
        var reachedLimit = false
        if let lim = st.limitRemaining {
            if Int64(chunk.count) >= lim {
                chunk = chunk.prefix(Int(lim))
                reachedLimit = true
            }
            st.limitRemaining = lim - Int64(chunk.count)
        }
        if let fh = st.fileHandle {
            fh.write(chunk)
        } else {
            let status = st.response?.statusCode ?? 0
            if case .file = st.sink, st.buffer.count >= Self.maxErrorBody, !(200..<300).contains(status) {
                // keep only the head of error bodies
            } else {
                st.buffer.append(chunk)
            }
        }
        if reachedLimit {
            finish(dataTask, st, error: nil)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let st = state(task) else { return }
        finish(task, st, error: error)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard followRedirects else { completionHandler(nil); return }
        var req = request
        let original = task.currentRequest ?? task.originalRequest
        let crossHost = original?.url?.host?.lowercased() != request.url?.host?.lowercased()
        // Keep our headers (Range, UA, Cookie, ...) on the redirected request; drop Authorization across hosts.
        for (k, v) in original?.allHTTPHeaderFields ?? [:] {
            let lk = k.lowercased()
            if lk == "content-length" || lk == "content-type" || lk == "host" { continue }
            if lk == "authorization" { if crossHost { continue } }
            if req.value(forHTTPHeaderField: k) == nil { req.setValue(v, forHTTPHeaderField: k) }
        }
        if crossHost { req.setValue(nil, forHTTPHeaderField: "Authorization") }
        completionHandler(req)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, needNewBodyStream completionHandler: @escaping (InputStream?) -> Void) {
        guard let st = state(task), let url = st.bodyFile else { completionHandler(nil); return }
        completionHandler(InputStream(url: url))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // HTTP auth is answered by the providers themselves (Basic/Digest headers); let 401s through.
        #if canImport(FoundationNetworking)
        completionHandler(.rejectProtectionSpace, nil)
        #else
        completionHandler(.performDefaultHandling, nil)
        #endif
    }

    private func finish(_ task: URLSessionTask, _ st: TaskState, error: Error?) {
        if st.finished { return }
        st.finished = true
        remove(task)
        if let fh = st.fileHandle { try? fh.close(); st.fileHandle = nil }
        guard let cont = st.continuation else { return }
        st.continuation = nil
        if let error = error {
            if case .file(let url) = st.sink { try? FileManager.default.removeItem(at: url) }
            cont.resume(throwing: error)
            return
        }
        guard let http = st.response else {
            cont.resume(throwing: URLError(.badServerResponse))
            return
        }
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String { headers[ks.lowercased()] = "\(v)" }
        }
        let cookies = Self.setCookies(http)
        cont.resume(returning: HTTPResponse(status: http.statusCode, headers: headers, body: st.buffer, url: http.url, setCookies: cookies))
    }

    static func setCookies(_ http: HTTPURLResponse) -> [String] {
        var fields: [String: String] = [:]
        for (k, v) in http.allHeaderFields { if let ks = k as? String { fields[ks] = "\(v)" } }
        guard let url = http.url ?? URL(string: "https://localhost/") else { return [] }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        if !cookies.isEmpty { return cookies.map { "\($0.name)=\($0.value)" } }
        // Fallback: parse the raw header ourselves.
        guard let raw = fields.first(where: { $0.key.lowercased() == "set-cookie" })?.value else { return [] }
        return raw.components(separatedBy: ",").compactMap { part -> String? in
            let nv = part.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return nv.contains("=") ? nv : nil
        }
    }
}

// MARK: - Helpers

extension URLRequest {
    init(url: URL, method: String, headers: [String: String] = [:]) {
        self.init(url: url)
        httpMethod = method
        for (k, v) in headers { setValue(v, forHTTPHeaderField: k) }
    }
}

/// Wraps a transport error with context ("what: cannot reach host (...)").
func transportError(_ error: Error, what: String, host: String?) -> Error {
    if error is RemoteStorageError { return error }
    if let u = error as? URLError, u.code == .cancelled { return RemoteStorageError.cancelled }
    if error is CancellationError { return RemoteStorageError.cancelled }
    return RemoteStorageError.io("\(what): cannot reach \(host ?? "server") (\(error.localizedDescription))")
}

/// Range header value for offset/length (length < 0 = to end), or nil when the whole file is wanted.
func rangeHeader(offset: Int64, length: Int64) -> String? {
    if offset <= 0 && length < 0 { return nil }
    let start = max(0, offset)
    return length < 0 ? "bytes=\(start)-" : "bytes=\(start)-\(start + length - 1)"
}

/// Appends a query (keys and values strictly percent-encoded, '+' as %2B) to `base`.
func urlWithQuery(_ base: String, _ items: [(String, String)]) -> URL {
    let q = items.map { RemotePaths.encodeSegment($0.0) + "=" + RemotePaths.encodeSegment($0.1) }.joined(separator: "&")
    let sep = base.contains("?") ? "&" : "?"
    return URL(string: items.isEmpty ? base : base + sep + q)!
}
