// GRDB records mirroring the Android Room entities (FolderEntity, SongEntity).
import Foundation
import GRDB

enum FolderKind: String, Codable {
    /// The app's own Documents directory (visible in the Files app).
    case documents
    /// A folder picked with UIDocumentPickerViewController, persisted as a security-scoped bookmark.
    case local
    /// A folder on a remote location (WebDAV/OpenList/SMB/115) provided by the RemoteStorage package.
    case remote
}

struct FolderRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "folders"

    var id: Int64?
    var kind: FolderKind
    var displayName: String
    /// Local: last resolved absolute path (display only). Remote: folder path on the remote ("/Music").
    var path: String
    /// Security-scoped bookmark (local kind only).
    var bookmark: Data?
    /// Remote location id (remote kind only); see RemoteLocationConfig.
    var sourceId: String?
    var songCount: Int = 0
    var isIgnored: Bool = false
    var addedAt: Date = Date()
    var lastScanned: Date?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// Port of SongEntity. `uri` is the stable identity: "local://<folderId>/<relativePath>" or
/// "remote://<locationId>/<url-encoded path>" (same scheme as Android).
struct SongRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "songs"

    var id: Int64?
    var folderId: Int64
    var uri: String
    var source: String = "LOCAL"
    /// Path inside the folder, '/'-separated, starting with '/'.
    var relativePath: String
    var fileName: String
    var fileExtension: String?
    var fileSize: Int64 = 0

    var title: String?
    var artist: String?
    var albumArtist: String?
    var discNumber: Int?
    var composer: String?
    var lyricist: String?
    var comment: String?
    var album: String?
    var genre: String?
    var language: String?
    var trackerNumber: String?
    var date: String?
    var lyrics: String?
    var copyright: String?
    var rating: Int?
    var replayGainTrackGain: String?
    var replayGainTrackPeak: String?
    var replayGainAlbumGain: String?
    var replayGainAlbumPeak: String?
    var replayGainReferenceLoudness: String?
    var customTagsJSON: String?

    var durationMilliseconds: Int = 0
    var bitrate: Int = 0
    var sampleRate: Int = 0
    var channels: Int = 0

    var fileLastModified: Double = 0
    var fileAdded: Double = 0
    var dbUpdateTime: Double = Date().timeIntervalSince1970

    var titleGroupKey: String = "#"
    var titleSortKey: String = "#"
    var artistGroupKey: String = "#"
    var artistSortKey: String = "#"
    var albumGroupKey: String = "#"
    var albumSortKey: String = "#"
    var hasCover: Bool?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        return (fileName as NSString).deletingPathExtension
    }

    var displayArtist: String { (artist?.isEmpty == false ? artist : nil) ?? L("unknown_artist") }
    var displayAlbum: String { (album?.isEmpty == false ? album : nil) ?? L("unknown_album") }

    /// Directory part of relativePath ("/" for files at the folder root).
    var directory: String {
        let dir = (relativePath as NSString).deletingLastPathComponent
        return dir.isEmpty ? "/" : dir
    }

    var customFields: [CustomTagField] {
        guard let json = customTagsJSON, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([[String]].self, from: data) else { return [] }
        return dict.compactMap { $0.count == 2 ? CustomTagField(key: $0[0], value: $0[1]) : nil }
    }

    /// Fills tag columns from AudioTagData (port of the Android mapper).
    mutating func apply(tag: AudioTagData) {
        title = tag.title
        artist = tag.artist
        albumArtist = tag.albumArtist
        discNumber = tag.discNumber
        composer = tag.composer
        lyricist = tag.lyricist
        comment = tag.comment
        album = tag.album
        genre = tag.genre
        language = tag.language
        trackerNumber = tag.trackNumber
        date = tag.date
        lyrics = tag.lyrics
        copyright = tag.copyright
        rating = tag.rating
        replayGainTrackGain = tag.replayGainTrackGain
        replayGainTrackPeak = tag.replayGainTrackPeak
        replayGainAlbumGain = tag.replayGainAlbumGain
        replayGainAlbumPeak = tag.replayGainAlbumPeak
        replayGainReferenceLoudness = tag.replayGainReferenceLoudness
        if tag.durationMilliseconds > 0 || durationMilliseconds == 0 {
            durationMilliseconds = tag.durationMilliseconds
            bitrate = tag.bitrate
            sampleRate = tag.sampleRate
            channels = tag.channels
        }
        let pairs = tag.customFields.map { [$0.key, $0.value] }
        customTagsJSON = (try? JSONEncoder().encode(pairs)).flatMap { String(data: $0, encoding: .utf8) }
        dbUpdateTime = Date().timeIntervalSince1970
        titleSortKey = SortKeys.sortKey(displayTitle)
        titleGroupKey = SortKeys.groupKey(displayTitle)
        artistSortKey = SortKeys.sortKey(artist ?? "")
        artistGroupKey = SortKeys.groupKey(artist ?? "")
        albumSortKey = SortKeys.sortKey(album ?? "")
        albumGroupKey = SortKeys.groupKey(album ?? "")
    }

    /// Minimal AudioTagData from the database (used for rename previews / batch edit defaults).
    var tagData: AudioTagData {
        var d = AudioTagData()
        d.title = title; d.artist = artist; d.album = album; d.albumArtist = albumArtist
        d.genre = genre; d.date = date; d.language = language; d.trackNumber = trackerNumber
        d.discNumber = discNumber; d.composer = composer; d.lyricist = lyricist; d.comment = comment
        d.lyrics = lyrics; d.copyright = copyright; d.rating = rating
        d.replayGainTrackGain = replayGainTrackGain; d.replayGainTrackPeak = replayGainTrackPeak
        d.replayGainAlbumGain = replayGainAlbumGain; d.replayGainAlbumPeak = replayGainAlbumPeak
        d.replayGainReferenceLoudness = replayGainReferenceLoudness
        d.fileName = fileName; d.durationMilliseconds = durationMilliseconds; d.bitrate = bitrate
        d.sampleRate = sampleRate; d.channels = channels; d.customFields = customFields
        return d
    }
}

enum SortKeys {
    /// Pinyin/latin transliteration, uppercased, used for ordering (letters first, then '#').
    static func sortKey(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "~" }
        let latin = transliterate(trimmed).uppercased()
        if let first = latin.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first), first.isASCII {
            return "1_" + latin
        }
        return "2_" + latin
    }

    static func groupKey(_ s: String) -> String {
        let latin = transliterate(s.trimmingCharacters(in: .whitespacesAndNewlines)).uppercased()
        if let first = latin.unicodeScalars.first, first.isASCII, CharacterSet.uppercaseLetters.contains(first) {
            return String(Character(first))
        }
        return "#"
    }

    static func transliterate(_ s: String) -> String {
        let m = NSMutableString(string: s) as CFMutableString
        CFStringTransform(m, nil, kCFStringTransformToLatin, false)
        CFStringTransform(m, nil, kCFStringTransformStripCombiningMarks, false)
        return m as String
    }
}
