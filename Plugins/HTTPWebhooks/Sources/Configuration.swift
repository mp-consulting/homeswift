import Foundation
import Homeswift
import HomeswiftPlugin

extension HTTPWebhooksPlugin {
    /// The `HttpWebHooks` block of homebridge-http-webhooks, read as that plugin reads it: every option optional, and a
    /// missing or "falsy" value (`""`, `0`, `false`, `null`) taking the default. The entries stay JSON (`Entry`), each kind
    /// reading its own keys.
    public struct Configuration: Decodable, Sendable {
        public var block: JSONValue

        public static let defaultPort = 51828
        public static let defaultHost = "0.0.0.0"

        public init(block: JSONValue) {
            self.block = block
        }

        public init(from decoder: any Decoder) throws {
            self.init(block: try JSONValue(from: decoder))
        }

        /// `webhook_port`, a number or a numeric string (the schema types it as a string).
        public var port: Int {
            block["webhook_port"].flatMap(Loose.number).flatMap { Int(saturating: $0, in: 0...65535) }.flatMap { $0 == 0 ? nil : $0 } ?? Self.defaultPort
        }

        public var host: String { block["webhook_listen_host"].flatMap(Loose.string) ?? Self.defaultHost }
        public var enableCORS: Bool { block["webhook_enable_cors"].map(Loose.truthy) ?? false }

        /// Basic authentication, on only when both the user and the password are given.
        public var credentials: (user: String, password: String)? {
            guard let user = block["http_auth_user"].flatMap(Loose.string), let password = block["http_auth_pass"].flatMap(Loose.string) else { return nil }
            return (user, password)
        }

        /// HTTPS only for the JSON boolean `true`, as the Homebridge plugin has it (the string `"true"` does not count).
        public var https: Bool { block["https"] == .bool(true) }
        public var httpsKeyFile: String? { block["https_keyfile"].flatMap(Loose.string) }
        public var httpsCertificateFile: String? { block["https_certfile"].flatMap(Loose.string) }

        /// The entries of one kind's list (`switches`, `sensors`, ...): objects only.
        func entries(_ key: String) -> [Entry] {
            (block[key]?.arrayValue ?? []).compactMap { $0.objectValue == nil ? nil : Entry(json: $0) }
        }
    }

    /// One entry of a kind's list, with the readings every kind shares.
    struct Entry: Sendable {
        let json: JSONValue

        /// The webhook's `accessoryId` and the state's storage key; a number reads as its text.
        var id: String? { json["id"].flatMap(Loose.string) }
        /// Whether webhooks reach the entry: the Homebridge plugin compares `accessoryId` with a string `id` only, so an
        /// entry with a number for its `id` is an accessory HomeKit drives, and no webhook's.
        var takesWebhooks: Bool { json["id"]?.stringValue != nil }
        var name: String? { json["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

        /// TLS verification of the outgoing calls: on when absent, and when present only for the boolean `true`.
        var rejectUnauthorized: Bool {
            guard let value = json["rejectUnauthorized"], !value.isNull else { return true }
            return value == .bool(true)
        }

        subscript(key: String) -> JSONValue? { json[key] }

        func string(_ key: String) -> String? { json[key].flatMap(Loose.string) }
        func number(_ key: String) -> Double? { json[key].flatMap(Loose.number) }
        func number(_ key: String, default value: Double) -> Double { number(key) ?? value }
        /// A flag: its truthiness when present, `value` when missing.
        func flag(_ key: String, default value: Bool) -> Bool {
            guard let flag = json[key], !flag.isNull else { return value }
            return Loose.truthy(flag)
        }

        /// The outgoing call of an action (`on`, `brightness`, `open_20`...): its `<prefix>_url` and the rest, nil without a URL.
        func call(_ prefix: String) -> OutgoingCall? {
            guard let url = string("\(prefix)_url") else { return nil }
            return OutgoingCall(
                url: url, method: string("\(prefix)_method") ?? "GET", body: string("\(prefix)_body"), form: string("\(prefix)_form"),
                headers: string("\(prefix)_headers"), rejectUnauthorized: rejectUnauthorized)
        }
    }
}

/// JavaScript's readings of configuration values: what is "falsy", and a number from a number or a numeric string.
enum Loose {
    static func truthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let flag): flag
        case .number(let number): number != 0 && !number.isNaN
        case .string(let text): !text.isEmpty
        case .array, .object: true
        }
    }

    /// A non-empty string; a number reads as its text.
    static func string(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text.isEmpty ? nil : text
        case .number: Format.number(value.doubleValue ?? 0)
        default: nil
        }
    }

    /// A non-zero number, from a number or a numeric string; nil for anything falsy, so the default applies.
    static func number(_ value: JSONValue) -> Double? {
        let number: Double? = switch value {
        case .number(let number): number
        case .string(let text): Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
        guard let number, number.isFinite, number != 0 else { return nil }
        return number
    }
}

enum Format {
    /// A number in its shortest form, as JavaScript writes it: `21`, `21.5`.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        let text = value.description
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }
}
