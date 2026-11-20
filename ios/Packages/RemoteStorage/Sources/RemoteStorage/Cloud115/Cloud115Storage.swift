import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 115 cloud storage using a 115 session cookie (from `Cloud115QRLogin`, the web login, or pasted manually).
/// UID, CID and SEID are required; KID is optional.
///
/// Protocol follows SheltonZhu/115driver (as the Android `Cloud115Storage.kt`):
///  - listing: `webapi.115.com/files` (paged); path -> cid resolved by walking folders, cached
///  - download: `proapi.115.com/app/chrome/downurl` with an m115-encrypted payload; the CDN URL is fetched with the
///    same User-Agent and cookies (incl. Set-Cookie from downurl)
///  - upload: rapid upload (`initupload.php` 4.0, ECDH/AES, sha1 + sign_check) else Aliyun OSS (simple PUT,
///    multipart above 100 MiB) with 115's callback. 115 has no overwrite, so the new file is uploaded under a
///    temporary name, then the old file is deleted (to the recycle bin) and the new one renamed.
///  - rename `files/batch_rename`, delete `rb/delete`.
/// Cookie expiry -> `RemoteStorageError.auth("115 登录已失效，请重新登录")`.
public final class Cloud115Storage: RemoteStorage, @unchecked Sendable {
    struct Node: Equatable {
        let entry: RemoteEntry
        /// fid for files, cid for folders.
        let id: String
        let parentId: String
        let pickCode: String
        let sha1: String
    }

    private struct Listing { let at: Int64; let nodes: [Node] }
    struct DownURL { let url: String; let cookie: String; let at: Int64 }
    private struct UploadInfo { let userId: String; let userKey: String; let sizeLimit: Int64 }

    public static let rootId = "0"
    static let pageLimit = 1000 // 115driver MaxDirPageLimit = 1150
    public static let tmpPrefix = ".lyrico_upload_"

    public let config: RemoteLocationConfig
    private let endpoints: Cloud115Endpoints
    private let client: HTTPClient
    private let credential: Cloud115Credential?
    private let http: Cloud115HTTP
    private let oss: Cloud115OSS

    private let dirIds = Locked<[String: String]>(["/": Cloud115Storage.rootId])
    private let listings = Locked<[String: Listing]>([:])
    private let downURLs = Locked<[String: DownURL]>([:])
    private let uploadInfo = Locked<UploadInfo?>(nil)

    // Test seams (the server side of m115/ECDH can't be reproduced without 115's private keys).
    var listingTTLMillis: Int64 = 30_000
    var downURLTTLMillis: Int64 = 10 * 60_000
    var retryDelay: TimeInterval = 1
    var now: () -> Int64 = { nowMillis() }
    var m115Decode: (String, [UInt8]) throws -> [UInt8] = { try M115.decode($0, key: $1) }
    var cipherFactory: () -> Ec115Cipher = { Ec115Cipher.create() }

    /// - Parameters:
    ///   - cookie: the 115 session cookie (the location's secret).
    public init(config: RemoteLocationConfig, cookie: String, endpoints: Cloud115Endpoints = Cloud115Endpoints(),
                sessionConfiguration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration()) {
        self.config = config
        self.endpoints = endpoints
        self.client = HTTPClient(configuration: sessionConfiguration)
        self.credential = Cloud115Credential.parse(cookie)
        self.http = Cloud115HTTP(client: client, cookie: credential?.cookie ?? "")
        self.oss = Cloud115OSS(client: client, endpoints: endpoints)
    }

    private func requireCredential() throws {
        if credential == nil { throw RemoteStorageError.auth("115 未登录或 Cookie 不完整（需要 UID、CID、SEID），请重新登录") }
    }

    // MARK: RemoteStorage

    public func testConnection() async throws {
        try requireCredential()
        do {
            let o = try await http.getJSON(URL(string: endpoints.statusCheck)!, "检查登录状态")
            try J.checkAuth(o)
            if o["state"] != nil && !o["state"].truthy { throw RemoteStorageError.auth(Cloud115Const.authExpiredMessage) }
        } catch let e as RemoteStorageError where e.isAuth || e == .cancelled {
            throw e
        } catch {
            // status page unreachable/non-JSON: fall through to the files API, which is authoritative
        }
        _ = try await fetchPage(cid: Self.rootId, offset: 0, limit: 1)
    }

    public func list(_ dir: String) async throws -> [RemoteEntry] {
        try await listNodes(Self.normalize(dir), fresh: true).map(\.entry)
    }

    public func stat(_ path: String) async throws -> RemoteEntry? {
        try await findNode(Self.normalize(path), fresh: false)?.entry
    }

    public func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        guard offset >= 0 else { throw RemoteStorageError.invalidArgument("offset < 0") }
        let node = try await requireFile(Self.normalize(path))
        if length == 0 { return Data() }
        if offset > 0 && node.entry.size >= 0 && node.entry.size <= offset { return Data() }
        return try await fetch(node, offset: offset, length: length, sink: .range(skip: offset, limit: length > 0 ? length : nil)).body
    }

    public func download(_ path: String, to localURL: URL) async throws {
        let node = try await requireFile(Self.normalize(path))
        let resp = try await fetch(node, offset: 0, length: -1, sink: .file(localURL))
        if resp.status == 416 { try writeFileAtomically(Data(), to: localURL) }
    }

    private func fetch(_ node: Node, offset: Int64, length: Int64, sink: HTTPSink) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            let du = try await downloadURL(pickCode: node.pickCode, fresh: attempt > 0)
            guard let url = URL(string: du.url) else { throw RemoteStorageError.io("115 下载链接无效") }
            var r = http.request(url)
            r.setValue(du.cookie, forHTTPHeaderField: "Cookie")
            if offset > 0 || length > 0 {
                let end = length > 0 ? String(offset + length - 1) : ""
                r.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            }
            let resp = try await http.send(r, sink: sink, what: "115 下载")
            if [403, 404, 410].contains(resp.status) && attempt == 0 {
                attempt += 1
                continue // signed URL expired: fetch a fresh one once
            }
            if resp.status == 416 { return HTTPResponse(status: 416, headers: resp.headers, body: Data(), url: resp.url, setCookies: []) }
            if resp.status != 200 && resp.status != 206 {
                throw RemoteStorageError.io("115 下载失败: HTTP \(resp.status) \(String(resp.text.prefix(200)))")
            }
            return resp
        }
    }

    public func upload(from localURL: URL, to path: String) async throws {
        try requireCredential()
        let p = Self.normalize(path)
        guard p != "/" else { throw RemoteStorageError.invalidArgument("cannot upload to root path") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw RemoteStorageError.notFound(localURL.path)
        }
        let name = Self.baseName(p)
        let parentPath = Self.parentOf(p)
        let cid = try await resolveDirId(parentPath)
        let old = try await listNodes(parentPath, fresh: true).first { $0.entry.name == name }
        if let old = old, old.entry.isDirectory { throw RemoteStorageError.io("目标是文件夹: \(p)") }

        let digest = try Cloud115Hash.digest(file: localURL)
        if let old = old, old.sha1.caseInsensitiveCompare(digest.sha1) == .orderedSame, old.entry.size == digest.size { return } // unchanged

        let info = try await ensureUploadInfo()
        if info.sizeLimit > 0 && digest.size > info.sizeLimit { throw RemoteStorageError.io("文件超过 115 上传大小限制") }

        let tmpName = Self.tmpPrefix + String(now()) + "_" + name
        let initResp = try await initUpload(cid: cid, fileName: tmpName, digest: digest, file: localURL, info: info)
        var newFileId = ""
        switch J.long(initResp, "status") {
        case 2:
            break // rapid upload hit
        case 1:
            let cb = initResp["callback"]
            let target = OSSTarget(bucket: J.str(initResp, "bucket"), objectKey: J.str(initResp, "object"),
                                   callback: J.str(cb, "callback"), callbackVar: J.str(cb, "callback_var"))
            if target.bucket.isEmpty || target.objectKey.isEmpty { throw RemoteStorageError.io("115 上传初始化缺少 OSS 参数") }
            let body: String
            if digest.size > Cloud115OSS.multipartThreshold {
                body = try await oss.multipartUpload(target: target, tokenProvider: { try await self.ossToken() }, file: localURL)
            } else {
                body = try await oss.putObject(target: target, token: try await ossToken(), file: localURL, md5Base64: digest.md5Base64)
            }
            newFileId = try Self.parseCallback(body)
        default:
            throw RemoteStorageError.io("115 上传初始化返回未知状态: \(J.str(initResp, "status")) \(J.errorMessage(initResp))")
        }

        // Locate the new file (fresh listing; tolerate a little server-side lag)
        invalidate(parentPath)
        var newNode: Node?
        for _ in 0..<4 {
            newNode = try await listNodes(parentPath, fresh: true).first {
                (!newFileId.isEmpty && $0.id == newFileId) || $0.entry.name == tmpName
            }
            if newNode != nil { break }
            if retryDelay > 0 { try await Task.sleep(nanoseconds: UInt64(retryDelay * 1e9)) }
        }
        guard let created = newNode else { throw RemoteStorageError.io("115 上传后未找到新文件 \(tmpName)") }

        if let old = old {
            do {
                try await deleteIds([old.id])
            } catch {
                try? await deleteIds([created.id]) // keep the original intact, drop the temp copy
                throw error
            }
        }
        defer { invalidate(parentPath) }
        do {
            try await renameId(created.id, name)
        } catch {
            throw RemoteStorageError.io("新文件已上传为 \(tmpName)，但重命名为 \(name) 失败: \((error as? RemoteStorageError)?.message ?? error.localizedDescription)")
        }
    }

    public func rename(_ path: String, to newName: String) async throws -> String {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty, !newName.contains("/") else {
            throw RemoteStorageError.invalidArgument("invalid name")
        }
        let p = Self.normalize(path)
        guard let node = try await findNode(p, fresh: true) else { throw RemoteStorageError.notFound(p) }
        if node.entry.name == newName { return p }
        try await renameId(node.id, newName)
        let parent = Self.parentOf(p)
        invalidate(parent)
        if node.entry.isDirectory { dropSubtree(p) }
        return Self.join(parent, newName)
    }

    public func delete(_ path: String) async throws {
        let p = Self.normalize(path)
        guard p != "/" else { throw RemoteStorageError.invalidArgument("cannot delete root") }
        guard let node = try await findNode(p, fresh: true) else { throw RemoteStorageError.notFound(p) }
        try await deleteIds([node.id])
        invalidate(Self.parentOf(p))
        if node.entry.isDirectory { dropSubtree(p) }
    }

    public func close() async {
        listings.withLock { $0.removeAll() }
        downURLs.withLock { $0.removeAll() }
        client.invalidate()
    }

    // MARK: listing / resolve

    func resolveDirId(_ dirPath: String) async throws -> String {
        let p = Self.normalize(dirPath)
        if let id = dirIds.withLock({ $0[p] }) { return id }
        let parent = Self.parentOf(p)
        let name = Self.baseName(p)
        _ = try await resolveDirId(parent)
        var child = try await listNodes(parent, fresh: false).first { $0.entry.isDirectory && $0.entry.name == name }
        if child == nil { child = try await listNodes(parent, fresh: true).first { $0.entry.isDirectory && $0.entry.name == name } }
        guard let found = child else { throw RemoteStorageError.notFound("115 目录不存在: \(p)") }
        dirIds.withLock { $0[p] = found.id }
        return found.id
    }

    func findNode(_ p: String, fresh: Bool) async throws -> Node? {
        if p == "/" {
            return Node(entry: RemoteEntry(path: "/", name: "", isDirectory: true, providerId: Self.rootId), id: Self.rootId, parentId: "", pickCode: "", sha1: "")
        }
        let nodes: [Node]
        do {
            nodes = try await listNodes(Self.parentOf(p), fresh: fresh)
        } catch let e as RemoteStorageError where e.isNotFound {
            return nil
        }
        let name = Self.baseName(p)
        return nodes.first { $0.entry.name == name }
    }

    private func requireFile(_ p: String) async throws -> Node {
        var n = try await findNode(p, fresh: false)
        if n == nil { n = try await findNode(p, fresh: true) }
        guard let node = n else { throw RemoteStorageError.notFound(p) }
        if node.entry.isDirectory { throw RemoteStorageError.io("是文件夹: \(p)") }
        if node.pickCode.isEmpty { throw RemoteStorageError.io("115 文件缺少 pick code: \(p)") }
        return node
    }

    func listNodes(_ dirPath: String, fresh: Bool) async throws -> [Node] {
        try requireCredential()
        let p = Self.normalize(dirPath)
        if !fresh, let l = listings.withLock({ $0[p] }), now() - l.at < listingTTLMillis { return l.nodes }
        let cid = try await resolveDirId(p)
        var out: [Node] = []
        var offset = 0
        while true {
            let page: JSONValue
            do {
                page = try await fetchPage(cid: cid, offset: offset, limit: Self.pageLimit)
            } catch let e as RemoteStorageError where e.isNotFound {
                dropSubtree(p)
                throw RemoteStorageError.notFound("115 目录不存在: \(p)")
            }
            let data = page["data"]?.array ?? []
            for item in data { if let node = Self.parseNode(item, dirPath: p) { out.append(node) } }
            let count = Int(J.long(page, "count"))
            offset = Int(J.long(page, "offset")) + Self.pageLimit
            if data.isEmpty || offset >= count { break }
        }
        let snapshot = out
        dirIds.withLock { ids in for n in snapshot where n.entry.isDirectory { ids[n.entry.path] = n.id } }
        listings.withLock { $0[p] = Listing(at: now(), nodes: snapshot) }
        return out
    }

    /// One page of `webapi.115.com/files`; throws `.notFound` if the cid doesn't exist.
    func fetchPage(cid: String, offset: Int, limit: Int) async throws -> JSONValue {
        let url = urlWithQuery(endpoints.files, [
            ("aid", "1"), ("cid", cid), ("o", "user_ptime"), ("asc", "1"), ("offset", String(offset)), ("show_dir", "1"),
            ("limit", String(limit)), ("snap", "0"), ("natsort", "0"), ("record_open_time", "1"), ("format", "json"), ("fc_mix", "0"),
        ])
        let o = try J.requireOK(try await http.getJSON(url, "列出目录"), "列出目录")
        // 115 silently falls back to root for an unknown cid (115driver GetFiles checks this)
        let got = J.str(o, "cid")
        if !got.isEmpty && got != cid { throw RemoteStorageError.notFound("115 目录 id 不存在: \(cid)") }
        return o
    }

    // MARK: download URL

    private func downloadURL(pickCode: String, fresh: Bool) async throws -> DownURL {
        if !fresh, let d = downURLs.withLock({ $0[pickCode] }), now() - d.at < downURLTTLMillis { return d }
        try requireCredential()
        let key = M115.generateKey()
        let payload = Array("{\"pickcode\":\"\(pickCode)\"}".utf8)
        var r = http.request(urlWithQuery(endpoints.downURL, [("t", String(now() / 1000))]), method: "POST")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = "data=" + RemotePaths.formEncode(M115.encode(payload, key: key))
        let resp = try await http.send(r, body: .data(Data(form.utf8)), what: "获取下载链接")
        let o = try http.readJSON(resp, "获取下载链接")
        try J.requireOK(o, "获取下载链接")
        guard case .string(let enc)? = o["data"] else { throw RemoteStorageError.io("获取下载链接失败: 无数据") }
        let decoded = String(decoding: try m115Decode(enc, key), as: UTF8.self)
        let url = try Self.parseDownURL(decoded)
        let cookie = ([http.cookie] + resp.setCookies).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "; ")
        let du = DownURL(url: url, cookie: cookie, at: now())
        downURLs.withLock { $0[pickCode] = du }
        return du
    }

    // MARK: upload

    private func ensureUploadInfo() async throws -> UploadInfo {
        if let i = uploadInfo.current, !i.userKey.isEmpty { return i }
        let o = try J.requireOK(try await http.postFormJSON(URL(string: endpoints.uploadInfo)!, [], "获取上传信息"), "获取上传信息")
        let uid = J.long(o, "user_id")
        let key = J.str(o, "userkey")
        if uid == 0 || key.isEmpty { throw RemoteStorageError.io("获取上传信息失败: 缺少 user_id/userkey") }
        let info = UploadInfo(userId: String(uid), userKey: key, sizeLimit: J.long(o, "size_limit"))
        uploadInfo.withLock { $0 = info }
        return info
    }

    /// initupload.php 4.0 with the sign_check second round (status 7).
    private func initUpload(cid: String, fileName: String, digest d: Cloud115Hash.Digest, file: URL, info: UploadInfo) async throws -> JSONValue {
        let target = "U_1_\(cid)"
        let sizeStr = String(d.size)
        var signKey = "", signVal = ""
        let cipher = cipherFactory()
        for round in 0..<4 {
            let t = String(now())
            var form: [(String, String)] = [
                ("appid", "0"), ("appversion", Cloud115Const.appVer), ("userid", info.userId),
                ("filename", fileName), ("filesize", sizeStr), ("fileid", d.sha1),
                ("target", target), ("sig", Cloud115Hash.uploadSignature(userId: info.userId, userKey: info.userKey, fileId: d.sha1, target: target)),
                ("topupload", "true"), ("t", t),
                ("token", Cloud115Hash.uploadToken(userId: info.userId, fileId: d.sha1, fileSize: sizeStr, signKey: signKey, signVal: signVal,
                                                   timestamp: t, appVer: Cloud115Const.appVer)),
            ]
            if !signKey.isEmpty && !signVal.isEmpty { form += [("sign_key", signKey), ("sign_val", signVal)] }
            let encoded = form.map { RemotePaths.formEncode($0.0) + "=" + RemotePaths.formEncode($0.1) }.joined(separator: "&")
            var r = http.request(urlWithQuery(endpoints.uploadInit, [("k_ec", cipher.encodeToken(timestamp: Int64(t) ?? 0))]), method: "POST")
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let resp = try await http.send(r, body: .data(Data(cipher.encrypt(Array(encoded.utf8)))), what: "上传初始化")
            if resp.status == 401 && round < 3 { continue } // p115client: occasional 401, just retry
            guard resp.isSuccess else { throw RemoteStorageError.io("115 上传初始化失败: HTTP \(resp.status)") }
            let o = try J.parse(Data(try cipher.decrypt(Array(resp.body))), "上传初始化")
            try J.checkAuth(o)
            let code = J.long(o, "statuscode")
            if code != 0 && code != 701 { throw RemoteStorageError.io("115 上传初始化失败: \(J.errorMessage(o)) (\(code))") }
            if J.long(o, "status") == 7 {
                signKey = J.str(o, "sign_key")
                signVal = try Cloud115Hash.rangeSha1(file: file, rangeSpec: J.str(o, "sign_check"))
                continue
            }
            return o
        }
        throw RemoteStorageError.io("115 上传初始化失败: 校验轮次过多")
    }

    private func ossToken() async throws -> OSSToken {
        let o = try await http.getJSON(URL(string: endpoints.ossToken)!, "获取 OSS 令牌")
        try J.checkAuth(o)
        if J.str(o, "StatusCode") != "200" { throw RemoteStorageError.io("获取 OSS 令牌失败: \(String(o.serializedString.prefix(200)))") }
        return OSSToken(accessKeyId: J.str(o, "AccessKeyID"), accessKeySecret: J.str(o, "AccessKeySecret"), securityToken: J.str(o, "SecurityToken"))
    }

    // MARK: mutations

    private func renameId(_ id: String, _ newName: String) async throws {
        try J.requireOK(try await http.postFormJSON(URL(string: endpoints.rename)!,
                                                     [("fid", id), ("file_name", newName), ("files_new_name[\(id)]", newName)], "重命名"), "重命名")
    }

    private func deleteIds(_ ids: [String]) async throws {
        try J.requireOK(try await http.postFormJSON(URL(string: endpoints.delete)!,
                                                     ids.enumerated().map { ("fid[\($0.offset)]", $0.element) }, "删除"), "删除")
    }

    // MARK: cache helpers

    private func invalidate(_ dirPath: String) {
        let p = Self.normalize(dirPath)
        listings.withLock { $0[p] = nil }
    }

    private func dropSubtree(_ p: String) {
        let prefix = p == "/" ? "/" : p + "/"
        dirIds.withLock { ids in for k in ids.keys where k != "/" && (k == p || k.hasPrefix(prefix)) { ids[k] = nil } }
        listings.withLock { l in for k in l.keys where k == p || k.hasPrefix(prefix) { l[k] = nil } }
    }

    // MARK: static helpers

    public static func normalize(_ path: String) -> String {
        "/" + path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }

    public static func parentOf(_ p: String) -> String { RemotePaths.parent(normalize(p)) }
    public static func baseName(_ p: String) -> String { RemotePaths.name(normalize(p)) }
    public static func join(_ dir: String, _ name: String) -> String { normalize(dir + "/" + name) }

    /// File: has "fid" (its parent is "cid"); folder: no "fid", own id "cid", parent "pid".
    static func parseNode(_ o: JSONValue, dirPath: String) -> Node? {
        let name = J.str(o, "n", "file_name")
        if name.isEmpty { return nil }
        let fid = J.str(o, "fid")
        let isDir = fid.isEmpty
        let id = isDir ? J.str(o, "cid") : fid
        let parent = isDir ? J.str(o, "pid") : J.str(o, "cid")
        let entry = RemoteEntry(path: join(dirPath, name), name: name, isDirectory: isDir, size: isDir ? -1 : J.long(o, "s"),
                                modifiedMillis: parseTime(o), providerId: id)
        return Node(entry: entry, id: id, parentId: parent, pickCode: J.str(o, "pc"), sha1: J.str(o, "sha"))
    }

    /// "te"/"tu" are unix seconds when present; "t" is unix seconds or "yyyy-MM-dd HH:mm" (UTC+8).
    static func parseTime(_ o: JSONValue) -> Int64 {
        for k in ["te", "tu", "t"] {
            let s = J.str(o, k).trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            if let v = Int64(s), v > 0 { return v * 1000 }
            for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
                f.dateFormat = fmt
                f.isLenient = false
                if let d = f.date(from: s) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
            }
        }
        return 0
    }

    /// Decoded downurl data: `{"<fid>":{"file_name":..,"file_size":..,"pick_code":..,"url":{"url":..}|false}}`.
    static func parseDownURL(_ decoded: String) throws -> String {
        let root = try J.parse(Data(decoded.utf8), "下载链接")
        for (_, info) in root.object ?? [:] {
            guard info.object != nil else { continue }
            if J.long(info, "file_size") < 0 { continue }
            var url = ""
            switch info["url"] {
            case .object?: url = J.str(info["url"], "url")
            case .string(let s)?: url = s
            default: break
            }
            if !url.isEmpty { return url }
        }
        throw RemoteStorageError.io("115 无法获取下载链接（文件可能已删除或违规）")
    }

    /// OSS callback body -> new file id ("" if absent). Throws if 115 reports failure.
    static func parseCallback(_ body: String) throws -> String {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") else { return "" }
        let o = try J.parse(Data(t.utf8), "上传回调")
        if o["state"] != nil && !o["state"].truthy {
            throw RemoteStorageError.io("115 上传回调失败: \(J.errorMessage(o)) (code \(J.errorCode(o)))")
        }
        return J.str(o["data"], "file_id")
    }
}
