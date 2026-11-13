import Foundation

/// One `WWW-Authenticate` challenge.
struct AuthChallenge: Equatable {
    let scheme: String
    /// Parameter names lower-cased.
    let params: [String: String]
}

/// HTTP Basic + Digest (RFC 7616: MD5, MD5-sess, SHA-256, SHA-256-sess, qop=auth), answered by hand so the
/// scheme is known after the first challenge and later requests carry the header preemptively.
final class HTTPAuth: @unchecked Sendable {
    private struct DigestState {
        let realm: String
        let nonce: String
        let opaque: String?
        let algorithm: String
        let qop: String?
        var nc: Int = 0
    }

    private let username: String
    private let password: String
    private let lock = NSLock()
    private var basicKnown = false
    private var digest: DigestState?

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    var hasCredentials: Bool { !username.isEmpty || !password.isEmpty }

    /// Preemptive Authorization header once the scheme is known.
    func preemptiveHeader(method: String, uri: String) -> String? {
        guard hasCredentials else { return nil }
        lock.lock(); defer { lock.unlock() }
        if digest != nil { return digestHeaderLocked(method: method, uri: uri) }
        if basicKnown { return basicHeader() }
        return nil
    }

    /// Answers a 401. Returns the Authorization header to retry with, or nil to give up.
    /// - Parameters:
    ///   - sentAuth: the Authorization header of the rejected request (nil if none).
    ///   - priorAttempts: how many authenticated retries were already made for this request.
    func respond(to wwwAuthenticate: [String], method: String, uri: String, sentAuth: String?, priorAttempts: Int) -> String? {
        guard hasCredentials, priorAttempts < 3 else { return nil }
        let challenges = wwwAuthenticate.flatMap(Self.parseChallenges)
        lock.lock(); defer { lock.unlock() }
        if let dc = Self.pickDigest(challenges) {
            let stale = dc.params["stale"]?.lowercased() == "true"
            let sentNonce = sentAuth.flatMap(Self.nonceOf)
            // Our digest was already rejected and the nonce is not merely stale -> wrong credentials.
            if let sent = sentAuth, sent.lowercased().hasPrefix("digest"), !stale, sentNonce == dc.params["nonce"] || priorAttempts > 0 {
                digest = nil
                return nil
            }
            guard let nonce = dc.params["nonce"] else { return nil }
            var qop: String?
            if let offered = dc.params["qop"] {
                let opts = offered.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard opts.contains("auth") else { return nil } // auth-int only: unsupported
                qop = "auth"
            }
            let algorithm = dc.params["algorithm"] ?? "MD5"
            guard Self.hashKind(algorithm) != nil else { return nil }
            digest = DigestState(realm: dc.params["realm"] ?? "", nonce: nonce, opaque: dc.params["opaque"], algorithm: algorithm, qop: qop)
            basicKnown = false
            return digestHeaderLocked(method: method, uri: uri)
        }
        let basic = challenges.first { $0.scheme.lowercased() == "basic" }
        // Some servers send 401 without a challenge header at all; Basic is the only sensible guess.
        if basic == nil && !challenges.isEmpty { return nil }
        if let sent = sentAuth, sent.lowercased().hasPrefix("basic") {
            basicKnown = false
            return nil
        }
        basicKnown = true
        return basicHeader()
    }

    private func basicHeader() -> String {
        "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
    }

    private func digestHeaderLocked(method: String, uri: String) -> String {
        guard var d = digest, let kind = Self.hashKind(d.algorithm) else { return "" }
        d.nc += 1
        digest = d
        let cnonce = Hex.lowerHex(M115.randomBytes(8))
        let nc = String(format: "%08x", d.nc)
        var ha1 = Self.h(kind, "\(username):\(d.realm):\(password)")
        if d.algorithm.lowercased().hasSuffix("-sess") { ha1 = Self.h(kind, "\(ha1):\(d.nonce):\(cnonce)") }
        let ha2 = Self.h(kind, "\(method):\(uri)")
        let resp = d.qop != nil
            ? Self.h(kind, "\(ha1):\(d.nonce):\(nc):\(cnonce):\(d.qop!):\(ha2)")
            : Self.h(kind, "\(ha1):\(d.nonce):\(ha2)")
        var s = "Digest username=\"\(Self.quote(username))\", realm=\"\(Self.quote(d.realm))\", nonce=\"\(Self.quote(d.nonce))\", "
        s += "uri=\"\(Self.quote(uri))\", algorithm=\(d.algorithm), response=\"\(resp)\""
        if let q = d.qop { s += ", qop=\(q), nc=\(nc), cnonce=\"\(cnonce)\"" }
        if let o = d.opaque { s += ", opaque=\"\(Self.quote(o))\"" }
        return s
    }

    static func hashKind(_ algorithm: String) -> HashKind? {
        var a = algorithm.uppercased()
        if a.hasSuffix("-SESS") { a.removeLast(5) }
        switch a {
        case "MD5": return .md5
        case "SHA-256": return .sha256
        default: return nil
        }
    }

    static func h(_ kind: HashKind, _ s: String) -> String { Hex.lowerHex(IncrementalHash.digest(kind, s)) }

    private static func quote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func nonceOf(_ header: String) -> String? {
        guard let r = header.range(of: "nonce=\"") else { return nil }
        let rest = header[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func pickDigest(_ challenges: [AuthChallenge]) -> AuthChallenge? {
        let digests = challenges.filter { $0.scheme.lowercased() == "digest" && $0.params["nonce"] != nil }
        return digests.first { ($0.params["algorithm"] ?? "").uppercased().hasPrefix("SHA-256") }
            ?? digests.first { hashKind($0.params["algorithm"] ?? "MD5") != nil }
    }

    /// Parses one header value that may hold several challenges:
    /// `Digest realm="a, b", nonce="x", Basic realm="y"`.
    static func parseChallenges(_ header: String) -> [AuthChallenge] {
        let s = Array(header.unicodeScalars)
        var i = 0
        var out: [AuthChallenge] = []
        var scheme: String?
        var params: [String: String] = [:]

        func skipSpacesAndCommas() { while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "," { i += 1 } }
        func readToken() -> String {
            let start = i
            while i < s.count, s[i] != " ", s[i] != "\t", s[i] != ",", s[i] != "=" { i += 1 }
            return String(String.UnicodeScalarView(s[start..<i]))
        }
        func flush() {
            if let sc = scheme { out.append(AuthChallenge(scheme: sc, params: params)) }
            scheme = nil
            params = [:]
        }

        while true {
            skipSpacesAndCommas()
            if i >= s.count { break }
            let token = readToken()
            var j = i
            while j < s.count, s[j] == " " || s[j] == "\t" { j += 1 }
            if j < s.count, s[j] == "=", scheme != nil {
                // auth-param
                i = j + 1
                while i < s.count, s[i] == " " || s[i] == "\t" { i += 1 }
                var value = ""
                if i < s.count, s[i] == "\"" {
                    i += 1
                    var v = String.UnicodeScalarView()
                    while i < s.count, s[i] != "\"" {
                        if s[i] == "\\", i + 1 < s.count { i += 1 }
                        v.append(s[i]); i += 1
                    }
                    i += 1
                    value = String(v)
                } else {
                    let start = i
                    while i < s.count, s[i] != ",", s[i] != " " { i += 1 }
                    value = String(String.UnicodeScalarView(s[start..<i]))
                }
                params[token.lowercased()] = value
            } else if j < s.count, s[j] == "=", scheme == nil {
                // token68 without scheme: ignore
                i = j + 1
            } else {
                // new scheme (possibly followed by token68)
                flush()
                scheme = token
                i = j
                // token68 form ("Negotiate abc==") : read it if next token is not a param
                var k = i
                while k < s.count, s[k] != ",", s[k] != " ", s[k] != "=" { k += 1 }
                if k < s.count, s[k] == "=" {
                    var m = k
                    while m < s.count, s[m] == "=" { m += 1 }
                    if m >= s.count || s[m] == "," || s[m] == " " {
                        if k > i { i = m } // token68 ends with '=' padding
                    }
                }
            }
        }
        flush()
        return out
    }
}
