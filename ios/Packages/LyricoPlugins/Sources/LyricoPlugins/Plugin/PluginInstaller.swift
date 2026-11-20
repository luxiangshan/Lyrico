import Foundation

public struct PluginImportLimits: Hashable, Sendable {
    public var maxTotalUncompressedBytes = 30 * 1024 * 1024
    public var maxSinglePluginBytes = 5 * 1024 * 1024
    public var maxManifestBytes = 128 * 1024
    public var maxEntryScriptBytes = 1 * 1024 * 1024
    public var maxPluginCountPerArchive = 20
    public var maxFileCountPerArchive = 1000
    public var maxDepth = 16
    public init() {}
}

public enum PluginVersionConflict: String, Hashable, Sendable {
    case none = "NONE", update = "UPDATE", overwrite = "OVERWRITE", downgrade = "DOWNGRADE"

    static func between(installed: Int?, candidate: Int) -> PluginVersionConflict {
        guard let installed else { return .none }
        if candidate > installed { return .update }
        if candidate == installed { return .overwrite }
        return .downgrade
    }
}

public struct PluginInstallError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// A validated plugin found in an archive, ready to install.
public struct PluginInstallCandidate: Hashable, Sendable, Identifiable {
    public var manifest: PluginManifest
    /// Display name resolved for the current locale.
    public var displayName: String
    public var relativeRootInArchive: String
    public var existingVersionCode: Int?
    public var existingVersionName: String?
    public var versionConflict: PluginVersionConflict
    public var id: String { relativeRootInArchive }
    let pluginRoot: URL
}

public struct PluginInstallFailure: Hashable, Sendable {
    public var rootPath: String
    public var reason: String
    public var pluginId: String?
    public var pluginName: String?
    public var versionCode: Int?
    public var versionName: String?
    public var existingVersionCode: Int?
    public var existingVersionName: String?
    public var conflict: PluginVersionConflict?

    public var displayName: String {
        if let n = pluginName, n.ktIsNotBlank { return n }
        if let i = pluginId, i.ktIsNotBlank { return i }
        return rootPath.ktIsNotBlank ? rootPath : "."
    }
}

/// Result of `prepareImport`: extracted + validated candidates. Discard with `PluginManager.discard(_:)`.
public struct PluginImportSession: Sendable {
    public let candidates: [PluginInstallCandidate]
    public let failed: [PluginInstallFailure]
    let tempDir: URL
}

public struct PluginInstallResult: Sendable {
    public let installed: [InstalledPlugin]
    public let failed: [PluginInstallFailure]
}

/// Port of `SourcePluginInstaller` (archive extraction, manifest/entry/include/icon validation, staging install).
struct PluginInstaller {
    let installRoot: URL
    let limits: PluginImportLimits
    let localePreferences: () -> [String]
    static let idPattern = KRegex("^[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z][a-zA-Z0-9_]*)+$")
    static let iconExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

    private var fm: FileManager { .default }

    func prepareImport(zipData: [UInt8], existing: (String) -> InstalledPlugin?) throws -> PluginImportSession {
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let tempDir = installRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try extractZip(zipData, to: tempDir)
            return try prepare(extracted: tempDir, existing: existing)
        } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
    }

    /// Prepare from an already extracted directory (e.g. a folder picked in Files).
    func prepareImport(directory: URL, existing: (String) -> InstalledPlugin?) throws -> PluginImportSession {
        try fm.createDirectory(at: installRoot, withIntermediateDirectories: true)
        let tempDir = installRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: directory, to: tempDir)
        do { return try prepare(extracted: tempDir, existing: existing) } catch {
            try? fm.removeItem(at: tempDir)
            throw error
        }
    }

    private func prepare(extracted tempDir: URL, existing: (String) -> InstalledPlugin?) throws -> PluginImportSession {
        let manifests = try findManifestFiles(tempDir)
        if manifests.isEmpty {
            return PluginImportSession(candidates: [], failed: [PluginInstallFailure(rootPath: ".", reason: "Plugin manifest not found")], tempDir: tempDir)
        }
        let validated: [Result<PluginInstallCandidate, Error>] = manifests.map { file in Result { try buildCandidate(file, packageRoot: tempDir) } }
        var counts: [String: Int] = [:]
        for case .success(let c) in validated { counts[c.manifest.id, default: 0] += 1 }
        var candidates: [PluginInstallCandidate] = []
        var failed: [PluginInstallFailure] = []
        for result in validated {
            switch result {
            case .success(var candidate):
                if counts[candidate.manifest.id, default: 0] > 1 {
                    failed.append(failure(candidate, "Duplicate plugin id in archive: \(candidate.manifest.id)"))
                } else {
                    let current = existing(candidate.manifest.id)
                    candidate.existingVersionCode = current?.versionCode
                    candidate.existingVersionName = current?.versionName
                    candidate.versionConflict = .between(installed: current?.versionCode, candidate: candidate.manifest.versionCode)
                    candidates.append(candidate)
                }
            case .failure(let error):
                let message = String(describing: error)
                let root = message.ktSubstringBefore(": ")
                failed.append(PluginInstallFailure(rootPath: root.ktIsBlank ? "." : root, reason: message))
            }
        }
        return PluginImportSession(candidates: candidates, failed: failed, tempDir: tempDir)
    }

    func failure(_ c: PluginInstallCandidate, _ reason: String) -> PluginInstallFailure {
        PluginInstallFailure(rootPath: c.relativeRootInArchive, reason: reason, pluginId: c.manifest.id, pluginName: c.displayName,
                             versionCode: c.manifest.versionCode, versionName: c.manifest.versionName,
                             existingVersionCode: c.existingVersionCode, existingVersionName: c.existingVersionName, conflict: c.versionConflict)
    }

    // MARK: Extraction

    private func extractZip(_ data: [UInt8], to target: URL) throws {
        let archive = try ZipArchive(data: data)
        var fileCount = 0
        var total = 0
        let canonicalTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        for entry in archive.entries {
            let name = entry.name
            try Self.validateZipEntryName(name)
            guard Self.depth(name) <= limits.maxDepth else { throw PluginInstallError("Zip entry is too deep: \(name)") }
            fileCount += 1
            guard fileCount <= limits.maxFileCountPerArchive else { throw PluginInstallError("Archive contains too many files") }
            let output = canonicalTarget.appendingPathComponent(name).standardizedFileURL
            guard output.path == canonicalTarget.path || output.path.hasPrefix(canonicalTarget.path + "/") else {
                throw PluginInstallError("Unsafe zip entry: \(name)")
            }
            if entry.isDirectory {
                try fm.createDirectory(at: output, withIntermediateDirectories: true)
            } else {
                let remaining = limits.maxTotalUncompressedBytes - total
                let bytes: [UInt8]
                do { bytes = try archive.contents(of: entry, limit: max(remaining, 0)) } catch let e as CodecError where e.description.contains("too large") {
                    throw PluginInstallError("Archive is too large after extraction")
                }
                total += bytes.count
                guard total <= limits.maxTotalUncompressedBytes else { throw PluginInstallError("Archive is too large after extraction") }
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(bytes).write(to: output)
            }
        }
    }

    static func validateZipEntryName(_ name: String) throws {
        guard name.ktIsNotBlank else { throw PluginInstallError("Zip entry name is blank") }
        guard !name.hasScalar("\u{0}") else { throw PluginInstallError("Zip entry contains NUL byte") }
        guard !name.hasPrefix("/"), !name.hasPrefix("\\") else { throw PluginInstallError("Absolute zip entry is not allowed: \(name)") }
        guard !name.hasScalar("\\") else { throw PluginInstallError("Backslash zip entry is not allowed: \(name)") }
        guard !name.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw PluginInstallError("Unsafe zip entry: \(name)") }
    }

    static func depth(_ name: String) -> Int {
        name.split(separator: "/").filter { !String($0).ktIsBlank }.count
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        if path.ktIsBlank { return false }
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        if path.hasScalar("\\") || path.hasScalar("\u{0}") { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || String($0).ktIsBlank }
    }

    private func findManifestFiles(_ root: URL) throws -> [URL] {
        var found: [URL] = []
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        for case let url as URL in e where url.lastPathComponent == "manifest.json" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            found.append(url)
            if found.count > limits.maxPluginCountPerArchive { throw PluginInstallError("Archive contains too many plugins") }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: Validation

    private func buildCandidate(_ manifestFile: URL, packageRoot: URL) throws -> PluginInstallCandidate {
        let rel = PluginScriptBuilder.relativePath(of: manifestFile, under: packageRoot)
        let data = try Data(contentsOf: manifestFile)
        guard data.count <= limits.maxManifestBytes else { throw PluginInstallError("\(rel): manifest is too large") }
        let manifest: PluginManifest
        do { manifest = try PluginManifest.decode(String(decoding: data, as: UTF8.self)) } catch {
            throw PluginInstallError("\(rel): manifest parse failed: \(error)")
        }
        let pluginRoot = manifestFile.deletingLastPathComponent()
        try Self.validateManifest(manifest)
        do { _ = try PluginStrings.load(root: pluginRoot, manifest: manifest) } catch { throw PluginInstallError(String(describing: error)) }
        try validateEntry(pluginRoot, manifest.entry)
        try validateIncludeDirs(pluginRoot, manifest.includeDirs)
        if let icon = manifest.icon { try validateIcon(pluginRoot, icon) }
        let rootRel = PluginScriptBuilder.relativePath(of: pluginRoot, under: packageRoot)
        return PluginInstallCandidate(
            manifest: manifest,
            displayName: PluginStrings.displayName(manifest: manifest, root: pluginRoot, preferences: localePreferences()),
            relativeRootInArchive: rootRel.ktIsBlank ? "." : rootRel,
            existingVersionCode: nil, existingVersionName: nil, versionConflict: .none, pluginRoot: pluginRoot)
    }

    static func validateManifest(_ m: PluginManifest) throws {
        guard idPattern.matches(m.id) else { throw PluginInstallError("Plugin id must use reverse-domain format") }
        guard m.name.ktIsNotBlank else { throw PluginInstallError("Plugin name is required") }
        guard m.versionCode >= 1 else { throw PluginInstallError("Plugin versionCode must be >= 1") }
        if let u = m.updateUrl { try PluginCatalogParser.requireUrl(u) }
        guard HostApiRegistry.supportsPluginApiVersion(m.apiVersion) else {
            throw PluginInstallError("Unsupported plugin apiVersion: \(m.apiVersion) (supported: \(HostApiRegistry.minPluginProtocolVersion)..\(HostApiRegistry.pluginProtocolVersion))")
        }
        guard HostApiRegistry.supportsHostApiVersion(m.minHostApiVersion) else {
            throw PluginInstallError("Unsupported minHostApiVersion: \(m.minHostApiVersion) (host: \(HostApiRegistry.platformApiVersion))")
        }
    }

    private func resolvedChild(_ root: URL, _ path: String) -> (URL, Bool) {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = canonicalRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        return (file, file.path == canonicalRoot.path || file.path.hasPrefix(canonicalRoot.path + "/"))
    }

    private func validateEntry(_ root: URL, _ entry: String) throws {
        guard Self.isSafeRelativePath(entry) else { throw PluginInstallError("Unsafe entry path: \(entry)") }
        let (file, inside) = resolvedChild(root, entry)
        guard inside else { throw PluginInstallError("Entry escapes plugin root: \(entry)") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { throw PluginInstallError("Plugin entry not found: \(entry)") }
        guard file.pathExtension.lowercased() == "js" else { throw PluginInstallError("Plugin entry must be a .js file") }
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= limits.maxEntryScriptBytes else { throw PluginInstallError("Plugin entry is too large") }
    }

    private func validateIncludeDirs(_ root: URL, _ dirs: [String]) throws {
        for dir in dirs {
            guard Self.isSafeRelativePath(dir), dir != "." else { throw PluginInstallError("Unsafe includeDir: \(dir)") }
            let (url, inside) = resolvedChild(root, dir)
            guard inside else { throw PluginInstallError("includeDir escapes plugin root: \(dir)") }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw PluginInstallError("includeDir not found: \(dir)") }
        }
    }

    private func validateIcon(_ root: URL, _ icon: String) throws {
        guard Self.isSafeRelativePath(icon) else { throw PluginInstallError("Unsafe icon path: \(icon)") }
        let (url, inside) = resolvedChild(root, icon)
        guard inside else { throw PluginInstallError("Icon escapes plugin root: \(icon)") }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw PluginInstallError("Icon not found: \(icon)") }
        guard Self.iconExtensions.contains(url.pathExtension.lowercased()) else { throw PluginInstallError("Unsupported icon type: \(icon)") }
    }

    // MARK: Install

    /// Copies one candidate (excluding nested plugin roots) into `<root>/<id>/<uuid>` via a staging dir.
    func install(_ candidate: PluginInstallCandidate, allCandidates: [PluginInstallCandidate]) throws -> String {
        let id = candidate.manifest.id
        let versionDirName = UUID().uuidString
        let target = installRoot.appendingPathComponent(id, isDirectory: true).appendingPathComponent(versionDirName, isDirectory: true)
        let staging = installRoot.appendingPathComponent(".staging-\(id)-\(Int64(Date().timeIntervalSince1970 * 1000))", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let sourceRoot = candidate.pluginRoot.standardizedFileURL.resolvingSymlinksInPath()
        let excluded = allCandidates.map { $0.pluginRoot.standardizedFileURL.resolvingSymlinksInPath().path }
            .filter { $0 != sourceRoot.path && $0.hasPrefix(sourceRoot.path + "/") }
        var total = 0
        if let e = fm.enumerator(at: sourceRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) {
            for case let url as URL in e {
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if excluded.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { e.skipDescendants() }
                    continue
                }
                let rel = PluginScriptBuilder.relativePath(of: url, under: sourceRoot)
                if rel.isEmpty { continue }
                let dest = staging.appendingPathComponent(rel)
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                } else {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: url, to: dest)
                    total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                }
            }
        }
        guard total <= limits.maxSinglePluginBytes else { throw PluginInstallError("Plugin is too large") }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: target)
        return id + "/" + versionDirName
    }
}
