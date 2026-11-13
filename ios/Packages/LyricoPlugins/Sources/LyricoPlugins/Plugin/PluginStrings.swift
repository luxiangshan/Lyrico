import Foundation

public struct PluginStringsError: Error, CustomStringConvertible {
    public let description: String
    init(_ d: String) { description = d }
}

/// A string argument for `Platform.i18n.t` / `PluginStringFormat`.
public enum PluginStringArgument: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case none
}

/// Port of `PluginStringFormat`: a small positional subset of Android format syntax.
public enum PluginStringFormat {
    private static let token = KRegex("%(?:([1-9][0-9]*)\\$)?([sd%])")
    private static let argPattern = KRegex("%(?:[1-9][0-9]*\\$)?[sd]")

    public static func hasArguments(_ text: String) -> Bool { argPattern.containsMatch(text) }

    public static func signature(_ text: String) throws -> [Int: String] {
        var result: [Int: String] = [:]
        let ns = text as NSString
        var offset = 0
        var implicit = 0
        var hasImplicit = false, hasExplicit = false
        while true {
            let r = ns.range(of: "%", options: [], range: NSRange(location: offset, length: ns.length - offset))
            if r.location == NSNotFound { break }
            let start = r.location
            guard let match = token.find(text, startIndex: start), match.first == start else {
                throw PluginStringsError("Unsupported format at \(start): \(text)")
            }
            offset = match.end
            let type = match.groupValues[2]
            let position = match.groupValues[1]
            if type == "%" {
                guard position.isEmpty else { throw PluginStringsError("Use %% for a literal percent") }
                continue
            }
            let index: Int
            if position.isEmpty { hasImplicit = true; implicit += 1; index = implicit } else { hasExplicit = true; index = Int(position) ?? Int.max }
            guard index <= 64 else { throw PluginStringsError("At most 64 format arguments are supported") }
            guard result[index] == nil || result[index] == type else { throw PluginStringsError("Conflicting argument types at \(index)") }
            result[index] = type
        }
        guard !(hasImplicit && hasExplicit) else { throw PluginStringsError("Do not mix indexed and unindexed placeholders") }
        guard !hasImplicit || implicit <= 1 else { throw PluginStringsError("Multiple arguments require positional placeholders") }
        guard result.keys.sorted() == Array(stride(from: 1, through: result.count, by: 1)) else {
            throw PluginStringsError("Argument indexes must be contiguous")
        }
        return result
    }

    public static func format(_ text: String, _ args: [PluginStringArgument]) throws -> String {
        let sig = try signature(text)
        guard args.count == sig.count else { throw PluginStringsError("Expected \(sig.count) arguments, got \(args.count)") }
        for (index, type) in sig {
            let value = args[index - 1]
            let ok: Bool
            if type == "s" {
                if case .string = value { ok = true } else { ok = false }
            } else {
                switch value {
                case .integer(let i): ok = abs(Double(i)) <= 9007199254740991.0
                case .double(let d): ok = d.isFinite && abs(d) <= 9007199254740991.0 && d == Double(Int64(clampingDouble: d))
                default: ok = false
                }
            }
            guard ok else { throw PluginStringsError("Invalid argument \(index) for %\(type)") }
        }
        var implicit = 0
        return token.replace(text) { match in
            let type = match.groupValues[2]
            if type == "%" { return "%" }
            let index: Int
            if let explicit = Int(match.groupValues[1]) { index = explicit - 1 } else { index = implicit; implicit += 1 }
            switch args[index] {
            case .string(let s): return s
            case .integer(let i): return String(i)
            case .double(let d): return String(Int64(clampingDouble: d))
            case .none: return ""
            }
        }
    }
}

/// Minimal BCP 47 handling equivalent to `java.util.Locale.forLanguageTag` for language/script/region.
struct LocaleTag: Hashable {
    var language: String
    var script: String
    var country: String

    init(_ tag: String) {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var language = "", script = "", country = ""
        var i = 0
        if i < parts.count, parts[i].count >= 2, parts[i].count <= 8, parts[i].allSatisfy({ $0.isASCII && $0.isLetter }) {
            language = parts[i].lowercased(); i += 1
            if i < parts.count, parts[i].count == 4, parts[i].allSatisfy({ $0.isASCII && $0.isLetter }) {
                script = parts[i].prefix(1).uppercased() + parts[i].dropFirst().lowercased(); i += 1
            }
            if i < parts.count, (parts[i].count == 2 && parts[i].allSatisfy({ $0.isASCII && $0.isLetter })) ||
                (parts[i].count == 3 && parts[i].allSatisfy({ $0.isASCII && $0.isNumber })) {
                country = parts[i].uppercased(); i += 1
            }
        }
        self.language = language; self.script = script; self.country = country
    }

    var languageTag: String {
        if language.isEmpty { return "und" }
        return [language, script, country].filter { !$0.isEmpty }.joined(separator: "-")
    }

    /// `Locale.Builder().setLanguageTag(tag).build().toLanguageTag() == tag`.
    static func isCanonical(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let first = parts.first, (2...8).contains(first.count), first != "und",
              first.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return false }
        var i = 1
        if i < parts.count, parts[i].count == 4, parts[i].allSatisfy({ $0.isASCII && $0.isLetter }) {
            guard parts[i] == parts[i].prefix(1).uppercased() + parts[i].dropFirst().lowercased() else { return false }
            i += 1
        }
        if i < parts.count, (parts[i].count == 2 && parts[i].allSatisfy({ $0.isASCII && $0.isLetter })) ||
            (parts[i].count == 3 && parts[i].allSatisfy({ $0.isASCII && $0.isNumber })) {
            guard parts[i] == parts[i].uppercased() else { return false }
            i += 1
        }
        while i < parts.count {
            let p = parts[i]
            let isVariant = ((5...8).contains(p.count) || (p.count == 4 && p.first!.isNumber)) && p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
            guard isVariant, p == p.lowercased() else { return false }
            i += 1
        }
        return true
    }
}

/// Port of `PluginStrings` (plugin i18n catalogs + `@key` resolution).
public final class PluginStrings: @unchecked Sendable {
    let defaultLocale: String
    let resources: [String: [String: String]]

    private init(defaultLocale: String, resources: [String: [String: String]]) {
        self.defaultLocale = defaultLocale
        self.resources = resources
    }

    /// Script inference for locales without an explicit script (ICU likely-subtags on Apple platforms).
    public nonisolated(unsafe) static var inferScript: (String) -> String = { tag in
        #if canImport(Darwin)
        if #available(iOS 16, macOS 13, *) {
            let language = Locale.Language(identifier: tag)
            if let script = language.maximalIdentifier.split(separator: "-").dropFirst().first(where: { $0.count == 4 }) {
                return String(script)
            }
        }
        #endif
        let locale = LocaleTag(tag)
        if locale.language == "zh" { return ["TW", "HK", "MO"].contains(locale.country) ? "Hant" : "Hans" }
        return ""
    }

    private static func script(_ locale: LocaleTag) -> String {
        locale.script.isEmpty ? inferScript(locale.languageTag) : locale.script
    }

    public final class Snapshot: @unchecked Sendable {
        public let locale: String
        let chain: [[String: String]]
        init(locale: String, chain: [[String: String]]) { self.locale = locale; self.chain = chain }

        /// Resolve once: `@@x` → `@x`, `@key` → catalog value, anything else literal.
        public func text(_ value: String) throws -> String {
            if value.hasPrefix("@@") { return String(value.dropFirst()) }
            if value.hasPrefix("@") { return try lookup(String(value.dropFirst())) }
            return value
        }

        func lookup(_ key: String) throws -> String {
            for map in chain { if let v = map[key] { return v } }
            throw PluginStringsError("Unknown plugin string: \(key)")
        }

        public func format(_ key: String, _ args: [PluginStringArgument]) throws -> String {
            let template = try lookup(key)
            return args.isEmpty ? template : try PluginStringFormat.format(template, args)
        }

        /// Localise display strings of a manifest; stable values are untouched.
        public func localize(_ manifest: PluginManifest) throws -> PluginManifest {
            var m = manifest
            m.name = try text(manifest.name)
            m.description = try text(manifest.description)
            m.configFields = try manifest.configFields.map { field in
                var f = field
                f.title = try text(field.title)
                f.summary = try field.summary.map(text)
                f.groupTitle = try text(field.group)
                if field.type == .markdown {
                    f.defaultValue = try text(field.defaultValue.ktIsBlank ? (field.summary ?? "") : field.defaultValue)
                }
                f.options = try field.options.map { o in
                    var oo = o
                    oo.label = try text(o.label)
                    oo.summary = try text(o.summary)
                    return oo
                }
                return f
            }
            return m
        }
    }

    public func snapshot(_ preferences: [String]) -> Snapshot {
        let available = resources.keys.sorted()
        var selected: String?
        for preference in preferences {
            let wanted = LocaleTag(preference)
            if let exact = available.first(where: { $0.caseInsensitiveCompare(wanted.languageTag) == .orderedSame }) {
                selected = exact; break
            }
            let candidates = available.filter {
                let c = LocaleTag($0)
                return c.language == wanted.language && Self.script(c) == Self.script(wanted)
            }.sorted { a, b in
                let ac = !LocaleTag(a).country.isEmpty, bc = !LocaleTag(b).country.isEmpty
                if ac != bc { return !ac }
                return a < b
            }
            if let first = candidates.first { selected = first; break }
        }
        let chosen = selected ?? defaultLocale
        let locale = LocaleTag(chosen)
        var parents: [String] = []
        if !locale.country.isEmpty { parents.append([locale.language, locale.script].filter { !$0.isEmpty }.joined(separator: "-")) }
        if Self.script(LocaleTag(locale.language)) == Self.script(locale) { parents.append(locale.language) }
        let order = ([chosen] + parents + [defaultLocale]).ktDistinct()
        return Snapshot(locale: chosen, chain: order.compactMap { resources[$0] })
    }

    static let maxBytes = 512 * 1024

    /// Load and validate catalogs (`PluginStrings.load`). Throws on any install-time violation.
    public static func load(root: URL, manifest: PluginManifest) throws -> PluginStrings {
        var refs: [String] = [manifest.name, manifest.description]
        for field in manifest.configFields {
            refs.append(field.title); refs.append(field.summary ?? ""); refs.append(field.group)
            if field.type == .markdown { refs.append(field.defaultValue) }
            for o in field.options { refs.append(o.label); refs.append(o.summary) }
        }
        let references = Set(refs.filter { $0.hasPrefix("@") && !$0.hasPrefix("@@") }.map { String($0.dropFirst()) })
        guard !references.contains(where: { $0.ktIsBlank }) else { throw PluginStringsError("Empty plugin string reference") }
        guard let spec = manifest.i18n else {
            guard references.isEmpty else { throw PluginStringsError("String references require i18n resources") }
            return PluginStrings(defaultLocale: "und", resources: [:])
        }
        guard references.isEmpty || manifest.minHostApiVersion >= 4 else { throw PluginStringsError("String references require minHostApiVersion >= 4") }
        guard (1...64).contains(spec.resources.count) else { throw PluginStringsError("Expected 1..64 plugin locales") }
        guard spec.resources.contains(spec.defaultLocale) else { throw PluginStringsError("Default locale resource is missing") }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var catalogs: [String: [String: String]] = [:]
        for (tag, path) in spec.resources {
            guard LocaleTag.isCanonical(tag) else { throw PluginStringsError("Use a canonical BCP 47 locale: \(tag)") }
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0.isEmpty }) else {
                throw PluginStringsError("Unsafe locale path: \(path)")
            }
            let file = canonicalRoot.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard file.path.hasPrefix(canonicalRoot.path + "/"), FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue,
                  file.pathExtension == "json" else {
                throw PluginStringsError("Invalid locale resource: \(path)")
            }
            let data = try Data(contentsOf: file)
            guard data.count <= maxBytes else { throw PluginStringsError("Locale resource exceeds 512 KiB: \(path)") }
            guard case .object(let o) = try JSONValue.parse(data: data) else { throw PluginStringsError("Locale resource must be a JSON object: \(path)") }
            var values: [String: String] = [:]
            for (k, v) in o {
                guard case .string(let s) = v else { throw PluginStringsError("Locale values must be strings: \(path)") }
                guard k.ktIsNotBlank else { throw PluginStringsError("Empty resource key") }
                values[k] = s
            }
            catalogs[tag] = values
        }
        let defaults = catalogs[spec.defaultLocale]!
        var formattedKeys = Set<String>()
        for values in catalogs.values {
            for (k, v) in values where !references.contains(k) && PluginStringFormat.hasArguments(v) { formattedKeys.insert(k) }
        }
        for (tag, values) in catalogs {
            for (key, value) in values {
                guard let d = defaults[key] else { throw PluginStringsError("\(tag)/\(key) is absent from default resources") }
                if formattedKeys.contains(key) {
                    guard try PluginStringFormat.signature(value) == PluginStringFormat.signature(d) else {
                        throw PluginStringsError("\(tag)/\(key) has incompatible placeholders")
                    }
                }
            }
        }
        for key in references where defaults[key] == nil { throw PluginStringsError("Missing default string: \(key)") }
        return PluginStrings(defaultLocale: spec.defaultLocale, resources: catalogs)
    }

    /// Diagnostic display name (`PluginNames.resolve`).
    public static func displayName(manifest: PluginManifest, root: URL, preferences: [String]) -> String {
        if let strings = try? load(root: root, manifest: manifest), let n = try? strings.snapshot(preferences).text(manifest.name), n.ktIsNotBlank {
            return n
        }
        if manifest.name.hasPrefix("@@") { return String(manifest.name.dropFirst()) }
        if manifest.name.hasPrefix("@") || manifest.name.ktIsBlank { return manifest.id }
        return manifest.name
    }
}
