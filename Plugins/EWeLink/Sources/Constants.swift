import Foundation

/// The eWeLink cloud: the app credentials the Homebridge plugin uses, the regions and their hosts.
enum EWeLinkCloud {
    static let appID = "Uw83EKZFxdif7XFXEsrpduz5YyjP7nTl"
    static let appSecret = "mXLOjea0woSMvK9gw7Fjsy7YlFO4iSu6"

    enum Region: String, Sendable, CaseIterable, Codable {
        case cn, `as`, us, eu

        var httpHost: String {
            switch self {
            case .cn: "cn-apia.coolkit.cn"
            case .as: "as-apia.coolkit.cc"
            case .us: "us-apia.coolkit.cc"
            case .eu: "eu-apia.coolkit.cc"
            }
        }

        /// The WebSocket servers to fall back on when the dispatch service does not answer.
        var socketHosts: [String] {
            let domain = self == .cn ? "coolkit.cn" : "coolkit.cc"
            return (1...5).map { "\(rawValue)-pconnect\($0).\(domain):8080" }
        }

        /// The country dial codes of the region (`44`, `351`...), as eWeLink assigns them.
        var countryCodes: [String] {
            switch self {
            case .cn: ["86", "cn"]
            case .as: ["81", "82", "852", "853", "886", "91", "65", "60", "66", "84", "62", "63", "61", "64", "as"]
            case .us: ["1"]
            case .eu:
                [
                    "44", "33", "49", "39", "34", "31", "32", "41", "43", "351", "353", "352", "356", "377", "45", "46", "47", "358", "354",
                    "48", "420", "421", "36", "40", "359", "380", "7", "370", "371", "372", "375", "373", "381", "385", "386", "387",
                    "389", "355", "383", "382", "30", "357", "90", "971", "966", "972", "974", "965", "968", "973", "962", "961", "963",
                    "964", "967", "970", "98", "92", "992", "993", "994", "995", "996", "998", "374", "976", "977", "975", "27", "20",
                    "234", "212", "213", "216", "218", "249", "254", "255", "256", "233", "225", "221", "237", "251", "260", "263",
                    "244", "258", "261", "51", "52", "53", "54", "55", "56", "57", "58", "591", "593", "595", "598", "506", "507",
                    "502", "503", "504", "505", "eu",
                ]
            }
        }

        /// The region of a country code (`+44`, `44`, `eu`...); the US when unknown or missing.
        init(countryCode: String?) {
            guard let code = countryCode, !code.isEmpty else {
                self = .us
                return
            }
            var normalized = code.lowercased()
            if let plus = normalized.range(of: "+") { normalized.removeSubrange(plus) }
            // The Homebridge plugin checks the regions in this order: cn, as, eu, us.
            for region in [Region.cn, .as, .eu, .us] where region.countryCodes.contains(normalized) {
                self = region
                return
            }
            self = .us
        }
    }

    /// The WebSocket server for an API host when the dispatch service fails: `pconnect3` of its region.
    static let socketHostMapping: [(prefix: String, host: String)] = [
        ("eu-apia", "eu-pconnect3.coolkit.cc:8080"), ("us-apia", "us-pconnect3.coolkit.cc:8080"),
        ("as-apia", "as-pconnect3.coolkit.cc:8080"), ("cn-apia", "cn-pconnect3.coolkit.cn:8080"),
    ]
}

/// Timeouts, intervals and delays, in milliseconds unless the name says otherwise.
enum Timing {
    static let httpRequest = 30_000
    static let socketAuthentication = 10_000
    /// The platform retries a command that timed out.
    static let socketCommand = 8_000
    /// A LAN command that fails falls back to the cloud quickly.
    static let lanRequest = 3_000
    static let queryRetryAttempts = 3
    static let queryRetryDelay = 2_000

    static let socketReconnect = 5_000
    static let socketHeartbeat = 90_000
    static let socketReconnectMaximum = 300_000
    static let socketReconnectJitter = 0.2
    static let socketMaxReconnectAttempts = 10
    /// A connection that lasted this long resets the reconnection backoff.
    static let socketStableConnection = 60_000

    static let discoveryRetryBase = 15_000
    static let discoveryRetryMaximum = 300_000
    static let discoveryRetryJitter = 0.2

    static let lanMaxConsecutiveFailures = 3
    static let lanCooldown = 60_000
    static let lanDiscoveryReport = 10_000
    static let lanUDPPort = 8082
    static let lanHTTPPort = 8081

    static let inchingDebounce = 1500
    static let failedCommandReset = 2000
    static let buttonPress = 1000
    static let rfButtonPress = 2000
    static let rfButtonTrigger = 3000
    static let garageOperation = 10_000
    static let stateInitDelay = 500
    static let commandDelay = 450
    static let curtainQueryDelay = 5000

    static let pollingInterval = 120_000
    static let pollingInitialDelay = 5000
    static let uiActiveSeconds = 120
    static let valveDefaultSeconds = 120
    static let eventDebounce = 1000
    static let eventFreshnessSeconds = 5.0

    static let autoOffDelay = 5000
    static let doorbellRing = 5000
    static let positionCleanup = 2000
    static let deviceAutoOff = 5000
    static let defaultOperationSeconds = 120.0
    static let colorDebounce = 400

    static let sensorMaxTimeDifferenceSeconds = 60.0
}

/// Ranges and scales of device values.
enum DeviceLimits {
    static let temperature = -270.0...100.0
    static let defaultTemperature = 20.0
    static let humidity = 0.0...100.0
    static let defaultHumidity = 50.0
    static let battery = 0.0...100.0
    static let defaultBattery = 100.0
    static let thermostatTemperature = 5.0...45.0
    static let thermostatStep = 0.5
    /// Raw power, voltage and current readings of a DUALR3 are ×100.
    static let powerDivisor = 100.0
    static let voltageDivisor = 100.0
    static let currentDivisor = 100.0

    /// An air conditioner's fan speeds (eWeLink values) and their HomeKit rotation speeds.
    enum AirConditionerWind {
        static let off = 0, low = 101, medium = 102, high = 103
    }

    enum AirConditionerRotation {
        static let off = 0.0, low = 25.0, medium = 50.0, high = 75.0, lowThreshold = 33.0, highThreshold = 66.0
    }

    enum DiffuserSpeed {
        static let off = 0.0, low = 50.0, high = 100.0
    }

    static let rfButtonTypes: Set<String> = ["1", "2", "3", "4"]
    static let rfSensorTypes: Set<String> = ["6", "7"]
    static let rfCurtainType = "5"

    /// A channel's suffix in a sub-device id (`1000abcdefSW1`).
    static func parentDeviceID(_ deviceID: String) -> String {
        guard let range = deviceID.range(of: "SW[0-9]+$", options: .regularExpression) else { return deviceID }
        return String(deviceID[..<range.lowerBound])
    }

    /// `00` for channel 0: DUALR3 readings are `actPow_00`, `actPow_01`.
    static func channelSuffix(_ channel: Int) -> String { channel < 10 ? "0\(channel)" : "\(channel)" }
}
