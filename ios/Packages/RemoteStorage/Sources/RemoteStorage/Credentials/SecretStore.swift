import Foundation
#if canImport(Security)
import Security
#endif

/// Secrets of remote locations (passwords, 115 cookie) plus provider extras (e.g. the OpenList token cache).
public protocol SecretStore: RemoteCredentialStore {
    func loadSecret(configId: String) -> String?
    /// nil removes the secret.
    func saveSecret(configId: String, secret: String?) throws
    /// Removes the secret and every provider extra of `configId`.
    func deleteAll(configId: String)
}

/// In-memory store (tests, previews).
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let values = Locked<[String: String]>([:])
    public init() {}

    public func loadSecret(configId: String) -> String? { values.withLock { $0["\(configId)|secret"] } }
    public func saveSecret(configId: String, secret: String?) throws { values.withLock { $0["\(configId)|secret"] = secret } }
    public func loadExtra(configId: String, key: String) -> String? { values.withLock { $0["\(configId)|x:\(key)"] } }
    public func saveExtra(configId: String, key: String, value: String?) { values.withLock { $0["\(configId)|x:\(key)"] = value } }
    public func deleteAll(configId: String) {
        values.withLock { v in for k in v.keys where k.hasPrefix("\(configId)|") { v[k] = nil } }
    }
}

#if canImport(Security)
/// Keychain-backed store: one generic-password item per value (service = `service`, account = "<configId>|<name>"),
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (usable by background scans, never synced or backed up).
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public let service: String
    private let accessGroup: String?
    private let lock = NSLock()

    public init(service: String = "com.lonx.lyrico.mod.remote", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func loadSecret(configId: String) -> String? { read(account(configId, "secret")) }
    public func saveSecret(configId: String, secret: String?) throws { try write(account(configId, "secret"), secret) }
    public func loadExtra(configId: String, key: String) -> String? { read(account(configId, "x:\(key)")) }
    public func saveExtra(configId: String, key: String, value: String?) { try? write(account(configId, "x:\(key)"), value) }

    public func deleteAll(configId: String) {
        lock.lock(); defer { lock.unlock() }
        for acct in allAccounts() where acct.hasPrefix("\(configId)|") {
            SecItemDelete(baseQuery(acct) as CFDictionary)
        }
    }

    private func account(_ configId: String, _ name: String) -> String { "\(configId)|\(name)" }

    private func baseQuery(_ account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let a = account { q[kSecAttrAccount as String] = a }
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    private func read(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ account: String, _ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let q = baseQuery(account)
        guard let value = value else {
            SecItemDelete(q as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            for (k, v) in attrs { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    private func allAccounts() -> [String] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain error: \(msg)"
    }
}
#endif
