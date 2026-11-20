import Foundation

public typealias StringMap = OrderedMap<String, String>

// MARK: - Structured lyrics (port of data/model/lyrics/Lyrics.kt)

public struct LyricsRubySyllable: Hashable, Sendable {
    public var start: Int64?
    public var end: Int64?
    public var text: String
    public init(start: Int64?, end: Int64?, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public struct LyricsWord: Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var text: String
    public var ruby: [LyricsRubySyllable]
    public init(start: Int64, end: Int64, text: String, ruby: [LyricsRubySyllable] = []) {
        self.start = start; self.end = end; self.text = text; self.ruby = ruby
    }
}

public struct LyricsLine: Hashable, Sendable {
    public var start: Int64
    public var end: Int64
    public var words: [LyricsWord]
    /// Line-level TTML attributes (`ttm:agent`, `itunes:song-part`, `divBegin`, ...).
    public var extensions: StringMap
    public init(start: Int64, end: Int64, words: [LyricsWord], extensions: StringMap = [:]) {
        self.start = start; self.end = end; self.words = words; self.extensions = extensions
    }

    public var text: String { words.map(\.text).joined() }
}

public struct LyricsAgentEntry: Hashable, Sendable {
    public var id: String
    public var type: String?
    public var name: String?
    public init(id: String, type: String? = nil, name: String? = nil) {
        self.id = id; self.type = type; self.name = name
    }
}

public struct LyricsMetadataElement: Hashable, Sendable {
    public var name: String
    public var namespace: String?
    public var attributes: StringMap
    public var text: String?
    public var children: [LyricsMetadataElement]
    public init(name: String, namespace: String? = nil, attributes: StringMap = [:], text: String? = nil, children: [LyricsMetadataElement] = []) {
        self.name = name; self.namespace = namespace; self.attributes = attributes; self.text = text; self.children = children
    }
}

public enum LyricsPayloadType: String, Hashable, Sendable, CaseIterable {
    case structured = "STRUCTURED"
    case rawPlainLrc = "RAW_PLAIN_LRC"
    case rawVerbatimLrc = "RAW_VERBATIM_LRC"
    case rawEnhancedLrc = "RAW_ENHANCED_LRC"
    case rawTtml = "RAW_TTML"
    case rawMultiPersonEnhancedLrc = "RAW_MULTI_PERSON_ENHANCED_LRC"

    public var isRaw: Bool { self != .structured }
}

public struct LyricsResult: Hashable, Sendable {
    public var tags: StringMap
    public var original: [LyricsLine]
    public var translated: [LyricsLine]?
    public var romanization: [LyricsLine]?
    public var payloadType: LyricsPayloadType
    public var isWordByWord: Bool
    public var rawPlainLrc: String
    public var rawVerbatimLrc: String
    public var rawEnhancedLrc: String
    public var rawTtml: String
    public var rawMultiPersonEnhancedLrc: String
    public var agents: [LyricsAgentEntry]
    public var metadata: [LyricsMetadataElement]
    public var timing: String
    public var language: String
    public var translatedLang: String
    public var romanizationLang: String
    public var bodyDur: String

    public init(
        tags: StringMap = [:],
        original: [LyricsLine],
        translated: [LyricsLine]? = nil,
        romanization: [LyricsLine]? = nil,
        payloadType: LyricsPayloadType = .structured,
        isWordByWord: Bool = true,
        rawPlainLrc: String = "",
        rawVerbatimLrc: String = "",
        rawEnhancedLrc: String = "",
        rawTtml: String = "",
        rawMultiPersonEnhancedLrc: String = "",
        agents: [LyricsAgentEntry] = [],
        metadata: [LyricsMetadataElement] = [],
        timing: String = "",
        language: String = "",
        translatedLang: String = "",
        romanizationLang: String = "",
        bodyDur: String = ""
    ) {
        self.tags = tags; self.original = original; self.translated = translated; self.romanization = romanization
        self.payloadType = payloadType; self.isWordByWord = isWordByWord
        self.rawPlainLrc = rawPlainLrc; self.rawVerbatimLrc = rawVerbatimLrc; self.rawEnhancedLrc = rawEnhancedLrc
        self.rawTtml = rawTtml; self.rawMultiPersonEnhancedLrc = rawMultiPersonEnhancedLrc
        self.agents = agents; self.metadata = metadata; self.timing = timing; self.language = language
        self.translatedLang = translatedLang; self.romanizationLang = romanizationLang; self.bodyDur = bodyDur
    }
}

extension Array where Element == LyricsLine {
    /// `List<LyricsLine>.isWordByWord()`.
    public var isWordByWord: Bool { contains { $0.words.count > 1 } }
}

// MARK: - Render configuration

public enum LyricFormat: String, Hashable, Sendable, CaseIterable, Codable {
    case plainLrc = "PLAIN_LRC"
    case verbatimLrc = "VERBATIM_LRC"
    case enhancedLrc = "ENHANCED_LRC"
    case ttml = "TTML"
}

public enum LyricLineTrack: String, Hashable, Sendable, CaseIterable, Codable {
    case original = "ORIGINAL"
    case romanization = "ROMANIZATION"
    case translation = "TRANSLATION"
}

public let defaultLyricLineOrder: [LyricLineTrack] = [.original, .romanization, .translation]

extension Array where Element == LyricLineTrack {
    public var normalizedLyricLineOrder: [LyricLineTrack] {
        (self + defaultLyricLineOrder).ktDistinct().filter { defaultLyricLineOrder.contains($0) }
    }
}

public func visibleLyricLineTracks(showRomanization: Bool, showTranslation: Bool, onlyTranslationIfAvailable: Bool) -> [LyricLineTrack] {
    if showTranslation && onlyTranslationIfAvailable { return [.translation] }
    var out: [LyricLineTrack] = [.original]
    if showRomanization { out.append(.romanization) }
    if showTranslation { out.append(.translation) }
    return out
}

public enum ConversionMode: String, Hashable, Sendable, CaseIterable, Codable {
    case none = "NONE"
    case traditionalToSimplified = "TRADITIONAL_TO_SIMPLIFIED"
    case simplifiedToTraditional = "SIMPLIFIED_TO_TRADITIONAL"
}

/// Defaults mirror `SettingsDefaults` of the Android app.
public struct LyricRenderConfig: Hashable, Sendable, Codable {
    public var format: LyricFormat
    public var showRomanization: Bool
    public var showTranslation: Bool
    public var onlyTranslationIfAvailable: Bool
    public var lineOrder: [LyricLineTrack]
    public var removeEmptyLines: Bool
    public var conversionMode: ConversionMode

    public init(
        format: LyricFormat = .verbatimLrc,
        showRomanization: Bool = true,
        showTranslation: Bool = true,
        onlyTranslationIfAvailable: Bool = false,
        lineOrder: [LyricLineTrack] = defaultLyricLineOrder,
        removeEmptyLines: Bool = true,
        conversionMode: ConversionMode = .none
    ) {
        self.format = format; self.showRomanization = showRomanization; self.showTranslation = showTranslation
        self.onlyTranslationIfAvailable = onlyTranslationIfAvailable; self.lineOrder = lineOrder
        self.removeEmptyLines = removeEmptyLines; self.conversionMode = conversionMode
    }

    public var normalizedLineOrder: [LyricLineTrack] { lineOrder.normalizedLyricLineOrder }
}

// MARK: - Column mapping / processing options

public struct LyricsColumnMapping: Hashable, Sendable, Codable {
    public var sourceCount: Int
    public var order: [Int]
    public init(sourceCount: Int, order: [Int]) { self.sourceCount = sourceCount; self.order = order }

    public var isValid: Bool {
        sourceCount > 0 && !order.isEmpty && order.ktDistinct().count == order.count && order.allSatisfy { $0 >= 0 && $0 < sourceCount }
    }
    public var isChanged: Bool { order != Array(0..<max(sourceCount, 0)) }

    public func place(_ source: Int, _ destination: Int?) -> LyricsColumnMapping {
        precondition(isValid && source >= 0 && source < sourceCount)
        var remaining = order.filter { $0 != source }
        if let destination { remaining.insert(source, at: min(max(destination, 0), remaining.count)) }
        return remaining.isEmpty ? self : LyricsColumnMapping(sourceCount: sourceCount, order: remaining)
    }

    public static func identity(_ count: Int) -> LyricsColumnMapping { LyricsColumnMapping(sourceCount: count, order: Array(0..<count)) }
}

public struct LyricsProcessingOptions: Hashable, Sendable {
    public var targetFormat: LyricFormat?
    public var formatLineOrder: Bool
    public var removeTagLines: Bool
    public var tagLineKeywords: [String]
    public var removeEmptyLines: Bool
    public var twoColumnMapping: LyricsColumnMapping
    public var threeColumnMapping: LyricsColumnMapping

    public init(targetFormat: LyricFormat? = nil, formatLineOrder: Bool = false, removeTagLines: Bool = false,
                tagLineKeywords: [String] = [], removeEmptyLines: Bool = false,
                twoColumnMapping: LyricsColumnMapping = .identity(2), threeColumnMapping: LyricsColumnMapping = .identity(3)) {
        self.targetFormat = targetFormat; self.formatLineOrder = formatLineOrder; self.removeTagLines = removeTagLines
        self.tagLineKeywords = tagLineKeywords; self.removeEmptyLines = removeEmptyLines
        self.twoColumnMapping = twoColumnMapping; self.threeColumnMapping = threeColumnMapping
    }

    public func hasTextOperations() -> Bool {
        formatLineOrder || twoColumnMapping.isChanged || threeColumnMapping.isChanged ||
            (removeTagLines && tagLineKeywords.contains { $0.ktIsNotBlank }) || removeEmptyLines
    }

    public static let defaultTagLineKeywords: [String] = [
        "[by:", "[kana:", "[trans:", "[roma:", "作词：", "作词:", "作曲：", "作曲:", "编曲：", "编曲:",
        "制作人：", "制作人:", "监制：", "监制:", "混音：", "混音:", "录音：", "录音:", "母带：", "母带:",
        "和声：", "和声:", "配唱制作人：", "配唱制作人:", "OP：", "OP:", "SP：", "SP:", "出品：", "出品:",
        "发行：", "发行:"
    ]
}

// MARK: - Document model (port of data/model/lyrics/document)

public struct QualifiedName: Hashable, Sendable {
    public var namespaceUri: String?
    public var localName: String
    public var prefix: String?
    public init(namespaceUri: String? = nil, localName: String, prefix: String? = nil) {
        self.namespaceUri = namespaceUri; self.localName = localName; self.prefix = prefix
    }
}

public struct ExtensionElement: Hashable, Sendable {
    public var name: QualifiedName
    public var attributes: OrderedMap<QualifiedName, String>
    public var text: String?
    public var children: [ExtensionElement]
    public init(name: QualifiedName, attributes: OrderedMap<QualifiedName, String> = [:], text: String? = nil, children: [ExtensionElement] = []) {
        self.name = name; self.attributes = attributes; self.text = text; self.children = children
    }
}

public struct ExtensionMap: Hashable, Sendable {
    public var attributes: OrderedMap<QualifiedName, String>
    public var elements: [ExtensionElement]
    public var values: StringMap
    public init(attributes: OrderedMap<QualifiedName, String> = [:], elements: [ExtensionElement] = [], values: StringMap = [:]) {
        self.attributes = attributes; self.elements = elements; self.values = values
    }
}

public struct LyricsMetadata: Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var language: String?
    public var timing: String?
    public var offsetMs: Int64?
    public var extra: StringMap
    public init(title: String? = nil, artist: String? = nil, album: String? = nil, language: String? = nil,
                timing: String? = nil, offsetMs: Int64? = nil, extra: StringMap = [:]) {
        self.title = title; self.artist = artist; self.album = album; self.language = language
        self.timing = timing; self.offsetMs = offsetMs; self.extra = extra
    }
}

public enum LyricsAgentType: Hashable, Sendable {
    case person, group, character, organization, other, narrator, unknown
}

public struct LyricsAgent: Hashable, Sendable {
    public var id: String
    public var type: LyricsAgentType
    public var name: String?
    public var rawType: String?
    public var extensions: ExtensionMap
    public init(id: String, type: LyricsAgentType = .unknown, name: String? = nil, rawType: String? = nil, extensions: ExtensionMap = ExtensionMap()) {
        self.id = id; self.type = type; self.name = name; self.rawType = rawType; self.extensions = extensions
    }
}

public enum LyricsTrackType: Hashable, Sendable {
    case original, translation, romanization, background, other
}

public struct LyricsDocumentRubySyllable: Hashable, Sendable {
    public var startMs: Int64?
    public var endMs: Int64?
    public var text: String
    public init(startMs: Int64? = nil, endMs: Int64? = nil, text: String) {
        self.startMs = startMs; self.endMs = endMs; self.text = text
    }
}

public struct LyricsDocumentWord: Hashable, Sendable {
    public var startMs: Int64?
    public var endMs: Int64?
    public var text: String
    public var ruby: [LyricsDocumentRubySyllable]
    public var extensions: ExtensionMap
    public init(startMs: Int64? = nil, endMs: Int64? = nil, text: String, ruby: [LyricsDocumentRubySyllable] = [], extensions: ExtensionMap = ExtensionMap()) {
        self.startMs = startMs; self.endMs = endMs; self.text = text; self.ruby = ruby; self.extensions = extensions
    }
}

public struct LyricsDocumentLine: Hashable, Sendable {
    public var id: String?
    public var startMs: Int64?
    public var endMs: Int64?
    public var text: String
    public var words: [LyricsDocumentWord]
    public var linkKey: String?
    public var agentId: String?
    public var extensions: ExtensionMap
    public init(id: String? = nil, startMs: Int64? = nil, endMs: Int64? = nil, text: String = "", words: [LyricsDocumentWord] = [],
                linkKey: String? = nil, agentId: String? = nil, extensions: ExtensionMap = ExtensionMap()) {
        self.id = id; self.startMs = startMs; self.endMs = endMs; self.text = text; self.words = words
        self.linkKey = linkKey; self.agentId = agentId; self.extensions = extensions
    }

    /// `visibleText()`.
    public var visibleText: String { words.isEmpty ? text : words.map(\.text).joined() }
}

public struct LyricsTrack: Hashable, Sendable {
    public var type: LyricsTrackType
    public var language: String?
    public var lines: [LyricsDocumentLine]
    public var extensions: ExtensionMap
    public init(type: LyricsTrackType, language: String? = nil, lines: [LyricsDocumentLine] = [], extensions: ExtensionMap = ExtensionMap()) {
        self.type = type; self.language = language; self.lines = lines; self.extensions = extensions
    }
}

public struct LyricsDocument: Hashable, Sendable {
    public var metadata: LyricsMetadata
    public var agents: [LyricsAgent]
    public var tracks: [LyricsTrack]
    public var extensions: ExtensionMap
    public var bodyExtensions: ExtensionMap
    public var headMetadataElements: [ExtensionElement]
    public var itunesMetadataElements: [ExtensionElement]
    public var sourceFormat: LyricFormat?
    public init(metadata: LyricsMetadata = LyricsMetadata(), agents: [LyricsAgent] = [], tracks: [LyricsTrack] = [],
                extensions: ExtensionMap = ExtensionMap(), bodyExtensions: ExtensionMap = ExtensionMap(),
                headMetadataElements: [ExtensionElement] = [], itunesMetadataElements: [ExtensionElement] = [],
                sourceFormat: LyricFormat? = nil) {
        self.metadata = metadata; self.agents = agents; self.tracks = tracks; self.extensions = extensions
        self.bodyExtensions = bodyExtensions; self.headMetadataElements = headMetadataElements
        self.itunesMetadataElements = itunesMetadataElements; self.sourceFormat = sourceFormat
    }
}
