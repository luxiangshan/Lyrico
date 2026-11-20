import Foundation
import GRDB
import SwiftUI

enum SongScope: Hashable {
    case all
    case artist(String)
    case album(String)
    /// Direct children of `directory` inside folder `folderId`.
    case folder(Int64, String)
    case ids([Int64])
}

/// Observes the songs table for one scope (Android SongDao flows + LibraryPresentation).
@MainActor
final class SongListModel: ObservableObject {
    @Published private(set) var songs: [SongRecord] = []
    @Published private(set) var loaded = false
    @Published var query = "" { didSet { restart() } }

    let scope: SongScope
    private var observation: AnyDatabaseCancellable?
    private var settingsToken: Any?

    init(scope: SongScope) {
        self.scope = scope
        restart()
    }

    func restart() {
        let scope = self.scope
        let sort = AppSettings.shared.sortBy
        let asc = AppSettings.shared.songSortAscending
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = AppSettings.shared
        let artistSplit = settings.artistSplitEnabled
        let separators = settings.artistSeparators
        observation = ValueObservation
            .tracking { db -> [SongRecord] in
                var sql = "SELECT * FROM songs"
                var conditions: [String] = []
                var args: [DatabaseValueConvertible?] = []
                switch scope {
                case .all: break
                case .artist(let name):
                    conditions.append("(artist LIKE ? ESCAPE '\\' OR albumArtist LIKE ? ESCAPE '\\')")
                    let p = "%" + Self.escapeLike(name) + "%"
                    args += [p, p]
                case .album(let name):
                    if name.isEmpty { conditions.append("(album IS NULL OR album = '')") } else {
                        conditions.append("album = ?")
                        args.append(name)
                    }
                case .folder(let id, _):
                    conditions.append("folderId = ?")
                    args.append(id)
                case .ids(let ids):
                    conditions.append("id IN (\(ids.map { String($0) }.joined(separator: ",")))")
                }
                if !q.isEmpty {
                    let p = "%" + Self.escapeLike(q) + "%"
                    conditions.append("(title LIKE ? ESCAPE '\\' OR artist LIKE ? ESCAPE '\\' OR album LIKE ? ESCAPE '\\' OR albumArtist LIKE ? ESCAPE '\\' OR fileName LIKE ? ESCAPE '\\')")
                    args += [p, p, p, p, p]
                }
                if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
                let dir = asc ? "ASC" : "DESC"
                switch scope {
                case .album:
                    sql += " ORDER BY discNumber, CAST(trackerNumber AS INTEGER), titleSortKey"
                default:
                    sql += " ORDER BY \(sort.sqlOrder) \(dir), titleSortKey ASC"
                }
                var rows = try SongRecord.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                switch scope {
                case .artist(let name):
                    rows = rows.filter { song in
                        let all = Self.split(song.artist, artistSplit, separators) + Self.split(song.albumArtist, artistSplit, separators)
                        return all.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
                    }
                case .folder(_, let directory):
                    rows = rows.filter { $0.directory == directory }
                default: break
                }
                return rows
            }
            .removeDuplicates()
            .start(in: AppDatabase.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { [weak self] rows in
                self?.songs = rows
                self?.loaded = true
            })
    }

    nonisolated static func split(_ v: String?, _ enabled: Bool, _ seps: String) -> [String] {
        guard let v, !v.isEmpty else { return [] }
        guard enabled else { return [v] }
        let parts = v.components(separatedBy: CharacterSet(charactersIn: seps)).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? [v] : parts
    }

    nonisolated static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }
}

/// Aggregated artist / album rows (Android LibraryIndexDao).
struct ArtistRow: Identifiable, Hashable {
    let name: String
    var songCount: Int
    var albums: Set<String>
    var sample: SongRecord
    var id: String { name }
}

struct AlbumRow: Identifiable, Hashable {
    let name: String
    var albumArtist: String
    var year: String
    var songCount: Int
    var sample: SongRecord
    var id: String { name }
}

@MainActor
final class LibraryIndexModel: ObservableObject {
    @Published private(set) var artists: [ArtistRow] = []
    @Published private(set) var albums: [AlbumRow] = []
    @Published var query = "" { didSet { rebuild() } }
    private var all: [SongRecord] = []
    private var observation: AnyDatabaseCancellable?

    init() {
        observation = ValueObservation
            .tracking { db in try SongRecord.fetchAll(db, sql: "SELECT * FROM songs ORDER BY titleSortKey") }
            .start(in: AppDatabase.shared.pool, scheduling: .immediate, onError: { _ in }, onChange: { [weak self] rows in
                self?.all = rows
                self?.rebuild()
            })
    }

    func rebuild() {
        let s = AppSettings.shared
        var artistMap: [String: ArtistRow] = [:]
        var albumMap: [String: AlbumRow] = [:]
        for song in all {
            for a in SongListModel.split(song.artist, s.artistSplitEnabled, s.artistSeparators) {
                let key = a.lowercased()
                if var row = artistMap[key] {
                    row.songCount += 1
                    if let al = song.album, !al.isEmpty { row.albums.insert(al) }
                    artistMap[key] = row
                } else {
                    artistMap[key] = ArtistRow(name: a, songCount: 1, albums: Set([song.album].compactMap { $0 }.filter { !$0.isEmpty }), sample: song)
                }
            }
            let albumName = song.album ?? ""
            if !albumName.isEmpty {
                if var row = albumMap[albumName] {
                    row.songCount += 1
                    albumMap[albumName] = row
                } else {
                    albumMap[albumName] = AlbumRow(name: albumName, albumArtist: song.albumArtist ?? song.artist ?? "",
                                                   year: song.date ?? "", songCount: 1, sample: song)
                }
            }
        }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var a = Array(artistMap.values)
        var b = Array(albumMap.values)
        if !q.isEmpty {
            a = a.filter { $0.name.lowercased().contains(q) }
            b = b.filter { $0.name.lowercased().contains(q) || $0.albumArtist.lowercased().contains(q) }
        }
        let asc = s.artistSortAscending
        switch ArtistSortBy(rawValue: s.artistSortBy) ?? .name {
        case .name: a.sort { SortKeys.sortKey($0.name) < SortKeys.sortKey($1.name) }
        case .songCount: a.sort { $0.songCount < $1.songCount }
        case .albumCount: a.sort { $0.albums.count < $1.albums.count }
        }
        if !asc { a.reverse() }
        let asc2 = s.albumSortAscending
        switch AlbumSortBy(rawValue: s.albumSortBy) ?? .name {
        case .name: b.sort { SortKeys.sortKey($0.name) < SortKeys.sortKey($1.name) }
        case .albumArtist: b.sort { SortKeys.sortKey($0.albumArtist) < SortKeys.sortKey($1.albumArtist) }
        case .songCount: b.sort { $0.songCount < $1.songCount }
        case .year: b.sort { $0.year < $1.year }
        }
        if !asc2 { b.reverse() }
        artists = a
        albums = b
    }
}
