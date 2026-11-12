import Foundation
import GRDB
import SwiftUI
import UIKit

/// What the editor works on: a library song, or a file opened from another app (Files "Open in").
enum EditorTarget {
    case song(SongRecord)
    case file(URL)

    var fileName: String {
        switch self {
        case .song(let s): return s.fileName
        case .file(let u): return u.lastPathComponent
        }
    }
}

@MainActor
final class SongEditorModel: ObservableObject {
    @Published var target: EditorTarget?
    @Published var original = AudioTagData()
    @Published var edited = AudioTagData()
    @Published var coverData: Data?
    @Published var pictureUpdate: PictureUpdate = .unchanged
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var loadError: String?
    @Published var message: BannerMessage?

    var song: SongRecord? {
        if case .song(let s) = target { return s }
        return nil
    }

    var hasChanges: Bool {
        pictureUpdate != .unchanged || !AudioTagMutation.diff(original: original, edited: edited).isEmpty
    }

    func load(songId: Int64) async {
        guard let song = try? await AppDatabase.shared.pool.read({ db in try SongRecord.fetchOne(db, key: songId) }) else {
            loadError = L("ios_folder_missing")
            isLoading = false
            return
        }
        target = .song(song)
        await reload()
    }

    func load(url: URL) async {
        target = .file(url)
        await reload()
    }

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let data: AudioTagData
            switch target {
            case .song(let s): data = try await SongFileService.readTags(s, readPictures: true)
            case .file(let url):
                let sep = AppSettings.shared.multiValueSeparator
                data = try await Task.detached {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    return try AudioTagReader.read(url, readPictures: true, multiValueSeparator: sep, strict: true)
                }.value
            case nil: return
            }
            original = data
            edited = data
            coverData = data.pictures.frontCoverOrFallback()?.data
            pictureUpdate = .unchanged
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func binding(_ key: AudioTagFieldKey) -> Binding<String> {
        Binding(get: { key.value(in: self.edited) ?? "" }, set: { key.set($0, in: &self.edited) })
    }

    func revert() {
        edited = original
        coverData = original.pictures.frontCoverOrFallback()?.data
        pictureUpdate = .unchanged
    }

    func setCover(_ data: Data) {
        let mime = ImageMime.detect(data)
        coverData = data
        pictureUpdate = .replaceFrontCover(data: data, mimeType: mime)
    }

    func removeCover() {
        coverData = nil
        pictureUpdate = .removeFrontCover
    }

    func save() async {
        guard let target else { return }
        let mutation = AudioTagMutation.diff(original: original, edited: edited, pictureUpdate: pictureUpdate)
        guard !mutation.isEmpty else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            switch target {
            case .song(let s):
                let updated = try await SongFileService.apply(mutation, to: s, current: original)
                self.target = .song(updated)
            case .file(let url):
                let sep = AppSettings.shared.multiValueSeparator
                let current = original
                _ = try await Task.detached {
                    let ok = url.startAccessingSecurityScopedResource()
                    defer { if ok { url.stopAccessingSecurityScopedResource() } }
                    var result: Result<AudioTagData, Error>!
                    var coordError: NSError?
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
                        result = Result { try SongFileService.writeMutation(mutation, to: u, fileExtension: url.pathExtension, current: current, separator: sep) }
                    }
                    if let coordError { throw coordError }
                    return try result.get()
                }.value
            }
            message = BannerMessage(text: L("msg_save_success"))
            await reload()
        } catch {
            message = BannerMessage(text: L("msg_save_failed_with_reason", error.localizedDescription), isError: true)
        }
    }

    /// Writes the current cover to a temp file for sharing.
    func coverFileURL() -> URL? {
        guard let coverData else { return nil }
        let ext = ImageMime.detect(coverData) == "image/png" ? "png" : "jpg"
        let base = ((target?.fileName ?? "cover") as NSString).deletingPathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).\(ext)")
        try? coverData.write(to: url)
        return url
    }

    func lyricsFileURL() -> URL? {
        guard let lyrics = edited.lyrics, !lyrics.isEmpty else { return nil }
        let base = ((target?.fileName ?? "lyrics") as NSString).deletingPathExtension
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(base).lrc")
        try? lyrics.data(using: .utf8)?.write(to: url)
        return url
    }
}

enum ImageMime {
    static func detect(_ data: Data) -> String {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "image/jpeg" }
        if b.count >= 8, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "image/png" }
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46, b[8] == 0x57, b[9] == 0x45 { return "image/webp" }
        if b.count >= 6, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "image/gif" }
        if b.count >= 2, b[0] == 0x42, b[1] == 0x4D { return "image/bmp" }
        return "image/jpeg"
    }

    /// Re-encodes formats most tag readers do not support (HEIC, WebP, ...) to JPEG.
    static func normalizedForTag(_ data: Data) -> Data {
        let mime = detect(data)
        if mime == "image/jpeg" || mime == "image/png" { return data }
        if let img = UIImage(data: data), let jpeg = img.jpegData(compressionQuality: 0.92) { return jpeg }
        return data
    }
}
