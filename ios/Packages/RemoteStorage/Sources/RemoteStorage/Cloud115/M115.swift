import Foundation

/// 115 "m115" payload cipher used by the proapi download-url endpoint.
///
/// Port of SheltonZhu/115driver pkg/crypto/m115 (via the Android `M115.kt`). The request body is
/// `data=<encode(json, key)>`; the response `data` field is decoded with `decode` and the same key.
/// The RSA "decrypt" uses the public exponent: the server signs with its private key.
public enum M115 {
    public static let keySize = 16

    static let n = BigUInt(hex:
        "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b86021" +
        "36477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad633" +
        "8c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f1" +
        "0a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683")!
    static let e = BigUInt(0x10001)
    static let keyLength = 128 // n.bitLength / 8

    static let xorKeySeed: [UInt8] = [
        0xf0, 0xe5, 0x69, 0xae, 0xbf, 0xdc, 0xbf, 0x8a, 0x1a, 0x45, 0xe8, 0xbe, 0x7d, 0xa6, 0x73, 0xb8,
        0xde, 0x8f, 0xe7, 0xc4, 0x45, 0xda, 0x86, 0xc4, 0x9b, 0x64, 0x8b, 0x14, 0x6a, 0xb4, 0xf1, 0xaa,
        0x38, 0x01, 0x35, 0x9e, 0x26, 0x69, 0x2c, 0x86, 0x00, 0x6b, 0x4f, 0xa5, 0x36, 0x34, 0x62, 0xa6,
        0x2a, 0x96, 0x68, 0x18, 0xf2, 0x4a, 0xfd, 0xbd, 0x6b, 0x97, 0x8f, 0x4d, 0x8f, 0x89, 0x13, 0xb7,
        0x6c, 0x8e, 0x93, 0xed, 0x0e, 0x0d, 0x48, 0x3e, 0xd7, 0x2f, 0x88, 0xd8, 0xfe, 0xfe, 0x7e, 0x86,
        0x50, 0x95, 0x4f, 0xd1, 0xeb, 0x83, 0x26, 0x34, 0xdb, 0x66, 0x7b, 0x9c, 0x7e, 0x9d, 0x7a, 0x81,
        0x32, 0xea, 0xb6, 0x33, 0xde, 0x3a, 0xa9, 0x59, 0x34, 0x66, 0x3b, 0xaa, 0xba, 0x81, 0x60, 0x48,
        0xb9, 0xd5, 0x81, 0x9c, 0xf8, 0x6c, 0x84, 0x77, 0xff, 0x54, 0x78, 0x26, 0x5f, 0xbe, 0xe8, 0x1e,
        0x36, 0x9f, 0x34, 0x80, 0x5c, 0x45, 0x2c, 0x9b, 0x76, 0xd5, 0x1b, 0x8f, 0xcc, 0xc3, 0xb8, 0xf5,
    ]

    static let xorClientKey: [UInt8] = [0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18, 0x4c, 0x01, 0x3f, 0x46]

    public static func generateKey() -> [UInt8] { randomBytes(keySize) }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// Encodes `input` with client `key` (16 bytes). `padSource` fills RSA padding bytes (tests inject it).
    public static func encode(_ input: [UInt8], key: [UInt8], padSource: ((Int) -> [UInt8])? = nil) -> String {
        precondition(key.count == keySize)
        var body = input
        xorTransform(&body, xorDeriveKey(key, 4))
        body.reverse()
        xorTransform(&body, xorClientKey)
        let buf = key + body
        return Data(rsaEncrypt(buf, padSource: padSource ?? { randomBytes($0) })).base64EncodedString()
    }

    /// Decodes a server response (base64) using the client `key` that encoded the request.
    public static func decode(_ input: String, key: [UInt8]) throws -> [UInt8] {
        guard let raw = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines), options: .ignoreUnknownCharacters) else {
            throw RemoteStorageError.io("m115: invalid base64 payload")
        }
        return try decodeXor(rsaDecrypt(Array(raw)), key: key)
    }

    /// XOR stage of `decode`, after RSA: the first 16 bytes are the server key.
    static func decodeXor(_ data: [UInt8], key: [UInt8]) throws -> [UInt8] {
        guard data.count >= keySize else { throw RemoteStorageError.io("m115 payload too short") }
        var out = Array(data[keySize...])
        xorTransform(&out, xorDeriveKey(Array(data[0..<keySize]), 12))
        out.reverse()
        xorTransform(&out, xorDeriveKey(key, 4))
        return out
    }

    static func xorDeriveKey(_ seed: [UInt8], _ size: Int) -> [UInt8] {
        (0..<size).map { i in
            let v = (Int(seed[i]) + Int(xorKeySeed[size * i])) & 0xff
            return UInt8(v ^ Int(xorKeySeed[size * (size - i - 1)]))
        }
    }

    static func xorTransform(_ data: inout [UInt8], _ key: [UInt8]) {
        let mod = data.count % 4
        for i in 0..<mod { data[i] ^= key[i % key.count] }
        if mod < data.count {
            for i in mod..<data.count { data[i] ^= key[(i - mod) % key.count] }
        }
    }

    static func rsaEncrypt(_ input: [UInt8], padSource: (Int) -> [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var pos = 0
        while pos < input.count {
            let slice = min(keyLength - 11, input.count - pos)
            let chunk = input[pos..<(pos + slice)]
            let padSize = keyLength - chunk.count - 3
            let pad = padSource(padSize)
            var msg = [UInt8](repeating: 0, count: keyLength)
            msg[1] = 2
            for i in 0..<padSize { msg[2 + i] = UInt8((Int(pad[i]) % 0xff) + 1) }
            msg[padSize + 2] = 0
            msg.replaceSubrange((padSize + 3)..<keyLength, with: chunk)
            out += BigUInt(bytes: msg).power(e, modulus: n).bytes(length: keyLength)
            pos += slice
        }
        return out
    }

    static func rsaDecrypt(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        var pos = 0
        while pos < input.count {
            let slice = min(keyLength, input.count - pos)
            let ret = BigUInt(bytes: input[pos..<(pos + slice)]).power(e, modulus: n).bytes
            // Strip PKCS#1 v1.5 padding: plaintext starts after the first zero byte (index > 0).
            if ret.count > 1 {
                for i in 1..<ret.count where ret[i] == 0 {
                    out += ret[(i + 1)...]
                    break
                }
            }
            pos += slice
        }
        return out
    }
}
