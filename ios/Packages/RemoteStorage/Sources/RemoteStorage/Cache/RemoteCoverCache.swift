import Foundation

/// Small disk cache of embedded front covers of remote songs, so song lists show covers right after a scan without
/// touching the network. Entries are keyed by song uri + file size + mtime; a song known to have no embedded cover
/// is recorded too (so lists don't re-read it). Writes are atomic (temp + rename). Same behaviour as Android.
public final class RemoteCoverCache: @unchecked Sendable {
    public enum Lookup: Equatable, Sendable {
        case hit(Data)
        case noCover
        case miss
    }

    public static let defaultMaxBytes: Int64 = 64 * 1024 * 1024
    static let trimEvery = 50
    private static let img = ".img"
    private static let none = ".none"

    public let directory: URL
    private let maxBytes: Int64
    private let fm = FileManager.default
    private let trimLock = NSLock()
    private let writes = Locked(0)

    /// Default directory: `Caches/remote-covers`.
    public static func defaultDirectory() -> URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("remote-covers", isDirectory: true)
    }

    public init(directory: URL = RemoteCoverCache.defaultDirectory(), maxBytes: Int64 = RemoteCoverCache.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public func get(uri: String, size: Int64, mtime: Int64) -> Lookup {
        let base = baseName(uri, size, mtime)
        let imgURL = directory.appendingPathComponent(base + Self.img)
        if fm.fileExists(atPath: imgURL.path) {
            guard let data = try? Data(contentsOf: imgURL), !data.isEmpty else { return .miss }
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: imgURL.path)
            return .hit(data)
        }
        if fm.fileExists(atPath: directory.appendingPathComponent(base + Self.none).path) { return .noCover }
        return .miss
    }

    /// True when either a cover or a "no cover" marker is stored.
    public func has(uri: String, size: Int64, mtime: Int64) -> Bool {
        let base = baseName(uri, size, mtime)
        return fm.fileExists(atPath: directory.appendingPathComponent(base + Self.img).path)
            || fm.fileExists(atPath: directory.appendingPathComponent(base + Self.none).path)
    }

    /// Stores `bytes` (nil/empty = the song has no embedded cover).
    public func put(uri: String, size: Int64, mtime: Int64, bytes: Data?) {
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = baseName(uri, size, mtime)
        let isImage = !(bytes?.isEmpty ?? true)
        let target = directory.appendingPathComponent(base + (isImage ? Self.img : Self.none))
        let tmp = directory.appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try (bytes ?? Data()).write(to: tmp)
            if fm.fileExists(atPath: target.path) { _ = try? fm.replaceItemAt(target, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: target) }
        } catch {}
        try? fm.removeItem(at: tmp)
        // Drop the opposite marker and entries of older versions of this song.
        try? fm.removeItem(at: directory.appendingPathComponent(base + (isImage ? Self.none : Self.img)))
        let prefix = uriPrefix(uri)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        where name.hasPrefix(prefix) && name != base + Self.img && name != base + Self.none && !name.hasSuffix(".tmp") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        let shouldTrim = writes.withLock { w -> Bool in
            w += 1
            if w >= Self.trimEvery { w = 0; return true }
            return false
        }
        if shouldTrim { trim() }
    }

    /// Forgets every cached cover of `uri` (file changed / renamed / deleted).
    public func invalidate(uri: String) {
        let prefix = uriPrefix(uri)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(prefix) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func clear() { try? fm.removeItem(at: directory) }

    /// Deletes least-recently used entries until the cache is under `maxBytes`.
    public func trim() {
        trimLock.lock(); defer { trimLock.unlock() }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var files: [(URL, Int64, Date)] = []
        for u in urls where !u.lastPathComponent.hasSuffix(".tmp") {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files.append((u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
        }
        var total = files.reduce(Int64(0)) { $0 + $1.1 }
        if total <= maxBytes { return }
        for f in files.sorted(by: { $0.2 < $1.2 }) {
            if total <= maxBytes { break }
            if (try? fm.removeItem(at: f.0)) != nil { total -= f.1 }
        }
    }

    private func uriPrefix(_ uri: String) -> String { String(Hex.lowerHex(IncrementalHash.digest(.sha1, uri)).prefix(32)) + "_" }
    private func baseName(_ uri: String, _ size: Int64, _ mtime: Int64) -> String { "\(uriPrefix(uri))\(size)_\(mtime)" }
}
