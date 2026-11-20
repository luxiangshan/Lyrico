// Wires the RemoteStorage package (ios/Packages/RemoteStorage: WebDAV, OpenList, SMB, 115) into the app.
import Foundation
#if canImport(RemoteStorage)
import RemoteStorage
#endif

enum RemoteIntegration {
    static var isPackageLinked: Bool {
        #if canImport(RemoteStorage)
        return true
        #else
        return false
        #endif
    }

    /// Called once at app start (LyricoModApp.init).
    static func register() {
        #if canImport(RemoteStorage)
        RemoteStorageRegistry.shared.factory = { location in try PackageRemoteClient(location) }
        #endif
    }

    /// Creates a client for an unsaved form (testing before saving). Not cached.
    static func makeClient(_ location: RemoteLocation) throws -> RemoteStorageClient {
        guard let factory = RemoteStorageRegistry.shared.factory else { throw LibrarySourceError.unsupported }
        return try factory(location)
    }
}

#if canImport(RemoteStorage)

/// Secrets for the package: the location secret comes from `RemoteLocation.secret`
/// (passed as override); provider extras (OpenList token) go to the app Keychain wrapper.
final class AppRemoteSecretStore: SecretStore, @unchecked Sendable {
    static let shared = AppRemoteSecretStore()

    func loadSecret(configId: String) -> String? { Keychain.read(account: "remote." + configId) }
    func saveSecret(configId: String, secret: String?) throws { Keychain.write(account: "remote." + configId, value: secret) }
    func loadExtra(configId: String, key: String) -> String? { Keychain.read(account: "remote.\(configId).x.\(key)") }
    func saveExtra(configId: String, key: String, value: String?) { Keychain.write(account: "remote.\(configId).x.\(key)", value: value) }
    func deleteAll(configId: String) {
        Keychain.write(account: "remote." + configId, value: nil)
        for key in ["token"] { Keychain.write(account: "remote.\(configId).x.\(key)", value: nil) }
    }
}

extension RemoteKind {
    var packageType: RemoteType {
        switch self {
        case .webdav: return .webdav
        case .openlist: return .openList
        case .smb: return .smb
        case .cloud115: return .cloud115
        }
    }
}

extension RemoteLocation {
    var packageConfig: RemoteLocationConfig {
        RemoteLocationConfig(id: id, type: type.packageType, displayName: displayName, baseURL: baseUrl,
                             share: share, username: username, domain: domain, folders: folders)
    }
}

/// Adapts a package `RemoteStorage` to the app's `RemoteStorageClient`.
final class PackageRemoteClient: RemoteStorageClient {
    let config: RemoteLocation
    private let storage: RemoteStorage

    private static let factory = RemoteStorageFactory(secrets: AppRemoteSecretStore.shared)

    init(_ location: RemoteLocation) throws {
        config = location
        do {
            storage = try Self.factory.makeStorage(for: location.packageConfig, secretOverride: location.secret)
        } catch {
            throw Self.map(error)
        }
    }

    func testConnection() async throws {
        do { try await storage.testConnection() } catch { throw Self.map(error) }
    }

    func list(_ dirPath: String) async throws -> [LibraryEntry] {
        do { return try await storage.list(dirPath).map(Self.entry) } catch { throw Self.map(error) }
    }

    func stat(_ path: String) async throws -> LibraryEntry? {
        do { return try await storage.stat(path).map(Self.entry) } catch { throw Self.map(error) }
    }

    func openRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        do { return try await storage.readRange(path, offset: offset, length: length) } catch { throw Self.map(error) }
    }

    func download(_ path: String, to localURL: URL) async throws {
        do { try await storage.download(path, to: localURL) } catch { throw Self.map(error) }
    }

    func upload(_ path: String, from localURL: URL) async throws {
        do { try await storage.upload(from: localURL, to: path) } catch { throw Self.map(error) }
    }

    func rename(_ path: String, newName: String) async throws -> String {
        do { return try await storage.rename(path, to: newName) } catch { throw Self.map(error) }
    }

    func delete(_ path: String) async throws {
        do { try await storage.delete(path) } catch { throw Self.map(error) }
    }

    func close() {
        let s = storage
        Task.detached { await s.close() }
    }

    private static func entry(_ e: RemoteEntry) -> LibraryEntry {
        LibraryEntry(path: e.path, name: e.name, isDirectory: e.isDirectory, size: e.size,
                     modified: e.modificationDate, providerId: e.providerId)
    }

    private static func map(_ error: Error) -> Error {
        if let e = error as? RemoteStorageError {
            switch e {
            case .notFound(let m): return LibrarySourceError.notFound(m)
            case .auth(let m): return LibrarySourceError.accessDenied(m)
            default: return LibrarySourceError.unavailable(e.message)
            }
        }
        return error
    }
}

/// 115 QR login, exposed without leaking package types into views.
final class Cloud115QRLoginFlow {
    struct Code: Equatable { let content: String; fileprivate let session: Cloud115QRLogin.Session }
    enum Status { case waiting, scanned, confirmed, expired, cancelled }

    private let login = Cloud115QRLogin()

    func start() async throws -> Code {
        let s = try await login.start()
        return Code(content: s.qrContent, session: s)
    }

    /// Polls until confirmed, then returns the cookie (nil on expiry/cancel).
    func awaitCookie(_ code: Code, onStatus: @escaping (Status) -> Void) async throws -> String? {
        try await login.awaitCookie(code.session, timeout: 300) { s in
            let mapped: Status
            switch s {
            case .waiting: mapped = .waiting
            case .scanned: mapped = .scanned
            case .confirmed: mapped = .confirmed
            case .expired: mapped = .expired
            case .cancelled: mapped = .cancelled
            }
            DispatchQueue.main.async { onStatus(mapped) }
        }
    }

    /// Normalizes a pasted cookie; nil when UID/CID/SEID are missing.
    static func normalizeCookie(_ raw: String) -> String? {
        Cloud115Credential.parse(raw)?.cookie
    }
}
#else
final class Cloud115QRLoginFlow {
    struct Code: Equatable { let content: String }
    enum Status { case waiting, scanned, confirmed, expired, cancelled }
    func start() async throws -> Code { throw LibrarySourceError.unsupported }
    func awaitCookie(_ code: Code, onStatus: @escaping (Status) -> Void) async throws -> String? { nil }
    static func normalizeCookie(_ raw: String) -> String? { nil }
}
#endif
