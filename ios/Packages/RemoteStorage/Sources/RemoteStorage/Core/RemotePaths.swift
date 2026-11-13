import Foundation

/// Path helpers shared by the providers. Remote paths are '/'-separated and start with '/'.
public enum RemotePaths {
    /// Collapses duplicate slashes, removes "." segments (and resolves ".."), drops any trailing slash.
    public static func normalize(_ path: String) -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true)
        var out: [Substring] = []
        for p in parts where p != "." {
            if p == ".." { if !out.isEmpty { out.removeLast() } } else { out.append(p) }
        }
        return "/" + out.joined(separator: "/")
    }

    public static func join(_ dir: String, _ name: String) -> String {
        let d = normalize(dir)
        return d == "/" ? "/" + name : d + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let p = normalize(path)
        guard let i = p.lastIndex(of: "/"), i != p.startIndex else { return "/" }
        return String(p[..<i])
    }

    public static func name(_ path: String) -> String {
        let p = normalize(path)
        guard let i = p.lastIndex(of: "/") else { return p }
        return String(p[p.index(after: i)...])
    }

    private static let hex = Array("0123456789ABCDEF".utf8)

    /// Percent-encodes one path segment (RFC 3986 unreserved chars kept).
    public static func encodeSegment(_ segment: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(segment.utf8.count)
        for c in segment.utf8 {
            switch c {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(c)
            default:
                out.append(UInt8(ascii: "%")); out.append(hex[Int(c >> 4)]); out.append(hex[Int(c & 0xF)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Encodes every segment of an absolute path, keeping the '/' separators.
    public static func encodePath(_ path: String) -> String {
        normalize(path).split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : encodeSegment(String($0)) }
            .joined(separator: "/")
    }

    /// Strict percent-decoding (UTF-8): '+' stays '+'; malformed escapes are kept literally.
    public static func percentDecode(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let bytes = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if c == UInt8(ascii: "%"), i + 2 < bytes.count,
               let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
                continue
            }
            out.append(c)
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// application/x-www-form-urlencoded component (space as %20, everything but unreserved escaped).
    static func formEncode(_ s: String) -> String { encodeSegment(s) }

    static func formBody(_ pairs: [(String, String)]) -> Data {
        Data(pairs.map { formEncode($0.0) + "=" + formEncode($0.1) }.joined(separator: "&").utf8)
    }
}

/// Song / folder addressing for remote locations (port of the Android `RemoteUri`).
///
///  - Song uri: `remote://<configId>/<percent-encoded path segments>`, e.g. `remote://a1b2c3/My%20Music/%E6%AD%8C.flac`.
///  - Display path: `remote://<configId>/My Music/歌.flac` (not encoded, human readable, folder-tree prefix).
public enum RemoteURI {
    public static let scheme = "remote"
    public static let prefix = "remote://"
    public static let source = "REMOTE"

    public struct Parsed: Hashable, Sendable {
        public var configId: String
        public var path: String
        public init(configId: String, path: String) { self.configId = configId; self.path = path }
    }

    public static func isRemote(_ uriOrPath: String?) -> Bool { uriOrPath?.hasPrefix(prefix) == true }

    /// Encoded song uri.
    public static func build(configId: String, path: String) -> String {
        let normalized = normalizePath(path)
        let encoded = normalized.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : RemotePaths.encodeSegment(String($0)) }
            .joined(separator: "/")
        return prefix + configId + encoded
    }

    /// Human-readable path.
    public static func displayPath(configId: String, path: String) -> String {
        let normalized = normalizePath(path)
        return normalized == "/" ? prefix + configId : prefix + configId + normalized
    }

    /// Parses an encoded uri (percent-decoding each segment; '+' stays '+').
    public static func parse(_ uri: String) -> Parsed? {
        guard isRemote(uri) else { return nil }
        let rest = uri.dropFirst(prefix.count)
        let slash = rest.firstIndex(of: "/")
        let configId = String(slash.map { rest[..<$0] } ?? rest)
        guard !configId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let rawPath = slash.map { String(rest[$0...]) } ?? "/"
        let decoded = rawPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { RemotePaths.percentDecode(String($0)) }
            .joined(separator: "/")
        return Parsed(configId: configId, path: normalizePath(decoded))
    }

    /// Parses a display path; no percent-decoding.
    public static func parseDisplayPath(_ displayPath: String) -> Parsed? {
        guard isRemote(displayPath) else { return nil }
        let rest = displayPath.dropFirst(prefix.count)
        let slash = rest.firstIndex(of: "/")
        let configId = String(slash.map { rest[..<$0] } ?? rest)
        guard !configId.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Parsed(configId: configId, path: normalizePath(slash.map { String(rest[$0...]) } ?? "/"))
    }

    public static func configId(of uriOrPath: String) -> String? { parse(uriOrPath)?.configId }

    public static func normalizePath(_ path: String) -> String {
        let cleaned = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }
        return "/" + cleaned.joined(separator: "/")
    }

    public static func parentPath(_ path: String) -> String { RemotePaths.parent(normalizePath(path)) }

    public static func childPath(_ dir: String, _ name: String) -> String {
        let n = normalizePath(dir)
        return n == "/" ? "/" + name : n + "/" + name
    }

    public static func fileName(_ path: String) -> String {
        let n = normalizePath(path)
        return String(n[n.index(after: n.lastIndex(of: "/")!)...])
    }

    /// Same extension set as the Android media scanner.
    public static let supportedAudioExtensions: Set<String> = ["mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "wma", "ape"]

    public static func isSupportedAudio(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return supportedAudioExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Folder names skipped by the remote scanner (hidden dirs, NAS metadata, recycle bins).
    public static func isSkippedFolder(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n.hasPrefix(".") || n == "@eadir" || n == "#recycle" || n == "$recycle.bin" || n == "system volume information"
    }

    /// Drops folders nested in another selected folder ("/Music", "/Music/Rock" -> "/Music"); keeps order.
    public static func topLevelFolders(_ folders: [String]) -> [String] {
        var normalized: [String] = []
        for f in folders.map(normalizePath) where !normalized.contains(f) { normalized.append(f) }
        return normalized.filter { candidate in
            !normalized.contains { other in other != candidate && (other == "/" || candidate.hasPrefix(other + "/")) }
        }
    }
}
