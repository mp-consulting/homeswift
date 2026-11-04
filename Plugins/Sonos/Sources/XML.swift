import Foundation

/// An XML element as the players send them (SOAP responses, event property sets, DIDL-Lite, the topology): its
/// qualified name, attributes, children and text.
///
/// The parser is the plugin's own, a small one: what Sonos sends is plain XML (no DTD), and Foundation's `XMLParser`
/// lives in FoundationXML on Linux, which needs libxml2 on the machine the bridge runs on (the container image and the
/// Synology package do not ship it). It reads elements, attributes, text, CDATA and the predefined and numeric
/// entities, and skips comments, processing instructions and a doctype.
struct XElement: Sendable, Equatable {
    var name: String
    var attributes: [String: String] = [:]
    var children: [XElement] = []
    /// The text directly inside this element, entities decoded.
    var text = ""

    /// The name without its namespace prefix: `u:GetLEDStateResponse` → `GetLEDStateResponse`.
    var localName: String { name.split(separator: ":").last.map(String.init) ?? name }

    /// The first child whose local name is `name`.
    func child(_ name: String) -> XElement? { children.first { $0.localName == name } }

    /// Every child whose local name is `name`.
    func children(_ name: String) -> [XElement] { children.filter { $0.localName == name } }

    /// The first element of this subtree (itself included) whose local name is `name`, depth first.
    func first(_ name: String) -> XElement? {
        if localName == name { return self }
        for child in children { if let found = child.first(name) { return found } }
        return nil
    }

    /// Every element of this subtree (itself included) whose local name is `name`, in document order.
    func all(_ name: String) -> [XElement] {
        var found: [XElement] = []
        func walk(_ element: XElement) {
            if element.localName == name { found.append(element) }
            element.children.forEach(walk)
        }
        walk(self)
        return found
    }

    /// The text of the first child named `name`.
    func value(_ name: String) -> String? { child(name)?.text }

    /// An attribute by its local name, whatever its prefix.
    func attribute(_ name: String) -> String? {
        attributes[name] ?? attributes.first { $0.key.split(separator: ":").last.map(String.init) == name }?.value
    }
}

enum XMLError: Error, CustomStringConvertible, Equatable {
    case malformed(String)
    case tooDeep

    var description: String {
        switch self {
        case .malformed(let reason): "malformed XML: \(reason)"
        case .tooDeep: "XML nested too deeply"
        }
    }
}

enum XML {
    /// Elements deeper than this fail the parse, so a hostile body cannot exhaust memory with nesting.
    static let maximumDepth = 64

    /// Parses a document (or a fragment with one root element) into its root element.
    static func parse(_ text: String) throws -> XElement {
        let roots = try parseFragment(text)
        guard roots.count == 1, let root = roots.first else { throw XMLError.malformed(roots.isEmpty ? "no element" : "several root elements") }
        return root
    }

    /// Parses text that may hold several top-level elements (an older `ZoneGroupState` without its outer element).
    static func parseFragment(_ text: String) throws -> [XElement] {
        let bytes = Array(text.utf8)
        var index = 0
        var stack: [XElement] = [XElement(name: "")]

        func starts(with prefix: String) -> Bool {
            let prefix = Array(prefix.utf8)
            return index + prefix.count <= bytes.count && Array(bytes[index..<index + prefix.count]) == prefix
        }
        func skip(past terminator: String) throws {
            let terminator = Array(terminator.utf8)
            while index + terminator.count <= bytes.count {
                if Array(bytes[index..<index + terminator.count]) == terminator {
                    index += terminator.count
                    return
                }
                index += 1
            }
            throw XMLError.malformed("unterminated \(String(decoding: terminator, as: UTF8.self))")
        }
        func isNameByte(_ byte: UInt8) -> Bool {
            !(byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == UInt8(ascii: ">") || byte == UInt8(ascii: "/")
                || byte == UInt8(ascii: "=") || byte == UInt8(ascii: "<"))
        }
        func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }
        func readName() throws -> String {
            let start = index
            while index < bytes.count, isNameByte(bytes[index]) { index += 1 }
            guard index > start else { throw XMLError.malformed("a name is missing") }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
        func appendText(_ text: String) {
            guard stack.count > 1 else { return }
            stack[stack.count - 1].text += text
        }

        while index < bytes.count {
            if bytes[index] != UInt8(ascii: "<") {
                let start = index
                while index < bytes.count, bytes[index] != UInt8(ascii: "<") { index += 1 }
                appendText(decodeEntities(String(decoding: bytes[start..<index], as: UTF8.self)))
                continue
            }
            if starts(with: "<!--") {
                try skip(past: "-->")
            } else if starts(with: "<![CDATA[") {
                index += 9
                let start = index
                try skip(past: "]]>")
                appendText(String(decoding: bytes[start..<index - 3], as: UTF8.self))
            } else if starts(with: "<?") {
                try skip(past: "?>")
            } else if starts(with: "<!") {
                try skip(past: ">")
            } else if starts(with: "</") {
                index += 2
                let name = try readName()
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ">") else { throw XMLError.malformed("bad closing tag \(name)") }
                index += 1
                guard stack.count > 1, stack[stack.count - 1].name == name else { throw XMLError.malformed("unexpected </\(name)>") }
                let element = stack.removeLast()
                stack[stack.count - 1].children.append(element)
            } else {
                index += 1
                var element = XElement(name: try readName())
                var selfClosing = false
                while true {
                    skipSpace()
                    guard index < bytes.count else { throw XMLError.malformed("unterminated <\(element.name)>") }
                    if bytes[index] == UInt8(ascii: ">") { index += 1; break }
                    if bytes[index] == UInt8(ascii: "/") {
                        guard index + 1 < bytes.count, bytes[index + 1] == UInt8(ascii: ">") else { throw XMLError.malformed("bad tag \(element.name)") }
                        index += 2
                        selfClosing = true
                        break
                    }
                    let attribute = try readName()
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "=") else { throw XMLError.malformed("attribute \(attribute) without a value") }
                    index += 1
                    skipSpace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") else {
                        throw XMLError.malformed("unquoted attribute \(attribute)")
                    }
                    let quote = bytes[index]
                    index += 1
                    let start = index
                    while index < bytes.count, bytes[index] != quote { index += 1 }
                    guard index < bytes.count else { throw XMLError.malformed("unterminated attribute \(attribute)") }
                    element.attributes[attribute] = decodeEntities(String(decoding: bytes[start..<index], as: UTF8.self))
                    index += 1
                }
                if selfClosing {
                    stack[stack.count - 1].children.append(element)
                } else {
                    guard stack.count <= maximumDepth else { throw XMLError.tooDeep }
                    stack.append(element)
                }
            }
        }
        guard stack.count == 1, let document = stack.first else { throw XMLError.malformed("unclosed <\(stack.last?.name ?? "")>") }
        return document.children
    }

    /// Decodes XML's predefined entities and numeric character references; an unknown entity stays as it is.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)
        while let ampersand = rest.firstIndex(of: "&") {
            result += rest[..<ampersand]
            let after = rest[rest.index(after: ampersand)...]
            guard let semicolon = after.prefix(12).firstIndex(of: ";") else {
                result += "&"
                rest = after
                continue
            }
            let entity = after[..<semicolon]
            if let decoded = decodeEntity(entity) {
                result += decoded
            } else {
                result += "&\(entity);"
            }
            rest = after[after.index(after: semicolon)...]
        }
        result += rest
        return result
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        switch entity {
        case "lt": return "<"
        case "gt": return ">"
        case "amp": return "&"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard entity.hasPrefix("#") else { return nil }
            let digits = entity.dropFirst()
            let code = digits.hasPrefix("x") || digits.hasPrefix("X") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return code.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }

    /// Escapes text for an XML element or attribute, as the plugin stores URIs and sends values: `&`, `<`, `>`, `"`,
    /// `'` and `` ` ``.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            case "`": result += "&#96;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Decodes HTML's named entities a title may still carry after the XML decoding (Sonos escapes some twice), and the
    /// numeric ones.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var decoded = decodeEntities(text)
        for (entity, character) in htmlEntities where decoded.contains(entity) {
            decoded = decoded.replacingOccurrences(of: entity, with: character)
        }
        return decoded
    }

    private static let htmlEntities: [(String, String)] = [
        ("&nbsp;", "\u{00A0}"), ("&eacute;", "é"), ("&egrave;", "è"), ("&agrave;", "à"), ("&uuml;", "ü"), ("&ouml;", "ö"),
        ("&auml;", "ä"), ("&szlig;", "ß"), ("&ccedil;", "ç"), ("&ntilde;", "ñ"), ("&hellip;", "…"), ("&ndash;", "–"),
        ("&mdash;", "—"), ("&rsquo;", "’"), ("&lsquo;", "‘"), ("&rdquo;", "”"), ("&ldquo;", "“"), ("&copy;", "©"),
    ]
}
