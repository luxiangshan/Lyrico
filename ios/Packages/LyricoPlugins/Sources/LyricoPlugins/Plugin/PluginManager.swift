import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine)
import Combine
#endif

/// What a remote URL turned out to be (`PluginManager.installFromURL`).
public enum PluginRemoteContent: Sendable {
    /// The URL pointed at a plugin archive; it has been installed.
    case archive(PluginInstallResult)
    /// The URL pointed at a catalog (`schemaVersion` 1); pick releases and call `install(release:from:)`.
    case catalog(PluginCatalog)
}

/// Public facade over the installer, the registry store and the runtime search sources
/// (port of Android `SourcePluginInstaller` + `SourcePluginRepository` + `PluginSearchSourceManager`).
///
/// Layout: `<root>/plugins.json`, `<root>/plugin-config.json`, `<root>/sources/<id>/<uuid>/` (one version dir per plugin).
@MainActor
public final class PluginManager {
    public static let shared = PluginManager()

    /// `Application Support/plugins` by default.
    public let rootDirectory: URL
    /// Version directories live here; `InstalledPlugin.relativeDirectory` is relative to it.
    public let installDirectory: URL
    /// Host environment handed to every plugin runtime. Changing it rebuilds the sources.
    public var environment: PluginHostEnvironment { didSet { closeAllSources() } }
    public let limits: PluginImportLimits

    /// All installed plugins, ordered by their global `sortOrder` (then id).
    public private(set) var plugins: [InstalledPlugin] = [] { willSet { notifyChange() } }
    /// Bumped on every change (plugins, config, names); handy for `onChange`.
    public private(set) var revision = 0

    private let store: PluginRegistryStore
    private var loaded: [String: LoadedPlugin] = [:]
    private var sourceCache: [String: (directory: String, source: PluginSearchSource)] = [:]
    private var orderedSources: [PluginSourceType: [PluginSearchSource]] = [:]

    private struct LoadedPlugin {
        let directory: String
        let manifest: PluginManifest
        let strings: PluginStrings?
    }

    public init(root: URL? = nil, environment: PluginHostEnvironment? = nil, limits: PluginImportLimits = PluginImportLimits()) {
        let fm = FileManager.default
        let base = root ?? (fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory)
            .appendingPathComponent("plugins", isDirectory: true)
        rootDirectory = base
        installDirectory = base.appendingPathComponent("sources", isDirectory: true)
        self.limits = limits
        self.environment = environment ?? PluginManager.defaultEnvironment()
        store = PluginRegistryStore(root: base)
        try? fm.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        plugins = store.plugins()
        recover()
    }

    public static func defaultEnvironment() -> PluginHostEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let appInfo = HostAppInfo(
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Lyrico",
            packageName: Bundle.main.bundleIdentifier ?? "com.lonx.lyrico",
            versionName: info["CFBundleShortVersionString"] as? String ?? "0.0.0",
            versionCode: Int64(info["CFBundleVersion"] as? String ?? "") ?? 0,
            buildType: "release", debug: false)
        return PluginHostEnvironment(appInfo: appInfo, cacheRoot: caches.appendingPathComponent("plugin-cache", isDirectory: true))
    }

    private func notifyChange() {
        #if canImport(Combine)
        objectWillChange.send()
        #endif
    }

    private func reload() {
        plugins = store.plugins()
        revision += 1
        orderedSources.removeAll()
        let ids = Set(plugins.map(\.id))
        for id in loaded.keys where !ids.contains(id) { loaded[id] = nil }
        for (id, cached) in sourceCache where plugin(id)?.relativeDirectory != cached.directory || plugin(id)?.isEnabledAnywhere != true {
            cached.source.close()
            sourceCache[id] = nil
        }
    }

    // MARK: Queries

    public func plugin(_ id: String) -> InstalledPlugin? { plugins.first { $0.id == id } }

    /// Plugins that support `type`, ordered by that type's sort order then display name.
    public func plugins(for type: PluginSourceType, enabledOnly: Bool = false) -> [InstalledPlugin] {
        plugins.filter { Set($0.capabilities).supports(type) && (!enabledOnly || $0.isEnabled(for: type)) }
            .sorted { a, b in
                let ao = a.sortOrder(for: type), bo = b.sortOrder(for: type)
                if ao != bo { return ao < bo }
                return displayName(a).localizedStandardCompare(displayName(b)) == .orderedAscending
            }
    }

    public func directory(of plugin: InstalledPlugin) -> URL {
        installDirectory.appendingPathComponent(plugin.relativeDirectory, isDirectory: true)
    }

    public func iconURL(of plugin: InstalledPlugin) -> URL? {
        guard let icon = plugin.icon else { return nil }
        let url = directory(of: plugin).appendingPathComponent(icon)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Manifest with display strings resolved for the current locale preferences.
    public func localizedManifest(_ id: String) -> PluginManifest? {
        guard let p = plugin(id), let l = load(p) else { return nil }
        return (try? l.strings?.snapshot(environment.localePreferences()).localize(l.manifest)) ?? l.manifest
    }

    /// Custom name, else the localized manifest name, else the stored name.
    public func displayName(_ plugin: InstalledPlugin) -> String {
        if let c = plugin.customName?.ktTrim(), !c.isEmpty { return c }
        return originalName(plugin)
    }

    /// Localized manifest name ignoring the custom name.
    public func originalName(_ plugin: InstalledPlugin) -> String {
        if let n = localizedManifest(plugin.id)?.name, n.ktIsNotBlank, !n.hasPrefix("@") { return n }
        return plugin.name.hasPrefix("@") ? plugin.id : plugin.name
    }

    public func localizedDescription(_ plugin: InstalledPlugin) -> String {
        localizedManifest(plugin.id)?.description ?? plugin.description
    }

    private func load(_ plugin: InstalledPlugin) -> LoadedPlugin? {
        if let l = loaded[plugin.id], l.directory == plugin.relativeDirectory { return l }
        let dir = directory(of: plugin)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? PluginManifest.decode(String(decoding: data, as: UTF8.self)) else { return nil }
        let l = LoadedPlugin(directory: plugin.relativeDirectory, manifest: manifest, strings: try? PluginStrings.load(root: dir, manifest: manifest))
        loaded[plugin.id] = l
        return l
    }

    // MARK: Local install

    /// Extracts and validates a zip archive (security-scoped URLs are handled). Install with `install(_:)` or `discard(_:)`.
    public func prepareImport(zipAt url: URL) async throws -> PluginImportSession {
        let scoped = Self.startAccess(url)
        defer { if scoped { Self.stopAccess(url) } }
        let data = try Data(contentsOf: url)
        return try await prepareImport(zipData: data)
    }

    public func prepareImport(zipData: Data) async throws -> PluginImportSession {
        guard zipData.count <= Int(PluginCatalogParser.maxPackageBytes) else { throw PluginInstallError("Archive is too large") }
        let installer = makeInstaller()
        let snapshot = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        let bytes = [UInt8](zipData)
        return try await Task.detached(priority: .userInitiated) {
            try installer.prepareImport(zipData: bytes, existing: { snapshot[$0] })
        }.value
    }

    /// Imports an already extracted plugin folder.
    public func prepareImport(directory url: URL) async throws -> PluginImportSession {
        let scoped = Self.startAccess(url)
        defer { if scoped { Self.stopAccess(url) } }
        let installer = makeInstaller()
        let snapshot = Dictionary(uniqueKeysWithValues: plugins.map { ($0.id, $0) })
        return try installer.prepareImport(directory: url, existing: { snapshot[$0] })
    }

    public func discard(_ session: PluginImportSession) {
        try? FileManager.default.removeItem(at: session.tempDir)
    }

    /// Installs candidates of a prepared session (all, or those whose `id` is in `selected`) and discards the session.
    /// An existing plugin with the same id is replaced (update, overwrite and — when `allowDowngrade` — downgrade);
    /// its enabled flags, order, custom name and config are kept.
    @discardableResult
    public func install(_ session: PluginImportSession, selected: Set<String>? = nil, allowDowngrade: Bool = true, enabled: Bool = true,
                        installSourceUrl: String? = nil, installSha256: String? = nil) async -> PluginInstallResult {
        defer { discard(session) }
        var failed = session.failed
        var installed: [InstalledPlugin] = []
        let installer = makeInstaller()
        for candidate in session.candidates where selected == nil || selected!.contains(candidate.id) {
            let current = plugin(candidate.manifest.id)
            if let current, candidate.manifest.versionCode < current.versionCode, !allowDowngrade {
                failed.append(installer.failure(candidate, "Import version is lower than installed version: \(candidate.manifest.id)"))
                continue
            }
            do {
                let all = session.candidates
                let relative = try await Task.detached(priority: .userInitiated) {
                    try installer.install(candidate, allCandidates: all)
                }.value
                let record = try commit(candidate.manifest, relativeDirectory: relative, enabled: enabled,
                                        installSourceUrl: installSourceUrl, installSha256: installSha256)
                installed.append(record)
            } catch {
                failed.append(installer.failure(candidate, String(describing: error)))
            }
        }
        return PluginInstallResult(installed: installed, failed: failed)
    }

    /// Convenience: prepare + install everything in a zip file, replacing installed versions.
    @discardableResult
    public func installZip(at url: URL) async throws -> PluginInstallResult {
        await install(try await prepareImport(zipAt: url))
    }

    private func commit(_ manifest: PluginManifest, relativeDirectory: String, enabled: Bool,
                        installSourceUrl: String?, installSha256: String?) throws -> InstalledPlugin {
        let existing = store.plugin(manifest.id)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let initialOrder = existing?.sortOrder ?? ((store.plugins().map(\.sortOrder).max() ?? -1) + 1)
        let record = InstalledPlugin(
            id: manifest.id, name: manifest.name, versionCode: manifest.versionCode, versionName: manifest.versionName,
            author: manifest.author, description: manifest.description, apiVersion: manifest.apiVersion,
            minHostApiVersion: manifest.minHostApiVersion, relativeDirectory: relativeDirectory, entryFile: manifest.entry,
            includeDirs: manifest.includeDirs,
            capabilities: PluginCapability.allCases.filter { manifest.capabilities.normalized.contains($0) },
            customName: existing?.customName, icon: manifest.icon,
            metadataEnabled: existing?.metadataEnabled ?? enabled, lyricsEnabled: existing?.lyricsEnabled ?? enabled,
            coverEnabled: existing?.coverEnabled ?? enabled,
            sortOrder: initialOrder,
            metadataSortOrder: existing?.metadataSortOrder ?? initialOrder,
            lyricsSortOrder: existing?.lyricsSortOrder ?? initialOrder,
            coverSortOrder: existing?.coverSortOrder ?? initialOrder,
            installedAt: existing?.installedAt ?? now, updatedAt: now, updateUrl: manifest.updateUrl,
            installSourceUrl: installSourceUrl, installSha256: installSha256)
        do { try store.upsert(record) } catch {
            try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(relativeDirectory))
            throw error
        }
        reload()
        if let old = existing?.relativeDirectory, old != relativeDirectory {
            try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(old, isDirectory: true))
        }
        return record
    }

    // MARK: Remote install

    /// Downloads `url`. A zip archive is installed right away; a catalog JSON is returned for selection.
    public func installFromURL(_ string: String) async throws -> PluginRemoteContent {
        let url = try PluginCatalogParser.requireUrl(string)
        let (data, finalURL) = try await Self.download(url, limit: PluginCatalogParser.maxPackageBytes)
        if data.starts(with: [0x50, 0x4B]) {
            let session = try await prepareImport(zipData: data)
            return .archive(await install(session, installSourceUrl: finalURL.absoluteString))
        }
        let text = String(decoding: data, as: UTF8.self)
        return .catalog(try PluginCatalogParser.parse(text, url: finalURL.absoluteString))
    }

    public func fetchCatalog(_ string: String) async throws -> PluginCatalog {
        let url = try PluginCatalogParser.requireUrl(string)
        let (data, finalURL) = try await Self.download(url, limit: 1024 * 1024)
        return try PluginCatalogParser.parse(String(decoding: data, as: UTF8.self), url: finalURL.absoluteString)
    }

    /// Downloads one catalog release, checks size + SHA-256 and that the package holds exactly this plugin, then installs it.
    @discardableResult
    public func install(release: PluginRelease, from catalog: PluginCatalog) async throws -> InstalledPlugin {
        guard release.compatible else { throw PluginCatalogError("Plugin requires a newer or different host API: \(release.id)") }
        let (data, _) = try await Self.download(try PluginCatalogParser.requireUrl(release.downloadUrl), limit: release.size)
        guard Int64(data.count) == release.size else { throw PluginCatalogError("Plugin package size mismatch") }
        guard Digest.hexLower(Digest.sha256([UInt8](data))).caseInsensitiveCompare(release.sha256) == .orderedSame else {
            throw PluginCatalogError("Plugin package SHA-256 mismatch")
        }
        let session = try await prepareImport(zipData: data)
        guard session.failed.isEmpty, session.candidates.count == 1, let candidate = session.candidates.first else {
            discard(session)
            throw PluginCatalogError(session.failed.first?.reason ?? "Online package must contain exactly one valid plugin")
        }
        do { try release.verify(candidate.manifest) } catch { discard(session); throw error }
        let result = await install(session, installSourceUrl: catalog.sourceUrl, installSha256: release.sha256.lowercased())
        guard let record = result.installed.first else {
            throw PluginInstallError(result.failed.first?.reason ?? "Plugin install failed")
        }
        return record
    }

    nonisolated static func download(_ url: URL, limit: Int64) async throws -> (Data, URL) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse?) = try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (data ?? Data(), response))
            }
            task.resume()
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PluginCatalogError("HTTP \(http.statusCode)")
        }
        guard Int64(data.count) <= limit else { throw PluginCatalogError("Response is too large") }
        let finalURL = response?.url ?? url
        try PluginCatalogParser.requireUrl(finalURL.absoluteString)
        return (data, finalURL)
    }

    // MARK: Mutations

    public func uninstall(_ id: String) throws {
        guard let p = plugin(id) else { return }
        sourceCache[id]?.source.close()
        sourceCache[id] = nil
        try store.remove(id)
        reload()
        try? FileManager.default.removeItem(at: installDirectory.appendingPathComponent(id, isDirectory: true))
        _ = p
    }

    public func setEnabled(_ id: String, _ type: PluginSourceType, _ enabled: Bool) throws {
        try store.mutate { map in map[id]?.setEnabled(type, enabled) }
        reload()
    }

    /// Persists a new order for `type`; `ids` lists plugins of that type in the wanted order (others keep relative order after).
    public func reorder(_ type: PluginSourceType, ids: [String]) throws {
        let current = plugins(for: type).map(\.id)
        let ordered = ids.filter(current.contains) + current.filter { !ids.contains($0) }
        try store.mutate { map in
            for (index, id) in ordered.enumerated() { map[id]?.setSortOrder(type, index) }
        }
        reload()
    }

    /// `List.onMove` helper for `plugins(for: type)`.
    public func move(_ type: PluginSourceType, fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var ids = plugins(for: type).map(\.id)
        let moving = source.sorted().map { ids[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        ids.removeAll { moving.contains($0) }
        ids.insert(contentsOf: moving, at: max(0, min(insertAt, ids.count)))
        try reorder(type, ids: ids)
    }

    /// Blank or nil restores the original name.
    public func setCustomName(_ id: String, _ name: String?) throws {
        let trimmed = name?.ktTrim()
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        try store.mutate { map in map[id]?.customName = value }
        sourceCache[id]?.source.customName = value
        reload()
    }

    // MARK: Config

    /// Localized config fields of a plugin.
    public func configFields(_ id: String) -> [PluginConfigField] { localizedManifest(id)?.configFields ?? [] }

    /// Defaults of value fields overlaid with saved values (what the plugin receives as `request.config`).
    public func config(_ id: String) -> [String: String] {
        var values: [String: String] = [:]
        for f in configFields(id) where f.type != .markdown { values[f.key] = f.defaultValue }
        for (k, v) in store.config(id).pairs { values[k] = v }
        return values
    }

    public func savedConfig(_ id: String) -> [String: String] {
        Dictionary(store.config(id).pairs, uniquingKeysWith: { _, b in b })
    }

    /// Saves values for value fields only (markdown and unknown keys are dropped).
    public func setConfig(_ id: String, _ values: [String: String]) throws {
        let fields = configFields(id).filter { $0.type != .markdown }
        let map = StringMap(fields.compactMap { f in values[f.key].map { (f.key, $0) } })
        try store.setConfig(id, map)
        sourceCache[id]?.source.applyConfig(runtimeConfig(id))
        revision += 1
        notifyChange()
    }

    /// Keys of visible required fields that are blank.
    public func missingRequiredKeys(_ id: String, values: [String: String]) -> [String] {
        configFields(id).filter { $0.type != .markdown && $0.required && $0.dependency.isSatisfied(values) && (values[$0.key] ?? "").ktIsBlank }.map(\.key)
    }

    private func runtimeConfig(_ id: String) -> StringMap {
        let c = config(id)
        return StringMap(c.keys.sorted().map { ($0, c[$0]!) })
    }

    // MARK: Sources

    /// Runtime sources enabled for `type`, in the user's order. Instances are cached and reused until the plugin changes.
    public func sources(for type: PluginSourceType) -> [PluginSearchSource] {
        if let cached = orderedSources[type] { return cached }
        let list = plugins(for: type, enabledOnly: true).compactMap { source(for: $0) }
        orderedSources[type] = list
        return list
    }

    /// Runtime source for one plugin (enabled or not), e.g. to test a config.
    public func source(id: String) -> PluginSearchSource? {
        plugin(id).flatMap(source(for:))
    }

    private func source(for plugin: InstalledPlugin) -> PluginSearchSource? {
        if let cached = sourceCache[plugin.id], cached.directory == plugin.relativeDirectory { return cached.source }
        sourceCache[plugin.id]?.source.close()
        sourceCache[plugin.id] = nil
        guard let l = load(plugin) else { return nil }
        let dir = directory(of: plugin)
        guard let script = try? PluginScriptBuilder.build(pluginDir: dir, manifest: l.manifest, entryFile: plugin.entryFile) else { return nil }
        let source = PluginSearchSource(manifest: l.manifest, pluginDirectory: dir, script: script, strings: l.strings,
                                        environment: environment, customName: plugin.customName, iconURL: iconURL(of: plugin))
        source.applyConfig(runtimeConfig(plugin.id))
        sourceCache[plugin.id] = (plugin.relativeDirectory, source)
        return source
    }

    /// Releases every JavaScript context (e.g. on memory warning); sources are rebuilt on demand.
    public func closeAllSources() {
        for (_, cached) in sourceCache { cached.source.close() }
        sourceCache.removeAll()
        orderedSources.removeAll()
    }

    // MARK: Internals

    nonisolated static func startAccess(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return url.startAccessingSecurityScopedResource()
        #else
        return false
        #endif
    }

    nonisolated static func stopAccess(_ url: URL) {
        #if canImport(Darwin)
        url.stopAccessingSecurityScopedResource()
        #endif
    }

    private func makeInstaller() -> PluginInstaller {
        let env = environment
        return PluginInstaller(installRoot: installDirectory, limits: limits, localePreferences: { env.localePreferences() })
    }

    /// Removes leftovers (import/staging dirs, unreferenced version dirs) — Android `recover`.
    private func recover() {
        let fm = FileManager.default
        let referenced = Set(plugins.map { installDirectory.appendingPathComponent($0.relativeDirectory).standardizedFileURL.path })
        guard let top = try? fm.contentsOfDirectory(at: installDirectory, includingPropertiesForKeys: nil) else { return }
        for item in top {
            let path = item.standardizedFileURL.path
            if referenced.contains(path) { continue }
            if referenced.contains(where: { $0.hasPrefix(path + "/") }), let children = try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil) {
                for child in children where !referenced.contains(child.standardizedFileURL.path) { try? fm.removeItem(at: child) }
            } else {
                try? fm.removeItem(at: item)
            }
        }
    }
}

#if canImport(Combine)
extension PluginManager: ObservableObject {}
#endif
