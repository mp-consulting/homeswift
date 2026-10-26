import Foundation

/// Keeps credentials out of the model's context.
///
/// `redactSecrets` swaps secret-looking values in a configuration for a placeholder before it is shown;
/// `restoreSecrets` puts the real values back when the model writes the configuration, so a read, edit,
/// write round trip is lossless. `redactText` is the best-effort version for free text such as logs.
public enum Redaction {
    public static let placeholder = "__REDACTED__"
    /// The prefix of a secret sealed in config.json (`SecretBox`): its text is ciphertext, never shown.
    public static let sealedPrefix = "enc:v1:"

    /// Keys whose values are secrets: password, mqttPass, apiKey, clientSecret, bridge.pin.
    /// The key rule as a pattern: the server sends it to the page, so the page never keeps its own copy.
    public static let secretKeyPattern = #"pass$|pass(word|wd|phrase)|secret|token|api[-_]?key|private[-_]?key|credential|^pin$|authorization|cookie|session[-_]?(id|key)$|^sid$|signature|^otp$"#
    public static let notSecretKeyPattern = #"(max|min|context|input|output|total|daily|monthly)\w*tokens$"#
    private static let secretKey = try! NSRegularExpression(pattern: secretKeyPattern, options: [.caseInsensitive])
    /// Keys that look secret but hold token counts: maxOutputTokens, contextTokens, a budget's dailyTokens.
    private static let notSecretKey = try! NSRegularExpression(pattern: notSecretKeyPattern, options: [.caseInsensitive])
    /// `key: value`, `key=value` and `"key": "value"` pairs whose key names a secret (including HomeKit's
    /// pin and setup code).
    private static let secretPair = try! NSRegularExpression(
        pattern: #"(["']?)([\w.-]*(?:password|passwd|passphrase|pass|pin|setup[-_ ]?code|secret|token|api[-_]?key|private[-_]?key|credential|cookie|session[-_]?id|signature)[\w-]*)\1(\s*[:=]\s*)(["']?)([^\s"',;}&]+)\4"#,
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

    /// A URL with a user name and password in it (`rtsp://user:pass@host/stream`): a credential whatever its key.
    public static func isCredentialURL(_ text: String) -> Bool {
        guard let scheme = text.range(of: "://") else { return false }
        let rest = text[scheme.upperBound...]
        let authority = rest.prefix { $0 != "/" && $0 != "?" }
        return authority.contains("@")
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
        case .string(let text) where (isCredentialURL(text) || text.hasPrefix(sealedPrefix)) && !isConcealed(text):
            return replacing(value)
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

    /// What one pass over a text finds of what the expressions need, for ASCII text: a separator and a keyword of a
    /// secret's key for `secretPair`, and the fixed part of each of `secretShapes`. Sixteen searches of each line
    /// had become most of a log search's time.
    struct Hints: OptionSet {
        let rawValue: UInt16
        static let nonASCII = Hints(rawValue: 1 << 0)
        static let separator = Hints(rawValue: 1 << 1)
        static let keyword = Hints(rawValue: 1 << 2)
        static let bearer = Hints(rawValue: 1 << 3)
        static let openAI = Hints(rawValue: 1 << 4)
        static let homebridge = Hints(rawValue: 1 << 5)
        static let google = Hints(rawValue: 1 << 6)
        static let jwt = Hints(rawValue: 1 << 7)
        static let setupURI = Hints(rawValue: 1 << 8)
        static let setupCode = Hints(rawValue: 1 << 9)
        static let shortSetupCode = Hints(rawValue: 1 << 10)
    }

    /// What each of `secretShapes` needs, in the same order.
    private static let shapeHints: [Hints] = [.bearer, .openAI, .homebridge, .google, .jwt, .setupURI, .setupCode, .shortSetupCode]

    /// The keywords of `secretPair`'s key (password, passwd, passphrase and pass all start `pass`), lower case.
    private static let keywords = ["pass", "pin", "setup", "secret", "token", "api", "private", "credential", "cookie", "session", "signature"].map { Array($0.utf8) }

    /// The shapes' fixed parts, case as written.
    private static let fixed = (
        openAI: Array("sk-".utf8), google: Array("AIza".utf8), bearer: Array("Bearer".utf8), basic: Array("Basic".utf8),
        homebridge: Array("hbg_".utf8), jwt: Array("eyJ".utf8), setupURI: Array("X-HM://".utf8))

    static func hints(_ text: String) -> Hints {
        TextSearch.withBytes(text) { bytes in
            var hints: Hints = []
            func at(_ start: Int, _ needle: [UInt8], caseless: Bool) -> Bool {
                guard start + needle.count <= bytes.count else { return false }
                for offset in needle.indices where (caseless ? TextSearch.lower(bytes[start + offset]) : bytes[start + offset]) != needle[offset] { return false }
                return true
            }
            func word(_ index: Int) -> Bool {
                guard index >= 0, index < bytes.count else { return false }
                let byte = bytes[index]
                return byte &- UInt8(ascii: "0") < 10 || (byte | 0x20) &- UInt8(ascii: "a") < 26 || byte == UInt8(ascii: "_")
            }
            for index in bytes.indices {
                let byte = bytes[index]
                // Other text takes every expression: nothing more to find.
                if byte >= 0x80 { return [.nonASCII] }
                if byte == UInt8(ascii: ":") || byte == UInt8(ascii: "=") { hints.insert(.separator); continue }
                if byte &- UInt8(ascii: "0") < 10 {
                    if !word(index - 1) {
                        if digitGroups(at: index, in: bytes, [3, 2, 3], word: word) { hints.insert(.setupCode) }
                        if digitGroups(at: index, in: bytes, [4, 4], word: word) { hints.insert(.shortSetupCode) }
                    }
                    continue
                }
                switch TextSearch.lower(byte) {
                case UInt8(ascii: "p"), UInt8(ascii: "t"), UInt8(ascii: "c"):
                    if keywords.contains(where: { at(index, $0, caseless: true) }) { hints.insert(.keyword) }
                case UInt8(ascii: "s"):
                    if keywords.contains(where: { at(index, $0, caseless: true) }) { hints.insert(.keyword) }
                    if at(index, fixed.openAI, caseless: false) { hints.insert(.openAI) }
                case UInt8(ascii: "a"):
                    if keywords.contains(where: { at(index, $0, caseless: true) }) { hints.insert(.keyword) }
                    if at(index, fixed.google, caseless: false) { hints.insert(.google) }
                case UInt8(ascii: "b"):
                    if at(index, fixed.bearer, caseless: false) || at(index, fixed.basic, caseless: false) { hints.insert(.bearer) }
                case UInt8(ascii: "h"):
                    if at(index, fixed.homebridge, caseless: false) { hints.insert(.homebridge) }
                case UInt8(ascii: "e"):
                    if at(index, fixed.jwt, caseless: false) { hints.insert(.jwt) }
                case UInt8(ascii: "x"):
                    if at(index, fixed.setupURI, caseless: false) { hints.insert(.setupURI) }
                default:
                    break
                }
            }
            return hints
        }
    }

    /// Whether groups of exactly these many digits joined by dashes start at `start` and end at a word boundary:
    /// `\d{3}-\d{2}-\d{3}\b` for `[3, 2, 3]` (the caller checks the boundary before). Every log line starts with a
    /// date, which a looser test lets through.
    private static func digitGroups(at start: Int, in bytes: UnsafeBufferPointer<UInt8>, _ groups: [Int], word: (Int) -> Bool) -> Bool {
        func digit(_ index: Int) -> Bool { index < bytes.count && bytes[index] &- UInt8(ascii: "0") < 10 }
        var position = start
        for (index, count) in groups.enumerated() {
            if index > 0 {
                guard position < bytes.count, bytes[position] == UInt8(ascii: "-") else { return false }
                position += 1
            }
            guard (position..<(position + count)).allSatisfy(digit) else { return false }
            position += count
        }
        return !word(position)
    }

    /// Best-effort redaction of free text such as log lines or error messages: values of secret-named
    /// keys and well-known credential shapes become the placeholder.
    ///
    /// The expressions cost hundreds of microseconds a line, so ASCII text skips those it cannot match (it lacks
    /// what each one needs); other text goes through all of them, since case folding reaches past ASCII.
    public static func redactText(_ text: String) -> String {
        maskURLPasswords(redactText(text, prefilter: true))
    }

    /// `scheme://user:password@host` with the password replaced by the placeholder.
    private static let urlPassword = try! NSRegularExpression(pattern: #"([A-Za-z][A-Za-z0-9+.-]*://[^:/@\s]+:)[^@\s/]+(@)"#)

    private static func maskURLPasswords(_ text: String) -> String {
        urlPassword.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\(placeholder)$2")
    }

    /// `prefilter: false` runs every expression: what the tests compare the shortcut with.
    static func redactText(_ text: String, prefilter: Bool) -> String {
        var out = text
        var hints = prefilter ? Self.hints(text) : .nonASCII
        let ascii = !hints.contains(.nonASCII)
        let mayHoldPair = !ascii || hints.contains([.separator, .keyword])
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
        // Replacements keep ASCII text ASCII; the hints look at the text as each expression will see it.
        if ascii, !pairs.isEmpty { hints = Self.hints(out) }
        for (shape, hint) in zip(secretShapes, shapeHints) {
            if ascii, !hints.contains(hint) { continue }
            let found = shape.matches(in: out, range: NSRange(out.startIndex..., in: out))
            defer { if ascii, !found.isEmpty { hints = Self.hints(out) } }
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
