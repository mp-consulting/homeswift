import Foundation
import HomeswiftPlugin

extension DaikinCloudPlugin {
    /// The platform block of `@mp-consulting/homebridge-daikin-cloud`, key for key, kept as written.
    ///
    /// Homebridge configs are hand-edited JSON: numbers arrive as strings, booleans as null, arrays as
    /// anything. The block is kept raw and read through `DaikinSettings`, which normalises it the way the
    /// Homebridge plugin's ConfigManager does (coercion, schema bounds, defaults, legacy aliases), so a block
    /// that worked there works here and nothing fails to decode.
    public struct Configuration: Decodable, Sendable {
        public var raw: [String: JSONValue]

        public init(from decoder: any Decoder) throws {
            raw = try JSONValue(from: decoder).objectValue ?? [:]
        }

        public init(_ raw: [String: JSONValue] = [:]) {
            self.raw = raw
        }

        public subscript(key: String) -> JSONValue? { raw[key] }
    }
}

/// How the plugin authenticates with the Onecta cloud.
enum AuthMode: String, Sendable, CaseIterable {
    /// OAuth 2.0 with a Client ID and Secret from the Daikin Developer Portal: 200 calls a day.
    case developerPortal = "developer_portal"
    /// The Onecta app's own login (Gigya and PKCE) with the account's email and password: 3000 calls a day
    /// and the WebSocket.
    case mobileApp = "mobile_app"

    var label: String { self == .mobileApp ? "Mobile App" : "Developer Portal" }
    /// The token file in the plugin's storage directory, named as in the Homebridge storage path.
    var tokenFileName: String { self == .mobileApp ? ".daikin-mobile-tokenset" : ".daikin-controller-cloud-tokenset" }
}

/// How requests reach the cloud: the built-in client, or curl for networks whose firewall drops the
/// built-in client's TLS fingerprint (the Homebridge plugin's issue #6).
enum TransportMode: String, Sendable {
    case node, curl
}

/// The per-feature switches (the `show*` keys of config.schema.json).
enum FeatureKey: String, Sendable, CaseIterable {
    case showPowerfulMode, showEconoMode, showStreamerMode, showOutdoorSilentMode, showIndoorSilentMode, showAutoFanMode
    case showOscillationSwitch, showDryMode, showFanOnlyMode, showHolidayMode
    case showSeparateFanControl, showFirmwareUpdateSwitch

    /// Extra features follow the legacy `showExtraFeatures` catch-all when their own key is not set.
    static let extra: [FeatureKey] = [
        .showPowerfulMode, .showEconoMode, .showStreamerMode, .showOutdoorSilentMode, .showIndoorSilentMode, .showAutoFanMode,
        .showOscillationSwitch, .showDryMode, .showFanOnlyMode, .showHolidayMode,
    ]
    /// Standalone toggles are off unless set: a separate Fan tile, and a switch that installs firmware.
    static let standalone: [FeatureKey] = [.showSeparateFanControl, .showFirmwareUpdateSwitch]
}

/// The configuration once normalised: what the plugin works from. The rules are the Homebridge plugin's
/// ConfigManager's, so the settings page, the plugin and the README agree.
struct DaikinSettings: Sendable {
    static let defaultUpdateIntervalMinutes = 15.0
    static let updateIntervalMinutes = 1.0...60.0
    static let defaultForceUpdateDelay = 60_000.0
    static let forceUpdateDelay = 5000.0...300_000.0
    static let defaultCallbackPort = 8582
    static let defaultCallbackBindAddress = "0.0.0.0"
    static let privilegedPortMax = 1023
    static let developerPortalRecommendedInterval = 15.0

    var name: String?
    var authMode: AuthMode
    var httpTransport: TransportMode?
    var clientID: String?
    var clientSecret: String?
    var callbackServerExternalAddress: String?
    var callbackServerPort: Int
    var callbackBindAddress: String
    var email: String?
    var password: String?
    /// Milliseconds, clamped to 1 to 60 minutes.
    var updateInterval: Double
    /// Milliseconds, clamped to 5 to 300 seconds.
    var forceUpdateDelay: Double
    var excludedDeviceIDs: Set<String>
    var features: [FeatureKey: Bool]
    var webSocketEnabled: Bool

    init(_ configuration: DaikinCloudPlugin.Configuration) {
        let raw = configuration.raw
        name = Self.nonEmpty(raw["name"])
        authMode = Self.authMode(raw)
        httpTransport = raw["httpTransport"]?.stringValue.flatMap(TransportMode.init(rawValue:))
        clientID = Self.nonEmpty(raw["clientId"])
        clientSecret = Self.nonEmpty(raw["clientSecret"])
        callbackServerExternalAddress = Self.nonEmpty(raw["callbackServerExternalAddress"])
        callbackServerPort = Self.port(raw["callbackServerPort"]) ?? Self.defaultCallbackPort
        callbackBindAddress = Self.nonEmpty(raw["oidcCallbackServerBindAddr"]) ?? Self.defaultCallbackBindAddress
        email = Self.nonEmpty(raw["daikinEmail"]) ?? Self.nonEmpty(raw["email"])
        password = Self.nonEmpty(raw["daikinPassword"]) ?? Self.nonEmpty(raw["password"])
        updateInterval = Self.updateIntervalMinutes(raw["updateIntervalInMinutes"]) * 60_000
        forceUpdateDelay = Self.forceUpdateDelay(raw["forceUpdateDelay"])
        excludedDeviceIDs = Set((raw["excludedDevicesByDeviceId"]?.arrayValue ?? []).compactMap(\.stringValue))
        var features: [FeatureKey: Bool] = [:]
        let legacy = raw["showExtraFeatures"]?.boolValue == true
        for key in FeatureKey.extra { features[key] = raw[key.rawValue]?.boolValue ?? legacy }
        for key in FeatureKey.standalone { features[key] = raw[key.rawValue]?.boolValue == true }
        self.features = features
        webSocketEnabled = raw["enableWebSocket"]?.boolValue != false
    }

    func isEnabled(_ feature: FeatureKey) -> Bool { features[feature] ?? false }
    func isExcluded(_ deviceID: String) -> Bool { excludedDeviceIDs.contains(deviceID) }
    var hasDeveloperCredentials: Bool { clientID != nil && clientSecret != nil }
    var mobileCredentials: (email: String, password: String)? {
        guard let email, let password else { return nil }
        return (email, password)
    }

    // MARK: Coercion, as the Homebridge plugin does it

    /// A number from a number or a numeric string; nil (JavaScript's NaN) for anything else.
    static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number): return number
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : Double(trimmed)
        default: return nil
        }
    }

    static func isSet(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null: false
        case .string(let string): !string.isEmpty
        default: true
        }
    }

    static func nonEmpty(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue, !string.isEmpty else { return nil }
        return string
    }

    static func authMode(_ raw: [String: JSONValue]) -> AuthMode {
        raw["authMode"]?.stringValue == AuthMode.mobileApp.rawValue ? .mobileApp : .developerPortal
    }

    /// An integer port in 1...65535.
    static func port(_ value: JSONValue?) -> Int? {
        guard let number = number(value), number.rounded() == number, (1...65535).contains(number) else { return nil }
        return Int(number)
    }

    /// Unset, 0 or not a number: the default; anything else clamped to the schema's bounds.
    static func updateIntervalMinutes(_ value: JSONValue?) -> Double {
        guard let minutes = number(value), minutes.isFinite, minutes != 0 else { return defaultUpdateIntervalMinutes }
        return min(updateIntervalMinutes.upperBound, max(updateIntervalMinutes.lowerBound, minutes))
    }

    static func forceUpdateDelay(_ value: JSONValue?) -> Double {
        guard let delay = number(value), delay.isFinite, delay != 0 else { return defaultForceUpdateDelay }
        return min(forceUpdateDelay.upperBound, max(forceUpdateDelay.lowerBound, delay))
    }

    /// The legacy credential keys in use because the canonical ones are absent.
    static func legacyCredentialKeys(_ raw: [String: JSONValue]) -> [String] {
        var keys: [String] = []
        if !isTruthy(raw["daikinEmail"]), isTruthy(raw["email"]) { keys.append("email") }
        if !isTruthy(raw["daikinPassword"]), isTruthy(raw["password"]) { keys.append("password") }
        return keys
    }

    /// JavaScript truthiness, for the checks the Homebridge plugin writes as `!config.key`.
    static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null: false
        case .bool(let bool): bool
        case .number(let number): number != 0 && !number.isNaN
        case .string(let string): !string.isEmpty
        case .array, .object: true
        }
    }

    // MARK: Validation

    struct Validation: Sendable, Equatable {
        var errors: [String] = []
        var warnings: [String] = []
        var valid: Bool { errors.isEmpty }
    }

    /// Checks a raw block, with the Homebridge plugin's messages. Errors are blocks the plugin cannot work
    /// with; out-of-range numbers are warnings, since they are clamped. The settings page validates the
    /// Developer Portal wizard with it too.
    static func validate(_ raw: [String: JSONValue]) -> Validation {
        var result = Validation()
        let mode = authMode(raw)
        if mode == .developerPortal {
            if !isTruthy(raw["clientId"]) { result.errors.append("Client ID is required for Developer Portal mode") }
            if !isTruthy(raw["clientSecret"]) { result.errors.append("Client Secret is required for Developer Portal mode") }
            if !isTruthy(raw["callbackServerExternalAddress"]) {
                result.errors.append("Callback Server Address is required for Developer Portal mode")
            } else if let address = raw["callbackServerExternalAddress"]?.stringValue, address == "localhost" || address == "127.0.0.1" {
                // The Daikin redirect must reach this host from the user's browser.
                result.errors.append("Callback address cannot be localhost. Use your external IP or domain.")
            }
        } else {
            if !isTruthy(raw["daikinEmail"]), !isTruthy(raw["email"]) {
                result.errors.append("Email is required for Mobile App mode (config key: \"daikinEmail\")")
            }
            if !isTruthy(raw["daikinPassword"]), !isTruthy(raw["password"]) {
                result.errors.append("Password is required for Mobile App mode (config key: \"daikinPassword\")")
            }
            let legacy = legacyCredentialKeys(raw)
            if !legacy.isEmpty {
                result.warnings.append(
                    "Using deprecated config key(s) \(legacy.map { "\"\($0)\"" }.joined(separator: " and ")). "
                        + "Rename to \"daikinEmail\"/\"daikinPassword\" — the old names will stop working in a future release.")
            }
        }
        if isSet(raw["callbackServerPort"]) {
            if let port = port(raw["callbackServerPort"]) {
                if port <= privilegedPortMax { result.warnings.append("Port \(port) is privileged (< 1024) and may require root permissions.") }
            } else {
                result.errors.append("Invalid port number: \(display(raw["callbackServerPort"])). Must be between 1 and 65535.")
            }
        }
        if isSet(raw["updateIntervalInMinutes"]) {
            let minutes = updateIntervalMinutes(raw["updateIntervalInMinutes"])
            if number(raw["updateIntervalInMinutes"]) != minutes {
                result.warnings.append(
                    "Update interval must be between 1 and 60 minutes, got: \(display(raw["updateIntervalInMinutes"])). Using \(jsNumber(minutes)) minutes.")
            } else if mode == .developerPortal, minutes < developerPortalRecommendedInterval {
                result.warnings.append("Update interval \(jsNumber(minutes))min may exceed Developer Portal rate limit (200 calls/day). Recommended: 15+ minutes.")
            }
        }
        if isSet(raw["forceUpdateDelay"]) {
            let delay = forceUpdateDelay(raw["forceUpdateDelay"])
            if number(raw["forceUpdateDelay"]) != delay {
                result.warnings.append(
                    "Force update delay must be between 5000 and 300000 ms, got: \(display(raw["forceUpdateDelay"])). Using \(jsNumber(delay)) ms.")
            }
        }
        return result
    }

    /// The block with credentials and device ids masked, for debug logs.
    static func redacted(_ raw: [String: JSONValue], excluded: Set<String>) -> JSONValue {
        var copy = raw
        copy["clientId"] = .string(mask(raw["clientId"]?.stringValue))
        copy["clientSecret"] = .string(mask(raw["clientSecret"]?.stringValue))
        copy["daikinEmail"] = .string(mask(raw["daikinEmail"]?.stringValue))
        copy["daikinPassword"] = isTruthy(raw["daikinPassword"]) ? "***" : nil
        copy["email"] = .string(mask(raw["email"]?.stringValue))
        copy["password"] = isTruthy(raw["password"]) ? "***" : nil
        copy["excludedDevicesByDeviceId"] = .array(excluded.sorted().map { .string(mask($0)) })
        return .object(copy.filter { !$0.value.isNull })
    }

    /// `abc******xyz`, or only stars for anything shorter than seven characters.
    static func mask(_ string: String?) -> String {
        guard let string, string.count > 6 else { return "******" }
        return "\(string.prefix(3))******\(string.suffix(3))"
    }

    /// A value as JavaScript prints it in a template string.
    static func display(_ value: JSONValue?) -> String {
        switch value {
        case .number(let number): jsNumber(number)
        case .string(let string): string
        case .bool(let bool): String(bool)
        case nil: "undefined"
        case .null: "null"
        default: value?.text() ?? ""
        }
    }

    /// A number as JavaScript prints it: no ".0" on whole numbers.
    static func jsNumber(_ number: Double) -> String {
        if number.rounded() == number, abs(number) < 1e15 { return String(Int(number)) }
        return String(number)
    }
}
