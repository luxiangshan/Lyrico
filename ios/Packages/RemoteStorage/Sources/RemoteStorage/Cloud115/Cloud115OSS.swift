import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// STS credentials from `uplb.115.com/3.0/gettoken.php`.
struct OSSToken: Equatable {
    let accessKeyId: String
    let accessKeySecret: String
    let securityToken: String
}

/// Target returned by upload init when the rapid upload missed.
struct OSSTarget: Equatable {
    let bucket: String
    let objectKey: String
    let callback: String
    let callbackVar: String
}

/// Minimal Aliyun OSS client (V1 header signature) for 115 uploads: simple PutObject and sequential multipart,
/// both with 115's callback headers (mirrors 115driver's UploadByOSS / UploadByMultipart).
/// The OSS response body is 115's callback JSON.
struct Cloud115OSS {
    let client: HTTPClient
    let endpoints: Cloud115Endpoints
    var clock: () -> Date = { Date() }

    static let octet = "application/octet-stream"
    static let xml = "application/xml"
    static let defaultPartSize: Int64 = 8 * 1024 * 1024
    /// Above this, use multipart (simple PUT is fine for typical audio files).
    static let multipartThreshold: Int64 = 100 * 1024 * 1024
    static let tokenRefreshSeconds: TimeInterval = 50 * 60

    /// Returns the callback response body (115 JSON).
    func putObject(target: OSSTarget, token: OSSToken, file: URL, md5Base64: String) async throws -> String {
        let url = endpoints.ossObjectURL(bucket: target.bucket, objectKey: target.objectKey)
        let req = signed("PUT", url, target, subResource: "", contentType: Self.octet, contentMD5: md5Base64,
                         ossHeaders: callbackHeaders(target, token), token: token)
        let resp = try await send(req, body: .file(file), what: "OSS 上传")
        guard resp.isSuccess else { throw RemoteStorageError.io("OSS 上传失败: HTTP \(resp.status) \(String(resp.text.prefix(300)))") }
        return resp.text
    }

    /// Sequential multipart upload, parts of `partSize` bytes. Returns the callback response body.
    func multipartUpload(target: OSSTarget, tokenProvider: () async throws -> OSSToken, file: URL,
                         partSize: Int64 = Cloud115OSS.defaultPartSize, retryDelay: TimeInterval = 1) async throws -> String {
        var token = try await tokenProvider()
        var tokenAt = Date()
        // Initiate
        let initURL = endpoints.ossObjectURL(bucket: target.bucket, objectKey: target.objectKey, query: "?uploads")
        let initReq = signed("POST", initURL, target, subResource: "?uploads", contentType: Self.octet, contentMD5: "",
                             ossHeaders: sts(token), token: token)
        let initResp = try await send(initReq, body: .data(Data()), what: "OSS 初始化分片")
        guard initResp.isSuccess else { throw RemoteStorageError.io("OSS 初始化分片失败: HTTP \(initResp.status) \(String(initResp.text.prefix(300)))") }
        guard let uploadId = Self.xmlTag(initResp.text, "UploadId") else { throw RemoteStorageError.io("OSS 初始化分片失败: 无 UploadId") }

        var etags: [String] = []
        let total = try HTTPClient.fileSize(file)
        var offset: Int64 = 0
        var part = 1
        while offset < total {
            let len = min(partSize, total - offset)
            var lastErr: Error?
            var etag: String?
            for attempt in 0..<3 {
                if Date().timeIntervalSince(tokenAt) > Self.tokenRefreshSeconds {
                    token = try await tokenProvider(); tokenAt = Date()
                }
                do {
                    let q = "?partNumber=\(part)&uploadId=\(uploadId)"
                    let partURL = endpoints.ossObjectURL(bucket: target.bucket, objectKey: target.objectKey,
                                                         query: "?partNumber=\(part)&uploadId=\(RemotePaths.encodeSegment(uploadId))")
                    let req = signed("PUT", partURL, target, subResource: q, contentType: Self.octet, contentMD5: "",
                                     ossHeaders: sts(token), token: token)
                    let resp = try await send(req, body: .fileRange(file, offset: offset, length: len), what: "OSS 分片 \(part)")
                    guard resp.isSuccess else { throw RemoteStorageError.io("OSS 分片 \(part) 失败: HTTP \(resp.status)") }
                    guard let e = resp.header("ETag") else { throw RemoteStorageError.io("OSS 分片 \(part) 无 ETag") }
                    etag = e
                    break
                } catch let e as RemoteStorageError where e == .cancelled {
                    throw e
                } catch {
                    lastErr = error
                    if retryDelay > 0 { try await Task.sleep(nanoseconds: UInt64(retryDelay * Double(attempt + 1) * 1e9)) }
                }
            }
            guard let tag = etag else { throw lastErr ?? RemoteStorageError.io("OSS 分片 \(part) 失败") }
            etags.append(tag)
            offset += len
            part += 1
        }
        // Complete (with callback)
        var xml = "<CompleteMultipartUpload>"
        for (i, e) in etags.enumerated() { xml += "<Part><PartNumber>\(i + 1)</PartNumber><ETag>\(e)</ETag></Part>" }
        xml += "</CompleteMultipartUpload>"
        let doneURL = endpoints.ossObjectURL(bucket: target.bucket, objectKey: target.objectKey, query: "?uploadId=\(RemotePaths.encodeSegment(uploadId))")
        let req = signed("POST", doneURL, target, subResource: "?uploadId=\(uploadId)", contentType: Self.xml, contentMD5: "",
                         ossHeaders: callbackHeaders(target, token), token: token)
        let resp = try await send(req, body: .data(Data(xml.utf8)), what: "OSS 完成分片")
        guard resp.isSuccess else { throw RemoteStorageError.io("OSS 完成分片失败: HTTP \(resp.status) \(String(resp.text.prefix(300)))") }
        return resp.text
    }

    private func send(_ req: URLRequest, body: HTTPBody, what: String) async throws -> HTTPResponse {
        do { return try await client.send(req, body: body) } catch { throw transportError(error, what: what, host: req.url?.host) }
    }

    private func sts(_ token: OSSToken) -> [String: String] { ["x-oss-security-token": token.securityToken] }

    private func callbackHeaders(_ target: OSSTarget, _ token: OSSToken) -> [String: String] {
        [
            "x-oss-security-token": token.securityToken,
            "x-oss-callback": Data(target.callback.utf8).base64EncodedString(),
            "x-oss-callback-var": Data(target.callbackVar.utf8).base64EncodedString(),
        ]
    }

    private func signed(_ method: String, _ url: URL, _ target: OSSTarget, subResource: String, contentType: String,
                        contentMD5: String, ossHeaders: [String: String], token: OSSToken) -> URLRequest {
        let date = Self.httpDate(clock())
        let objectKey = target.objectKey.drop(while: { $0 == "/" })
        let resource = "/\(target.bucket)/\(objectKey)\(subResource)"
        let auth = "OSS \(token.accessKeyId):" + Self.sign(secret: token.accessKeySecret, method: method, contentMD5: contentMD5,
                                                          contentType: contentType, date: date, ossHeaders: ossHeaders, resource: resource)
        var r = URLRequest(url: url, method: method)
        r.setValue(date, forHTTPHeaderField: "Date")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        r.setValue(Cloud115Const.ossUserAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(auth, forHTTPHeaderField: "Authorization")
        if !contentMD5.isEmpty { r.setValue(contentMD5, forHTTPHeaderField: "Content-MD5") }
        for (k, v) in ossHeaders { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    /// OSS V1 signature: base64(HMAC-SHA1(secret, VERB\nMD5\nType\nDate\nOssHeaders+Resource)).
    static func sign(secret: String, method: String, contentMD5: String, contentType: String, date: String,
                     ossHeaders: [String: String], resource: String) -> String {
        let canon = ossHeaders
            .map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.0.hasPrefix("x-oss-") }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)\n" }
            .joined()
        let toSign = "\(method)\n\(contentMD5)\n\(contentType)\n\(date)\n\(canon)\(resource)"
        return Data(HMAC_SHA1.mac(key: Array(secret.utf8), message: Array(toSign.utf8))).base64EncodedString()
    }

    static func httpDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: d)
    }

    static func xmlTag(_ xml: String, _ tag: String) -> String? {
        guard let a = xml.range(of: "<\(tag)>"), let b = xml.range(of: "</\(tag)>", range: a.upperBound..<xml.endIndex) else { return nil }
        let v = String(xml[a.upperBound..<b.lowerBound])
        return v.contains("<") ? nil : v
    }
}
