import Foundation

/// Reads `length` bytes of a remote file starting at `offset` (synchronous; see `RemoteBlockReader`).
public typealias RemoteRangeSource = @Sendable (_ offset: Int64, _ length: Int64) throws -> Data

/// Process-wide LRU of fixed-size blocks of remote files, shared by every `RemoteBlockReader`.
/// A block is identified by `fileKey` (configId|path|size|mtime, so a changed file never hits stale blocks)
/// and its index. Thread-safe.
public final class RemoteBlockCache: @unchecked Sendable {
    public static let defaultBlockSize = 256 * 1024
    /// 64 × 256 KB = 16 MB across all files (a tag read typically touches 1–3 blocks of a file).
    public static let defaultMaxBlocks = 64

    public let blockSize: Int
    private let maxBlocks: Int
    private let lock = NSLock()

    private struct Key: Hashable { let fileKey: String; let index: Int64 }
    private final class Node {
        let key: Key
        var data: Data
        var prev: Node?
        var next: Node?
        init(key: Key, data: Data) { self.key = key; self.data = data }
    }

    private var map: [Key: Node] = [:]
    private var head: Node? // most recent
    private var tail: Node? // least recent

    public init(blockSize: Int = RemoteBlockCache.defaultBlockSize, maxBlocks: Int = RemoteBlockCache.defaultMaxBlocks) {
        self.blockSize = blockSize
        self.maxBlocks = maxBlocks
    }

    /// Shared instance used by default (16 MB).
    public static let shared = RemoteBlockCache()

    public static func fileKey(configId: String, path: String, size: Int64, mtime: Int64) -> String { "\(configId)|\(path)|\(size)|\(mtime)" }
    public static func pathPrefix(configId: String, path: String) -> String { "\(configId)|\(path)|" }

    public func get(_ fileKey: String, _ index: Int64) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let n = map[Key(fileKey: fileKey, index: index)] else { return nil }
        moveToFront(n)
        return n.data
    }

    public func contains(_ fileKey: String, _ index: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map[Key(fileKey: fileKey, index: index)] != nil
    }

    public func put(_ fileKey: String, _ index: Int64, _ data: Data) {
        lock.lock(); defer { lock.unlock() }
        let k = Key(fileKey: fileKey, index: index)
        if let n = map[k] {
            n.data = data
            moveToFront(n)
            return
        }
        let n = Node(key: k, data: data)
        map[k] = n
        insertFront(n)
        while map.count > maxBlocks, let t = tail { unlink(t); map[t.key] = nil }
    }

    /// Drops every block whose file key starts with `prefix` (e.g. `pathPrefix(...)` after an upload).
    public func invalidatePrefix(_ prefix: String) {
        lock.lock(); defer { lock.unlock() }
        for (k, n) in map where k.fileKey.hasPrefix(prefix) { unlink(n); map[k] = nil }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll(); head = nil; tail = nil
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }

    private func insertFront(_ n: Node) {
        n.prev = nil
        n.next = head
        head?.prev = n
        head = n
        if tail == nil { tail = n }
    }

    private func unlink(_ n: Node) {
        if let p = n.prev { p.next = n.next } else { head = n.next }
        if let nx = n.next { nx.prev = n.prev } else { tail = n.prev }
        n.prev = nil; n.next = nil
    }

    private func moveToFront(_ n: Node) {
        guard head !== n else { return }
        unlink(n)
        insertFront(n)
    }
}

/// Random-access reads of one remote file of known `size`, served from `cache` in `cache.blockSize` blocks fetched
/// with ranged requests. Once reads walk three consecutive blocks the access is treated as sequential and a miss
/// also fetches up to `readAhead` following blocks in the same request. A failed fetch is retried once
/// (`maxAttempts` = 2). Thread-safe (reads of one reader are serialized).
///
/// The core API is synchronous so a TagLib IOStream (or any C callback) can call it from its own thread;
/// `read(at:length:) async` runs it on a background queue.
public final class RemoteBlockReader: @unchecked Sendable {
    public let fileKey: String
    public let size: Int64
    private let source: RemoteRangeSource
    private let cache: RemoteBlockCache
    private let readAhead: Int
    private let maxAttempts: Int
    private let blockSize: Int
    private let blockCount: Int64
    private let lock = NSLock()
    private var lastBlock: Int64 = -2
    private var sequentialRun = 0
    private var _bytesFetched: Int64 = 0
    private var _requests = 0

    private static let queue = DispatchQueue(label: "RemoteStorage.RemoteBlockReader", qos: .userInitiated, attributes: .concurrent)

    public init(fileKey: String, size: Int64, cache: RemoteBlockCache = .shared, readAhead: Int = 1, maxAttempts: Int = 2,
                source: @escaping RemoteRangeSource) {
        self.fileKey = fileKey
        self.size = size
        self.source = source
        self.cache = cache
        self.readAhead = readAhead
        self.maxAttempts = maxAttempts
        self.blockSize = cache.blockSize
        self.blockCount = size <= 0 ? 0 : (size + Int64(cache.blockSize) - 1) / Int64(cache.blockSize)
    }

    /// Reader over a `RemoteStorage` file (bridges its async `readRange` to the synchronous source).
    /// Do not call the synchronous `read` from Swift-concurrency's cooperative threads (use the async variant).
    public convenience init(storage: RemoteStorage, path: String, entry: RemoteEntry, cache: RemoteBlockCache = .shared, readAhead: Int = 1) {
        let key = RemoteBlockCache.fileKey(configId: storage.config.id, path: RemotePaths.normalize(path), size: entry.size, mtime: entry.modifiedMillis)
        let p = RemotePaths.normalize(path)
        self.init(fileKey: key, size: entry.size, cache: cache, readAhead: readAhead) { offset, length in
            try blockingAwait { try await storage.readRange(p, offset: offset, length: length) }
        }
    }

    /// Bytes fetched from the network by this reader.
    public var bytesFetched: Int64 { lock.lock(); defer { lock.unlock() }; return _bytesFetched }
    public var requests: Int { lock.lock(); defer { lock.unlock() }; return _requests }

    /// Copies up to `length` bytes at `offset` into `buffer`; returns the number copied (0 at/after EOF).
    public func read(at offset: Int64, into buffer: UnsafeMutableRawBufferPointer, length: Int) throws -> Int {
        precondition(offset >= 0 && length >= 0 && length <= buffer.count)
        lock.lock(); defer { lock.unlock() }
        if offset >= size || length == 0 { return 0 }
        let wanted = Int(min(Int64(length), size - offset))
        var copied = 0
        while copied < wanted {
            let pos = offset + Int64(copied)
            let index = pos / Int64(blockSize)
            let block = try blockLocked(index)
            let inBlock = Int(pos - index * Int64(blockSize))
            let n = min(wanted - copied, block.count - inBlock)
            if n <= 0 { break } // file shorter than announced
            block.withUnsafeBytes { raw in
                buffer.baseAddress!.advanced(by: copied).copyMemory(from: raw.baseAddress!.advanced(by: inBlock), byteCount: n)
            }
            copied += n
        }
        return copied
    }

    /// Up to `length` bytes at `offset` (empty at/after EOF). Synchronous.
    public func read(at offset: Int64, length: Int) throws -> Data {
        var out = Data(count: length)
        let n = try out.withUnsafeMutableBytes { try read(at: offset, into: $0, length: length) }
        out.count = n
        return out
    }

    /// Async variant, runs the blocking read on a background dispatch queue.
    public func read(at offset: Int64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            Self.queue.async {
                do { cont.resume(returning: try self.read(at: offset, length: length)) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func blockLocked(_ index: Int64) throws -> Data {
        if index == lastBlock + 1 { sequentialRun += 1 } else if index != lastBlock { sequentialRun = 0 }
        if let b = cache.get(fileKey, index) {
            lastBlock = index
            return b
        }
        var count = 1
        // Read ahead only once access is clearly streaming (third consecutive block), so a tag that just spills
        // into the second block doesn't pull a third one.
        if sequentialRun >= 2 {
            while count <= readAhead && index + Int64(count) < blockCount && !cache.contains(fileKey, index + Int64(count)) { count += 1 }
        }
        let blocks = try fetchLocked(index, count)
        lastBlock = index
        return blocks[0]
    }

    private func fetchLocked(_ first: Int64, _ count: Int) throws -> [Data] {
        let start = first * Int64(blockSize)
        let length = Int(min(Int64(count) * Int64(blockSize), size - start))
        var lastError: Error?
        for _ in 0..<max(1, maxAttempts) {
            do {
                _requests += 1
                var data = try source(start, Int64(length))
                if data.count > length { data = data.prefix(length) }
                _bytesFetched += Int64(data.count)
                if data.isEmpty { throw RemoteStorageError.io("No data at offset \(start)") }
                var out: [Data] = []
                var off = 0
                var index = first
                while off < data.count {
                    let n = min(blockSize, data.count - off)
                    let block = Data(data[data.startIndex.advanced(by: off)..<data.startIndex.advanced(by: off + n)])
                    cache.put(fileKey, index, block)
                    out.append(block)
                    off += n
                    index += 1
                }
                return out
            } catch let e as RemoteStorageError where e == .cancelled {
                throw e
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RemoteStorageError.io("Read failed at \(start)")
    }
}

/// Runs async work and blocks the calling thread until it finishes. Never call from the main thread or from a
/// Swift-concurrency cooperative thread.
public func blockingAwait<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = Locked<Result<T, Error>?>(nil)
    Task.detached(priority: .userInitiated) {
        do { let v = try await body(); box.withLock { $0 = .success(v) } } catch { box.withLock { $0 = .failure(error) } }
        sem.signal()
    }
    sem.wait()
    return try box.current!.get()
}
