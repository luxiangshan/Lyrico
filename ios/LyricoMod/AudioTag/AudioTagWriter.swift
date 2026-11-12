// Swift port of com.lonx.audiotag.rw.AudioTagWriter.
import Foundation

public enum AudioTagWriter {
    /// Writes `updates` (key -> single value; "" removes the key). With preserveOldTags the
    /// existing property map is merged first, exactly like the Kotlin implementation.
    @discardableResult
    public static func writeTags(_ url: URL, updates: [String: String], preserveOldTags: Bool = true) throws -> Bool {
        var mapToSave = PropertyMap()
        if preserveOldTags, let old = try? TagLib.getMetadata(url, readPictures: false) {
            mapToSave.merge(old.propertyMap) { _, new in new }
        }
        for (k, v) in updates {
            mapToSave[k] = [v]
        }
        return try TagLib.savePropertyMap(url, propertyMap: mapToSave)
    }

    /// Multi-value aware variant (each key replaced by the given list; [] removes it).
    @discardableResult
    public static func writePropertyMap(_ url: URL, updates: PropertyMap) throws -> Bool {
        try TagLib.savePropertyMap(url, propertyMap: updates)
    }

    @discardableResult
    public static func writePictures(_ url: URL, pictures: [AudioPicture]) throws -> Bool {
        try TagLib.savePictures(url, pictures: pictures.map {
            Picture(data: $0.data, description: $0.description, pictureType: $0.pictureType, mimeType: $0.mimeType)
        })
    }
}
