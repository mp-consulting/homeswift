import Foundation
import Homeswift

extension DolphinPoolCleanerPlugin {
    /// The platform block of `@mp-consulting/homebridge-dolphin-pool-cleaner`, key for key. Every option is
    /// optional, and numbers and booleans written as strings are read as Homebridge reads them.
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            /// The robot's serial number, on the power supply's label.
            public var serialNumber: String?
            /// The name in HomeKit; the robot's name in the app otherwise.
            public var name: String?
            /// Saved by the setup wizard for display; the plugin reads the type from the account.
            public var deviceType: Int?
            /// The mode a start from HomeKit uses: `all` by default, `regular` is an alias of it.
            public var cleaningMode: String?
            /// `false` leaves the water temperature sensor out.
            public var enableTemperature: Bool?
            /// `false` leaves the filter indicator out.
            public var enableFilterStatus: Bool?
            /// Saved by the setup wizard: the robot's picture, for the page.
            public var robotImageUrl: String?

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Keys.self)
                serialNumber = container.lenientString(.serialNumber)
                name = container.lenientString(.name)
                deviceType = container.lenientInt(.deviceType)
                cleaningMode = container.lenientString(.cleaningMode)
                enableTemperature = container.lenientBool(.enableTemperature)
                enableFilterStatus = container.lenientBool(.enableFilterStatus)
                robotImageUrl = container.lenientString(.robotImageUrl)
            }

            init(serialNumber: String?, name: String? = nil, cleaningMode: String? = nil, enableTemperature: Bool? = nil, enableFilterStatus: Bool? = nil) {
                self.serialNumber = serialNumber
                self.name = name
                self.cleaningMode = cleaningMode
                self.enableTemperature = enableTemperature
                self.enableFilterStatus = enableFilterStatus
            }
        }

        public var name: String?
        public var email: String?
        /// Optional: the setup wizard stores a refresh token instead.
        public var password: String?
        /// Saved by the setup wizard; preferred over the password.
        public var refreshToken: String?
        /// The AWS IoT region of the robot, `eu-west-1`.
        public var iotRegion: String?
        /// Seconds between status polls, 30 at least, 60 by default.
        public var pollingInterval: Int?
        public var devices: [Device]?

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Keys.self)
            name = container.lenientString(.name)
            email = container.lenientString(.email)
            password = container.lenientString(.password)
            refreshToken = container.lenientString(.refreshToken)
            iotRegion = container.lenientString(.iotRegion)
            pollingInterval = container.lenientInt(.pollingInterval)
            devices = try? container.decodeIfPresent([Device].self, forKey: .devices)
        }

        init(email: String? = nil, password: String? = nil, refreshToken: String? = nil, iotRegion: String? = nil, pollingInterval: Int? = nil, devices: [Device]? = nil) {
            self.email = email
            self.password = password
            self.refreshToken = refreshToken
            self.iotRegion = iotRegion
            self.pollingInterval = pollingInterval
            self.devices = devices
        }

        /// A refresh token, or an email and a password: the plugin needs one of the two.
        var hasCredentials: Bool {
            refreshToken?.isEmpty == false || (email?.isEmpty == false && password?.isEmpty == false)
        }

        /// The polling interval in seconds: 60 when unset or 0, never below 30, nor above the longest delay a
        /// JavaScript timer takes (2³¹ - 1 ms, about 24.8 days).
        var effectivePollingInterval: Int {
            let configured = pollingInterval ?? 0
            let interval = max(configured == 0 ? DolphinPoolCleanerPlugin.defaultPollingInterval : configured, DolphinPoolCleanerPlugin.minimumPollingInterval)
            return min(interval, DolphinPoolCleanerPlugin.maximumPollingInterval)
        }

        func device(serialNumber: String) -> Device? {
            devices?.first { $0.serialNumber == serialNumber }
        }
    }
}

private struct Keys: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }

    static let serialNumber = Keys(stringValue: "serialNumber")
    static let name = Keys(stringValue: "name")
    static let deviceType = Keys(stringValue: "deviceType")
    static let cleaningMode = Keys(stringValue: "cleaningMode")
    static let enableTemperature = Keys(stringValue: "enableTemperature")
    static let enableFilterStatus = Keys(stringValue: "enableFilterStatus")
    static let robotImageUrl = Keys(stringValue: "robotImageUrl")
    static let email = Keys(stringValue: "email")
    static let password = Keys(stringValue: "password")
    static let refreshToken = Keys(stringValue: "refreshToken")
    static let iotRegion = Keys(stringValue: "iotRegion")
    static let pollingInterval = Keys(stringValue: "pollingInterval")
    static let devices = Keys(stringValue: "devices")
}

/// Homebridge hands plugins the JSON as written, and JavaScript is forgiving: a number in quotes is still a
/// number, a serial number typed as digits is still a serial number.
extension KeyedDecodingContainer where Key == Keys {
    fileprivate func lenientString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return String(int) }
        return nil
    }

    fileprivate func lenientInt(_ key: Key) -> Int? {
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int }
        if let double = try? decodeIfPresent(Double.self, forKey: key), let int = Int(saturating: double) { return int }
        if let string = try? decodeIfPresent(String.self, forKey: key) { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    fileprivate func lenientBool(_ key: Key) -> Bool? {
        if let bool = try? decodeIfPresent(Bool.self, forKey: key) { return bool }
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            switch string.lowercased() {
            case "true": return true
            case "false": return false
            default: return nil
            }
        }
        if let int = try? decodeIfPresent(Int.self, forKey: key) { return int != 0 }
        return nil
    }
}
