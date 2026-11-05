import Foundation
import HomeswiftPlugin

// The `Reolink` block (docs/clean-room/Reolink.md, section 2): no Homebridge platform of that name exists, so the
// shape is the spec's recommendation. Every option is optional and read leniently (a number may be a numeric string).

extension ReolinkPlugin {
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        /// The FFmpeg executable.
        public var videoProcessor: String
        public var devices: [Device]

        public init(from decoder: any Decoder) throws {
            self.init(json: try JSONValue(from: decoder))
        }

        init(json: JSONValue) {
            name = json["name"]?.stringValue
            videoProcessor = json["videoProcessor"]?.stringValue?.nonEmptyText ?? "ffmpeg"
            devices = (json["devices"]?.arrayValue ?? []).compactMap { Device(json: $0) }
        }
    }

    /// A host: a camera, a doorbell, an NVR or a Home Hub (2.2).
    public struct Device: Sendable, Equatable {
        public var host: String
        public var username: String
        public var password: String
        public var port: Int?
        public var useHttps: Bool?
        public var baichuanPort: Int?
        /// An NVR's channels to publish, 0-based; nil for every online channel.
        public var channels: [Int]?
        public var streamProtocol: String
        public var pushEvents: Bool
        public var pollInterval: Int?
        public var motionPollInterval: Int
        public var cameras: [String: CameraOptions]

        /// The keys a host's own Accessory Settings may hold (its address and the way to reach it).
        static let settingKeys = ["host", "port", "useHttps", "baichuanPort", "channels", "streamProtocol", "pushEvents", "pollInterval", "motionPollInterval"]

        init?(json: JSONValue) {
            guard let host = json["host"]?.stringValue?.trimmingCharacters(in: .whitespaces), !host.isEmpty else { return nil }
            self.host = host
            username = json["username"]?.stringValue?.nonEmptyText ?? "admin"
            password = json["password"]?.stringValue ?? ""
            port = json["port"].lenientInt.flatMap { (1...65535).contains($0) ? $0 : nil }
            useHttps = json["useHttps"]?.boolValue
            baichuanPort = json["baichuanPort"].lenientInt.flatMap { (1...65535).contains($0) ? $0 : nil }
            channels = json["channels"]?.arrayValue?.compactMap { $0.saturatingIntValue(in: 0...255) }
            let protocolName = json["streamProtocol"]?.stringValue?.lowercased() ?? "rtsp"
            streamProtocol = ["rtsp", "rtmp", "flv"].contains(protocolName) ? protocolName : "rtsp"
            pushEvents = json["pushEvents"]?.boolValue ?? true
            pollInterval = json["pollInterval"].lenientInt.flatMap { $0 > 0 ? $0 : nil }
            motionPollInterval = max(1, json["motionPollInterval"].lenientInt ?? 5)
            var cameras: [String: CameraOptions] = [:]
            for (key, value) in json["cameras"]?.objectValue ?? [:] { cameras[key] = CameraOptions(json: value) }
            self.cameras = cameras
        }

        /// The full-refresh interval of 7.1: 60 s, 10 more per camera above six, or the configured one (at least 10 s).
        func refreshInterval(cameras count: Int) -> Int {
            if let pollInterval { return max(10, pollInterval) }
            return max(60, 10 * count)
        }
    }

    /// A channel's options (2.2, `cameras["0"]`), also its Accessory Settings.
    public struct CameraOptions: Sendable, Equatable {
        public var name: String?
        public var motionSensor: Bool?
        /// `person`, `vehicle`, `pet`, `face`, `package`; nil for every supported type.
        public var aiSensors: [String]?
        public var doorbell: Bool?
        public var floodlight: Bool?
        public var siren: Bool
        public var irLights: Bool
        public var stream: String
        public var audio: Bool
        public var recording: Bool
        public var prebuffer: Bool
        public var maxStreams: Int
        public var vcodec: String?
        public var encoderOptions: String?
        public var debug: Bool
        public var ringThrottleSeconds: Int
        /// A momentary "Go to <preset>" switch per PTZ preset.
        public var presetSwitches: Bool
        /// A switch that runs the camera's first PTZ patrol.
        public var patrolSwitch: Bool
        /// A Privacy switch where the camera has privacy mode.
        public var privacySwitch: Bool
        /// Motion sensitivity, 1 to 50, written to the device at start; nil leaves it.
        public var motionSensitivity: Int?
        /// AI detections' sensitivity, 0 to 100, written to the device at start; nil leaves it.
        public var aiSensitivity: Int?
        /// A Recording switch: the device's own recording of the channel on or off.
        public var recordingSwitch: Bool
        /// A momentary switch per paired Reolink Chime.
        public var chimeSwitch: Bool
        /// The tone the chime switches play, `musicId` 0 to 9 (`ReolinkChime.tones`).
        public var chimeTone: Int
        /// The floodlight's mode (`ReolinkFloodlight.modes`), written to the device at start; nil leaves it.
        public var floodlightMode: String?

        static let settingKeys = ["motionSensor", "aiSensors", "doorbell", "floodlight", "siren", "irLights", "stream", "audio", "recording", "prebuffer",
                                  "maxStreams", "vcodec", "encoderOptions", "debug", "ringThrottleSeconds", "presetSwitches", "patrolSwitch", "privacySwitch", "floodlightMode", "chimeSwitch", "chimeTone", "recordingSwitch", "motionSensitivity", "aiSensitivity"]

        init(json: JSONValue) {
            name = json["name"]?.stringValue?.nonEmptyText
            motionSensor = json["motionSensor"]?.boolValue
            aiSensors = json["aiSensors"]?.arrayValue?.compactMap { $0.stringValue?.lowercased() }
            doorbell = json["doorbell"]?.boolValue
            floodlight = json["floodlight"]?.boolValue
            siren = json["siren"]?.boolValue ?? false
            irLights = json["irLights"]?.boolValue ?? false
            let stream = json["stream"]?.stringValue?.lowercased() ?? "auto"
            self.stream = ["main", "sub", "auto"].contains(stream) ? stream : "auto"
            audio = json["audio"]?.boolValue ?? false
            recording = json["recording"]?.boolValue ?? false
            prebuffer = recording && (json["prebuffer"]?.boolValue ?? false)
            maxStreams = min(4, max(1, json["maxStreams"].lenientInt ?? 2))
            vcodec = json["vcodec"]?.stringValue?.nonEmptyText
            encoderOptions = json["encoderOptions"]?.stringValue?.nonEmptyText
            debug = json["debug"]?.boolValue ?? false
            ringThrottleSeconds = max(0, json["ringThrottleSeconds"].lenientInt ?? 3)
            presetSwitches = json["presetSwitches"]?.boolValue ?? false
            patrolSwitch = json["patrolSwitch"]?.boolValue ?? false
            privacySwitch = json["privacySwitch"]?.boolValue ?? true
            motionSensitivity = json["motionSensitivity"].lenientInt.map { min(50, max(1, $0)) }
            aiSensitivity = json["aiSensitivity"].lenientInt.map { min(100, max(0, $0)) }
            recordingSwitch = json["recordingSwitch"]?.boolValue ?? false
            chimeSwitch = json["chimeSwitch"]?.boolValue ?? false
            chimeTone = json["chimeTone"]?.stringValue.flatMap { ReolinkChime.tones.firstIndex(of: $0) } ?? 0
            floodlightMode = json["floodlightMode"]?.stringValue.flatMap { ReolinkFloodlight.modeNumber($0) == nil ? nil : $0 }
        }

        /// The options with Accessory Settings on top.
        func with(settings: [String: JSONValue]) -> CameraOptions {
            var fields = json.objectValue ?? [:]
            for key in Self.settingKeys { if let value = settings[key] { fields[key] = value } }
            return CameraOptions(json: .object(fields))
        }

        var json: JSONValue {
            var fields: [String: JSONValue] = ["siren": .bool(siren), "irLights": .bool(irLights), "stream": .string(stream), "audio": .bool(audio),
                                               "recording": .bool(recording), "prebuffer": .bool(prebuffer), "maxStreams": .number(Double(maxStreams)),
                                               "debug": .bool(debug), "ringThrottleSeconds": .number(Double(ringThrottleSeconds)),
                                               "presetSwitches": .bool(presetSwitches), "patrolSwitch": .bool(patrolSwitch),
                                               "privacySwitch": .bool(privacySwitch),
                                               "chimeSwitch": .bool(chimeSwitch), "recordingSwitch": .bool(recordingSwitch), "chimeTone": .string(ReolinkChime.tones[chimeTone])]
            if let name { fields["name"] = .string(name) }
            if let motionSensor { fields["motionSensor"] = .bool(motionSensor) }
            if let aiSensors { fields["aiSensors"] = .array(aiSensors.map(JSONValue.string)) }
            if let doorbell { fields["doorbell"] = .bool(doorbell) }
            if let floodlight { fields["floodlight"] = .bool(floodlight) }
            if let vcodec { fields["vcodec"] = .string(vcodec) }
            if let encoderOptions { fields["encoderOptions"] = .string(encoderOptions) }
            if let floodlightMode { fields["floodlightMode"] = .string(floodlightMode) }
            if let motionSensitivity { fields["motionSensitivity"] = .number(Double(motionSensitivity)) }
            if let aiSensitivity { fields["aiSensitivity"] = .number(Double(aiSensitivity)) }
            return .object(fields)
        }

        static let defaults = CameraOptions(json: [:])

        /// The options the device itself keeps, written at start.
        var deviceSettings: ReolinkHost.DeviceSettings {
            ReolinkHost.DeviceSettings(floodlightMode: floodlightMode, motionSensitivity: motionSensitivity, aiSensitivity: aiSensitivity)
        }
    }
}

extension Optional where Wrapped == JSONValue {
    /// An integer from a number or a numeric string; nil otherwise.
    var lenientInt: Int? {
        switch self {
        case .number(let value)?: return Int(saturating: value)
        case .string(let value)?: return Double(value.trimmingCharacters(in: .whitespaces)).flatMap { Int(saturating: $0) }
        default: return nil
        }
    }
}
