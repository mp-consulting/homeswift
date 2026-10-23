import Foundation
import HomeswiftAI

/// JSON a log line carries (a device's state, a cloud's message), taken out of the line: the text keeps a marker
/// (`{…} 1.4 KB`) and the JSON goes beside it as the line's details, compact, its secrets masked, for the web UI
/// to expand and the Assistant to read. JSON shorter than `threshold` (an option or two) stays in the text, and
/// so does JSON a plugin cut short, which does not parse.
public enum LogDetails {
    /// The smallest JSON taken out of a line, in bytes.
    public static let threshold = 160
    /// Bracket groups looked at in a line before giving up: labels such as `[AWS]` come first.
    static let candidates = 16

    /// The text with its first JSON object or array of `threshold` bytes or more replaced by a marker, and that
    /// JSON with its secrets masked; nil when the line has none.
    public static func split(_ text: String) -> (text: String, details: String)? {
        guard text.utf8.count >= threshold else { return nil }
        let array = Array(text.utf8)
        var index = 0
        var groups = 0
        while index < array.count, groups < candidates {
            let byte = array[index]
            guard byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") else {
                index += 1
                continue
            }
            groups += 1
            // A bracket nothing closes (a stray `[`, JSON cut short): what follows may still close.
            guard let end = closing(array, from: index) else {
                index += 1
                continue
            }
            if end - index + 1 >= threshold, let value = try? JSONValue(data: Data(array[index...end])), value.objectValue != nil || value.arrayValue != nil {
                let marker = "\(byte == UInt8(ascii: "{") ? "{…}" : "[…]") \(size(end - index + 1))"
                let details = String(decoding: masked(value).encoded(), as: UTF8.self)
                return (String(decoding: array[..<index], as: UTF8.self) + marker + String(decoding: array[(end + 1)...], as: UTF8.self), details)
            }
            // A label (`[AWS]`) or a group that is not JSON: what follows it may be.
            index = end + 1
        }
        return nil
    }

    /// The index of the bracket that closes the one at `start`, skipping those inside JSON strings; nil when the
    /// text ends first (JSON cut short).
    static func closing(_ bytes: [UInt8], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if inString {
                if escaped { escaped = false } else if byte == UInt8(ascii: "\\") { escaped = true } else if byte == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return index }
            default: break
            }
        }
        return nil
    }

    /// The JSON with the values of secret-named keys (`password`, `accessToken`, `apiKey`…) and credential shapes
    /// in strings (JWTs, bearer tokens, setup codes) replaced by `Redaction.placeholder`.
    static func masked(_ value: JSONValue) -> JSONValue {
        func shapes(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let string) where string.utf8.count >= 8: .string(Redaction.redactText(string))
            case .array(let items): .array(items.map(shapes))
            case .object(let object): .object(object.mapValues(shapes))
            default: value
            }
        }
        return shapes(Redaction.redactSecrets(value))
    }

    /// `840 B`, `1.4 KB`, `2.1 MB`.
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
