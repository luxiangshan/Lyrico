import Foundation

/// Port of `ScriptSearchSourceFactory.buildScript`: include bootstrap + includeDirs + entry, one script unit.
enum PluginScriptBuilder {
    static func build(pluginDir: URL, manifest: PluginManifest, entryFile: String? = nil) throws -> String {
        let fm = FileManager.default
        var includes: [(path: String, content: String)] = []
        for includeDir in manifest.includeDirs {
            let dir = pluginDir.appendingPathComponent(includeDir, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            var files: [(String, URL)] = []
            if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let url as URL in enumerator {
                    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                          url.pathExtension.lowercased() == "js" else { continue }
                    let rel = relativePath(of: url, under: dir)
                    files.append((rel, url))
                }
            }
            for (rel, url) in files.sorted(by: { $0.0.utf16.lexicographicallyPrecedes($1.0.utf16) }) {
                includes.append((includeDir + "/" + rel, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        var seen = Set<String>()
        let declared = includes.map(\.path).filter { seen.insert($0).inserted }
        let declaredJSON = JSONValue.array(declared.map { .string($0) }).jsonString
        let includeBootstrap = """
        (function() {
          var __lyricoDeclaredIncludes = \(declaredJSON);
          var __lyricoDeclaredIncludeMap = Object.create(null);

          __lyricoDeclaredIncludes.forEach(function(path) {
            __lyricoDeclaredIncludeMap[path] = true;
          });

          /*
           * All declared include files have already been concatenated into the same
           * script unit before source.js.
           *
           * Keep include(path) for compatibility with plugins that call it manually.
           * It validates the path, then becomes a no-op.
           */
          globalThis.include = function(path) {
            path = String(path || "");
            if (!Object.prototype.hasOwnProperty.call(__lyricoDeclaredIncludeMap, path)) {
              throw new Error("Include path is not declared in includeDirs: " + path);
            }
          };
        })();
        """
        var out = includeBootstrap + "\n"
        for source in includes {
            out += "\n;\n// ===== Platform include: " + source.path + " =====\n" + source.content + "\n//# sourceURL=" + source.path + "\n"
        }
        let entry = pluginDir.appendingPathComponent((entryFile?.ktIsNotBlank == true) ? entryFile! : manifest.entry)
        out += "\n;\n// ===== Platform entry: " + manifest.entry + " =====\n" + (try String(contentsOf: entry, encoding: .utf8)) +
            "\n//# sourceURL=" + manifest.entry + "\n"
        return out
    }

    static func relativePath(of url: URL, under dir: URL) -> String {
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let full = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return full.dropFirst(base.count).joined(separator: "/")
    }
}

/// A runnable plugin search source (port of `ScriptSearchSource`).
///
/// Each source owns one JavaScript context on one dedicated thread, created lazily on first use.
/// All calls are `async`; cancelling the calling task interrupts the running script and its HTTP.
public final class PluginSearchSource: @unchecked Sendable, Identifiable {
    public let id: String
    public let manifest: PluginManifest
    /// Localised manifest (display name, config field titles) for the current locale preferences.
    public var localizedManifest: PluginManifest { (try? strings?.snapshot(environment.localePreferences()).localize(manifest)) ?? manifest }
    public var name: String {
        if let custom = customName?.ktTrim(), !custom.isEmpty { return custom }
        return localizedManifest.name
    }
    public var capabilities: Set<PluginCapability> { manifest.capabilities.normalized }
    public var apiVersion: Int { manifest.apiVersion }
    public var configFields: [PluginConfigField] { localizedManifest.configFields }
    public let iconURL: URL?
    public let pluginDirectory: URL

    var customName: String?
    private let script: String
    private let strings: PluginStrings?
    private let environment: PluginHostEnvironment
    private let engineFactory: (HostApi) throws -> PluginScriptEngine
    private let lock = NSLock()
    private var config = StringMap()
    private var executor: PluginExecutor?
    private var engine: PluginScriptEngine?
    private var scriptInitialized = false
    private var activeCalls = 0
    private var closing = false

    init(manifest: PluginManifest, pluginDirectory: URL, script: String, strings: PluginStrings?, environment: PluginHostEnvironment,
         customName: String? = nil, iconURL: URL? = nil, engineFactory: ((HostApi) throws -> PluginScriptEngine)? = nil) {
        self.id = manifest.id
        self.manifest = manifest
        self.pluginDirectory = pluginDirectory
        self.script = script
        self.strings = strings
        self.environment = environment
        self.customName = customName
        self.iconURL = iconURL
        self.engineFactory = engineFactory ?? { api in
            #if canImport(JavaScriptCore)
            return try JSCPluginEngine(hostApi: api, timeoutMs: environment.timeoutMs)
            #else
            throw PluginRuntimeError.engineUnavailable("JavaScriptCore is not available on this platform")
            #endif
        }
    }

    /// Runtime config values sent to the plugin as `request.config` (`applyConfig`).
    public func applyConfig(_ values: StringMap) { lock.lock(); config = values; lock.unlock() }
    public var currentConfig: StringMap { lock.lock(); defer { lock.unlock() }; return config }

    // MARK: Search API

    public func searchSongs(keyword: String, page: Int = 1, separator: String = "/", pageSize: Int = 20) async throws -> [SongSearchResult] {
        guard capabilities.contains(.searchSongs) else { return [] }
        let request = PluginRequests.searchSongs(keyword: keyword, page: page, pageSize: pageSize, separator: separator, config: currentConfig)
        let raw = try await callRuntime("searchSongs", request)
        return try PluginJSONParser.parseSongResults(raw, pluginId: id, pluginName: name)
    }

    public func getLyricsCandidates(song: SongSearchResult, page: Int = 1, pageSize: Int = 20) async throws -> [LyricsCandidateResult] {
        guard capabilities.contains(.getLyrics) else { return [] }
        let request = PluginRequests.getLyrics(song: song, page: page, pageSize: pageSize, config: currentConfig)
        let raw = try await callRuntime("getLyrics", request)
        return try PluginJSONParser.parseLyricsCandidates(raw, pluginId: id, pluginName: name, fallbackSong: song, enforceApi4Contract: apiVersion >= 4)
    }

    public func getLyrics(song: SongSearchResult) async throws -> LyricsResult? {
        try await getLyricsCandidates(song: song).first?.lyrics
    }

    public func searchCovers(keyword: String, page: Int = 1, pageSize: Int = 5) async throws -> [CoverSearchResult] {
        guard capabilities.contains(.searchCovers) else { return [] }
        let request = PluginRequests.searchCovers(keyword: keyword, song: nil, page: page, pageSize: pageSize, config: currentConfig)
        let raw = try await callRuntime("searchCovers", request)
        return try PluginJSONParser.parseCoverResults(raw, pluginId: id, pluginName: name, enforceApi4Contract: apiVersion >= 4)
    }

    public func searchCovers(song: SongSearchResult, page: Int = 1, pageSize: Int = 5) async throws -> [CoverSearchResult] {
        guard capabilities.contains(.searchCovers) else { return [] }
        let keyword = [song.title, song.artist].filter { $0.ktIsNotBlank }.joined(separator: " ")
        let request = PluginRequests.searchCovers(keyword: keyword, song: song, page: page, pageSize: pageSize, config: currentConfig)
        let raw = try await callRuntime("searchCovers", request)
        return try PluginJSONParser.parseCoverResults(raw, pluginId: id, pluginName: name, enforceApi4Contract: apiVersion >= 4)
    }

    /// Calls any global plugin function with a JSON request and returns the JSON result.
    public func callFunction(_ function: String, requestJSON: String) async throws -> String {
        try await callRuntime(function, requestJSON)
    }

    // MARK: Lifecycle

    /// Retires the instance; the engine is released once in-flight calls finish.
    public func close() {
        lock.lock()
        closing = true
        lock.unlock()
        disposeIfIdle()
    }

    private func disposeIfIdle() {
        lock.lock()
        guard closing, activeCalls == 0, let executor else { lock.unlock(); return }
        self.executor = nil
        let engine = self.engine
        self.engine = nil
        lock.unlock()
        executor.submit { engine?.close() }
        executor.shutdown()
    }

    private func acquire() throws -> PluginExecutor {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw PluginRuntimeError.closed }
        activeCalls += 1
        if let executor { return executor }
        let created = PluginExecutor(name: "JSC-\(id)")
        executor = created
        return created
    }

    private func release() {
        lock.lock(); activeCalls -= 1; lock.unlock()
        disposeIfIdle()
    }

    private func callRuntime(_ function: String, _ request: String) async throws -> String {
        let executor = try acquire()
        defer { release() }
        let cancelled = CancelFlag()
        return try await withTaskCancellationHandler {
            try await executor.run { [self] in
                if cancelled.value { throw CancellationError() }
                let engine = try currentEngine()
                engine.resetCancellation()
                cancelled.onCancel = { engine.cancel() }
                if cancelled.value { engine.cancel() }
                defer { cancelled.onCancel = nil }
                do {
                    if !scriptInitialized {
                        do {
                            try engine.evaluate(script, filename: manifest.entry)
                            scriptInitialized = true
                        } catch {
                            // An interrupted initializer may have left partial globals behind.
                            lock.lock(); self.engine = nil; lock.unlock()
                            engine.close()
                            throw error
                        }
                    }
                    return try engine.call(function, requestJSON: request)
                } catch PluginRuntimeError.cancelled {
                    throw CancellationError()
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private func currentEngine() throws -> PluginScriptEngine {
        lock.lock()
        if let engine { lock.unlock(); return engine }
        lock.unlock()
        let api = HostApi(pluginId: id, strings: strings, environment: environment)
        let created = try engineFactory(api)
        lock.lock(); engine = created; scriptInitialized = false; lock.unlock()
        return created
    }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?

    var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    var onCancel: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let h = handler
        lock.unlock()
        h?()
    }
}
