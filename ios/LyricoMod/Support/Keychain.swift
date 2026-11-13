import Foundation
import Security

/// Small secret store for remote location passwords / cookies.
///
/// Uses the Keychain when it works. Builds installed with TrollStore or re-signed without a
/// keychain-access-groups entitlement get errSecMissingEntitlement (-34018) from the Keychain; then the
/// value is kept in a file in Application Support that is excluded from backup and protected with
/// iOS data protection, so remote locations still work.
enum Keychain {
    private static let service = "com.lonx.lyrico.mod"
    private static let lock = NSLock()

    static func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return FallbackStore.read(account)
    }

    static func write(account: String, value: String?) {
        lock.lock(); defer { lock.unlock() }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else {
            FallbackStore.write(account, nil)
            return
        }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
            FallbackStore.write(account, nil)
        } else {
            FallbackStore.write(account, value)
        }
    }

    /// File fallback (see type comment).
    private enum FallbackStore {
        static var url: URL {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return dir.appendingPathComponent("secure", isDirectory: true).appendingPathComponent("secrets.plist")
        }

        static func load() -> [String: String] {
            guard let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
            return dict
        }

        static func read(_ key: String) -> String? { load()[key] }

        static func write(_ key: String, _ value: String?) {
            var dict = load()
            if dict[key] == value { return }
            dict[key] = value
            let fm = FileManager.default
            var dir = url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
            if dict.isEmpty {
                try? fm.removeItem(at: url)
                return
            }
            if let data = try? PropertyListEncoder().encode(dict) {
                try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    }
}
