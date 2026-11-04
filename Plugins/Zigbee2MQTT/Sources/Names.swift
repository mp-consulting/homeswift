import Foundation
import HomeswiftPlugin

enum Names {
    /// Kept among letters and numbers, and stripped from the start.
    private static let kept: Set<Character> = ["\u{2019}", " ", "'", ".", ",", "-"]
    private static let trailing: Set<Character> = [" ", "'", ".", ",", "-"]

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }

    /// A name HomeKit takes (3.2): other characters become spaces, spaces collapse, punctuation leaves the ends; nil
    /// when nothing is left.
    static func sanitize(_ name: String) -> String? {
        var result = ""
        var replacing = false
        for character in name {
            let allowed = kept.contains(character) || character.unicodeScalars.allSatisfy(isLetterOrNumber)
            if allowed {
                result.append(character)
                replacing = false
            } else if !replacing {
                result.append(" ")
                replacing = true
            }
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        while let first = result.first, kept.contains(first) { result.removeFirst() }
        while let last = result.last, trailing.contains(last) { result.removeLast() }
        return result.isEmpty ? nil : result
    }
}

/// Zigbee2MQTT's availability configuration (its `bridge/info` `config`), as Z2M itself decides which devices it
/// reports availability for (10.1).
struct AvailabilityConfiguration: Sendable, Equatable {
    var global = false
    var enabled: Set<String> = []
    var disabled: Set<String> = []

    init() {}

    init(config: JSONValue) {
        let advanced = config["advanced"]
        let passlist = Self.list(advanced?["availability_passlist"]) + Self.list(advanced?["availability_whitelist"])
        global = (Self.truthy(config["availability"]) || Self.truthy(advanced?["availability_timeout"])) && passlist.isEmpty
        for (address, device) in config["devices"]?.objectValue ?? [:] {
            guard let availability = device["availability"] else { continue }
            let names = [address] + [device["friendly_name"]?.stringValue].compactMap { $0 }
            if availability == .bool(false) { disabled.formUnion(names) } else { enabled.formUnion(names) }
        }
        if !passlist.isEmpty {
            enabled.formUnion(passlist)
        } else {
            disabled.formUnion(Self.list(advanced?["availability_blocklist"]) + Self.list(advanced?["availability_blacklist"]))
        }
    }

    func isEnabled(address: String, name: String) -> Bool {
        if enabled.contains(address) || enabled.contains(name) { return true }
        if disabled.contains(address) || disabled.contains(name) { return false }
        return global
    }

    private static func list(_ value: JSONValue?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    /// JavaScript's truthiness.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let value)?: value
        case .number(let value)?: value != 0 && !value.isNaN
        case .string(let value)?: !value.isEmpty
        case .array?, .object?: true
        }
    }
}

/// `{"state":"online"}`, or plain `online` (Z2M before 2.0); anything but `offline` is online for the bridge.
enum OnlineState {
    static func text(_ payload: Data) -> String {
        let raw = String(decoding: payload, as: UTF8.self)
        if let json = try? JSONValue(data: payload), let state = json["state"]?.stringValue { return state }
        return raw
    }

    static func bridgeIsOffline(_ payload: Data) -> Bool { text(payload) == "offline" }

    static func deviceIsOnline(_ payload: Data) -> Bool { text(payload) == "online" }
}
