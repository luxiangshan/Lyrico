// Stub of the Android `com.lonx.lyrico.remote.RemoteStorage` interface for iOS.
// The real implementations (WebDAV, OpenList, SMB, 115) live in the local Swift package
// ios/Packages/RemoteStorage (branch ios-remote). When that package is linked
// (scripts/generate-project.sh adds it automatically), Remote/RemoteIntegration.swift registers a
// factory in RemoteStorageRegistry and remote folders start working through RemoteLibrarySource.
import Foundation

/// Kind of remote location (Android RemoteType).
enum RemoteKind: String, Codable, CaseIterable, Identifiable {
    case webdav = "WEBDAV"
    case openlist = "OPENLIST"
    case smb = "SMB"
    case cloud115 = "CLOUD115"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .webdav: return "WebDAV"
        case .openlist: return "OpenList"
        case .smb: return "SMB"
        case .cloud115: return "115"
        }
    }
}

/// Connection settings (Android RemoteConfig). `secret` is stored in the Keychain by the integration layer.
struct RemoteLocation: Codable, Hashable, Identifiable {
    var id: String
    var type: RemoteKind
    var displayName: String
    var baseUrl: String = ""
    var share: String = ""
    var username: String = ""
    var secret: String = ""
    var domain: String = ""
    var folders: [String] = ["/"]
}

/// One connected remote location (Android RemoteStorage). Paths are absolute within the location.
protocol RemoteStorageClient: AnyObject {
    var config: RemoteLocation { get }
    func testConnection() async throws
    func list(_ dirPath: String) async throws -> [LibraryEntry]
    func stat(_ path: String) async throws -> LibraryEntry?
    /// Whole file as a stream of data chunks is not needed by the app; download() covers it.
    func openRange(_ path: String, offset: Int64, length: Int64) async throws -> Data
    func download(_ path: String, to localURL: URL) async throws
    func upload(_ path: String, from localURL: URL) async throws
    func rename(_ path: String, newName: String) async throws -> String
    func delete(_ path: String) async throws
    func close()
}

/// Registry the RemoteStorage package hooks into. `factory == nil` means remote folders are unavailable.
final class RemoteStorageRegistry {
    static let shared = RemoteStorageRegistry()

    /// Creates a client for a saved location.
    var factory: ((RemoteLocation) throws -> RemoteStorageClient)?
    /// Optional SwiftUI screen for adding/editing a location (returns the saved config).
    var isAvailable: Bool { factory != nil }

    private var clients: [String: RemoteStorageClient] = [:]
    private let lock = NSLock()

    func client(for config: RemoteLocation) throws -> RemoteStorageClient {
        lock.lock(); defer { lock.unlock() }
        if let c = clients[config.id], c.config == config { return c }
        guard let factory else { throw LibrarySourceError.unsupported }
        let c = try factory(config)
        clients[config.id] = c
        return c
    }

    func drop(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        clients.removeValue(forKey: id)?.close()
    }
}

/// Saved remote locations (configs in UserDefaults, secrets in Keychain).
final class RemoteLocationStore {
    static let shared = RemoteLocationStore()
    private let key = "remote_locations_v1"

    func all() -> [RemoteLocation] {
        guard let data = UserDefaults.standard.data(forKey: key),
              var list = try? JSONDecoder().decode([RemoteLocation].self, from: data) else { return [] }
        for i in list.indices { list[i].secret = Keychain.read(account: "remote." + list[i].id) ?? "" }
        return list
    }

    func config(id: String) -> RemoteLocation? {
        guard var c = info(id: id) else { return nil }
        c.secret = Keychain.read(account: "remote." + id) ?? ""
        return c
    }

    /// Config without its secret (cheap; for display).
    func info(id: String) -> RemoteLocation? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RemoteLocation].self, from: data) else { return nil }
        return list.first { $0.id == id }
    }

    func save(_ config: RemoteLocation) {
        var list = all().filter { $0.id != config.id }
        Keychain.write(account: "remote." + config.id, value: config.secret)
        var stored = config
        stored.secret = ""
        list.append(stored)
        let cleaned = list.map { c -> RemoteLocation in var x = c; x.secret = ""; return x }
        UserDefaults.standard.set(try? JSONEncoder().encode(cleaned), forKey: key)
        RemoteStorageRegistry.shared.drop(config.id)
    }

    func remove(id: String) {
        let list = all().filter { $0.id != id }.map { c -> RemoteLocation in var x = c; x.secret = ""; return x }
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
        Keychain.write(account: "remote." + id, value: nil)
        Keychain.write(account: "remote.\(id).x.token", value: nil)
        RemoteStorageRegistry.shared.drop(id)
    }
}

/// Adapts a RemoteStorageClient to LibrarySource. Reading tags uses ranged reads
/// (RemoteRangeReader); editing downloads to a cache copy, writes, then uploads (RemoteFileCache).
final class RemoteLibrarySource: LibrarySource {
    let client: RemoteStorageClient
    let rootPath: String
    var kind: LibrarySourceKind { .remote(type: client.config.type.rawValue) }
    var displayName: String { client.config.displayName }

    init(client: RemoteStorageClient, rootPath: String) {
        self.client = client
        self.rootPath = rootPath
    }

    func testConnection() async throws { try await client.testConnection() }
    func list(_ dirPath: String) async throws -> [LibraryEntry] { try await client.list(dirPath) }
    func stat(_ path: String) async throws -> LibraryEntry? { try await client.stat(path) }
    func openRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        try await client.openRange(path, offset: offset, length: length)
    }
    func download(_ path: String, to localURL: URL) async throws { try await client.download(path, to: localURL) }
    func upload(_ path: String, from localURL: URL) async throws { try await client.upload(path, from: localURL) }
    func rename(_ path: String, newName: String) async throws -> String { try await client.rename(path, newName: newName) }
    func delete(_ path: String) async throws { try await client.delete(path) }
    func localURL(for path: String) -> URL? { nil }
    func beginAccess() -> Bool { true }
    func endAccess() {}
}

/// LTRandomAccessReader over a remote file with a small block cache (256 KB blocks), so TagLib only
/// fetches the parts of the file it actually reads (port of Android RemoteBlockReader).
final class RemoteRangeReader: NSObject, LTRandomAccessReader {
    private let source: LibrarySource
    private let path: String
    private let length: Int64
    private let blockSize: Int64 = 256 * 1024
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private let maxBlocks = 32

    init(source: LibrarySource, path: String, length: Int64) {
        self.source = source
        self.path = path
        self.length = length
    }

    func totalLength() -> Int64 { length }

    func read(atOffset offset: Int64, length want: Int) -> Data? {
        guard offset < length else { return Data() }
        var out = Data()
        var pos = offset
        let end = min(length, offset + Int64(want))
        while pos < end {
            let index = pos / blockSize
            guard let block = block(index) else { return out.isEmpty ? nil : out }
            let start = Int(pos - index * blockSize)
            if start >= block.count { break }
            let take = min(block.count - start, Int(end - pos))
            out.append(block.subdata(in: start..<(start + take)))
            pos += Int64(take)
        }
        return out
    }

    private func block(_ index: Int64) -> Data? {
        if let b = blocks[index] { return b }
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        let src = source, p = path, off = index * blockSize, len = min(blockSize, length - index * blockSize)
        Task.detached {
            result = try? await src.openRange(p, offset: off, length: len)
            sem.signal()
        }
        sem.wait()
        guard let data = result else { return nil }
        blocks[index] = data
        order.append(index)
        if order.count > maxBlocks { blocks.removeValue(forKey: order.removeFirst()) }
        return data
    }
}
