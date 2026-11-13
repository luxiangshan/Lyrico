import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 115 QR-code login.
///
/// Flow (115driver qrcode.go, p115client p115qrcode):
///  1. `start()` -> `Session`; render `Session.qrContent` as a QR code (see `Cloud115QRLoginModel`).
///  2. call `poll(_:)` repeatedly (server long-polls) until `.confirmed`, `.expired` or `.cancelled`; or `awaitCookie`.
///  3. `login(_:)` exchanges the confirmed session for cookies: `UID=..; CID=..; SEID=..; KID=..`.
///
/// `app` is the device slot the new session occupies. 115 allows one session per slot, so "android"/"ios" would
/// kick the user's phone app. Default "alipaymini" (115生活 支付宝小程序) only kicks a session of that mini-program.
public final class Cloud115QRLogin: @unchecked Sendable {
    public struct Session: Hashable, Sendable {
        public let uid: String
        public let time: Int64
        public let sign: String
        public let qrContent: String
        public init(uid: String, time: Int64, sign: String, qrContent: String) {
            self.uid = uid; self.time = time; self.sign = sign; self.qrContent = qrContent
        }
    }

    public enum Status: String, Sendable { case waiting, scanned, confirmed, expired, cancelled }

    public static let defaultApp = "alipaymini"

    private let app: String
    private let endpoints: Cloud115Endpoints
    private let http: Cloud115HTTP
    var pollGap: TimeInterval = 1

    public init(app: String = Cloud115QRLogin.defaultApp, endpoints: Cloud115Endpoints = Cloud115Endpoints(),
                sessionConfiguration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration()) {
        self.app = app
        self.endpoints = endpoints
        self.http = Cloud115HTTP(client: HTTPClient(configuration: sessionConfiguration), cookie: "")
    }

    /// Requests a new QR token.
    public func start() async throws -> Session {
        let o = try await http.getJSON(URL(string: endpoints.qrToken)!, "获取二维码")
        guard o["state"].truthy else { throw RemoteStorageError.io("获取二维码失败: \(J.errorMessage(o))") }
        guard let d = o["data"], d.object != nil else { throw RemoteStorageError.io("获取二维码失败: 缺少 data") }
        let uid = J.str(d, "uid")
        guard !uid.isEmpty else { throw RemoteStorageError.io("获取二维码失败: 缺少 uid") }
        let content = J.str(d, "qrcode")
        return Session(uid: uid, time: J.long(d, "time"), sign: J.str(d, "sign"),
                       qrContent: content.isEmpty ? "https://115.com/scan/dg-\(uid)" : content)
    }

    /// One status check. The server long-polls; a timeout counts as `.waiting`.
    public func poll(_ session: Session) async throws -> Status {
        let url = urlWithQuery(endpoints.qrStatus, [
            ("uid", session.uid), ("time", String(session.time)), ("sign", session.sign),
            ("_", String(Int64(Date().timeIntervalSince1970))),
        ])
        let resp: HTTPResponse
        do {
            resp = try await http.client.send(http.request(url))
        } catch let u as URLError where u.code == .timedOut {
            return .waiting
        } catch {
            throw transportError(error, what: "查询扫码状态", host: url.host)
        }
        let o = try http.readJSON(resp, "查询扫码状态")
        return try Self.parseStatus(o)
    }

    /// Exchanges a confirmed session for the cookie string.
    public func login(_ session: Session) async throws -> String {
        let url = URL(string: endpoints.qrLogin.replacingOccurrences(of: "%@", with: app))!
        let o = try await http.postFormJSON(url, [("account", session.uid), ("app", app)], "扫码登录")
        return try Self.parseLoginCookie(o)
    }

    /// Polls until confirmed, then logs in. Returns the cookie, or nil if the code expired / was cancelled,
    /// the task was cancelled, or `timeout` elapsed.
    public func awaitCookie(_ session: Session, timeout: TimeInterval = 300, onStatus: @escaping @Sendable (Status) -> Void = { _ in }) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Status?
        while !Task.isCancelled && Date() < deadline {
            let s = try await poll(session)
            if s != last { onStatus(s); last = s }
            switch s {
            case .confirmed: return try await login(session)
            case .expired, .cancelled: return nil
            default:
                if pollGap > 0 { try? await Task.sleep(nanoseconds: UInt64(pollGap * 1e9)) }
            }
        }
        return nil
    }

    static func parseStatus(_ o: JSONValue) throws -> Status {
        if let d = o["data"], d["status"] != nil {
            switch J.long(d, "status") {
            case 0: return .waiting
            case 1: return .scanned
            case 2: return .confirmed
            case -1: return .expired
            case -2: return .cancelled
            default: return .waiting
            }
        }
        if !o["state"].truthy {
            let msg = J.errorMessage(o)
            if msg.contains("过期") || msg.lowercased().contains("expire") { return .expired }
            throw RemoteStorageError.io("查询扫码状态失败: \(msg)")
        }
        return .waiting
    }

    static func parseLoginCookie(_ o: JSONValue) throws -> String {
        guard o["state"].truthy else {
            let m = J.errorMessage(o)
            throw RemoteStorageError.io("扫码登录失败: \(m.isEmpty ? "code \(J.errorCode(o))" : m)")
        }
        guard let c = o["data"]?["cookie"], c.object != nil else { throw RemoteStorageError.io("扫码登录失败: 响应缺少 cookie") }
        let cred = Cloud115Credential(uid: J.str(c, "UID"), cid: J.str(c, "CID"), seid: J.str(c, "SEID"), kid: J.str(c, "KID"))
        if cred.uid.isEmpty || cred.cid.isEmpty || cred.seid.isEmpty { throw RemoteStorageError.io("扫码登录失败: cookie 不完整") }
        return cred.cookie
    }
}
