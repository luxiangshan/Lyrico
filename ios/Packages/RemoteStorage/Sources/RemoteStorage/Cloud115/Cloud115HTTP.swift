import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// All 115 endpoints. Overridable so tests can point them at a stub. Values follow SheltonZhu/115driver.
public struct Cloud115Endpoints: Sendable, Equatable {
    public var qrToken = "https://qrcodeapi.115.com/api/1.0/web/1.0/token"
    public var qrStatus = "https://qrcodeapi.115.com/get/status/"
    /// `%@` = login app, e.g. alipaymini.
    public var qrLogin = "https://passportapi.115.com/app/1.0/%@/1.0/login/qrcode"
    public var statusCheck = "https://my.115.com/?ct=guide&ac=status"
    public var files = "https://webapi.115.com/files"
    public var rename = "https://webapi.115.com/files/batch_rename"
    public var delete = "https://webapi.115.com/rb/delete"
    public var downURL = "https://proapi.115.com/app/chrome/downurl"
    public var uploadInfo = "https://proapi.115.com/app/uploadinfo"
    public var uploadInit = "https://uplb.115.com/4.0/initupload.php"
    public var ossToken = "https://uplb.115.com/3.0/gettoken.php"
    /// Virtual-hosted OSS object base; `%@` = bucket.
    public var ossHost = "https://%@.oss-cn-shenzhen.aliyuncs.com"
    /// Tests only: path-style base (`<base>/<bucket>/<object>`) instead of `ossHost`.
    public var ossPathStyleBase: String?

    public init() {}

    func ossObjectURL(bucket: String, objectKey: String, query: String = "") -> URL {
        var base: String
        if let b = ossPathStyleBase {
            base = b.trimmingTrailing("/") + "/" + RemotePaths.encodeSegment(bucket)
        } else {
            base = ossHost.replacingOccurrences(of: "%@", with: bucket)
        }
        for seg in objectKey.split(separator: "/") where !seg.isEmpty {
            base += "/" + RemotePaths.encodeSegment(String(seg))
        }
        return URL(string: base + query)!
    }
}

enum Cloud115Const {
    static let appVer = "27.0.5.7"
    /// UA OpenList's 115 driver uses for every API call (proapi rejects plain browser UAs).
    static let userAgent = "Mozilla/5.0 115Browser/\(appVer)"
    static let ossUserAgent = "aliyun-sdk-android/2.9.1"
    static let authExpiredMessage = "115 登录已失效，请重新登录"
    /// 115driver error.go: 99/990001 not login; 40101035 kicked out; 40101037 session exited.
    static let authCodes: Set<Int64> = [99, 990001, 990002, 40101035, 40101037, 40101032]
}

/// JSON helpers tolerant of 115's mixed bool/int/string fields.
enum J {
    static func parse(_ data: Data, _ what: String) throws -> JSONValue {
        do { return try JSONValue.parse(data) } catch {
            throw RemoteStorageError.io("\(what): 非 JSON 响应: \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
    }

    static func long(_ o: JSONValue?, _ keys: String...) -> Int64 {
        for k in keys { if let v = o?[k]?.int64Value { return v } }
        return 0
    }

    static func str(_ o: JSONValue?, _ keys: String...) -> String {
        for k in keys {
            if let v = o?[k], !v.isNull, let s = v.stringValue ?? (v.object != nil || v.array != nil ? v.serializedString : nil), !s.isEmpty { return s }
        }
        return ""
    }

    static func errorCode(_ o: JSONValue) -> Int64 { long(o, "errno", "errNo", "errcode", "code", "statuscode") }
    static func errorMessage(_ o: JSONValue) -> String { str(o, "error", "msg", "message", "statusmsg", "errtype") }

    /// Throws `.auth` when the payload says the cookie is no longer valid.
    static func checkAuth(_ o: JSONValue) throws {
        let ok = o["state"].truthy
        let code = errorCode(o)
        let msg = errorMessage(o)
        if Cloud115Const.authCodes.contains(code) || (!ok && (msg.contains("登录") || msg.lowercased().contains("login"))) {
            throw RemoteStorageError.auth(Cloud115Const.authExpiredMessage)
        }
    }

    /// `state` true or throws (auth-aware).
    @discardableResult
    static func requireOK(_ o: JSONValue, _ what: String) throws -> JSONValue {
        try checkAuth(o)
        if !o["state"].truthy {
            let msg = errorMessage(o)
            throw RemoteStorageError.io("\(what) 失败: \(msg.isEmpty ? "未知错误" : msg) (code \(errorCode(o)))")
        }
        return o
    }
}

/// Parsed `UID=..; CID=..; SEID=..; KID=..` credential.
public struct Cloud115Credential: Hashable, Sendable {
    public let uid: String
    public let cid: String
    public let seid: String
    public let kid: String

    public init(uid: String, cid: String, seid: String, kid: String = "") {
        self.uid = uid; self.cid = cid; self.seid = seid; self.kid = kid
    }

    public var cookie: String {
        var s = "UID=\(uid); CID=\(cid); SEID=\(seid)"
        if !kid.isEmpty { s += "; KID=\(kid)" }
        return s
    }

    /// First UID segment is the numeric user id (e.g. "123456_A1_1700000000").
    public var userId: String { String(uid.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first ?? "") }

    /// Tolerant parse; nil if UID/CID/SEID are missing (KID optional). Accepts a leading `Cookie:` header
    /// name, line breaks and quoted values, as pasted from a browser.
    public static func parse(_ cookie: String) -> Cloud115Credential? {
        var map: [String: String] = [:]
        var text = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") { text = String(text.dropFirst(7)) }
        for item in text.split(whereSeparator: { $0 == ";" || $0 == "\n" || $0 == "\r" }) {
            guard let idx = item.firstIndex(of: "="), idx != item.startIndex else { continue }
            var value = item[item.index(after: idx)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            map[item[..<idx].trimmingCharacters(in: .whitespaces).uppercased()] = value
        }
        let uid = map["UID"] ?? "", cid = map["CID"] ?? "", seid = map["SEID"] ?? ""
        if uid.isEmpty || cid.isEmpty || seid.isEmpty { return nil }
        return Cloud115Credential(uid: uid, cid: cid, seid: seid, kid: map["KID"] ?? "")
    }
}

/// Thin HTTP wrapper that attaches the 115 cookie and UA.
final class Cloud115HTTP: @unchecked Sendable {
    let client: HTTPClient
    private let lock = NSLock()
    private var _cookie: String
    let userAgent: String

    var cookie: String {
        get { lock.lock(); defer { lock.unlock() }; return _cookie }
        set { lock.lock(); _cookie = newValue; lock.unlock() }
    }

    init(client: HTTPClient, cookie: String, userAgent: String = Cloud115Const.userAgent) {
        self.client = client
        self._cookie = cookie
        self.userAgent = userAgent
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url, method: method)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let c = cookie
        if !c.trimmingCharacters(in: .whitespaces).isEmpty { r.setValue(c, forHTTPHeaderField: "Cookie") }
        return r
    }

    func send(_ req: URLRequest, body: HTTPBody = .none, sink: HTTPSink = .memory, what: String) async throws -> HTTPResponse {
        do {
            return try await client.send(req, body: body, sink: sink)
        } catch {
            throw transportError(error, what: what, host: req.url?.host)
        }
    }

    func getJSON(_ url: URL, _ what: String) async throws -> JSONValue {
        let resp = try await send(request(url), what: what)
        return try readJSON(resp, what)
    }

    func postFormJSON(_ url: URL, _ form: [(String, String)], _ what: String) async throws -> JSONValue {
        var r = request(url, method: "POST")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let resp = try await send(r, body: .data(RemotePaths.formBody(form)), what: what)
        return try readJSON(resp, what)
    }

    func readJSON(_ resp: HTTPResponse, _ what: String) throws -> JSONValue {
        let trimmed = resp.text.drop(while: { $0.isWhitespace })
        if !trimmed.hasPrefix("{") {
            let finalURL = resp.url?.absoluteString.lowercased() ?? ""
            if (resp.status == 401 && what != "上传初始化") || finalURL.contains("login") || finalURL.contains("passport") {
                throw RemoteStorageError.auth(Cloud115Const.authExpiredMessage)
            }
            throw RemoteStorageError.io("\(what): HTTP \(resp.status) \(String(resp.text.prefix(200)))")
        }
        return try J.parse(resp.body, what)
    }
}

extension String {
    func trimmingTrailing(_ c: Character) -> String {
        var s = self
        while s.last == c { s.removeLast() }
        return s
    }
}
