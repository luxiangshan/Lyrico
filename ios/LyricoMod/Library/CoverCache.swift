import CryptoKit
import Foundation
import ImageIO
import UIKit

/// Cover thumbnails: memory NSCache + disk cache (Caches/covers), keyed by song uri + size + mtime
/// (Android RemoteCoverCache / Coil cache). Songs without covers get a ".none" marker so they are
/// not re-read every time.
final class CoverCache {
    static let shared = CoverCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let queue = DispatchQueue(label: "cover-cache", qos: .utility, attributes: .concurrent)
    private var inFlight: [String: [(UIImage?) -> Void]] = [:]
    private let lock = NSLock()
    static let thumbnailSize: CGFloat = 256

    private init() {
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    private func key(_ song: SongRecord) -> String {
        let raw = "\(song.uri)|\(song.fileSize)|\(Int(song.fileLastModified))"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func cachedImage(for song: SongRecord) -> UIImage? {
        memory.object(forKey: key(song) as NSString)
    }

    func image(for song: SongRecord) async -> UIImage? {
        let k = key(song)
        if let img = memory.object(forKey: k as NSString) { return img }
        let file = dir.appendingPathComponent(k + ".jpg")
        let none = dir.appendingPathComponent(k + ".none")
        if FileManager.default.fileExists(atPath: none.path) { return nil }
        if let img = UIImage(contentsOfFile: file.path) {
            memory.setObject(img, forKey: k as NSString)
            return img
        }
        let bytes: Data?
        do { bytes = try await readCover(song) } catch { return nil }
        guard let bytes, !bytes.isEmpty, let thumb = Self.thumbnail(bytes, maxPixel: Self.thumbnailSize) else {
            FileManager.default.createFile(atPath: none.path, contents: Data())
            return nil
        }
        if let jpeg = thumb.jpegData(compressionQuality: 0.85) { try? jpeg.write(to: file) }
        memory.setObject(thumb, forKey: k as NSString)
        trimIfNeeded()
        return thumb
    }

    private func readCover(_ song: SongRecord) async throws -> Data {
        let source = try await SongFileService.source(for: song)
        if source.kind.isRemote {
            let reader = RemoteRangeReader(source: source, path: song.relativePath, length: song.fileSize)
            let data = await RemoteTagIO.run { () -> Data in
                let pics = TagLib.getPictures(reader: reader)
                return TagLib.selectPicture(pics, pictureType: .frontCover, fallbackPictureTypes: [], fallbackToAny: true, description: nil)?.data ?? Data()
            }
            // A network failure is not "no cover": don't write the .none marker, retry next time.
            if data.isEmpty && reader.failed { throw SongFileService.ServiceError(message: "cover read failed") }
            return data
        }
        return try await SongFileService.withReadableFile(song) { url in
            AudioTagReader.readPicture(url)
        }
    }

    /// Full-size front cover (editor).
    func fullCover(for song: SongRecord) async -> Data? {
        let d = try? await readCover(song)
        return (d?.isEmpty ?? true) ? nil : d
    }

    func invalidate(_ song: SongRecord) {
        let k = key(song)
        memory.removeObject(forKey: k as NSString)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(k + ".jpg"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(k + ".none"))
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func diskSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func trimIfNeeded() {
        let limit = Int64(max(16, AppSettings.shared.coverCacheLimitMB)) * 1024 * 1024
        queue.async(flags: .barrier) { [dir] in
            let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
            var entries = files.compactMap { u -> (URL, Int64, Date)? in
                guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
                return (u, Int64(v.fileSize ?? 0), v.contentAccessDate ?? .distantPast)
            }
            var total = entries.reduce(Int64(0)) { $0 + $1.1 }
            guard total > limit else { return }
            entries.sort { $0.2 < $1.2 }
            for e in entries where total > limit * 8 / 10 {
                try? FileManager.default.removeItem(at: e.0)
                total -= e.1
            }
        }
    }

    static func thumbnail(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * UIScreen.main.scale,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
