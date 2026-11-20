import Foundation

/// Namespace-aware DOM equivalent to Android's `DocumentBuilder` output
/// (comments kept, CDATA kept as separate nodes, adjacent text merged, attributes in document order).
final class DOMNode {
    enum Kind { case element, text, cdata, comment }

    let kind: Kind
    weak var parent: DOMNode?
    var children: [DOMNode] = []

    // Element data
    var nodeName = ""
    var localName = ""
    var prefix: String?
    var namespaceURI: String?
    var attributes: [DOMAttribute] = []

    // Character data
    var value = ""

    init(kind: Kind) { self.kind = kind }

    var isElement: Bool { kind == .element }
    var isTextLike: Bool { kind == .text || kind == .cdata }

    /// DOM `textContent`.
    var textContent: String {
        switch kind {
        case .text, .cdata: return value
        case .comment: return value
        case .element:
            var out = ""
            func visit(_ n: DOMNode) {
                for c in n.children {
                    switch c.kind {
                    case .text, .cdata: out += c.value
                    case .element: visit(c)
                    case .comment: break
                    }
                }
            }
            visit(self)
            return out
        }
    }

    /// DOM `getAttributeNS(ns, local)` returning "" when absent.
    func getAttributeNS(_ namespace: String, _ local: String) -> String {
        attributes.first { $0.namespaceURI == namespace && $0.localName == local }?.value ?? ""
    }

    /// DOM `getAttribute(qualifiedName)` returning "" when absent.
    func getAttribute(_ name: String) -> String {
        attributes.first { $0.nodeName == name }?.value ?? ""
    }

    var childElements: [DOMNode] { children.filter { $0.isElement } }
}

struct DOMAttribute {
    let nodeName: String
    let localName: String
    let prefix: String?
    let namespaceURI: String?
    let value: String
}

enum NamespaceDOM {
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    static let xmlnsNamespace = "http://www.w3.org/2000/xmlns/"

    static func parse(_ text: String) throws -> DOMNode {
        let raw = try XMLTokenizer.parse(text)
        return try build(raw, parent: nil, scope: ["xml": xmlNamespace])
    }

    private static func split(_ qname: String) -> (String?, String) {
        if let idx = qname.firstIndex(of: ":") {
            return (String(qname[..<idx]), String(qname[qname.index(after: idx)...]))
        }
        return (nil, qname)
    }

    private static func build(_ raw: RawXMLElement, parent: DOMNode?, scope inherited: [String: String]) throws -> DOMNode {
        var scope = inherited
        for (name, value) in raw.attributes {
            if name == "xmlns" {
                scope[""] = value
            } else if name.hasPrefix("xmlns:") {
                scope[String(name.dropFirst(6))] = value
            }
        }
        let element = DOMNode(kind: .element)
        element.parent = parent
        element.nodeName = raw.qualifiedName
        let (prefix, local) = split(raw.qualifiedName)
        element.prefix = prefix
        element.localName = local
        if let prefix {
            guard let ns = scope[prefix] else { throw XMLError(description: "undefined prefix: \(prefix)") }
            element.namespaceURI = ns
        } else {
            let ns = scope[""] ?? ""
            element.namespaceURI = ns.isEmpty ? nil : ns
        }
        for (name, value) in raw.attributes {
            if name == "xmlns" {
                element.attributes.append(DOMAttribute(nodeName: name, localName: "xmlns", prefix: nil, namespaceURI: xmlnsNamespace, value: value))
                continue
            }
            let (p, l) = split(name)
            if let p {
                if p == "xmlns" {
                    element.attributes.append(DOMAttribute(nodeName: name, localName: l, prefix: p, namespaceURI: xmlnsNamespace, value: value))
                } else {
                    guard let ns = scope[p] else { throw XMLError(description: "undefined prefix: \(p)") }
                    element.attributes.append(DOMAttribute(nodeName: name, localName: l, prefix: p, namespaceURI: ns, value: value))
                }
            } else {
                element.attributes.append(DOMAttribute(nodeName: name, localName: name, prefix: nil, namespaceURI: nil, value: value))
            }
        }
        for child in raw.children {
            switch child {
            case .element(let e):
                element.children.append(try build(e, parent: element, scope: scope))
            case .text(let s, let cdata):
                if s.isEmpty { continue }
                if !cdata, let last = element.children.last, last.kind == .text {
                    last.value += s
                } else {
                    let node = DOMNode(kind: cdata ? .cdata : .text)
                    node.value = s
                    node.parent = element
                    element.children.append(node)
                }
            case .comment(let c):
                let node = DOMNode(kind: .comment)
                node.value = c
                node.parent = element
                element.children.append(node)
            }
        }
        return element
    }
}
