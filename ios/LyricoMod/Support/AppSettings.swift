import Foundation
import SwiftUI

enum SongSortBy: String, CaseIterable, Identifiable {
    case title = "TITLE", artists = "ARTISTS", album = "ALBUM", dateModified = "DATE_MODIFIED",
         dateAdded = "DATE_ADDED", fileSize = "FILE_SIZE", duration = "DURATION", fileExtension = "EXTENSION"
    var id: String { rawValue }
    var labelKey: String {
        switch self {
        case .title: return "label_title"
        case .artists: return "label_artists"
        case .album: return "label_album"
        case .dateModified: return "label_date_modified"
        case .dateAdded: return "label_date_added"
        case .fileSize: return "label_file_size"
        case .duration: return "label_duration"
        case .fileExtension: return "label_extension"
        }
    }
    var sqlOrder: String {
        switch self {
        case .title: return "titleSortKey"
        case .artists: return "artistSortKey"
        case .album: return "albumSortKey"
        case .dateModified: return "fileLastModified"
        case .dateAdded: return "fileAdded"
        case .fileSize: return "fileSize"
        case .duration: return "durationMilliseconds"
        case .fileExtension: return "fileExtension"
        }
    }
}

enum ArtistSortBy: String, CaseIterable, Identifiable {
    case name = "NAME", songCount = "SONG_COUNT", albumCount = "ALBUM_COUNT"
    var id: String { rawValue }
    var labelKey: String { ["NAME": "label_name", "SONG_COUNT": "label_song_count", "ALBUM_COUNT": "label_album_count"][rawValue]! }
}

enum AlbumSortBy: String, CaseIterable, Identifiable {
    case name = "NAME", albumArtist = "ALBUM_ARTIST", songCount = "SONG_COUNT", year = "YEAR"
    var id: String { rawValue }
    var labelKey: String { ["NAME": "label_album", "ALBUM_ARTIST": "label_album_artist", "SONG_COUNT": "label_song_count", "YEAR": "label_year"][rawValue]! }
}

/// User preferences (Android SettingsRepository subset that applies to the iOS port so far).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("song_sort_by") var songSortBy: String = SongSortBy.title.rawValue
    @AppStorage("song_sort_asc") var songSortAscending: Bool = true
    @AppStorage("artist_sort_by") var artistSortBy: String = ArtistSortBy.name.rawValue
    @AppStorage("artist_sort_asc") var artistSortAscending: Bool = true
    @AppStorage("album_sort_by") var albumSortBy: String = AlbumSortBy.name.rawValue
    @AppStorage("album_sort_asc") var albumSortAscending: Bool = true
    /// Separator used to join multi-value tags when reading (Android default "/").
    @AppStorage("multi_value_separator") var multiValueSeparator: String = "/"
    /// Separators used to split artist names in the artist list.
    @AppStorage("artist_separators") var artistSeparators: String = "/;、"
    @AppStorage("artist_split_enabled") var artistSplitEnabled: Bool = true
    @AppStorage("rename_format") var renameFormat: String = "@1 - @2"
    @AppStorage("ignore_short_audio") var ignoreShortAudio: Bool = false
    @AppStorage("scan_on_launch") var scanOnLaunch: Bool = true
    @AppStorage("cover_cache_limit_mb") var coverCacheLimitMB: Int = 128

    var sortBy: SongSortBy { SongSortBy(rawValue: songSortBy) ?? .title }

    func splitArtists(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        guard artistSplitEnabled else { return [value] }
        let seps = CharacterSet(charactersIn: artistSeparators)
        let parts = value.components(separatedBy: seps).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? [value] : parts
    }
}
