import Foundation
import Homeswift
import HomeswiftPlugin

// The `Camera-ffmpeg` block of homebridge-camera-ffmpeg, read as that plugin reads it: most options are tested for
// JavaScript truthiness (absent, null, false, 0 and "" are all "off"), ports may be numbers or numeric strings, and
// unknown keys (`unbridge`, `hflip`, a top-level `topic`…) are ignored. docs/clean-room/CameraFFmpeg.md, section 3.

extension IPCamerasPlugin {
    public struct Configuration: Decodable, Sendable {
        /// `videoProcessor`: the FFmpeg executable (a path, or a name in PATH); `ffmpeg` when unset.
        public var videoProcessor: String?
        /// `mqtt`: the broker's host; no MQTT without it.
        public var mqttHost: String?
        public var mqttPort: Int
        public var mqttTLS: Bool
        public var mqttUsername: String?
        /// Homebridge's `passmqtt`, read until the bridge moves it into the vault (`canonicalSettings`).
        public var mqttPassword: String?
        /// `porthttp`: the automation server's port; no server without it.
        public var httpPort: Int?
        /// `localhttp`: the automation server listens on the loopback address only.
        public var httpLocalOnly: Bool
        public var cameras: [Camera]

        public init(from decoder: any Decoder) throws {
            self.init(json: try JSONValue(from: decoder))
        }

        init(json: JSONValue) {
            videoProcessor = json["videoProcessor"].truthyString
            mqttHost = json["mqtt"].truthyString
            mqttPort = json["portmqtt"].truthyInt ?? 1883
            mqttTLS = json["tlsmqtt"].isTruthy
            mqttUsername = json["usermqtt"].truthyString
            mqttPassword = json["passmqtt"].truthyString
            httpPort = json["porthttp"].truthyInt
            httpLocalOnly = json["localhttp"].isTruthy
            cameras = (json["cameras"]?.arrayValue ?? []).map(Camera.init(json:))
        }
    }

    /// A `cameras[]` entry.
    public struct Camera: Sendable {
        /// Falsy for an unnamed camera, which the plugin names `Camera N`.
        public var name: String?
        public var manufacturer: String
        public var model: String
        public var serialNumber: String
        public var firmwareRevision: String
        public var motion: Bool
        public var doorbell: Bool
        public var switches: Bool
        /// Seconds; nil when absent or null (the plugin then uses 1).
        public var motionTimeout: Int?
        public var motionDoorbell: Bool
        public var videoConfig: VideoConfig?
        public var mqtt: CameraMQTT?
        /// The entry as the block has it.
        let json: JSONValue

        /// The options a camera's Accessory Settings hold (`accessorySchema`), which `canonicalSettings` moves out of its
        /// `cameras` entry.
        static let accessorySettingKeys = ["motion", "doorbell", "switches", "motionTimeout", "motionDoorbell"]

        /// The camera with its Accessory Settings on top of its entry's options.
        func with(settings: [String: JSONValue]) -> Camera {
            var fields = json.objectValue ?? [:]
            for key in Self.accessorySettingKeys { if let value = settings[key] { fields[key] = value } }
            return Camera(json: .object(fields))
        }

        init(json: JSONValue) {
            self.json = json
            name = json["name"].truthyString
            manufacturer = json["manufacturer"].truthyString ?? "Homebridge"
            model = json["model"].truthyString ?? "Camera FFmpeg"
            serialNumber = json["serialNumber"].truthyString ?? "SerialNumber"
            firmwareRevision = json["firmwareRevision"].truthyString ?? PluginHost.version
            motion = json["motion"].isTruthy
            doorbell = json["doorbell"].isTruthy
            switches = json["switches"].isTruthy
            motionTimeout = json["motionTimeout"].lenientInt
            motionDoorbell = json["motionDoorbell"].isTruthy
            videoConfig = json["videoConfig"]?.objectValue.map { VideoConfig(json: .object($0)) }
            mqtt = json["mqtt"]?.objectValue.map { CameraMQTT(json: .object($0)) }
        }
    }

    /// `videoConfig`.
    public struct VideoConfig: Sendable {
        public var source: String?
        public var stillImageSource: String?
        public var returnAudioTarget: String?
        public var maxStreams: Int
        /// nil when absent: no cap. 0 keeps the source's size.
        public var maxWidth: Int?
        public var maxHeight: Int?
        public var maxFPS: Int?
        public var maxBitrate: Int?
        public var forceMax: Bool
        public var vcodec: String
        public var packetSize: Int
        public var videoFilter: String?
        public var encoderOptions: String?
        public var mapvideo: String?
        public var mapaudio: String?
        public var audio: Bool
        /// `audio` is exactly `false` (not absent): recordings then get a silent track (section 9.4).
        public var audioExplicitlyOff: Bool
        public var debug: Bool
        public var debugReturn: Bool
        public var recording: Bool
        /// Only with `recording`.
        public var prebuffer: Bool

        init(json: JSONValue) {
            source = json["source"].truthyString
            stillImageSource = json["stillImageSource"].truthyString
            returnAudioTarget = json["returnAudioTarget"].truthyString
            maxStreams = max(1, json["maxStreams"].lenientInt ?? 2)
            // A cap given as null is no cap.
            maxWidth = json["maxWidth"].lenientInt
            maxHeight = json["maxHeight"].lenientInt
            maxFPS = json["maxFPS"].lenientInt
            maxBitrate = json["maxBitrate"].lenientInt
            forceMax = json["forceMax"].isTruthy
            vcodec = json["vcodec"].truthyString ?? "libx264"
            packetSize = json["packetSize"].truthyInt ?? 1316
            videoFilter = json["videoFilter"].truthyString
            encoderOptions = json["encoderOptions"].truthyString
            mapvideo = json["mapvideo"].truthyString
            mapaudio = json["mapaudio"].truthyString
            audio = json["audio"].isTruthy
            audioExplicitlyOff = json["audio"] == .bool(false)
            debug = json["debug"].isTruthy
            debugReturn = json["debugReturn"].isTruthy
            recording = json["recording"].isTruthy
            prebuffer = recording && json["prebuffer"].isTruthy
        }
    }

    /// A camera's `mqtt` topics; a falsy message is the camera's name.
    public struct CameraMQTT: Sendable {
        public var motionTopic: String?
        public var motionMessage: String?
        public var motionResetTopic: String?
        public var motionResetMessage: String?
        public var doorbellTopic: String?
        public var doorbellMessage: String?

        init(json: JSONValue) {
            motionTopic = json["motionTopic"].truthyString
            motionMessage = json["motionMessage"].truthyString
            motionResetTopic = json["motionResetTopic"].truthyString
            motionResetMessage = json["motionResetMessage"].truthyString
            doorbellTopic = json["doorbellTopic"].truthyString
            doorbellMessage = json["doorbellMessage"].truthyString
        }
    }
}

extension Optional where Wrapped == JSONValue {
    /// JavaScript truthiness: absent, null, false, 0, NaN and "" are false.
    var isTruthy: Bool {
        switch self {
        case nil, .null?: false
        case .bool(let value)?: value
        case .number(let value)?: value != 0 && !value.isNaN
        case .string(let value)?: !value.isEmpty
        case .array?, .object?: true
        }
    }

    /// A truthy string (a number is written as JavaScript would print it); nil otherwise.
    var truthyString: String? {
        guard isTruthy else { return nil }
        switch self {
        case .string(let value)?: return value
        case .number(let value)?: return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        default: return nil
        }
    }

    /// An integer from a number or a numeric string ("8080"); nil otherwise.
    var lenientInt: Int? {
        switch self {
        case .number(let value)?: return Int(saturating: value)
        case .string(let value)?: return Double(value.trimmingCharacters(in: .whitespaces)).flatMap { Int(saturating: $0) }
        default: return nil
        }
    }

    /// A truthy integer: nil for 0 and for anything that is not a number.
    var truthyInt: Int? {
        guard let value = lenientInt, value != 0 else { return nil }
        return value
    }
}
