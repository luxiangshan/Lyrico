import Foundation

/// An order-preserving JSON tree that mirrors kotlinx.serialization's `JsonElement`.
///
/// Numbers keep their literal text (like `JsonPrimitive.content`), objects keep key order,
/// and serialization reproduces kotlinx's compact output so request/response payloads match
/// the Android host byte for byte.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public static func int(_ value: Int) -> JSONValue { .number(String(value)) }
    public static func int64(_ value: Int64) -> JSONValue { .number(String(value)) }
}

/// Ordered JSON object. Duplicate keys keep the first position and the last value.
public struct JSONObject: Equatable, Sendable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}
    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
}

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

// MARK: - Accessors mirroring kotlinx helpers

extension JSONValue {
    var objectValue: JSONObject? { if case .object(let o) = self { return o }; return nil }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }

    /// `JsonPrimitive` check (null counts as a primitive in kotlinx).
    var isPrimitive: Bool {
        switch self {
        case .null, .bool, .number, .string: return true
        default: return false
        }
    }

    /// `(this as? JsonPrimitive)?.contentOrNull`.
    var contentOrNull: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// `JsonPrimitive.longOrNull`.
    var longOrNull: Int64? { contentOrNull?.ktToLongOrNull }

    /// `JsonPrimitive.booleanOrNull`.
    var booleanOrNull: Bool? {
        guard let c = contentOrNull else { return nil }
        if c.caseInsensitiveCompare("true") == .orderedSame { return true }
        if c.caseInsensitiveCompare("false") == .orderedSame { return false }
        return nil
    }
}

// MARK: - Parsing

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = JSONTextParser(Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw JSONParseError(message: "Unexpected trailing JSON content at \(parser.index)")
        }
        return value
    }

    public static func parse(data: Data) throws -> JSONValue {
        try parse(String(decoding: data, as: UTF8.self))
    }
}

private struct JSONTextParser {
    let bytes: [UInt8]
    var index = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    func error(_ message: String) -> JSONParseError {
        JSONParseError(message: "\(message) at offset \(index)")
    }

    mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth < 512 else { throw error("JSON nesting too deep") }
        guard index < bytes.count else { throw error("Unexpected end of JSON") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try parseNumber())
        }
    }

    mutating func expect(_ word: String) throws {
        let w = Array(word.utf8)
        guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else {
            throw error("Unexpected JSON token")
        }
        index += w.count
    }

    mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue(depth: depth + 1)
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("Expected ',' or '}'")
        }
    }

    mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        var utf16Pending: [UInt16] = []
        func flushUTF16(_ buffer: inout [UInt8], _ pending: inout [UInt16]) {
            if pending.isEmpty { return }
            buffer.append(contentsOf: Array(String(decoding: pending, as: UTF16.self).utf8))
            pending.removeAll()
        }
        while true {
            guard index < bytes.count else { throw error("Unterminated string") }
            let b = bytes[index]
            if b == UInt8(ascii: "\"") {
                flushUTF16(&buffer, &utf16Pending)
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { throw error("Unterminated escape") }
                let e = bytes[index]
                index += 1
                if e == UInt8(ascii: "u") {
                    guard index + 4 <= bytes.count,
                          let code = UInt16(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
                        throw error("Invalid unicode escape")
                    }
                    index += 4
                    utf16Pending.append(code)
                    continue
                }
                flushUTF16(&buffer, &utf16Pending)
                switch e {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                default: throw error("Invalid escape")
                }
                continue
            }
            flushUTF16(&buffer, &utf16Pending)
            buffer.append(b)
            index += 1
        }
    }

    mutating func parseNumber() throws -> String {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var digits = 0
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; digits += 1 }
        guard digits > 0 else { throw error("Unexpected JSON token") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var frac = 0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; frac += 1 }
            guard frac > 0 else { throw error("Invalid number") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            var exp = 0
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1; exp += 1 }
            guard exp > 0 else { throw error("Invalid number") }
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}

// MARK: - Serialization (kotlinx compact style)

extension JSONValue {
    public var jsonString: String {
        var out = ""
        write(to: &out)
        return out
    }

    func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): JSONValue.writeQuoted(s, to: &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            var first = true
            for (k, v) in o {
                if !first { out += "," }
                first = false
                JSONValue.writeQuoted(k, to: &out)
                out += ":"
                v.write(to: &out)
            }
            out += "}"
        }
    }

    static func writeQuoted(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Builders

extension JSONObject {
    /// Kotlin `Map<String,String>` → JSON object.
    static func strings(_ map: OrderedMap<String, String>) -> JSONObject {
        JSONObject(map.pairs.map { ($0.0, JSONValue.string($0.1)) })
    }
}
