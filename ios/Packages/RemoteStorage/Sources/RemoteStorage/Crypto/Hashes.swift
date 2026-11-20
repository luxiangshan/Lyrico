import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Hash algorithms needed by the providers (115 upload digests, HTTP Digest auth, OSS signatures).
/// Uses CryptoKit on Apple platforms and a portable Swift implementation elsewhere (Linux test runs).
enum HashKind { case sha1, md5, sha256 }

struct IncrementalHash {
    let kind: HashKind
    #if canImport(CryptoKit)
    private var sha1 = Insecure.SHA1()
    private var md5 = Insecure.MD5()
    private var sha256 = SHA256()
    #else
    private var portable: PortableHash
    #endif

    init(_ kind: HashKind) {
        self.kind = kind
        #if !canImport(CryptoKit)
        portable = PortableHash(kind)
        #endif
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { update($0) }
    }

    mutating func update(_ raw: UnsafeRawBufferPointer) {
        #if canImport(CryptoKit)
        switch kind {
        case .sha1: sha1.update(bufferPointer: raw)
        case .md5: md5.update(bufferPointer: raw)
        case .sha256: sha256.update(bufferPointer: raw)
        }
        #else
        portable.update(raw)
        #endif
    }

    /// Non-mutating: a copy is finalized, so the hash can continue (used for 115's 128 KiB pre-hash).
    func finalize() -> [UInt8] {
        #if canImport(CryptoKit)
        switch kind {
        case .sha1: return Array(sha1.finalize())
        case .md5: return Array(md5.finalize())
        case .sha256: return Array(sha256.finalize())
        }
        #else
        return portable.finalize()
        #endif
    }

    static func digest(_ kind: HashKind, _ data: Data) -> [UInt8] {
        var h = IncrementalHash(kind)
        h.update(data)
        return h.finalize()
    }

    static func digest(_ kind: HashKind, _ s: String) -> [UInt8] { digest(kind, Data(s.utf8)) }

    static var blockSize: Int { 64 }
}

enum Hex {
    private static let lower = Array("0123456789abcdef".utf8)
    static func lowerHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out = [UInt8]()
        for b in bytes { out.append(lower[Int(b >> 4)]); out.append(lower[Int(b & 0xF)]) }
        return String(decoding: out, as: UTF8.self)
    }
    static func upperHex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { lowerHex(bytes).uppercased() }

    static func decode(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        var out = [UInt8]()
        out.reserveCapacity(u.count / 2)
        var i = 0
        while i + 1 < u.count {
            out.append((RemotePaths.hexValue(u[i]) ?? 0) << 4 | (RemotePaths.hexValue(u[i + 1]) ?? 0))
            i += 2
        }
        return out
    }
}

enum HMAC_SHA1 {
    static func mac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key
        if k.count > 64 { k = IncrementalHash.digest(.sha1, Data(k)) }
        k += [UInt8](repeating: 0, count: 64 - k.count)
        var inner = IncrementalHash(.sha1)
        inner.update(k.map { $0 ^ 0x36 })
        inner.update(message)
        var outer = IncrementalHash(.sha1)
        outer.update(k.map { $0 ^ 0x5c })
        outer.update(inner.finalize())
        return outer.finalize()
    }
}

// MARK: - Portable implementations (also exercised by tests on every platform)

struct PortableHash {
    let kind: HashKind
    private var state: [UInt32]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    init(_ kind: HashKind) {
        self.kind = kind
        switch kind {
        case .sha1: state = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        case .md5: state = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476]
        case .sha256: state = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        }
        buffer.reserveCapacity(64)
    }

    mutating func update(_ raw: UnsafeRawBufferPointer) {
        let bytes = raw.bindMemory(to: UInt8.self)
        length &+= UInt64(bytes.count)
        var i = 0
        if !buffer.isEmpty {
            while i < bytes.count && buffer.count < 64 { buffer.append(bytes[i]); i += 1 }
            if buffer.count == 64 { buffer.withUnsafeBufferPointer { process($0, 0) }; buffer.removeAll(keepingCapacity: true) }
        }
        while i + 64 <= bytes.count { process(UnsafeBufferPointer(rebasing: bytes[i..<(i + 64)]), 0); i += 64 }
        while i < bytes.count { buffer.append(bytes[i]); i += 1 }
    }

    mutating func update(_ data: [UInt8]) { data.withUnsafeBytes { update($0) } }

    func finalize() -> [UInt8] {
        var copy = self
        let bitLen = length &* 8
        var pad: [UInt8] = [0x80]
        let rem = Int((length + 1) % 64)
        pad += [UInt8](repeating: 0, count: rem <= 56 ? 56 - rem : 120 - rem)
        var lenBytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<8 {
            if kind == .md5 { lenBytes[i] = UInt8(truncatingIfNeeded: bitLen >> (8 * UInt64(i))) }
            else { lenBytes[i] = UInt8(truncatingIfNeeded: bitLen >> (8 * UInt64(7 - i))) }
        }
        let savedLen = copy.length
        copy.update(pad + lenBytes)
        copy.length = savedLen
        var out = [UInt8]()
        for w in copy.state {
            if kind == .md5 { out += [UInt8(w & 0xff), UInt8(w >> 8 & 0xff), UInt8(w >> 16 & 0xff), UInt8(w >> 24)] }
            else { out += [UInt8(w >> 24), UInt8(w >> 16 & 0xff), UInt8(w >> 8 & 0xff), UInt8(w & 0xff)] }
        }
        return out
    }

    private mutating func process(_ block: UnsafeBufferPointer<UInt8>, _ off: Int) {
        switch kind {
        case .sha1: sha1Block(block)
        case .md5: md5Block(block)
        case .sha256: sha256Block(block)
        }
    }

    @inline(__always) private func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
    @inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func sha1Block(_ b: UnsafeBufferPointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 80)
        for i in 0..<16 {
            w[i] = UInt32(b[4 * i]) << 24 | UInt32(b[4 * i + 1]) << 16 | UInt32(b[4 * i + 2]) << 8 | UInt32(b[4 * i + 3])
        }
        for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
        var a = state[0], bb = state[1], c = state[2], d = state[3], e = state[4]
        for i in 0..<80 {
            let f: UInt32, k: UInt32
            switch i {
            case 0..<20: f = (bb & c) | (~bb & d); k = 0x5A827999
            case 20..<40: f = bb ^ c ^ d; k = 0x6ED9EBA1
            case 40..<60: f = (bb & c) | (bb & d) | (c & d); k = 0x8F1BBCDC
            default: f = bb ^ c ^ d; k = 0xCA62C1D6
            }
            let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = rotl(bb, 30); bb = a; a = t
        }
        state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d; state[4] &+= e
    }

    private static let md5S: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                         5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                         4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                         6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
    private static let md5K: [UInt32] = (0..<64).map { i in UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4294967296.0)) }

    private mutating func md5Block(_ b: UnsafeBufferPointer<UInt8>) {
        var m = [UInt32](repeating: 0, count: 16)
        for i in 0..<16 {
            m[i] = UInt32(b[4 * i]) | UInt32(b[4 * i + 1]) << 8 | UInt32(b[4 * i + 2]) << 16 | UInt32(b[4 * i + 3]) << 24
        }
        var a = state[0], bb = state[1], c = state[2], d = state[3]
        for i in 0..<64 {
            var f: UInt32
            let g: Int
            switch i {
            case 0..<16: f = (bb & c) | (~bb & d); g = i
            case 16..<32: f = (d & bb) | (~d & c); g = (5 * i + 1) % 16
            case 32..<48: f = bb ^ c ^ d; g = (3 * i + 5) % 16
            default: f = c ^ (bb | ~d); g = (7 * i) % 16
            }
            f = f &+ a &+ Self.md5K[i] &+ m[g]
            a = d; d = c; c = bb
            bb = bb &+ rotl(f, Self.md5S[i])
        }
        state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d
    }

    private static let k256: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private mutating func sha256Block(_ b: UnsafeBufferPointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            w[i] = UInt32(b[4 * i]) << 24 | UInt32(b[4 * i + 1]) << 16 | UInt32(b[4 * i + 2]) << 8 | UInt32(b[4 * i + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], bb = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = h &+ s1 &+ ch &+ Self.k256[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & bb) ^ (a & c) ^ (bb & c)
            let t2 = s0 &+ maj
            h = g; g = f; f = e; e = d &+ t1; d = c; c = bb; bb = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= bb; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
}

/// CRC-32 (IEEE, as java.util.zip.CRC32).
struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    private var crc: UInt32 = 0xFFFFFFFF
    mutating func update(_ bytes: [UInt8]) {
        for b in bytes { crc = Self.table[Int((crc ^ UInt32(b)) & 0xff)] ^ (crc >> 8) }
    }
    var value: UInt32 { crc ^ 0xFFFFFFFF }
}
