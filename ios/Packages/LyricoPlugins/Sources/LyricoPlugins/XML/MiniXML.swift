import Foundation

struct XMLError: Error, CustomStringConvertible {
    let description: String
}

/// Raw XML tree produced by `XMLTokenizer`, before namespace processing.
indirect enum RawXMLNode {
    case element(RawXMLElement)
    case text(String, cdata: Bool)
    case comment(String)
}

final class RawXMLElement {
    let qualifiedName: String
    var attributes: [(String, String)]
    var children: [RawXMLNode] = []
    init(qualifiedName: String, attributes: [(String, String)]) {
        self.qualifiedName = qualifiedName
        self.attributes = attributes
    }
}

/// A small, strict XML 1.0 parser (no DTD processing, predefined + character entities only).
/// Shared by the `Platform.xml` host API (kxml-style, non namespace aware) and the TTML DOM.
enum XMLTokenizer {
    static func parse(_ text: String) throws -> RawXMLElement {
        guard let root = try parseOptional(text) else { throw XMLError(description: "No root element") }
        return root
    }

    static func parseOptional(_ text: String) throws -> RawXMLElement? {
        let chars = Array(text.unicodeScalars)
        var i = 0
        var stack: [RawXMLElement] = []
        var root: RawXMLElement?

        func peek(_ s: String, at index: Int) -> Bool {
            var j = index
            for c in s.unicodeScalars {
                guard j < chars.count, chars[j] == c else { return false }
                j += 1
            }
            return true
        }
        func isNameChar(_ c: Unicode.Scalar) -> Bool {
            if c.ktIsWhitespace { return false }
            switch c {
            case "<", ">", "/", "=", "\"", "'", "?", "!": return false
            default: return true
            }
        }
        func skipSpace() { while i < chars.count, chars[i].ktIsWhitespace { i += 1 } }
        func readName() throws -> String {
            let start = i
            while i < chars.count, isNameChar(chars[i]) { i += 1 }
            guard i > start else { throw XMLError(description: "XML name expected at \(i)") }
            return String(String.UnicodeScalarView(chars[start..<i]))
        }
        func decodeEntities(_ raw: ArraySlice<Unicode.Scalar>) throws -> String {
            var out = String.UnicodeScalarView()
            var j = raw.startIndex
            while j < raw.endIndex {
                let c = raw[j]
                if c == "&" {
                    guard let semi = raw[j...].firstIndex(of: ";") else { throw XMLError(description: "unterminated entity ref") }
                    let name = String(String.UnicodeScalarView(raw[(j + 1)..<semi]))
                    switch name {
                    case "lt": out.append("<")
                    case "gt": out.append(">")
                    case "amp": out.append("&")
                    case "quot": out.append("\"")
                    case "apos": out.append("'")
                    default:
                        if name.hasPrefix("#x") || name.hasPrefix("#X"), let v = UInt32(name.dropFirst(2), radix: 16), let s = Unicode.Scalar(v) {
                            out.append(s)
                        } else if name.hasPrefix("#"), let v = UInt32(name.dropFirst(1)), let s = Unicode.Scalar(v) {
                            out.append(s)
                        } else {
                            throw XMLError(description: "unresolved: &\(name);")
                        }
                    }
                    j = semi + 1
                } else {
                    out.append(c)
                    j += 1
                }
            }
            return String(out)
        }
        func appendText(_ s: String, cdata: Bool) {
            guard let top = stack.last, !s.isEmpty else { return }
            top.children.append(.text(s, cdata: cdata))
        }

        while i < chars.count {
            if chars[i] == "<" {
                if peek("<!--", at: i) {
                    guard let end = findSequence(chars, "-->", from: i + 4) else { throw XMLError(description: "Unterminated comment") }
                    if let top = stack.last {
                        top.children.append(.comment(String(String.UnicodeScalarView(chars[(i + 4)..<end]))))
                    }
                    i = end + 3
                } else if peek("<![CDATA[", at: i) {
                    guard let end = findSequence(chars, "]]>", from: i + 9) else { throw XMLError(description: "Unterminated CDATA") }
                    appendText(String(String.UnicodeScalarView(chars[(i + 9)..<end])), cdata: true)
                    i = end + 3
                } else if peek("<?", at: i) {
                    guard let end = findSequence(chars, "?>", from: i + 2) else { throw XMLError(description: "Unterminated processing instruction") }
                    i = end + 2
                } else if peek("<!", at: i) {
                    // DOCTYPE or other declaration: skip, including an internal subset.
                    var depth = 0
                    i += 2
                    while i < chars.count {
                        if chars[i] == "[" { depth += 1 } else if chars[i] == "]" { depth -= 1 } else if chars[i] == ">" && depth <= 0 { break }
                        i += 1
                    }
                    guard i < chars.count else { throw XMLError(description: "Unterminated declaration") }
                    i += 1
                } else if peek("</", at: i) {
                    i += 2
                    let name = try readName()
                    skipSpace()
                    guard i < chars.count, chars[i] == ">" else { throw XMLError(description: "expected '>' in end tag") }
                    i += 1
                    guard let top = stack.popLast(), top.qualifiedName == name else {
                        throw XMLError(description: "end tag name </\(name)> must match start tag name")
                    }
                } else {
                    i += 1
                    let name = try readName()
                    var attributes: [(String, String)] = []
                    var selfClosing = false
                    while true {
                        skipSpace()
                        guard i < chars.count else { throw XMLError(description: "Unterminated start tag") }
                        if chars[i] == ">" { i += 1; break }
                        if chars[i] == "/" {
                            guard i + 1 < chars.count, chars[i + 1] == ">" else { throw XMLError(description: "expected '>'") }
                            i += 2; selfClosing = true; break
                        }
                        let attrName = try readName()
                        skipSpace()
                        guard i < chars.count, chars[i] == "=" else { throw XMLError(description: "Attr.value missing f. \(attrName)") }
                        i += 1
                        skipSpace()
                        guard i < chars.count, chars[i] == "\"" || chars[i] == "'" else { throw XMLError(description: "attribute value quote expected") }
                        let quote = chars[i]
                        i += 1
                        let start = i
                        while i < chars.count, chars[i] != quote {
                            if chars[i] == "<" { throw XMLError(description: "'<' in attribute value") }
                            i += 1
                        }
                        guard i < chars.count else { throw XMLError(description: "Unterminated attribute value") }
                        var value = try decodeEntities(chars[start..<i])
                        // Attribute value normalization of literal whitespace characters.
                        value = String(String.UnicodeScalarView(value.unicodeScalars.map { ($0 == "\n" || $0 == "\r" || $0 == "\t") ? " " : $0 }))
                        i += 1
                        if attributes.contains(where: { $0.0 == attrName }) {
                            throw XMLError(description: "Duplicate attribute: \(attrName)")
                        }
                        attributes.append((attrName, value))
                    }
                    let element = RawXMLElement(qualifiedName: name, attributes: attributes)
                    if let top = stack.last {
                        top.children.append(.element(element))
                    } else {
                        guard root == nil else { throw XMLError(description: "Multiple root elements") }
                        root = element
                    }
                    if !selfClosing { stack.append(element) }
                }
            } else {
                let start = i
                while i < chars.count, chars[i] != "<" { i += 1 }
                let raw = chars[start..<i]
                if stack.isEmpty {
                    if raw.contains(where: { !$0.ktIsWhitespace }) && root == nil {
                        throw XMLError(description: "Unexpected text before root element")
                    }
                    continue
                }
                appendText(try decodeEntities(raw), cdata: false)
            }
        }
        guard stack.isEmpty else { throw XMLError(description: "Unexpected end of document") }
        return root
    }

    private static func findSequence(_ chars: [Unicode.Scalar], _ s: String, from: Int) -> Int? {
        let target = Array(s.unicodeScalars)
        guard target.count <= chars.count else { return nil }
        var i = from
        while i + target.count <= chars.count {
            if chars[i] == target[0] && Array(chars[i..<(i + target.count)]) == target { return i }
            i += 1
        }
        return nil
    }
}
