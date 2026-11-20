#if canImport(AMSMB2)
import AMSMB2
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// SMB2/3 location backed by AMSMB2 (libsmb2). The connection to the share is opened lazily, reused, and
/// re-established once when an operation fails because the connection died.
///
/// `config.baseURL` = "host[:port]" (default 445), `config.share` = share name, `config.username` (blank = guest,
/// then anonymous), password = the location's secret, `config.domain` optional.
public final class SMBStorage: RemoteStorage, @unchecked Sendable {
    public let config: RemoteLocationConfig
    private let password: String
    private let hostPort: SMBPaths.HostPort
    private let hostDesc: String
    private let gate = AsyncGate()
    private let state = Locked<(manager: SMB2Manager?, closed: Bool)>((nil, false))

    public init(config: RemoteLocationConfig, password: String) throws {
        self.config = config
        self.password = password
        self.hostPort = try SMBPaths.parseHost(config.baseURL)
        self.hostDesc = "\(hostPort.host):\(hostPort.port)"
    }

    // MARK: connection management

    private var shareName: String {
        config.share.trimmingCharacters(in: CharacterSet(charactersIn: " \\/"))
    }

    /// Returns a manager connected to the share, connecting/authenticating if needed.
    private func manager() async throws -> SMB2Manager {
        try await gate.run {
            let s = self.state.current
            if s.closed { throw RemoteStorageError.io("SMB storage is closed") }
            if let m = s.manager { return m }
            guard !self.shareName.isEmpty else { throw RemoteStorageError.io("No SMB share selected") }
            let m = try await Self.connect(hostPort: self.hostPort, username: self.config.username, password: self.password,
                                           domain: self.config.domain, share: self.shareName, hostDesc: self.hostDesc)
            self.state.withLock { $0.manager = m }
            return m
        }
    }

    private func reset(_ failed: SMB2Manager) {
        let old: SMB2Manager? = state.withLock { st in
            guard st.manager === failed else { return nil }
            st.manager = nil
            return failed
        }
        if let o = old { Task { try? await o.disconnectShare(gracefully: false) } }
    }

    /// Runs `block` against the share; reconnects once if an existing connection died. Errors are mapped.
    private func op<T>(_ what: String, _ block: (SMB2Manager) async throws -> T) async throws -> T {
        do {
            let m = try await manager()
            do {
                return try await block(m)
            } catch {
                if !state.current.closed && Self.isBrokenConnection(error) {
                    reset(m)
                    return try await block(try await manager())
                }
                throw error
            }
        } catch {
            throw Self.map(error, what: what, hostDesc: hostDesc)
        }
    }

    public func close() async {
        let m: SMB2Manager? = state.withLock { st in
            st.closed = true
            let m = st.manager
            st.manager = nil
            return m
        }
        try? await m?.disconnectShare(gracefully: true)
    }

    // MARK: RemoteStorage

    public func testConnection() async throws {
        try await op("share \"\(config.share)\" on \(hostDesc)") { m in
            _ = try await m.contentsOfDirectory(atPath: "/") // real round trip with the share's permissions
        }
    }

    public func list(_ dirPath: String) async throws -> [RemoteEntry] {
        let dir = try SMBPaths.normalize(dirPath)
        let items = try await op(dir) { m in try await m.contentsOfDirectory(atPath: dir) }
        var out: [RemoteEntry] = []
        for info in items {
            guard let name = info[.nameKey] as? String, name != ".", name != "..", !SMBPaths.isTempName(name) else { continue }
            let isDir = Self.bool(info[.isDirectoryKey])
            out.append(RemoteEntry(path: try SMBPaths.child(dir, name), name: name, isDirectory: isDir,
                                   size: isDir ? -1 : Self.int64(info[.fileSizeKey]),
                                   modifiedMillis: Self.millis(info[.contentModificationDateKey])))
        }
        return out.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    public func stat(_ path: String) async throws -> RemoteEntry? {
        let p = try SMBPaths.normalize(path)
        if p == "/" { return RemoteEntry(path: "/", name: "", isDirectory: true) }
        do {
            let info = try await op(p) { m in try await m.attributesOfItem(atPath: p) }
            let isDir = Self.bool(info[.isDirectoryKey])
            return RemoteEntry(path: p, name: try SMBPaths.name(p), isDirectory: isDir,
                               size: isDir ? -1 : Self.int64(info[.fileSizeKey]), modifiedMillis: Self.millis(info[.contentModificationDateKey]))
        } catch let e as RemoteStorageError where e.isNotFound {
            return nil
        }
    }

    public func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        guard offset >= 0 else { throw RemoteStorageError.invalidArgument("offset must be >= 0") }
        let p = try SMBPaths.normalize(path)
        if length == 0 { return Data() }
        let range: Range<Int64> = length < 0 ? offset..<Int64.max : offset..<(offset + length)
        return try await op(p) { m in try await m.contents(atPath: p, range: range, progress: nil) }
    }

    public func download(_ path: String, to localURL: URL) async throws {
        let p = try SMBPaths.normalize(path)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: localURL)
        try await op(p) { m in try await m.downloadItem(atPath: p, to: localURL, progress: nil) }
    }

    public func upload(from localURL: URL, to path: String) async throws {
        let p = try SMBPaths.normalize(path)
        guard p != "/" else { throw RemoteStorageError.invalidArgument("Cannot upload to the share root") }
        guard FileManager.default.fileExists(atPath: localURL.path) else { throw RemoteStorageError.notFound("Local file not found: \(localURL.path)") }
        let temp = try SMBPaths.tempPath(for: p)
        let backup = try SMBPaths.child(SMBPaths.parent(p), ".\(try SMBPaths.name(p)).lyrico-old")
        try await op(p) { m in
            try? await m.removeFile(atPath: temp)
            do {
                try await m.uploadItem(at: localURL, toPath: temp, progress: nil)
            } catch {
                // No create rights in the folder (or similar): overwrite the target in place.
                try? await m.removeFile(atPath: temp)
                try await Self.writeDirect(m, localURL, p)
                return
            }
            do {
                try await m.moveItem(atPath: temp, toPath: p) // target does not exist yet
                return
            } catch {
                // libsmb2 renames never replace: move the old file aside, then put the new one in place.
            }
            try? await m.removeFile(atPath: backup)
            do {
                try await m.moveItem(atPath: p, toPath: backup)
            } catch {
                try? await m.removeFile(atPath: temp)
                try await Self.writeDirect(m, localURL, p)
                return
            }
            do {
                try await m.moveItem(atPath: temp, toPath: p)
            } catch {
                try? await m.moveItem(atPath: backup, toPath: p) // restore the original
                try? await m.removeFile(atPath: temp)
                throw error
            }
            try? await m.removeFile(atPath: backup)
        }
    }

    public func rename(_ path: String, to newName: String) async throws -> String {
        try SMBPaths.validateName(newName)
        let p = try SMBPaths.normalize(path)
        guard p != "/" else { throw RemoteStorageError.invalidArgument("Cannot rename the share root") }
        let newPath = try SMBPaths.child(SMBPaths.parent(p), newName)
        if newPath == p { return p }
        try await op(p) { m in try await m.moveItem(atPath: p, toPath: newPath) }
        return newPath
    }

    /// Deletes a file, or an empty folder (non-recursive on purpose).
    public func delete(_ path: String) async throws {
        let p = try SMBPaths.normalize(path)
        guard p != "/" else { throw RemoteStorageError.invalidArgument("Cannot delete the share root") }
        try await op(p) { m in
            let info = try await m.attributesOfItem(atPath: p)
            if Self.bool(info[.isDirectoryKey]) { try await m.removeDirectory(atPath: p, recursive: false) } else { try await m.removeFile(atPath: p) }
        }
    }

    // MARK: share enumeration

    /// Lists the browsable disk shares on `host` ("host[:port]"). Guest/anonymous when `username` is blank.
    public static func listShares(host: String, username: String, password: String, domain: String = "") async throws -> [SMBShareInfo] {
        let hp = try SMBPaths.parseHost(host)
        let desc = "\(hp.host):\(hp.port)"
        do {
            var lastError: Error?
            for cred in credentials(username: username, password: password, domain: domain) {
                guard let m = SMB2Manager(url: smbURL(hp), domain: cred.domain, credential: cred.credential) else {
                    throw RemoteStorageError.invalidArgument("Invalid SMB host: \(host)")
                }
                do {
                    let shares = try await m.listShares(enumerateHidden: false)
                    return SMBPaths.diskShares(shares.map { (name: $0.name, comment: $0.comment) })
                } catch {
                    lastError = error
                    if !isAuthFailure(error) { throw error }
                }
            }
            throw lastError ?? RemoteStorageError.io("SMB share list failed")
        } catch {
            let mapped = map(error, what: "share list of \(desc)", hostDesc: desc)
            if username.trimmingCharacters(in: .whitespaces).isEmpty, mapped.isAuth {
                throw RemoteStorageError.auth("SMB server \(desc) does not allow guest/anonymous access; enter a username and password")
            }
            throw mapped
        }
    }

    // MARK: helpers

    private struct Cred { let credential: URLCredential?; let domain: String }

    /// Blank username: guest first, then anonymous (servers differ in which they allow).
    private static func credentials(username: String, password: String, domain: String) -> [Cred] {
        let user = username.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            return [Cred(credential: nil, domain: ""), Cred(credential: URLCredential(user: "", password: "", persistence: .none), domain: "")]
        }
        let (u, d) = SMBPaths.splitUser(user, domain: domain.trimmingCharacters(in: .whitespaces))
        return [Cred(credential: URLCredential(user: u, password: password, persistence: .none), domain: d)]
    }

    private static func smbURL(_ hp: SMBPaths.HostPort) -> URL {
        let host = hp.host.contains(":") ? "[\(hp.host)]" : hp.host
        return URL(string: "smb://\(host)" + (hp.port == SMBPaths.defaultPort ? "" : ":\(hp.port)"))!
    }

    private static func connect(hostPort: SMBPaths.HostPort, username: String, password: String, domain: String,
                                share: String, hostDesc: String) async throws -> SMB2Manager {
        var lastError: Error?
        let creds = credentials(username: username, password: password, domain: domain)
        for cred in creds {
            guard let m = SMB2Manager(url: smbURL(hostPort), domain: cred.domain, credential: cred.credential) else {
                throw RemoteStorageError.invalidArgument("Invalid SMB host: \(hostDesc)")
            }
            do {
                try await m.connectShare(name: share)
                return m
            } catch {
                lastError = error
                if !isAuthFailure(error) { break }
            }
        }
        let err = lastError ?? RemoteStorageError.io("SMB connection failed")
        let mapped = map(err, what: "\"\(share)\" on \(hostDesc)", hostDesc: hostDesc)
        if username.trimmingCharacters(in: .whitespaces).isEmpty, mapped.isAuth {
            throw RemoteStorageError.auth("SMB server \(hostDesc) does not allow guest/anonymous access; enter a username and password")
        }
        throw mapped
    }

    private static func writeDirect(_ m: SMB2Manager, _ source: URL, _ target: String) async throws {
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        try await m.append(data: data, toPath: target, offset: 0, progress: nil)
    }

    static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return false
    }

    static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        return -1
    }

    static func millis(_ v: Any?) -> Int64 {
        guard let d = v as? Date else { return 0 }
        return Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    static func posixCode(_ error: Error) -> POSIXErrorCode? {
        if let p = error as? POSIXError { return p.code }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return POSIXErrorCode(rawValue: Int32(ns.code)) }
        return nil
    }

    static func isAuthFailure(_ error: Error) -> Bool {
        if let e = error as? RemoteStorageError { return e.isAuth }
        let desc = error.localizedDescription.lowercased()
        switch posixCode(error) {
        case .EACCES?: return true
        case .ECONNREFUSED?: return desc.contains("logon") || desc.contains("auth") || desc.contains("session setup")
        default: return desc.contains("logon_failure") || desc.contains("authentication")
        }
    }

    /// True when the failure looks like a dead transport/session that one reconnect could fix.
    static func isBrokenConnection(_ error: Error) -> Bool {
        switch posixCode(error) {
        case .ENOTCONN?, .ECONNRESET?, .EPIPE?, .ETIMEDOUT?, .ECONNABORTED?, .ENETRESET?, .EBADF?: return true
        default: return false
        }
    }

    /// Converts any failure to `RemoteStorageError`.
    static func map(_ error: Error, what: String, hostDesc: String) -> RemoteStorageError {
        if let e = error as? RemoteStorageError { return e }
        if error is CancellationError { return .cancelled }
        let desc = error.localizedDescription
        switch posixCode(error) {
        case .ENOENT?: return .notFound("Not found on SMB share: \(what)")
        case .EACCES?: return .auth("Access denied on the SMB server for \(what) (check the account's share/file permissions)")
        case .ECONNREFUSED?:
            if isAuthFailure(error) { return .auth("SMB login failed: wrong username or password") }
            return .io("Cannot connect to SMB server \(hostDesc) (is it running and is the port open?)")
        case .EHOSTUNREACH?, .ENETUNREACH?: return .io("No route to SMB server \(hostDesc)")
        case .ETIMEDOUT?: return .io("SMB server \(hostDesc) timed out")
        case .ENOTEMPTY?: return .io("Folder is not empty: \(what)")
        case .EEXIST?: return .io("A file with that name already exists: \(what)")
        case .ETXTBSY?: return .io("File is in use by another program: \(what)")
        case .ENOTDIR?: return .io("Expected a folder but found a file: \(what)")
        case .EPERM?: return .io("Operation not permitted on the SMB server for \(what) (\(desc))")
        default:
            if isAuthFailure(error) { return .auth("SMB login to \(hostDesc) failed: \(desc)") }
            return .io("SMB error for \(what): \(desc)")
        }
    }
}
#endif
