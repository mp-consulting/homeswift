import Foundation

/// An element of the small XML documents Baichuan carries: its name, its children and its own text. The parser is the
/// plugin's own (Foundation's `XMLParser` needs libxml2 on Linux, which the container image does not ship): elements,
/// text and the predefined entities; attributes, comments and processing instructions are skipped. Bounded in depth and
/// size, as the documents come from the network.
struct BXElement: Sendable, Equatable {
    var name: String
    var children: [BXElement] = []
    var text = ""

    func child(_ name: String) -> BXElement? { children.first { $0.name == name } }
    func value(_ name: String) -> String? { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first element of this subtree (itself included) named `name`, depth first.
    func first(_ name: String) -> BXElement? {
        if self.name == name { return self }
        for child in children { if let found = child.first(name) { return found } }
        return nil
    }

    /// Every element of this subtree named `name`.
    func all(_ name: String) -> [BXElement] {
        (self.name == name ? [self] : []) + children.flatMap { $0.all(name) }
    }

    /// Every element of the subtree, depth first.
    var descendants: [BXElement] { children.flatMap { [$0] + $0.descendants } }
}

enum BXParser {
    static let maximumDepth = 32
    static let maximumLength = 1 << 20

    struct Malformed: Error, CustomStringConvertible {
        var description: String
    }

    /// The root element of a document.
    static func parse(_ text: String) throws -> BXElement {
        let bytes = Array(text.utf8)
        guard bytes.count <= maximumLength else { throw Malformed(description: "document too large") }
        var stack = [BXElement(name: "")]
        var index = 0
        var textStart = 0
        func flushText(upTo end: Int) {
            guard end > textStart else { return }
            stack[stack.count - 1].text += decode(String(decoding: bytes[textStart..<end], as: UTF8.self))
        }
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            flushText(upTo: index)
            guard let close = bytes[index...].firstIndex(of: UInt8(ascii: ">")) else { throw Malformed(description: "unterminated tag") }
            let tag = String(decoding: bytes[(index + 1)..<close], as: UTF8.self)
            index = close + 1
            textStart = index
            if tag.hasPrefix("?") || tag.hasPrefix("!") { continue }
            if tag.hasPrefix("/") {
                let name = tag.dropFirst().trimmingCharacters(in: .whitespaces)
                guard stack.count > 1, stack[stack.count - 1].name == name else { throw Malformed(description: "unexpected </\(name)>") }
                let element = stack.removeLast()
                stack[stack.count - 1].children.append(element)
                continue
            }
            let selfClosing = tag.hasSuffix("/")
            let name = String((selfClosing ? tag.dropLast() : Substring(tag)).prefix { !$0.isWhitespace })
            guard !name.isEmpty else { throw Malformed(description: "empty tag") }
            if selfClosing {
                stack[stack.count - 1].children.append(BXElement(name: name))
            } else {
                guard stack.count <= maximumDepth else { throw Malformed(description: "nested too deeply") }
                stack.append(BXElement(name: name))
            }
        }
        guard stack.count == 1, let root = stack[0].children.first else { throw Malformed(description: "no complete root element") }
        return root
    }

    /// Text with XML's special characters as entities.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}
