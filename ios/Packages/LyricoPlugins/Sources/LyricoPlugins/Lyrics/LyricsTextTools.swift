import Foundation

/// Port of `LyricsColumnSorter` (re-ordering original / translation / romanization columns in raw LRC).
public enum LyricsColumnSorter {
    private static let timestamp = KRegex("\\[([0-9]{1,9}):([0-9]{2})(?:[.:]([0-9]{1,3}))?]")
    private static let wordTimestamp = KRegex("<[0-9]+:[0-9]{2}(?:[.:][0-9]{1,3})?>")
    private static let xmlRoot = KRegex("<(?:[A-Za-z0-9_-]+:)?tt(?:[\(jWhitespaceClass)]|>)", ignoreCase: true)
    private static let token = KRegex("([^\\r\\n]*)(\\r\\n|\\n|\\r|$)")

    public struct Line: Hashable { public let text: String; public let ending: String }
    public struct Group: Hashable { public let indices: [Int]; public let text: [String] }
    public struct Analysis {
        public let lines: [Line]
        public let groups: [Group]
        public let sourceCount: Int
        public var samples: [Group] { groups.filter { $0.indices.count == sourceCount } }
        public var incomplete: [Group] { groups.filter { $0.indices.count != sourceCount } }
    }

    public static func fingerprint(_ raw: String) -> String { Digest.hexLower(Digest.sha256(Array(raw.utf8))) }

    public static func analyze(_ raw: String) -> Analysis {
        let body = raw.hasPrefix("\u{FEFF}") ? String(raw.unicodeScalars.dropFirst()) : raw
        let lines = token.findAll(body).filter { !$0.value.isEmpty }.map { Line(text: $0.groupValues[1], ending: $0.groupValues[2]) }
        if xmlRoot.containsMatch(raw) { return Analysis(lines: lines, groups: [], sourceCount: 0) }
        var keysOrder: [[Int64]] = []
        var groups: [[Int64]: [Int]] = [:]
        for (index, line) in lines.enumerated() {
            let content = line.text.ktTrimStart(chars: [" ", "\t", "\u{FEFF}"])
            let matches = timestamp.findAll(content)
            guard matches.first?.first == 0 else { continue }
            var end = 0
            var keys: [Int64] = []
            for m in matches {
                guard m.first == end else { break }
                end = m.end
                let minutes: Int64 = Int64(m.groupValues[1]) ?? 0
                let seconds: Int64 = Int64(m.groupValues[2]) ?? 0
                let millis: Int64 = Int64(m.groupValues[3].ktPadEnd(3, "0")) ?? 0
                keys.append(minutes * 60000 + seconds * 1000 + millis)
            }
            if groups[keys] == nil { keysOrder.append(keys); groups[keys] = [] }
            groups[keys]!.append(index)
        }
        let result = keysOrder.map { k -> Group in
            let indices = groups[k]!
            return Group(indices: indices, text: indices.map { visible(lines[$0].text) })
        }
        return Analysis(lines: lines, groups: result, sourceCount: result.map { $0.indices.count }.max() ?? 0)
    }

    public static func visible(_ raw: String) -> String {
        wordTimestamp.replace(timestamp.replace(raw, with: ""), with: "").ktTrim()
    }

    public struct InvalidMappingError: Error {}

    public static func apply(_ raw: String, twoColumnMapping: LyricsColumnMapping, threeColumnMapping: LyricsColumnMapping) throws -> String {
        guard twoColumnMapping.isValid, twoColumnMapping.sourceCount == 2, threeColumnMapping.isValid, threeColumnMapping.sourceCount == 3 else {
            throw InvalidMappingError()
        }
        let analysis = analyze(raw)
        if !twoColumnMapping.isChanged && !threeColumnMapping.isChanged { return raw }
        var replacements: [Int: String?] = [:]
        for group in analysis.groups {
            let mapping: LyricsColumnMapping
            switch group.indices.count {
            case 2: mapping = twoColumnMapping
            case 3: mapping = threeColumnMapping
            default: continue
            }
            for (position, index) in group.indices.enumerated() {
                replacements[index] = mapping.order.getOrNull(position).map { analysis.lines[group.indices[$0]].text }
            }
        }
        return rebuild(raw, analysis, replacements)
    }

    /// Legacy single-mapping variant.
    public static func apply(_ raw: String, mapping: LyricsColumnMapping) throws -> String {
        guard mapping.isValid else { throw InvalidMappingError() }
        let analysis = analyze(raw)
        guard analysis.sourceCount == mapping.sourceCount else { throw InvalidMappingError() }
        if !mapping.isChanged { return raw }
        var replacements: [Int: String?] = [:]
        for group in analysis.samples {
            for (position, index) in group.indices.enumerated() {
                replacements[index] = mapping.order.getOrNull(position).map { analysis.lines[group.indices[$0]].text }
            }
        }
        return rebuild(raw, analysis, replacements)
    }

    private static func rebuild(_ raw: String, _ analysis: Analysis, _ replacements: [Int: String?]) -> String {
        var out = raw.hasPrefix("\u{FEFF}") ? "\u{FEFF}" : ""
        for (index, line) in analysis.lines.enumerated() {
            if let replacement = replacements[index] {
                if let r = replacement { out += r + line.ending }
            } else {
                out += line.text + line.ending
            }
        }
        return out
    }
}

/// Port of `LyricsTextCleanup`.
public enum LyricsTextCleanup {
    private static let line = KRegex("([^\\r\\n]*)(\\r\\n|\\n|\\r|$)")
    private static let tag = KRegex("<[^>]+>")
    private static let placeholder = KRegex("^[\(jWhitespaceClass)/\\\\|｜·・.。…_-]*$")

    public static func process(_ raw: String, removeEmptyLines: Bool, tagLineKeywords: [String]) -> String {
        let keywords = tagLineKeywords.map { $0.ktTrim() }.filter { !$0.isEmpty }
        return line.findAll(raw).filter { !$0.value.isEmpty }.filter { match in
            let l = match.groupValues[1]
            let visible = tag.replace(LyricFormatter.lrcTimePattern.replace(l, with: ""), with: "")
            let trimmed = visible.ktTrim()
            let removeEmpty = removeEmptyLines && (trimmed.isEmpty || placeholder.matches(trimmed))
            let removeTag = keywords.contains { l.ktContainsIgnoreCase($0) || visible.ktContainsIgnoreCase($0) }
            return !(removeEmpty || removeTag)
        }.map(\.value).joined()
    }
}

/// Port of `LyricsSearchTextExtractor`.
public enum LyricsSearchTextExtractor {
    private static let lrcTime = KRegex("\\[(?:[0-9]{1,2}:)?[0-9]{1,2}:[0-9]{1,2}(?:[.:][0-9]{1,3})?]")
    private static let ttmlTag = KRegex("<[^>]+>")

    public static func extractLines(_ lyrics: String?) -> [String] {
        let raw = lyrics ?? ""
        if raw.ktIsBlank { return [] }
        var decoded: [String] = []
        if let result = LyricDecoder.decode(raw) {
            let all = [result.original, result.translated, result.romanization].compactMap { $0 }.flatMap { $0 }
            decoded = all.map { $0.words.map(\.text).joined() }
        }
        let source = decoded.isEmpty ? fallbackLines(raw) : decoded
        return source.map { $0.ktTrim() }.filter { $0.ktIsNotBlank }.ktDistinct()
    }

    public static func toSearchText(_ lyrics: String?) -> String? {
        let joined = extractLines(lyrics).joined(separator: "\n")
        return joined.ktIsNotBlank ? joined : nil
    }

    private static func fallbackLines(_ lyrics: String) -> [String] {
        lyrics.ktLines().map { ttmlTag.replace(lrcTime.replace($0, with: ""), with: "").ktTrim() }
            .filter { $0.ktIsNotBlank && !$0.hasPrefix("[") && !$0.hasPrefix("<") }
    }
}
