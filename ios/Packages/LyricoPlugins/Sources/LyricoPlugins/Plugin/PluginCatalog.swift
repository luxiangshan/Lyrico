import Foundation

public struct PluginCatalogError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// One release in a subscription catalog (`PluginRelease`).
public struct PluginRelease: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var versionCode: Int
    public var versionName: String
    public var apiVersion: Int
    public var minHostApiVersion: Int
    public var downloadUrl: String
    public var sha256: String
    public var size: Int64
    public var changelog: String

    public var compatible: Bool {
        HostApiRegistry.supportsPluginApiVersion(apiVersion) && HostApiRegistry.supportsHostApiVersion(minHostApiVersion)
    }

    func verify(_ manifest: PluginManifest) throws {
        guard manifest.id == id, manifest.versionCode == versionCode, manifest.versionName == versionName,
              manifest.apiVersion == apiVersion, manifest.minHostApiVersion == minHostApiVersion else {
            throw PluginCatalogError("Downloaded manifest does not match catalog: \(id)")
        }
    }
}

public struct PluginCatalog: Hashable, Sendable {
    public var schemaVersion: Int
    public var plugins: [PluginRelease]
    /// The URL the catalog was fetched from (after redirects).
    public var sourceUrl: String
}

/// Port of `PluginCatalogParser`.
public enum PluginCatalogParser {
    public static let maxPackageBytes: Int64 = 30 * 1024 * 1024
    private static let idPattern = KRegex("[a-zA-Z][a-zA-Z0-9_]*(\\.[a-zA-Z][a-zA-Z0-9_]*)+")
    private static let shaPattern = KRegex("[a-fA-F0-9]{64}")

    public static func parse(_ text: String, url: String) throws -> PluginCatalog {
        let base = try requireUrl(url)
        guard case .object(let o) = try JSONValue.parse(text) else { throw PluginCatalogError("Expected a JSON object") }
        let schema = try o.reqInt("schemaVersion")
        guard schema == 1 else { throw PluginCatalogError("Unsupported plugin catalog format") }
        guard let rawPlugins = try o.optArray("plugins") else { throw PluginCatalogError("Field 'plugins' is required") }
        guard rawPlugins.count <= 500 else { throw PluginCatalogError("Too many catalog entries") }
        var releases: [PluginRelease] = []
        for item in rawPlugins {
            guard case .object(let r) = item else { throw PluginCatalogError("Invalid catalog entry") }
            guard case .number(let sizeText)? = r["size"], let size = Int64(sizeText) else { throw PluginCatalogError("Field 'size' is required") }
            releases.append(PluginRelease(
                id: try r.reqString("id"), name: try r.reqString("name"), versionCode: try r.reqInt("versionCode"),
                versionName: try r.reqString("versionName"), apiVersion: try r.reqInt("apiVersion"),
                minHostApiVersion: try r.optInt("minHostApiVersion") ?? 1, downloadUrl: try r.reqString("downloadUrl"),
                sha256: try r.reqString("sha256"), size: size, changelog: try r.optString("changelog") ?? ""))
        }
        guard Set(releases.map(\.id)).count == releases.count else { throw PluginCatalogError("Duplicate plugin IDs in catalog") }
        let resolved = try releases.map { release -> PluginRelease in
            guard idPattern.matches(release.id), release.name.ktIsNotBlank else { throw PluginCatalogError("Invalid plugin identity") }
            guard release.versionCode >= 1, release.versionName.ktIsNotBlank else { throw PluginCatalogError("Invalid plugin version") }
            guard release.apiVersion >= 1, release.minHostApiVersion >= 1 else { throw PluginCatalogError("Invalid plugin API version") }
            guard shaPattern.matches(release.sha256) else { throw PluginCatalogError("Invalid SHA-256") }
            guard (1...maxPackageBytes).contains(release.size) else { throw PluginCatalogError("Invalid plugin package size") }
            guard let downloadURL = URL(string: release.downloadUrl, relativeTo: base)?.absoluteURL else { throw PluginCatalogError("Invalid download URL") }
            var r = release
            r.downloadUrl = try requireUrl(downloadURL.absoluteString).absoluteString
            return r
        }
        return PluginCatalog(schemaVersion: schema, plugins: resolved, sourceUrl: base.absoluteString)
    }

    /// HTTP(S) URL without credentials or fragment.
    @discardableResult
    public static func requireUrl(_ value: String) throws -> URL {
        guard let url = URL(string: value.ktTrim()), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw PluginCatalogError("Expected an HTTP or HTTPS URL without credentials or fragment")
        }
        return url
    }
}
