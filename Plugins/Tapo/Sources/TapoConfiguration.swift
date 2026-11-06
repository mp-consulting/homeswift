import Foundation

extension TapoPlugin {
    /// The Homebridge plugin's block (docs/clean-room/Tapo.md, 2), so it works unchanged. `pollingInterval` and
    /// `timeout` at the top and `port` of a device are unused there and are not read here; `waitTimeUpdate` is unused
    /// there and here is how long writes wait for the ones made with them.
    public struct Configuration: Decodable, Sendable {
        public struct Device: Decodable, Sendable {
            /// The display name, and with `host` the device's identity.
            public var name: String?
            public var host: String?
            /// `Plug` (the default), `PowerPlug`, `Light`, `WhiteLight` or `Colorlight`, in any case.
            public var type: String?
            /// Seconds between polls; 10 when absent or 0.
            public var updateInterval: TapoNumber?
            /// Seconds before a securePassthrough request gives up; 2 when absent or 0.
            public var timeout: TapoNumber?
            /// A camera's stream: `HD` (the default; every lens, HEVC) or `VGA` (one 1280 x 720 H.264 stream: a C675D's tele lens).
            public var resolution: String?
            /// Whether a camera has a Motion Sensor, from the TP-Link cloud's notifications: on by default.
            public var motion: Bool?
            /// The camera's id in the TP-Link cloud, when its name, its model or its MAC do not find it.
            public var cloudId: String?
            /// Whether a camera's lenses each get a HAP server of their own (`publishExternal`), added in the Home app one
            /// by one, rather than going on the bridge: off by default, as UniFi Protect's `Device.Standalone`.
            public var standalone: Bool?
        }

        /// The Tapo account's email.
        public var username: String?
        public var password: String?
        public var devices: [Device]?
        /// Milliseconds; 100 by default.
        public var waitTimeUpdate: TapoNumber?
        /// The FFmpeg the cameras' streams go through: `ffmpeg` on the path by default.
        public var videoProcessor: String?
    }
}

/// A number, or a numeric string as the Homebridge plugin's schema writes its defaults (`"10"`); anything else is nil.
public struct TapoNumber: Decodable, Sendable, Equatable {
    public var value: Double?

    public init(_ value: Double?) { self.value = value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number.isFinite ? number : nil
        } else if let text = try? container.decode(String.self) {
            value = Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        } else {
            value = nil
        }
    }

    /// The value when it is above zero.
    var positive: Double? { value.flatMap { $0 > 0 ? $0 : nil } }
}

extension TapoPlugin.Configuration.Device {
    var trimmedHost: String? {
        guard let host = host?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
        return host
    }

    var trimmedName: String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// The Device Id: the host and the name run together, as the Homebridge plugin seeded its accessory's UUID with them
    /// (`192.168.1.21Kitchen`), or the host alone without a name. A Homebridge user's accessories keep their identity.
    /// Both as written, so the seed is the same.
    var deviceID: String? {
        guard trimmedHost != nil, let host else { return nil }
        return host + (trimmedName ?? "")
    }
}
