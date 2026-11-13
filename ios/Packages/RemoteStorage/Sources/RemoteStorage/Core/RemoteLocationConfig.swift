import Foundation

/// Settings of a WebDAV location. `baseURL` is the WebDAV root, e.g. `https://host/remote.php/dav/files/alice`.
public struct WebDAVSettings: Codable, Hashable, Sendable {
    public var baseURL: String
    public var username: String
    public init(baseURL: String, username: String = "") { self.baseURL = baseURL; self.username = username }
}

/// Settings of an OpenList / Alist v3 site. Blank username = guest access.
public struct OpenListSettings: Codable, Hashable, Sendable {
    public var baseURL: String
    public var username: String
    public init(baseURL: String, username: String = "") { self.baseURL = baseURL; self.username = username }
}

/// Settings of an SMB share. `host` is `host[:port]` (default 445). Blank username = guest, then anonymous.
public struct SMBSettings: Codable, Hashable, Sendable {
    public var host: String
    public var share: String
    public var username: String
    public var domain: String
    public init(host: String, share: String, username: String = "", domain: String = "") {
        self.host = host; self.share = share; self.username = username; self.domain = domain
    }
}

/// 115 has no non-secret settings: the session cookie (UID/CID/SEID[/KID]) is the secret.
public struct Cloud115Settings: Codable, Hashable, Sendable {
    public init() {}
}

/// Typed view of the provider-specific part of a location.
public enum RemoteEndpoint: Hashable, Sendable {
    case webdav(WebDAVSettings)
    case openList(OpenListSettings)
    case smb(SMBSettings)
    case cloud115(Cloud115Settings)

    public var type: RemoteType {
        switch self {
        case .webdav: return .webdav
        case .openList: return .openList
        case .smb: return .smb
        case .cloud115: return .cloud115
        }
    }
}

/// One remote location (without its secret). The secret (password / 115 cookie) lives in a `SecretStore`
/// (Keychain on iOS) keyed by `id`.
///
/// JSON shape matches the Android app's stored config
/// (`{"id","type","name","url","share","username","domain","folders","createdAt"}`), so exports interoperate.
public struct RemoteLocationConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: RemoteType
    public var displayName: String
    /// WebDAV/OpenList: http(s) URL. SMB: `host[:port]`. 115: empty.
    public var baseURL: String
    /// SMB share name.
    public var share: String
    public var username: String
    /// SMB domain (optional).
    public var domain: String
    /// Folders on the remote chosen by the user to scan/edit.
    public var folders: [String]
    public var createdAt: Int64

    public init(
        id: String = RemoteLocationConfig.newId(),
        type: RemoteType,
        displayName: String,
        baseURL: String = "",
        share: String = "",
        username: String = "",
        domain: String = "",
        folders: [String] = ["/"],
        createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.baseURL = baseURL
        self.share = share
        self.username = username
        self.domain = domain
        self.folders = folders
        self.createdAt = createdAt
    }

    public init(id: String = RemoteLocationConfig.newId(), displayName: String, endpoint: RemoteEndpoint, folders: [String] = ["/"]) {
        self.init(id: id, type: endpoint.type, displayName: displayName, folders: folders)
        self.endpoint = endpoint
    }

    /// Typed accessor for the provider fields.
    public var endpoint: RemoteEndpoint {
        get {
            switch type {
            case .webdav: return .webdav(WebDAVSettings(baseURL: baseURL, username: username))
            case .openList: return .openList(OpenListSettings(baseURL: baseURL, username: username))
            case .smb: return .smb(SMBSettings(host: baseURL, share: share, username: username, domain: domain))
            case .cloud115: return .cloud115(Cloud115Settings())
            }
        }
        set {
            type = newValue.type
            switch newValue {
            case .webdav(let s): baseURL = s.baseURL; username = s.username; share = ""; domain = ""
            case .openList(let s): baseURL = s.baseURL; username = s.username; share = ""; domain = ""
            case .smb(let s): baseURL = s.host; share = s.share; username = s.username; domain = s.domain
            case .cloud115: baseURL = ""; share = ""; username = ""; domain = ""
            }
        }
    }

    /// Short id; used inside song uris (`remote://<id>/...`) so it must stay uri-safe.
    public static func newId() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    enum CodingKeys: String, CodingKey {
        case id, type, name, url, share, username, domain, folders, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        let rawType = try c.decodeIfPresent(String.self, forKey: .type) ?? RemoteType.webdav.rawValue
        type = RemoteType(rawValue: rawType) ?? .webdav
        displayName = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        share = try c.decodeIfPresent(String.self, forKey: .share) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        domain = try c.decodeIfPresent(String.self, forKey: .domain) ?? ""
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? ["/"]
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type.rawValue, forKey: .type)
        try c.encode(displayName, forKey: .name)
        try c.encode(baseURL, forKey: .url)
        try c.encode(share, forKey: .share)
        try c.encode(username, forKey: .username)
        try c.encode(domain, forKey: .domain)
        try c.encode(folders, forKey: .folders)
        try c.encode(createdAt, forKey: .createdAt)
    }
}
