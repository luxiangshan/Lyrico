import Foundation
import GRDB
import SwiftUI

/// Scan progress shown in the song list (Android LibraryScanRepository progress).
struct ScanProgress: Equatable {
    enum Phase: Equatable { case idle, listing, reading(Int, Int), writing, finished }
    var phase: Phase = .idle
    var folderName: String = ""
    var errors: [String] = []

    var isRunning: Bool {
        switch phase {
        case .idle, .finished: return false
        default: return true
        }
    }

    var text: String {
        switch phase {
        case .idle: return ""
        case .listing: return L("scan_progress_listing")
        case .reading(let a, let b): return L("scan_progress_reading", a, b)
        case .writing: return L("scan_progress_writing")
        case .finished: return L("scan_progress_finished")
        }
    }
}

/// Owns library folders, their sources, and scanning (Android LibraryFolderRepository +
/// LibraryScanRepositoryImpl).
@MainActor
final class LibraryManager: ObservableObject {
    static let shared = LibraryManager()

    @Published private(set) var folders: [FolderRecord] = []
    @Published private(set) var scan = ScanProgress()
    @Published var lastError: String?

    let db = AppDatabase.shared
    private var folderObservation: AnyDatabaseCancellable?
    private var sources: [Int64: LibrarySource] = [:]
    private var scanTask: Task<Void, Never>?
    private var pendingFolderIds: Set<Int64>? = nil
    private var rescanRequested = false

    private init() {
        ensureDocumentsFolder()
        folderObservation = ValueObservation
            .tracking { db in try FolderRecord.order(Column("id")).fetchAll(db) }
            .start(in: db.pool, scheduling: .immediate, onError: { _ in }, onChange: { [weak self] in self?.folders = $0 })
    }

    // MARK: Folders

    private func ensureDocumentsFolder() {
        try? db.pool.write { db in
            if try FolderRecord.filter(Column("kind") == FolderKind.documents.rawValue).fetchCount(db) == 0 {
                var f = FolderRecord(kind: .documents, displayName: "Documents", path: "/", bookmark: nil, sourceId: nil)
                try f.insert(db)
            }
        }
        // Make sure the Files app shows our Documents folder even when empty.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let readme = docs.appendingPathComponent(".lyrico")
        if !FileManager.default.fileExists(atPath: readme.path) {
            FileManager.default.createFile(atPath: readme.path, contents: Data())
        }
    }

    func source(for folder: FolderRecord) throws -> LibrarySource {
        guard let id = folder.id else { throw LibrarySourceError.notFound(folder.displayName) }
        if let s = sources[id] { return s }
        let s: LibrarySource
        switch folder.kind {
        case .documents:
            s = LocalFolderSource.documents()
        case .local:
            guard let bookmark = folder.bookmark else { throw LibrarySourceError.accessDenied(folder.displayName) }
            let (src, refreshed) = try LocalFolderSource.resolve(bookmark: bookmark, displayName: folder.displayName)
            if let refreshed {
                try? db.pool.write { db in
                    try db.execute(sql: "UPDATE folders SET bookmark = ? WHERE id = ?", arguments: [refreshed, id])
                }
            }
            s = src
        case .remote:
            guard let locId = folder.sourceId, let location = RemoteLocationStore.shared.config(id: locId) else {
                throw LibrarySourceError.unsupported
            }
            let client = try RemoteStorageRegistry.shared.client(for: location)
            s = RemoteLibrarySource(client: client, rootPath: folder.path)
        }
        sources[id] = s
        return s
    }

    func folder(id: Int64) -> FolderRecord? { folders.first { $0.id == id } }

    /// Adds a folder picked with UIDocumentPickerViewController (URL is security-scoped).
    func addLocalFolder(_ url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var record = FolderRecord(kind: .local, displayName: url.lastPathComponent, path: url.path, bookmark: bookmark, sourceId: nil)
            try db.pool.write { db in
                if let existing = try FolderRecord.filter(Column("kind") == FolderKind.local.rawValue && Column("path") == url.path).fetchOne(db) {
                    record.id = existing.id
                    try record.update(db)
                } else {
                    try record.insert(db)
                }
            }
            if let id = record.id {
                sources[id] = nil
                startScan(folderIds: [id])
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Adds remote folders for a saved location (used by the RemoteStorage integration UI).
    func addRemoteFolders(location: RemoteLocation, paths: [String]) {
        RemoteLocationStore.shared.save(location)
        var ids: [Int64] = []
        try? db.pool.write { db in
            for p in paths {
                if try FolderRecord.filter(Column("sourceId") == location.id && Column("path") == p).fetchCount(db) > 0 { continue }
                let name = p == "/" ? location.displayName : (p as NSString).lastPathComponent
                var f = FolderRecord(kind: .remote, displayName: name, path: p, bookmark: nil, sourceId: location.id)
                try f.insert(db)
                if let id = f.id { ids.append(id) }
            }
        }
        if !ids.isEmpty { startScan(folderIds: Set(ids)) }
    }

    /// Saves a remote location and makes its library folders exactly `paths` (added folders are
    /// scanned; folders no longer selected are removed with their songs). Existing folders are rescanned
    /// because the connection settings may have changed.
    func saveRemoteLocation(_ location: RemoteLocation, paths: [String]) {
        RemoteLocationStore.shared.save(location)
        let wanted = Set(paths)
        var ids: Set<Int64> = []
        try? db.pool.write { db in
            let existing = try FolderRecord.filter(Column("sourceId") == location.id).fetchAll(db)
            for f in existing where f.kind == .remote {
                guard let id = f.id else { continue }
                if wanted.contains(f.path) {
                    ids.insert(id)
                } else {
                    try db.execute(sql: "DELETE FROM songs WHERE folderId = ?", arguments: [id])
                    _ = try FolderRecord.deleteOne(db, key: id)
                }
            }
            let have = Set(existing.map(\.path))
            for p in paths where !have.contains(p) {
                let name = p == "/" ? location.displayName : (p as NSString).lastPathComponent
                var f = FolderRecord(kind: .remote, displayName: name, path: p, bookmark: nil, sourceId: location.id)
                try f.insert(db)
                if let id = f.id { ids.insert(id) }
            }
        }
        for id in ids { sources[id] = nil }
        if !ids.isEmpty { startScan(folderIds: ids) }
    }

    func removeFolder(_ folder: FolderRecord) {
        guard let id = folder.id, folder.kind != .documents else { return }
        sources[id] = nil
        _ = try? db.pool.write { db in try FolderRecord.deleteOne(db, key: id) }
        if folder.kind == .remote, let loc = folder.sourceId {
            let remaining = (try? db.pool.read { db in try FolderRecord.filter(Column("sourceId") == loc).fetchCount(db) }) ?? 0
            if remaining == 0 { RemoteLocationStore.shared.remove(id: loc) }
        }
    }

    func setIgnored(_ folder: FolderRecord, _ ignored: Bool) {
        guard let id = folder.id else { return }
        try? db.pool.write { db in
            try db.execute(sql: "UPDATE folders SET isIgnored = ? WHERE id = ?", arguments: [ignored, id])
        }
    }

    func clearLibrary() {
        try? db.pool.write { db in
            try db.execute(sql: "DELETE FROM songs")
            try db.execute(sql: "UPDATE folders SET songCount = 0")
        }
        CoverCache.shared.clear()
    }

    // MARK: Scanning

    func startScan(folderIds: Set<Int64>? = nil) {
        if scanTask != nil {
            // Merge into a follow-up scan.
            if let ids = folderIds, pendingFolderIds != nil {
                pendingFolderIds?.formUnion(ids)
            } else {
                pendingFolderIds = nil
            }
            rescanRequested = true
            return
        }
        let targets = folders.filter { f in
            guard let id = f.id, !f.isIgnored else { return false }
            return folderIds?.contains(id) ?? true
        }
        scan = ScanProgress(phase: .listing)
        scanTask = Task { [weak self] in
            guard let self else { return }
            var errors: [String] = []
            for folder in targets {
                if Task.isCancelled { break }
                do {
                    try await self.scanFolder(folder)
                } catch {
                    errors.append("\(folder.displayName): \(error.localizedDescription)")
                }
            }
            self.scan = ScanProgress(phase: .finished, folderName: "", errors: errors)
            self.scanTask = nil
            if self.rescanRequested {
                self.rescanRequested = false
                let ids = self.pendingFolderIds
                self.pendingFolderIds = nil
                self.startScan(folderIds: ids)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if case .finished = self.scan.phase { self.scan.phase = .idle }
            }
        }
    }

    private struct Known { let id: Int64; let size: Int64; let modified: Double }

    private func scanFolder(_ folder: FolderRecord) async throws {
        guard let folderId = folder.id else { return }
        let source = try self.source(for: folder)
        scan.folderName = folder.displayName
        scan.phase = .listing
        guard source.beginAccess() else { throw LibrarySourceError.accessDenied(folder.displayName) }
        defer { source.endAccess() }

        let entries: [LibraryEntry]
        if let local = source as? LocalFolderSource {
            entries = await Task.detached { local.enumerateAudioFiles() }.value
        } else {
            entries = try await Self.listRecursively(source, source.rootPath)
        }

        let known: [String: Known] = try await db.pool.read { db in
            var map: [String: Known] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, uri, fileSize, fileLastModified FROM songs WHERE folderId = ?", arguments: [folderId])
            for r in rows {
                map[r["uri"]] = Known(id: r["id"], size: r["fileSize"], modified: r["fileLastModified"])
            }
            return map
        }

        let separator = AppSettings.shared.multiValueSeparator
        let ignoreShort = AppSettings.shared.ignoreShortAudio
        var seen = Set<String>()
        var changed: [LibraryEntry] = []
        for e in entries {
            let uri = SongURI.make(folder: folder, path: e.path)
            seen.insert(uri)
            let mtime = e.modified?.timeIntervalSince1970 ?? 0
            if let k = known[uri], k.size == e.size, abs(k.modified - mtime) < 1 { continue }
            changed.append(e)
        }

        var batch: [SongRecord] = []
        var done = 0
        let total = changed.count
        scan.phase = .reading(0, total)
        // Remote reads are network bound: read a few files at a time (Android scans remote folders in parallel).
        let width = source.kind.isRemote ? 4 : 1
        var tags: [String: AudioTagData] = [:]
        for (index, e) in changed.enumerated() {
            if Task.isCancelled { break }
            if index % width == 0 {
                let chunk = Array(changed[index..<min(index + width, changed.count)])
                tags = await withTaskGroup(of: (String, AudioTagData?).self) { group in
                    for c in chunk { group.addTask { (c.path, await Self.readTag(source: source, entry: c, separator: separator)) } }
                    var out: [String: AudioTagData] = [:]
                    for await (p, t) in group { if let t { out[p] = t } }
                    return out
                }
            }
            let uri = SongURI.make(folder: folder, path: e.path)
            let tag = tags[e.path]
            done += 1
            if done % 5 == 0 || done == total { scan.phase = .reading(done, total) }
            if ignoreShort, let tag, tag.durationMilliseconds > 0, tag.durationMilliseconds < 60_000 {
                seen.remove(uri)
                continue
            }
            var song = SongRecord(folderId: folderId, uri: uri, source: source.kind.isRemote ? "REMOTE" : "LOCAL",
                                  relativePath: e.path, fileName: e.name,
                                  fileExtension: (e.name as NSString).pathExtension.lowercased(),
                                  fileSize: max(0, e.size))
            song.fileLastModified = e.modified?.timeIntervalSince1970 ?? 0
            song.fileAdded = Date().timeIntervalSince1970
            song.apply(tag: tag ?? AudioTagData())
            if let k = known[uri] { song.id = k.id }
            batch.append(song)
            if batch.count >= 20 {
                try await flush(batch)
                batch.removeAll()
            }
        }
        scan.phase = .writing
        try await flush(batch)

        let removed = known.keys.filter { !seen.contains($0) }
        try await db.pool.write { db in
            for chunk in stride(from: 0, to: removed.count, by: 500) {
                let part = Array(removed[chunk..<min(chunk + 500, removed.count)])
                try SongRecord.filter(part.contains(Column("uri"))).deleteAll(db)
            }
            let count = try SongRecord.filter(Column("folderId") == folderId).fetchCount(db)
            try db.execute(sql: "UPDATE folders SET songCount = ?, lastScanned = ? WHERE id = ?", arguments: [count, Date(), folderId])
        }
    }

    private func flush(_ batch: [SongRecord]) async throws {
        guard !batch.isEmpty else { return }
        try await db.pool.write { db in
            for var s in batch {
                if s.id != nil {
                    try s.update(db)
                } else if let existing = try SongRecord.filter(Column("uri") == s.uri).fetchOne(db) {
                    s.id = existing.id
                    s.fileAdded = existing.fileAdded
                    try s.update(db)
                } else {
                    try s.insert(db)
                }
            }
        }
    }

    nonisolated static func readTag(source: LibrarySource, entry: LibraryEntry, separator: String) async -> AudioTagData? {
        // TagLib reads synchronously and RemoteRangeReader blocks while it fetches blocks, so run this on a
        // GCD thread instead of Swift's small cooperative pool (blocking that pool can stall the fetches).
        await withCheckedContinuation { (cont: CheckedContinuation<AudioTagData?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                if let url = source.localURL(for: entry.path) {
                    cont.resume(returning: try? AudioTagReader.read(url, readPictures: false, multiValueSeparator: separator, strict: true))
                    return
                }
                let reader = RemoteRangeReader(source: source, path: entry.path, length: entry.size)
                cont.resume(returning: try? AudioTagReader.read(reader: reader, fileName: entry.name, readPictures: false, multiValueSeparator: separator))
            }
        }
    }

    nonisolated static func listRecursively(_ source: LibrarySource, _ dir: String, depth: Int = 0) async throws -> [LibraryEntry] {
        guard depth < 32 else { return [] }
        var out: [LibraryEntry] = []
        for e in try await source.list(dir) {
            if e.isDirectory {
                if e.name.hasPrefix(".") || AudioFormats.skippedDirectories.contains(e.name) { continue }
                out += try await listRecursively(source, e.path, depth: depth + 1)
            } else if AudioFormats.isAudio(e.name) {
                out.append(e)
            }
        }
        return out
    }
}

enum SongURI {
    static func make(folder: FolderRecord, path: String) -> String {
        switch folder.kind {
        case .remote:
            let enc = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            return "remote://\(folder.sourceId ?? "")\(enc)"
        default:
            return "local://\(folder.id ?? 0)\(path)"
        }
    }
}
