// Swift port of com.lonx.audiotag.TagLib. Kotlin takes file descriptors; on iOS we pass file URLs
// (security-scoped access must already be active) or an LTRandomAccessReader for partial reads.
import Foundation

public enum TagLib {
    public static var version: String { LTTagLib.tagLibVersion() }

    public static func getAudioProperties(_ url: URL, readStyle: AudioPropertiesReadStyle = .average) -> AudioProperties? {
        guard let p = try? LTTagLib.audioProperties(atPath: url.path, readStyle: readStyle.rawValue) else {
            return .empty
        }
        return AudioProperties(length: p.length, bitrate: p.bitrate, sampleRate: p.sampleRate, channels: p.channels)
    }

    public static func getMetadata(_ url: URL, readPictures: Bool = true) throws -> Metadata {
        let m = try LTTagLib.metadata(atPath: url.path, readPictures: readPictures)
        return convert(m)
    }

    public static func getMetadataPropertyValues(_ url: URL, propertyName: String) -> [String]? {
        LTTagLib.propertyValues(atPath: url.path, propertyName: propertyName)
    }

    public static func getPictures(_ url: URL) -> [Picture] {
        LTTagLib.pictures(atPath: url.path).map(convert)
    }

    /// See the Kotlin documentation of TagLib.getPicture for the description matching rules.
    public static func getPicture(
        _ url: URL,
        pictureType: AudioPictureType,
        fallbackPictureTypes: [AudioPictureType] = [],
        fallbackToAny: Bool = false,
        description: String? = nil
    ) -> Picture? {
        selectPicture(getPictures(url), pictureType: pictureType, fallbackPictureTypes: fallbackPictureTypes,
                      fallbackToAny: fallbackToAny, description: description)
    }

    public static func getFrontCover(_ url: URL) -> Picture? {
        getPicture(url, pictureType: .frontCover, fallbackToAny: true)
    }

    @discardableResult
    public static func savePropertyMap(_ url: URL, propertyMap: PropertyMap) throws -> Bool {
        try LTTagLib.savePropertyMap(propertyMap, atPath: url.path)
        return true
    }

    @discardableResult
    public static func savePictures(_ url: URL, pictures: [Picture]) throws -> Bool {
        let list = pictures.map {
            LTPicture(data: $0.data, pictureDescription: $0.description, pictureType: $0.pictureType, mimeType: $0.mimeType)
        }
        try LTTagLib.savePictures(list, atPath: url.path)
        return true
    }

    // MARK: Reader based (read-only, e.g. remote partial reads)

    public static func getMetadata(reader: LTRandomAccessReader, readPictures: Bool = true) throws -> Metadata {
        convert(try LTTagLib.metadata(with: reader, readPictures: readPictures))
    }

    public static func getAudioProperties(reader: LTRandomAccessReader, readStyle: AudioPropertiesReadStyle = .fast) -> AudioProperties {
        guard let p = try? LTTagLib.audioProperties(with: reader, readStyle: readStyle.rawValue) else { return .empty }
        return AudioProperties(length: p.length, bitrate: p.bitrate, sampleRate: p.sampleRate, channels: p.channels)
    }

    public static func getPictures(reader: LTRandomAccessReader) -> [Picture] {
        LTTagLib.pictures(with: reader).map(convert)
    }

    // MARK: Helpers

    static func selectPicture(
        _ pictures: [Picture],
        pictureType: AudioPictureType,
        fallbackPictureTypes: [AudioPictureType],
        fallbackToAny: Bool,
        description: String?
    ) -> Picture? {
        let types = [pictureType] + fallbackPictureTypes
        let requested = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, !requested.isEmpty {
            for type in types {
                if let p = pictures.first(where: {
                    $0.pictureType == type.tagLibName &&
                        $0.description.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(requested) == .orderedSame
                }) { return p }
            }
            for type in types {
                if let p = pictures.first(where: {
                    $0.pictureType == type.tagLibName && $0.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) { return p }
            }
            return fallbackToAny ? pictures.first : nil
        }
        for type in types {
            if let p = pictures.first(where: { $0.pictureType == type.tagLibName }) { return p }
        }
        return fallbackToAny ? pictures.first : nil
    }

    private static func convert(_ p: LTPicture) -> Picture {
        Picture(data: p.data, description: p.pictureDescription, pictureType: p.pictureType, mimeType: p.mimeType)
    }

    private static func convert(_ m: LTMetadata) -> Metadata {
        Metadata(propertyMap: m.propertyMap, pictures: m.pictures.map(convert), supportsTypedPictures: m.supportsTypedPictures)
    }
}
