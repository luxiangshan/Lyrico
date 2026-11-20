import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors raised by host API functions. The description mirrors the Java exception `toString()`
/// that Android plugins see in `"Host API call failed: <name>: <reason>"`.
public enum HostCallError: Error, CustomStringConvertible {
    case argument(String)
    case state(String)
    case io(String)
    case other(String)

    public var description: String {
        switch self {
        case .argument(let m): return "java.lang.IllegalArgumentException: \(m)"
        case .state(let m): return "java.lang.IllegalStateException: \(m)"
        case .io(let m): return m
        case .other(let m): return m
        }
    }
}

/// Information returned by `app.info` (defaults match the Android host).
public struct HostAppInfo: Hashable, Sendable {
    public var name: String
    public var packageName: String
    public var versionName: String
    public var versionCode: Int64
    public var buildType: String
    public var debug: Bool
    public init(name: String = "Lyrico", packageName: String = "com.lonx.lyrico", versionName: String = "0.0.0",
                versionCode: Int64 = 0, buildType: String = "unknown", debug: Bool = false) {
        self.name = name; self.packageName = packageName; self.versionName = versionName
        self.versionCode = versionCode; self.buildType = buildType; self.debug = debug
    }

    public var userAgent: String { "\(name)/\(versionName)" }
}

public enum PluginLogLevel: String, Sendable { case debug, info, warning, error }

/// Receives plugin `Platform.log.*` output and runtime diagnostics.
public typealias PluginLogHandler = @Sendable (_ level: PluginLogLevel, _ pluginId: String, _ tag: String, _ message: String) -> Void

/// Shared environment for all plugin runtimes created by a `PluginManager`.
public struct PluginHostEnvironment: @unchecked Sendable {
    public var appInfo: HostAppInfo
    /// Root directory for per-plugin `Platform.cache` files (nil disables the cache, like Android).
    public var cacheRoot: URL?
    /// URLSession configuration used for plugin HTTP (inject `protocolClasses` for tests).
    public var sessionConfiguration: () -> URLSessionConfiguration
    /// Preferred UI languages (BCP 47), first = most preferred.
    public var localePreferences: @Sendable () -> [String]
    /// Default per-call timeout in milliseconds (Android: 15000).
    public var timeoutMs: Int64
    public var engineVersion: String?
    public var logHandler: PluginLogHandler?

    public init(appInfo: HostAppInfo = HostAppInfo(), cacheRoot: URL? = nil,
                sessionConfiguration: @escaping () -> URLSessionConfiguration = { URLSessionConfiguration.ephemeral },
                localePreferences: @escaping @Sendable () -> [String] = { Locale.preferredLanguages },
                timeoutMs: Int64 = 15_000, engineVersion: String? = nil, logHandler: PluginLogHandler? = nil) {
        self.appInfo = appInfo; self.cacheRoot = cacheRoot; self.sessionConfiguration = sessionConfiguration
        self.localePreferences = localePreferences; self.timeoutMs = timeoutMs; self.engineVersion = engineVersion
        self.logHandler = logHandler
    }
}

/// Port of `QuickJsHostApi`: dispatches `__lyricoHostCall(name, payloadJson)` and returns `{"value": ...}` JSON.
final class HostApi: @unchecked Sendable {
    let pluginId: String
    private let strings: PluginStrings?
    private let environment: PluginHostEnvironment
    private let engineName: String
    private lazy var http = HostHTTPClient(configuration: environment.sessionConfiguration())
    private let cancelLock = NSLock()
    private var cancelled = false
    private var cancelActiveHTTP: (() -> Void)?
    private var deadline: Date?
    private var snapshot: PluginStrings.Snapshot?

    init(pluginId: String, strings: PluginStrings?, environment: PluginHostEnvironment, engineName: String = "javascriptcore") {
        self.pluginId = pluginId
        self.strings = strings
        self.environment = environment
        self.engineName = engineName
    }

    deinit { if httpCreated { http.invalidate() } }
    private var httpCreated = false

    var isCancelled: Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled }

    func resetCancellation() { cancelLock.lock(); cancelled = false; cancelLock.unlock() }

    func cancelInvocation() {
        cancelLock.lock()
        cancelled = true
        let cancel = cancelActiveHTTP
        cancelLock.unlock()
        cancel?()
    }

    func beginInvocation(timeoutMs: Int64) {
        deadline = timeoutMs > 0 ? Date().addingTimeInterval(Double(timeoutMs) / 1000) : nil
        snapshot = strings?.snapshot(environment.localePreferences())
    }

    var invocationDeadline: Date? { deadline }

    // MARK: Dispatch

    func call(_ name: String, _ payloadJSON: String) throws -> String {
        let payload: JSONObject = (try? JSONValue.parse(payloadJSON))?.objectValue ?? JSONObject()
        switch name {
        case "i18n.getLocale": return text(snapshot?.locale ?? "und")
        case "i18n.t":
            guard let snapshot else { throw HostCallError.argument("Plugin has no string resources") }
            let args: [PluginStringArgument] = (payload["args"]?.arrayValue ?? []).map { element in
                switch element {
                case .string(let s): return .string(s)
                case .number, .bool: return element.longOrNull.map { .integer($0) } ?? .none
                default: return .none
                }
            }
            do { return text(try snapshot.format(payload.string("key"), args)) } catch let e as PluginStringsError {
                throw HostCallError.argument(e.description)
            }
        case "app.info":
            let a = environment.appInfo
            return value(.object(JSONObject([
                ("name", .string(a.name)), ("packageName", .string(a.packageName)), ("versionName", .string(a.versionName)),
                ("versionCode", .int64(a.versionCode)), ("buildType", .string(a.buildType)), ("debug", .bool(a.debug))
            ])))
        case "app.userAgent": return text(environment.appInfo.userAgent)
        case "runtime.info":
            return value(.object(JSONObject([
                ("pluginApiVersion", .int(HostApiRegistry.pluginProtocolVersion)),
                ("hostApiVersion", .int(HostApiRegistry.platformApiVersion)),
                ("engine", .string(engineName)),
                ("engineVersion", environment.engineVersion.map { .string($0) } ?? .null),
                ("supportedHostApis", .array(HostApiRegistry.supportedHostApis.sorted().map { .string($0) }))
            ])))
        case "cache.get": return text(cacheGet(payload.string("key")))
        case "cache.set":
            cacheSet(payload.string("key"), payload.string("value"), try payload.hostLong("ttlMs"))
            return text("")
        case "cache.remove": cacheRemove(payload.string("key")); return text("")
        case "cache.clear": cacheClear(); return text("")
        case "crypto.md5": return text(Digest.md5Hex(payload.string("text")))
        case "crypto.aesEcbPkcs5EncryptBase64":
            return text(AndroidBase64.encode(try aes(Array(payload.string("text").utf8), payload.string("key"), encrypt: true)))
        case "crypto.aesEcbPkcs5EncryptHex":
            return text(Digest.hexUpper(try aes(Array(payload.string("text").utf8), payload.string("key"), encrypt: true)))
        case "crypto.aesEcbPkcs5DecryptBase64ToText":
            let input = try decodeBase64(payload.string("base64"))
            return text(String(decoding: try aes(input, payload.string("key"), encrypt: false), as: UTF8.self))
        case "base64.encodeText": return text(AndroidBase64.encode(Array(payload.string("text").utf8)))
        case "base64.decodeText": return text(String(decoding: try decodeBase64(payload.string("base64")), as: UTF8.self))
        case "base64.dropBytes":
            let bytes = try decodeBase64(payload.string("base64"))
            let count = max(try payload.hostInt("count") ?? 0, 0)
            return text(AndroidBase64.encode(Array(bytes.dropFirst(min(count, bytes.count)))))
        case "base64.decodeBytes": return bytesValue(try decodeBase64(payload.string("base64")))
        case "base64.encodeBytes": return text(AndroidBase64.encode(try payload.hostBytes("bytes")))
        case "base64.encodeUrlText": return text(AndroidBase64.encode(Array(payload.string("text").utf8), urlSafe: true, padding: false))
        case "base64.decodeUrlText":
            return text(String(decoding: try decodeBase64(AndroidBase64.fromUrl(payload.string("base64Url"))), as: UTF8.self))
        case "base64.encodeUrlBytes": return text(AndroidBase64.encode(try payload.hostBytes("bytes"), urlSafe: true, padding: false))
        case "base64.decodeUrlBytes": return bytesValue(try decodeBase64(AndroidBase64.fromUrl(payload.string("base64Url"))))
        case "base64.toUrl": return text(AndroidBase64.toUrl(payload.string("base64")))
        case "base64.fromUrl": return text(AndroidBase64.fromUrl(payload.string("base64Url")))
        case "bytes.xor": return bytesValue(xor(try payload.hostBytes("bytes"), try payload.hostBytes("key")))
        case "bytes.xorBase64":
            return text(AndroidBase64.encode(xor(try decodeBase64(payload.string("base64")), try payload.hostBytes("key"))))
        case "compression.inflateBytesToText": return text(try inflate(try payload.hostBytes("bytes")))
        case "compression.inflateBase64ToText": return text(try inflate(try decodeBase64(payload.string("base64"))))
        case "http.getText": return text(String(decoding: try executeHttp("GET", payload, binary: false).body, as: UTF8.self))
        case "http.postText": return text(String(decoding: try executeHttp("POST", payload, binary: false).body, as: UTF8.self))
        case "http.postBytes": return text(AndroidBase64.encode(try executeHttp("POST", payload, binary: true).body))
        case "http.get": return value(responseObject(try executeHttp("GET", payload, binary: false), binary: false))
        case "http.post": return value(responseObject(try executeHttp("POST", payload, binary: false), binary: false))
        case "http.getBytes": return value(responseObject(try executeHttp("GET", payload, binary: true), binary: true))
        case "http.postBytesResponse": return value(responseObject(try executeHttp("POST", payload, binary: true), binary: true))
        case "xml.getRootAttributes": return value(try xml { try HostXmlApi.getRootAttributes(xml: payload.string("xml")) })
        case "xml.findElements":
            return value(try xml { try HostXmlApi.findElements(xml: payload.string("xml"), query: payload.obj("query") ?? JSONObject()) })
        case "xml.replaceChildrenByAttr":
            return text(try xml { try HostXmlApi.replaceChildrenByAttr(xml: payload.string("xml"), options: payload.obj("options") ?? JSONObject()) })
        case "xml.removeElements":
            return text(try xml { try HostXmlApi.removeElements(xml: payload.string("xml"), query: payload.obj("query") ?? JSONObject()) })
        case "log.debug": log(.debug, payload); return text("")
        case "log.warn": log(.warning, payload); return text("")
        case "log.error": log(.error, payload); return text("")
        default: throw HostCallError.state("Unsupported host api: \(name)")
        }
    }

    // MARK: Values

    private func value(_ v: JSONValue) -> String { JSONValue.object(JSONObject([("value", v)])).jsonString }
    private func text(_ s: String) -> String { value(.string(s)) }
    private func bytesValue(_ b: [UInt8]) -> String { value(.array(b.map { .int(Int($0)) })) }

    private func decodeBase64(_ s: String) throws -> [UInt8] {
        do { return try AndroidBase64.decode(s) } catch let e as CodecError { throw HostCallError.other(e.description) }
    }

    private func aes(_ input: [UInt8], _ key: String, encrypt: Bool) throws -> [UInt8] {
        do { return try AESECB.crypt(input, key: Array(key.utf8), encrypt: encrypt) } catch {
            throw HostCallError.other(String(describing: error))
        }
    }

    private func inflate(_ bytes: [UInt8]) throws -> String {
        do { return String(decoding: try Inflate.zlib(bytes), as: UTF8.self) } catch let e as CodecError { throw HostCallError.other(e.description) }
    }

    private func xor(_ bytes: [UInt8], _ key: [UInt8]) -> [UInt8] {
        if key.isEmpty { return bytes }
        return bytes.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    }

    private func xml<T>(_ block: () throws -> T) throws -> T {
        do { return try block() } catch let e as XMLError { throw HostCallError.other("org.xmlpull.v1.XmlPullParserException: \(e.description)") }
    }

    private func log(_ level: PluginLogLevel, _ payload: JSONObject) {
        let rawTag = payload.string("tag")
        let tag = (rawTag.ktIsBlank ? "PlatformPlugin" : rawTag).ktTake(48)
        environment.logHandler?(level, pluginId, tag, payload.string("message"))
    }

    // MARK: Cache (one JSON file per key: {"value": ..., "expiresAt": ...})

    private func pluginCacheDir() -> URL? {
        guard let root = environment.cacheRoot else { return nil }
        return root.appendingPathComponent(Digest.md5Hex(pluginId.ktIsBlank ? "default" : pluginId), isDirectory: true)
    }

    private func cacheFile(_ key: String) -> URL? {
        let k = key.ktTrim()
        if k.isEmpty { return nil }
        return pluginCacheDir()?.appendingPathComponent(Digest.md5Hex(k) + ".json")
    }

    private func cacheGet(_ key: String) -> String {
        guard let file = cacheFile(key), let data = try? Data(contentsOf: file) else { return "" }
        guard let entry = (try? JSONValue.parse(data: data))?.objectValue else {
            try? FileManager.default.removeItem(at: file)
            return ""
        }
        let expiresAt = entry["expiresAt"]?.longOrNull ?? 0
        if expiresAt > 0 && expiresAt <= Int64(Date().timeIntervalSince1970 * 1000) {
            try? FileManager.default.removeItem(at: file)
            return ""
        }
        return entry.string("value")
    }

    private func cacheSet(_ key: String, _ value: String, _ ttlMs: Int64?) {
        guard let file = cacheFile(key) else { return }
        let ttl = ttlMs ?? 0
        let expiresAt: Int64 = ttl > 0 ? Int64(Date().timeIntervalSince1970 * 1000) + ttl : 0
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = JSONValue.object(JSONObject([("value", .string(value)), ("expiresAt", .int64(expiresAt))])).jsonString
        try? Data(json.utf8).write(to: file, options: .atomic)
    }

    private func cacheRemove(_ key: String) {
        if let file = cacheFile(key) { try? FileManager.default.removeItem(at: file) }
    }

    private func cacheClear() {
        if let dir = pluginCacheDir() { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: HTTP

    private func executeHttp(_ method: String, _ payload: JSONObject, binary: Bool) throws -> HostHTTPResponse {
        let urlText = payload.string("url")
        guard urlText.ktIsNotBlank else { throw HostCallError.argument("HTTP url is blank") }
        guard let url = URL(string: urlText), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw HostCallError.argument("Expected URL scheme 'http' or 'https' but no scheme was found for \(urlText.ktTake(64))")
        }
        let rawContentType = payload.string("contentType")
        let contentType = rawContentType.ktIsBlank ? (binary ? "application/octet-stream" : "application/json; charset=utf-8") : rawContentType
        var request = URLRequest(url: url)
        request.httpMethod = method
        let headers = payload.obj("headers")
        if method == "POST" { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let headers {
            for (key, v) in headers {
                let headerValue = Self.headerString(v)
                if key.caseInsensitiveCompare("User-Agent") == .orderedSame && headerValue.ktIsBlank { continue }
                request.setValue(headerValue, forHTTPHeaderField: key)
            }
        }
        let hasUA = headers?.contains { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame && Self.headerString($0.value).ktIsNotBlank } ?? false
        if !hasUA { request.setValue(environment.appInfo.userAgent, forHTTPHeaderField: "User-Agent") }
        if method == "POST" { request.httpBody = Data(try requestBodyBytes(payload)) }

        if isCancelled { throw HostCallError.state("Plugin invocation cancelled") }
        if let deadline, deadline.timeIntervalSinceNow <= 0 { throw HostCallError.state("Plugin invocation timed out") }
        let connectMs = try payload.hostInt("connectTimeoutMs") ?? 8_000
        let readMs = try payload.hostInt("readTimeoutMs") ?? 12_000
        request.timeoutInterval = Double(max(connectMs, readMs, 1)) / 1000
        let follow = payload["followRedirects"]?.contentOrNull.flatMap { $0 == "true" ? true : ($0 == "false" ? false : nil) } ?? true
        if !httpCreated { httpCreated = true }
        return try http.execute(request, followRedirects: follow, deadline: deadline, isCancelled: { [weak self] in self?.isCancelled ?? true }) { cancel in
            cancelLock.lock(); cancelActiveHTTP = cancel; cancelLock.unlock()
        }
    }

    private func requestBodyBytes(_ payload: JSONObject) throws -> [UInt8] {
        let b64 = payload.string("bodyBase64")
        if b64.ktIsNotBlank { return try decodeBase64(b64) }
        if case .array = payload["bodyBytes"] { return try payload.hostBytes("bodyBytes") }
        return Array(payload.string("body").utf8)
    }

    private func responseObject(_ r: HostHTTPResponse, binary: Bool) -> JSONValue {
        .object(JSONObject([
            ("code", .int(r.code)),
            ("message", .string(r.message)),
            ("headers", .object(JSONObject(r.headers.map { ($0.0, JSONValue.array($0.1.map { .string($0) })) }))),
            ("body", .string(binary ? "" : String(decoding: r.body, as: UTF8.self))),
            ("bodyBase64", .string(binary ? AndroidBase64.encode(r.body) : ""))
        ]))
    }

    static func headerString(_ v: JSONValue) -> String {
        switch v {
        case .array(let a): return a.map { $0.contentOrNull ?? "" }.joined(separator: ", ")
        case .object: return v.jsonString
        default: return v.contentOrNull ?? ""
        }
    }
}

extension JSONObject {
    /// `this[key]?.jsonPrimitive?.int` (throws on null / non-integer like kotlinx).
    func hostInt(_ key: String) throws -> Int? {
        guard let v = self[key] else { return nil }
        guard case .number(let n) = v, let i = Int32(n) else {
            if case .string(let s) = v, let i = Int32(s) { return Int(i) }
            throw HostCallError.other("java.lang.NumberFormatException: Invalid number format: '\(v.contentOrNull ?? v.jsonString)'")
        }
        return Int(i)
    }

    /// `this[key]?.jsonPrimitive?.longOrNull`.
    func hostLong(_ key: String) throws -> Int64? {
        guard let v = self[key] else { return nil }
        guard v.isPrimitive else { throw HostCallError.argument("Element \(v.jsonString) is not a JsonPrimitive") }
        return v.longOrNull
    }

    /// `bytes(key)`: int array → bytes (values truncated to 8 bits like `Int.toByte()`).
    func hostBytes(_ key: String) throws -> [UInt8] {
        guard let v = self[key] else { return [] }
        guard case .array(let a) = v else { throw HostCallError.argument("Element \(v.jsonString) is not a JsonArray") }
        return try a.map { e in
            guard case .number(let n) = e, let i = Int32(n) else {
                if case .string(let s) = e, let i = Int32(s) { return UInt8(truncatingIfNeeded: i) }
                throw HostCallError.other("java.lang.NumberFormatException: Invalid number format: '\(e.contentOrNull ?? e.jsonString)'")
            }
            return UInt8(truncatingIfNeeded: i)
        }
    }
}
