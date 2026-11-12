import Foundation

/// A folder on this device: the app's Documents directory or a folder picked with
/// UIDocumentPickerViewController (security-scoped bookmark).
final class LocalFolderSource: LibrarySource {
    let kind: LibrarySourceKind
    let displayName: String
    let rootURL: URL
    let rootPath = "/"
    private var accessCount = 0
    private var scoped = false
    private let lock = NSLock()

    init(kind: LibrarySourceKind, displayName: String, rootURL: URL) {
        self.kind = kind
        self.displayName = displayName
        self.rootURL = rootURL
    }

    static func documents() -> LocalFolderSource {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return LocalFolderSource(kind: .documents, displayName: L("ios_documents_folder"), rootURL: url)
    }

    /// Resolves a bookmark; returns the source and a refreshed bookmark if the stored one was stale.
    static func resolve(bookmark: Data, displayName: String) throws -> (LocalFolderSource, Data?) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        var refreshed: Data?
        if stale {
            let ok = url.startAccessingSecurityScopedResource()
            refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            if ok { url.stopAccessingSecurityScopedResource() }
        }
        return (LocalFolderSource(kind: .localFolder, displayName: displayName, rootURL: url), refreshed)
    }

    func beginAccess() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if kind == .documents { return true }
        if accessCount == 0 {
            scoped = rootURL.startAccessingSecurityScopedResource()
        }
        accessCount += 1
        // Even when startAccessing returns false the folder may still be readable (e.g. already granted).
        return scoped || FileManager.default.isReadableFile(atPath: rootURL.path)
    }

    func endAccess() {
        lock.lock(); defer { lock.unlock() }
        if kind == .documents { return }
        accessCount = max(0, accessCount - 1)
        if accessCount == 0 && scoped {
            rootURL.stopAccessingSecurityScopedResource()
            scoped = false
        }
    }

    func url(for path: String) -> URL {
        let rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return rel.isEmpty ? rootURL : rootURL.appendingPathComponent(rel)
    }

    func localURL(for path: String) -> URL? { url(for: path) }

    func testConnection() async throws {
        guard beginAccess() else { throw LibrarySourceError.accessDenied(L("permission_denied_cannot_save")) }
        defer { endAccess() }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LibrarySourceError.notFound(rootURL.path)
        }
    }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]

    func list(_ dirPath: String) async throws -> [LibraryEntry] {
        let dir = url(for: dirPath)
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.keys, options: [.skipsHiddenFiles])
        return items.compactMap { item in
            guard let v = try? item.resourceValues(forKeys: Set(Self.keys)) else { return nil }
            return LibraryEntry(path: joinPath(dirPath, item.lastPathComponent), name: item.lastPathComponent,
                                isDirectory: v.isDirectory ?? false, size: Int64(v.fileSize ?? -1),
                                modified: v.contentModificationDate)
        }
    }

    /// Recursive listing of audio files, used by the scanner (faster than list() per directory).
    func enumerateAudioFiles() -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        guard let e = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: Self.keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        let rootComponents = rootURL.standardizedFileURL.pathComponents.count
        for case let item as URL in e {
            let name = item.lastPathComponent
            guard let v = try? item.resourceValues(forKeys: Set(Self.keys)) else { continue }
            if v.isDirectory == true {
                if AudioFormats.skippedDirectories.contains(name) { e.skipDescendants() }
                continue
            }
            guard AudioFormats.isAudio(name) else { continue }
            let comps = item.standardizedFileURL.pathComponents.dropFirst(rootComponents)
            let rel = "/" + comps.joined(separator: "/")
            out.append(LibraryEntry(path: rel, name: name, isDirectory: false, size: Int64(v.fileSize ?? 0),
                                    modified: v.contentModificationDate))
        }
        return out
    }

    func stat(_ path: String) async throws -> LibraryEntry? {
        let u = url(for: path)
        guard let v = try? u.resourceValues(forKeys: Set(Self.keys)) else { return nil }
        return LibraryEntry(path: path, name: u.lastPathComponent, isDirectory: v.isDirectory ?? false,
                            size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate)
    }

    func openRange(_ path: String, offset: Int64, length: Int64) async throws -> Data {
        let h = try FileHandle(forReadingFrom: url(for: path))
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(max(0, offset)))
        if length < 0 { return try h.readToEnd() ?? Data() }
        return try h.read(upToCount: Int(length)) ?? Data()
    }

    func download(_ path: String, to localURL: URL) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) { try fm.removeItem(at: localURL) }
        try fm.copyItem(at: url(for: path), to: localURL)
    }

    func upload(_ path: String, from localURL: URL) async throws {
        let target = url(for: path)
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordError) { dest in
            do {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: localURL)
            } catch { thrown = error }
        }
        if let e = coordError ?? thrown { throw e }
    }

    func rename(_ path: String, newName: String) async throws -> String {
        let src = url(for: path)
        let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
        if dst.path != src.path {
            if FileManager.default.fileExists(atPath: dst.path), dst.path.lowercased() != src.path.lowercased() {
                throw LibrarySourceError.unavailable(L("rename_conflict_warning"))
            }
            var coordError: NSError?
            var thrown: Error?
            NSFileCoordinator().coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &coordError) { s, d in
                do { try FileManager.default.moveItem(at: s, to: d) } catch { thrown = error }
            }
            if let e = coordError ?? thrown { throw e }
        }
        let dir = (path as NSString).deletingLastPathComponent
        return joinPath(dir.isEmpty ? "/" : dir, newName)
    }

    func delete(_ path: String) async throws {
        let target = url(for: path)
        var coordError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forDeleting, error: &coordError) { u in
            do { try FileManager.default.removeItem(at: u) } catch { thrown = error }
        }
        if let e = coordError ?? thrown { throw e }
    }
}
