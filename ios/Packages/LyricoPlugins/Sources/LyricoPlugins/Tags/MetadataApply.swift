import Foundation

/// Per-field write mode used by batch matching (`MetadataWriteMode`).
public enum MetadataWriteMode: String, Hashable, Sendable, CaseIterable, Codable {
    case disabled = "DISABLED"
    case supplement = "SUPPLEMENT"
    case overwrite = "OVERWRITE"
}

/// Tag targets (`MetadataFieldTarget`).
public enum MetadataFieldTarget: String, Hashable, Sendable, CaseIterable, Codable {
    case title = "TITLE", artist = "ARTIST", album = "ALBUM", albumArtist = "ALBUM_ARTIST", genre = "GENRE"
    case date = "DATE", trackNumber = "TRACK_NUMBER", discNumber = "DISC_NUMBER", composer = "COMPOSER"
    case lyricist = "LYRICIST", comment = "COMMENT", lyrics = "LYRICS", cover = "COVER", language = "LANGUAGE"
    case copyright = "COPYRIGHT", rating = "RATING"
    case replayGainTrackGain = "REPLAY_GAIN_TRACK_GAIN", replayGainTrackPeak = "REPLAY_GAIN_TRACK_PEAK"
    case replayGainAlbumGain = "REPLAY_GAIN_ALBUM_GAIN", replayGainAlbumPeak = "REPLAY_GAIN_ALBUM_PEAK"
    case replayGainReferenceLoudness = "REPLAY_GAIN_REFERENCE_LOUDNESS"
    case custom = "CUSTOM"
}

/// Host standard plugin field keys (`StandardPluginField`).
public enum StandardPluginField: String, CaseIterable, Sendable {
    case title, artist, album
    case albumArtist = "album_artist"
    case genre, date
    case trackNumber = "track_number"
    case discNumber = "disc_number"
    case composer, lyricist, comment, lyrics
    case coverUrl = "cover_url"
    case language, copyright, rating
    case replayGainTrackGain = "replaygain_track_gain"
    case replayGainTrackPeak = "replaygain_track_peak"
    case replayGainAlbumGain = "replaygain_album_gain"
    case replayGainAlbumPeak = "replaygain_album_peak"
    case replayGainReferenceLoudness = "replaygain_reference_loudness"

    public var key: String { rawValue }

    public var target: MetadataFieldTarget {
        switch self {
        case .title: return .title
        case .artist: return .artist
        case .album: return .album
        case .albumArtist: return .albumArtist
        case .genre: return .genre
        case .date: return .date
        case .trackNumber: return .trackNumber
        case .discNumber: return .discNumber
        case .composer: return .composer
        case .lyricist: return .lyricist
        case .comment: return .comment
        case .lyrics: return .lyrics
        case .coverUrl: return .cover
        case .language: return .language
        case .copyright: return .copyright
        case .rating: return .rating
        case .replayGainTrackGain: return .replayGainTrackGain
        case .replayGainTrackPeak: return .replayGainTrackPeak
        case .replayGainAlbumGain: return .replayGainAlbumGain
        case .replayGainAlbumPeak: return .replayGainAlbumPeak
        case .replayGainReferenceLoudness: return .replayGainReferenceLoudness
        }
    }

    public static func fromKey(_ key: String) -> StandardPluginField? { StandardPluginField(rawValue: key) }
}

extension OrderedMap where Key == String, Value == String {
    /// `sanitizeStandardFields()`.
    func sanitizeStandardFields() -> StringMap {
        var out = StringMap()
        for (k, v) in self where StandardPluginField.fromKey(k) != nil && v.ktIsNotBlank { out[k] = v }
        return out
    }

    /// `sanitizePluginInternal()`.
    func sanitizePluginInternal() -> StringMap {
        var out = StringMap()
        for (k, v) in self where k.ktIsNotBlank && k.ktLength <= 64 && v.ktLength <= 4096 {
            if out.count >= 64 { break }
            out[k] = v
        }
        return out
    }
}

public struct MetadataApplyPolicy: Hashable, Sendable {
    public var fieldModes: [MetadataFieldTarget: MetadataWriteMode]
    public init(fieldModes: [MetadataFieldTarget: MetadataWriteMode]) { self.fieldModes = fieldModes }

    public func modeOf(_ target: MetadataFieldTarget) -> MetadataWriteMode { fieldModes[target] ?? .disabled }

    public static func overwriteAvailableFields(_ fields: StringMap) -> MetadataApplyPolicy {
        var modes: [MetadataFieldTarget: MetadataWriteMode] = [:]
        for key in fields.keys { if let t = StandardPluginField.fromKey(key)?.target { modes[t] = .overwrite } }
        return MetadataApplyPolicy(fieldModes: modes)
    }
}

/// Swift counterpart of `AudioTagData` restricted to the fields plugins can fill.
/// `nil` means "not present / unchanged" exactly like the Kotlin patch semantics.
public struct TagFields: Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var date: String?
    public var language: String?
    public var trackNumber: String?
    public var discNumber: Int?
    public var composer: String?
    public var lyricist: String?
    public var comment: String?
    public var lyrics: String?
    public var copyright: String?
    public var rating: Int?
    public var replayGainTrackGain: String?
    public var replayGainTrackPeak: String?
    public var replayGainAlbumGain: String?
    public var replayGainAlbumPeak: String?
    public var replayGainReferenceLoudness: String?
    /// Remote cover URL to download and embed (`picUrl`).
    public var picUrl: String?
    /// Whether the file already has embedded pictures (only read for "supplement" cover checks).
    public var hasEmbeddedPictures: Bool
    public var customFields: [String: String]

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil, genre: String? = nil,
                date: String? = nil, language: String? = nil, trackNumber: String? = nil, discNumber: Int? = nil,
                composer: String? = nil, lyricist: String? = nil, comment: String? = nil, lyrics: String? = nil,
                copyright: String? = nil, rating: Int? = nil, replayGainTrackGain: String? = nil, replayGainTrackPeak: String? = nil,
                replayGainAlbumGain: String? = nil, replayGainAlbumPeak: String? = nil, replayGainReferenceLoudness: String? = nil,
                picUrl: String? = nil, hasEmbeddedPictures: Bool = false, customFields: [String: String] = [:]) {
        self.title = title; self.artist = artist; self.album = album; self.albumArtist = albumArtist; self.genre = genre
        self.date = date; self.language = language; self.trackNumber = trackNumber; self.discNumber = discNumber
        self.composer = composer; self.lyricist = lyricist; self.comment = comment; self.lyrics = lyrics
        self.copyright = copyright; self.rating = rating; self.replayGainTrackGain = replayGainTrackGain
        self.replayGainTrackPeak = replayGainTrackPeak; self.replayGainAlbumGain = replayGainAlbumGain
        self.replayGainAlbumPeak = replayGainAlbumPeak; self.replayGainReferenceLoudness = replayGainReferenceLoudness
        self.picUrl = picUrl; self.hasEmbeddedPictures = hasEmbeddedPictures; self.customFields = customFields
    }

    /// Patch emptiness check used by `MatchMetadataProcessor` (`AudioTagData.isEmpty`).
    public var isEmptyPatch: Bool {
        title == nil && artist == nil && album == nil && genre == nil && albumArtist == nil && date == nil &&
            trackNumber == nil && discNumber == nil && composer == nil && lyricist == nil && lyrics == nil &&
            picUrl == nil && comment == nil && replayGainTrackGain == nil && replayGainTrackPeak == nil &&
            replayGainAlbumGain == nil && replayGainAlbumPeak == nil && replayGainReferenceLoudness == nil
    }

    func isTargetBlank(_ target: MetadataFieldTarget) -> Bool {
        func blank(_ s: String?) -> Bool { s?.ktIsBlank ?? true }
        switch target {
        case .title: return blank(title)
        case .artist: return blank(artist)
        case .album: return blank(album)
        case .albumArtist: return blank(albumArtist)
        case .genre: return blank(genre)
        case .date: return blank(date)
        case .trackNumber: return blank(trackNumber)
        case .discNumber: return discNumber == nil
        case .composer: return blank(composer)
        case .lyricist: return blank(lyricist)
        case .comment: return blank(comment)
        case .lyrics: return blank(lyrics)
        case .cover: return blank(picUrl) && !hasEmbeddedPictures
        case .language: return blank(language)
        case .copyright: return blank(copyright)
        case .rating: return rating == nil
        case .replayGainTrackGain: return blank(replayGainTrackGain)
        case .replayGainTrackPeak: return blank(replayGainTrackPeak)
        case .replayGainAlbumGain: return blank(replayGainAlbumGain)
        case .replayGainAlbumPeak: return blank(replayGainAlbumPeak)
        case .replayGainReferenceLoudness: return blank(replayGainReferenceLoudness)
        case .custom: return customFields.isEmpty
        }
    }

    mutating func setTarget(_ target: MetadataFieldTarget, _ value: String) {
        switch target {
        case .title: title = value
        case .artist: artist = value
        case .album: album = value
        case .albumArtist: albumArtist = value
        case .genre: genre = value
        case .date: date = value
        case .trackNumber: trackNumber = value
        case .discNumber: discNumber = TagFields.parseIntTag(value)
        case .composer: composer = value
        case .lyricist: lyricist = value
        case .comment: comment = value
        case .lyrics: lyrics = value
        case .cover: picUrl = value
        case .language: language = value
        case .copyright: copyright = value
        case .rating: rating = TagFields.parseIntTag(value)
        case .replayGainTrackGain: replayGainTrackGain = value
        case .replayGainTrackPeak: replayGainTrackPeak = value
        case .replayGainAlbumGain: replayGainAlbumGain = value
        case .replayGainAlbumPeak: replayGainAlbumPeak = value
        case .replayGainReferenceLoudness: replayGainReferenceLoudness = value
        case .custom: break
        }
    }

    static func parseIntTag(_ value: String) -> Int? {
        let digits = String(value.ktSubstringBefore("/").unicodeScalars.filter { $0.properties.numericType == .decimal })
        guard digits.ktIsNotBlank else { return nil }
        return Int(digits)
    }
}

/// Port of `SearchResultApplier`.
public enum SearchResultApplier {
    public static func applyFields(current: TagFields, fields: StringMap, policy: MetadataApplyPolicy) -> TagFields {
        var output = current
        for (key, value) in fields {
            if value.ktIsBlank { continue }
            guard let target = StandardPluginField.fromKey(key)?.target else { continue }
            switch policy.modeOf(target) {
            case .disabled: break
            case .supplement: if output.isTargetBlank(target) { output.setTarget(target, value) }
            case .overwrite: output.setTarget(target, value)
            }
        }
        return output
    }

    /// Returns only the fields that change (nil = unchanged).
    public static func buildPatch(current: TagFields, fields: StringMap, policy: MetadataApplyPolicy) -> TagFields {
        let a = applyFields(current: current, fields: fields, policy: policy)
        func d<T: Equatable>(_ new: T?, _ old: T?) -> T? { new != old ? new : nil }
        return TagFields(
            title: d(a.title, current.title), artist: d(a.artist, current.artist), album: d(a.album, current.album),
            albumArtist: d(a.albumArtist, current.albumArtist), genre: d(a.genre, current.genre), date: d(a.date, current.date),
            language: d(a.language, current.language), trackNumber: d(a.trackNumber, current.trackNumber),
            discNumber: d(a.discNumber, current.discNumber), composer: d(a.composer, current.composer),
            lyricist: d(a.lyricist, current.lyricist), comment: d(a.comment, current.comment), lyrics: d(a.lyrics, current.lyrics),
            copyright: d(a.copyright, current.copyright), rating: d(a.rating, current.rating),
            replayGainTrackGain: d(a.replayGainTrackGain, current.replayGainTrackGain),
            replayGainTrackPeak: d(a.replayGainTrackPeak, current.replayGainTrackPeak),
            replayGainAlbumGain: d(a.replayGainAlbumGain, current.replayGainAlbumGain),
            replayGainAlbumPeak: d(a.replayGainAlbumPeak, current.replayGainAlbumPeak),
            replayGainReferenceLoudness: d(a.replayGainReferenceLoudness, current.replayGainReferenceLoudness),
            picUrl: d(a.picUrl, current.picUrl),
            customFields: a.customFields != current.customFields ? a.customFields : [:]
        )
    }
}

/// Port of `AudioTagWriteRules` + `TagMapBuilder`: converts a patch into the raw TagLib property map
/// (standard key plus aliases cleared with ""), ready for the app's TagLib bridge.
public enum TagPropertyMap {
    struct Rule { let standardKey: String; let aliases: [String] }

    static let rules: [MetadataFieldTarget: Rule] = [
        .title: Rule(standardKey: "TITLE", aliases: ["TIT2", "TIT1"]),
        .artist: Rule(standardKey: "ARTIST", aliases: ["TPE1"]),
        .album: Rule(standardKey: "ALBUM", aliases: ["TALB"]),
        .genre: Rule(standardKey: "GENRE", aliases: ["TCON", "STYLE", "SUBGENRE", "MOOD"]),
        .date: Rule(standardKey: "DATE", aliases: ["YEAR", "TYER", "TDAT"]),
        .language: Rule(standardKey: "LANGUAGE", aliases: ["TLAN"]),
        .trackNumber: Rule(standardKey: "TRACKNUMBER", aliases: ["TRACK", "TRCK"]),
        .albumArtist: Rule(standardKey: "ALBUMARTIST", aliases: ["TPE2", "ALBUM ARTIST", "aART", "ALBUMARTISTSORT"]),
        .discNumber: Rule(standardKey: "DISCNUMBER", aliases: ["DISC", "TPOS", "DISKNUMBER"]),
        .composer: Rule(standardKey: "COMPOSER", aliases: ["TCOM", "©wrt"]),
        .comment: Rule(standardKey: "COMMENT", aliases: ["COMM", "DESCRIPTION"]),
        .lyricist: Rule(standardKey: "LYRICIST", aliases: ["TEXT", "WRITER", "LYRICS BY"]),
        .lyrics: Rule(standardKey: "LYRICS", aliases: ["UNSYNCED LYRICS", "USLT", "LYRIC", "LYRICSENG"]),
        .copyright: Rule(standardKey: "COPYRIGHT", aliases: ["TCOP", "CPRO", "©cpy"]),
        .replayGainTrackGain: Rule(standardKey: "REPLAYGAIN_TRACK_GAIN", aliases: []),
        .replayGainTrackPeak: Rule(standardKey: "REPLAYGAIN_TRACK_PEAK", aliases: []),
        .replayGainAlbumGain: Rule(standardKey: "REPLAYGAIN_ALBUM_GAIN", aliases: []),
        .replayGainAlbumPeak: Rule(standardKey: "REPLAYGAIN_ALBUM_PEAK", aliases: []),
        .replayGainReferenceLoudness: Rule(standardKey: "REPLAYGAIN_REFERENCE_LOUDNESS", aliases: [])
    ]

    /// Builds the property map for a patch. `fileExtension` matters only for rating.
    /// The cover (`picUrl`) is not part of the map: download it and write it as a picture.
    public static func build(patch: TagFields, fileExtension: String) -> [String: String] {
        var result: [String: String] = [:]
        func set(_ target: MetadataFieldTarget, _ value: String?) {
            guard let value, let rule = rules[target] else { return }
            result[rule.standardKey] = value
            for alias in rule.aliases { result[alias] = "" }
        }
        set(.title, patch.title); set(.artist, patch.artist); set(.album, patch.album)
        set(.albumArtist, patch.albumArtist); set(.genre, patch.genre); set(.date, patch.date)
        set(.language, patch.language); set(.trackNumber, patch.trackNumber)
        set(.discNumber, patch.discNumber.map { String($0) }); set(.composer, patch.composer)
        set(.lyricist, patch.lyricist); set(.comment, patch.comment); set(.lyrics, patch.lyrics)
        set(.copyright, patch.copyright); set(.replayGainTrackGain, patch.replayGainTrackGain)
        set(.replayGainTrackPeak, patch.replayGainTrackPeak); set(.replayGainAlbumGain, patch.replayGainAlbumGain)
        set(.replayGainAlbumPeak, patch.replayGainAlbumPeak); set(.replayGainReferenceLoudness, patch.replayGainReferenceLoudness)
        if let rating = patch.rating {
            let star = rating
            let ext = fileExtension.uppercased()
            if (1...5).contains(star) && ext == "MP3" {
                let popm = [1: 1, 2: 64, 3: 128, 4: 196, 5: 255][star] ?? 0
                result["POPM"] = "no@email|\(popm)|0"; result["RATING"] = ""; result["RATE"] = ""
            } else if (1...5).contains(star) && (ext == "FLAC" || ext == "OGG") {
                result["RATING"] = String(star * 20); result["POPM"] = ""; result["RATE"] = ""
            } else if (1...5).contains(star) {
                result["RATE"] = String(star * 20); result["RATING"] = ""; result["POPM"] = ""
            } else {
                result["POPM"] = ""; result["RATING"] = ""; result["RATE"] = ""
            }
        }
        return result
    }
}
