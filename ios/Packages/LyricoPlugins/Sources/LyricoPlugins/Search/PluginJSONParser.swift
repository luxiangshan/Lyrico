import Foundation

/// Port of `PluginJsonParser`: turns plugin JSON responses into result models.
public enum PluginJSONParser {
    public static func parseSongResults(_ raw: String, pluginId: String, pluginName: String) throws -> [SongSearchResult] {
        try parseItems(raw, pluginId: pluginId, pluginName: pluginName, requireId: true, enforceCover: false)
    }

    public static func parseCoverResults(_ raw: String, pluginId: String, pluginName: String, enforceApi4Contract: Bool = false) throws -> [SongSearchResult] {
        try parseItems(raw, pluginId: pluginId, pluginName: pluginName, requireId: false, enforceCover: enforceApi4Contract)
    }

    private static func parseItems(_ raw: String, pluginId: String, pluginName: String, requireId: Bool, enforceCover: Bool) throws -> [SongSearchResult] {
        let root = try JSONValue.parse(raw)
        let items: [JSONValue]
        switch root {
        case .array(let a): items = a
        case .object(let o): items = o.array("items", "results", "songs", "data") ?? []
        default: items = []
        }
        var out: [SongSearchResult] = []
        for (index, element) in items.enumerated() {
            guard case .object(let obj) = element else { continue }
            let coverUrl = obj.string("picUrl", "coverUrl", "cover_url", "artworkUrl") ?? ""
            let id: String
            if let v = obj.string("id", "songId", "trackId") {
                id = v
            } else if requireId {
                continue
            } else {
                id = coverUrl.ktIsBlank ? "\(pluginId):cover:\(index)" : coverUrl
            }
            let title = obj.string("title", "name", "songName") ?? ""
            let artist = obj.string("artist", "artists", "singer") ?? ""
            let album = obj.string("album", "albumName") ?? ""
            let date = obj.string("year", "date", "releaseDate", "release_date") ?? ""
            if enforceCover && [title, artist, album, date, coverUrl].contains(where: { $0.ktIsBlank }) { continue }
            out.append(SongSearchResult(
                id: id, pluginId: pluginId, pluginName: pluginName, title: title, artist: artist, album: album,
                duration: obj.long("duration", "durationMs", "duration_ms") ?? 0, date: date,
                trackNumber: obj.string("trackNumber", "trackerNumber", "track_number") ?? "",
                picUrl: coverUrl,
                fields: (obj.stringMap("fields", "metadata") ?? StringMap()).sanitizeStandardFields(),
                internal: (obj.stringMap("internal") ?? StringMap()).sanitizePluginInternal()
            ))
        }
        return out
    }

    public static func parseLyricsCandidates(_ raw: String, pluginId: String, pluginName: String, fallbackSong: SongSearchResult,
                                             enforceApi4Contract: Bool = false) throws -> [LyricsCandidateResult] {
        let root = try JSONValue.parse(raw)
        if root.isNull { return [] }
        let elements: [JSONValue]
        switch root {
        case .array(let a): elements = a
        case .object(let o): elements = o.array("items", "results", "candidates") ?? [root]
        default: elements = [root]
        }
        var out: [LyricsCandidateResult] = []
        for (index, element) in elements.enumerated() {
            let tags = element.objectValue?.stringMap("tags") ?? StringMap()
            if enforceApi4Contract && [tags["ti"], tags["ar"], tags["al"], tags["date"]].contains(where: { $0?.ktIsBlank ?? true }) {
                continue
            }
            guard let lyrics = parseLyrics(element) else { continue }
            let candidateId = elements.count == 1 ? fallbackSong.id : "\(fallbackSong.id):lyrics:\(index)"
            out.append(LyricsCandidateResult(
                song: SongSearchResult(
                    id: candidateId, pluginId: pluginId, pluginName: pluginName,
                    title: tags["ti"] ?? fallbackSong.title, artist: tags["ar"] ?? fallbackSong.artist,
                    album: tags["al"] ?? fallbackSong.album, duration: fallbackSong.duration,
                    date: tags["date"] ?? fallbackSong.date, trackNumber: fallbackSong.trackNumber,
                    picUrl: fallbackSong.picUrl, fields: fallbackSong.fields, internal: fallbackSong.internal),
                lyrics: lyrics))
        }
        return out
    }

    public static func parseLyrics(_ raw: String) throws -> LyricsResult? {
        parseLyrics(try JSONValue.parse(raw))
    }

    static func parseLyrics(_ root: JSONValue) -> LyricsResult? {
        if root.isNull { return nil }
        if root.isPrimitive {
            let lrc = root.contentOrNull ?? ""
            return lrc.ktIsNotBlank ? LyricsResult(original: [], payloadType: .rawPlainLrc, isWordByWord: false, rawPlainLrc: lrc) : nil
        }
        guard case .object(let obj) = root else { return nil }
        if obj["notFound"]?.booleanOrNull == true { return nil }
        let tags = obj.stringMap("tags") ?? StringMap()
        let payloadType = obj.primitiveString("type").flatMap(payloadTypeOf) ?? .structured
        let rawPlain = obj.primitiveString("rawPlainLrc", "raw_plain_lrc", "plainLrc", "plain_lrc", "lrc", "originalLrc", "original_lrc") ?? ""
        let rawOriginal = obj.primitiveString("original") ?? ""
        let verbatim = obj.primitiveString("rawVerbatimLrc", "raw_verbatim_lrc") ?? ""
        let enhanced = obj.primitiveString("rawEnhancedLrc", "raw_enhanced_lrc") ?? ""
        let ttml = obj.primitiveString("rawTtml", "raw_ttml") ?? ""
        let multi = obj.primitiveString("rawMultiPersonEnhancedLrc", "raw_multi_person_enhanced_lrc") ?? ""

        if payloadType != .structured {
            let plain = rawPlain.ktIsBlank ? rawOriginal : rawPlain
            let declared: Bool
            switch payloadType {
            case .rawPlainLrc: declared = plain.ktIsNotBlank
            case .rawVerbatimLrc: declared = verbatim.ktIsNotBlank
            case .rawEnhancedLrc: declared = enhanced.ktIsNotBlank
            case .rawTtml: declared = ttml.ktIsNotBlank
            case .rawMultiPersonEnhancedLrc: declared = multi.ktIsNotBlank
            case .structured: declared = false
            }
            guard declared else { return nil }
            return LyricsResult(tags: tags, original: [], payloadType: payloadType, isWordByWord: false, rawPlainLrc: plain,
                                rawVerbatimLrc: verbatim, rawEnhancedLrc: enhanced, rawTtml: ttml, rawMultiPersonEnhancedLrc: multi)
        }

        let originalLines = parseCompactWordLines(obj.array("original", "lines"))
        let translated = parseCompactTextLines(obj.array("translated", "translation", "translations"))
        let romanization = parseCompactWordLines(obj.array("romanization", "romanized", "roma"))
        let agents = parseAgents(obj.array("agents"))
        let metadata = parseMetadataElements(obj.array("metadata"))
        let rawBodyDur = obj.string("bodyDur", "body_dur") ?? ""
        let bodyDur = TtmlTime.isValid(rawBodyDur) ? rawBodyDur : ""
        if originalLines.isEmpty { return nil }
        return LyricsResult(
            tags: tags, original: originalLines,
            translated: translated.isEmpty ? nil : translated,
            romanization: romanization.isEmpty ? nil : romanization,
            payloadType: .structured, isWordByWord: originalLines.isWordByWord,
            agents: agents, metadata: metadata,
            timing: obj.string("timing") ?? "",
            language: obj.string("language") ?? "",
            translatedLang: obj.string("translatedLang", "translated_lang") ?? "",
            romanizationLang: obj.string("romanizationLang", "romanization_lang") ?? "",
            bodyDur: bodyDur)
    }

    private static func payloadTypeOf(_ s: String) -> LyricsPayloadType? {
        switch s.ktTrim() {
        case "structured", "STRUCTURED": return .structured
        case "rawPlainLrc", "raw_plain_lrc", "RAW_PLAIN_LRC", "plainLrc", "plain_lrc", "lrc": return .rawPlainLrc
        case "rawVerbatimLrc", "raw_verbatim_lrc", "RAW_VERBATIM_LRC": return .rawVerbatimLrc
        case "rawEnhancedLrc", "raw_enhanced_lrc", "RAW_ENHANCED_LRC": return .rawEnhancedLrc
        case "rawTtml", "raw_ttml", "RAW_TTML", "ttml": return .rawTtml
        case "rawMultiPersonEnhancedLrc", "raw_multi_person_enhanced_lrc", "RAW_MULTI_PERSON_ENHANCED_LRC": return .rawMultiPersonEnhancedLrc
        default: return nil
        }
    }

    private static func longAt(_ a: [JSONValue], _ i: Int) -> Int64? {
        guard let v = a.getOrNull(i), v.isPrimitive else { return nil }
        return v.longOrNull
    }
    private static func stringAt(_ a: [JSONValue], _ i: Int) -> String? {
        guard let v = a.getOrNull(i), v.isPrimitive else { return nil }
        return v.contentOrNull
    }
    private static func arrayAt(_ a: [JSONValue], _ i: Int) -> [JSONValue]? { a.getOrNull(i)?.arrayValue }

    private static func parseCompactWordLines(_ array: [JSONValue]?) -> [LyricsLine] {
        (array ?? []).compactMap { element in
            guard case .array(let line) = element, let start = longAt(line, 0) else { return nil }
            let end = longAt(line, 1) ?? start
            var extensions = StringMap()
            if let ext = line.getOrNull(3)?.objectValue {
                for (k, v) in parseStringMap(ext) {
                    let prefix = k.ktSubstringBefore(":", missing: "")
                    if prefix.isEmpty || prefix == "ttm" || prefix == "itunes" { extensions[k] = v }
                }
            }
            let words: [LyricsWord]
            if let wordsArray = arrayAt(line, 2) {
                words = wordsArray.compactMap { we in
                    guard case .array(let w) = we else { return nil }
                    let text = stringAt(w, 2) ?? ""
                    if text.isEmpty { return nil }
                    return LyricsWord(start: longAt(w, 0) ?? start, end: longAt(w, 1) ?? end, text: text, ruby: parseRuby(arrayAt(w, 3)))
                }
            } else if let text = stringAt(line, 2), !text.isEmpty {
                words = [LyricsWord(start: start, end: end, text: text)]
            } else {
                words = []
            }
            if words.isEmpty { return nil }
            return LyricsLine(start: start, end: end, words: words, extensions: extensions)
        }
    }

    private static func parseRuby(_ array: [JSONValue]?) -> [LyricsRubySyllable] {
        (array ?? []).compactMap { e in
            guard case .array(let s) = e, let text = stringAt(s, 2), !text.isEmpty else { return nil }
            return LyricsRubySyllable(start: longAt(s, 0), end: longAt(s, 1), text: text)
        }
    }

    private static func parseCompactTextLines(_ array: [JSONValue]?) -> [LyricsLine] {
        (array ?? []).compactMap { e in
            guard case .array(let line) = e, let start = longAt(line, 0) else { return nil }
            let end = longAt(line, 1) ?? start
            let text = stringAt(line, 2) ?? ""
            if text.ktIsBlank { return nil }
            return LyricsLine(start: start, end: end, words: [LyricsWord(start: start, end: end, text: text)])
        }
    }

    private static func parseAgents(_ array: [JSONValue]?) -> [LyricsAgentEntry] {
        (array ?? []).compactMap { e in
            guard case .object(let o) = e, let id = o.primitiveString("id") else { return nil }
            return LyricsAgentEntry(id: id, type: o.primitiveString("type"), name: o.primitiveString("name"))
        }
    }

    private static let duplicatedMetadataNames: Set<String> = ["translations", "transliterations", "ttm:agent"]

    private static func parseMetadataElements(_ array: [JSONValue]?) -> [LyricsMetadataElement] {
        (array ?? []).compactMap { e in
            guard case .object(let o) = e, let node = parseMetadataElement(o) else { return nil }
            if node.name == "songwriters" {
                let valid = !node.children.isEmpty && node.children.allSatisfy { $0.name == "songwriter" && ($0.text?.ktIsNotBlank ?? false) }
                return valid ? node : nil
            }
            if duplicatedMetadataNames.contains(node.name) { return nil }
            return node
        }
    }

    private static func parseMetadataElement(_ o: JSONObject) -> LyricsMetadataElement? {
        guard let name = o.primitiveString("name"), name.ktIsNotBlank else { return nil }
        let namespace = o.primitiveString("namespace")
        let prefix = name.ktSubstringBefore(":", missing: "")
        if !prefix.isEmpty && prefix != "ttm" && prefix != "itunes" && prefix != "xml" && (namespace?.ktIsBlank ?? true) { return nil }
        return LyricsMetadataElement(
            name: name, namespace: namespace,
            attributes: o["attributes"]?.objectValue.map(parseStringMap) ?? StringMap(),
            text: o.primitiveString("text"),
            children: (o["children"]?.arrayValue ?? []).compactMap { $0.objectValue.flatMap(parseMetadataElement) })
    }

    private static func parseStringMap(_ o: JSONObject) -> StringMap {
        var out = StringMap()
        for (k, v) in o where v.isPrimitive { if let c = v.contentOrNull { out[k] = c } }
        return out
    }
}

extension JSONObject {
    /// `JsonObject.string(vararg keys)` (arrays are joined with "/").
    func string(_ keys: String...) -> String? { string(keys) }

    func string(_ keys: [String]) -> String? {
        for key in keys {
            guard let value = self[key] else { continue }
            switch value {
            case .array(let a):
                let joined = a.map { item -> String in
                    switch item {
                    case .object(let o): return o.string("name", "title", "value") ?? ""
                    case .array: return ""
                    default: return item.contentOrNull ?? ""
                    }
                }.joined(separator: "/")
                if joined.ktIsNotBlank { return joined }
            case .object:
                continue
            default:
                if let c = value.contentOrNull { return c }
            }
        }
        return nil
    }

    func primitiveString(_ keys: String...) -> String? {
        for key in keys { if let v = self[key], v.isPrimitive, let c = v.contentOrNull { return c } }
        return nil
    }

    func long(_ keys: String...) -> Int64? {
        for key in keys { if let v = self[key], v.isPrimitive, let l = v.longOrNull { return l } }
        return nil
    }

    func array(_ keys: String...) -> [JSONValue]? {
        for key in keys { if case .array(let a)? = self[key] { return a } }
        return nil
    }

    /// `stringMap`: primitives by content, nested values as compact JSON.
    func stringMap(_ keys: String...) -> StringMap? {
        for key in keys {
            guard case .object(let o)? = self[key] else { continue }
            var out = StringMap()
            for (k, v) in o {
                switch v {
                case .array, .object: out[k] = v.jsonString
                default: if let c = v.contentOrNull { out[k] = c }
                }
            }
            return out
        }
        return nil
    }
}
