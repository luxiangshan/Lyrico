import Foundation

/// Port of `LyricsDocumentPipeline`: parse → post-process → write between LRC/enhanced/verbatim/TTML.
public enum LyricsDocumentPipeline {
    public static func parse(_ raw: String, sourceFormat: LyricFormat) throws -> LyricsDocument? {
        switch sourceFormat {
        case .plainLrc, .verbatimLrc, .enhancedLrc: return LrcDocumentFormat.parse(raw, sourceFormat: sourceFormat)
        case .ttml: return try TtmlParser.parse(raw)
        }
    }

    static func write(_ document: LyricsDocument, format: LyricFormat, lineOrder: [LyricLineTrack]) -> String {
        switch format {
        case .plainLrc: return LrcDocumentFormat.writePlain(document, lineOrder: lineOrder)
        case .enhancedLrc: return LrcDocumentFormat.writeEnhanced(document, lineOrder: lineOrder)
        case .verbatimLrc: return LrcDocumentFormat.writeVerbatim(document, lineOrder: lineOrder)
        case .ttml: return TtmlWriter.write(document, lineOrder: lineOrder)
        }
    }

    public static func processRawResult(_ result: LyricsResult, config: LyricRenderConfig, offset: Int64 = 0) throws -> String? {
        guard let source = selectSource(result, config) else { return nil }
        let raw = rawFor(result, source)
        guard raw.ktIsNotBlank else { return nil }
        return try process(raw: raw, sourceFormat: source, targetFormat: config.format, conversionMode: config.conversionMode,
                           showTranslation: config.showTranslation, showRomanization: config.showRomanization,
                           onlyTranslationIfAvailable: config.onlyTranslationIfAvailable, lineOrder: config.normalizedLineOrder,
                           removeEmptyLines: config.removeEmptyLines, offset: offset)
    }

    static func processRawResultForFieldRule(_ result: LyricsResult, rule: ResolvedFieldProcessRule) throws -> LyricsResult {
        func processRaw(_ raw: String, _ format: LyricFormat) throws -> String {
            if raw.ktIsBlank { return raw }
            return try process(raw: raw, sourceFormat: format, targetFormat: format, conversionMode: rule.scriptConversion,
                               normalizeWhitespace: rule.normalizeWhitespace, removeEmptyLines: rule.removeEmptyLines) ?? raw
        }
        var copy = result
        copy.rawPlainLrc = try processRaw(result.rawPlainLrc, .plainLrc)
        copy.rawVerbatimLrc = try processRaw(result.rawVerbatimLrc, .verbatimLrc)
        copy.rawEnhancedLrc = try processRaw(result.rawEnhancedLrc, .enhancedLrc)
        copy.rawTtml = try processRaw(result.rawTtml, .ttml)
        copy.rawMultiPersonEnhancedLrc = try processRaw(result.rawMultiPersonEnhancedLrc, .enhancedLrc)
        return copy
    }

    public static func process(
        raw: String,
        sourceFormat: LyricFormat,
        targetFormat: LyricFormat,
        conversionMode: ConversionMode = .none,
        showTranslation: Bool = true,
        showRomanization: Bool = true,
        onlyTranslationIfAvailable: Bool = false,
        lineOrder: [LyricLineTrack] = defaultLyricLineOrder,
        normalizeWhitespace: Bool = false,
        removeEmptyLines: Bool = false,
        removeTagLineKeywords: [String] = [],
        offset: Int64 = 0
    ) throws -> String? {
        guard let document = try parse(raw, sourceFormat: sourceFormat) else { return nil }
        return processDocument(document, targetFormat: targetFormat, conversionMode: conversionMode,
                               showTranslation: showTranslation, showRomanization: showRomanization,
                               onlyTranslationIfAvailable: onlyTranslationIfAvailable, lineOrder: lineOrder,
                               normalizeWhitespace: normalizeWhitespace, removeEmptyLines: removeEmptyLines,
                               removeTagLineKeywords: removeTagLineKeywords, offset: offset)
    }

    public static func processStructuredResult(_ result: LyricsResult, config: LyricRenderConfig, offset: Int64 = 0) -> String? {
        processDocument(toLyricsDocument(result), targetFormat: .ttml, conversionMode: config.conversionMode,
                        showTranslation: config.showTranslation, showRomanization: config.showRomanization,
                        onlyTranslationIfAvailable: config.onlyTranslationIfAvailable, lineOrder: config.normalizedLineOrder,
                        removeEmptyLines: config.removeEmptyLines, offset: offset)
    }

    static func processDocument(
        _ document: LyricsDocument,
        targetFormat: LyricFormat,
        conversionMode: ConversionMode,
        showTranslation: Bool,
        showRomanization: Bool,
        onlyTranslationIfAvailable: Bool,
        lineOrder: [LyricLineTrack],
        normalizeWhitespace: Bool = false,
        removeEmptyLines: Bool,
        removeTagLineKeywords: [String] = [],
        offset: Int64
    ) -> String? {
        var processed = document
        if conversionMode != .none { processed = transformText(processed) { ChineseConverter.convert($0, conversionMode) } }
        if normalizeWhitespace { processed = transformText(processed, normalizeVisibleWhitespace) }
        if !showTranslation { processed.tracks.removeAll { $0.type == .translation } }
        if !showRomanization { processed.tracks.removeAll { $0.type == .romanization } }
        let keywords = removeTagLineKeywords.map { $0.ktTrim() }.filter { !$0.isEmpty }
        if !keywords.isEmpty { processed = removeTagLines(processed, keywords) }
        if removeEmptyLines { processed = Self.removeEmptyLines(processed) }
        if onlyTranslationIfAvailable { processed = onlyTranslation(processed) }
        if offset != 0 { processed = applyOffset(processed, offset) }
        let output = write(processed, format: targetFormat, lineOrder: lineOrder)
        return output.ktIsNotBlank ? output : nil
    }

    // MARK: Structured <-> document

    public static func toLyricsDocument(_ result: LyricsResult) -> LyricsDocument {
        var tracks = [LyricsTrack(type: .original, lines: result.original.map(toDocumentLine))]
        if let translated = result.translated {
            tracks.append(LyricsTrack(type: .translation, language: result.translatedLang.ktIsNotBlank ? result.translatedLang : nil,
                                      lines: translated.map(toDocumentLine)))
        }
        if let romanization = result.romanization {
            tracks.append(LyricsTrack(type: .romanization, language: result.romanizationLang.ktIsNotBlank ? result.romanizationLang : nil,
                                      lines: romanization.map(toDocumentLine)))
        }
        var metadata = LrcDocumentFormat.toLyricsMetadata(result.tags)
        metadata.timing = result.timing.ktIsNotBlank ? result.timing : nil
        metadata.language = result.language.ktIsNotBlank ? result.language : nil
        return LyricsDocument(
            metadata: metadata,
            agents: result.agents.map { LyricsAgent(id: $0.id, name: $0.name, rawType: $0.type) },
            tracks: tracks,
            bodyExtensions: result.bodyDur.ktIsNotBlank ? ExtensionMap(attributes: [QualifiedName(localName: "dur"): result.bodyDur]) : ExtensionMap(),
            headMetadataElements: result.metadata.filter { $0.name != "songwriters" }.map(toExtensionElement),
            itunesMetadataElements: result.metadata.filter { $0.name == "songwriters" }.map(toExtensionElement),
            sourceFormat: nil
        )
    }

    public static func toLyricsResult(_ document: LyricsDocument) -> LyricsResult {
        let originalDocumentLines = document.tracks.first { $0.type == .original }?.lines ?? []
        let originalLines = originalDocumentLines.compactMap { toLyricsLine($0) }
        var originalByKey: [String: LyricsDocumentLine] = [:]
        var originalByStart: [Int64: LyricsDocumentLine] = [:]
        for line in originalDocumentLines {
            if let k = line.linkKey { originalByKey[k] = line }
            if let s = line.startMs { originalByStart[s] = line }
        }
        func linked(_ type: LyricsTrackType) -> [LyricsLine]? {
            let lines = document.tracks.filter { $0.type == type }.flatMap(\.lines).compactMap { line -> LyricsLine? in
                let fallback = line.linkKey.flatMap { originalByKey[$0] } ?? line.startMs.flatMap { originalByStart[$0] }
                return toLyricsLine(line, fallback: fallback)
            }
            return lines.isEmpty ? nil : lines
        }
        var tags = StringMap()
        if let t = document.metadata.title { tags["ti"] = t }
        if let a = document.metadata.artist { tags["ar"] = a }
        if let a = document.metadata.album { tags["al"] = a }
        if let o = document.metadata.offsetMs { tags["offset"] = String(o) }
        for (k, v) in document.metadata.extra { tags[k] = v }

        return LyricsResult(
            tags: tags,
            original: originalLines,
            translated: linked(.translation),
            romanization: linked(.romanization),
            isWordByWord: originalLines.isWordByWord,
            agents: document.agents.map { LyricsAgentEntry(id: $0.id, type: $0.rawType ?? ttmlAgentType($0.type), name: $0.name) },
            metadata: (document.headMetadataElements + document.itunesMetadataElements).map(toLyricsMetadataElement),
            timing: document.metadata.timing ?? "",
            language: document.metadata.language ?? "",
            translatedLang: document.tracks.first { $0.type == .translation }?.language ?? "",
            romanizationLang: document.tracks.first { $0.type == .romanization }?.language ?? "",
            bodyDur: document.bodyExtensions.attributes.pairs.first { $0.0.namespaceUri == nil && $0.0.localName == "dur" }?.1 ?? ""
        )
    }

    private static func selectSource(_ result: LyricsResult, _ config: LyricRenderConfig) -> LyricFormat? {
        if config.format == .ttml && result.rawTtml.ktIsNotBlank { return .ttml }
        if config.format == .enhancedLrc && result.rawEnhancedLrc.ktIsNotBlank { return .enhancedLrc }
        if config.format == .verbatimLrc && result.rawVerbatimLrc.ktIsNotBlank { return .verbatimLrc }
        if config.format == .plainLrc && result.rawPlainLrc.ktIsNotBlank { return .plainLrc }
        if result.rawTtml.ktIsNotBlank && (config.showTranslation || config.onlyTranslationIfAvailable) { return .ttml }
        if result.rawEnhancedLrc.ktIsNotBlank { return .enhancedLrc }
        if result.rawVerbatimLrc.ktIsNotBlank { return .verbatimLrc }
        if result.rawPlainLrc.ktIsNotBlank { return .plainLrc }
        return nil
    }

    private static func rawFor(_ result: LyricsResult, _ format: LyricFormat) -> String {
        switch format {
        case .plainLrc: return result.rawPlainLrc
        case .verbatimLrc: return result.rawVerbatimLrc.ktIsBlank ? result.rawEnhancedLrc : result.rawVerbatimLrc
        case .enhancedLrc: return result.rawEnhancedLrc
        case .ttml: return result.rawTtml
        }
    }

    private static func toDocumentLine(_ line: LyricsLine) -> LyricsDocumentLine {
        var attrs = OrderedMap<QualifiedName, String>()
        for (name, value) in line.extensions { attrs[toQualifiedName(name)] = value }
        return LyricsDocumentLine(
            startMs: line.start, endMs: line.end, text: line.words.map(\.text).joined(),
            words: line.words.map { word in
                LyricsDocumentWord(startMs: word.start, endMs: word.end, text: word.text,
                                   ruby: word.ruby.map { LyricsDocumentRubySyllable(startMs: $0.start, endMs: $0.end, text: $0.text) })
            },
            agentId: line.extensions["ttm:agent"],
            extensions: ExtensionMap(attributes: attrs)
        )
    }

    private static func toQualifiedName(_ s: String) -> QualifiedName {
        let p = s.ktSubstringBefore(":", missing: "")
        let prefix: String? = p.isEmpty ? nil : p
        let localName = prefix == nil ? s : s.ktSubstringAfter(":")
        let namespace: String?
        switch prefix {
        case "ttm": namespace = NS_TTM
        case "itunes": namespace = NS_ITUNES_INTERNAL
        case "xml": namespace = NS_XML
        default: namespace = nil
        }
        return QualifiedName(namespaceUri: namespace, localName: localName, prefix: prefix)
    }

    private static func toExtensionElement(_ element: LyricsMetadataElement) -> ExtensionElement {
        var name = toQualifiedName(element.name)
        if let ns = element.namespace, ns.ktIsNotBlank { name.namespaceUri = ns }
        var attrs = OrderedMap<QualifiedName, String>()
        for (k, v) in element.attributes { attrs[toQualifiedName(k)] = v }
        return ExtensionElement(name: name, attributes: attrs, text: element.text, children: element.children.map(toExtensionElement))
    }

    private static func toLyricsMetadataElement(_ element: ExtensionElement) -> LyricsMetadataElement {
        func display(_ q: QualifiedName) -> String {
            if let p = q.prefix, p.ktIsNotBlank { return p + ":" + q.localName }
            return q.localName
        }
        var attrs = StringMap()
        for (k, v) in element.attributes { attrs[display(k)] = v }
        return LyricsMetadataElement(name: display(element.name), namespace: element.name.namespaceUri, attributes: attrs,
                                     text: element.text, children: element.children.map(toLyricsMetadataElement))
    }

    private static func toLyricsLine(_ line: LyricsDocumentLine, fallback: LyricsDocumentLine? = nil) -> LyricsLine? {
        guard let start = line.startMs ?? fallback?.startMs else { return nil }
        let end = line.endMs ?? line.words.last?.endMs ?? fallback?.endMs ?? fallback?.words.last?.endMs ?? start
        let lineText = line.visibleText
        var converted: [LyricsWord] = []
        var pendingUntimed = ""
        for word in line.words {
            guard let wordStart = word.startMs else {
                if !converted.isEmpty {
                    converted[converted.count - 1].text += word.text
                } else {
                    pendingUntimed += word.text
                }
                continue
            }
            let wordEnd = word.endMs ?? fallback?.endMs ?? end
            converted.append(LyricsWord(start: wordStart, end: wordEnd, text: pendingUntimed + word.text,
                                        ruby: word.ruby.map { LyricsRubySyllable(start: $0.startMs, end: $0.endMs, text: $0.text) }))
            pendingUntimed = ""
        }
        if !pendingUntimed.isEmpty && !converted.isEmpty {
            converted[converted.count - 1].text += pendingUntimed
        }
        let resultWords: [LyricsWord]
        if !converted.isEmpty {
            resultWords = converted
        } else if lineText.ktIsBlank {
            resultWords = []
        } else {
            resultWords = [LyricsWord(start: start, end: end, text: lineText)]
        }
        if resultWords.isEmpty { return nil }
        var extensions = StringMap()
        if let agent = line.agentId { extensions["ttm:agent"] = agent }
        let pairs = line.extensions.attributes.pairs
        if let sp = pairs.first(where: { $0.0.localName == "song-part" || $0.0.localName == "songPart" }) { extensions["itunes:song-part"] = sp.1 }
        if let b = pairs.first(where: { $0.0.localName == "divBegin" }) { extensions["divBegin"] = b.1 }
        if let e = pairs.first(where: { $0.0.localName == "divEnd" }) { extensions["divEnd"] = e.1 }
        return LyricsLine(start: start, end: end, words: resultWords, extensions: extensions)
    }

    private static func ttmlAgentType(_ type: LyricsAgentType) -> String? {
        switch type {
        case .person, .narrator: return "person"
        case .group: return "group"
        case .character: return "character"
        case .organization: return "organization"
        case .other: return "other"
        case .unknown: return nil
        }
    }

    private static let visibleWhitespace = KRegex("[ \\t\\u00A0]+")
    static func normalizeVisibleWhitespace(_ text: String) -> String { visibleWhitespace.replace(text, with: " ") }

    // MARK: Post processors

    static func transformText(_ document: LyricsDocument, _ transform: (String) -> String) -> LyricsDocument {
        var d = document
        d.metadata.title = document.metadata.title.map(transform)
        d.metadata.artist = document.metadata.artist.map(transform)
        d.metadata.album = document.metadata.album.map(transform)
        var extra = StringMap()
        for (k, v) in document.metadata.extra { extra[k] = transform(v) }
        d.metadata.extra = extra
        d.tracks = document.tracks.map { track in
            var t = track
            t.lines = track.lines.map { line in
                var l = line
                l.text = transform(line.text)
                l.words = line.words.map { word in
                    var w = word
                    w.text = transform(word.text)
                    w.ruby = word.ruby.map { var s = $0; s.text = transform($0.text); return s }
                    return w
                }
                return l
            }
            return t
        }
        return d
    }

    private static let placeholderPattern = KRegex("^[\(jWhitespaceClass)/\\\\|｜·・.。…_-]*$")

    static func isBlankOrPlaceholder(_ line: LyricsDocumentLine) -> Bool {
        let visible = line.visibleText.ktTrim()
        return visible.isEmpty || placeholderPattern.matches(visible)
    }

    private static func isLinkedToOriginal(_ type: LyricsTrackType) -> Bool {
        type == .translation || type == .romanization || type == .background
    }

    private static func removeLines(_ document: LyricsDocument, where shouldRemove: (LyricsDocumentLine) -> Bool) -> [LyricsTrack] {
        var removedKeys = Set<String>()
        var removedStarts = Set<Int64>()
        let first = document.tracks.map { track -> LyricsTrack in
            var t = track
            t.lines = track.lines.filter { line in
                let remove = shouldRemove(line)
                if remove && track.type == .original {
                    if let k = line.linkKey { removedKeys.insert(k) }
                    if let s = line.startMs { removedStarts.insert(s) }
                }
                return !remove
            }
            return t
        }
        return first.map { track in
            guard isLinkedToOriginal(track.type) else { return track }
            var t = track
            t.lines = track.lines.filter { line in
                !((line.linkKey.map { removedKeys.contains($0) } ?? false) || (line.startMs.map { removedStarts.contains($0) } ?? false))
            }
            return t
        }
    }

    static func removeEmptyLines(_ document: LyricsDocument) -> LyricsDocument {
        var d = document
        d.tracks = removeLines(document, where: isBlankOrPlaceholder)
        return d
    }

    static func removeTagLines(_ document: LyricsDocument, _ keywords: [String]) -> LyricsDocument {
        var d = document
        d.tracks = removeLines(document) { line in keywords.contains { line.visibleText.ktContainsIgnoreCase($0) } }
        func shouldRemove(_ key: String, _ value: String?) -> Bool {
            let tagText = "[" + key + ":" + (value ?? "") + "]"
            return keywords.contains { tagText.ktContainsIgnoreCase($0) }
        }
        let m = document.metadata
        d.metadata.title = shouldRemove("ti", m.title) ? nil : m.title
        d.metadata.artist = shouldRemove("ar", m.artist) ? nil : m.artist
        d.metadata.album = shouldRemove("al", m.album) ? nil : m.album
        d.metadata.offsetMs = shouldRemove("offset", m.offsetMs.map { String($0) }) ? nil : m.offsetMs
        var extra = StringMap()
        for (k, v) in m.extra where !shouldRemove(k, v) { extra[k] = v }
        d.metadata.extra = extra
        return d
    }

    static func onlyTranslation(_ document: LyricsDocument) -> LyricsDocument {
        guard let original = document.tracks.first(where: { $0.type == .original }),
              let translation = document.tracks.first(where: { $0.type == .translation }) else { return document }
        var byKey: [String: LyricsDocumentLine] = [:]
        var byStart: [Int64: LyricsDocumentLine] = [:]
        for line in translation.lines {
            if let k = line.linkKey { byKey[k] = line }
            if let s = line.startMs { byStart[s] = line }
        }
        var merged = original
        merged.lines = original.lines.map { line in
            let translated = line.linkKey.flatMap { byKey[$0] } ?? line.startMs.flatMap { byStart[$0] }
            if let translated, translated.text.ktIsNotBlank {
                var l = line
                l.text = translated.text
                l.words = []
                return l
            }
            return line
        }
        var d = document
        d.tracks = [merged] + document.tracks.filter { ![.original, .translation, .romanization, .background].contains($0.type) }
        return d
    }

    static func applyOffset(_ document: LyricsDocument, _ offset: Int64) -> LyricsDocument {
        func shift(_ v: Int64?) -> Int64? { v.map { max($0 + offset, 0) } }
        var d = document
        d.tracks = document.tracks.map { track in
            var t = track
            t.lines = track.lines.map { line in
                var l = line
                l.startMs = shift(line.startMs)
                l.endMs = shift(line.endMs)
                l.words = line.words.map { word in
                    var w = word
                    w.startMs = shift(word.startMs)
                    w.endMs = shift(word.endMs)
                    w.ruby = word.ruby.map { var s = $0; s.startMs = shift($0.startMs); s.endMs = shift($0.endMs); return s }
                    return w
                }
                return l
            }
            return t
        }
        return d
    }
}
