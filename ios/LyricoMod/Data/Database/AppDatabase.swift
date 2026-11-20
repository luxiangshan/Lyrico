import Foundation
import GRDB

/// SQLite database (GRDB) holding folders and songs, like the Android Room database.
final class AppDatabase {
    static let shared: AppDatabase = {
        do {
            return try AppDatabase()
        } catch {
            fatalError("Cannot open database: \(error)")
        }
    }()

    let pool: DatabasePool

    private init() throws {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let url = dir.appendingPathComponent("lyrico.sqlite")
        var config = Configuration()
        config.foreignKeysEnabled = true
        pool = try DatabasePool(path: url.path, configuration: config)
        try migrator.migrate(pool)
    }

    private var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "folders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("path", .text).notNull()
                t.column("bookmark", .blob)
                t.column("sourceId", .text)
                t.column("songCount", .integer).notNull().defaults(to: 0)
                t.column("isIgnored", .boolean).notNull().defaults(to: false)
                t.column("addedAt", .datetime).notNull()
                t.column("lastScanned", .datetime)
            }
            try db.create(table: "songs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("folderId", .integer).notNull().indexed().references("folders", onDelete: .cascade)
                t.column("uri", .text).notNull().unique()
                t.column("source", .text).notNull().defaults(to: "LOCAL")
                t.column("relativePath", .text).notNull()
                t.column("fileName", .text).notNull()
                t.column("fileExtension", .text)
                t.column("fileSize", .integer).notNull().defaults(to: 0)
                for c in ["title", "artist", "albumArtist", "composer", "lyricist", "comment", "album", "genre", "language",
                          "trackerNumber", "date", "lyrics", "copyright", "replayGainTrackGain", "replayGainTrackPeak",
                          "replayGainAlbumGain", "replayGainAlbumPeak", "replayGainReferenceLoudness", "customTagsJSON"] {
                    t.column(c, .text)
                }
                t.column("discNumber", .integer)
                t.column("rating", .integer)
                t.column("durationMilliseconds", .integer).notNull().defaults(to: 0)
                t.column("bitrate", .integer).notNull().defaults(to: 0)
                t.column("sampleRate", .integer).notNull().defaults(to: 0)
                t.column("channels", .integer).notNull().defaults(to: 0)
                t.column("fileLastModified", .double).notNull().defaults(to: 0)
                t.column("fileAdded", .double).notNull().defaults(to: 0)
                t.column("dbUpdateTime", .double).notNull().defaults(to: 0)
                t.column("titleGroupKey", .text).notNull().defaults(to: "#")
                t.column("titleSortKey", .text).notNull().defaults(to: "#")
                t.column("artistGroupKey", .text).notNull().defaults(to: "#")
                t.column("artistSortKey", .text).notNull().defaults(to: "#")
                t.column("albumGroupKey", .text).notNull().defaults(to: "#")
                t.column("albumSortKey", .text).notNull().defaults(to: "#")
                t.column("hasCover", .boolean)
            }
            try db.create(index: "songs_title", on: "songs", columns: ["titleGroupKey", "titleSortKey"])
            try db.create(index: "songs_artist", on: "songs", columns: ["artistSortKey"])
            try db.create(index: "songs_album", on: "songs", columns: ["albumSortKey"])
        }
        return m
    }
}
