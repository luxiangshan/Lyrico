import Foundation

/// Minimal read-only ZIP reader (stored + deflate), enough for plugin packages.
struct ZipArchive {
    struct Entry {
        let name: String
        let isDirectory: Bool
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        let crc32: UInt32
    }

    let data: [UInt8]
    let entries: [Entry]

    init(data: [UInt8]) throws {
        self.data = data
        guard data.count >= 22 else { throw CodecError(description: "Not a ZIP archive") }
        var eocd = -1
        var i = data.count - 22
        let lowest = max(0, data.count - 22 - 65_535)
        while i >= lowest {
            if data[i] == 0x50, data[i + 1] == 0x4B, data[i + 2] == 0x05, data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw CodecError(description: "Not a ZIP archive") }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24 }
        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, u32(offset) == 0x02014B50 else { throw CodecError(description: "Corrupt ZIP central directory") }
            let flags = u16(offset + 8)
            let method = UInt16(u16(offset + 10))
            let crc = UInt32(u32(offset + 16))
            let compressed = u32(offset + 20)
            let uncompressed = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            guard offset + 46 + nameLength <= data.count else { throw CodecError(description: "Corrupt ZIP entry name") }
            let nameBytes = Array(data[(offset + 46)..<(offset + 46 + nameLength)])
            let name: String
            if flags & 0x800 != 0 {
                name = String(decoding: nameBytes, as: UTF8.self)
            } else {
                // ZipInputStream defaults to UTF-8 as well.
                name = String(decoding: nameBytes, as: UTF8.self)
            }
            entries.append(Entry(name: name, isDirectory: name.hasSuffix("/"), method: method,
                                 compressedSize: compressed, uncompressedSize: uncompressed,
                                 localHeaderOffset: local, crc32: crc))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    func contents(of entry: Entry, limit: Int) throws -> [UInt8] {
        let o = entry.localHeaderOffset
        guard o + 30 <= data.count, data[o] == 0x50, data[o + 1] == 0x4B, data[o + 2] == 0x03, data[o + 3] == 0x04 else {
            throw CodecError(description: "Corrupt ZIP local header: \(entry.name)")
        }
        let nameLength = Int(data[o + 26]) | Int(data[o + 27]) << 8
        let extraLength = Int(data[o + 28]) | Int(data[o + 29]) << 8
        let start = o + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw CodecError(description: "Truncated ZIP entry: \(entry.name)") }
        guard entry.uncompressedSize <= limit else { throw CodecError(description: "Archive is too large after extraction") }
        let compressed = Array(data[start..<(start + entry.compressedSize)])
        switch entry.method {
        case 0: return compressed
        case 8:
            let out = try Inflate.raw(compressed, expectedSize: entry.uncompressedSize)
            guard out.count <= limit else { throw CodecError(description: "Archive is too large after extraction") }
            return out
        default:
            throw CodecError(description: "Unsupported ZIP compression method \(entry.method): \(entry.name)")
        }
    }
}
