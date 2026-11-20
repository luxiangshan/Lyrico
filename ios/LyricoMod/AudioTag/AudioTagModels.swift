// Swift port of lyrico-audiotag/src/main/java/com/lonx/audiotag/model/*.kt
import Foundation

/// PropertyMap is a map of property names to arrays of values (Kotlin: HashMap<String, Array<String>>).
public typealias PropertyMap = [String: [String]]

/// Length in milliseconds, bitrate in kbps, sample rate in Hz.
public struct AudioProperties: Equatable, Sendable {
    public var length: Int
    public var bitrate: Int
    public var sampleRate: Int
    public var channels: Int
    public static let empty = AudioProperties(length: 0, bitrate: 0, sampleRate: 0, channels: 0)
}

public enum AudioPropertiesReadStyle: Int, Sendable {
    /// Read as little of the file as possible
    case fast = 0
    /// Read more of the file and make better values guesses
    case average = 1
    /// Read as much of the file as needed to report accurate values
    case accurate = 2
}

/// Picture contains information and data of a picture (Kotlin: com.lonx.audiotag.model.Picture).
public struct Picture: Equatable, Hashable, Sendable {
    public var data: Data
    public var description: String
    /// ID3v2 type name, e.g. "Front Cover"
    public var pictureType: String
    public var mimeType: String
}

/// Metadata contains property map and pictures of an audio file.
public struct Metadata: Equatable, Sendable {
    public var propertyMap: PropertyMap
    public var pictures: [Picture]
    public var supportsTypedPictures: Bool
}

public enum AudioPictureType: String, CaseIterable, Sendable {
    case other = "Other"
    case fileIcon = "32x32 pixels 'file icon' (PNG only)"
    case otherFileIcon = "Other file icon"
    case frontCover = "Front Cover"
    case backCover = "Back Cover"
    case leafletPage = "Leaflet Page"
    case media = "Media"
    case leadArtist = "Lead Artist"
    case artist = "Artist"
    case conductor = "Conductor"
    case band = "Band"
    case composer = "Composer"
    case lyricist = "Lyricist"
    case recordingLocation = "Recording Location"
    case duringRecording = "During Recording"
    case duringPerformance = "During Performance"
    case movieCapture = "Movie Capture"
    case brightColoredFish = "A bright coloured fish"
    case illustration = "Illustration"
    case bandLogo = "Band Logo"
    case publisherLogo = "Publisher Logo"
    case unknown = "Unknown"

    public var tagLibName: String { rawValue }

    public static func fromTagLibName(_ value: String?) -> AudioPictureType {
        let normalized = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return .other }
        if let match = allCases.first(where: { $0.tagLibName.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return match
        }
        switch normalized.lowercased() {
        case "cover (front)": return .frontCover
        case "cover (back)": return .backCover
        case "band/orchestra": return .band
        case "lead performer": return .leadArtist
        default: return .unknown
        }
    }
}

/// 标签中可承载艺术家图片的图片类型。
public let artistPictureTypes: [AudioPictureType] = [.artist, .leadArtist, .band]

public struct CustomTagField: Equatable, Hashable, Sendable, Identifiable {
    public var key: String = ""
    public var value: String = ""
    public var id: String { key }
    public init(key: String = "", value: String = "") { self.key = key; self.value = value }
}

public struct AudioPicture: Equatable, Hashable, Sendable {
    public var data: Data
    public var mimeType: String = "image/jpeg"
    public var description: String = ""
    public var pictureType: String = "Front Cover"

    public init(data: Data, mimeType: String = "image/jpeg", description: String = "", pictureType: String = "Front Cover") {
        self.data = data
        self.mimeType = mimeType
        self.description = description
        self.pictureType = pictureType
    }

    public var type: AudioPictureType { AudioPictureType.fromTagLibName(pictureType) }
}

public extension Array where Element == AudioPicture {
    func frontCoverOrFallback() -> AudioPicture? {
        first(where: { $0.type == .frontCover }) ?? first(where: { $0.type == .other }) ?? first
    }

    func pictureOfType(_ type: AudioPictureType) -> AudioPicture? {
        first(where: { $0.type == type })
    }

    func replacePicture(_ picture: AudioPicture, type: AudioPictureType = .frontCover) -> [AudioPicture] {
        var normalized = picture
        normalized.pictureType = type.tagLibName
        return [normalized] + filter { $0.type != type }
    }

    func removePictureType(_ type: AudioPictureType) -> [AudioPicture] {
        filter { $0.type != type }
    }

    func addPicture(_ picture: AudioPicture) -> [AudioPicture] { self + [picture] }
}

/// Swift port of com.lonx.audiotag.model.AudioTagData.
public struct AudioTagData: Equatable, Sendable {
    public var title: String? = nil
    public var artist: String? = nil
    public var album: String? = nil
    public var albumArtist: String? = nil
    public var genre: String? = nil
    public var date: String? = nil
    public var language: String? = nil
    public var trackNumber: String? = nil
    public var discNumber: Int? = nil

    public var composer: String? = nil
    public var lyricist: String? = nil
    public var comment: String? = nil
    public var lyrics: String? = nil
    public var copyright: String? = nil
    public var rating: Int? = nil
    public var replayGainTrackGain: String? = nil
    public var replayGainTrackPeak: String? = nil
    public var replayGainAlbumGain: String? = nil
    public var replayGainAlbumPeak: String? = nil
    public var replayGainReferenceLoudness: String? = nil
    public var fileName: String = ""
    public var durationMilliseconds: Int = 0
    public var bitrate: Int = 0
    public var sampleRate: Int = 0
    public var channels: Int = 0

    public var rawProperties: PropertyMap? = nil
    public var customFields: [CustomTagField] = []

    public var pictures: [AudioPicture] = []
    public var picUrl: String? = nil
    public var supportsTypedPictures: Bool = false

    public init() {}
}

public enum AudioTagKeys {
    private static let reservedKeys: Set<String> = [
        "TITLE", "TIT2", "TIT1",
        "ARTIST", "TPE1",
        "ALBUM", "TALB",
        "GENRE", "TCON", "STYLE", "SUBGENRE", "MOOD",
        "DATE", "YEAR", "TYER", "TDAT",
        "LANGUAGE", "TLAN",
        "TRACKNUMBER", "TRACK", "TRCK",
        "ALBUMARTIST", "ALBUM ARTIST", "TPE2", "AART", "ALBUMARTISTSORT",
        "DISCNUMBER", "DISC", "TPOS", "DISKNUMBER",
        "COMPOSER", "TCOM", "©WRT",
        "COMMENT", "COMM", "DESCRIPTION",
        "LYRICIST", "TEXT", "WRITER", "LYRICS BY",
        "LYRICS", "UNSYNCED LYRICS", "USLT", "LYRIC", "LYRICSENG",
        "COPYRIGHT", "TCOP", "CPRO", "©CPY",
        "RATING", "POPM", "RATE",
        "REPLAYGAIN_TRACK_GAIN", "REPLAYGAIN_TRACK_PEAK",
        "REPLAYGAIN_ALBUM_GAIN", "REPLAYGAIN_ALBUM_PEAK",
        "REPLAYGAIN_REFERENCE_LOUDNESS",
        "PICTURE",
    ]

    public static func isReserved(_ key: String) -> Bool {
        reservedKeys.contains(key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }
}
