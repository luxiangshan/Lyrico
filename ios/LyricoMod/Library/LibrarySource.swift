// Extension point for library locations. Local folders (Documents + picked folders) are implemented
// here; remote folders are provided through RemoteStorageClient (see Remote/RemoteStorageClient.swift)
// by the RemoteStorage package.
import Foundation

/// A file or folder inside a library source. `path` is absolute within the source, '/'-separated,
/// starting with '/' (same convention as Android RemoteEntry).
struct LibraryEntry: Hashable {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: Int64 = -1
    var modified: Date?
    /// Provider specific id (e.g. 115 file id). Empty when unused.
    var providerId: String = ""
}

enum LibrarySourceKind: Equatable {
    case documents
    case localFolder
    case remote(type: String)
}

enum LibrarySourceError: LocalizedError {
    case unavailable(String)
    case notFound(String)
    case accessDenied(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unavailable(let s): return s
        case .notFound(let s): return s
        case .accessDenied(let s): return s
        case .unsupported: return L("ios_remote_unavailable")
        }
    }
}

/// Mirrors the Android RemoteStorage interface (list, stat, openRead/openRange, download, upload,
/// rename, delete, testConnection) so local and remote folders share one scanning/editing pipeline.
protocol LibrarySource: AnyObject {
    var kind: LibrarySourceKind { get }
    var displayName: String { get }
    /// Root folder path inside the source that this library folder covers ("/" for a whole local folder).
    var rootPath: String { get }

    func testConnection() async throws
    func list(_ dirPath: String) async throws -> [LibraryEntry]
    func stat(_ path: String) async throws -> LibraryEntry?
    /// Reads `length` bytes at `offset` (length < 0 = to end).
    func openRange(_ path: String, offset: Int64, length: Int64) async throws -> Data
    /// Copies the whole file to `localURL`.
    func download(_ path: String, to localURL: URL) async throws
    /// Replaces the file at `path` with the contents of `localURL`.
    func upload(_ path: String, from localURL: URL) async throws
    /// Renames within the same folder; returns the new path.
    func rename(_ path: String, newName: String) async throws -> String
    func delete(_ path: String) async throws

    /// Direct file URL for sources stored on this device (nil for remote sources).
    func localURL(for path: String) -> URL?
    /// Starts security-scoped access (balanced with endAccess). Returns false if access was refused.
    func beginAccess() -> Bool
    func endAccess()
}

extension LibrarySource {
    var isLocal: Bool { !kind.isRemote }
}

extension LibrarySourceKind {
    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

enum AudioFormats {
    /// Same list as the Android scanner, plus a few formats TagLib reads on iOS.
    static let extensions: Set<String> = ["mp3", "flac", "m4a", "ogg", "opus", "wav", "aac", "wma", "ape",
                                          "m4b", "aif", "aiff", "wv", "dsf", "oga", "spx", "alac"]

    static func isAudio(_ name: String) -> Bool {
        extensions.contains((name as NSString).pathExtension.lowercased())
    }

    static let skippedDirectories: Set<String> = ["@eaDir", "#recycle", ".Trash", ".Trashes", "__MACOSX"]
}

/// Joins a source path with a child name.
func joinPath(_ dir: String, _ name: String) -> String {
    dir.hasSuffix("/") ? dir + name : dir + "/" + name
}
