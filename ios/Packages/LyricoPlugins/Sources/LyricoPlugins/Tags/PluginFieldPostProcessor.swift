import Foundation

public enum FollowGlobalBooleanMode: String, Hashable, Sendable, Codable { case followGlobal = "FOLLOW_GLOBAL", enabled = "ENABLED", disabled = "DISABLED" }
public enum FieldScriptConversionMode: String, Hashable, Sendable, Codable { case followGlobal = "FOLLOW_GLOBAL", disabled = "DISABLED", simplified = "SIMPLIFIED", traditional = "TRADITIONAL" }

public enum PluginFieldValueType: Hashable, Sendable {
    case text, multilineText, personList, number, date, url, imageUrl, identifier, lyrics, raw
}

public struct FieldProcessRule: Hashable, Sendable, Codable {
    public var scriptConversion: FieldScriptConversionMode = .followGlobal
    public var trim: FollowGlobalBooleanMode = .followGlobal
    public var normalizeWhitespace: FollowGlobalBooleanMode = .followGlobal
    public var removeEmptyLines: FollowGlobalBooleanMode = .followGlobal
    public init() {}
}

public struct PluginFieldProcessConfig: Hashable, Sendable {
    public var pluginId: String
    public var fieldRules: [String: FieldProcessRule]
    public init(pluginId: String, fieldRules: [String: FieldProcessRule] = [:]) { self.pluginId = pluginId; self.fieldRules = fieldRules }
}

public struct GlobalFieldProcessSettings: Hashable, Sendable {
    public var scriptConversion: ConversionMode
    public var trim: Bool
    public var normalizeWhitespace: Bool
    public var removeEmptyLines: Bool
    public init(scriptConversion: ConversionMode = .none, trim: Bool = false, normalizeWhitespace: Bool = false, removeEmptyLines: Bool = true) {
        self.scriptConversion = scriptConversion; self.trim = trim; self.normalizeWhitespace = normalizeWhitespace; self.removeEmptyLines = removeEmptyLines
    }
}

public struct ResolvedFieldProcessRule: Hashable, Sendable {
    public var scriptConversion: ConversionMode
    public var trim: Bool
    public var normalizeWhitespace: Bool
    public var removeEmptyLines: Bool

    static func resolve(_ global: GlobalFieldProcessSettings, _ rule: FieldProcessRule) -> ResolvedFieldProcessRule {
        func b(_ m: FollowGlobalBooleanMode, _ g: Bool) -> Bool { m == .followGlobal ? g : m == .enabled }
        let conversion: ConversionMode
        switch rule.scriptConversion {
        case .followGlobal: conversion = global.scriptConversion
        case .disabled: conversion = .none
        case .simplified: conversion = .traditionalToSimplified
        case .traditional: conversion = .simplifiedToTraditional
        }
        return ResolvedFieldProcessRule(scriptConversion: conversion, trim: b(rule.trim, global.trim),
                                        normalizeWhitespace: b(rule.normalizeWhitespace, global.normalizeWhitespace),
                                        removeEmptyLines: b(rule.removeEmptyLines, global.removeEmptyLines))
    }
}

/// Port of `PluginFieldPostProcessor` (field/lyrics normalisation before tags are written).
public struct PluginFieldPostProcessor: Sendable {
    public let globalSettings: GlobalFieldProcessSettings
    public init(_ globalSettings: GlobalFieldProcessSettings) { self.globalSettings = globalSettings }

    public func processFields(pluginId: String, fields: StringMap, config: PluginFieldProcessConfig) -> StringMap {
        var out = StringMap()
        for (key, value) in fields {
            let rule = ResolvedFieldProcessRule.resolve(globalSettings, config.fieldRules[key] ?? FieldProcessRule())
            out[key] = processTextField(value, Self.inferValueType(key), rule)
        }
        return out
    }

    public func processTextField(_ value: String, _ valueType: PluginFieldValueType, _ rule: ResolvedFieldProcessRule) -> String {
        var text = value
        let textual: Set<PluginFieldValueType> = [.text, .multilineText, .personList, .lyrics]
        if rule.trim && textual.contains(valueType) { text = text.ktTrim() }
        if rule.normalizeWhitespace && textual.contains(valueType) { text = Self.normalizeWhitespace(text, valueType) }
        if rule.removeEmptyLines && (valueType == .multilineText || valueType == .lyrics) { text = Self.removeEmptyLines(text) }
        if textual.contains(valueType) { text = LyricEncoder.convertLyricsText(text, rule.scriptConversion) }
        return text
    }

    public func processLyrics(_ lyrics: LyricsResult, config: PluginFieldProcessConfig, fieldKey: String = "lyrics") throws -> LyricsResult {
        let rule = ResolvedFieldProcessRule.resolve(globalSettings, config.fieldRules[fieldKey] ?? FieldProcessRule())
        var processed = lyrics
        processed.original = processLines(lyrics.original, rule, convertScript: true)
        processed.translated = lyrics.translated.map { processLines($0, rule, convertScript: true) }
        processed.romanization = lyrics.romanization.map { processLines($0, rule, convertScript: false) }
        var tags = StringMap()
        for (k, v) in lyrics.tags { tags[k] = LyricEncoder.convertLyricsText(v, rule.scriptConversion) }
        processed.tags = tags
        return try LyricsDocumentPipeline.processRawResultForFieldRule(processed, rule: rule)
    }

    static func inferValueType(_ key: String) -> PluginFieldValueType {
        switch key {
        case "artist", "album_artist", "composer", "lyricist": return .personList
        case "lyrics", "lyric": return .lyrics
        case "cover_url", "pic_url", "image_url": return .imageUrl
        case "track_number", "disc_number", "duration", "rating": return .number
        case "date", "year": return .date
        default: return .text
        }
    }

    private func processLines(_ lines: [LyricsLine], _ rule: ResolvedFieldProcessRule, convertScript: Bool) -> [LyricsLine] {
        let processed = lines.map { line -> LyricsLine in
            var l = line
            l.words = line.words.map { word in
                var w = word
                if convertScript { w.text = LyricEncoder.convertLyricsText(word.text, rule.scriptConversion) }
                return w
            }
            return l
        }
        return rule.removeEmptyLines ? processed.filter { $0.words.map(\.text).joined().ktIsNotBlank } : processed
    }

    private static let visibleWhitespace = KRegex("[ \\t\\u00A0]+")
    private static let anyWhitespace = KRegex("[\(jWhitespaceClass)]+")

    static func normalizeWhitespace(_ value: String, _ type: PluginFieldValueType) -> String {
        if type == .lyrics || type == .multilineText {
            return value.ktLines().map { visibleWhitespace.replace($0, with: " ") }.joined(separator: "\n")
        }
        return anyWhitespace.replace(value, with: " ")
    }

    static func removeEmptyLines(_ value: String) -> String {
        value.ktLines().filter { $0.ktIsNotBlank }.joined(separator: "\n")
    }
}
