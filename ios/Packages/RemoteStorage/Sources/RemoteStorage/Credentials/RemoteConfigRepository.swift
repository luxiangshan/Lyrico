import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Persists remote locations (without secrets) as JSON in a file; secrets go to a `SecretStore` (Keychain).
/// Same JSON shape as the Android app's stored list.
public final class RemoteConfigRepository: @unchecked Sendable {
    public let fileURL: URL
    public let secrets: SecretStore
    private let lock = NSLock()

    /// Default file: `Application Support/RemoteStorage/remote_locations.json`.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RemoteStorage", isDirectory: true).appendingPathComponent("remote_locations.json")
    }

    public init(fileURL: URL = RemoteConfigRepository.defaultFileURL(), secrets: SecretStore) {
        self.fileURL = fileURL
        self.secrets = secrets
    }

    public func all() -> [RemoteLocationConfig] {
        lock.lock(); defer { lock.unlock() }
        return readLocked()
    }

    public func get(_ id: String) -> RemoteLocationConfig? { all().first { $0.id == id } }

    public func secret(for id: String) -> String { secrets.loadSecret(configId: id) ?? "" }

    /// Inserts or replaces `config`. `newSecret == nil` keeps the stored secret (password field left blank while
    /// editing); "" clears it.
    public func save(_ config: RemoteLocationConfig, newSecret: String?) throws {
        if let s = newSecret { try secrets.saveSecret(configId: config.id, secret: s.isEmpty ? nil : s) }
        lock.lock(); defer { lock.unlock() }
        var list = readLocked()
        if let i = list.firstIndex(where: { $0.id == config.id }) {
            var updated = config
            updated.createdAt = list[i].createdAt
            list[i] = updated
        } else {
            list.append(config)
        }
        try writeLocked(list)
    }

    /// Removes the location and all of its secrets.
    public func delete(_ id: String) throws {
        lock.lock()
        var list = readLocked()
        list.removeAll { $0.id == id }
        do { try writeLocked(list) } catch { lock.unlock(); throw error }
        lock.unlock()
        secrets.deleteAll(configId: id)
    }

    private func readLocked() -> [RemoteLocationConfig] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([RemoteLocationConfig].self, from: data)) ?? []
    }

    private func writeLocked(_ list: [RemoteLocationConfig]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(list).write(to: fileURL, options: .atomic)
    }
}

/// Creates the provider implementation for a location, loading its secret from the store.
public final class RemoteStorageFactory: @unchecked Sendable {
    public let secrets: SecretStore
    public var sessionConfiguration: URLSessionConfiguration

    public init(secrets: SecretStore, sessionConfiguration: URLSessionConfiguration = RemoteHTTP.defaultConfiguration()) {
        self.secrets = secrets
        self.sessionConfiguration = sessionConfiguration
    }

    /// - Parameter secretOverride: use this secret instead of the stored one (e.g. testing a form before saving).
    public func makeStorage(for config: RemoteLocationConfig, secretOverride: String? = nil) throws -> RemoteStorage {
        let secret = secretOverride ?? secrets.loadSecret(configId: config.id) ?? ""
        switch config.type {
        case .webdav:
            return try WebDAVStorage(config: config, password: secret, sessionConfiguration: sessionConfiguration)
        case .openList:
            return try OpenListStorage(config: config, password: secret, credentialStore: secrets, sessionConfiguration: sessionConfiguration)
        case .smb:
            #if canImport(AMSMB2)
            return try SMBStorage(config: config, password: secret)
            #else
            throw RemoteStorageError.io("SMB is not available on this platform")
            #endif
        case .cloud115:
            return Cloud115Storage(config: config, cookie: secret, sessionConfiguration: sessionConfiguration)
        }
    }
}

/// Keeps one live storage per location (like the Android RemoteStorageManager); drop on edit/delete/auth failure.
public final class RemoteStorageManager: @unchecked Sendable {
    public let repository: RemoteConfigRepository
    public let factory: RemoteStorageFactory
    private let cache = Locked<[String: (config: RemoteLocationConfig, storage: RemoteStorage)]>([:])

    public init(repository: RemoteConfigRepository, factory: RemoteStorageFactory? = nil) {
        self.repository = repository
        self.factory = factory ?? RemoteStorageFactory(secrets: repository.secrets)
    }

    public func storage(for configId: String) throws -> RemoteStorage {
        guard let config = repository.get(configId) else { throw RemoteStorageError.notFound("Remote location \(configId) not found") }
        if let c = cache.withLock({ $0[configId] }), c.config == config { return c.storage }
        let s = try factory.makeStorage(for: config)
        let old = cache.withLock { m -> RemoteStorage? in
            let o = m[configId]?.storage
            m[configId] = (config, s)
            return o
        }
        if let o = old { Task { await o.close() } }
        return s
    }

    /// Storage for a `remote://<configId>/...` uri plus the decoded path.
    public func resolve(uri: String) throws -> (storage: RemoteStorage, path: String) {
        guard let p = RemoteURI.parse(uri) else { throw RemoteStorageError.invalidArgument("Not a remote uri: \(uri)") }
        return (try storage(for: p.configId), p.path)
    }

    public func invalidate(_ configId: String) {
        if let o = cache.withLock({ $0.removeValue(forKey: configId)?.storage }) { Task { await o.close() } }
    }

    public func invalidateAll() {
        let all = cache.withLock { m -> [RemoteStorage] in let v = m.values.map(\.storage); m.removeAll(); return v }
        for s in all { Task { await s.close() } }
    }
}
