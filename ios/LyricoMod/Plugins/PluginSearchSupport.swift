// Glue between the LyricoPlugins package and the app: lyric render settings, plugin field -> editor
// field mapping, cover download, and a port of Android MusicMatchUtils used by batch matching.
#if canImport(LyricoPlugins)
import Foundation
import LyricoPlugins
import UIKit

extension AppSettings {
    var lyricLineOrderTracks: [LyricLineTrack] {
        lyricLineOrder.split(separator: ",").compactMap { LyricLineTrack(rawValue: String($0)) }.normalizedLyricLineOrder
    }

    /// Android `SettingsRepository.getLyricRenderConfig()`.
    var lyricRenderConfig: LyricRenderConfig {
        LyricRenderConfig(
            format: LyricFormat(rawValue: lyricFormat) ?? .verbatimLrc,
            showRomanization: lyricShowRomanization,
            showTranslation: lyricShowTranslation,
            onlyTranslationIfAvailable: lyricOnlyTranslation,
            lineOrder: lyricLineOrderTracks,
            removeEmptyLines: lyricRemoveEmptyLines,
            conversionMode: ConversionMode(rawValue: lyricConversionMode) ?? .none
        )
    }
}

extension LyricFormat {
    var labelKey: String {
        switch self {
        case .plainLrc: return "lyric_format_plain"
        case .verbatimLrc: return "lyric_format_verbatim"
        case .enhancedLrc: return "lyric_format_enhanced"
        case .ttml: return "lyric_format_ttml"
        }
    }
}

extension ConversionMode {
    var labelKey: String {
        switch self {
        case .none: return "chinese_conversion_mode_none"
        case .traditionalToSimplified: return "chinese_conversion_mode_traditional_to_simplified"
        case .simplifiedToTraditional: return "chinese_conversion_mode_simplified_to_traditional"
        }
    }
}

extension LyricLineTrack {
    var labelKey: String {
        switch self {
        case .original: return "lyric_line_original"
        case .romanization: return "lyric_line_romanization"
        case .translation: return "lyric_line_translation"
        }
    }
}

enum PluginSearch {
    /// Key of the cover url in plugin standard fields.
    static let coverKey = "cover_url"
    static let lyricsKey = "lyrics"

    static func fieldProcessor(_ config: LyricRenderConfig) -> PluginFieldPostProcessor {
        PluginFieldPostProcessor(GlobalFieldProcessSettings(scriptConversion: config.conversionMode, removeEmptyLines: config.removeEmptyLines))
    }

    /// Renders plugin lyrics with the user's lyric settings (Android: processLyrics + LyricEncoder.encode).
    static func render(_ lyrics: LyricsResult, pluginId: String, config: LyricRenderConfig) -> String? {
        let processed = (try? fieldProcessor(config).processLyrics(lyrics, config: PluginFieldProcessConfig(pluginId: pluginId))) ?? lyrics
        var c = config
        c.conversionMode = .none
        guard let text = try? LyricEncoder.encode(processed, config: c),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// Lyrics of a search result (Android: `getLyricsCandidates(song).firstOrNull()`).
    static func fetchLyrics(_ song: SongSearchResult, source: PluginSearchSource) async throws -> LyricsResult? {
        if let first = try await source.getLyricsCandidates(song: song, page: 1, pageSize: 1).first { return first.lyrics }
        return try await source.getLyrics(song: song)
    }

    static func supportsLyrics(_ source: PluginSearchSource) -> Bool { source.capabilities.contains(.getLyrics) }

    /// Standard fields of a result plus rendered lyrics, after the global field post-processing.
    static func processedFields(_ result: SongSearchResult, lyrics: String?, config: LyricRenderConfig) -> StringMap {
        var fields = result.normalizedFields()
        if let lyrics, !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields[lyricsKey] = lyrics }
        return fieldProcessor(config).processFields(pluginId: result.pluginId, fields: fields, config: PluginFieldProcessConfig(pluginId: result.pluginId))
    }

    /// Editor field for a plugin standard field key (cover is handled separately).
    static func editorKey(_ key: String) -> AudioTagFieldKey? {
        guard let f = StandardPluginField.fromKey(key) else { return nil }
        switch f {
        case .title: return .title
        case .artist: return .artist
        case .album: return .album
        case .albumArtist: return .albumArtist
        case .genre: return .genre
        case .date: return .date
        case .trackNumber: return .trackNumber
        case .discNumber: return .discNumber
        case .composer: return .composer
        case .lyricist: return .lyricist
        case .comment: return .comment
        case .lyrics: return .lyrics
        case .coverUrl: return nil
        case .language: return .language
        case .copyright: return .copyright
        case .rating: return .rating
        case .replayGainTrackGain: return .replayGainTrackGain
        case .replayGainTrackPeak: return .replayGainTrackPeak
        case .replayGainAlbumGain: return .replayGainAlbumGain
        case .replayGainAlbumPeak: return .replayGainAlbumPeak
        case .replayGainReferenceLoudness: return .replayGainReferenceLoudness
        }
    }

    static func label(forKey key: String) -> String {
        if key == coverKey { return L("label_cover") }
        if let k = editorKey(key) { return L(k.labelKey) }
        return key
    }

    /// Display order: cover, standard fields in host order, lyrics last.
    static func orderedKeys(_ fields: StringMap) -> [String] {
        var keys: [String] = []
        if fields[coverKey] != nil { keys.append(coverKey) }
        for f in StandardPluginField.allCases where f.key != coverKey && f.key != lyricsKey && fields[f.key] != nil { keys.append(f.key) }
        if fields[lyricsKey] != nil { keys.append(lyricsKey) }
        return keys
    }

    /// Writes `fields` restricted to `keys` into `data` (Android SearchResultApplier semantics:
    /// overwrite replaces, supplement only fills blank fields). Returns the keys that changed.
    @discardableResult
    static func apply(_ fields: StringMap, keys: Set<String>, overwrite: Bool, to data: inout AudioTagData) -> [String] {
        var changed: [String] = []
        for (key, raw) in fields.pairs where keys.contains(key) {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, let target = editorKey(key) else { continue }
            let current = target.value(in: data) ?? ""
            if !overwrite && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let normalized: String
            switch target {
            case .discNumber, .rating:
                let digits = value.split(separator: "/").first.map { String($0).filter(\.isNumber) } ?? ""
                guard let n = Int(digits) else { continue }
                normalized = String(n)
            default:
                normalized = value
            }
            if normalized == current { continue }
            target.set(normalized, in: &data)
            changed.append(key)
        }
        return changed
    }

    /// Downloads a cover image and re-encodes unsupported formats for tags.
    static func downloadImage(_ urlString: String) async throws -> Data {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("//") { s = "https:" + s }
        guard let url = URL(string: s) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard !data.isEmpty, UIImage(data: data) != nil else { throw URLError(.cannotDecodeContentData) }
        return ImageMime.normalizedForTag(data)
    }
}

// MARK: - Android MusicMatchUtils port

/// Local song facts used for match scoring (Android SongEntity subset).
struct MatchSong {
    var title: String?
    var artist: String?
    var album: String?
    var fileName: String
    var durationMs: Int64
}

struct MatchScoreDetail {
    var finalScore: Double
    var textScore: Double
}

enum MusicMatch {
    private static func regex(_ pattern: String, _ ci: Bool = false) -> NSRegularExpression {
        // Patterns are constants; a failure is a programming error.
        try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }

    private static let versionNoise = regex(
        #"[(\[（【《]?\s*(?:official\s*(?:video|audio|mv)|music\s*video|lyric[s]?\s*video|lyrics?|完整版|高清|无损|动态歌词|歌词版|instrumental|inst\.?|off\s*vocal|伴奏|纯音乐|live|现场版?|remix|remaster(?:ed)?|acoustic|cover|sped\s*up|slowed|nightcore|demo|edit|radio\s*edit|deluxe|bonus\s*track)\s*[)\]）】》]?"#,
        true)
    private static let segmentSplit = regex(
        #"\s*[-–—－/、,，&＆+×|｜]\s*|\s+_\s+|_-_|\s+(?:x|and|feat\.?|ft\.?|featuring|with)\s+"#, true)
    private static let brackets = regex(#"[【】\[\]（）()《》<>「」『』"'“”\-–—~·・]"#)
    private static let spaces = regex(#"\s+"#)
    private static let punct = regex(#"[._/\\|,:;，。！？!?#&＆]+"#)
    private static let trailingCopy = regex(#"\(\d+\)$"#)
    private static let leadingTrack = regex(#"^\d+[.\s\-_]+"#)

    private static func replace(_ s: String, _ r: NSRegularExpression, _ with: String) -> String {
        r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }

    private static func cleanNoise(_ s: String) -> String {
        var out = replace(s, versionNoise, " ")
        out = replace(out, brackets, " ")
        out = replace(out, spaces, " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalize(_ s: String) -> String {
        var out = cleanNoise(s).lowercased().replacingOccurrences(of: "\u{3000}", with: " ")
        out = replace(out, punct, " ")
        out = replace(out, spaces, " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compact(_ s: String) -> String { normalize(s).replacingOccurrences(of: " ", with: "") }

    private static func split(_ s: String, by r: NSRegularExpression) -> [String] {
        let ns = s as NSString
        var parts: [String] = []
        var last = 0
        for m in r.matches(in: s, range: NSRange(location: 0, length: ns.length)) where m.range.length > 0 {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    static func splitToSegments(_ s: String?) -> [String] {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<String>()
        return split(s, by: segmentSplit).map { cleanNoise($0) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func parseFileNameSegments(_ fileName: String) -> [String] {
        var name = (fileName as NSString).deletingPathExtension
        name = replace(name, trailingCopy, "")
        name = replace(name, leadingTrack, "")
        return splitToSegments(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Similarity

    private static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    private static func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        return 1 - Double(levenshtein(x, y)) / Double(max(x.count, y.count))
    }

    private static func charRemainderSimilarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var counts: [Unicode.Scalar: Int] = [:]
        for c in x { counts[c, default: 0] += 1 }
        var common = 0
        for c in y { if let n = counts[c], n > 0 { common += 1; counts[c] = n - 1 } }
        return min(1, max(0, 2.0 * Double(common) / Double(x.count + y.count)))
    }

    private static func containsSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let la = a.utf16.count, lb = b.utf16.count
        let shorter = la <= lb ? a : b, longer = la <= lb ? b : a
        guard longer.contains(shorter) else { return 0 }
        return 0.80 + 0.20 * Double(shorter.utf16.count) / Double(longer.utf16.count)
    }

    private static func tokenDice(_ a: String, _ b: String) -> Double {
        let ta = Set(a.split(whereSeparator: \.isWhitespace).map(String.init))
        let tb = Set(b.split(whereSeparator: \.isWhitespace).map(String.init))
        if ta.isEmpty && tb.isEmpty { return 1 }
        if ta.isEmpty || tb.isEmpty { return 0 }
        return min(1, 2.0 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count))
    }

    static func smartSimilarity(_ a: String?, _ b: String?) -> Double {
        let ab = a?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let bb = b?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if ab && bb { return 1 }
        if ab || bb { return 0 }
        let na = normalize(a!), nb = normalize(b!)
        if na.isEmpty && nb.isEmpty { return 1 }
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        let ca = compact(a!), cb = compact(b!)
        if ca == cb { return 1 }
        let containsScore = containsSimilarity(ca, cb)
        let charScore = charRemainderSimilarity(ca, cb)
        let levScore = levenshteinSimilarity(ca, cb)
        let dice = tokenDice(na, nb)
        let minLen = min(ca.utf16.count, cb.utf16.count)
        let blended = minLen <= 3
            ? charScore * 0.35 + levScore * 0.45 + dice * 0.20
            : charScore * 0.50 + levScore * 0.30 + dice * 0.20
        return min(1, max(0, max(containsScore, blended)))
    }

    static func segmentMatchScore(_ local: [String], _ title: String?, _ artist: String?) -> Double {
        guard !local.isEmpty else { return 0 }
        var seen = Set<String>()
        let remote = (splitToSegments(title) + splitToSegments(artist)).filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !remote.isEmpty else { return 0 }
        let localScores = local.map { l in remote.map { smartSimilarity(l, $0) }.max() ?? 0 }
        let resultScores = remote.map { r in local.map { smartSimilarity($0, r) }.max() ?? 0 }
        let localAvg = localScores.reduce(0, +) / Double(localScores.count)
        let resultAvg = resultScores.reduce(0, +) / Double(resultScores.count)
        let coverage = Double(localScores.filter { $0 >= 0.75 }.count) / Double(localScores.count)
        let strongHit = localScores.contains { $0 >= 0.90 } || coverage >= 0.75
        let score = localAvg * 0.50 + resultAvg * 0.25 + coverage * 0.25
        return min(1, max(0, strongHit ? score : score * 0.85))
    }

    private static func wholeMatchScore(_ local: [String], _ title: String?, _ artist: String?) -> Double {
        let remote = [title, artist].compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " ")
        return smartSimilarity(local.joined(separator: " "), remote)
    }

    private static func durationSimilarity(_ local: Int64, _ remote: Int64) -> Double? {
        guard local > 0, remote > 0 else { return nil }
        let diff = abs(local - remote)
        switch diff {
        case ...1500: return 1.0
        case ...3000: return 0.85
        case ...5000: return 0.60
        case ...8000: return 0.30
        case ...12000: return 0.10
        default: return 0
        }
    }

    private static func rankBonus(_ index: Int, _ textScore: Double, threshold: Double = 0.60, maxBonus: Double = 0.06) -> Double {
        guard index >= 0, textScore >= threshold else { return 0 }
        return maxBonus / Double(index + 1).squareRoot()
    }

    private static func usable(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !s.lowercased().contains("未知") else { return nil }
        return s
    }

    static func localSegments(_ song: MatchSong, preferFileName: Bool) -> [String] {
        if preferFileName {
            let raw = (song.fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.isEmpty ? [] : [raw]
        }
        var seen = Set<String>()
        let segs = (splitToSegments(usable(song.title)) + splitToSegments(usable(song.artist))).filter { !$0.isEmpty && seen.insert($0).inserted }
        return segs.isEmpty ? parseFileNameSegments(song.fileName) : segs
    }

    static func buildSearchQueries(_ song: MatchSong, preferFileName: Bool) -> [String] {
        let segments = localSegments(song, preferFileName: preferFileName)
        var out: [String] = []
        if !segments.isEmpty {
            out.append(segments.joined(separator: " "))
            if segments.count > 1 { out.append(contentsOf: segments.prefix(2)) }
        }
        if !preferFileName {
            let title = usable(song.title), artist = usable(song.artist)
            if let title, let artist {
                out.append("\(cleanNoise(title)) \(cleanNoise(artist))")
                out.append(cleanNoise(title))
            } else if let title {
                out.append(cleanNoise(title))
            }
        }
        var seen = Set<String>()
        return Array(out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }.prefix(5))
    }

    static func score(_ result: SongSearchResult, _ song: MatchSong, preferFileName: Bool, rankIndex: Int = -1) -> MatchScoreDetail {
        let local = localSegments(song, preferFileName: preferFileName)
        guard !local.isEmpty else { return MatchScoreDetail(finalScore: 0, textScore: 0) }
        let seg = segmentMatchScore(local, result.title, result.artist)
        let whole = wholeMatchScore(local, result.title, result.artist)
        let text = seg * 0.75 + whole * 0.25
        let combined: Double
        if let d = durationSimilarity(song.durationMs, result.duration) { combined = text * 0.88 + d * 0.12 } else { combined = text }
        let final = min(1, max(0, combined + rankBonus(rankIndex, text)))
        return MatchScoreDetail(finalScore: final, textScore: text)
    }
}
#endif
