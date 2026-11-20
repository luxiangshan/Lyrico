import Foundation

/// A Kotlin-`Regex`-like wrapper over `NSRegularExpression`.
///
/// Ranges are expressed in UTF-16 offsets, which is what Kotlin/Java use, so ported
/// substring arithmetic behaves the same. Patterns are written with explicit ASCII classes
/// (`[0-9]`, `[ \t\n\x0B\f\r]`) where Java's ASCII-only `\d`/`\s` semantics matter.
final class KRegex: @unchecked Sendable {
    struct Match {
        /// Whole match range (UTF-16).
        let range: NSRange
        /// `groupValues` like Kotlin: index 0 is the whole match, unmatched groups are "".
        let groupValues: [String]
        /// Optional groups (nil when not participating).
        let groups: [String?]
        var value: String { groupValues[0] }
        /// Kotlin `range.first`.
        var first: Int { range.location }
        /// Kotlin `range.last` (inclusive).
        var last: Int { range.location + range.length - 1 }
        var end: Int { range.location + range.length }
    }

    let pattern: String
    private let regex: NSRegularExpression
    private let entireRegex: NSRegularExpression

    init(_ pattern: String, ignoreCase: Bool = false) {
        self.pattern = pattern
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: pattern, options: options)
            entireRegex = try NSRegularExpression(pattern: "^(?:" + pattern + ")\\z", options: options)
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }

    private func makeMatch(_ result: NSTextCheckingResult, _ ns: NSString) -> Match {
        var values: [String] = []
        var groups: [String?] = []
        for i in 0..<result.numberOfRanges {
            let r = result.range(at: i)
            if r.location == NSNotFound {
                values.append(""); groups.append(nil)
            } else {
                let s = ns.substring(with: r)
                values.append(s); groups.append(s)
            }
        }
        return Match(range: result.range, groupValues: values, groups: groups)
    }

    func findAll(_ input: String) -> [Match] {
        let ns = input as NSString
        return regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
            .map { makeMatch($0, ns) }
    }

    func find(_ input: String, startIndex: Int = 0) -> Match? {
        let ns = input as NSString
        guard startIndex <= ns.length else { return nil }
        guard let r = regex.firstMatch(in: input, options: [], range: NSRange(location: startIndex, length: ns.length - startIndex)) else { return nil }
        return makeMatch(r, ns)
    }

    func containsMatch(_ input: String) -> Bool { find(input) != nil }

    func matchEntire(_ input: String) -> Match? {
        let ns = input as NSString
        guard let r = entireRegex.firstMatch(in: input, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return makeMatch(r, ns)
    }

    func matches(_ input: String) -> Bool { matchEntire(input) != nil }

    /// Replace every match with a literal string.
    func replace(_ input: String, with literal: String) -> String {
        replace(input) { _ in literal }
    }

    func replace(_ input: String, transform: (Match) -> String) -> String {
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return input }
        var out = ""
        var last = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(makeMatch(m, ns))
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Kotlin `CharSequence.split(Regex)` (keeps trailing empty strings).
    func split(_ input: String) -> [String] {
        let ns = input as NSString
        let matches = regex.matches(in: input, options: [], range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return [input] }
        var parts: [String] = []
        var last = 0
        for m in matches {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }
}

/// Java's ASCII-only `\s` character class content.
let jWhitespaceClass = "\\t\\n\\x{0B}\\f\\r "
