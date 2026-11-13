import Foundation

// Helpers that reproduce the exact Kotlin/JVM string semantics the Android code relies on.
// Kotlin strings are UTF-16 based and its whitespace definition differs from Foundation's,
// so the ported algorithms go through these helpers instead of Foundation equivalents.

extension Unicode.Scalar {
    /// Kotlin `Char.isWhitespace()`: Java `isWhitespace || isSpaceChar`.
    var ktIsWhitespace: Bool {
        switch value {
        case 0x09...0x0D, 0x1C...0x1F: return true
        default: break
        }
        switch properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}

extension Character {
    var ktIsWhitespace: Bool {
        unicodeScalars.count == 1 && unicodeScalars.first!.ktIsWhitespace
    }
}

extension String {
    func hasScalar(_ c: Unicode.Scalar) -> Bool { unicodeScalars.contains(c) }

    /// Kotlin `isBlank()`.
    var ktIsBlank: Bool { unicodeScalars.allSatisfy { $0.ktIsWhitespace } }
    var ktIsNotBlank: Bool { !ktIsBlank }

    /// Kotlin `trim()`.
    func ktTrim() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.ktIsWhitespace }) else { return "" }
        let last = scalars.lastIndex(where: { !$0.ktIsWhitespace })!
        return String(scalars[first...last])
    }

    func ktTrimStart() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.ktIsWhitespace }) else { return "" }
        return String(scalars[first...])
    }

    func ktTrimEnd() -> String {
        let scalars = unicodeScalars
        guard let last = scalars.lastIndex(where: { !$0.ktIsWhitespace }) else { return "" }
        return String(scalars[...last])
    }

    /// Kotlin `trimStart(vararg chars)`.
    func ktTrimStart(chars: Set<Unicode.Scalar>) -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !chars.contains($0) }) else { return "" }
        return String(scalars[first...])
    }

    /// Kotlin `lines()` / `lineSequence()`: splits on CRLF, LF and CR.
    func ktLines() -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var iterator = unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = iterator.next()
        while let scalar = pending {
            pending = iterator.next()
            if scalar == "\r" {
                result.append(String(current)); current = String.UnicodeScalarView()
                if pending == "\n" { pending = iterator.next() }
            } else if scalar == "\n" {
                result.append(String(current)); current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    /// Kotlin `substringBefore(delimiter, missing)`.
    func ktSubstringBefore(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter) else { return missing ?? self }
        return String(self[..<range.lowerBound])
    }

    /// Kotlin `substringAfter(delimiter, missing)`.
    func ktSubstringAfter(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter) else { return missing ?? self }
        return String(self[range.upperBound...])
    }

    /// Kotlin `substringBeforeLast(delimiter, missing)`.
    func ktSubstringBeforeLast(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter, options: .backwards) else { return missing ?? self }
        return String(self[..<range.lowerBound])
    }

    func ktSubstringAfterLast(_ delimiter: String, missing: String? = nil) -> String {
        guard let range = range(of: delimiter, options: .backwards) else { return missing ?? self }
        return String(self[range.upperBound...])
    }

    /// Kotlin `contains(other, ignoreCase = true)`.
    func ktContainsIgnoreCase(_ other: String) -> Bool {
        if other.isEmpty { return true }
        return range(of: other, options: [.caseInsensitive]) != nil
    }

    /// Kotlin `padEnd(length, char)` (UTF-16 length based).
    func ktPadEnd(_ length: Int, _ pad: Character) -> String {
        let count = utf16.count
        if count >= length { return self }
        return self + String(repeating: pad, count: length - count)
    }

    /// Kotlin `take(n)` on UTF-16 units.
    func ktTake(_ n: Int) -> String {
        let units = Array(utf16)
        if units.count <= n { return self }
        return String(decoding: units[0..<n], as: UTF16.self)
    }

    /// Kotlin `String.toLongOrNull()`.
    var ktToLongOrNull: Int64? {
        if isEmpty { return nil }
        return Int64(self)
    }

    var ktToIntOrNull: Int32? {
        if isEmpty { return nil }
        return Int32(self)
    }

    /// Kotlin `String.toDoubleOrNull()` for the decimal forms used by TTML time values.
    var ktToDoubleOrNull: Double? { Double(self) }

    /// Number of UTF-16 code units, the Kotlin `length`.
    var ktLength: Int { utf16.count }

    func ktUTF16Substring(_ start: Int, _ end: Int) -> String {
        let ns = self as NSString
        return ns.substring(with: NSRange(location: start, length: end - start))
    }
}

extension Array {
    func getOrNull(_ index: Int) -> Element? {
        index >= 0 && index < count ? self[index] : nil
    }
}

extension Sequence {
    /// Kotlin `groupBy` keeping first-occurrence key order.
    func ktGroupBy<K: Hashable>(_ key: (Element) -> K) -> [(K, [Element])] {
        var order: [K] = []
        var groups: [K: [Element]] = [:]
        for element in self {
            let k = key(element)
            if groups[k] == nil { order.append(k); groups[k] = [element] } else { groups[k]!.append(element) }
        }
        return order.map { ($0, groups[$0]!) }
    }
}

extension Array where Element: Hashable {
    /// Kotlin `distinct()` preserving order.
    func ktDistinct() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

/// Insertion ordered map, mirroring Kotlin `LinkedHashMap` iteration order semantics.
public struct OrderedMap<Key: Hashable, Value> {
    public private(set) var keys: [Key] = []
    private var storage: [Key: Value] = [:]

    public init() {}
    public init(_ pairs: [(Key, Value)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }
    public var values: [Value] { keys.map { storage[$0]! } }
    public var pairs: [(Key, Value)] { keys.map { ($0, storage[$0]!) } }

    public mutating func putIfAbsent(_ key: Key, _ value: Value) {
        if storage[key] == nil { self[key] = value }
    }

    public func contains(_ key: Key) -> Bool { storage[key] != nil }
}

extension OrderedMap: Equatable where Value: Equatable {
    /// Map equality ignores order, like Kotlin `Map.equals`.
    public static func == (lhs: OrderedMap, rhs: OrderedMap) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension OrderedMap: Hashable where Value: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

extension OrderedMap: Sequence {
    public func makeIterator() -> AnyIterator<(key: Key, value: Value)> {
        var index = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            return (keys[index], storage[keys[index]]!)
        }
    }
}

extension OrderedMap: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (Key, Value)...) {
        self.init(elements.map { ($0.0, $0.1) })
    }
}

extension OrderedMap: @unchecked Sendable where Key: Sendable, Value: Sendable {}
