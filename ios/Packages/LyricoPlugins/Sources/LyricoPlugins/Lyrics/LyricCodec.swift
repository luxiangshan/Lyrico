import Foundation

/// Port of `LyricDecoder`.
public enum LyricDecoder {
    public static func detectFormat(_ lyricsText: String) -> LyricFormat? {
        if lyricsText.ktIsBlank { return nil }
        if looksLikeTtml(lyricsText) { return .ttml }
        var hasEnhanced = false, hasVerbatim = false, hasPlain = false
        for line in lyricsText.ktLines() where line.ktIsNotBlank {
            if line.hasPrefix("[ti:") || line.hasPrefix("[ar:") || line.hasPrefix("[al:") { continue }
            let matches = LyricFormatter.lrcTimePattern.findAll(line)
            if matches.isEmpty { continue }
            let hasBracket = matches.contains { $0.value.hasPrefix("[") }
            let hasAngle = matches.contains { $0.value.hasPrefix("<") }
            if hasBracket && hasAngle { hasEnhanced = true; break }
            else if hasBracket && matches.count > 1 { hasVerbatim = true; break }
            else if hasBracket && matches.count == 1 { hasPlain = true }
        }
        if hasEnhanced { return .enhancedLrc }
        if hasVerbatim { return .verbatimLrc }
        if hasPlain { return .plainLrc }
        return nil
    }

    private static func looksLikeTtml(_ text: String) -> Bool {
        var rest = text.ktTrimStart(chars: ["\u{FEFF}"]).ktTrimStart()
        while true {
            if rest.hasPrefix("<?") {
                guard let r = rest.range(of: "?>", range: rest.index(rest.startIndex, offsetBy: 2)..<rest.endIndex) else { return false }
                rest = String(rest[r.upperBound...]).ktTrimStart()
            } else if rest.hasPrefix("<!--") {
                guard let r = rest.range(of: "-->", range: rest.index(rest.startIndex, offsetBy: 4)..<rest.endIndex) else { return false }
                rest = String(rest[r.upperBound...]).ktTrimStart()
            } else {
                let scalars = Array(rest.unicodeScalars.prefix(4))
                guard scalars.count >= 3, scalars[0] == "<", scalars[1] == "t", scalars[2] == "t" else { return false }
                guard scalars.count == 4 else { return false }
                let b = scalars[3]
                return b == ">" || b == "/" || b.ktIsWhitespace
            }
        }
    }

    /// Safe decode: returns nil on any parse failure.
    public static func decode(_ lyricsText: String) -> LyricsResult? {
        guard let format = detectFormat(lyricsText) else { return nil }
        guard let document = try? LyricsDocumentPipeline.parse(lyricsText, sourceFormat: format) else { return nil }
        return LyricsDocumentPipeline.toLyricsResult(document)
    }
}

/// Port of `LyricEncoder`.
public enum LyricEncoder {
    private static let ttmlTimePattern = KRegex("(begin=\"|end=\")([0-9]{2,}):([0-9]{2}):([0-9]{2})\\.([0-9]{2,3})(\")")
    private static let placeholder = KRegex("^[\(jWhitespaceClass)/]*$")
    private static let timeToken = KRegex(
        "[\\[<][0-9]{2,}:[0-9]{2}\\.[0-9]{2,3}[>\\]]" +
        "|begin=\"[0-9]{2,}:[0-9]{2}:[0-9]{2}\\.[0-9]{2,3}" +
        "|end=\"[0-9]{2,}:[0-9]{2}:[0-9]{2}\\.[0-9]{2,3}"
    )

    private static func isBlankOrPlaceholder(_ line: LyricsLine) -> Bool {
        let text = line.words.map(\.text).joined().ktTrim()
        return text.isEmpty || placeholder.matches(text)
    }

    public static func convertLyricsResult(_ result: LyricsResult, _ mode: ConversionMode) -> LyricsResult {
        if mode == .none { return result }
        var r = result
        r.original = convertLines(result.original, mode)
        r.translated = result.translated.map { convertLines($0, mode) }
        r.romanization = result.romanization.map { convertLines($0, mode) }
        var tags = StringMap()
        for (k, v) in result.tags { tags[k] = ChineseConverter.convert(v, mode) }
        r.tags = tags
        return r
    }

    private static func convertLines(_ lines: [LyricsLine], _ mode: ConversionMode) -> [LyricsLine] {
        lines.map { line in
            var l = line
            l.words = line.words.map { word in
                var w = word
                w.text = ChineseConverter.convert(word.text, mode)
                w.ruby = word.ruby.map { var s = $0; s.text = ChineseConverter.convert($0.text, mode); return s }
                return w
            }
            return l
        }
    }

    /// Converts the text segments of raw lyrics while keeping timestamp tokens.
    public static func convertLyricsText(_ lyricsText: String, _ mode: ConversionMode) -> String {
        if mode == .none || lyricsText.ktIsBlank { return lyricsText }
        let ns = lyricsText as NSString
        var result = ""
        var lastEnd = 0
        for m in timeToken.findAll(lyricsText) {
            if m.first > lastEnd {
                result += ChineseConverter.convert(ns.substring(with: NSRange(location: lastEnd, length: m.first - lastEnd)), mode)
            }
            result += m.value
            lastEnd = m.end
        }
        if lastEnd < ns.length { result += ChineseConverter.convert(ns.substring(from: lastEnd), mode) }
        return result
    }

    public static func encodePlainText(_ result: LyricsResult, config: LyricRenderConfig, conversionMode: ConversionMode = .none) -> String {
        let converted = convertLyricsResult(result, conversionMode)
        var builder = ""
        let romanMap = config.showRomanization ? alignSubLines(converted.original, converted.romanization) : [:]
        let translatedMap = config.showTranslation ? alignSubLines(converted.original, converted.translated) : [:]
        for line in converted.original {
            if config.removeEmptyLines && isBlankOrPlaceholder(line) { continue }
            var matchedTranslation: LyricsLine?
            if config.showTranslation, let m = translatedMap[line.start] {
                matchedTranslation = (config.removeEmptyLines && isBlankOrPlaceholder(m)) ? nil : m
            }
            var matchedRoman: LyricsLine?
            if config.showRomanization, let m = romanMap[line.start] {
                matchedRoman = (config.removeEmptyLines && isBlankOrPlaceholder(m)) ? nil : m
            }
            let skipOriginal = config.onlyTranslationIfAvailable && matchedTranslation != nil
            for track in config.normalizedLineOrder {
                let trackLine: LyricsLine?
                switch track {
                case .original: trackLine = skipOriginal ? nil : line
                case .romanization: trackLine = skipOriginal ? nil : matchedRoman
                case .translation: trackLine = matchedTranslation
                }
                guard let trackLine else { continue }
                let separator = track == .romanization ? " " : ""
                let text = trackLine.words.map(\.text).joined(separator: separator)
                if text.ktIsNotBlank { builder += text + "\n" }
            }
        }
        return builder.ktTrim()
    }

    public static func encode(_ result: LyricsResult, config: LyricRenderConfig, offset: Int64 = 0) throws -> String {
        if result.payloadType.isRaw {
            if shouldUseDocumentPipeline(result, config, offset), let out = try LyricsDocumentPipeline.processRawResult(result, config: config, offset: offset) {
                return out
            }
            if let out = try encodeRawWithRenderConfig(selectRawLyrics(result, config), config, offset) { return out }
            if let raw = selectRawLyrics(result, config) {
                return shiftLyricsOffset(convertLyricsText(raw, config.conversionMode), offset).ktTrim()
            }
            if let out = try encodeFallbackRawLyrics(result, config, offset) { return out }
        }
        if result.original.isEmpty {
            let selectedRaw = selectRawLyrics(result, config)
            if shouldUseDocumentPipeline(result, config, offset), let out = try LyricsDocumentPipeline.processRawResult(result, config: config, offset: offset) {
                return out
            }
            if let out = try encodeRawWithRenderConfig(selectedRaw, config, offset) { return out }
            if let raw = selectedRaw {
                return shiftLyricsOffset(convertLyricsText(raw, config.conversionMode), offset).ktTrim()
            }
            if let out = try encodeFallbackRawLyrics(result, config, offset) { return out }
        }
        if config.format == .ttml, let out = LyricsDocumentPipeline.processStructuredResult(result, config: config, offset: offset) {
            return out
        }

        let converted = convertLyricsResult(result, config.conversionMode)
        var builder = ""
        let isWordLevel = converted.isWordByWord
        let romanMap = config.showRomanization ? alignSubLines(converted.original, converted.romanization) : [:]
        let translatedMap = config.showTranslation ? alignSubLines(converted.original, converted.translated) : [:]

        for line in converted.original {
            if config.removeEmptyLines && isBlankOrPlaceholder(line) { continue }
            var matchedTranslation: LyricsLine?
            if config.showTranslation, let m = translatedMap[line.start] {
                matchedTranslation = (config.removeEmptyLines && isBlankOrPlaceholder(m)) ? nil : m
            }
            var matchedRoman: LyricsLine?
            if config.showRomanization, let m = romanMap[line.start] {
                matchedRoman = (config.removeEmptyLines && isBlankOrPlaceholder(m)) ? nil : m
            }
            let skipOriginal = config.onlyTranslationIfAvailable && matchedTranslation != nil
            for track in config.normalizedLineOrder {
                let trackLine: LyricsLine?
                switch track {
                case .original: trackLine = skipOriginal ? nil : line
                case .romanization: trackLine = skipOriginal ? nil : matchedRoman
                case .translation: trackLine = matchedTranslation
                }
                guard let trackLine else { continue }
                let trackWordLevel: Bool
                switch track {
                case .original: trackWordLevel = isWordLevel
                case .romanization: trackWordLevel = trackLine.words.count > 1
                case .translation: trackWordLevel = false
                }
                let separator = track == .romanization ? " " : ""
                switch config.format {
                case .plainLrc: appendLineByLine(&builder, trackLine, offset)
                case .enhancedLrc:
                    if trackWordLevel { appendEnhancedLine(&builder, trackLine, offset, separator) } else { appendLineByLine(&builder, trackLine, offset) }
                case .verbatimLrc:
                    if trackWordLevel { appendWordByWord(&builder, trackLine, offset, separator) } else { appendLineByLine(&builder, trackLine, offset) }
                case .ttml: break
                }
                builder += "\n"
            }
        }
        return builder.ktTrim()
    }

    private static func encodeRawWithRenderConfig(_ raw: String?, _ config: LyricRenderConfig, _ offset: Int64) throws -> String? {
        guard let raw, raw.ktIsNotBlank else { return nil }
        let apply = !config.showTranslation || !config.showRomanization || config.onlyTranslationIfAvailable ||
            lineOrderAffectsLineOutput(config) || config.removeEmptyLines
        if !apply { return nil }
        guard let sourceFormat = LyricDecoder.detectFormat(raw) else { return nil }
        return try LyricsDocumentPipeline.process(
            raw: raw, sourceFormat: sourceFormat, targetFormat: config.format, conversionMode: config.conversionMode,
            showTranslation: config.showTranslation, showRomanization: config.showRomanization,
            onlyTranslationIfAvailable: config.onlyTranslationIfAvailable, lineOrder: config.normalizedLineOrder,
            removeEmptyLines: config.removeEmptyLines, offset: offset)
    }

    private static func selectRawLyrics(_ result: LyricsResult, _ config: LyricRenderConfig) -> String? {
        let raw: String
        switch config.format {
        case .plainLrc: raw = result.rawPlainLrc
        case .verbatimLrc: raw = result.rawVerbatimLrc
        case .enhancedLrc: raw = result.rawEnhancedLrc
        case .ttml: raw = result.rawTtml
        }
        return raw.ktIsNotBlank ? raw : nil
    }

    private static func encodeFallbackRawLyrics(_ result: LyricsResult, _ config: LyricRenderConfig, _ offset: Int64) throws -> String? {
        let candidates: [(LyricFormat, String)]
        switch config.format {
        case .plainLrc:
            candidates = [(.verbatimLrc, result.rawVerbatimLrc), (.enhancedLrc, result.rawEnhancedLrc),
                          (.enhancedLrc, result.rawMultiPersonEnhancedLrc), (.ttml, result.rawTtml)]
        case .verbatimLrc:
            candidates = [(.enhancedLrc, result.rawEnhancedLrc), (.enhancedLrc, result.rawMultiPersonEnhancedLrc),
                          (.ttml, result.rawTtml), (.plainLrc, result.rawPlainLrc)]
        case .enhancedLrc:
            candidates = [(.verbatimLrc, result.rawVerbatimLrc), (.enhancedLrc, result.rawMultiPersonEnhancedLrc),
                          (.ttml, result.rawTtml), (.plainLrc, result.rawPlainLrc)]
        case .ttml:
            candidates = [(.enhancedLrc, result.rawEnhancedLrc), (.verbatimLrc, result.rawVerbatimLrc), (.plainLrc, result.rawPlainLrc)]
        }
        if let (format, raw) = candidates.first(where: { $0.1.ktIsNotBlank }) {
            if let out = try LyricsDocumentPipeline.process(
                raw: raw, sourceFormat: format, targetFormat: config.format, conversionMode: config.conversionMode,
                showTranslation: config.showTranslation, showRomanization: config.showRomanization,
                onlyTranslationIfAvailable: config.onlyTranslationIfAvailable, lineOrder: config.normalizedLineOrder,
                removeEmptyLines: config.removeEmptyLines, offset: offset) {
                return out
            }
        }
        return nil
    }

    private static func shouldUseDocumentPipeline(_ result: LyricsResult, _ config: LyricRenderConfig, _ offset: Int64) -> Bool {
        offset != 0 || config.conversionMode != .none || !config.showTranslation || !config.showRomanization ||
            config.onlyTranslationIfAvailable || lineOrderAffectsLineOutput(config) || config.removeEmptyLines ||
            selectRawLyrics(result, config) == nil
    }

    private static func lineOrderAffectsLineOutput(_ config: LyricRenderConfig) -> Bool {
        config.format != .ttml && config.normalizedLineOrder != defaultLyricLineOrder
    }

    private static func appendEnhancedLine(_ builder: inout String, _ line: LyricsLine, _ offset: Int64, _ separator: String) {
        guard let lastWord = line.words.last else { return }
        builder += "[" + LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(line.start, offset)) + "] "
        for (index, word) in line.words.enumerated() {
            if index > 0 && !separator.isEmpty { builder += separator }
            builder += "<" + LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(word.start, offset)) + ">" + word.text
        }
        let end: Int64
        if lastWord.end > 0 { end = lastWord.end } else if lastWord.start > 0 { end = lastWord.start + 100 } else { end = line.start + 2000 }
        builder += "<" + LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(end, offset)) + ">"
    }

    private static func appendLineByLine(_ builder: inout String, _ line: LyricsLine, _ offset: Int64) {
        builder += "[" + LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(line.start, offset)) + "]" + line.words.map(\.text).joined()
    }

    private static func appendWordByWord(_ builder: inout String, _ line: LyricsLine, _ offset: Int64, _ separator: String) {
        for (index, word) in line.words.enumerated() {
            let startFormatted = LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(word.start, offset))
            if index == line.words.count - 1 {
                let end = word.end > 0 ? word.end : word.start + 100
                builder += "[" + startFormatted + "]" + word.text + "[" + LyricFormatter.formatTimestamp(LyricFormatter.applyOffset(end, offset)) + "]"
            } else {
                builder += "[" + startFormatted + "]" + word.text
                if !separator.isEmpty { builder += separator }
            }
        }
    }

    static func alignSubLines(_ originalLines: [LyricsLine], _ subLines: [LyricsLine]?) -> [Int64: LyricsLine] {
        guard !originalLines.isEmpty, let subLines, !subLines.isEmpty else { return [:] }
        var byStart: [Int64: [LyricsLine]] = [:]
        for line in subLines { byStart[line.start, default: []].append(line) }
        var used: [Int64: Int] = [:]
        var result: [Int64: LyricsLine] = [:]
        for original in originalLines {
            let same = byStart[original.start] ?? []
            let usedCount = used[original.start] ?? 0
            guard let matched = same.getOrNull(usedCount) else { continue }
            used[original.start] = usedCount + 1
            result[original.start] = matched
        }
        return result
    }

    /// Shifts all LRC / enhanced / TTML timestamps by `offset` milliseconds.
    public static func shiftLyricsOffset(_ lyricsText: String, _ offset: Int64) -> String {
        if offset == 0 || lyricsText.ktIsBlank { return lyricsText }
        var text = LyricFormatter.lrcTimePattern.replace(lyricsText) { m in
            let min = Int64(m.groupValues[2]) ?? 0, sec = Int64(m.groupValues[3]) ?? 0
            let ms = Int64(m.groupValues[4].ktPadEnd(3, "0")) ?? 0
            let total = max((min * 60 + sec) * 1000 + ms + offset, 0)
            return m.groupValues[1] + String(format: "%02lld:%02lld.%03lld", total / 60000, (total % 60000) / 1000, total % 1000) + m.groupValues[5]
        }
        text = ttmlTimePattern.replace(text) { m in
            let hr = Int64(m.groupValues[2]) ?? 0, min = Int64(m.groupValues[3]) ?? 0, sec = Int64(m.groupValues[4]) ?? 0
            let ms = Int64(m.groupValues[5].ktPadEnd(3, "0")) ?? 0
            let total = max((hr * 3600 + min * 60 + sec) * 1000 + ms + offset, 0)
            return m.groupValues[1] + String(format: "%02lld:%02lld:%02lld.%03lld", total / 3_600_000, (total % 3_600_000) / 60000, (total % 60000) / 1000, total % 1000) + m.groupValues[6]
        }
        return text
    }
}
