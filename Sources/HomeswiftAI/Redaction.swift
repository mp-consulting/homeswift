import Foundation

/// Keeps credentials out of the model's context.
///
/// `redactSecrets` swaps secret-looking values in a configuration for a placeholder before it is shown;
/// `restoreSecrets` puts the real values back when the model writes the configuration, so a read, edit,
/// write round trip is lossless. `redactText` is the best-effort version for free text such as logs.
public enum Redaction {
    public static let placeholder = "__REDACTED__"

    /// Keys whose values are secrets: password, mqttPass, apiKey, clientSecret, bridge.pin.
    private static let secretKey = try! NSRegularExpression(pattern: #"pass(word|wd|phrase)?$|secret|token|api[-_]?key|private[-_]?key|credential|^pin$"#, options: [.caseInsensitive])
    /// Keys that look secret but hold token counts: maxOutputTokens, contextTokens.
    private static let notSecretKey = try! NSRegularExpression(pattern: #"(max|min|context|input|output|total)\w*tokens$"#, options: [.caseInsensitive])
    /// `key: value`, `key=value` and `"key": "value"` pairs whose key names a secret (including HomeKit's
    /// pin and setup code).
    private static let secretPair = try! NSRegularExpression(
        pattern: #"(["']?)([\w.-]*(?:password|passwd|passphrase|pass|pin|setup[-_ ]?code|secret|token|api[-_]?key|private[-_]?key|credential)[\w-]*)\1(\s*[:=]\s*)(["']?)([^\s"',;}&]+)\4"#,
        options: [.caseInsensitive])
    /// Well-known credential shapes that can appear anywhere in free text: API keys, JWTs, and HomeKit
    /// setup codes (`031-45-154`, `0314-5154`) and setup URIs, which the bridge prints at launch.
    private static let secretShapes: [NSRegularExpression] = [
        #"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"\bsk-[A-Za-z0-9_-]{16,}"#,
        #"\bhbg_[A-Za-z0-9_-]{8,}"#,
        #"\bAIza[0-9A-Za-z_-]{30,}"#,
        #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        #"\bX-HM://[0-9A-Z]+"#,
        #"\b\d{3}-\d{2}-\d{3}\b"#,
        #"\b\d{4}-\d{4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Fields that identify an entry in an array such as `platforms`.
    private static let identityKeys = ["platform", "accessory", "name", "id", "username"]

    private static func matches(_ expression: NSRegularExpression, _ string: String) -> Bool {
        expression.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    /// Whether the value under `key` is treated as a secret.
    public static func isSecretKey(_ key: String) -> Bool {
        matches(secretKey, key) && !matches(notSecretKey, key)
    }

    private static func isSecretValue(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string): !string.isEmpty && !isConcealed(string)
        case .number: true
        default: false
        }
    }

    /// The placeholder, or a `SecretVault` handle: a value that already hides a secret.
    public static func isConcealed(_ string: String) -> Bool {
        string == placeholder || SecretVault.isHandle(string)
    }

    /// Masks addresses in text for a provider: e-mail addresses (cloud account logins), MAC addresses, IPv4,
    /// bracketed IPv6 and `.local` host names, as the Homebridge UIs' `scrubAddresses` does. A device's address
    /// helps nobody explain its error.
    public static func scrubAddresses(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#, "<email>"),
            (#"\b(?:[0-9A-Fa-f]{1,2}[:-]){5}[0-9A-Fa-f]{1,2}\b"#, "<MAC>"),
            (#"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, "<IP>"),
            (#"\[[0-9A-Fa-f:]*:[0-9A-Fa-f:]*\]"#, "<IP>"),
            (#"\b[\w-]+\.local\b"#, "<hostname>.local"),
        ]
        for (pattern, replacement) in patterns {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return result
    }

    /// `scrubAddresses` on every string of a value.
    public static func scrubAddresses(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text): .string(scrubAddresses(text))
        case .array(let items): .array(items.map(scrubAddresses))
        case .object(let object): .object(object.mapValues(scrubAddresses))
        default: value
        }
    }

    /// A copy of `value` with every secret replaced by the placeholder, or by what `replacing` makes of it
    /// (a `SecretVault`'s handle).
    public static func redactSecrets(_ value: JSONValue, underSecretKey: Bool = false, replacing: (JSONValue) -> JSONValue = { _ in .string(placeholder) }) -> JSONValue {
        switch value {
        case .array(let items):
            return .array(items.map { redactSecrets($0, underSecretKey: underSecretKey, replacing: replacing) })
        case .object(let object):
            return .object(object.reduce(into: [:]) { result, entry in
                result[entry.key] = redactSecrets(entry.value, underSecretKey: underSecretKey || isSecretKey(entry.key), replacing: replacing)
            })
        default:
            return underSecretKey && isSecretValue(value) ? replacing(value) : value
        }
    }

    public static func containsRedacted(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let string): string == placeholder
        case .array(let items): items.contains(where: containsRedacted)
        case .object(let object): object.values.contains(where: containsRedacted)
        default: false
        }
    }

    public struct RestoreError: Error, CustomStringConvertible, Sendable {
        public let paths: [String]
        public var description: String {
            // Worded so that redactText, which every error passes through, finds no "key: value" pair to mask.
            "Cannot restore \(placeholder) (no matching value in the current config) in \(paths.joined(separator: ", ")). "
                + "Supply the real value, or keep the entry's identifying fields (platform, accessory, name) unchanged."
        }
    }

    private static func identity(_ item: JSONValue, index: Int) -> String {
        if let object = item.objectValue {
            let parts = identityKeys.compactMap { key -> String? in
                guard let value = object[key] else { return nil }
                switch value {
                case .string(let string): return "\(key)=\(string)"
                case .number: return "\(key)=\(value.text())"
                default: return nil
                }
            }
            if !parts.isEmpty { return parts.joined(separator: "&") }
        }
        return "#\(index)"
    }

    /// The entry of `current` that corresponds to `item`: by identity fields when it has any, by position
    /// otherwise. An ambiguous match is no match, so a reordered list never receives another entry's secret.
    private static func counterpart(_ item: JSONValue, index: Int, in current: [JSONValue]) -> JSONValue? {
        let id = identity(item, index: index)
        if id.hasPrefix("#") { return current.indices.contains(index) ? current[index] : nil }
        let found = current.enumerated().filter { identity($0.element, index: $0.offset) == id }
        return found.count == 1 ? found[0].element : nil
    }

    /// Replaces every placeholder in `next` with the real value from `current`.
    public static func restoreSecrets(_ next: JSONValue, from current: JSONValue) throws -> JSONValue {
        var missing: [String] = []
        func walk(_ n: JSONValue, _ c: JSONValue?, _ path: String) -> JSONValue {
            if case .string(let string) = n, string == placeholder {
                if let c, isSecretValue(c) { return c }
                missing.append(path.isEmpty ? "(root)" : path)
                return n
            }
            switch n {
            case .array(let items):
                let cur = c?.arrayValue ?? []
                return .array(items.enumerated().map { walk($0.element, counterpart($0.element, index: $0.offset, in: cur), "\(path)[\($0.offset)]") })
            case .object(let object):
                let cur = c?.objectValue ?? [:]
                return .object(object.reduce(into: [:]) { result, entry in
                    result[entry.key] = walk(entry.value, cur[entry.key], path.isEmpty ? entry.key : "\(path).\(entry.key)")
                })
            default:
                return n
            }
        }
        let restored = walk(next, current, "")
        if !missing.isEmpty { throw RestoreError(paths: missing.sorted()) }
        return restored
    }

    /// What ASCII text must contain for `secretPair` to match: a keyword of its key and a separator.
    private static let pairKeywords = ["pass", "pin", "setup", "secret", "token", "api", "private", "credential"].map { Array($0.utf8) }

    /// What ASCII text must contain for each of `secretShapes` to match, in the same order.
    private static let shapeHints: [@Sendable (String) -> Bool] = [
        { TextSearch.contains($0, ascii: "Bearer") || TextSearch.contains($0, ascii: "Basic") },
        { TextSearch.contains($0, ascii: "sk-") },
        { TextSearch.contains($0, ascii: "hbg_") },
        { TextSearch.contains($0, ascii: "AIza") },
        { TextSearch.contains($0, ascii: "eyJ") },
        { TextSearch.contains($0, ascii: "X-HM://") },
        { hasDigitGroups($0, [3, 2, 3]) },
        { hasDigitGroups($0, [4, 4]) },
    ]

    /// Whether ASCII text has groups of exactly these many digits joined by dashes, between word boundaries:
    /// `\b\d{3}-\d{2}-\d{3}\b` for `[3, 2, 3]`. Every log line starts with a date, which a looser test lets through.
    private static func hasDigitGroups(_ text: String, _ groups: [Int]) -> Bool {
        TextSearch.withBytes(text) { bytes in
            func digit(_ index: Int) -> Bool { index < bytes.count && bytes[index] &- UInt8(ascii: "0") < 10 }
            func word(_ index: Int) -> Bool {
                guard index >= 0, index < bytes.count else { return false }
                let byte = bytes[index]
                return byte &- UInt8(ascii: "0") < 10 || (byte | 0x20) &- UInt8(ascii: "a") < 26 || byte == UInt8(ascii: "_")
            }
            var start = 0
            while start < bytes.count {
                if digit(start), !word(start - 1) {
                    var position = start
                    var matched = true
                    for (index, count) in groups.enumerated() {
                        if index > 0 {
                            guard position < bytes.count, bytes[position] == UInt8(ascii: "-") else { matched = false; break }
                            position += 1
                        }
                        guard (position..<(position + count)).allSatisfy(digit) else { matched = false; break }
                        position += count
                    }
                    if matched, !word(position) { return true }
                }
                start += 1
            }
            return false
        }
    }

    /// Best-effort redaction of free text such as log lines or error messages: values of secret-named
    /// keys and well-known credential shapes become the placeholder.
    ///
    /// The expressions cost hundreds of microseconds a line, so ASCII text skips those it cannot match (it lacks
    /// what each one needs); other text goes through all of them, since case folding reaches past ASCII.
    public static func redactText(_ text: String) -> String {
        redactText(text, prefilter: true)
    }

    /// `prefilter: false` runs every expression: what the tests compare the shortcut with.
    static func redactText(_ text: String, prefilter: Bool) -> String {
        var out = text
        let ascii = prefilter && TextSearch.isASCII(text)
        let mayHoldPair = !ascii || (TextSearch.contains(text, ascii: ":") || TextSearch.contains(text, ascii: "="))
            && TextSearch.containsAny(text, caseless: pairKeywords)
        let pairs = mayHoldPair ? secretPair.matches(in: out, range: NSRange(out.startIndex..., in: out)) : []
        for match in pairs.reversed() {
            guard let whole = Range(match.range, in: out), let keyRange = Range(match.range(at: 2), in: out) else { continue }
            let key = String(out[keyRange])
            if matches(notSecretKey, key) { continue }
            if let valueRange = Range(match.range(at: 5), in: out), isConcealed(String(out[valueRange])) { continue }
            let quote = Range(match.range(at: 1), in: out).map { String(out[$0]) } ?? ""
            let separator = Range(match.range(at: 3), in: out).map { String(out[$0]) } ?? ""
            let valueQuote = Range(match.range(at: 4), in: out).map { String(out[$0]) } ?? ""
            out.replaceSubrange(whole, with: "\(quote)\(key)\(quote)\(separator)\(valueQuote)\(placeholder)\(valueQuote)")
        }
        for (shape, hint) in zip(secretShapes, shapeHints) {
            // Replacements keep ASCII text ASCII; the hint looks at the text as the expression would see it.
            if ascii, !hint(out) { continue }
            let found = shape.matches(in: out, range: NSRange(out.startIndex..., in: out))
            for match in found.reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let matched = String(out[range])
                let replacement: String
                if matched.hasPrefix("Bearer ") || matched.hasPrefix("Basic ") {
                    replacement = "\(matched.split(separator: " ")[0]) \(placeholder)"
                } else {
                    replacement = placeholder
                }
                out.replaceSubrange(range, with: replacement)
            }
        }
        return out
    }

    /// HomeKit pairing fields: whoever holds them can add an unpaired bridge to their own Home.
    public static let pairingKeys: Set<String> = ["pin", "setupUri", "setupCode", "setupId", "setupURI", "qrCode", "manualPairingCode"]

    /// A conversation with every user text, tool result and tool argument redacted; assistant turns and
    /// provider content are left as they came from the model.
    public static func redactMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.map { message in
            var copy = message
            copy.content = message.content.map { part in
                switch part {
                case .text(let text): message.role == .user ? .text(redactText(text)) : part
                case .toolCall(let call): .toolCall(ToolCall(id: call.id, name: call.name, arguments: redactSecrets(call.arguments)))
                case .toolResult(let id, let name, let content, let isError): .toolResult(toolCallID: id, name: name, content: redactText(content), isError: isError)
                }
            }
            return copy
        }
    }

    /// A copy of a status object (or an array of them) without its pairing codes.
    public static func redactPairing(_ value: JSONValue) -> JSONValue {
        switch value {
        case .array(let items): .array(items.map(redactPairing))
        case .object(let object): .object(object.filter { !pairingKeys.contains($0.key) }.mapValues(redactPairing))
        default: value
        }
    }
}
