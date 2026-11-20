import Foundation

/// File digests used by 115 upload (port of 115driver pkg/crypto/digest.go and UploadDigestRange).
public enum Cloud115Hash {
    public static let preHashSize = 128 * 1024

    public struct Digest: Equatable, Sendable {
        public let size: Int64
        /// Upper-case hex SHA-1 of the first 128 KiB.
        public let preId: String
        /// Upper-case hex SHA-1 of the whole file (115 "fileid").
        public let sha1: String
        /// Base64 MD5 of the whole file (OSS Content-MD5).
        public let md5Base64: String
    }

    public static func digest(file: URL) throws -> Digest {
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        var sha = IncrementalHash(.sha1)
        var md5 = IncrementalHash(.md5)
        var preId: String?
        var total: Int64 = 0
        while true {
            let want = preId == nil ? min(64 * 1024, Int(Int64(preHashSize) - total)) : 1024 * 1024
            let chunk = fh.readData(ofLength: want)
            if chunk.isEmpty { break }
            sha.update(chunk); md5.update(chunk)
            total += Int64(chunk.count)
            if preId == nil && total >= Int64(preHashSize) {
                preId = Hex.upperHex(sha.finalize())
            }
        }
        let full = Hex.upperHex(sha.finalize())
        return Digest(size: total, preId: preId ?? full, sha1: full, md5Base64: Data(md5.finalize()).base64EncodedString())
    }

    /// SHA-1 (upper hex) of the inclusive byte range "start-end" (115 `sign_check`).
    public static func rangeSha1(file: URL, rangeSpec: String) throws -> String {
        let parts = rangeSpec.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let start = Int64(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(parts[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start else {
            throw RemoteStorageError.io("bad sign_check range: \(rangeSpec)")
        }
        let fh = try FileHandle(forReadingFrom: file)
        defer { try? fh.close() }
        try fh.seek(toOffset: UInt64(start))
        var sha = IncrementalHash(.sha1)
        var remaining = end - start + 1
        while remaining > 0 {
            let chunk = fh.readData(ofLength: Int(min(64 * 1024, remaining)))
            if chunk.isEmpty { throw RemoteStorageError.io("sign_check range beyond end of file") }
            sha.update(chunk)
            remaining -= Int64(chunk.count)
        }
        return Hex.upperHex(sha.finalize())
    }

    static func sha1Hex(_ s: String) -> String { Hex.lowerHex(IncrementalHash.digest(.sha1, s)) }
    static func md5Hex(_ s: String) -> String { Hex.lowerHex(IncrementalHash.digest(.md5, s)) }

    /// Upload `sig` (115driver GenerateSignature).
    public static func uploadSignature(userId: String, userKey: String, fileId: String, target: String) -> String {
        sha1Hex(userKey + sha1Hex(userId + fileId + target + "0") + "000000").uppercased()
    }

    /// Upload `token` (115driver GenerateToken).
    public static func uploadToken(userId: String, fileId: String, fileSize: String, signKey: String, signVal: String,
                                   timestamp: String, appVer: String) -> String {
        md5Hex(uploadMd5Salt + fileId + fileSize + signKey + signVal + userId + timestamp + md5Hex(userId) + appVer)
    }

    static let uploadMd5Salt = "Qclm8MGWUv59TnrR0XPg"
}
