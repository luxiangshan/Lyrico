import Foundation

/// Port of `HostXmlApi`: non-namespace-aware tree editing with KXmlSerializer-compatible output.
enum HostXmlApi {
    final class Node {
        enum Kind { case element, text }
        let kind: Kind
        var name: String?
        var attributes: [(String, String)] = []
        var children: [Node] = []
        var text: String?

        init(element name: String) { kind = .element; self.name = name }
        init(text: String) { kind = .text; self.text = text }

        func attribute(_ name: String) -> String? { attributes.first { $0.0 == name }?.1 }
        func setAttribute(_ name: String, _ value: String) {
            if let idx = attributes.firstIndex(where: { $0.0 == name }) { attributes[idx].1 = value } else { attributes.append((name, value)) }
        }
    }

    static func getRootAttributes(xml: String) throws -> JSONValue {
        let root = try parse(xml)
        return .object(JSONObject(root.attributes.map { ($0.0, .string($0.1)) }))
    }

    static func findElements(xml: String, query: JSONObject) throws -> JSONValue {
        let root = try parse(xml)
        let tag = query.string("tag")
        let attrs = query.obj("attrs") ?? JSONObject()
        var results: [JSONValue] = []
        try walk(root) { node in
            guard node.kind == .element else { return }
            if tag.ktIsNotBlank && node.name != tag { return }
            if !attrsMatch(node, attrs) { return }
            results.append(try toJSON(node))
        }
        return .array(results)
    }

    static func replaceChildrenByAttr(xml: String, options: JSONObject) throws -> String {
        let root = try parse(xml)
        let targetTag = options.string("targetTag")
        let keyAttr = options.string("keyAttr")
        let replacements = options.obj("replacements") ?? JSONObject()
        let rootAttributes = options.obj("rootAttributes") ?? JSONObject()
        if targetTag.ktIsBlank || keyAttr.ktIsBlank { return xml }

        for (name, value) in rootAttributes {
            guard value.isPrimitive else { throw XMLError(description: "Element \(value.jsonString) is not a JsonPrimitive") }
            root.setAttribute(name, value.contentOrNull ?? "")
        }
        try walk(root) { node in
            guard node.kind == .element, node.name == targetTag else { return }
            let key = node.attribute(keyAttr) ?? ""
            if key.ktIsBlank { return }
            guard let replacementValue = replacements[key] else { return }
            guard let replacement = replacementValue.objectValue else {
                throw XMLError(description: "Element \(replacementValue.jsonString) is not a JsonObject")
            }
            let modeRaw = replacement.string("mode")
            let mode = modeRaw.ktIsBlank ? "text" : modeRaw
            let value = replacement.string("value")
            node.children.removeAll()
            if mode == "xml" {
                node.children.append(contentsOf: try parse("<root>" + value + "</root>").children)
            } else {
                node.children.append(Node(text: value))
            }
        }
        return try serialize(root)
    }

    static func removeElements(xml: String, query: JSONObject) throws -> String {
        let root = try parse(xml)
        let tag = query.string("tag")
        let attrs = query.obj("attrs") ?? JSONObject()
        func removeIn(_ node: Node) {
            node.children = node.children.filter { child in
                if child.kind == .element && (tag.ktIsBlank || child.name == tag) && attrsMatch(child, attrs) {
                    return false
                }
                removeIn(child)
                return true
            }
        }
        removeIn(root)
        try walk(root) { current in
            guard current.kind == .element, current.name == "translations" else { return }
            if !current.children.contains(where: { $0.kind == .element }) { current.children.removeAll() }
        }
        return try serialize(root)
    }

    // MARK: Parsing (kxml `next()` semantics: comments dropped, adjacent text coalesced)

    static func parse(_ xml: String) throws -> Node {
        guard let raw = try XMLTokenizer.parseOptional(xml) else { return Node(element: "root") }
        return convert(raw)
    }

    private static func convert(_ raw: RawXMLElement) -> Node {
        let node = Node(element: raw.qualifiedName)
        node.attributes = raw.attributes
        var pendingText: String?
        for child in raw.children {
            switch child {
            case .text(let s, _):
                pendingText = (pendingText ?? "") + s
            case .comment:
                continue
            case .element(let e):
                if let t = pendingText, !t.isEmpty { node.children.append(Node(text: t)) }
                pendingText = nil
                node.children.append(convert(e))
            }
        }
        if let t = pendingText, !t.isEmpty { node.children.append(Node(text: t)) }
        return node
    }

    // MARK: Serialization (KXmlSerializer with a Writer output: non-ASCII as character references)

    static func serialize(_ node: Node) throws -> String {
        var out = ""
        try write(node, &out)
        return out
    }

    private static func write(_ node: Node, _ out: inout String) throws {
        switch node.kind {
        case .text:
            try escape(node.text ?? "", quote: nil, &out)
        case .element:
            let name = node.name ?? ""
            out += "<" + name
            for (k, v) in node.attributes {
                out += " " + k + "=\""
                try escape(v, quote: "\"", &out)
                out += "\""
            }
            if node.children.isEmpty {
                out += " />"
            } else {
                out += ">"
                for child in node.children { try write(child, &out) }
                out += "</" + name + ">"
            }
        }
    }

    private static func escape(_ s: String, quote: Unicode.Scalar?, _ out: inout String) throws {
        for c in s.unicodeScalars {
            switch c {
            case "\n", "\r", "\t":
                if quote == nil { out.unicodeScalars.append(c) } else { out += "&#\(c.value);" }
            case "&": out += "&amp;"
            case ">": out += "&gt;"
            case "<": out += "&lt;"
            default:
                if let quote, c == quote {
                    out += quote == "\"" ? "&quot;" : "&apos;"
                    continue
                }
                let v = c.value
                let allowed = (v >= 0x20 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0xFFFD) || v >= 0x10000
                guard allowed else {
                    throw XMLError(description: "java.lang.IllegalArgumentException: Illegal character (U+\(String(v, radix: 16)))")
                }
                if v < 127 { out.unicodeScalars.append(c) } else { out += "&#\(v);" }
            }
        }
    }

    // MARK: Helpers

    private static func walk(_ node: Node, _ block: (Node) throws -> Void) rethrows {
        try block(node)
        for child in node.children { try walk(child, block) }
    }

    private static func attrsMatch(_ node: Node, _ attrs: JSONObject) -> Bool {
        attrs.allSatisfy { name, value in
            node.attribute(name) == (value.contentOrNull ?? "")
        }
    }

    private static func toJSON(_ node: Node) throws -> JSONValue {
        var obj = JSONObject()
        obj["tag"] = .string(node.name ?? "")
        obj["attrs"] = .object(JSONObject(node.attributes.map { ($0.0, .string($0.1)) }))
        obj["text"] = .string(textContent(node))
        obj["innerXml"] = .string(try node.children.map { try serialize($0) }.joined())
        obj["children"] = .array(try node.children.filter { $0.kind == .element }.map { try toJSON($0) })
        return .object(obj)
    }

    private static func textContent(_ node: Node) -> String {
        switch node.kind {
        case .text: return node.text ?? ""
        case .element: return node.children.map { textContent($0) }.joined()
        }
    }
}

extension JSONObject {
    /// `this[key]?.jsonPrimitive?.contentOrNull.orEmpty()`.
    func string(_ key: String) -> String { self[key]?.contentOrNull ?? "" }
    func obj(_ key: String) -> JSONObject? { self[key]?.objectValue }
}
