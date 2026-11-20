import Foundation
import GRDB

/// Reads and writes song files through their LibrarySource (Android AudioTagRepositoryImpl +
/// SongFileRepositoryImpl). Local files are edited in place; remote files are downloaded to a
/// cache copy, edited, then uploaded back.
enum SongFileService {
    struct ServiceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func source(for song: SongRecord) throws -> LibrarySource {
        guard let folder = LibraryManager.shared.folder(id: song.folderId) else {
            throw ServiceError(message: L("ios_folder_missing"))
        }
        return try LibraryManager.shared.source(for: folder)
    }

    static var editCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("remote-edit", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs `body` with a readable local URL for the song (security scope active / remote copy).
    static func withReadableFile<T>(_ song: SongRecord, _ body: @escaping (URL) throws -> T) async throws -> T {
        let src = try await source(for: song)
        guard src.beginAccess() else { throw ServiceError(message: L("permission_denied_cannot_save")) }
        defer { src.endAccess() }
        if let url = src.localURL(for: song.relativePath) {
            return try await Task.detached(priority: .userInitiated) { try body(url) }.value
        }
        let local = editCacheDir.appendingPathComponent(cacheName(song))
        try await src.download(song.relativePath, to: local)
        return try await Task.detached(priority: .userInitiated) { try body(local) }.value
    }

    /// Runs `body` on a writable URL, then uploads for remote sources.
    static func withWritableFile<T>(_ song: SongRecord, _ body: @escaping (URL) throws -> T) async throws -> T {
        let src = try await source(for: song)
        guard src.beginAccess() else { throw ServiceError(message: L("permission_denied_cannot_save")) }
        defer { src.endAccess() }
        if let url = src.localURL(for: song.relativePath) {
            return try await Task.detached(priority: .userInitiated) { () throws -> T in
                var result: Result<T, Error>!
                var coordError: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
                    result = Result { try body(u) }
                }
                if let coordError { throw coordError }
                return try result.get()
            }.value
        }
        let local = editCacheDir.appendingPathComponent(cacheName(song))
        try await src.download(song.relativePath, to: local)
        let value = try await Task.detached(priority: .userInitiated) { try body(local) }.value
        try await src.upload(song.relativePath, from: local)
        return value
    }

    private static func cacheName(_ song: SongRecord) -> String {
        let ext = (song.fileName as NSString).pathExtension
        return "\(abs(song.uri.hashValue))-\(song.fileSize).\(ext)"
    }

    /// Full tag read (with pictures) for the editor.
    static func readTags(_ song: SongRecord, readPictures: Bool = true) async throws -> AudioTagData {
        let sep = AppSettings.shared.multiValueSeparator
        if try await source(for: song).kind.isRemote {
            // Ranged read: only the tag area is fetched.
            let src = try await source(for: song)
            let reader = RemoteRangeReader(source: src, path: song.relativePath, length: song.fileSize)
            return try await RemoteTagIO.runThrowing { () throws -> AudioTagData in
                try AudioTagReader.read(reader: reader, fileName: song.fileName, readPictures: readPictures, multiValueSeparator: sep)
            }
        }
        return try await withReadableFile(song) { url in
            try AudioTagReader.read(url, readPictures: readPictures, multiValueSeparator: sep, strict: true)
        }
    }

    /// Applies a mutation (fields, custom fields, pictures), re-reads the file and updates the database.
    @discardableResult
    static func apply(_ mutation: AudioTagMutation, to song: SongRecord, current: AudioTagData? = nil) async throws -> SongRecord {
        let sep = AppSettings.shared.multiValueSeparator
        let ext = (song.fileName as NSString).pathExtension
        let readBack: AudioTagData = try await withWritableFile(song) { url in
            try writeMutation(mutation, to: url, fileExtension: ext, current: current, separator: sep)
        }
        var updated = song
        updated.apply(tag: readBack)
        if let src = try? await source(for: song), let st = try? await src.stat(song.relativePath) {
            updated.fileSize = max(0, st.size)
            updated.fileLastModified = st.modified?.timeIntervalSince1970 ?? updated.fileLastModified
        }
        if mutation.pictureUpdate != .unchanged { updated.hasCover = nil }
        let toSave = updated
        try await AppDatabase.shared.pool.write { db in try toSave.update(db) }
        CoverCache.shared.invalidate(song)
        return updated
    }

    /// Writes a mutation to a local file and returns the re-read tags (without pictures).
    static func writeMutation(_ mutation: AudioTagMutation, to url: URL, fileExtension ext: String,
                              current: AudioTagData?, separator sep: String) throws -> AudioTagData {
        let base = try current ?? AudioTagReader.read(url, readPictures: true, multiValueSeparator: sep, strict: true)
        let updates = TagMapBuilder.build(fileExtension: ext, current: base, mutation: mutation)
        if !updates.isEmpty {
            try AudioTagWriter.writeTags(url, updates: updates, preserveOldTags: mutation.mode == .patch)
        }
        func existing() -> [AudioPicture] {
            TagLib.getPictures(url).map { AudioPicture(data: $0.data, mimeType: $0.mimeType, description: $0.description, pictureType: $0.pictureType) }
        }
        switch mutation.pictureUpdate {
        case .unchanged: break
        case .removeAllPictures:
            try AudioTagWriter.writePictures(url, pictures: [])
        case .removeFrontCover:
            // MP4 pictures carry no type (empty name): removing the front cover removes them too.
            try AudioTagWriter.writePictures(url, pictures: existing().filter { $0.type != .frontCover && !$0.pictureType.isEmpty })
        case .replaceFrontCover(let data, let mime):
            let newPic = AudioPicture(data: data, mimeType: mime, description: "", pictureType: AudioPictureType.frontCover.tagLibName)
            let others = existing().filter { !$0.pictureType.isEmpty }
            try AudioTagWriter.writePictures(url, pictures: others.replacePicture(newPic, type: .frontCover))
        case .replaceAll(let pictures):
            try AudioTagWriter.writePictures(url, pictures: pictures)
        }
        return try AudioTagReader.read(url, readPictures: false, multiValueSeparator: sep, strict: true)
    }

    /// Renames the file (same folder). Adds " (n)" on conflicts like Android.
    @discardableResult
    static func rename(_ song: SongRecord, to rawName: String) async throws -> SongRecord {
        let ext = (song.fileName as NSString).pathExtension
        var base = sanitizeFileName(rawName)
        if base.lowercased().hasSuffix("." + ext.lowercased()) { base = String(base.dropLast(ext.count + 1)) }
        guard !base.isEmpty else { throw ServiceError(message: L("invalid_empty_input")) }
        let src = try await source(for: song)
        guard src.beginAccess() else { throw ServiceError(message: L("permission_denied_cannot_save")) }
        defer { src.endAccess() }
        let dir = song.directory
        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        if candidate == song.fileName { return song }
        var n = 1
        func exists(_ name: String) async -> Bool {
            let entry = try? await src.stat(joinPath(dir, name))
            return entry != nil
        }
        while candidate.lowercased() != song.fileName.lowercased(), await exists(candidate) {
            n += 1
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
        }
        let newPath = try await src.rename(song.relativePath, newName: candidate)
        guard let folder = await LibraryManager.shared.folder(id: song.folderId) else { return song }
        var updated = song
        updated.relativePath = newPath
        updated.fileName = (newPath as NSString).lastPathComponent
        updated.fileExtension = ext.lowercased()
        updated.uri = SongURI.make(folder: folder, path: newPath)
        updated.titleSortKey = SortKeys.sortKey(updated.displayTitle)
        let toSave = updated
        try await AppDatabase.shared.pool.write { db in try toSave.update(db) }
        CoverCache.shared.invalidate(song)
        return updated
    }

    static func delete(_ song: SongRecord) async throws {
        let src = try await source(for: song)
        guard src.beginAccess() else { throw ServiceError(message: L("permission_denied_cannot_save")) }
        defer { src.endAccess() }
        try await src.delete(song.relativePath)
        let id = song.id
        let folderId = song.folderId
        try await AppDatabase.shared.pool.write { db in
            if let id { _ = try SongRecord.deleteOne(db, key: id) }
            try db.execute(sql: "UPDATE folders SET songCount = (SELECT COUNT(*) FROM songs WHERE folderId = ?) WHERE id = ?", arguments: [folderId, folderId])
        }
        CoverCache.shared.invalidate(song)
    }

    /// Copies songs into a temporary share folder (so the share sheet does not depend on
    /// security-scoped access) and returns the URLs.
    static func shareableURLs(_ songs: [SongRecord]) async -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("share-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for song in songs {
            let target = dir.appendingPathComponent(song.fileName)
            let ok: Bool = (try? await withReadableFile(song) { url in
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: url, to: target)
                return true
            }) ?? false
            if ok { urls.append(target) }
        }
        return urls
    }

    static func sanitizeFileName(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\u{0}")
        return name.components(separatedBy: illegal).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func fetch(ids: [Int64]) async -> [SongRecord] {
        (try? await AppDatabase.shared.pool.read { db in try SongRecord.fetchAll(db, keys: ids) }) ?? []
    }
}
