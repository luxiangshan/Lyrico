import Foundation

/// Pure helpers for SMB paths: the interface uses '/'-separated paths absolute within the share ("/" = share root);
/// AMSMB2 takes share-relative paths without a leading separator ("" = root).
public enum SMBPaths {
    public static let defaultPort = 445
    public static let tempSuffix = ".lyrico-tmp"

    public struct HostPort: Equatable, Sendable {
        public let host: String
        public let port: Int
    }

    /// Parses "host[:port]" (also "smb://host[:port][/...]", "\\\\host", "[ipv6]:port").
    public static func parseHost(_ baseURL: String) throws -> HostPort {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("smb://") { s = String(s.dropFirst(6)) }
        s = String(s.drop(while: { $0 == "\\" || $0 == "/" }))
        if let cut = s.firstIndex(where: { $0 == "/" || $0 == "\\" }) { s = String(s[..<cut]) }
        guard !s.isEmpty else { throw RemoteStorageError.invalidArgument("SMB host is empty") }

        if s.hasPrefix("[") {
            guard let end = s.firstIndex(of: "]"), end != s.startIndex else { throw RemoteStorageError.invalidArgument("Invalid SMB host: \(baseURL)") }
            let host = String(s[s.index(after: s.startIndex)..<end])
            let rest = s[s.index(after: end)...]
            let port = rest.hasPrefix(":") ? try parsePort(String(rest.dropFirst()), baseURL) : defaultPort
            return HostPort(host: host, port: port)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let idx = s.firstIndex(of: ":") {
            let host = String(s[..<idx])
            guard !host.isEmpty else { throw RemoteStorageError.invalidArgument("SMB host is empty") }
            return HostPort(host: host, port: try parsePort(String(s[s.index(after: idx)...]), baseURL))
        }
        return HostPort(host: s, port: defaultPort)
    }

    private static func parsePort(_ p: String, _ original: String) throws -> Int {
        if p.isEmpty { return defaultPort }
        guard let port = Int(p), (1...65535).contains(port) else { throw RemoteStorageError.invalidArgument("Invalid SMB port in \"\(original)\"") }
        return port
    }

    /// Leading '/', no trailing '/', collapses duplicates, rejects "..".
    public static func normalize(_ path: String) throws -> String {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { $0 != "." }
        if parts.contains("..") { throw RemoteStorageError.invalidArgument("Path must not contain '..': \(path)") }
        return "/" + parts.joined(separator: "/")
    }

    /// "/Music/a.flac" -> "Music/a.flac"; "/" -> "".
    public static func toShareRelative(_ path: String) throws -> String { String(try normalize(path).dropFirst()) }

    public static func child(_ dir: String, _ name: String) throws -> String {
        let d = try normalize(dir)
        return d == "/" ? "/" + name : d + "/" + name
    }

    public static func parent(_ path: String) throws -> String { RemotePaths.parent(try normalize(path)) }
    public static func name(_ path: String) throws -> String { RemotePaths.name(try normalize(path)) }

    /// Hidden temp file used during upload: "<dir>/.<name>.lyrico-tmp".
    public static func tempPath(for path: String) throws -> String { try child(parent(path), ".\(try name(path))\(tempSuffix)") }
    public static func isTempName(_ name: String) -> Bool { name.hasPrefix(".") && name.hasSuffix(tempSuffix) }

    /// Validates a new file name (single segment, no characters SMB forbids).
    public static func validateName(_ newName: String) throws {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { throw RemoteStorageError.invalidArgument("New name is empty") }
        guard newName != ".", newName != ".." else { throw RemoteStorageError.invalidArgument("Invalid name: \(newName)") }
        if let bad = newName.unicodeScalars.first(where: { "\\/:*?\"<>|".unicodeScalars.contains($0) || $0.value < 0x20 }) {
            throw RemoteStorageError.invalidArgument("Name contains a character not allowed on SMB: '\(bad)'")
        }
        if newName.hasSuffix(" ") || newName.hasSuffix(".") { throw RemoteStorageError.invalidArgument("Name must not end with a space or dot") }
    }

    /// "DOM\\user" -> (user, DOM); "user@dom" -> (user, dom) when `domain` is blank; else (user, domain).
    public static func splitUser(_ user: String, domain: String) -> (user: String, domain: String) {
        if domain.isEmpty, let bs = user.firstIndex(of: "\\"), bs != user.startIndex {
            return (String(user[user.index(after: bs)...]), String(user[..<bs]))
        }
        if domain.isEmpty, let at = user.lastIndex(of: "@"), at != user.startIndex {
            return (String(user[..<at]), String(user[user.index(after: at)...]))
        }
        return (user, domain)
    }

    /// Keeps plain disk shares: drops IPC$ / admin shares (names ending in '$'), duplicates; sorted by name.
    public static func diskShares(_ shares: [(name: String, comment: String)]) -> [SMBShareInfo] {
        var seen = Set<String>()
        var out: [SMBShareInfo] = []
        for s in shares {
            let name = s.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name.hasSuffix("$") { continue }
            if seen.insert(name.lowercased()).inserted { out.append(SMBShareInfo(name: name, remark: s.comment)) }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
}

public struct SMBShareInfo: Hashable, Sendable {
    public let name: String
    public let remark: String
    public init(name: String, remark: String) { self.name = name; self.remark = remark }
}
