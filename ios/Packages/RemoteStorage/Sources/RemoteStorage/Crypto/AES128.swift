import Foundation

/// AES-128 block cipher with CBC helpers (portable; only used for 115's small upload-init payloads).
struct AES128 {
    private var roundKeys: [UInt8] // 176 bytes

    private static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        repeat {
            // multiply p by 3
            p = p ^ (p << 1) ^ ((p & 0x80) != 0 ? 0x1B : 0)
            // divide q by 3
            q ^= q << 1; q ^= q << 2; q ^= q << 4
            if (q & 0x80) != 0 { q ^= 0x09 }
            let x = q ^ rotl8(q, 1) ^ rotl8(q, 2) ^ rotl8(q, 3) ^ rotl8(q, 4)
            s[Int(p)] = x ^ 0x63
        } while p != 1
        s[0] = 0x63
        return s
    }()

    private static let invSbox: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()

    @inline(__always) private static func rotl8(_ x: UInt8, _ n: UInt8) -> UInt8 { (x << n) | (x >> (8 - n)) }

    @inline(__always) private static func xtime(_ x: UInt8) -> UInt8 { (x << 1) ^ ((x & 0x80) != 0 ? 0x1B : 0) }

    @inline(__always) private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var a = a, b = b, r: UInt8 = 0
        while b != 0 {
            if (b & 1) != 0 { r ^= a }
            a = xtime(a)
            b >>= 1
        }
        return r
    }

    init(key: [UInt8]) {
        precondition(key.count == 16, "AES-128 key must be 16 bytes")
        var w = key
        var rcon: UInt8 = 1
        while w.count < 176 {
            var t = Array(w[(w.count - 4)...])
            if w.count % 16 == 0 {
                t = [t[1], t[2], t[3], t[0]].map { Self.sbox[Int($0)] }
                t[0] ^= rcon
                rcon = Self.xtime(rcon)
            }
            for i in 0..<4 { w.append(w[w.count - 16] ^ t[i]) }
        }
        roundKeys = w
    }

    func encryptBlock(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var s = Array(input)
        addRoundKey(&s, 0)
        for round in 1..<10 {
            subBytes(&s); shiftRows(&s); mixColumns(&s); addRoundKey(&s, round)
        }
        subBytes(&s); shiftRows(&s); addRoundKey(&s, 10)
        return s
    }

    func decryptBlock(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var s = Array(input)
        addRoundKey(&s, 10)
        for round in stride(from: 9, through: 1, by: -1) {
            invShiftRows(&s); invSubBytes(&s); addRoundKey(&s, round); invMixColumns(&s)
        }
        invShiftRows(&s); invSubBytes(&s); addRoundKey(&s, 0)
        return s
    }

    private func addRoundKey(_ s: inout [UInt8], _ round: Int) {
        for i in 0..<16 { s[i] ^= roundKeys[round * 16 + i] }
    }
    private func subBytes(_ s: inout [UInt8]) { for i in 0..<16 { s[i] = Self.sbox[Int(s[i])] } }
    private func invSubBytes(_ s: inout [UInt8]) { for i in 0..<16 { s[i] = Self.invSbox[Int(s[i])] } }

    // State is column-major: s[r + 4c]
    private func shiftRows(_ s: inout [UInt8]) {
        let t = s
        for r in 1..<4 { for c in 0..<4 { s[r + 4 * c] = t[r + 4 * ((c + r) % 4)] } }
    }
    private func invShiftRows(_ s: inout [UInt8]) {
        let t = s
        for r in 1..<4 { for c in 0..<4 { s[r + 4 * ((c + r) % 4)] = t[r + 4 * c] } }
    }
    private func mixColumns(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3]
            s[4 * c] = Self.mul(a0, 2) ^ Self.mul(a1, 3) ^ a2 ^ a3
            s[4 * c + 1] = a0 ^ Self.mul(a1, 2) ^ Self.mul(a2, 3) ^ a3
            s[4 * c + 2] = a0 ^ a1 ^ Self.mul(a2, 2) ^ Self.mul(a3, 3)
            s[4 * c + 3] = Self.mul(a0, 3) ^ a1 ^ a2 ^ Self.mul(a3, 2)
        }
    }
    private func invMixColumns(_ s: inout [UInt8]) {
        for c in 0..<4 {
            let a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3]
            s[4 * c] = Self.mul(a0, 14) ^ Self.mul(a1, 11) ^ Self.mul(a2, 13) ^ Self.mul(a3, 9)
            s[4 * c + 1] = Self.mul(a0, 9) ^ Self.mul(a1, 14) ^ Self.mul(a2, 11) ^ Self.mul(a3, 13)
            s[4 * c + 2] = Self.mul(a0, 13) ^ Self.mul(a1, 9) ^ Self.mul(a2, 14) ^ Self.mul(a3, 11)
            s[4 * c + 3] = Self.mul(a0, 11) ^ Self.mul(a1, 13) ^ Self.mul(a2, 9) ^ Self.mul(a3, 14)
        }
    }

    /// AES-128-CBC with PKCS#7 padding.
    static func cbcEncryptPKCS7(key: [UInt8], iv: [UInt8], plain: [UInt8]) -> [UInt8] {
        let aes = AES128(key: key)
        let padLen = 16 - plain.count % 16
        let data = plain + [UInt8](repeating: UInt8(padLen), count: padLen)
        var prev = iv
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var i = 0
        while i < data.count {
            var block = Array(data[i..<(i + 16)])
            for j in 0..<16 { block[j] ^= prev[j] }
            prev = aes.encryptBlock(block[...])
            out += prev
            i += 16
        }
        return out
    }

    /// AES-128-CBC without padding removal (input must be whole blocks).
    static func cbcDecryptNoPadding(key: [UInt8], iv: [UInt8], cipher: [UInt8]) -> [UInt8] {
        let aes = AES128(key: key)
        var prev = iv
        var out = [UInt8]()
        out.reserveCapacity(cipher.count)
        var i = 0
        while i + 16 <= cipher.count {
            let block = cipher[i..<(i + 16)]
            var p = aes.decryptBlock(block)
            for j in 0..<16 { p[j] ^= prev[j] }
            out += p
            prev = Array(block)
            i += 16
        }
        return out
    }

    /// AES-128-CBC encryption without padding (input must be whole blocks). Test helper.
    static func cbcEncryptNoPadding(key: [UInt8], iv: [UInt8], plain: [UInt8]) -> [UInt8] {
        let aes = AES128(key: key)
        var prev = iv
        var out = [UInt8]()
        var i = 0
        while i + 16 <= plain.count {
            var block = Array(plain[i..<(i + 16)])
            for j in 0..<16 { block[j] ^= prev[j] }
            prev = aes.encryptBlock(block[...])
            out += prev
            i += 16
        }
        return out
    }

    /// AES-128-CBC decrypt + PKCS#7 unpad. Test helper.
    static func cbcDecryptPKCS7(key: [UInt8], iv: [UInt8], cipher: [UInt8]) -> [UInt8]? {
        let p = cbcDecryptNoPadding(key: key, iv: iv, cipher: cipher)
        guard let last = p.last, last >= 1, last <= 16, Int(last) <= p.count else { return nil }
        return Array(p.dropLast(Int(last)))
    }
}
