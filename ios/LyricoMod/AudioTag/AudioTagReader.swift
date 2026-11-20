// Swift port of com.lonx.audiotag.rw.AudioTagReader.
import Foundation

public enum AudioTagReader {
    public struct ReadError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Reads tags + audio properties from a local file. Mirrors the Kotlin signature (pfd -> url).
    public static func read(
        _ url: URL,
        readPictures: Bool = true,
        multiValueSeparator: String = "/",
        strict: Bool = false,
        audioPropertiesReadStyle: AudioPropertiesReadStyle = .average
    ) throws -> AudioTagData {
        do {
            let audioProps = TagLib.getAudioProperties(url, readStyle: audioPropertiesReadStyle)
            let metadata = try TagLib.getMetadata(url, readPictures: readPictures)
            var data = build(metadata: metadata, audio: audioProps, readPictures: readPictures, separator: multiValueSeparator)
            data.fileName = url.lastPathComponent
            return data
        } catch {
            if strict { throw ReadError(message: error.localizedDescription) }
            var empty = AudioTagData()
            empty.fileName = url.lastPathComponent
            return empty
        }
    }

    /// Reader based variant (remote partial reads). Audio properties use Fast by default.
    public static func read(
        reader: LTRandomAccessReader,
        fileName: String,
        readPictures: Bool = true,
        multiValueSeparator: String = "/",
        audioPropertiesReadStyle: AudioPropertiesReadStyle = .fast
    ) throws -> AudioTagData {
        let audio = TagLib.getAudioProperties(reader: reader, readStyle: audioPropertiesReadStyle)
        let metadata = try TagLib.getMetadata(reader: reader, readPictures: readPictures)
        var data = build(metadata: metadata, audio: audio, readPictures: readPictures, separator: multiValueSeparator)
        data.fileName = fileName
        return data
    }

    /// Returns the bytes of the requested picture, or empty Data.
    public static func readPicture(
        _ url: URL,
        pictureType: AudioPictureType = .frontCover,
        fallbackPictureTypes: [AudioPictureType] = [],
        fallbackToAny: Bool? = nil,
        description: String? = nil
    ) -> Data {
        TagLib.getPicture(url, pictureType: pictureType, fallbackPictureTypes: fallbackPictureTypes,
                          fallbackToAny: fallbackToAny ?? (pictureType == .frontCover), description: description)?.data ?? Data()
    }

    static func build(metadata: Metadata, audio: AudioProperties?, readPictures: Bool, separator: String) -> AudioTagData {
        let props = metadata.propertyMap

        func firstOf(_ keys: String...) -> String? {
            for key in keys {
                if let arr = props[key], let first = arr.first {
                    let v = first.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !v.isEmpty { return v }
                }
            }
            return nil
        }
        func joinedOf(_ keys: String...) -> String? {
            for key in keys {
                if let arr = props[key] {
                    let filtered = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    if !filtered.isEmpty { return filtered.joined(separator: separator) }
                }
            }
            return nil
        }
        func intPrefix(_ raw: String?) -> Int? {
            guard let raw else { return nil }
            let head = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
            return Int(head.trimmingCharacters(in: .whitespaces))
        }

        var ratingStar: Int? = nil
        if let rawRating = firstOf("RATING", "POPM", "RATE") {
            if rawRating.contains("|") {
                let parts = rawRating.split(separator: "|", omittingEmptySubsequences: false)
                let popm = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                switch popm {
                case 255...: ratingStar = 5
                case 196...: ratingStar = 4
                case 128...: ratingStar = 3
                case 64...: ratingStar = 2
                case 1...: ratingStar = 1
                default: ratingStar = 0
                }
            } else {
                let r = Int(rawRating) ?? 0
                if r > 5 {
                    switch r {
                    case 100...: ratingStar = 5
                    case 80...: ratingStar = 4
                    case 60...: ratingStar = 3
                    case 40...: ratingStar = 2
                    case 1...: ratingStar = 1
                    default: ratingStar = 0
                    }
                } else {
                    ratingStar = r
                }
            }
            if ratingStar == 0 { ratingStar = nil }
        }

        let customFields = props
            .filter { !AudioTagKeys.isReserved($0.key) }
            .map { CustomTagField(key: $0.key, value: $0.value.joined(separator: "; ")) }
            .sorted { $0.key.uppercased() < $1.key.uppercased() }

        var d = AudioTagData()
        d.title = joinedOf("TITLE")
        d.artist = joinedOf("ARTIST")
        d.album = joinedOf("ALBUM")
        d.genre = joinedOf("GENRE", "TCON") ?? joinedOf("STYLE", "SUBGENRE", "MOOD")
        d.date = joinedOf("DATE", "YEAR")
        d.language = joinedOf("LANGUAGE", "TLAN")
        d.trackNumber = intPrefix(firstOf("TRACKNUMBER", "TRACK", "TRCK")).map(String.init)
        d.albumArtist = joinedOf("ALBUMARTIST", "ALBUM ARTIST", "TPE2", "aART", "ALBUMARTISTSORT")
        d.discNumber = intPrefix(firstOf("DISCNUMBER", "DISC", "TPOS", "DISKNUMBER"))
        d.composer = joinedOf("COMPOSER", "TCOM", "©wrt")
        d.lyricist = joinedOf("LYRICIST", "TEXT", "WRITER", "LYRICS BY")
        d.comment = joinedOf("COMMENT", "COMM", "DESCRIPTION")
        d.lyrics = joinedOf("LYRICS", "UNSYNCED LYRICS", "USLT", "LYRIC", "LYRICSENG")
        d.copyright = joinedOf("COPYRIGHT", "TCOP", "CPRO", "©cpy")
        d.rating = ratingStar
        d.replayGainTrackGain = joinedOf("REPLAYGAIN_TRACK_GAIN")
        d.replayGainTrackPeak = joinedOf("REPLAYGAIN_TRACK_PEAK")
        d.replayGainAlbumGain = joinedOf("REPLAYGAIN_ALBUM_GAIN")
        d.replayGainAlbumPeak = joinedOf("REPLAYGAIN_ALBUM_PEAK")
        d.replayGainReferenceLoudness = joinedOf("REPLAYGAIN_REFERENCE_LOUDNESS")
        d.durationMilliseconds = audio?.length ?? 0
        d.bitrate = audio?.bitrate ?? 0
        d.sampleRate = audio?.sampleRate ?? 0
        d.channels = audio?.channels ?? 0
        d.rawProperties = props
        d.customFields = customFields
        if readPictures {
            d.pictures = metadata.pictures.map {
                AudioPicture(data: $0.data, mimeType: $0.mimeType, description: $0.description, pictureType: $0.pictureType)
            }
        }
        d.supportsTypedPictures = metadata.supportsTypedPictures
        return d
    }
}
