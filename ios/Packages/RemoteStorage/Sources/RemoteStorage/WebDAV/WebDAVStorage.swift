import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// WebDAV provider (RFC 4918 subset: PROPFIND, GET+Range, PUT, MOVE, DELETE) over URLSession, with Basic and
/// Digest auth. Tested shapes: Apache mod_dav, nginx dav(-ext), Nextcloud/ownCloud, rclone, OpenList /dav.
///
/// `config.baseURL` is the WebDAV root, e.g. `https://host/remote.php/dav/files/alice`; paths are relative to it.
public final class WebDAVStorage: RemoteStorage, @unchecked Sendable {
    public let config: RemoteLocationConfig
    private let baseURLString: String
    private let basePath: String
    private let client: HTTPClient
    private let auth: HTTPAuth

    public init(config: RemoteLocationConfig, password: String,
                sessionConfiguration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration()) throws {
        self.config = config
        let base = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailing("/")
        let lower = base.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://"), let u = URL(string: base + "/") else {
            throw RemoteStorageError.invalidArgument("WebDAV address must start with http:// or https://")
        }
        baseURLString = base
        basePath = RemotePaths.normalize(RemotePaths.percentDecode(URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"))
        client = HTTPClient(configuration: sessionConfiguration)
        auth = HTTPAuth(username: config.username, password: password)
    }

    // MARK: URLs

    func urlString(_ path: String, directory: Bool = false) -> String {
        let p = RemotePaths.normalize(path)
        if p == "/" { return baseURLString + "/" }
        return baseURLString + RemotePaths.encodePath(p) + (directory ? "/" : "")
    }

    private func url(_ path: String, directory: Bool = false) -> URL { URL(string: urlString(path, directory: directory))! }

    /// Decoded server path -> path relative to the WebDAV root, or nil when outside it.
    private func relativize(_ hrefPath: String) -> String? {
        if basePath == "/" { return hrefPath }
        if hrefPath == basePath { return "/" }
        if hrefPath.hasPrefix(basePath + "/") { return String(hrefPath.dropFirst(basePath.count)) }
        return nil
    }

    // MARK: operations

    public func testConnection() async throws {
        let r = try await propfind("/", depth: 0, directory: true)
        switch r.status {
        case 207: _ = try WebDAVXML.parseMultistatus(r.body)
        case 404: throw RemoteStorageError.io("WebDAV folder not found at \(config.baseURL)")
        case 405, 501, 200..<300:
            throw RemoteStorageError.io("Server at \(config.baseURL) does not look like WebDAV (HTTP \(r.status) to PROPFIND)")
        default: throw httpFailure("WebDAV connection", r)
        }
    }

    public func list(_ dirPath: String) async throws -> [RemoteEntry] {
        let dir = RemotePaths.normalize(dirPath)
        let r = try await propfind(dir, depth: 1, directory: true)
        if r.status == 404 { throw RemoteStorageError.notFound("Folder not found: \(dir)") }
        guard r.status == 207 else { throw httpFailure("List \(dir)", r) }
        let requestPath = WebDAVXML.hrefToPath(r.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? urlString(dir, directory: true))
        let resources = try WebDAVXML.parseMultistatus(r.body)
        let depths = resources.map { $0.hrefPath.filter { $0 == "/" }.count }
        let selfDepth = Set(depths).count > 1 ? (depths.min() ?? -1) : -1
        var out: [RemoteEntry] = []
        var seen = Set<String>()
        for (index, res) in resources.enumerated() {
            let path: String
            if let rel = relativize(res.hrefPath) {
                if rel == dir { continue }
                path = RemotePaths.parent(rel) == dir ? rel : RemotePaths.join(dir, RemotePaths.name(rel))
            } else {
                // hrefs outside the configured root (reverse proxy rewriting etc.): last segment under the folder.
                if res.hrefPath == requestPath || depths[index] == selfDepth { continue }
                path = RemotePaths.join(dir, RemotePaths.name(res.hrefPath))
            }
            let name = RemotePaths.name(path)
            if name.isEmpty || path == dir || seen.contains(path) { continue }
            seen.insert(path)
            out.append(RemoteEntry(path: path, name: name, isDirectory: res.isCollection, size: res.contentLength, modifiedMillis: res.lastModifiedMillis))
        }
        return out
    }

    public func stat(_ path: String) async throws -> RemoteEntry? {
        let p = RemotePaths.normalize(path)
        let r = try await propfind(p, depth: 0, directory: p == "/")
        if r.status == 404 { return nil }
        guard r.status == 207 else { throw httpFailure("Stat \(p)", r) }
        guard let res = try WebDAVXML.parseMultistatus(r.body).first else { return nil }
        return RemoteEntry(path: p, name: RemotePaths.name(p), isDirectory: res.isCollection, size: res.contentLength, modifiedMillis: res.lastModifiedMillis)
    }

    public func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        let p = RemotePaths.normalize(path)
        if length == 0 { return Data() }
        var req = URLRequest(url: url(p), method: "GET")
        if let range = rangeHeader(offset: offset, length: length) { req.setValue(range, forHTTPHeaderField: "Range") }
        let r = try await execute(req, what: "Read \(p)", sink: .range(skip: max(0, offset), limit: length < 0 ? nil : length))
        if r.status == 404 { throw RemoteStorageError.notFound("File not found: \(p)") }
        if r.status == 416 { return Data() }
        guard r.isSuccess else { throw httpFailure("Read \(p)", r) }
        return r.body
    }

    public func download(_ path: String, to localURL: URL) async throws {
        let p = RemotePaths.normalize(path)
        let r = try await execute(URLRequest(url: url(p), method: "GET"), what: "Read \(p)", sink: .file(localURL))
        if r.status == 404 { throw RemoteStorageError.notFound("File not found: \(p)") }
        guard r.isSuccess else { throw httpFailure("Read \(p)", r) }
    }

    public func upload(from localURL: URL, to path: String) async throws {
        let target = RemotePaths.normalize(path)
        let tmp = RemotePaths.join(RemotePaths.parent(target), ".\(RemotePaths.name(target)).lyrico-tmp")

        let tmpOK = try await put(tmp, localURL, failOnError: false)
        if !tmpOK { _ = try await put(target, localURL, failOnError: true); return }

        let moveCode = try await move(tmp, to: target, overwrite: true)
        switch moveCode {
        case 200..<300:
            return
        case 412:
            // Server refuses Overwrite:T; the new content is safe in tmp, so replace explicitly.
            try await delete(target)
            let retry = try await move(tmp, to: target, overwrite: false)
            if (200..<300).contains(retry) { return }
            throw RemoteStorageError.io("Upload of \(target) failed: MOVE from temp file returned HTTP \(retry) (new content kept at \(tmp))")
        case 405, 501, 403, 400, 502:
            // MOVE not supported/allowed: plain overwrite, then clean up.
            _ = try await put(target, localURL, failOnError: true)
            try? await delete(tmp)
        default:
            try? await delete(tmp)
            throw RemoteStorageError.io("Upload of \(target) failed: MOVE returned HTTP \(moveCode)")
        }
    }

    public func rename(_ path: String, to newName: String) async throws -> String {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, !newName.contains("/") else {
            throw RemoteStorageError.invalidArgument("Invalid file name: \(newName)")
        }
        let src = RemotePaths.normalize(path)
        let dst = RemotePaths.join(RemotePaths.parent(src), newName)
        if dst == src { return src }
        let code = try await move(src, to: dst, overwrite: false)
        switch code {
        case 200..<300: return dst
        case 412: throw RemoteStorageError.io("A file named \"\(newName)\" already exists")
        case 404: throw RemoteStorageError.notFound("File not found: \(src)")
        default: throw RemoteStorageError.io("Rename \(src) failed: HTTP \(code)")
        }
    }

    public func delete(_ path: String) async throws {
        let p = RemotePaths.normalize(path)
        let r = try await execute(URLRequest(url: url(p), method: "DELETE"), what: "Delete \(p)")
        if !r.isSuccess && r.status != 404 { throw httpFailure("Delete \(p)", r) }
    }

    public func close() async { client.invalidate() }

    // MARK: HTTP helpers

    private func propfind(_ path: String, depth: Int, directory: Bool) async throws -> HTTPResponse {
        var req = URLRequest(url: url(path, directory: directory), method: "PROPFIND")
        req.setValue(String(depth), forHTTPHeaderField: "Depth")
        req.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        return try await execute(req, what: "PROPFIND \(path)", body: .data(Data(WebDAVXML.propfindBody.utf8)))
    }

    /// true on success; false (non-auth failure) when `failOnError` is false.
    private func put(_ path: String, _ source: URL, failOnError: Bool) async throws -> Bool {
        var req = URLRequest(url: url(path), method: "PUT")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let r = try await execute(req, what: "Upload \(path)", body: .file(source))
        if r.isSuccess { return true }
        if failOnError { throw httpFailure("Upload \(path)", r) }
        return false
    }

    private func move(_ from: String, to: String, overwrite: Bool) async throws -> Int {
        var req = URLRequest(url: url(from), method: "MOVE")
        req.setValue(urlString(to), forHTTPHeaderField: "Destination")
        req.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        return try await execute(req, what: "Move \(from)").status
    }

    private func requestURI(_ url: URL) -> String {
        let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = c?.percentEncodedPath ?? url.path
        if let q = c?.percentEncodedQuery { return path + "?" + q }
        return path
    }

    /// Executes with Basic/Digest handling; maps a final 401 to `.auth`.
    private func execute(_ request: URLRequest, what: String, body: HTTPBody = .none, sink: HTTPSink = .memory) async throws -> HTTPResponse {
        let method = request.httpMethod ?? "GET"
        let uri = requestURI(request.url!)
        var req = request
        if let h = auth.preemptiveHeader(method: method, uri: uri) { req.setValue(h, forHTTPHeaderField: "Authorization") }
        var attempts = 0
        while true {
            let r: HTTPResponse
            do {
                r = try await client.send(req, body: body, sink: sink)
            } catch {
                throw transportError(error, what: what, host: request.url?.host)
            }
            if r.status == 401 {
                let challenges = r.header("WWW-Authenticate").map { [$0] } ?? []
                if let h = auth.respond(to: challenges, method: method, uri: uri, sentAuth: req.value(forHTTPHeaderField: "Authorization"),
                                        priorAttempts: attempts) {
                    attempts += 1
                    req.setValue(h, forHTTPHeaderField: "Authorization")
                    continue
                }
                throw RemoteStorageError.auth("\(what): WebDAV login rejected (HTTP 401). Check username and password.")
            }
            if r.status == 403 && method == "PROPFIND" && req.value(forHTTPHeaderField: "Authorization") == nil && config.username.isEmpty {
                throw RemoteStorageError.auth("\(what): access denied (HTTP 403); this server probably needs a username and password.")
            }
            return r
        }
    }

    private func httpFailure(_ what: String, _ r: HTTPResponse) -> RemoteStorageError {
        .io("\(what) failed: HTTP \(r.status) \(HTTPURLResponse.localizedString(forStatusCode: r.status))".trimmingCharacters(in: .whitespaces) + r.snippet)
    }
}
