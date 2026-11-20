// Port of com.lonx.lyrico.data.song.tag.{AudioTagMutation, TagWriteRules, TagMapBuilder}.
import Foundation

enum AudioTagMutationMode { case patch, overwrite }

enum AudioTagFieldKey: String, CaseIterable, Hashable {
    case title, artist, album, albumArtist, genre, date, language, trackNumber, discNumber
    case composer, lyricist, comment, lyrics, copyright, rating
    case replayGainTrackGain, replayGainTrackPeak, replayGainAlbumGain, replayGainAlbumPeak, replayGainReferenceLoudness

    /// Android string resource key used for the label.
    var labelKey: String {
        switch self {
        case .title: return "label_title"
        case .artist: return "label_artists"
        case .album: return "label_album"
        case .albumArtist: return "label_album_artist"
        case .genre: return "label_genre"
        case .date: return "label_date"
        case .language: return "label_language"
        case .trackNumber: return "label_track_number"
        case .discNumber: return "label_disc_number"
        case .composer: return "label_composer"
        case .lyricist: return "label_lyricist"
        case .comment: return "label_comment"
        case .lyrics: return "label_lyrics"
        case .copyright: return "label_copyright"
        case .rating: return "label_rating"
        case .replayGainTrackGain: return "label_replaygain_track_gain"
        case .replayGainTrackPeak: return "label_replaygain_track_peak"
        case .replayGainAlbumGain: return "label_replaygain_album_gain"
        case .replayGainAlbumPeak: return "label_replaygain_album_peak"
        case .replayGainReferenceLoudness: return "label_replaygain_reference_loudness"
        }
    }

    func value(in d: AudioTagData) -> String? {
        switch self {
        case .title: return d.title
        case .artist: return d.artist
        case .album: return d.album
        case .albumArtist: return d.albumArtist
        case .genre: return d.genre
        case .date: return d.date
        case .language: return d.language
        case .trackNumber: return d.trackNumber
        case .discNumber: return d.discNumber.map(String.init)
        case .composer: return d.composer
        case .lyricist: return d.lyricist
        case .comment: return d.comment
        case .lyrics: return d.lyrics
        case .copyright: return d.copyright
        case .rating: return d.rating.map(String.init)
        case .replayGainTrackGain: return d.replayGainTrackGain
        case .replayGainTrackPeak: return d.replayGainTrackPeak
        case .replayGainAlbumGain: return d.replayGainAlbumGain
        case .replayGainAlbumPeak: return d.replayGainAlbumPeak
        case .replayGainReferenceLoudness: return d.replayGainReferenceLoudness
        }
    }

    func set(_ value: String?, in d: inout AudioTagData) {
        let v = value.flatMap { $0.isEmpty ? nil : $0 }
        switch self {
        case .title: d.title = v
        case .artist: d.artist = v
        case .album: d.album = v
        case .albumArtist: d.albumArtist = v
        case .genre: d.genre = v
        case .date: d.date = v
        case .language: d.language = v
        case .trackNumber: d.trackNumber = v
        case .discNumber: d.discNumber = v.flatMap { Int($0) }
        case .composer: d.composer = v
        case .lyricist: d.lyricist = v
        case .comment: d.comment = v
        case .lyrics: d.lyrics = v
        case .copyright: d.copyright = v
        case .rating: d.rating = v.flatMap { Int($0) }
        case .replayGainTrackGain: d.replayGainTrackGain = v
        case .replayGainTrackPeak: d.replayGainTrackPeak = v
        case .replayGainAlbumGain: d.replayGainAlbumGain = v
        case .replayGainAlbumPeak: d.replayGainAlbumPeak = v
        case .replayGainReferenceLoudness: d.replayGainReferenceLoudness = v
        }
    }

    static let basic: [AudioTagFieldKey] = [.title, .artist, .album, .albumArtist, .genre, .date, .language, .trackNumber, .discNumber]
    static let credits: [AudioTagFieldKey] = [.composer, .lyricist, .comment, .copyright, .rating]
    static let replayGain: [AudioTagFieldKey] = [.replayGainTrackGain, .replayGainTrackPeak, .replayGainAlbumGain, .replayGainAlbumPeak, .replayGainReferenceLoudness]
}

enum FieldMutation: Equatable {
    case unchanged
    case clear
    case set(String)
}

enum CustomTagFieldMutation: Equatable {
    case unchanged
    case replaceAll([CustomTagField])
    case set(key: String, value: String)
    case clear(key: String)
}

enum PictureUpdate: Equatable {
    case unchanged
    case removeFrontCover
    case removeAllPictures
    case replaceFrontCover(data: Data, mimeType: String)
    case replaceAll([AudioPicture])
}

struct AudioTagMutation: Equatable {
    var mode: AudioTagMutationMode = .patch
    var fields: [AudioTagFieldKey: FieldMutation] = [:]
    var customFields: [CustomTagFieldMutation] = []
    var pictureUpdate: PictureUpdate = .unchanged

    var isEmpty: Bool {
        fields.values.allSatisfy { $0 == .unchanged } &&
            customFields.allSatisfy { $0 == .unchanged } && pictureUpdate == .unchanged
    }

    /// Builds a mutation describing the differences between `original` and `edited`.
    static func diff(original: AudioTagData, edited: AudioTagData, pictureUpdate: PictureUpdate = .unchanged) -> AudioTagMutation {
        var m = AudioTagMutation()
        for key in AudioTagFieldKey.allCases {
            let old = key.value(in: original) ?? ""
            let new = (key.value(in: edited) ?? "")
            if old != new {
                m.fields[key] = new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .clear : .set(new)
            }
        }
        if original.customFields != edited.customFields {
            m.customFields = [.replaceAll(edited.customFields)]
        }
        m.pictureUpdate = pictureUpdate
        return m
    }
}

struct TagWriteRule {
    let standardKey: String
    let aliasesToClear: [String]
}

enum AudioTagWriteRules {
    private static let rules: [AudioTagFieldKey: TagWriteRule] = [
        .title: TagWriteRule(standardKey: "TITLE", aliasesToClear: ["TIT2", "TIT1"]),
        .artist: TagWriteRule(standardKey: "ARTIST", aliasesToClear: ["TPE1"]),
        .album: TagWriteRule(standardKey: "ALBUM", aliasesToClear: ["TALB"]),
        .genre: TagWriteRule(standardKey: "GENRE", aliasesToClear: ["TCON", "STYLE", "SUBGENRE", "MOOD"]),
        .date: TagWriteRule(standardKey: "DATE", aliasesToClear: ["YEAR", "TYER", "TDAT"]),
        .language: TagWriteRule(standardKey: "LANGUAGE", aliasesToClear: ["TLAN"]),
        .trackNumber: TagWriteRule(standardKey: "TRACKNUMBER", aliasesToClear: ["TRACK", "TRCK"]),
        .albumArtist: TagWriteRule(standardKey: "ALBUMARTIST", aliasesToClear: ["TPE2", "ALBUM ARTIST", "aART", "ALBUMARTISTSORT"]),
        .discNumber: TagWriteRule(standardKey: "DISCNUMBER", aliasesToClear: ["DISC", "TPOS", "DISKNUMBER"]),
        .composer: TagWriteRule(standardKey: "COMPOSER", aliasesToClear: ["TCOM", "©wrt"]),
        .comment: TagWriteRule(standardKey: "COMMENT", aliasesToClear: ["COMM", "DESCRIPTION"]),
        .lyricist: TagWriteRule(standardKey: "LYRICIST", aliasesToClear: ["TEXT", "WRITER", "LYRICS BY"]),
        .lyrics: TagWriteRule(standardKey: "LYRICS", aliasesToClear: ["UNSYNCED LYRICS", "USLT", "LYRIC", "LYRICSENG"]),
        .copyright: TagWriteRule(standardKey: "COPYRIGHT", aliasesToClear: ["TCOP", "CPRO", "©cpy"]),
        .replayGainTrackGain: TagWriteRule(standardKey: "REPLAYGAIN_TRACK_GAIN", aliasesToClear: []),
        .replayGainTrackPeak: TagWriteRule(standardKey: "REPLAYGAIN_TRACK_PEAK", aliasesToClear: []),
        .replayGainAlbumGain: TagWriteRule(standardKey: "REPLAYGAIN_ALBUM_GAIN", aliasesToClear: []),
        .replayGainAlbumPeak: TagWriteRule(standardKey: "REPLAYGAIN_ALBUM_PEAK", aliasesToClear: []),
        .replayGainReferenceLoudness: TagWriteRule(standardKey: "REPLAYGAIN_REFERENCE_LOUDNESS", aliasesToClear: []),
    ]

    static func ruleOf(_ key: AudioTagFieldKey) -> TagWriteRule? { rules[key] }
}

enum TagMapBuilder {
    /// Returns key -> value updates; "" means "remove key" (same contract as Android).
    static func build(fileExtension: String, current: AudioTagData, mutation: AudioTagMutation) -> [String: String] {
        var result: [String: String] = [:]
        for (key, fieldMutation) in mutation.fields {
            if key == .rating {
                applyRating(&result, ext: fileExtension, fieldMutation)
                continue
            }
            guard let rule = AudioTagWriteRules.ruleOf(key) else { continue }
            switch fieldMutation {
            case .unchanged: break
            case .clear:
                result[rule.standardKey] = ""
                rule.aliasesToClear.forEach { result[$0] = "" }
            case .set(let value):
                result[rule.standardKey] = value
                rule.aliasesToClear.forEach { result[$0] = "" }
            }
        }
        for custom in mutation.customFields {
            switch custom {
            case .unchanged: break
            case .replaceAll(let fields):
                for key in (current.rawProperties ?? [:]).keys where !AudioTagKeys.isReserved(key) {
                    if result[key] == nil { result[key] = "" }
                }
                for f in fields { putCustomField(&result, f.key, f.value) }
            case .set(let key, let value): putCustomField(&result, key, value)
            case .clear(let key): putCustomField(&result, key, "")
            }
        }
        return result
    }

    private static func applyRating(_ result: inout [String: String], ext rawExt: String, _ m: FieldMutation) {
        switch m {
        case .unchanged: return
        case .clear:
            result["POPM"] = ""; result["RATING"] = ""; result["RATE"] = ""
        case .set(let value):
            let star = Int(value) ?? 0
            let ext = rawExt.uppercased()
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
    }

    private static func putCustomField(_ result: inout [String: String], _ rawKey: String, _ rawValue: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if key.isEmpty || AudioTagKeys.isReserved(key) { return }
        result[key] = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
