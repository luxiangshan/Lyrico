import Foundation

/// Port of `LrcDocumentFormat.kt` (plain / verbatim / enhanced LRC parsers and writers).
enum LrcDocumentFormat {
    private static let tagPattern = KRegex("^\\[([A-Za-z][A-Za-z0-9_-]*):(.*)]$")

    static func parse(_ raw: String, sourceFormat: LyricFormat) -> LyricsDocument {
        var metadata = StringMap()
        var lines: [LyricsDocumentLine] = []

        for line in raw.ktLines() {
            if line.ktIsBlank { continue }
            if let tag = tagPattern.matchEntire(line) {
                metadata[tag.groupValues[1]] = tag.groupValues[2].ktTrim()
                continue
            }
            let matches = LyricFormatter.lrcTimePattern.findAll(line)
            if matches.isEmpty { continue }
            let ns = line as NSString
            let start = parseLrcTimeMs(matches[0])
            var words: [LyricsDocumentWord] = []
            for (index, match) in matches.enumerated() {
                let nextStart = matches.getOrNull(index + 1)?.first ?? ns.length
                let text = ns.substring(with: NSRange(location: match.last + 1, length: nextStart - (match.last + 1)))
                let isLeadingEnhancedLineTimestamp = index == 0 && match.value.hasPrefix("[") &&
                    (matches.getOrNull(index + 1)?.value.hasPrefix("<") ?? false) && text.ktIsBlank
                if isLeadingEnhancedLineTimestamp { continue }
                if text.isEmpty { continue }
                let wordStart = parseLrcTimeMs(match)
                let wordEnd = matches.getOrNull(index + 1).map(parseLrcTimeMs) ?? (wordStart + 500)
                words.append(LyricsDocumentWord(startMs: wordStart, endMs: wordEnd, text: text))
            }
            if !words.isEmpty {
                lines.append(LyricsDocumentLine(startMs: start, endMs: words.last!.endMs, text: words.map(\.text).joined(), words: words))
            }
        }

        return LyricsDocument(
            metadata: toLyricsMetadata(metadata),
            tracks: separateTracks(lines, sourceFormat: sourceFormat),
            sourceFormat: sourceFormat
        )
    }

    private static func separateTracks(_ lines: [LyricsDocumentLine], sourceFormat: LyricFormat) -> [LyricsTrack] {
        // groupBy startMs then toSortedMap(nullsLast)
        let grouped = lines.ktGroupBy { $0.startMs }.sorted { a, b in
            switch (a.0, b.0) {
            case let (x?, y?): return x < y
            case (nil, _?): return false
            case (_?, nil): return true
            default: return false
            }
        }
        if !grouped.contains(where: { $0.1.count > 1 }) {
            return [LyricsTrack(type: .original, lines: lines)]
        }
        var original: [LyricsDocumentLine] = []
        var translation: [LyricsDocumentLine] = []
        var romanization: [LyricsDocumentLine] = []
        for (_, group) in grouped {
            let wordLevel = sourceFormat != .plainLrc ? group.filter { $0.words.count > 1 } : []
            let originalLines = wordLevel.isEmpty ? [group[0]] : wordLevel
            let subLines = group.filter { !originalLines.contains($0) }
            original.append(contentsOf: originalLines)
            if subLines.count >= 2 {
                romanization.append(subLines[0])
                translation.append(contentsOf: subLines.dropFirst())
            } else if subLines.count == 1 {
                translation.append(subLines[0])
            }
        }
        var tracks = [LyricsTrack(type: .original, lines: original)]
        if !translation.isEmpty { tracks.append(LyricsTrack(type: .translation, lines: translation)) }
        if !romanization.isEmpty { tracks.append(LyricsTrack(type: .romanization, lines: romanization)) }
        return tracks
    }

    // MARK: Writers

    static func writePlain(_ document: LyricsDocument, lineOrder: [LyricLineTrack]) -> String {
        write(document, lineOrder: lineOrder) { builder, line, _ in appendLine(&builder, line) }
    }

    static func writeEnhanced(_ document: LyricsDocument, lineOrder: [LyricLineTrack]) -> String {
        write(document, lineOrder: lineOrder) { builder, line, _ in appendEnhancedOriginalLine(&builder, line) }
    }

    static func writeVerbatim(_ document: LyricsDocument, lineOrder: [LyricLineTrack]) -> String {
        write(document, lineOrder: lineOrder) { builder, line, isWordLevel in appendVerbatimOriginalLine(&builder, line, isWordLevel) }
    }

    private static func write(_ document: LyricsDocument, lineOrder: [LyricLineTrack],
                              appendOriginal: (inout String, LyricsDocumentLine, Bool) -> Void) -> String {
        var builder = ""
        appendTags(&builder, document.metadata)
        guard let original = document.tracks.first(where: { $0.type == .original }) else { return builder.ktTrim() }
        let isWordLevel = original.lines.contains { $0.words.count > 1 }
        for (_, lines) in original.lines.ktGroupBy({ $0.startMs }) {
            appendOrderedLineGroup(&builder, document, lines, lineOrder) { b, line in appendOriginal(&b, line, isWordLevel) }
        }
        return builder.ktTrim()
    }

    private static func appendTags(_ builder: inout String, _ metadata: LyricsMetadata) {
        if let t = metadata.title { builder += "[ti:" + t + "]\n" }
        if let a = metadata.artist { builder += "[ar:" + a + "]\n" }
        if let a = metadata.album { builder += "[al:" + a + "]\n" }
        if let o = metadata.offsetMs { builder += "[offset:" + String(o) + "]\n" }
        for (k, v) in metadata.extra { builder += "[" + k + ":" + v + "]\n" }
    }

    private static func appendOrderedLineGroup(_ builder: inout String, _ document: LyricsDocument,
                                               _ originalLines: [LyricsDocumentLine], _ lineOrder: [LyricLineTrack],
                                               appendOriginal: (inout String, LyricsDocumentLine) -> Void) {
        guard let originalLine = originalLines.first else { return }
        let romanization = findLinkedLine(document, originalLine, .romanization)
        let translation = findLinkedLine(document, originalLine, .translation)
        for track in lineOrder.normalizedLyricLineOrder {
            switch track {
            case .original: for line in originalLines { appendOriginal(&builder, line) }
            case .romanization: if let r = romanization { appendLine(&builder, r, fallbackStartMs: originalLine.startMs) }
            case .translation: if let t = translation { appendLine(&builder, t, fallbackStartMs: originalLine.startMs) }
            }
        }
    }

    private static func appendEnhancedOriginalLine(_ builder: inout String, _ line: LyricsDocumentLine) {
        guard let start = line.startMs else { return }
        if line.words.count <= 1 { appendLine(&builder, line); return }
        builder += "[" + LyricFormatter.formatTimestamp(start) + "]"
        for word in line.words {
            if let ws = word.startMs { builder += "<" + LyricFormatter.formatTimestamp(ws) + ">" }
            builder += word.text
        }
        let lineEnd = line.words.reversed().first(where: { $0.endMs != nil })?.endMs ?? line.endMs
        if let lineEnd { builder += "<" + LyricFormatter.formatTimestamp(lineEnd) + ">" }
        builder += "\n"
    }

    private static func appendVerbatimOriginalLine(_ builder: inout String, _ line: LyricsDocumentLine, _ isWordLevel: Bool) {
        if !isWordLevel || line.words.isEmpty { appendLine(&builder, line); return }
        for word in line.words {
            if let ws = word.startMs { builder += "[" + LyricFormatter.formatTimestamp(ws) + "]" }
            builder += word.text
        }
        let lineEnd = line.words.reversed().first(where: { $0.endMs != nil })?.endMs ?? line.endMs
        if let lineEnd { builder += "[" + LyricFormatter.formatTimestamp(lineEnd) + "]" }
        builder += "\n"
    }

    private static func appendLine(_ builder: inout String, _ line: LyricsDocumentLine) {
        guard let start = line.startMs else { return }
        builder += "[" + LyricFormatter.formatTimestamp(start) + "]" + line.visibleText + "\n"
    }

    private static func appendLine(_ builder: inout String, _ line: LyricsDocumentLine, fallbackStartMs: Int64?) {
        guard let start = line.startMs ?? fallbackStartMs else { return }
        builder += "[" + LyricFormatter.formatTimestamp(start) + "]" + line.visibleText + "\n"
    }

    private static func findLinkedLine(_ document: LyricsDocument, _ originalLine: LyricsDocumentLine, _ type: LyricsTrackType) -> LyricsDocumentLine? {
        if let key = originalLine.linkKey, let byKey = linesByKey(document, type)[key] { return byKey }
        if let start = originalLine.startMs { return linesByStart(document, type)[start] }
        return nil
    }

    private static func linesByKey(_ document: LyricsDocument, _ type: LyricsTrackType) -> [String: LyricsDocumentLine] {
        var map: [String: LyricsDocumentLine] = [:]
        for track in document.tracks where track.type == type {
            for line in track.lines { if let k = line.linkKey { map[k] = line } }
        }
        return map
    }

    private static func linesByStart(_ document: LyricsDocument, _ type: LyricsTrackType) -> [Int64: LyricsDocumentLine] {
        var map: [Int64: LyricsDocumentLine] = [:]
        for track in document.tracks where track.type == type {
            for line in track.lines { if let s = line.startMs { map[s] = line } }
        }
        return map
    }

    static func toLyricsMetadata(_ map: StringMap) -> LyricsMetadata {
        var extra = StringMap()
        for (k, v) in map where !["ti", "ar", "al", "offset"].contains(k) { extra[k] = v }
        return LyricsMetadata(title: map["ti"], artist: map["ar"], album: map["al"],
                              offsetMs: map["offset"]?.ktToLongOrNull, extra: extra)
    }

    private static func parseLrcTimeMs(_ match: KRegex.Match) -> Int64 {
        let min = Int64(match.groupValues[2]) ?? 0
        let sec = Int64(match.groupValues[3]) ?? 0
        let ms = Int64(match.groupValues[4].ktPadEnd(3, "0").ktTake(3)) ?? 0
        return (min * 60 + sec) * 1000 + ms
    }
}
