import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One `<D:response>` of a PROPFIND multistatus. `hrefPath` is the decoded URL path (no scheme/host).
struct DavResource: Equatable {
    let hrefPath: String
    let isCollection: Bool
    let contentLength: Int64
    let lastModifiedMillis: Int64
}

enum WebDAVXML {
    static let propfindBody = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/><d:getcontenttype/></d:prop></d:propfind>
    """

    /// Parses a multistatus document. Matching is on local names (any prefix, default namespace, or servers that
    /// forget to declare the DAV: namespace all work).
    static func parseMultistatus(_ data: Data) throws -> [DavResource] {
        let delegate = MultistatusParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        if !parser.parse() && delegate.resources.isEmpty {
            let msg = parser.parserError?.localizedDescription ?? "unknown error"
            throw RemoteStorageError.io("Invalid WebDAV response (\(msg))")
        }
        return delegate.resources
    }

    /// Absolute or relative href -> decoded path, no trailing slash (except root).
    static func hrefToPath(_ href: String) -> String {
        var h = Substring(href)
        if let r = h.range(of: "://"), h.distance(from: h.startIndex, to: r.lowerBound) >= 1, h.distance(from: h.startIndex, to: r.lowerBound) <= 10 {
            let after = h[r.upperBound...]
            if let slash = after.firstIndex(of: "/") { h = after[slash...] } else { h = "/" }
        }
        if let q = h.firstIndex(of: "?") { h = h[..<q] }
        if let f = h.firstIndex(of: "#") { h = h[..<f] }
        return RemotePaths.normalize(RemotePaths.percentDecode(String(h)))
    }

    private static let httpDateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "EEEE, dd-MMM-yy HH:mm:ss zzz",
        "EEE MMM d HH:mm:ss yyyy",
    ]

    /// RFC 1123 (standard), RFC 850, asctime, or ISO-8601 (some servers). 0 when unparseable.
    static func parseHTTPDate(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in httpDateFormats {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = fmt
            f.isLenient = false
            if let d = f.date(from: t) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        }
        return parseISO8601(t)
    }

    static func parseISO8601(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return 0 }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: t) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        // Fractions with more than 3 digits (Go's time.Time JSON, e.g. OpenList): trim to millis.
        if let dot = t.firstIndex(of: "."), let zone = t[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let frac = t[t.index(after: dot)..<zone]
            let millis = String((frac + "000").prefix(3))
            let trimmed = String(t[..<dot]) + "." + millis + String(t[zone...])
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: trimmed) { return Int64((d.timeIntervalSince1970 * 1000).rounded()) }
        }
        return 0
    }
}

private final class MultistatusParser: NSObject, XMLParserDelegate {
    var resources: [DavResource] = []

    private var stack: [String] = []
    private var text = ""
    // current response
    private var href: String?
    private var isCollection = false
    private var length: Int64 = -1
    private var modified: Int64 = 0
    private var contentType: String?
    // current propstat
    private var psStatus: String?
    private var psCollection = false
    private var psLength: Int64?
    private var psModified: Int64?
    private var psContentType: String?

    private static func local(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = Self.local(elementName)
        stack.append(name)
        text = ""
        switch name {
        case "response":
            href = nil; isCollection = false; length = -1; modified = 0; contentType = nil
        case "propstat":
            psStatus = nil; psCollection = false; psLength = nil; psModified = nil; psContentType = nil
        case "collection":
            if stack.dropLast().last == "resourcetype" { psCollection = true }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
        switch name {
        case "href" where parent == "response":
            if href == nil { href = value }
        case "status" where parent == "propstat":
            psStatus = value
        case "getcontentlength" where parent == "prop":
            psLength = Int64(value)
        case "getlastmodified" where parent == "prop":
            psModified = WebDAVXML.parseHTTPDate(value)
        case "getcontenttype" where parent == "prop":
            psContentType = value
        case "propstat":
            if psStatus == nil || psStatus!.contains(" 200") {
                if psCollection { isCollection = true }
                if let l = psLength { length = l }
                if let m = psModified { modified = m }
                if let c = psContentType { contentType = c }
            }
        case "response":
            if let h = href {
                if contentType?.lowercased() == "httpd/unix-directory" { isCollection = true }
                resources.append(DavResource(hrefPath: WebDAVXML.hrefToPath(h), isCollection: isCollection,
                                             contentLength: isCollection ? -1 : length, lastModifiedMillis: modified))
            }
        default:
            break
        }
        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }
}
