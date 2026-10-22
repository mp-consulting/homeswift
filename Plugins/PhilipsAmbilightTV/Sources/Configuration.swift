import Foundation

extension PhilipsAmbilightTVPlugin {
    /// The platform block of `homebridge-philips-ambilight-tv`, key for key. Every option is optional at
    /// decoding time: a TV with something missing is skipped with a message, the others run.
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            public var name: String?
            public var mac: String?
            public var ip: String?
            /// The device id the pairing produced.
            public var username: String?
            /// The auth key the pairing produced.
            public var password: String?
            /// SHA-256 of the TV's certificate, recorded at pairing: connections are refused otherwise.
            public var certFingerprint: String?
            /// Milliseconds between state polls, 1000 to 60000; 10000 by default.
            public var pollingInterval: Int?
            public var wakeOnLanEnabled: Bool?
            /// `STYLE/ALGORITHM`, e.g. `FOLLOW_VIDEO/NATURAL`, applied when Ambilight is switched on.
            public var ambilightMode: String?
            /// Switch Ambilight on whenever the TV comes on.
            public var ambilightOnStart: Bool?
            public var infoButtonKey: String?
            public var backButtonKey: String?
            public var playPauseButtonKey: String?
            /// An explicit input list; with one, apps are not discovered.
            public var inputs: [Input]?
            /// One Switch per input, for scenes and automations.
            public var sourceSwitches: Bool?
            /// A Switch for the Ambilight+hue feature.
            public var ambilightHueSwitch: Bool?
            public var customApps: [CustomApp]?
            /// Momentary switches that send a remote key.
            public var customButtons: [CustomButton]?
            /// Motion sensors mirroring `power`, `ambilight` and `mute`.
            public var stateSensors: [String]?
            /// Order, visibility and names of inputs, as the settings page writes them.
            public var sources: [SourceSetting]?
        }

        public struct Input: Decodable, Sendable {
            public var name: String?
            /// `app`, `source` or `channel`.
            public var type: String?
            /// The package name, source URI or channel number.
            public var identifier: String?
            public var displayOrder: Int?
        }

        public struct CustomApp: Decodable, Sendable {
            public var name: String?
            public var packageName: String?
            public var className: String?
            public var action: String?
        }

        public struct CustomButton: Decodable, Sendable {
            public var name: String?
            public var key: String?
        }

        public struct SourceSetting: Decodable, Sendable {
            public var id: String?
            public var order: Int?
            public var visible: Bool?
            public var customName: String?
        }

        public var name: String?
        public var devices: [Device]?
    }
}

/// One TV's settings once checked: what the plugin works from.
struct TVSettings: Sendable, Equatable {
    static let defaultPollingInterval = 10_000
    static let pollingIntervalRange = 1000...60_000
    static let defaultAmbilightMode = "FOLLOW_VIDEO/NATURAL"

    var name: String
    /// Uppercase, colon-separated.
    var mac: String
    var ip: String
    var username: String
    var password: String
    var certFingerprint: String?
    var pollingInterval: Duration
    var wakeOnLAN: Bool
    var ambilightMode: String
    var ambilightOnStart: Bool
    var infoButtonKey: String
    var backButtonKey: String
    var playPauseButtonKey: String
    var inputs: [InputData]
    var sourceSwitches: Bool
    var ambilightHueSwitch: Bool
    var customApps: [InputData]
    var customButtons: [(name: String, key: String)]
    var stateSensors: [StateSensor]
    var sources: [String: SourceSetting]

    struct SourceSetting: Sendable, Equatable {
        var order: Int?
        var visible: Bool?
        var customName: String?
    }

    enum StateSensor: String, Sendable, CaseIterable {
        case power, ambilight, mute

        var label: String {
            switch self {
            case .power: "Power"
            case .ambilight: "Ambilight"
            case .mute: "Muted"
            }
        }
    }

    static func == (lhs: TVSettings, rhs: TVSettings) -> Bool {
        lhs.mac == rhs.mac && lhs.name == rhs.name && lhs.ip == rhs.ip && lhs.username == rhs.username && lhs.password == rhs.password
    }

    /// Checks a device block. Throws with what is wrong, so the log says it.
    init(_ device: PhilipsAmbilightTVPlugin.Configuration.Device) throws {
        guard let name = device.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { throw TVConfigurationError.missing("name") }
        guard let rawMAC = device.mac, let mac = Self.canonicalMAC(rawMAC) else { throw TVConfigurationError.invalid("mac", device.mac ?? "") }
        guard let ip = device.ip?.trimmingCharacters(in: .whitespaces), Self.isIPv4(ip) else { throw TVConfigurationError.invalid("ip", device.ip ?? "") }
        guard let username = device.username, !username.isEmpty else { throw TVConfigurationError.missing("username") }
        guard let password = device.password, !password.isEmpty else { throw TVConfigurationError.missing("password") }
        self.name = Self.homeKitName(name)
        self.mac = mac
        self.ip = ip
        self.username = username
        self.password = password
        certFingerprint = device.certFingerprint.map { $0.lowercased().filter(\.isHexDigit) }.flatMap { $0.count == 64 ? $0 : nil }
        if let interval = device.pollingInterval, !Self.pollingIntervalRange.contains(interval) {
            throw TVConfigurationError.invalid("pollingInterval", String(interval))
        }
        pollingInterval = .milliseconds(device.pollingInterval ?? Self.defaultPollingInterval)
        wakeOnLAN = device.wakeOnLanEnabled ?? true
        ambilightMode = device.ambilightMode?.nonEmpty ?? Self.defaultAmbilightMode
        ambilightOnStart = device.ambilightOnStart ?? false
        infoButtonKey = RemoteKeys.valid(device.infoButtonKey) ?? "Source"
        backButtonKey = RemoteKeys.valid(device.backButtonKey) ?? "Back"
        playPauseButtonKey = RemoteKeys.valid(device.playPauseButtonKey) ?? "PlayPause"
        inputs = (device.inputs ?? []).compactMap { input in
            guard let identifier = input.identifier?.nonEmpty, let type = input.type.flatMap(InputType.init(rawValue:)) else { return nil }
            return InputData(id: identifier, name: Self.homeKitName(input.name?.nonEmpty ?? identifier), type: type, displayOrder: input.displayOrder)
        }
        sourceSwitches = device.sourceSwitches ?? false
        ambilightHueSwitch = device.ambilightHueSwitch ?? false
        customApps = (device.customApps ?? []).compactMap { app in
            guard let package = app.packageName?.nonEmpty else { return nil }
            return InputData(id: package, name: Self.homeKitName(app.name?.nonEmpty ?? package), type: .app, className: app.className?.nonEmpty, action: app.action?.nonEmpty)
        }
        customButtons = (device.customButtons ?? []).compactMap { button in
            guard let key = RemoteKeys.valid(button.key) else { return nil }
            return (name: Self.homeKitName(button.name?.nonEmpty ?? key), key: key)
        }
        stateSensors = (device.stateSensors ?? []).compactMap(StateSensor.init(rawValue:))
        var sources: [String: SourceSetting] = [:]
        for setting in device.sources ?? [] {
            guard let id = setting.id?.nonEmpty else { continue }
            sources[id] = SourceSetting(order: setting.order, visible: setting.visible, customName: setting.customName?.nonEmpty.map(Self.homeKitName))
        }
        self.sources = sources
    }

    /// Uppercase colon-separated octets, whatever separators the input had: one spelling, so a TV keeps
    /// its HomeKit identity however its address was typed.
    static func canonicalMAC(_ mac: String) -> String? {
        let digits = mac.trimmingCharacters(in: .whitespaces).filter { $0 != ":" && $0 != "-" && $0 != "." }
        guard digits.count == 12, digits.allSatisfy(\.isHexDigit) else { return nil }
        let characters = Array(digits.uppercased())
        return stride(from: 0, to: 12, by: 2).map { String(characters[$0..<$0 + 2]) }.joined(separator: ":")
    }

    static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil && !$0.isEmpty }
    }

    /// A name HomeKit accepts: letters, digits, spaces, apostrophes, commas, periods and hyphens, 64 at most,
    /// with `+` spelled out (Disney+ shows as "Disney Plus").
    static func homeKitName(_ name: String) -> String {
        var result = ""
        for character in name.replacingOccurrences(of: "+", with: " Plus") {
            if character.isLetter || character.isNumber || character == " " || character == "'" || character == "," || character == "." || character == "-" {
                result.append(character)
            } else if character == "&" {
                result.append(" and ")
            } else if character == "_" || character == "/" || character == ":" {
                result.append(" ")
            }
        }
        let collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ,.'-"))
        let capped = String(trimmed.prefix(64))
        return capped.isEmpty ? "Unnamed" : capped
    }

    /// A name a controller wrote: control characters out, 64 characters at most.
    static func controllerName(_ name: String) -> String {
        String(name.filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }.prefix(64)).trimmingCharacters(in: .whitespaces)
    }
}

enum TVConfigurationError: Error, CustomStringConvertible, Equatable {
    case missing(String)
    case invalid(String, String)

    var description: String {
        switch self {
        case .missing(let key): "\"\(key)\" is missing"
        case .invalid(let key, let value): "\"\(key)\" is not valid: \"\(value)\""
        }
    }
}

/// The keys `/input/key` accepts.
enum RemoteKeys {
    static let all: Set<String> = [
        "Standby", "Back", "Find", "RedColour", "GreenColour", "YellowColour", "BlueColour", "Home", "VolumeUp", "VolumeDown", "Mute",
        "Options", "Dot", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7", "Digit8", "Digit9", "Info",
        "CursorUp", "CursorDown", "CursorLeft", "CursorRight", "Confirm", "Next", "Previous", "Adjust", "WatchTV", "Viewmode", "Teletext",
        "Subtitle", "ChannelStepUp", "ChannelStepDown", "Source", "AmbilightOnOff", "PlayPause", "Pause", "FastForward", "Stop", "Rewind",
        "Record", "Online",
    ]

    static func valid(_ key: String?) -> String? {
        guard let key = key?.trimmingCharacters(in: .whitespaces), all.contains(key) else { return nil }
        return key
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
