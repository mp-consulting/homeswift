import Foundation

extension UniFiAccessPlugin {
    /// The platform block of `homebridge-unifi-access`, key for key. Decoding is lenient where Homebridge was:
    /// numbers may be strings, a missing array is empty, entries of the wrong type are skipped.
    public struct Configuration: Decodable, Sendable {
        public struct Controller: Decodable, Sendable, Equatable {
            /// Hostname or IP address, optionally with a port.
            public var address: String?
            public var username: String?
            public var password: String?
            /// For the log; the controller's own name otherwise.
            public var name: String?
            /// `mqtt://`, `mqtts://`, `tcp://` or `ssl://`; MQTT is off without it.
            public var mqttUrl: String?
            /// `unifi/access` by default.
            public var mqttTopic: String?
            /// Validate an `mqtts://` broker's certificate; true by default.
            public var mqttVerifyTls: Bool?
            /// Validate the controller's certificate against the system's roots; off by default, when the
            /// certificate is pinned on first use instead.
            public var verifyTls: Bool?

            public init(
                address: String? = nil, username: String? = nil, password: String? = nil, name: String? = nil, mqttUrl: String? = nil, mqttTopic: String? = nil,
                mqttVerifyTls: Bool? = nil, verifyTls: Bool? = nil
            ) {
                self.address = address
                self.username = username
                self.password = password
                self.name = name
                self.mqttUrl = mqttUrl
                self.mqttTopic = mqttTopic
                self.mqttVerifyTls = mqttVerifyTls
                self.verifyTls = verifyTls
            }

            enum CodingKeys: String, CodingKey {
                case address, username, password, name, mqttUrl, mqttTopic, mqttVerifyTls, verifyTls
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                address = container.lenientString(.address)
                username = container.lenientString(.username)
                password = container.lenientString(.password)
                name = container.lenientString(.name)
                mqttUrl = container.lenientString(.mqttUrl)
                mqttTopic = container.lenientString(.mqttTopic)
                mqttVerifyTls = container.lenientBool(.mqttVerifyTls)
                verifyTls = container.lenientBool(.verifyTls)
            }
        }

        public var name: String?
        public var controllers: [Controller]
        /// Feature options: `Enable.<Category>.<Option>[.<id>][.<value>]` or `Disable.…`.
        public var options: [String]
        /// Seconds between doorbell rings HomeKit hears; 0 lets every ring through.
        public var ringDelay: Int

        public init(name: String? = nil, controllers: [Controller] = [], options: [String] = [], ringDelay: Int = 0) {
            self.name = name
            self.controllers = controllers
            self.options = options
            self.ringDelay = ringDelay
        }

        enum CodingKeys: String, CodingKey {
            case name, controllers, options, ringDelay
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = container.lenientString(.name)
            controllers = (try? container.decodeIfPresent([Lenient<Controller>].self, forKey: .controllers))?.compactMap(\.value) ?? []
            options = (try? container.decodeIfPresent([Lenient<String>].self, forKey: .options))?.compactMap(\.value) ?? []
            ringDelay = max(0, container.lenientInt(.ringDelay) ?? 0)
        }
    }
}

/// A value that decodes to nil instead of failing, so one bad array entry does not cost the others.
struct Lenient<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let double = try? decodeIfPresent(Double.self, forKey: key), double.isFinite { return Int(double) }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            return Int(string.trimmingCharacters(in: .whitespaces)) ?? Double(string.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? Int($0) : nil }
        }
        return nil
    }
}

/// The plugin's constants and the small helpers of `settings.ts`.
enum AccessSettings {
    /// How often to bootstrap a controller again for new or removed devices.
    static let controllerRefreshInterval: Duration = .seconds(120)
    /// Between login and bootstrap attempts, before jitter.
    static let controllerRetryInterval: Duration = .seconds(10)
    /// Seconds before a device that left the controller leaves HomeKit (`Controller.DelayDeviceRemoval`).
    static let deviceRemovalDelay = 60
    /// Seconds of a full gate cycle: opening, open, closing (`Hub.GateDirectionDuration`).
    static let gateDirectionDuration = 90
    /// Minutes before a relay unlocked from HomeKit locks again (`Hub.LockDelayInterval`).
    static let deviceUnlockInterval = 0
    /// Where the pinned controller certificates are kept, in the plugin's storage directory.
    static let tlsPinFile = "unifi-access-tls-pins.json"
    /// Which controller each accessory belongs to (Homebridge kept it in the accessory's context).
    static let ownersFile = "accessory-owners.json"
    /// `<topic>/<device MAC>/<event>`.
    static let mqttTopic = "unifi/access"
    /// Before a characteristic goes back after a failed or ignored write.
    static let revertDelay: Duration = .milliseconds(50)

    /// `aa:bb:cc:dd:ee:ff` as `AABBCCDDEEFF`.
    static func normalizeMac(_ mac: String) -> String {
        mac.replacingOccurrences(of: ":", with: "").uppercased()
    }

    /// The identifiers feature options are scoped to: a MAC without separators, optionally followed by a port for
    /// multi-door devices (`AABBCCDDEEFF-PORT1`).
    static func isAccessIdentifier(_ segment: String) -> Bool {
        let parts = segment.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let mac = parts.first, mac.count == 12, mac.allSatisfy(\.isHexDigit), mac.allSatisfy(\.isASCII) else { return false }
        if parts.count == 2 {
            return !parts[1].isEmpty && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
        return true
    }

    /// A controller address the plugin connects to: a hostname or IPv4 address, optionally with a port; never
    /// loopback, link-local or unspecified, in any IPv4 spelling (`2130706433`, `0177.0.0.1` and `127.1` are
    /// 127.0.0.1). The address is spliced into URLs, so credentials, paths and fragments are refused.
    static func isValidAddress(_ address: String?) -> Bool {
        guard let address else { return false }
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        var host = trimmed
        if let colon = trimmed.lastIndex(of: ":") {
            let port = trimmed[trimmed.index(after: colon)...]
            guard (1...5).contains(port.count), port.allSatisfy(\.isNumber), let value = Int(port), value <= 65535 else { return false }
            host = String(trimmed[..<colon])
        }
        // Labels of letters, digits, underscores and inner hyphens, dot-separated, an optional final dot.
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard let first = label.first, let last = label.last, label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                first != "-", last != "-"
            else { return false }
        }
        // The URL parser's view of the host: a name ending in a number is an IPv4 address in some notation.
        let canonical: String
        switch ipv4(host) {
        case .notIPv4: canonical = host
        case .invalid: return false
        case .address(let value):
            canonical = [24, 16, 8, 0].map { String((value >> UInt32($0)) & 0xFF) }.joined(separator: ".")
        }
        if canonical == "localhost" || canonical.hasSuffix(".localhost") || canonical.hasPrefix("127.") || canonical.hasPrefix("169.254.") || canonical == "0.0.0.0" {
            return false
        }
        return true
    }

    private enum IPv4Parse: Equatable {
        case notIPv4, invalid
        case address(UInt32)
    }

    /// The WHATWG URL host parser's IPv4 rules: up to four parts, each decimal, `0x` hex or `0`-prefixed octal;
    /// the last part fills the remaining bytes.
    private static func ipv4(_ host: String) -> IPv4Parse {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" { parts.removeLast() }
        guard let last = parts.last, number(last) != nil || last.allSatisfy(\.isNumber) else { return .notIPv4 }
        guard parts.count <= 4 else { return .invalid }
        var numbers: [UInt64] = []
        for part in parts {
            guard let value = number(part) else { return .invalid }
            numbers.append(value)
        }
        for value in numbers.dropLast() where value > 255 { return .invalid }
        let lastValue = numbers[numbers.count - 1]
        let limit = UInt64(1) << UInt64(8 * (5 - numbers.count))
        guard lastValue < limit else { return .invalid }
        var result = lastValue
        for (index, value) in numbers.dropLast().enumerated() {
            result += value << UInt64(8 * (3 - index))
        }
        return .address(UInt32(truncatingIfNeeded: result))
    }

    private static func number(_ part: String) -> UInt64? {
        guard !part.isEmpty else { return nil }
        if part.hasPrefix("0x") || part.hasPrefix("0X") {
            let digits = part.dropFirst(2)
            return digits.isEmpty ? 0 : UInt64(digits, radix: 16)
        }
        if part.count > 1, part.hasPrefix("0") {
            return UInt64(part.dropFirst(), radix: 8)
        }
        return UInt64(part, radix: 10)
    }

    /// A name HomeKit accepts, as `sanitizeName` makes it: characters HomeKit refuses become spaces, runs of
    /// spaces collapse, and the name starts and ends with a letter or digit.
    static func sanitizeName(_ name: String) -> String {
        let allowed: Set<Character> = [" ", "’", "'", "&", "!", ".", "_", ":", ";", "(", ")", "/", ",", "-"]
        var result = ""
        for character in name {
            if character.isLetter || character.isNumber || allowed.contains(character) || character.isWhitespace {
                result.append(character.isWhitespace ? " " : character)
            } else {
                result.append(" ")
            }
        }
        var collapsed = result.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        while let first = collapsed.first, !(first.isLetter || first.isNumber) { collapsed.removeFirst() }
        while let last = collapsed.last, !(last.isLetter || last.isNumber) { collapsed.removeLast() }
        return collapsed
    }

    /// `v1.2.3.4567` as `1.2.3`, `v4` as `4.0.0`; anything else as it is. The rules of the regular expression
    /// `^v(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(.+))?$` the Homebridge plugin used.
    static func firmwareRevision(_ firmware: String) -> String {
        guard firmware.hasPrefix("v") else { return firmware }
        let rest = Substring(firmware.dropFirst())
        let major = rest.prefix { $0.isASCII && $0.isNumber }
        guard !major.isEmpty else { return firmware }
        /// Whatever may close the match: nothing, or a dot and at least one character.
        func closes(_ text: Substring) -> Bool { text.isEmpty || (text.first == "." && text.count >= 2) }
        /// A dot, digits, and what follows them.
        func number(_ text: Substring) -> (Substring, Substring)? {
            guard text.first == "." else { return nil }
            let digits = text.dropFirst().prefix { $0.isASCII && $0.isNumber }
            return digits.isEmpty ? nil : (digits, text.dropFirst(1 + digits.count))
        }
        /// The patch number and whether the text after the minor version can end the match.
        func patch(_ text: Substring) -> (patch: Substring?, ok: Bool) {
            if let (digits, after) = number(text), closes(after) { return (digits, true) }
            return (nil, closes(text))
        }
        let afterMajor = rest.dropFirst(major.count)
        if let (minor, afterMinor) = number(afterMajor) {
            let (patchNumber, ok) = patch(afterMinor)
            if ok { return "\(major).\(minor).\(patchNumber ?? "0")" }
        }
        let (patchOnly, ok) = patch(afterMajor)
        if ok { return "\(major).0.\(patchOnly ?? "0")" }
        return firmware
    }
}
