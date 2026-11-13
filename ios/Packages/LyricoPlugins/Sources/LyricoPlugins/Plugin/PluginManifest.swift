import Foundation

/// Host API registry (`HostApiRegistry`).
public enum HostApiRegistry {
    public static let minPluginProtocolVersion = 1
    public static let pluginProtocolVersion = 5
    public static let minPlatformApiVersion = 1
    public static let platformApiVersion = 4

    public static func supportsPluginApiVersion(_ v: Int) -> Bool { (minPluginProtocolVersion...pluginProtocolVersion).contains(v) }
    public static func supportsHostApiVersion(_ v: Int) -> Bool { (minPlatformApiVersion...platformApiVersion).contains(v) }

    public static let supportedHostApis: Set<String> = [
        "i18n.getLocale", "i18n.t", "app.info", "app.userAgent", "runtime.info",
        "cache.get", "cache.set", "cache.remove", "cache.clear",
        "crypto.md5", "crypto.aesEcbPkcs5EncryptBase64", "crypto.aesEcbPkcs5EncryptHex", "crypto.aesEcbPkcs5DecryptBase64ToText",
        "base64.encodeText", "base64.decodeText", "base64.dropBytes", "base64.decodeBytes", "base64.encodeBytes",
        "base64.encodeUrlText", "base64.decodeUrlText", "base64.encodeUrlBytes", "base64.decodeUrlBytes",
        "base64.toUrl", "base64.fromUrl", "bytes.xor", "bytes.xorBase64",
        "compression.inflateBytesToText", "compression.inflateBase64ToText",
        "http.getText", "http.postText", "http.postBytes", "http.get", "http.post", "http.getBytes", "http.postBytesResponse",
        "log.debug", "log.warn", "log.error",
        "xml.getRootAttributes", "xml.findElements", "xml.replaceChildrenByAttr", "xml.removeElements"
    ]
}

public enum PluginCapability: String, Hashable, Sendable, CaseIterable, Codable {
    case searchSongs
    case getLyrics
    case searchCovers
}

/// Where a plugin can be used. Each type has its own enabled flag and ordering.
public enum PluginSourceType: String, Hashable, Sendable, CaseIterable, Codable {
    case metadata = "METADATA"
    case lyrics = "LYRICS"
    case cover = "COVER"
}

extension Set where Element == PluginCapability {
    /// Empty capabilities mean `searchSongs` only.
    public var normalized: Set<PluginCapability> { isEmpty ? [.searchSongs] : self }

    public var displaySourceTypes: [PluginSourceType] {
        let n = normalized
        var out: [PluginSourceType] = []
        if n.contains(.searchSongs) { out.append(.metadata) }
        if n.contains(.getLyrics) { out.append(.lyrics) }
        if n.contains(.searchCovers) { out.append(.cover) }
        return out
    }

    public func supports(_ type: PluginSourceType) -> Bool {
        switch type {
        case .metadata: return normalized.contains(.searchSongs)
        case .lyrics: return normalized.contains(.getLyrics)
        case .cover: return normalized.contains(.searchCovers)
        }
    }
}

public enum PluginConfigFieldType: String, Hashable, Sendable, Codable {
    case text, password, number, `switch`, dropdown, textarea, markdown
}

public struct PluginConfigOption: Hashable, Sendable {
    public var value: String
    public var label: String
    public var summary: String
    public init(value: String, label: String, summary: String = "") { self.value = value; self.label = label; self.summary = summary }
}

/// Visibility dependency of a config field (`PluginConfigDependency`).
public indirect enum PluginConfigDependency: Hashable, Sendable {
    case match(key: String, value: String)
    case and([PluginConfigDependency])
    case or([PluginConfigDependency])
    case not(PluginConfigDependency)

    /// `isSatisfied(values)`.
    public func isSatisfied(_ values: [String: String]) -> Bool {
        switch self {
        case let .match(key, value): return values[key] == value
        case .and(let conditions): return conditions.allSatisfy { $0.isSatisfied(values) }
        case .or(let conditions): return conditions.contains { $0.isSatisfied(values) }
        case .not(let condition): return !condition.isSatisfied(values)
        }
    }
}

extension Optional where Wrapped == PluginConfigDependency {
    public func isSatisfied(_ values: [String: String]) -> Bool { self?.isSatisfied(values) ?? true }
}

/// A configuration field declared by a plugin. After localisation `title`, `summary`,
/// option labels and `groupTitle` are display strings; `key`, `group` and values stay stable.
public struct PluginConfigField: Hashable, Sendable, Identifiable {
    public var key: String
    public var title: String
    public var summary: String?
    public var group: String
    public var type: PluginConfigFieldType
    public var required: Bool
    public var defaultValue: String
    public var options: [PluginConfigOption]
    public var dependency: PluginConfigDependency?
    /// Resolved group presentation; `group` remains the grouping identity.
    public var groupTitle: String?

    public var id: String { key }

    public init(key: String, title: String, summary: String? = nil, group: String = "", type: PluginConfigFieldType,
                required: Bool = false, defaultValue: String = "", options: [PluginConfigOption] = [],
                dependency: PluginConfigDependency? = nil, groupTitle: String? = nil) {
        self.key = key; self.title = title; self.summary = summary; self.group = group; self.type = type
        self.required = required; self.defaultValue = defaultValue; self.options = options
        self.dependency = dependency; self.groupTitle = groupTitle
    }
}

public struct PluginI18n: Hashable, Sendable {
    public var defaultLocale: String
    public var resources: OrderedMap<String, String>
    public init(defaultLocale: String, resources: OrderedMap<String, String>) { self.defaultLocale = defaultLocale; self.resources = resources }
}

/// `manifest.json` (`PluginManifest`).
public struct PluginManifest: Hashable, Sendable {
    public var id: String
    public var name: String
    public var versionCode: Int
    public var versionName: String
    public var author: String
    public var description: String
    public var apiVersion: Int
    public var minHostApiVersion: Int
    public var entry: String
    public var includeDirs: [String]
    public var icon: String?
    public var capabilities: Set<PluginCapability>
    public var configFields: [PluginConfigField]
    public var i18n: PluginI18n?
    public var updateUrl: String?

    public init(id: String, name: String, versionCode: Int, versionName: String, author: String = "", description: String = "",
                apiVersion: Int, minHostApiVersion: Int = 1, entry: String = "source.js", includeDirs: [String] = [],
                icon: String? = nil, capabilities: Set<PluginCapability> = [], configFields: [PluginConfigField] = [],
                i18n: PluginI18n? = nil, updateUrl: String? = nil) {
        self.id = id; self.name = name; self.versionCode = versionCode; self.versionName = versionName
        self.author = author; self.description = description; self.apiVersion = apiVersion
        self.minHostApiVersion = minHostApiVersion; self.entry = entry; self.includeDirs = includeDirs
        self.icon = icon; self.capabilities = capabilities; self.configFields = configFields
        self.i18n = i18n; self.updateUrl = updateUrl
    }
}

public struct ManifestDecodingError: Error, CustomStringConvertible {
    public let description: String
}

// MARK: - JSON decoding (kotlinx semantics: unknown keys ignored, required keys enforced, strict types)

extension PluginManifest {
    public static func decode(_ text: String) throws -> PluginManifest {
        guard case .object(let o) = try JSONValue.parse(text) else { throw ManifestDecodingError(description: "Expected JSON object for PluginManifest") }
        return try decode(o)
    }

    static func decode(_ o: JSONObject) throws -> PluginManifest {
        var capabilities = Set<PluginCapability>()
        for item in try o.optArray("capabilities") ?? [] {
            guard case .string(let s) = item, let c = PluginCapability(rawValue: s) else {
                throw ManifestDecodingError(description: "Unknown plugin capability: \(item.jsonString)")
            }
            capabilities.insert(c)
        }
        var i18n: PluginI18n?
        if let v = o["i18n"], !v.isNull {
            guard case .object(let io) = v else { throw ManifestDecodingError(description: "i18n must be an object") }
            guard case .object(let res)? = io["resources"] else { throw ManifestDecodingError(description: "Field 'resources' is required for PluginI18n") }
            var resources = OrderedMap<String, String>()
            for (k, v) in res {
                guard case .string(let s) = v else { throw ManifestDecodingError(description: "i18n resource paths must be strings") }
                resources[k] = s
            }
            i18n = PluginI18n(defaultLocale: try io.reqString("defaultLocale"), resources: resources)
        }
        return PluginManifest(
            id: try o.reqString("id"),
            name: try o.reqString("name"),
            versionCode: try o.reqInt("versionCode"),
            versionName: try o.reqString("versionName"),
            author: try o.optString("author") ?? "",
            description: try o.optString("description") ?? "",
            apiVersion: try o.reqInt("apiVersion"),
            minHostApiVersion: try o.optInt("minHostApiVersion") ?? 1,
            entry: try o.optString("entry") ?? "source.js",
            includeDirs: try (o.optArray("includeDirs") ?? []).map { v -> String in
                guard case .string(let s) = v else { throw ManifestDecodingError(description: "includeDirs must contain strings") }
                return s
            },
            icon: try o.optString("icon"),
            capabilities: capabilities,
            configFields: try (o.optArray("configFields") ?? []).map(PluginConfigField.decode),
            i18n: i18n,
            updateUrl: try o.optString("updateUrl")
        )
    }
}

extension PluginConfigField {
    static func decode(_ v: JSONValue) throws -> PluginConfigField {
        guard case .object(let o) = v else { throw ManifestDecodingError(description: "configFields entries must be objects") }
        let typeName = try o.reqString("type")
        guard let type = PluginConfigFieldType(rawValue: typeName) else {
            throw ManifestDecodingError(description: "Unknown config field type: \(typeName)")
        }
        return PluginConfigField(
            key: try o.reqString("key"),
            title: try o.reqString("title"),
            summary: try o.optString("summary"),
            group: try o.optString("group") ?? "",
            type: type,
            required: try o.optBool("required") ?? false,
            defaultValue: try o.optString("defaultValue") ?? "",
            options: try (o.optArray("options") ?? []).map { item in
                guard case .object(let oo) = item else { throw ManifestDecodingError(description: "options entries must be objects") }
                return PluginConfigOption(value: try oo.reqString("value"), label: try oo.reqString("label"), summary: try oo.optString("summary") ?? "")
            },
            dependency: try o["dependency"].flatMap { $0.isNull ? nil : try PluginConfigDependency.decode($0) }
        )
    }
}

extension PluginConfigDependency {
    static func decode(_ v: JSONValue) throws -> PluginConfigDependency {
        guard case .object(let o) = v else { throw ManifestDecodingError(description: "dependency must be an object") }
        if case .object(let m)? = o["match"] {
            return .match(key: try m.reqString("key"), value: try m.reqString("value"))
        }
        if case .object(let a)? = o["and"] {
            return .and(try (a.optArray("conditions") ?? { throw ManifestDecodingError(description: "Field 'conditions' is required") }()).map(decode))
        }
        if case .object(let a)? = o["or"] {
            return .or(try (a.optArray("conditions") ?? { throw ManifestDecodingError(description: "Field 'conditions' is required") }()).map(decode))
        }
        if case .object(let n)? = o["not"] {
            guard let c = n["condition"] else { throw ManifestDecodingError(description: "Field 'condition' is required") }
            return .not(try decode(c))
        }
        throw ManifestDecodingError(description: "Unknown config dependency discriminator, expected [match, and, or, not], got: \(o.keys)")
    }
}

extension JSONObject {
    func reqString(_ key: String) throws -> String {
        guard let s = try optString(key) else { throw ManifestDecodingError(description: "Field '\(key)' is required") }
        return s
    }
    func optString(_ key: String) throws -> String? {
        guard let v = self[key] else { return nil }
        switch v {
        case .null: return nil
        case .string(let s): return s
        default: throw ManifestDecodingError(description: "Expected string for '\(key)'")
        }
    }
    func reqInt(_ key: String) throws -> Int {
        guard let i = try optInt(key) else { throw ManifestDecodingError(description: "Field '\(key)' is required") }
        return i
    }
    func optInt(_ key: String) throws -> Int? {
        guard let v = self[key] else { return nil }
        switch v {
        case .null: return nil
        case .number(let n):
            guard let i = Int32(n) else { throw ManifestDecodingError(description: "Expected int for '\(key)'") }
            return Int(i)
        default: throw ManifestDecodingError(description: "Expected int for '\(key)'")
        }
    }
    func optBool(_ key: String) throws -> Bool? {
        guard let v = self[key] else { return nil }
        switch v {
        case .null: return nil
        case .bool(let b): return b
        default: throw ManifestDecodingError(description: "Expected boolean for '\(key)'")
        }
    }
    func optArray(_ key: String) throws -> [JSONValue]? {
        guard let v = self[key] else { return nil }
        switch v {
        case .null: return nil
        case .array(let a): return a
        default: throw ManifestDecodingError(description: "Expected array for '\(key)'")
        }
    }
}
