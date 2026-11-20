import Foundation

/// A song (or cover) result returned by a plugin (`SongSearchResult`).
public struct SongSearchResult: Hashable, Sendable, Identifiable {
    public var id: String
    public var pluginId: String
    public var pluginName: String
    public var title: String
    public var artist: String
    public var album: String
    /// Milliseconds.
    public var duration: Int64
    public var date: String
    public var trackNumber: String
    public var picUrl: String
    /// Host standard metadata fields (`title`, `album_artist`, `lyrics`, `cover_url`, ...).
    public var fields: StringMap
    /// Plugin private context, sent back unchanged on `getLyrics`.
    public var `internal`: StringMap

    public init(id: String, pluginId: String, pluginName: String, title: String = "", artist: String = "", album: String = "",
                duration: Int64 = 0, date: String = "", trackNumber: String = "", picUrl: String = "",
                fields: StringMap = [:], internal: StringMap = [:]) {
        self.id = id; self.pluginId = pluginId; self.pluginName = pluginName; self.title = title; self.artist = artist
        self.album = album; self.duration = duration; self.date = date; self.trackNumber = trackNumber; self.picUrl = picUrl
        self.fields = fields; self.internal = `internal`
    }

    /// `normalizedFields()`: sanitized standard fields plus the display fields as fallbacks.
    public func normalizedFields() -> StringMap {
        var out = fields.sanitizeStandardFields()
        if title.ktIsNotBlank { out.putIfAbsent("title", title) }
        if artist.ktIsNotBlank { out.putIfAbsent("artist", artist) }
        if album.ktIsNotBlank { out.putIfAbsent("album", album) }
        if date.ktIsNotBlank { out.putIfAbsent("date", date) }
        if trackNumber.ktIsNotBlank { out.putIfAbsent("track_number", trackNumber) }
        if picUrl.ktIsNotBlank { out.putIfAbsent("cover_url", picUrl) }
        return out
    }
}

/// Cover search results use the same model.
public typealias CoverSearchResult = SongSearchResult

public struct LyricsCandidateResult: Hashable, Sendable {
    public var song: SongSearchResult
    public var lyrics: LyricsResult
    public init(song: SongSearchResult, lyrics: LyricsResult) { self.song = song; self.lyrics = lyrics }
}

// MARK: - Request payloads (PluginScriptModels.kt, encoded like kotlinx with encodeDefaults=true, explicitNulls=false)

enum PluginRequests {
    static func song(_ s: SongSearchResult) -> JSONValue {
        .object(JSONObject([
            ("id", .string(s.id)), ("title", .string(s.title)), ("artist", .string(s.artist)), ("album", .string(s.album)),
            ("date", .string(s.date)), ("duration", .int64(s.duration)), ("sourceId", .string(s.pluginId)),
            ("pluginId", .string(s.pluginId)), ("fields", .object(.strings(s.fields))), ("internal", .object(.strings(s.internal)))
        ]))
    }

    static func searchSongs(keyword: String, page: Int, pageSize: Int, separator: String, config: StringMap) -> String {
        JSONValue.object(JSONObject([
            ("keyword", .string(keyword)), ("page", .int(page)), ("pageSize", .int(pageSize)),
            ("separator", .string(separator)), ("config", .object(.strings(config)))
        ])).jsonString
    }

    static func searchCovers(keyword: String, song: SongSearchResult?, page: Int, pageSize: Int, config: StringMap) -> String {
        var o = JSONObject()
        o["keyword"] = .string(keyword)
        if let song { o["song"] = self.song(song) }
        o["page"] = .int(page)
        o["pageSize"] = .int(pageSize)
        o["config"] = .object(.strings(config))
        return JSONValue.object(o).jsonString
    }

    static func getLyrics(song: SongSearchResult, page: Int, pageSize: Int, config: StringMap) -> String {
        JSONValue.object(JSONObject([
            ("song", self.song(song)), ("page", .int(page)), ("pageSize", .int(pageSize)), ("config", .object(.strings(config)))
        ])).jsonString
    }
}
