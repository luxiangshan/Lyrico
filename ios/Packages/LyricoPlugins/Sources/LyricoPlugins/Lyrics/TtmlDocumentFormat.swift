import Foundation

let NS_TTML = "http://www.w3.org/ns/ttml"
let NS_TTM = "http://www.w3.org/ns/ttml#metadata"
let NS_ITUNES_INTERNAL = "http://music.apple.com/lyric-ttml-internal"
let NS_ITUNES_LEGACY = "http://music.apple.com/itunes/ttml"
let NS_XML = "http://www.w3.org/XML/1998/namespace"
let NS_XMLNS = "http://www.w3.org/2000/xmlns/"
let NS_TTS = "http://www.w3.org/ns/ttml#styling"
private let ROLE_ROMAN = "x-roman"
private let ROLE_ROMAN_LEGACY = "x-romanization"
private let SONG_PART = "song-part"
private let SONG_PART_LEGACY = "songPart"
private let SAFE_XML_NAME = KRegex("[A-Za-z_][A-Za-z0-9_.:-]*")
private let TTML_WRITER_MANAGED_LOCAL_NAMES: Set<String> = ["begin", "end", "id", "role", "agent", "key", SONG_PART, SONG_PART_LEGACY, "divBegin", "divEnd"]
private let ttmlWhitespaceRun = KRegex("[\(jWhitespaceClass)]+")

public struct TtmlParseError: Error, CustomStringConvertible {
    public let description: String
}

/// Port of `TtmlParser`.
enum TtmlParser {
    static func parse(_ raw: String) throws -> LyricsDocument {
        guard !raw.ktContainsIgnoreCase("<!DOCTYPE") else {
            throw TtmlParseError(description: "TTML documents containing DOCTYPE are not supported")
        }
        let root = try NamespaceDOM.parse(raw)
        let body = elementsByLocalName(root, "body").first
        let (headMetadataElements, itunesMetadataElements) = parseHeadExtensionElements(root)
        let metadataTranslationTracks = parseMetadataTranslations(root)
        let metadataTransliterationTracks = parseMetadataTransliterations(root)
        var originalLines: [LyricsDocumentLine] = []
        var inlineTranslationLines: [LyricsDocumentLine] = []
        var romanizationLines: [LyricsDocumentLine] = []
        var backgroundLines: [LyricsDocumentLine] = []

        for p in elementsByLocalName(root, "p") {
            let start = attr(p, "begin").map(parseTtmlTimeMs)
            let end = attr(p, "end").map(parseTtmlTimeMs)
            if start == nil && end == nil { continue }
            let role = attr(p, "role", NS_TTM)
            let linkKey = attr(p, "key", NS_ITUNES_INTERNAL) ?? attr(p, "key", NS_ITUNES_LEGACY) ?? attr(p, "key")
            let agentId = attr(p, "agent", NS_TTM) ?? attr(p, "agent")
            let songPart = ancestorDivSongPart(p)
            let divTiming = firstPInAncestorDiv(p)
            let parsed = parsePText(p, start ?? 0, end ?? start ?? 0)
            let line = LyricsDocumentLine(
                startMs: start, endMs: end, text: parsed.originalText, words: parsed.words,
                linkKey: linkKey, agentId: agentId,
                extensions: withDivTiming(withSongPart(attributesAsExtensions(p), songPart), divTiming)
            )
            switch role {
            case "x-translation": var l = line; l.text = parsed.originalText; inlineTranslationLines.append(l)
            case ROLE_ROMAN, ROLE_ROMAN_LEGACY: var l = line; l.text = parsed.originalText; romanizationLines.append(l)
            case "x-bg": var l = line; l.text = parsed.originalText; backgroundLines.append(l)
            default:
                originalLines.append(line)
                if parsed.translationText.ktIsNotBlank {
                    inlineTranslationLines.append(LyricsDocumentLine(startMs: start, endMs: end, text: parsed.translationText, linkKey: linkKey))
                }
                if parsed.romanizationText.ktIsNotBlank {
                    romanizationLines.append(LyricsDocumentLine(startMs: start, endMs: end, text: parsed.romanizationText, linkKey: linkKey))
                }
                backgroundLines.append(contentsOf: parsed.backgroundLines.map { bg in
                    var b = bg
                    b.startMs = bg.startMs ?? start
                    b.endMs = bg.endMs ?? end
                    b.linkKey = bg.linkKey ?? linkKey
                    return b
                })
            }
        }

        var tracks = [LyricsTrack(type: .original, lines: originalLines)]
        tracks.append(contentsOf: metadataTranslationTracks)
        if !inlineTranslationLines.isEmpty && metadataTranslationTracks.isEmpty {
            tracks.append(LyricsTrack(type: .translation, lines: inlineTranslationLines))
        }
        tracks.append(contentsOf: metadataTransliterationTracks)
        if !romanizationLines.isEmpty && metadataTransliterationTracks.isEmpty {
            tracks.append(LyricsTrack(type: .romanization, lines: romanizationLines))
        }
        if !backgroundLines.isEmpty {
            tracks.append(LyricsTrack(type: .background, lines: backgroundLines))
        }

        return LyricsDocument(
            metadata: LyricsMetadata(
                language: attr(root, "lang", NS_XML),
                timing: attr(root, "timing", NS_ITUNES_INTERNAL) ?? attr(root, "timing", NS_ITUNES_LEGACY) ?? attr(root, "timing")
            ),
            agents: parseAgents(root),
            tracks: tracks,
            extensions: attributesAsExtensions(root),
            bodyExtensions: body.map(attributesAsExtensions) ?? ExtensionMap(),
            headMetadataElements: headMetadataElements,
            itunesMetadataElements: itunesMetadataElements,
            sourceFormat: .ttml
        )
    }

    private static func parseHeadExtensionElements(_ root: DOMNode) -> ([ExtensionElement], [ExtensionElement]) {
        var regular: [ExtensionElement] = []
        var itunes: [ExtensionElement] = []
        guard let head = childElementsByLocalName(root, "head").first else { return (regular, itunes) }
        for metadata in childElementsByLocalName(head, "metadata") {
            for element in metadata.childElements {
                if element.localName == "iTunesMetadata" {
                    for child in element.childElements where child.localName != "translations" && child.localName != "transliterations" {
                        itunes.append(toExtensionElement(child))
                    }
                } else if element.localName != "agent" {
                    regular.append(toExtensionElement(element))
                }
            }
        }
        return (regular, itunes)
    }

    private static func parseAgents(_ root: DOMNode) -> [LyricsAgent] {
        elementsByLocalName(root, "agent").compactMap { element in
            guard let id = attr(element, "id", NS_XML) ?? attr(element, "id") else { return nil }
            let rawType = attr(element, "type")
            let type: LyricsAgentType
            switch rawType?.lowercased() {
            case "person": type = .person
            case "group": type = .group
            case "character": type = .character
            case "organization": type = .organization
            case "other": type = .other
            case "narrator": type = .narrator
            default: type = .unknown
            }
            let nameFromChild = childElementsByLocalName(element, "name").first.map { $0.textContent.ktTrim() }.flatMap { $0.ktIsNotBlank ? $0 : nil }
            let direct = directTextContent(element).ktTrim()
            return LyricsAgent(id: id, type: type, name: nameFromChild ?? (direct.ktIsNotBlank ? direct : nil),
                               rawType: rawType, extensions: attributesAsExtensions(element))
        }
    }

    private static func parseMetadataTranslations(_ root: DOMNode) -> [LyricsTrack] {
        elementsByLocalName(root, "translation").compactMap { translation in
            let lines: [LyricsDocumentLine] = childElementsByLocalName(translation, "text").compactMap { text in
                guard let key = attr(text, "for") else { return nil }
                return LyricsDocumentLine(text: normalizeTtmlText(text.textContent, trimEdges: true), linkKey: key,
                                          extensions: attributesAsExtensions(text))
            }
            if lines.isEmpty { return nil }
            return LyricsTrack(type: .translation, language: attr(translation, "lang", NS_XML), lines: lines,
                               extensions: attributesAsExtensions(translation))
        }
    }

    private static func parseMetadataTransliterations(_ root: DOMNode) -> [LyricsTrack] {
        elementsByLocalName(root, "transliteration").compactMap { transliteration in
            let lines: [LyricsDocumentLine] = childElementsByLocalName(transliteration, "text").compactMap { text in
                guard let key = attr(text, "for") else { return nil }
                return parseSidecarTextLine(text, key)
            }
            if lines.isEmpty { return nil }
            return LyricsTrack(type: .romanization, language: attr(transliteration, "lang", NS_XML), lines: lines,
                               extensions: attributesAsExtensions(transliteration))
        }
    }

    private static func parseSidecarTextLine(_ text: DOMNode, _ key: String) -> LyricsDocumentLine? {
        let words = parseSidecarTimedWords(text)
        if !words.isEmpty {
            return LyricsDocumentLine(text: words.map(\.text).joined(), words: words, linkKey: key, extensions: attributesAsExtensions(text))
        }
        let whole = normalizeTtmlText(text.textContent, trimEdges: true)
        if whole.ktIsBlank { return nil }
        return LyricsDocumentLine(text: whole, linkKey: key, extensions: attributesAsExtensions(text))
    }

    private static func parseSidecarTimedWords(_ element: DOMNode) -> [LyricsDocumentWord] {
        var words: [LyricsDocumentWord] = []
        func visit(_ node: DOMNode) {
            guard node.isElement else { return }
            let role = attr(node, "role", NS_TTM)
            let start = attr(node, "begin").map(parseTtmlTimeMs)
            if let start, role != "x-bg", role != "x-translation", !isRomanizationRole(role) {
                let value = normalizeTtmlText(node.textContent, trimEdges: false)
                if value.ktIsNotBlank {
                    words.append(LyricsDocumentWord(startMs: start, endMs: attr(node, "end").map(parseTtmlTimeMs), text: value,
                                                    extensions: attributesAsExtensions(node)))
                }
            } else {
                node.children.forEach(visit)
            }
        }
        element.children.forEach(visit)
        return words
    }

    private struct ParsedPText {
        let originalText: String
        let translationText: String
        let romanizationText: String
        let backgroundLines: [LyricsDocumentLine]
        let words: [LyricsDocumentWord]
    }

    private static func parsePText(_ p: DOMNode, _ fallbackStart: Int64, _ fallbackEnd: Int64) -> ParsedPText {
        var words: [LyricsDocumentWord] = []
        var original = ""
        var translation = ""
        var romanization = ""
        var background: [LyricsDocumentLine] = []

        func appendVisibleText(_ node: DOMNode, _ target: inout String) {
            switch node.kind {
            case .text, .cdata: target += normalizeTtmlText(node.value)
            case .element: node.children.forEach { appendVisibleText($0, &target) }
            case .comment: break
            }
        }

        func appendOriginalText(_ text: String) {
            let normalized = normalizeTtmlText(text)
            let isFormattingWhitespace = normalized.ktIsBlank && (text.hasScalar("\n") || text.hasScalar("\r"))
            if normalized.isEmpty || isFormattingWhitespace { return }
            if !words.isEmpty {
                words.append(LyricsDocumentWord(text: normalized))
            } else {
                original += normalized
            }
        }

        for child in p.children {
            switch child.kind {
            case .text, .cdata:
                appendOriginalText(child.value)
            case .element:
                let element = child
                let role = attr(element, "role", NS_TTM)
                var text = ""
                appendVisibleText(element, &text)
                if let rubyWord = parseRubyWord(element, fallbackStart, fallbackEnd) {
                    words.append(rubyWord)
                } else if role == "x-translation" {
                    translation += normalizeTtmlText(text, trimEdges: true)
                } else if isRomanizationRole(role) {
                    romanization += normalizeTtmlText(text, trimEdges: true)
                } else if role == "x-bg" {
                    background.append(LyricsDocumentLine(
                        startMs: fallbackStart, endMs: fallbackEnd,
                        text: normalizeTtmlText(text, trimEdges: false),
                        words: parseContentWords(element, fallbackStart, fallbackEnd),
                        extensions: attributesAsExtensions(element)
                    ))
                } else {
                    let start = attr(element, "begin").map(parseTtmlTimeMs)
                    let end = attr(element, "end").map(parseTtmlTimeMs)
                    let parsedWords = parseContentWords(element, start ?? fallbackStart, fallbackEnd)
                    if let start {
                        let normalized = normalizeTtmlText(text, trimEdges: false)
                        let isFormattingWhitespace = normalized.ktIsBlank && (text.hasScalar("\n") || text.hasScalar("\r"))
                        if !normalized.isEmpty && !isFormattingWhitespace {
                            words.append(LyricsDocumentWord(startMs: start, endMs: end ?? fallbackEnd, text: normalized,
                                                            extensions: attributesAsExtensions(element)))
                        }
                    } else if parsedWords.contains(where: { $0.startMs != nil }) {
                        words.append(contentsOf: parsedWords)
                    } else {
                        appendOriginalText(text)
                    }
                }
            case .comment:
                break
            }
        }

        let finalOriginal = !words.isEmpty ? words.map(\.text).joined() : normalizeTtmlText(original, trimEdges: true)
        let finalWords: [LyricsDocumentWord]
        if !words.isEmpty {
            finalWords = words
        } else if finalOriginal.ktIsBlank {
            finalWords = []
        } else {
            finalWords = [LyricsDocumentWord(startMs: fallbackStart, endMs: fallbackEnd, text: finalOriginal)]
        }
        return ParsedPText(
            originalText: finalOriginal,
            translationText: normalizeTtmlText(translation, trimEdges: true),
            romanizationText: normalizeTtmlText(romanization, trimEdges: true),
            backgroundLines: background,
            words: finalWords
        )
    }

    private static func parseContentWords(_ element: DOMNode, _ fallbackStart: Int64, _ fallbackEnd: Int64) -> [LyricsDocumentWord] {
        var words: [LyricsDocumentWord] = []
        func visit(_ node: DOMNode) {
            switch node.kind {
            case .text, .cdata:
                let rawText = node.value
                let text = normalizeTtmlText(rawText, trimEdges: false)
                let isFormattingWhitespace = text.ktIsBlank && (rawText.hasScalar("\n") || rawText.hasScalar("\r"))
                if !text.isEmpty && !isFormattingWhitespace { words.append(LyricsDocumentWord(text: text)) }
            case .element:
                if let rubyWord = parseRubyWord(node, fallbackStart, fallbackEnd) {
                    words.append(rubyWord)
                    return
                }
                let start = attr(node, "begin").map(parseTtmlTimeMs)
                let end = attr(node, "end").map(parseTtmlTimeMs)
                if let start {
                    let rawText = node.textContent
                    let text = normalizeTtmlText(rawText, trimEdges: false)
                    let isFormattingWhitespace = text.ktIsBlank && (rawText.hasScalar("\n") || rawText.hasScalar("\r"))
                    if !text.isEmpty && !isFormattingWhitespace {
                        words.append(LyricsDocumentWord(startMs: start, endMs: end ?? fallbackEnd, text: text, extensions: attributesAsExtensions(node)))
                    }
                } else {
                    node.children.forEach(visit)
                }
            case .comment:
                break
            }
        }
        element.children.forEach(visit)
        return words
    }

    private static func parseRubyWord(_ element: DOMNode, _ fallbackStart: Int64, _ fallbackEnd: Int64) -> LyricsDocumentWord? {
        guard attr(element, "ruby", NS_TTS) == "container" else { return nil }
        let directSpans = element.childElements.filter { $0.localName == "span" }
        let descendantSpans = elementsByLocalName(element, "span")
        guard let base = directSpans.first(where: { attr($0, "ruby", NS_TTS) == "base" })
                ?? descendantSpans.first(where: { attr($0, "ruby", NS_TTS) == "base" }) else { return nil }
        let baseText = normalizeTtmlText(base.textContent, trimEdges: false)
        if baseText.isEmpty { return nil }
        let textContainer = directSpans.first { attr($0, "ruby", NS_TTS) == "textContainer" }
        let directAnnotations = textContainer?.childElements.filter { $0.localName == "span" && attr($0, "ruby", NS_TTS) == "text" }
        let annotations = (directAnnotations?.isEmpty == false ? directAnnotations! : descendantSpans.filter { attr($0, "ruby", NS_TTS) == "text" })
        let ruby: [LyricsDocumentRubySyllable] = annotations.compactMap { annotation in
            let text = normalizeTtmlText(annotation.textContent, trimEdges: false)
            if text.isEmpty { return nil }
            return LyricsDocumentRubySyllable(startMs: attr(annotation, "begin").map(parseTtmlTimeMs),
                                              endMs: attr(annotation, "end").map(parseTtmlTimeMs), text: text)
        }
        if ruby.isEmpty { return nil }
        let start = ruby.compactMap(\.startMs).min()
            ?? attr(element, "begin").map(parseTtmlTimeMs)
            ?? attr(base, "begin").map(parseTtmlTimeMs)
            ?? fallbackStart
        let end = ruby.compactMap(\.endMs).max()
            ?? attr(element, "end").map(parseTtmlTimeMs)
            ?? attr(base, "end").map(parseTtmlTimeMs)
            ?? fallbackEnd
        return LyricsDocumentWord(startMs: start, endMs: end, text: baseText, ruby: ruby, extensions: attributesAsExtensions(element))
    }
}

/// Port of `TtmlWriter`.
enum TtmlWriter {
    static func write(_ document: LyricsDocument, lineOrder: [LyricLineTrack] = defaultLyricLineOrder) -> String {
        var builder = ""
        builder += "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
        builder += "<tt xmlns=\"" + NS_TTML + "\""
        builder += " xmlns:ttm=\"" + NS_TTM + "\""
        builder += " xmlns:itunes=\"" + NS_ITUNES_INTERNAL + "\""
        for (prefix, uri) in collectDocumentNamespaces(document) where prefix != "ttm" && prefix != "itunes" && prefix != "xml" {
            builder += " xmlns:" + prefix + "=\"" + escapeXml(uri) + "\""
        }
        if let lang = document.metadata.language { builder += " xml:lang=\"" + escapeXml(lang) + "\"" }
        if let timing = document.metadata.timing { builder += " itunes:timing=\"" + escapeXml(timing) + "\"" }
        appendUnmanagedAttributes(&builder, document.extensions, ["lang", "timing"])
        builder += ">\n"

        let originalLines = document.tracks.first { $0.type == .original }?.lines ?? []
        var nextLineKey = 1
        let originalLineKeys: [String?] = originalLines.map { line in
            if line.startMs == nil { return nil }
            defer { nextLineKey += 1 }
            return "L\(nextLineKey)"
        }

        appendHead(&builder, document, originalLines, originalLineKeys)
        builder += "  <body"
        appendUnmanagedAttributes(&builder, withValidBodyDuration(document.bodyExtensions), [])
        builder += ">\n"

        var currentSongPart: String?
        var divOpen = false
        let backgroundByKey = linesByKey(document, .background)
        let backgroundByStart = linesByStart(document, .background)
        let inlineTranslationTrack = document.sourceFormat == nil ? document.tracks.first { $0.type == .translation } : nil
        var inlineTranslationsByStart: [Int64: LyricsDocumentLine] = [:]
        for line in inlineTranslationTrack?.lines ?? [] { if let s = line.startMs { inlineTranslationsByStart[s] = line } }

        for (index, line) in originalLines.enumerated() {
            let backgroundLines = line.linkKey.flatMap { backgroundByKey[$0] }
                ?? line.startMs.flatMap { backgroundByStart[$0] }
                ?? []
            let songPart = songPartExtensionValue(line)
            let divBegin = divTimingExtensionValue(line, "divBegin")
            let divEnd = divTimingExtensionValue(line, "divEnd")
            if !divOpen || songPart != currentSongPart || divBegin != nil {
                if divOpen { builder += "    </div>\n" }
                builder += "    <div"
                if let songPart { builder += " itunes:song-part=\"" + escapeXml(songPart) + "\"" }
                if let divBegin { builder += " begin=\"" + LyricFormatter.formatTtmlTimestamp(divBegin) + "\"" }
                if let divEnd { builder += " end=\"" + LyricFormatter.formatTtmlTimestamp(divEnd) + "\"" }
                builder += ">\n"
                currentSongPart = songPart
                divOpen = true
            }
            appendOriginalLine(&builder, line, originalLineKeys[index], backgroundLines,
                               line.startMs.flatMap { inlineTranslationsByStart[$0] }, inlineTranslationTrack?.language)
        }
        if divOpen { builder += "    </div>\n" }
        builder += "  </body>\n"
        builder += "</tt>"
        return builder
    }

    private static func appendHead(_ builder: inout String, _ document: LyricsDocument, _ originalLines: [LyricsDocumentLine], _ originalLineKeys: [String?]) {
        let translations = document.sourceFormat == nil ? [] : document.tracks.filter { $0.type == .translation }
        let transliterations = document.tracks.filter { $0.type == .romanization }
        if document.agents.isEmpty && translations.isEmpty && transliterations.isEmpty &&
            document.headMetadataElements.isEmpty && document.itunesMetadataElements.isEmpty { return }

        builder += "  <head>\n"
        if !document.agents.isEmpty {
            builder += "    <metadata>\n"
            for agent in document.agents {
                builder += "      <ttm:agent xml:id=\"" + escapeXml(agent.id) + "\""
                if let type = agent.rawType ?? toTtmlType(agent.type) { builder += " type=\"" + escapeXml(type) + "\"" }
                if let name = agent.name, name.ktIsNotBlank {
                    builder += ">\n"
                    builder += "        <ttm:name type=\"full\">" + escapeXml(name) + "</ttm:name>\n"
                    builder += "      </ttm:agent>\n"
                } else {
                    builder += "/>\n"
                }
            }
            builder += "    </metadata>\n"
        }
        if !document.headMetadataElements.isEmpty {
            builder += "    <metadata>\n"
            for element in document.headMetadataElements { appendExtensionElement(&builder, element, "      ") }
            builder += "    </metadata>\n"
        }
        if !translations.isEmpty || !transliterations.isEmpty || !document.itunesMetadataElements.isEmpty {
            builder += "    <metadata>\n"
            builder += "      <iTunesMetadata xmlns=\"" + NS_ITUNES_INTERNAL + "\">\n"
            if !translations.isEmpty {
                builder += "        <translations>\n"
                for track in translations {
                    builder += "          <translation"
                    let rawType = track.extensions.attributes.pairs.first { $0.0.localName == "type" }?.1
                    let translationType = (rawType?.ktIsNotBlank == true) ? rawType! : "subtitle"
                    builder += " type=\"" + escapeXml(translationType) + "\""
                    if let lang = track.language { builder += " xml:lang=\"" + escapeXml(lang) + "\"" }
                    builder += ">\n"
                    for line in track.lines {
                        guard let key = originalKeyForLinkedLine(line, originalLines, originalLineKeys) else { continue }
                        builder += "            <text for=\"" + escapeXml(key) + "\">" + escapeXml(line.visibleText) + "</text>\n"
                    }
                    builder += "          </translation>\n"
                }
                builder += "        </translations>\n"
            }
            if !transliterations.isEmpty {
                builder += "        <transliterations>\n"
                for track in transliterations {
                    builder += "          <transliteration"
                    if let lang = track.language { builder += " xml:lang=\"" + escapeXml(lang) + "\"" }
                    builder += ">\n"
                    for line in track.lines {
                        guard let key = originalKeyForLinkedLine(line, originalLines, originalLineKeys) else { continue }
                        builder += "            <text for=\"" + escapeXml(key) + "\">"
                        appendSidecarRomanText(&builder, line)
                        builder += "</text>\n"
                    }
                    builder += "          </transliteration>\n"
                }
                builder += "        </transliterations>\n"
            }
            for element in document.itunesMetadataElements {
                appendExtensionElement(&builder, element, "        ", defaultNamespace: NS_ITUNES_INTERNAL)
            }
            builder += "      </iTunesMetadata>\n"
            builder += "    </metadata>\n"
        }
        builder += "  </head>\n"
    }

    private static func appendSidecarRomanText(_ builder: inout String, _ line: LyricsDocumentLine) {
        let timed = line.words.filter { $0.startMs != nil }
        if !timed.isEmpty {
            for (index, word) in line.words.enumerated() {
                if index > 0 && needsRomanizationSeparator(line.words[index - 1].text, word.text) { builder += " " }
                if let start = word.startMs, let end = word.endMs {
                    builder += "<span xmlns=\"" + NS_TTML + "\" begin=\"" + LyricFormatter.formatTtmlTimestamp(start)
                        + "\" end=\"" + LyricFormatter.formatTtmlTimestamp(end) + "\">" + escapeXml(word.text) + "</span>"
                } else {
                    builder += escapeXml(word.text)
                }
            }
        } else {
            builder += escapeXml(line.visibleText)
        }
    }

    private static func appendOriginalLine(_ builder: inout String, _ line: LyricsDocumentLine, _ lineKey: String?,
                                           _ backgroundLines: [LyricsDocumentLine], _ inlineTranslation: LyricsDocumentLine?,
                                           _ inlineTranslationLanguage: String?) {
        guard let start = line.startMs else { return }
        let end = line.endMs ?? line.words.last?.endMs ?? (start + 2000)
        builder += "      <p begin=\"" + LyricFormatter.formatTtmlTimestamp(start) + "\" end=\"" + LyricFormatter.formatTtmlTimestamp(end) + "\""
        if let lineKey { builder += " itunes:key=\"" + escapeXml(lineKey) + "\"" }
        if let agent = line.agentId { builder += " ttm:agent=\"" + escapeXml(agent) + "\"" }
        for (qName, value) in line.extensions.attributes {
            if let outputName = ttmlOutputName(qName) {
                builder += " " + outputName + "=\"" + escapeXml(value) + "\""
            }
        }
        builder += ">"
        if line.words.count > 1 || line.words.contains(where: { !$0.ruby.isEmpty }) {
            for word in line.words { appendWord(&builder, word) }
        } else {
            builder += escapeXml(line.visibleText)
        }
        for backgroundLine in backgroundLines where backgroundLine.visibleText.ktIsNotBlank {
            builder += "<span ttm:role=\"x-bg\">"
            if !backgroundLine.words.isEmpty {
                for word in backgroundLine.words { appendWord(&builder, word) }
            } else {
                builder += escapeXml(backgroundLine.visibleText)
            }
            builder += "</span>"
        }
        if let translation = inlineTranslation?.visibleText, translation.ktIsNotBlank {
            builder += "<span ttm:role=\"x-translation\""
            if let lang = inlineTranslationLanguage, lang.ktIsNotBlank { builder += " xml:lang=\"" + escapeXml(lang) + "\"" }
            builder += ">" + escapeXml(translation) + "</span>"
        }
        builder += "</p>\n"
    }

    private static func appendWord(_ builder: inout String, _ word: LyricsDocumentWord) {
        if !word.ruby.isEmpty {
            builder += "<span tts:ruby=\"container\""
            appendUnmanagedAttributes(&builder, word.extensions, ["ruby", "begin", "end"])
            builder += ">" + "<span tts:ruby=\"base\">" + escapeXml(word.text) + "</span>" + "<span tts:ruby=\"textContainer\">"
            for syllable in resolveRubyTimings(word) {
                builder += "<span tts:ruby=\"text\""
                builder += " begin=\"" + LyricFormatter.formatTtmlTimestamp(syllable.startMs) + "\""
                builder += " end=\"" + LyricFormatter.formatTtmlTimestamp(syllable.endMs) + "\""
                builder += ">" + escapeXml(syllable.text) + "</span>"
            }
            builder += "</span></span>"
            return
        }
        if let start = word.startMs, let end = word.endMs {
            builder += "<span begin=\"" + LyricFormatter.formatTtmlTimestamp(start) + "\" end=\"" + LyricFormatter.formatTtmlTimestamp(end) + "\""
            appendUnmanagedAttributes(&builder, word.extensions, ["begin", "end"])
            builder += ">" + escapeXml(word.text) + "</span>"
        } else {
            builder += escapeXml(word.text)
        }
    }

    struct ResolvedRubySyllable { let startMs: Int64; let endMs: Int64; let text: String }

    static func resolveRubyTimings(_ word: LyricsDocumentWord) -> [ResolvedRubySyllable] {
        if word.ruby.isEmpty { return [] }
        var starts = word.ruby.map(\.startMs)
        var ends = word.ruby.map(\.endMs)
        let fallbackStart = word.startMs ?? starts.compactMap { $0 }.first ?? ends.compactMap { $0 }.first ?? 0
        let fallbackEnd = word.endMs ?? ends.reversed().compactMap { $0 }.first ?? starts.reversed().compactMap { $0 }.first ?? fallbackStart
        let lastIndex = word.ruby.count - 1
        if starts[0] == nil { starts[0] = fallbackStart }
        if ends[lastIndex] == nil { ends[lastIndex] = fallbackEnd }
        for _ in 0..<word.ruby.count {
            for index in 0..<lastIndex {
                if ends[index] != nil && starts[index + 1] == nil { starts[index + 1] = ends[index] }
                if ends[index] == nil && starts[index + 1] != nil { ends[index] = starts[index + 1] }
            }
        }
        var index = 0
        while index < word.ruby.count {
            guard let rangeStart = starts[index], ends[index] == nil else { index += 1; continue }
            var rangeEndIndex = index
            while rangeEndIndex < lastIndex && ends[rangeEndIndex] == nil { rangeEndIndex += 1 }
            let rangeEnd = max(ends[rangeEndIndex] ?? fallbackEnd, rangeStart)
            let count = rangeEndIndex - index + 1
            for syllableIndex in index...rangeEndIndex {
                let position = syllableIndex - index
                if starts[syllableIndex] == nil { starts[syllableIndex] = interpolate(rangeStart, rangeEnd, position, count) }
                if ends[syllableIndex] == nil { ends[syllableIndex] = interpolate(rangeStart, rangeEnd, position + 1, count) }
            }
            index = rangeEndIndex + 1
        }
        var previousEnd = fallbackStart
        return word.ruby.enumerated().map { i, syllable in
            let start = starts[i] ?? previousEnd
            let end = ends[i] ?? max(fallbackEnd, start)
            previousEnd = end
            return ResolvedRubySyllable(startMs: start, endMs: end, text: syllable.text)
        }
    }

    private static func interpolate(_ start: Int64, _ end: Int64, _ position: Int, _ count: Int) -> Int64 {
        if start == end { return start }
        return start + Int64(clampingDouble: Double(end - start) * Double(position) / Double(count))
    }

    private static func originalKeyForLinkedLine(_ line: LyricsDocumentLine, _ originalLines: [LyricsDocumentLine], _ keys: [String?]) -> String? {
        if let linkKey = line.linkKey, let index = originalLines.firstIndex(where: { $0.linkKey == linkKey }) { return keys[index] }
        if let start = line.startMs, let index = originalLines.firstIndex(where: { $0.startMs == start }) { return keys[index] }
        return nil
    }

    private static func toTtmlType(_ type: LyricsAgentType) -> String? {
        switch type {
        case .person: return "person"
        case .group: return "group"
        case .character: return "character"
        case .organization: return "organization"
        case .other: return "other"
        case .narrator: return "person"
        case .unknown: return nil
        }
    }
}

// MARK: - Shared helpers (file-private in Kotlin)

private func linesByKey(_ document: LyricsDocument, _ type: LyricsTrackType) -> [String: [LyricsDocumentLine]] {
    let lines = document.tracks.first { $0.type == type }?.lines ?? []
    var map: [String: [LyricsDocumentLine]] = [:]
    for line in lines {
        let key = line.linkKey ?? ""
        if key.ktIsBlank { continue }
        map[key, default: []].append(line)
    }
    return map
}

private func linesByStart(_ document: LyricsDocument, _ type: LyricsTrackType) -> [Int64: [LyricsDocumentLine]] {
    let lines = document.tracks.first { $0.type == type }?.lines ?? []
    var map: [Int64: [LyricsDocumentLine]] = [:]
    for line in lines { if let s = line.startMs { map[s, default: []].append(line) } }
    return map
}

/// `Element.attr(localName, namespace)`.
private func attr(_ element: DOMNode, _ localName: String, _ namespace: String? = nil) -> String? {
    if let namespace {
        let v = element.getAttributeNS(namespace, localName)
        if v.ktIsNotBlank { return v }
    }
    let v = element.getAttribute(localName)
    if v.ktIsNotBlank { return v }
    for a in element.attributes where a.localName == localName || a.nodeName.hasSuffix(":" + localName) {
        return a.value
    }
    return nil
}

private func attributesAsExtensions(_ element: DOMNode) -> ExtensionMap {
    var map = OrderedMap<QualifiedName, String>()
    for a in element.attributes {
        map[QualifiedName(namespaceUri: a.namespaceURI, localName: a.localName, prefix: a.prefix)] = a.value
    }
    return ExtensionMap(attributes: map)
}

private func ancestorDivSongPart(_ element: DOMNode) -> String? {
    var node = element.parent
    while let n = node {
        if n.isElement && n.localName == "div" {
            return attr(n, SONG_PART, NS_ITUNES_INTERNAL) ?? attr(n, SONG_PART_LEGACY, NS_ITUNES_INTERNAL)
                ?? attr(n, SONG_PART, NS_ITUNES_LEGACY) ?? attr(n, SONG_PART_LEGACY, NS_ITUNES_LEGACY)
                ?? attr(n, SONG_PART) ?? attr(n, SONG_PART_LEGACY)
        }
        node = n.parent
    }
    return nil
}

private func firstPInAncestorDiv(_ element: DOMNode) -> (Int64?, Int64?)? {
    var node = element.parent
    while let n = node {
        if n.isElement && n.localName == "div" {
            guard let firstP = elementsByLocalName(n, "p").first else { return nil }
            if firstP !== element { return nil }
            return (attr(n, "begin").map(parseTtmlTimeMs), attr(n, "end").map(parseTtmlTimeMs))
        }
        node = n.parent
    }
    return nil
}

private func withSongPart(_ map: ExtensionMap, _ value: String?) -> ExtensionMap {
    guard let value else { return map }
    var copy = map
    copy.attributes[QualifiedName(namespaceUri: NS_ITUNES_INTERNAL, localName: SONG_PART, prefix: "itunes")] = value
    return copy
}

private func withDivTiming(_ map: ExtensionMap, _ divTiming: (Int64?, Int64?)?) -> ExtensionMap {
    guard let divTiming else { return map }
    var copy = map
    if let begin = divTiming.0 { copy.attributes[QualifiedName(localName: "divBegin")] = String(begin) }
    if let end = divTiming.1 { copy.attributes[QualifiedName(localName: "divEnd")] = String(end) }
    return copy
}

private func songPartExtensionValue(_ line: LyricsDocumentLine) -> String? {
    guard let v = line.extensions.attributes.pairs.first(where: { $0.0.localName == SONG_PART || $0.0.localName == SONG_PART_LEGACY })?.1,
          v.ktIsNotBlank else { return nil }
    return v
}

private func divTimingExtensionValue(_ line: LyricsDocumentLine, _ localName: String) -> Int64? {
    line.extensions.attributes.pairs.first { $0.0.localName == localName }?.1.ktToLongOrNull
}

private func ttmlOutputName(_ name: QualifiedName) -> String? {
    if name.localName == "xmlns" || name.prefix == "xmlns" || name.namespaceUri == NS_XMLNS { return nil }
    if TTML_WRITER_MANAGED_LOCAL_NAMES.contains(name.localName) { return nil }
    let output: String?
    switch name.namespaceUri {
    case nil: output = name.localName
    case NS_TTM?: output = "ttm:" + name.localName
    case NS_ITUNES_INTERNAL?, NS_ITUNES_LEGACY?: output = "itunes:" + name.localName
    case NS_XML?: output = "xml:" + name.localName
    default: output = nil
    }
    guard let output, SAFE_XML_NAME.matches(output) else { return nil }
    return output
}

private func toExtensionElement(_ element: DOMNode) -> ExtensionElement {
    let direct = directTextContent(element)
    return ExtensionElement(
        name: QualifiedName(namespaceUri: element.namespaceURI, localName: element.localName, prefix: element.prefix),
        attributes: attributesAsExtensions(element).attributes,
        text: direct.isEmpty ? nil : direct,
        children: element.childElements.map(toExtensionElement)
    )
}

private func appendExtensionElement(_ builder: inout String, _ element: ExtensionElement, _ indent: String, defaultNamespace: String? = nil) {
    let name = element.name.namespaceUri == defaultNamespace ? element.name.localName : outputName(element.name)
    guard SAFE_XML_NAME.matches(name) else { return }
    builder += indent + "<" + name
    for (attribute, value) in element.attributes {
        let attributeName = outputName(attribute)
        if attribute.namespaceUri != NS_XMLNS && SAFE_XML_NAME.matches(attributeName) {
            builder += " " + attributeName + "=\"" + escapeXml(value) + "\""
        }
    }
    if element.text == nil && element.children.isEmpty {
        builder += "/>\n"
        return
    }
    builder += ">"
    if let text = element.text { builder += escapeXml(text) }
    if !element.children.isEmpty {
        builder += "\n"
        for child in element.children { appendExtensionElement(&builder, child, indent + "  ", defaultNamespace: defaultNamespace) }
        builder += indent
    }
    builder += "</" + name + ">\n"
}

private func appendUnmanagedAttributes(_ builder: inout String, _ extensions: ExtensionMap, _ excluded: Set<String>) {
    for (name, value) in extensions.attributes {
        let output = outputName(name)
        if name.namespaceUri != NS_XMLNS && !excluded.contains(name.localName) && SAFE_XML_NAME.matches(output) {
            builder += " " + output + "=\"" + escapeXml(value) + "\""
        }
    }
}

private func withValidBodyDuration(_ map: ExtensionMap) -> ExtensionMap {
    var copy = map
    var filtered = OrderedMap<QualifiedName, String>()
    for (name, value) in map.attributes where !(name.namespaceUri == nil && name.localName == "dur" && !TtmlTime.isValid(value)) {
        filtered[name] = value
    }
    copy.attributes = filtered
    return copy
}

private func outputName(_ name: QualifiedName) -> String {
    switch name.namespaceUri {
    case NS_TTM?: return "ttm:" + name.localName
    case NS_ITUNES_INTERNAL?, NS_ITUNES_LEGACY?: return "itunes:" + name.localName
    case NS_XML?: return "xml:" + name.localName
    case NS_TTS?: return "tts:" + name.localName
    default:
        if let prefix = name.prefix, prefix.ktIsNotBlank { return prefix + ":" + name.localName }
        return name.localName
    }
}

private func collectDocumentNamespaces(_ document: LyricsDocument) -> [(String, String)] {
    var namespaces = OrderedMap<String, String>()
    func collectName(_ name: QualifiedName) {
        if let prefix = name.prefix, prefix.ktIsNotBlank, SAFE_XML_NAME.matches(prefix),
           let uri = name.namespaceUri, uri.ktIsNotBlank, uri != NS_XMLNS {
            namespaces.putIfAbsent(prefix, uri)
        }
    }
    func collectElement(_ element: ExtensionElement) {
        collectName(element.name)
        element.attributes.keys.forEach(collectName)
        element.children.forEach(collectElement)
    }
    document.extensions.attributes.keys.forEach(collectName)
    document.bodyExtensions.attributes.keys.forEach(collectName)
    document.headMetadataElements.forEach(collectElement)
    document.itunesMetadataElements.forEach(collectElement)
    if document.tracks.contains(where: { $0.lines.contains { $0.words.contains { !$0.ruby.isEmpty } } }) {
        namespaces["tts"] = NS_TTS
    }
    return namespaces.pairs
}

private func isRomanizationRole(_ role: String?) -> Bool { role == ROLE_ROMAN || role == ROLE_ROMAN_LEGACY }

private func needsRomanizationSeparator(_ previous: String, _ current: String) -> Bool {
    !(previous.unicodeScalars.last?.ktIsWhitespace ?? false) && !(current.unicodeScalars.first?.ktIsWhitespace ?? false)
}

private func directTextContent(_ element: DOMNode) -> String {
    element.children.filter { $0.isTextLike }.map(\.value).joined()
}

private func elementsByLocalName(_ root: DOMNode, _ localName: String) -> [DOMNode] {
    var result: [DOMNode] = []
    func visit(_ node: DOMNode) {
        if node.isElement && node.localName == localName { result.append(node) }
        node.children.forEach(visit)
    }
    visit(root)
    return result
}

private func childElementsByLocalName(_ element: DOMNode, _ localName: String) -> [DOMNode] {
    element.childElements.filter { $0.localName == localName }
}

func normalizeTtmlText(_ text: String, trimEdges: Bool = false) -> String {
    if !text.hasScalar("\n") && !text.hasScalar("\r") {
        return trimEdges ? text.ktTrim() : text
    }
    let collapsed = ttmlWhitespaceRun.replace(text, with: " ")
    return trimEdges ? collapsed.ktTrim() : collapsed
}

private func parseTtmlTimeMs(_ value: String) -> Int64 { TtmlTime.parseMsOrNull(value) ?? 0 }

private func escapeXml(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
