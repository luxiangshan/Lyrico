import Foundation

/// Persistent record of an installed plugin (`SourcePluginEntity`).
public struct InstalledPlugin: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var versionCode: Int
    public var versionName: String
    public var author: String
    public var description: String
    public var apiVersion: Int
    public var minHostApiVersion: Int
    /// Version directory relative to the plugin root (container paths change across app updates).
    public var relativeDirectory: String
    public var entryFile: String
    public var includeDirs: [String]
    public var capabilities: [PluginCapability]
    public var customName: String?
    /// Icon path relative to the version directory.
    public var icon: String?
    public var metadataEnabled: Bool
    public var lyricsEnabled: Bool
    public var coverEnabled: Bool
    public var sortOrder: Int
    public var metadataSortOrder: Int
    public var lyricsSortOrder: Int
    public var coverSortOrder: Int
    public var installedAt: Int64
    public var updatedAt: Int64
    public var updateUrl: String?
    public var installSourceUrl: String?
    public var installSha256: String?

    public var displayName: String {
        if let c = customName?.ktTrim(), !c.isEmpty { return c }
        return name
    }

    public var capabilitySet: Set<PluginCapability> { Set(capabilities).normalized }
    public var sourceTypes: [PluginSourceType] { Set(capabilities).displaySourceTypes }
    public var isEnabledAnywhere: Bool { metadataEnabled || lyricsEnabled || coverEnabled }

    public func isEnabled(for type: PluginSourceType) -> Bool {
        switch type {
        case .metadata: return metadataEnabled
        case .lyrics: return lyricsEnabled
        case .cover: return coverEnabled
        }
    }

    public func sortOrder(for type: PluginSourceType) -> Int {
        switch type {
        case .metadata: return metadataSortOrder
        case .lyrics: return lyricsSortOrder
        case .cover: return coverSortOrder
        }
    }

    mutating func setEnabled(_ type: PluginSourceType, _ value: Bool) {
        switch type {
        case .metadata: metadataEnabled = value
        case .lyrics: lyricsEnabled = value
        case .cover: coverEnabled = value
        }
    }

    mutating func setSortOrder(_ type: PluginSourceType, _ value: Int) {
        switch type {
        case .metadata: metadataSortOrder = value
        case .lyrics: lyricsSortOrder = value
        case .cover: coverSortOrder = value
        }
    }
}

/// JSON-file backed store for installed plugins and their saved config values.
final class PluginRegistryStore: @unchecked Sendable {
    private let pluginsFile: URL
    private let configFile: URL
    private let lock = NSLock()
    private var pluginsCache: [String: InstalledPlugin]?
    private var configCache: [String: StringMap]?

    init(root: URL) {
        pluginsFile = root.appendingPathComponent("plugins.json")
        configFile = root.appendingPathComponent("plugin-config.json")
    }

    func plugins() -> [InstalledPlugin] {
        lock.lock(); defer { lock.unlock() }
        return Array(loadPlugins().values).sorted { ($0.sortOrder, $0.id) < ($1.sortOrder, $1.id) }
    }

    func plugin(_ id: String) -> InstalledPlugin? {
        lock.lock(); defer { lock.unlock() }
        return loadPlugins()[id]
    }

    func upsert(_ plugin: InstalledPlugin) throws {
        try mutate { $0[plugin.id] = plugin }
    }

    func remove(_ id: String) throws {
        try mutate { $0[id] = nil }
        try mutateConfig { $0[id] = nil }
    }

    func mutate(_ body: (inout [String: InstalledPlugin]) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var map = loadPlugins()
        try body(&map)
        let data = try JSONEncoder().encode(map.values.sorted { $0.id < $1.id })
        try FileManager.default.createDirectory(at: pluginsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: pluginsFile, options: .atomic)
        pluginsCache = map
    }

    private func loadPlugins() -> [String: InstalledPlugin] {
        if let pluginsCache { return pluginsCache }
        var map: [String: InstalledPlugin] = [:]
        if let data = try? Data(contentsOf: pluginsFile), let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data) {
            for p in list { map[p.id] = p }
        }
        pluginsCache = map
        return map
    }

    // MARK: Config values

    func config(_ id: String) -> StringMap {
        lock.lock(); defer { lock.unlock() }
        return loadConfig()[id] ?? StringMap()
    }

    func setConfig(_ id: String, _ values: StringMap) throws {
        try mutateConfig { $0[id] = values }
    }

    private func mutateConfig(_ body: (inout [String: StringMap]) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        var map = loadConfig()
        body(&map)
        let json = JSONValue.object(JSONObject(map.keys.sorted().map { ($0, JSONValue.object(.strings(map[$0]!))) })).jsonString
        try FileManager.default.createDirectory(at: configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: configFile, options: .atomic)
        configCache = map
    }

    private func loadConfig() -> [String: StringMap] {
        if let configCache { return configCache }
        var map: [String: StringMap] = [:]
        if let data = try? Data(contentsOf: configFile), case .object(let root)? = try? JSONValue.parse(data: data) {
            for (id, value) in root {
                guard case .object(let o) = value else { continue }
                var values = StringMap()
                for (k, v) in o { if let s = v.contentOrNull { values[k] = s } }
                map[id] = values
            }
        }
        configCache = map
        return map
    }
}
