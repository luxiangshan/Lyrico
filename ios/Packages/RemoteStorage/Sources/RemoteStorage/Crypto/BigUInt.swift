import Foundation

/// Small arbitrary-precision unsigned integer (32-bit limbs, little endian), enough for the 1024-bit
/// "RSA" of m115 and the P-224 ECDH used by 115 uploads. Not constant-time (no secrets of the user are
/// processed: the m115 key is ephemeral and the 115 server keys are public).
struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    private(set) var limbs: [UInt32] // little endian, no trailing zero limbs (zero = [])

    init() { limbs = [] }

    init(_ v: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: v), UInt32(truncatingIfNeeded: v >> 32)]
        normalize()
    }

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    /// Big-endian bytes.
    init<C: Collection>(bytes: C) where C.Element == UInt8 {
        let b = Array(bytes)
        var l = [UInt32](repeating: 0, count: (b.count + 3) / 4)
        for (i, byte) in b.reversed().enumerated() {
            l[i / 4] |= UInt32(byte) << (8 * UInt32(i % 4))
        }
        self.init(limbs: l)
    }

    init?(hex: String) {
        let clean = hex.count % 2 == 1 ? "0" + hex : hex
        let bytes = Hex.decode(clean)
        guard bytes.count * 2 == clean.count else { return nil }
        self.init(bytes: bytes)
    }

    private mutating func normalize() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }
    var isOdd: Bool { (limbs.first ?? 0) & 1 == 1 }
    var isEven: Bool { !isOdd }

    var bitLength: Int {
        guard let last = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - last.leadingZeroBitCount)
    }

    func testBit(_ i: Int) -> Bool {
        let li = i / 32
        guard li < limbs.count else { return false }
        return (limbs[li] >> UInt32(i % 32)) & 1 == 1
    }

    /// Big-endian bytes, minimal length (empty for zero).
    var bytes: [UInt8] {
        var out = [UInt8]()
        for limb in limbs.reversed() {
            out += [UInt8(limb >> 24), UInt8(limb >> 16 & 0xff), UInt8(limb >> 8 & 0xff), UInt8(limb & 0xff)]
        }
        while let f = out.first, f == 0 { out.removeFirst() }
        return out
    }

    /// Big-endian bytes left-padded (or truncated to the low bytes) to `length`.
    func bytes(length: Int) -> [UInt8] {
        let b = bytes
        if b.count >= length { return Array(b.suffix(length)) }
        return [UInt8](repeating: 0, count: length - b.count) + b
    }

    var hex: String { isZero ? "0" : Hex.lowerHex(bytes) }
    var description: String { hex }

    static func < (a: BigUInt, b: BigUInt) -> Bool { compare(a.limbs, b.limbs) < 0 }

    private static func compare(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        var i = a.count - 1
        while i >= 0 {
            if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    static func + (a: BigUInt, b: BigUInt) -> BigUInt {
        let n = max(a.limbs.count, b.limbs.count)
        var out = [UInt32](repeating: 0, count: n + 1)
        var carry: UInt64 = 0
        for i in 0..<n {
            let s = UInt64(i < a.limbs.count ? a.limbs[i] : 0) + UInt64(i < b.limbs.count ? b.limbs[i] : 0) + carry
            out[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
        out[n] = UInt32(carry)
        return BigUInt(limbs: out)
    }

    /// a - b, requires a >= b.
    static func - (a: BigUInt, b: BigUInt) -> BigUInt {
        precondition(a >= b, "BigUInt underflow")
        var out = a.limbs
        var borrow: Int64 = 0
        for i in 0..<out.count {
            var d = Int64(out[i]) - Int64(i < b.limbs.count ? b.limbs[i] : 0) - borrow
            if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
            out[i] = UInt32(d)
        }
        return BigUInt(limbs: out)
    }

    static func * (a: BigUInt, b: BigUInt) -> BigUInt {
        if a.isZero || b.isZero { return BigUInt() }
        var out = [UInt32](repeating: 0, count: a.limbs.count + b.limbs.count)
        for i in 0..<a.limbs.count {
            var carry: UInt64 = 0
            let ai = UInt64(a.limbs[i])
            if ai == 0 { continue }
            for j in 0..<b.limbs.count {
                let t = ai * UInt64(b.limbs[j]) + UInt64(out[i + j]) + carry
                out[i + j] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
            }
            var k = i + b.limbs.count
            while carry != 0 {
                let t = UInt64(out[k]) + carry
                out[k] = UInt32(truncatingIfNeeded: t)
                carry = t >> 32
                k += 1
            }
        }
        return BigUInt(limbs: out)
    }

    func shiftedLeft(_ n: Int) -> BigUInt {
        if isZero || n == 0 { return self }
        let limbShift = n / 32, bitShift = UInt32(n % 32)
        var out = [UInt32](repeating: 0, count: limbs.count + limbShift + 1)
        for i in 0..<limbs.count {
            let v = UInt64(limbs[i]) << UInt64(bitShift)
            out[i + limbShift] |= UInt32(truncatingIfNeeded: v)
            out[i + limbShift + 1] |= UInt32(truncatingIfNeeded: v >> 32)
        }
        return BigUInt(limbs: out)
    }

    func shiftedRight(_ n: Int) -> BigUInt {
        let limbShift = n / 32, bitShift = UInt32(n % 32)
        if limbShift >= limbs.count { return BigUInt() }
        var out = [UInt32](repeating: 0, count: limbs.count - limbShift)
        for i in 0..<out.count {
            let lo = UInt64(limbs[i + limbShift])
            let hi = i + limbShift + 1 < limbs.count ? UInt64(limbs[i + limbShift + 1]) : 0
            out[i] = UInt32(truncatingIfNeeded: ((hi << 32) | lo) >> UInt64(bitShift))
        }
        return BigUInt(limbs: out)
    }

    /// Knuth algorithm D. Returns (quotient, remainder).
    func quotientAndRemainder(dividingBy d: BigUInt) -> (BigUInt, BigUInt) {
        precondition(!d.isZero, "division by zero")
        if self < d { return (BigUInt(), self) }
        if d.limbs.count == 1 {
            let dv = UInt64(d.limbs[0])
            var q = [UInt32](repeating: 0, count: limbs.count)
            var r: UInt64 = 0
            for i in stride(from: limbs.count - 1, through: 0, by: -1) {
                let cur = (r << 32) | UInt64(limbs[i])
                q[i] = UInt32(cur / dv)
                r = cur % dv
            }
            return (BigUInt(limbs: q), BigUInt(r))
        }
        let s = d.limbs.last!.leadingZeroBitCount
        let vn = d.shiftedLeft(s).limbs
        var un = self.shiftedLeft(s).limbs
        if un.count == limbs.count { un.append(0) }
        while un.count < limbs.count + 1 { un.append(0) }
        let n = vn.count, m = un.count - n
        var q = [UInt32](repeating: 0, count: m)
        let b: UInt64 = 1 << 32
        for j in stride(from: m - 1, through: 0, by: -1) {
            let num = (UInt64(un[j + n]) << 32) | UInt64(un[j + n - 1])
            var qhat = num / UInt64(vn[n - 1])
            var rhat = num % UInt64(vn[n - 1])
            while qhat >= b || qhat * UInt64(vn[n - 2]) > ((rhat << 32) | UInt64(un[j + n - 2])) {
                qhat -= 1
                rhat += UInt64(vn[n - 1])
                if rhat >= b { break }
            }
            // multiply and subtract
            var borrow: Int64 = 0
            var carry: UInt64 = 0
            for i in 0..<n {
                let p = qhat * UInt64(vn[i]) + carry
                carry = p >> 32
                let t = Int64(un[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
                un[i + j] = UInt32(truncatingIfNeeded: t)
                borrow = t < 0 ? 1 : 0
            }
            let t = Int64(un[j + n]) - borrow - Int64(carry)
            un[j + n] = UInt32(truncatingIfNeeded: t)
            if t < 0 {
                qhat -= 1
                var c: UInt64 = 0
                for i in 0..<n {
                    let s2 = UInt64(un[i + j]) + UInt64(vn[i]) + c
                    un[i + j] = UInt32(truncatingIfNeeded: s2)
                    c = s2 >> 32
                }
                un[j + n] = UInt32(truncatingIfNeeded: UInt64(un[j + n]) + c)
            }
            q[j] = UInt32(truncatingIfNeeded: qhat)
        }
        let rem = BigUInt(limbs: Array(un[0..<n])).shiftedRight(s)
        return (BigUInt(limbs: q), rem)
    }

    static func % (a: BigUInt, m: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: m).1 }
    static func / (a: BigUInt, m: BigUInt) -> BigUInt { a.quotientAndRemainder(dividingBy: m).0 }

    func power(_ e: BigUInt, modulus m: BigUInt) -> BigUInt {
        var result = BigUInt(1) % m
        let base = self % m
        let bits = e.bitLength
        if bits == 0 { return result }
        for i in stride(from: bits - 1, through: 0, by: -1) {
            result = (result * result) % m
            if e.testBit(i) { result = (result * base) % m }
        }
        return result
    }

    /// (a - b) mod m for a, b < m.
    static func subMod(_ a: BigUInt, _ b: BigUInt, _ m: BigUInt) -> BigUInt {
        a >= b ? a - b : (a + m) - b
    }

    /// Modular inverse for odd modulus m (binary extended Euclid). self must be non-zero mod m.
    func inverse(modulus m: BigUInt) -> BigUInt? {
        precondition(m.isOdd, "modulus must be odd")
        var u = self % m
        if u.isZero { return nil }
        var v = m
        var x1 = BigUInt(1), x2 = BigUInt()
        let one = BigUInt(1)
        while u != one && v != one {
            while u.isEven {
                u = u.shiftedRight(1)
                x1 = x1.isEven ? x1.shiftedRight(1) : (x1 + m).shiftedRight(1)
            }
            while v.isEven {
                v = v.shiftedRight(1)
                x2 = x2.isEven ? x2.shiftedRight(1) : (x2 + m).shiftedRight(1)
            }
            if u >= v {
                u = u - v
                x1 = BigUInt.subMod(x1, x2, m)
            } else {
                v = v - u
                x2 = BigUInt.subMod(x2, x1, m)
            }
            if u.isZero || v.isZero { return nil }
        }
        return u == one ? x1 % m : x2 % m
    }
}
