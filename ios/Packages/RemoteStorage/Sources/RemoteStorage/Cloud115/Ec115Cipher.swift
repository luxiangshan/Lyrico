import Foundation

/// ECDH(P-224) + AES cipher for 115's `uplb.115.com/4.0/initupload.php`.
///
/// Port of SheltonZhu/115driver pkg/crypto/ec115/cipher.go (via the Android `Ec115Cipher.kt`):
///  - shared secret = x(d * remotePub) (28 bytes); AES key = secret[0..<16], IV = secret[12..<28]
///  - request: AES-128-CBC/PKCS7
///  - response: AES-128-CBC no padding, then `[u16le len][lz4 block]` chunks
///  - query `k_ec` = `encodeToken`
struct Ec115Cipher {
    let key: [UInt8]
    let iv: [UInt8]
    /// 30 bytes: 0x1d, 0x02|0x03 (y parity), x(28).
    let pubKey: [UInt8]

    init(key: [UInt8], iv: [UInt8], pubKey: [UInt8]) {
        self.key = key; self.iv = iv; self.pubKey = pubKey
    }

    func encrypt(_ plain: [UInt8]) -> [UInt8] {
        AES128.cbcEncryptPKCS7(key: key, iv: iv, plain: plain)
    }

    func decrypt(_ cipherText: [UInt8]) throws -> [UInt8] {
        let usable = cipherText.count - cipherText.count % 16
        guard usable > 0 else { throw RemoteStorageError.io("115 upload init: empty encrypted response") }
        let plain = AES128.cbcDecryptNoPadding(key: key, iv: iv, cipher: Array(cipherText[0..<usable]))
        var out = [UInt8]()
        var pos = 0
        while pos + 2 <= plain.count {
            let len = Int(plain[pos]) | Int(plain[pos + 1]) << 8
            if len == 0 || pos + 2 + len > plain.count { break }
            out += try LZ4.decompressBlock(plain, offset: pos + 2, length: len)
            pos += 2 + len
        }
        return out
    }

    /// Builds the `k_ec` token. `r1`/`r2` are random mask bytes (tests pass 0).
    func encodeToken(timestamp: Int64, r1: UInt8 = UInt8.random(in: 0...255), r2: UInt8 = UInt8.random(in: 0...255)) -> String {
        let t = UInt32(truncatingIfNeeded: timestamp) // uint32 truncation, little endian (as 115driver)
        var tmp = [UInt8]()
        tmp.reserveCapacity(48)
        for i in 0..<15 { tmp.append(pubKey[i] ^ r1) }
        tmp.append(r1); tmp.append(0x73 ^ r1)
        tmp += [r1, r1, r1]
        for i in 0..<4 { tmp.append(UInt8(truncatingIfNeeded: t >> (8 * UInt32(i))) ^ r1) }
        for i in 15..<pubKey.count { tmp.append(pubKey[i] ^ r2) }
        tmp.append(r2); tmp.append(0x01 ^ r2)
        tmp += [r2, r2, r2]
        var crc = CRC32()
        crc.update(Self.crcSalt)
        crc.update(tmp)
        let c = crc.value
        for i in 0..<4 { tmp.append(UInt8(truncatingIfNeeded: c >> (8 * UInt32(i)))) }
        return Data(tmp).base64EncodedString()
    }

    static let crcSalt = Array("^j>WD3Kr?J2gLFjD4W2y@".utf8)

    static let remotePub: [UInt8] = [
        0x57, 0xA2, 0x92, 0x57, 0xCD, 0x23, 0x20, 0xE5, 0xD6, 0xD1, 0x43, 0x32, 0x2F, 0xA4, 0xBB, 0x8A,
        0x3C, 0xF9, 0xD3, 0xCC, 0x62, 0x3E, 0xF5, 0xED, 0xAC, 0x62, 0xB7, 0x67, 0x8A, 0x89, 0xC9, 0x1A,
        0x83, 0xBA, 0x80, 0x0D, 0x61, 0x29, 0xF5, 0x22, 0xD0, 0x34, 0xC8, 0x95, 0xDD, 0x24, 0x65, 0x24,
        0x3A, 0xDD, 0xC2, 0x50, 0x95, 0x3B, 0xEE, 0xBA,
    ]

    /// Fresh ephemeral key pair, as 115driver's NewEcdhCipher.
    static func create() -> Ec115Cipher {
        while true {
            let d = BigUInt(bytes: M115.randomBytes(28))
            if !d.isZero && d < P224.n, let c = try? fromPrivate(d) { return c }
        }
    }

    static func fromPrivate(_ d: BigUInt) throws -> Ec115Cipher {
        guard let pub = P224.mul(P224.g, d) else { throw RemoteStorageError.io("bad scalar") }
        let remote = P224.Point(x: BigUInt(bytes: remotePub[0..<28]), y: BigUInt(bytes: remotePub[28..<56]))
        guard let shared = P224.mul(remote, d) else { throw RemoteStorageError.io("bad shared point") }
        let secret = shared.x.bytes(length: 28)
        var pk = [UInt8](repeating: 0, count: 30)
        pk[0] = 29
        pk[1] = pub.y.testBit(0) ? 0x03 : 0x02
        pk.replaceSubrange(2..<30, with: pub.x.bytes(length: 28))
        return Ec115Cipher(key: Array(secret[0..<16]), iv: Array(secret[12..<28]), pubKey: pk)
    }
}

/// Minimal NIST P-224 (secp224r1) affine arithmetic for ECDH.
enum P224 {
    static let p = BigUInt(hex: "ffffffffffffffffffffffffffffffff000000000000000000000001")!
    static let a = p - BigUInt(3)
    static let b = BigUInt(hex: "b4050a850c04b3abf54132565044b0b7d7bfd8ba270b39432355ffb4")!
    static let n = BigUInt(hex: "ffffffffffffffffffffffffffff16a2e0b8f03e13dd29455c5c2a3d")!
    static let g = Point(
        x: BigUInt(hex: "b70e0cbd6bb4bf7f321390b94a03c1d356c21122343280d6115c1d21")!,
        y: BigUInt(hex: "bd376388b5f723fb4c22dfe6cd4375a05a07476444d5819985007e34")!
    )

    struct Point: Equatable {
        let x: BigUInt
        let y: BigUInt
    }

    static func isOnCurve(_ pt: Point) -> Bool {
        (pt.y * pt.y) % p == ((pt.x * pt.x % p) * pt.x + a * pt.x + b) % p
    }

    /// nil = point at infinity.
    static func add(_ pp: Point?, _ qq: Point?) -> Point? {
        guard let P = pp else { return qq }
        guard let Q = qq else { return pp }
        let lambda: BigUInt
        if P.x == Q.x {
            if ((P.y + Q.y) % p).isZero { return nil }
            let num = (P.x * P.x % p * BigUInt(3) + a) % p
            guard let inv = (P.y.shiftedLeft(1) % p).inverse(modulus: p) else { return nil }
            lambda = num * inv % p
        } else {
            guard let inv = BigUInt.subMod(Q.x, P.x, p).inverse(modulus: p) else { return nil }
            lambda = BigUInt.subMod(Q.y, P.y, p) * inv % p
        }
        let x = BigUInt.subMod(BigUInt.subMod(lambda * lambda % p, P.x, p), Q.x, p)
        let y = BigUInt.subMod(lambda * BigUInt.subMod(P.x, x, p) % p, P.y, p)
        return Point(x: x, y: y)
    }

    static func mul(_ pt: Point, _ k: BigUInt) -> Point? {
        var r: Point? = nil
        let bits = k.bitLength
        if bits == 0 { return nil }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            r = add(r, r)
            if k.testBit(i) { r = add(r, pt) }
        }
        return r
    }
}

/// LZ4 block-format decompressor (no frame header), enough for 115's small JSON responses.
enum LZ4 {
    static func decompressBlock(_ src: [UInt8], offset: Int, length: Int) throws -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(max(64, length * 4))
        var i = offset
        let end = offset + length
        while i < end {
            let token = Int(src[i]); i += 1
            var litLen = token >> 4
            if litLen == 15 {
                while true {
                    guard i < end else { throw RemoteStorageError.io("lz4: truncated literal length") }
                    let b = Int(src[i]); i += 1
                    litLen += b
                    if b != 255 { break }
                }
            }
            guard i + litLen <= end else { throw RemoteStorageError.io("lz4: literal overrun") }
            out += src[i..<(i + litLen)]
            i += litLen
            if i >= end { break } // last sequence has literals only
            guard i + 2 <= end else { throw RemoteStorageError.io("lz4: truncated offset") }
            let off = Int(src[i]) | Int(src[i + 1]) << 8
            i += 2
            guard off != 0, off <= out.count else { throw RemoteStorageError.io("lz4: bad offset") }
            var matchLen = token & 0x0f
            if matchLen == 15 {
                while true {
                    guard i < end else { throw RemoteStorageError.io("lz4: truncated match length") }
                    let b = Int(src[i]); i += 1
                    matchLen += b
                    if b != 255 { break }
                }
            }
            matchLen += 4
            var from = out.count - off
            for _ in 0..<matchLen { out.append(out[from]); from += 1 }
        }
        return out
    }
}
