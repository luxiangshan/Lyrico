import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenList / Alist v3 provider using the REST API (`/api/auth/login`, `/api/fs/{list,get,put,rename,remove}`).
///
/// `config.baseURL` is the site root (`https://host:5244`, or with a sub-path). A blank username means guest
/// access: no login, no Authorization header. The JWT token is cached in the credential store under
/// `OpenListStorage.tokenKey` and refreshed once on 401/403.
public final class OpenListStorage: RemoteStorage, @unchecked Sendable {
    public static let tokenKey = "openlist_token"
    static let pageSize = 200
    static let downloadURLTTL: TimeInterval = 4 * 60

    public let config: RemoteLocationConfig
    private let password: String
    private let strongStore: RemoteCredentialStore?
    private let base: String
    private let baseHost: String?
    private let client: HTTPClient
    private var guest: Bool { config.username.trimmingCharacters(in: .whitespaces).isEmpty }

    private let token = Locked<String?>(nil)
    private let downloadURLs = Locked<[String: ([String], Date)]>([:])
    private let loginGate = AsyncGate()

    public init(config: RemoteLocationConfig, password: String, credentialStore: RemoteCredentialStore? = nil,
                sessionConfiguration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration()) throws {
        self.config = config
        self.password = password
        self.strongStore = credentialStore
        let b = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
        let lower = b.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let u = URL(string: b + "/") else {
            throw RemoteStorageError.invalidArgument("OpenList address must start with http:// or https://")
        }
        base = b
        baseHost = u.host?.lowercased()
        client = HTTPClient(configuration: sessionConfiguration)
    }

    // MARK: auth

    private func currentToken() async throws -> String? {
        if guest { return nil }
        if let t = token.current { return t }
        if let cached = strongStore?.loadExtra(configId: config.id, key: Self.tokenKey), !cached.isEmpty {
            token.withLock { $0 = cached }
            return cached
        }
        return try await login()
    }

    private func login() async throws -> String {
        try await loginGate.run {
            var req = URLRequest(url: URL(string: self.base + "/api/auth/login")!, method: "POST")
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let body = JSONValue.object(["username": .string(self.config.username), "password": .string(self.password)])
            let (http, json) = try await self.rawCall(req, body: body.serialized(), what: "OpenList login")
            guard let json = json else { throw RemoteStorageError.io("OpenList login failed: HTTP \(http) (not an OpenList API response)") }
            let code = json["code"]?.int64Value ?? -1
            if code != 200 {
                self.invalidateToken()
                let msg = Self.message(json)
                if [400, 401, 403].contains(code) || msg.lowercased().contains("password") || msg.lowercased().contains("user") {
                    throw RemoteStorageError.auth("OpenList login failed: \(msg)")
                }
                throw RemoteStorageError.io("OpenList login failed (code \(code)): \(msg)")
            }
            guard let t = json["data"]?["token"]?.stringValue, !t.isEmpty else { throw RemoteStorageError.io("OpenList login returned no token") }
            self.token.withLock { $0 = t }
            self.strongStore?.saveExtra(configId: self.config.id, key: Self.tokenKey, value: t)
            return t
        }
    }

    private func invalidateToken() {
        token.withLock { $0 = nil }
        strongStore?.saveExtra(configId: config.id, key: Self.tokenKey, value: nil)
    }

    private static func isAuthError(_ httpCode: Int, _ json: JSONValue?) -> Bool {
        if httpCode == 401 || httpCode == 403 { return true }
        guard let c = json?["code"]?.int64Value else { return false }
        return c == 401 || c == 403
    }

    private struct APIError: Error { let code: Int64; let message: String }

    /// Calls an API endpoint with the token, re-logging in once on an auth error. Returns "data" after code == 200.
    private func api(_ what: String, body: HTTPBody, build: (String?) -> URLRequest) async throws -> JSONValue? {
        var attempt = 0
        while true {
            let tok = try await currentToken()
            let req = build(tok)
            let (httpCode, json) = try await rawCallWithStatus(req, body: body, what: what)
            if Self.isAuthError(httpCode, json) {
                if !guest && attempt == 0 {
                    attempt += 1
                    invalidateToken()
                    _ = try await login()
                    continue
                }
                let msg = json.map(Self.message) ?? "HTTP \(httpCode)"
                throw RemoteStorageError.auth(guest
                    ? "\(what): guest access denied (\(msg)). Enter an OpenList username and password."
                    : "\(what): OpenList rejected the login (\(msg))")
            }
            guard let json = json else { throw RemoteStorageError.io("\(what) failed: HTTP \(httpCode) (not an OpenList API response)") }
            let code = json["code"]?.int64Value ?? -1
            if code != 200 { throw APIError(code: code, message: "\(what) failed: \(Self.message(json))") }
            return json["data"]
        }
    }

    private func postAPI(_ what: String, _ endpoint: String, _ body: JSONValue) async throws -> JSONValue? {
        let data = body.serialized()
        return try await api(what, body: .data(data)) { tok in
            var r = URLRequest(url: URL(string: self.base + endpoint)!, method: "POST")
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            if let t = tok { r.setValue(t, forHTTPHeaderField: "Authorization") }
            return r
        }
    }

    /// Maps API errors to `RemoteStorageError` (not-found aware).
    private func mapped<T>(_ notFound: (() throws -> T)? = nil, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let e as APIError {
            if Self.isNotFound(e.message), let nf = notFound { return try nf() }
            throw RemoteStorageError.io(e.message)
        }
    }

    // MARK: operations

    public func testConnection() async throws {
        if !guest { invalidateToken(); _ = try await login() }
        _ = try await mapped { try await self.postAPI("OpenList connection", "/api/fs/list", Self.listBody("/", 1, 1)) }
    }

    public func list(_ dirPath: String) async throws -> [RemoteEntry] {
        let dir = RemotePaths.normalize(dirPath)
        var out: [RemoteEntry] = []
        var page = 1
        while true {
            let data = try await mapped({ throw RemoteStorageError.notFound("Folder not found: \(dir)") }) {
                try await self.postAPI("List \(dir)", "/api/fs/list", Self.listBody(dir, page, Self.pageSize))
            }
            guard let d = data, d.object != nil else { break }
            let content = d["content"]?.array ?? []
            for o in content {
                guard let name = o["name"]?.stringValue else { continue }
                out.append(Self.entry(RemotePaths.join(dir, name), o))
            }
            let total = d["total"]?.int64Value ?? -1
            if content.isEmpty || total < 0 || Int64(out.count) >= total || content.count < Self.pageSize { break }
            page += 1
            if page > 10_000 { break }
        }
        return out
    }

    public func stat(_ path: String) async throws -> RemoteEntry? {
        let p = RemotePaths.normalize(path)
        let data = try await mapped({ nil }) {
            try await self.postAPI("Stat \(p)", "/api/fs/get", .object(["path": .string(p), "password": .string("")]))
        }
        guard let d = data, d.object != nil else { return nil }
        return Self.entry(p, d)
    }

    public func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        if length == 0 { return Data() }
        return try await fetch(path, offset: offset, length: length, sink: .range(skip: max(0, offset), limit: length < 0 ? nil : length)).body
    }

    public func download(_ path: String, to localURL: URL) async throws {
        _ = try await fetch(path, offset: 0, length: -1, sink: .file(localURL))
    }

    private func fetch(_ path: String, offset: Int64, length: Int64, sink: HTTPSink) async throws -> HTTPResponse {
        let p = RemotePaths.normalize(path)
        // Partial reads issue many ranged requests per file: reuse resolved download URLs for a while instead of
        // calling /api/fs/get before every range; re-resolve once if a cached URL fails.
        if let cached = downloadURLs.withLock({ $0[p] }), Date().timeIntervalSince(cached.1) < Self.downloadURLTTL {
            do {
                return try await downloadFirst(cached.0, p, offset, length, sink)
            } catch let e as RemoteStorageError where e == .cancelled {
                throw e
            } catch {
                downloadURLs.withLock { $0[p] = nil }
            }
        }
        let candidates = try await resolveDownloadURLs(p)
        downloadURLs.withLock { $0[p] = (candidates, Date()) }
        return try await downloadFirst(candidates, p, offset, length, sink)
    }

    private func resolveDownloadURLs(_ p: String) async throws -> [String] {
        let data = try await mapped({ throw RemoteStorageError.notFound("File not found: \(p)") }) {
            try await self.postAPI("Read \(p)", "/api/fs/get", .object(["path": .string(p), "password": .string("")]))
        }
        guard let d = data, d.object != nil else { throw RemoteStorageError.io("Read \(p): empty response") }
        if d["is_dir"].truthy { throw RemoteStorageError.io("\(p) is a folder") }
        let sign = d["sign"]?.stringValue ?? ""
        let proxy = base + "/d" + RemotePaths.encodePath(p) + (sign.isEmpty ? "" : "?sign=" + RemotePaths.encodeSegment(sign))
        var out: [String] = []
        if let raw = d["raw_url"]?.stringValue, !raw.trimmingCharacters(in: .whitespaces).isEmpty { out.append(absolutize(raw)) }
        if !out.contains(proxy) { out.append(proxy) }
        return out
    }

    private func downloadFirst(_ candidates: [String], _ p: String, _ offset: Int64, _ length: Int64, _ sink: HTTPSink) async throws -> HTTPResponse {
        var lastError: Error?
        for u in candidates {
            do {
                return try await download(u, p, offset, length, sink)
            } catch let e as RemoteStorageError where e == .cancelled {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteStorageError.io("Read \(p) failed")
    }

    private func download(_ urlString: String, _ p: String, _ offset: Int64, _ length: Int64, _ sink: HTTPSink) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else { throw RemoteStorageError.io("Read \(p): invalid URL \(urlString)") }
        var req = URLRequest(url: url, method: "GET")
        if let r = rangeHeader(offset: offset, length: length) { req.setValue(r, forHTTPHeaderField: "Range") }
        // Token only for our own host; the redirect handler strips it on cross-host redirects.
        if url.host?.lowercased() == baseHost, let t = try await currentToken() { req.setValue(t, forHTTPHeaderField: "Authorization") }
        let r: HTTPResponse
        do { r = try await client.send(req, sink: sink) } catch { throw transportError(error, what: "Read \(p)", host: url.host) }
        if r.status == 401 || r.status == 403 {
            throw RemoteStorageError.auth("Read \(p): authentication failed (HTTP \(r.status)). Check username and password.")
        }
        if r.status == 416 { return HTTPResponse(status: 416, headers: r.headers, body: Data(), url: r.url, setCookies: []) }
        guard r.isSuccess else { throw RemoteStorageError.io("Read \(p) failed: HTTP \(r.status)" + r.snippet) }
        return r
    }

    public func upload(from localURL: URL, to path: String) async throws {
        let p = RemotePaths.normalize(path)
        downloadURLs.withLock { $0[p] = nil }
        let size = try HTTPClient.fileSize(localURL)
        _ = try await mapped {
            try await self.api("Upload \(p)", body: .file(localURL)) { tok in
                var r = URLRequest(url: URL(string: self.base + "/api/fs/put")!, method: "PUT")
                r.setValue(RemotePaths.encodePath(p), forHTTPHeaderField: "File-Path")
                r.setValue("false", forHTTPHeaderField: "As-Task")
                r.setValue("true", forHTTPHeaderField: "Overwrite")
                r.setValue(String(size), forHTTPHeaderField: "Content-Length")
                r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                if let t = tok { r.setValue(t, forHTTPHeaderField: "Authorization") }
                return r
            }
        }
    }

    public func rename(_ path: String, to newName: String) async throws -> String {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, !newName.contains("/") else {
            throw RemoteStorageError.invalidArgument("Invalid file name: \(newName)")
        }
        let p = RemotePaths.normalize(path)
        downloadURLs.withLock { $0[p] = nil }
        let dst = RemotePaths.join(RemotePaths.parent(p), newName)
        if dst == p { return p }
        _ = try await mapped { try await self.postAPI("Rename \(p)", "/api/fs/rename", .object(["path": .string(p), "name": .string(newName)])) }
        return dst
    }

    public func delete(_ path: String) async throws {
        let p = RemotePaths.normalize(path)
        downloadURLs.withLock { $0[p] = nil }
        let body = JSONValue.object(["dir": .string(RemotePaths.parent(p)), "names": .array([.string(RemotePaths.name(p))])])
        _ = try await mapped({ nil }) { try await self.postAPI("Delete \(p)", "/api/fs/remove", body) }
    }

    public func close() async { client.invalidate() }

    // MARK: helpers

    static func listBody(_ dir: String, _ page: Int, _ perPage: Int) -> JSONValue {
        .object(["path": .string(dir), "password": .string(""), "page": .int(Int64(page)), "per_page": .int(Int64(perPage)), "refresh": .bool(false)])
    }

    static func entry(_ path: String, _ o: JSONValue) -> RemoteEntry {
        let isDir = o["is_dir"].truthy
        return RemoteEntry(path: path, name: RemotePaths.name(path), isDirectory: isDir,
                           size: isDir ? -1 : (o["size"]?.int64Value ?? -1),
                           modifiedMillis: WebDAVXML.parseISO8601(o["modified"]?.stringValue ?? ""))
    }

    private static func isNotFound(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("not found") || m.contains("not exist")
    }

    private func absolutize(_ u: String) -> String {
        let l = u.lowercased()
        if l.hasPrefix("http://") || l.hasPrefix("https://") { return u }
        if u.hasPrefix("//") { return (URL(string: base)?.scheme ?? "https") + ":" + u }
        if u.hasPrefix("/") { return base + u }
        return base + "/" + u
    }

    private func rawCall(_ req: URLRequest, body: Data, what: String) async throws -> (Int, JSONValue?) {
        try await rawCallWithStatus(req, body: .data(body), what: what)
    }

    private func rawCallWithStatus(_ req: URLRequest, body: HTTPBody, what: String) async throws -> (Int, JSONValue?) {
        let r: HTTPResponse
        do { r = try await client.send(req, body: body) } catch { throw transportError(error, what: what, host: req.url?.host) }
        let json = try? JSONValue.parse(r.body)
        return (r.status, json?.object != nil ? json : nil)
    }

    private static func message(_ json: JSONValue) -> String {
        if let m = json["message"]?.stringValue, !m.trimmingCharacters(in: .whitespaces).isEmpty { return m }
        return "code \(json["code"]?.int64Value ?? 0)"
    }
}

/// Serializes async sections (one login at a time).
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !busy { busy = true; lock.unlock(); c.resume() } else { waiters.append(c); lock.unlock() }
        }
    }

    private func release() {
        lock.lock()
        if waiters.isEmpty { busy = false; lock.unlock() } else { let c = waiters.removeFirst(); lock.unlock(); c.resume() }
    }
}
