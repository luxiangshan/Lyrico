import Foundation

/// Kind of remote location. Raw values match the Android app's stored `type` strings.
public enum RemoteType: String, Codable, CaseIterable, Sendable {
    case webdav = "WEBDAV"
    case openList = "OPENLIST"
    case smb = "SMB"
    case cloud115 = "CLOUD115"

    public var label: String {
        switch self {
        case .webdav: return "WebDAV"
        case .openList: return "OpenList"
        case .smb: return "SMB"
        case .cloud115: return "115"
        }
    }
}

/// A file or folder on a remote location. `path` is absolute within the location, '/'-separated, starting with '/'.
public struct RemoteEntry: Hashable, Codable, Sendable {
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// Size in bytes; -1 for folders / unknown.
    public var size: Int64
    /// Last modification time in Unix milliseconds; 0 when unknown.
    public var modifiedMillis: Int64
    /// Provider-specific id (e.g. 115 file id). Empty when unused.
    public var providerId: String

    public init(path: String, name: String, isDirectory: Bool, size: Int64 = -1, modifiedMillis: Int64 = 0, providerId: String = "") {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedMillis = modifiedMillis
        self.providerId = providerId
    }

    public var modificationDate: Date? {
        modifiedMillis > 0 ? Date(timeIntervalSince1970: TimeInterval(modifiedMillis) / 1000) : nil
    }
}

/// Errors thrown by every provider. Mirrors the Kotlin contract:
/// `RemoteAuthException` -> `.auth`, `FileNotFoundException` -> `.notFound`, `IOException` -> `.io`.
public enum RemoteStorageError: Error, LocalizedError, Equatable, Sendable {
    /// Credentials missing, rejected or expired (the user must log in again).
    case auth(String)
    /// The path does not exist.
    case notFound(String)
    /// Network / protocol / server failure with a readable message.
    case io(String)
    /// Bad argument (invalid name, bad URL, ...).
    case invalidArgument(String)
    case cancelled

    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .auth(let m), .notFound(let m), .io(let m), .invalidArgument(let m): return m
        case .cancelled: return "Cancelled"
        }
    }

    public var isAuth: Bool { if case .auth = self { return true } else { return false } }
    public var isNotFound: Bool { if case .notFound = self { return true } else { return false } }
}

/// Lets a provider persist refreshed tokens/cookies (e.g. the OpenList token cache).
public protocol RemoteCredentialStore: AnyObject, Sendable {
    func loadExtra(configId: String, key: String) -> String?
    func saveExtra(configId: String, key: String, value: String?)
}

/// One connected location. Implementations: `WebDAVStorage`, `OpenListStorage`, `SMBStorage` (Apple only),
/// `Cloud115Storage`. All methods are safe to call concurrently from any task.
public protocol RemoteStorage: AnyObject, Sendable {
    var config: RemoteLocationConfig { get }

    /// Verifies credentials/reachability; throws `RemoteStorageError.auth` or `.io` with a readable message.
    func testConnection() async throws

    /// Direct children of `dir`.
    func list(_ dir: String) async throws -> [RemoteEntry]

    /// Metadata of a single path, or nil if it does not exist.
    func stat(_ path: String) async throws -> RemoteEntry?

    /// `length` bytes from `offset` (length < 0 = to end of file). Returns fewer bytes at EOF, empty past EOF.
    /// Used for partial (tag-header) reads through `RemoteBlockReader`.
    func readRange(_ path: String, offset: Int64, length: Int64) async throws -> Data

    /// Downloads the whole file to `localURL` (overwritten).
    func download(_ path: String, to localURL: URL) async throws

    /// Replaces the remote file at `path` with the contents of `localURL` (overwrite in place, same name).
    /// Avoids leaving a truncated file on failure where the protocol allows (temp + rename/move).
    func upload(from localURL: URL, to path: String) async throws

    /// Renames a file within its folder; returns the new path.
    func rename(_ path: String, to newName: String) async throws -> String

    func delete(_ path: String) async throws

    /// Releases connections / caches. The instance must not be used afterwards.
    func close() async
}

public extension RemoteStorage {
    func close() async {}

    /// Whole file into memory (small files only).
    func readAll(_ path: String) async throws -> Data {
        try await readRange(path, offset: 0, length: -1)
    }
}

/// Default `download` built on a streaming range read is provider specific; this helper writes Data to a file.
func writeFileAtomically(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

@inline(__always) func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
