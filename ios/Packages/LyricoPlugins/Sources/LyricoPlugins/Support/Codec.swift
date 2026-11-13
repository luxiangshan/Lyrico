import Foundation

struct CodecError: Error, CustomStringConvertible {
    let description: String
}

/// `android.util.Base64` compatible encoder/decoder.
enum AndroidBase64 {
    private static let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlSafe = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    /// `Base64.encodeToString(bytes, NO_WRAP)` and the URL_SAFE|NO_PADDING variant.
    static func encode(_ bytes: [UInt8], urlSafe url: Bool = false, padding: Bool = true) -> String {
        let alphabet = url ? urlSafe : standard
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var i = 0
        while i + 3 <= bytes.count {
            let v = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2])
            out.append(alphabet[Int(v >> 18 & 63)]); out.append(alphabet[Int(v >> 12 & 63)])
            out.append(alphabet[Int(v >> 6 & 63)]); out.append(alphabet[Int(v & 63)])
            i += 3
        }
        let rest = bytes.count - i
        if rest == 1 {
            let v = UInt32(bytes[i]) << 16
            out.append(alphabet[Int(v >> 18 & 63)]); out.append(alphabet[Int(v >> 12 & 63)])
            if padding { out.append(UInt8(ascii: "=")); out.append(UInt8(ascii: "=")) }
        } else if rest == 2 {
            let v = UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8
            out.append(alphabet[Int(v >> 18 & 63)]); out.append(alphabet[Int(v >> 12 & 63)])
            out.append(alphabet[Int(v >> 6 & 63)])
            if padding { out.append(UInt8(ascii: "=")) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `Base64.decode(text, DEFAULT)`: characters outside the alphabet are skipped,
    /// padding is optional, invalid padding placement throws `bad base-64`.
    static func decode(_ text: String) throws -> [UInt8] {
        var out: [UInt8] = []
        var state = 0
        var value: UInt32 = 0
        for c in text.utf8 {
            let d: Int
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): d = Int(c) - 65
            case UInt8(ascii: "a")...UInt8(ascii: "z"): d = Int(c) - 97 + 26
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = Int(c) - 48 + 52
            case UInt8(ascii: "+"): d = 62
            case UInt8(ascii: "/"): d = 63
            case UInt8(ascii: "="): d = -2
            default: d = -1
            }
            switch state {
            case 0, 1, 2, 3:
                if d >= 0 {
                    value = value << 6 | UInt32(d)
                    state += 1
                    if state == 4 {
                        out.append(UInt8(value >> 16 & 0xFF)); out.append(UInt8(value >> 8 & 0xFF)); out.append(UInt8(value & 0xFF))
                        state = 0; value = 0
                    }
                } else if d == -2 {
                    switch state {
                    case 2:
                        out.append(UInt8(value >> 4 & 0xFF))
                        state = 4 // expect a second '='
                    case 3:
                        out.append(UInt8(value >> 10 & 0xFF)); out.append(UInt8(value >> 2 & 0xFF))
                        state = 5
                    default:
                        throw CodecError(description: "java.lang.IllegalArgumentException: bad base-64")
                    }
                }
            case 4:
                if d == -2 { state = 5 } else if d != -1 { throw CodecError(description: "java.lang.IllegalArgumentException: bad base-64") }
            default:
                if d != -1 { throw CodecError(description: "java.lang.IllegalArgumentException: bad base-64") }
            }
        }
        switch state {
        case 1: throw CodecError(description: "java.lang.IllegalArgumentException: bad base-64")
        case 2: out.append(UInt8(value >> 4 & 0xFF))
        case 3: out.append(UInt8(value >> 10 & 0xFF)); out.append(UInt8(value >> 2 & 0xFF))
        case 4: throw CodecError(description: "java.lang.IllegalArgumentException: bad base-64")
        default: break
        }
        return out
    }

    static func toUrl(_ base64: String) -> String {
        var s = base64.ktTrim().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    static func fromUrl(_ base64Url: String) -> String {
        let normalized = base64Url.ktTrim().replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        switch normalized.utf16.count % 4 {
        case 2: return normalized + "=="
        case 3: return normalized + "="
        default: return normalized
        }
    }
}

/// Pure Swift DEFLATE decoder (RFC 1951) plus zlib (RFC 1950) and ZIP helpers.
enum Inflate {
    /// `java.util.zip.Inflater()` semantics used by the host API: zlib wrapper required;
    /// a truncated stream yields the bytes decoded so far.
    static func zlib(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= 2 else { return [] }
        let cmf = data[0], flg = data[1]
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw CodecError(description: "java.util.zip.DataFormatException: incorrect header check")
        }
        guard flg & 0x20 == 0 else {
            throw CodecError(description: "java.util.zip.DataFormatException: need dictionary")
        }
        var inflater = RawInflater(data, offset: 2)
        let output = try inflater.run(allowTruncated: true)
        if inflater.finished {
            let end = inflater.alignedByteOffset
            if end + 4 <= data.count {
                let expected = UInt32(data[end]) << 24 | UInt32(data[end + 1]) << 16 | UInt32(data[end + 2]) << 8 | UInt32(data[end + 3])
                if expected != adler32(output) {
                    throw CodecError(description: "java.util.zip.DataFormatException: incorrect data check")
                }
            }
        }
        return output
    }

    /// Raw DEFLATE (ZIP method 8).
    static func raw(_ data: [UInt8], expectedSize: Int? = nil) throws -> [UInt8] {
        var inflater = RawInflater(data, offset: 0)
        if let expectedSize { inflater.output.reserveCapacity(expectedSize) }
        return try inflater.run(allowTruncated: false)
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for chunkStart in stride(from: 0, to: data.count, by: 5552) {
            for byte in data[chunkStart..<min(chunkStart + 5552, data.count)] {
                a += UInt32(byte); b += a
            }
            a %= 65521; b %= 65521
        }
        return b << 16 | a
    }
}

private struct TruncatedInput: Error {}

private struct Huffman {
    var counts = [Int](repeating: 0, count: 16)
    var symbols: [Int]

    init(lengths: [Int]) throws {
        symbols = [Int](repeating: 0, count: lengths.count)
        for l in lengths { counts[l] += 1 }
        counts[0] = 0
        var left = 1
        for len in 1..<16 {
            left <<= 1
            left -= counts[len]
            if left < 0 { throw CodecError(description: "java.util.zip.DataFormatException: invalid code lengths set") }
        }
        var offsets = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offsets[len + 1] = offsets[len] + counts[len] }
        for (symbol, l) in lengths.enumerated() where l != 0 {
            symbols[offsets[l]] = symbol
            offsets[l] += 1
        }
    }
}

private struct RawInflater {
    let input: [UInt8]
    var position: Int
    var bitBuffer: UInt32 = 0
    var bitCount = 0
    var output: [UInt8] = []
    var finished = false

    init(_ input: [UInt8], offset: Int) {
        self.input = input
        self.position = offset
    }

    var alignedByteOffset: Int { position }

    mutating func bits(_ need: Int) throws -> Int {
        var value = bitBuffer
        while bitCount < need {
            guard position < input.count else { throw TruncatedInput() }
            value |= UInt32(input[position]) << UInt32(bitCount)
            position += 1
            bitCount += 8
        }
        bitBuffer = value >> UInt32(need)
        bitCount -= need
        return Int(value & ((1 << UInt32(need)) - 1))
    }

    mutating func decode(_ h: Huffman) throws -> Int {
        var code = 0, first = 0, index = 0
        for len in 1..<16 {
            code |= try bits(1)
            let count = h.counts[len]
            if code - count < first { return h.symbols[index + (code - first)] }
            index += count
            first += count
            first <<= 1
            code <<= 1
        }
        throw CodecError(description: "java.util.zip.DataFormatException: invalid code")
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static let fixedTables: (Huffman, Huffman) = {
        var lengths = [Int](repeating: 8, count: 288)
        for i in 144..<256 { lengths[i] = 9 }
        for i in 256..<280 { lengths[i] = 7 }
        let lit = try! Huffman(lengths: lengths)
        let dist = try! Huffman(lengths: [Int](repeating: 5, count: 30))
        return (lit, dist)
    }()

    mutating func run(allowTruncated: Bool) throws -> [UInt8] {
        do {
            var last = 0
            repeat {
                last = try bits(1)
                let type = try bits(2)
                switch type {
                case 0: try stored()
                case 1: try codes(RawInflater.fixedTables.0, RawInflater.fixedTables.1)
                case 2:
                    let (l, d) = try dynamicTables()
                    try codes(l, d)
                default: throw CodecError(description: "java.util.zip.DataFormatException: invalid block type")
                }
            } while last == 0
            finished = true
            bitBuffer = 0
            bitCount = 0
        } catch is TruncatedInput {
            if !allowTruncated { throw CodecError(description: "Unexpected end of DEFLATE stream") }
        }
        return output
    }

    mutating func stored() throws {
        bitBuffer = 0
        bitCount = 0
        guard position + 4 <= input.count else { throw TruncatedInput() }
        let len = Int(input[position]) | Int(input[position + 1]) << 8
        let nlen = Int(input[position + 2]) | Int(input[position + 3]) << 8
        guard len == (~nlen & 0xFFFF) else { throw CodecError(description: "java.util.zip.DataFormatException: invalid stored block lengths") }
        position += 4
        let available = min(len, input.count - position)
        output.append(contentsOf: input[position..<position + available])
        position += available
        if available < len { throw TruncatedInput() }
    }

    mutating func codes(_ lencode: Huffman, _ distcode: Huffman) throws {
        while true {
            let symbol = try decode(lencode)
            if symbol < 256 {
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let s = symbol - 257
                guard s < 29 else { throw CodecError(description: "java.util.zip.DataFormatException: invalid literal/length code") }
                let len = RawInflater.lengthBase[s] + (try bits(RawInflater.lengthExtra[s]))
                let ds = try decode(distcode)
                guard ds < 30 else { throw CodecError(description: "java.util.zip.DataFormatException: invalid distance code") }
                let dist = RawInflater.distBase[ds] + (try bits(RawInflater.distExtra[ds]))
                guard dist <= output.count else { throw CodecError(description: "java.util.zip.DataFormatException: invalid distance too far back") }
                let start = output.count - dist
                for i in 0..<len { output.append(output[start + i]) }
            }
        }
    }

    mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw CodecError(description: "java.util.zip.DataFormatException: too many length or distance symbols") }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = [Int](repeating: 0, count: 19)
        for i in 0..<ncode { lengths[order[i]] = try bits(3) }
        let lencode = try Huffman(lengths: lengths)
        var all = [Int](repeating: 0, count: nlen + ndist)
        var index = 0
        while index < nlen + ndist {
            var symbol = try decode(lencode)
            if symbol < 16 {
                all[index] = symbol; index += 1
            } else {
                var len = 0
                if symbol == 16 {
                    guard index > 0 else { throw CodecError(description: "java.util.zip.DataFormatException: invalid bit length repeat") }
                    len = all[index - 1]
                    symbol = 3 + (try bits(2))
                } else if symbol == 17 {
                    symbol = 3 + (try bits(3))
                } else {
                    symbol = 11 + (try bits(7))
                }
                guard index + symbol <= nlen + ndist else { throw CodecError(description: "java.util.zip.DataFormatException: invalid bit length repeat") }
                for _ in 0..<symbol { all[index] = len; index += 1 }
            }
        }
        return (try Huffman(lengths: Array(all[0..<nlen])), try Huffman(lengths: Array(all[nlen...])))
    }
}
