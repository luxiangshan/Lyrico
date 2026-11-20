import Foundation

/// Port of `LyricFormatter`.
public enum LyricFormatter {
    /// `([<\[])(\d{2,}):(\d{2})\.(\d{2,3})([>\]])`
    static let lrcTimePattern = KRegex("([<\\[])([0-9]{2,}):([0-9]{2})\\.([0-9]{2,3})([>\\]])")
    static let ttmlTimePattern = KRegex("(begin=\"|end=\")([0-9]{2,}):([0-9]{2}):([0-9]{2})\\.([0-9]{2,3})(\")")

    /// `mm:ss.SSS`
    public static func formatTimestamp(_ millis: Int64) -> String {
        let safe = max(millis, 0)
        let totalSeconds = safe / 1000
        return String(format: "%02lld:%02lld.%03lld", totalSeconds / 60, totalSeconds % 60, safe % 1000)
    }

    /// `HH:mm:ss.SSS`
    public static func formatTtmlTimestamp(_ millis: Int64) -> String {
        let safe = max(millis, 0)
        let totalSeconds = safe / 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", totalSeconds / 3600, (totalSeconds % 3600) / 60, totalSeconds % 60, safe % 1000)
    }

    public static func escapeXml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    public static func unescapeXml(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    public static func applyOffset(_ time: Int64, _ offset: Int64) -> Int64 { max(time + offset, 0) }
}

/// Port of `TtmlTime`.
enum TtmlTime {
    private static let milliseconds = KRegex("^([0-9]+(?:\\.[0-9]+)?)ms$")
    private static let seconds = KRegex("^([0-9]+(?:\\.[0-9]+)?)s$")
    private static let plainSeconds = KRegex("^([0-9]+(?:\\.[0-9]+)?)$")
    private static let clockHours = KRegex("^([0-9]+):([0-9]{2}):([0-9]{2})(?:\\.([0-9]+))?$")
    private static let clockMinutes = KRegex("^([0-9]+):([0-9]{2})(?:\\.([0-9]+))?$")

    static func parseMsOrNull(_ value: String?) -> Int64? {
        guard let text = value?.ktTrim(), !text.isEmpty else { return nil }
        if let m = milliseconds.matchEntire(text) { return finiteDouble(m.groupValues[1]).map { Int64(clampingDouble: $0) } }
        if let m = seconds.matchEntire(text) { return finiteDouble(m.groupValues[1]).map { Int64(clampingDouble: $0 * 1000) } }
        if let m = plainSeconds.matchEntire(text) { return finiteDouble(m.groupValues[1]).map { Int64(clampingDouble: $0 * 1000) } }
        if let m = clockHours.matchEntire(text) {
            return clockMs(m.groupValues[1], m.groupValues[2], m.groupValues[3], m.groupValues[4])
        }
        if let m = clockMinutes.matchEntire(text) {
            return clockMs("0", m.groupValues[1], m.groupValues[2], m.groupValues[3])
        }
        return nil
    }

    static func isValid(_ value: String?) -> Bool { parseMsOrNull(value) != nil }

    private static func clockMs(_ h: String, _ m: String, _ s: String, _ fraction: String) -> Int64? {
        guard let hours = Int64(h), let minutes = Int64(m), let secs = Int64(s) else { return nil }
        let (hm, o1) = hours.multipliedReportingOverflow(by: 3600)
        let (mm, o2) = minutes.multipliedReportingOverflow(by: 60)
        let (sum1, o3) = hm.addingReportingOverflow(mm)
        let (whole, o4) = sum1.addingReportingOverflow(secs)
        if o1 || o2 || o3 || o4 { return nil }
        var ms: Int64 = 0
        if !fraction.isEmpty {
            guard let v = Int64(fraction.ktPadEnd(3, "0").ktTake(3)) else { return nil }
            ms = v
        }
        let (wholeMs, o5) = whole.multipliedReportingOverflow(by: 1000)
        let (total, o6) = wholeMs.addingReportingOverflow(ms)
        if o5 || o6 { return nil }
        return total
    }

    private static func finiteDouble(_ s: String) -> Double? {
        guard let d = Double(s), d.isFinite else { return nil }
        return d
    }
}

extension Int64 {
    /// Kotlin `Double.toLong()` (truncating, saturating).
    init(clampingDouble d: Double) {
        if d.isNaN { self = 0 }
        else if d >= 9.223372036854775807e18 { self = .max }
        else if d <= -9.223372036854775808e18 { self = .min }
        else { self = Int64(d) }
    }
}

/// Simplified/Traditional Chinese conversion.
///
/// Android uses OpenCC (opencc4j). iOS has no OpenCC, so the default implementation uses the
/// ICU `Hant-Hans` / `Hans-Hant` transliterators that ship with the OS. Results match OpenCC for
/// common characters but may differ for phrase-level conversions; an app can plug in its own
/// converter through `ChineseConverter.custom`.
public enum ChineseConverter {
    public nonisolated(unsafe) static var custom: ((String, ConversionMode) -> String)?

    public static func convert(_ text: String, _ mode: ConversionMode) -> String {
        if mode == .none || text.isEmpty { return text }
        if let custom { return custom(text, mode) }
        let transform = mode == .traditionalToSimplified ? "Hant-Hans" : "Hans-Hant"
        return (text as NSString).applyingTransform(StringTransform(rawValue: transform), reverse: false) ?? text
    }
}
