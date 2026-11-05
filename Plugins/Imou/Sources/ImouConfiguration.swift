import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// The `Imou` block (docs/clean-room/Imou.md, section 2). No Homebridge plugin exists for IMOU, so the names are the spec's:
// the developer app's `appId` and `appSecret` (or Setup's, in the vault), the region, the poll intervals, and `devices`,
// cameras by address, which Setup moves into `_accessories` by Device Id with their safety code in the vault. Numbers may
// be written as strings.
extension ImouPlugin {
    public struct Configuration: Decodable, Sendable {
        public var appID: String?
        /// Read until `canonicalSettings` moves it into the vault.
        public var appSecret: String?
        public var region: String?
        public var apiURL: String?
        public var pollingInterval: Int?
        /// nil: the cloud's alarms are polled every 60 s only for a camera whose local event stream is down. 0: never. 30 or
        /// more: that often, also for cameras without a local address.
        public var alarmPollInterval: Int?
        public var snapshotWait: Double?
        public var wakeWait: Double?
        public var dormantRetryWait: Int?
        /// `HD` (the main stream) or `SD`, for cloud live video.
        public var resolution: String?
        public var motionTimeout: Int?
        public var videoProcessor: String?
        /// FFmpeg's video encoder and options (`copy` for none).
        public var encoder: String?
        public var devices: [Device]

        public init(from decoder: any Decoder) throws {
            self.init(json: try JSONValue(from: decoder))
        }

        init(json: JSONValue) {
            appID = json["appId"].text
            appSecret = json["appSecret"].text
            region = json["region"].text?.lowercased()
            apiURL = json["apiUrl"].text
            pollingInterval = json["pollingInterval"].lenientInt
            alarmPollInterval = json["alarmPollInterval"].lenientInt
            snapshotWait = json["snapshotWait"].lenientDouble
            wakeWait = json["wakeWait"].lenientDouble
            dormantRetryWait = json["dormantRetryWait"].lenientInt
            resolution = json["resolution"].text?.uppercased()
            motionTimeout = json["motionTimeout"].lenientInt
            videoProcessor = json["videoProcessor"].text
            encoder = json["encoder"].text
            devices = (json["devices"]?.arrayValue ?? []).compactMap { $0.objectValue.map { Device(json: .object($0)) } }
        }

        var cloudRegion: ImouRegion { region.flatMap(ImouRegion.init(rawValue:)) ?? .sg }
        var pollSeconds: Int { min(max(pollingInterval ?? 300, 30), 900) }
        var snapshotWaitSeconds: Double { min(max(snapshotWait ?? 3, 1), 9) }
        var wakeWaitSeconds: Double { min(max(wakeWait ?? 4, 1), 30) }
        var dormantRetrySeconds: Int { min(max(dormantRetryWait ?? 5, 5), 60) }
        var streamID: Int { resolution == "SD" ? 1 : 0 }
    }

    /// A `devices` entry: a camera by address (Setup finds its Device Id), or by its Device Id with its options.
    public struct Device: Sendable, Equatable {
        public var deviceID: String?
        public var name: String?
        public var host: String?
        /// The safety code, under `password` or `safetyCode` (both secret-named, sealed by the runtime): it moves into the
        /// vault with the next settings write.
        public var password: String?
        public var options: [String: JSONValue]

        init(json: JSONValue) {
            deviceID = json["deviceId"].text
            name = json["name"].text
            host = json["host"].text
            password = json["password"].text ?? json["safetyCode"].text
            options = (json.objectValue ?? [:]).filter { CameraSettings.keys.contains($0.key) }
        }
    }

    /// A camera's own options: its Accessory Settings (by Device Id), over its `devices` entry's, the plugin-wide ones under.
    public struct CameraSettings: Sendable, Equatable {
        static let keys: Set<String> = [
            "host", "rtspPort", "httpPort", "username", "localEvents", "motionTimeout", "privacySwitch", "lightSwitch", "sirenSwitch", "motionDetectSwitch",
            "recording", "encoder", "personDetectSwitch", "statusLightSwitch", "linkageSirenSwitch", "linkageLightSwitch", "nightVisionSwitch", "presetSwitches",
            "twoWayAudio", "talkCodec", "talkMethod", "talkZeroTimestamps",
        ]

        var host: String?
        var rtspPort = 554
        var httpPort = 80
        var username = "admin"
        var password: String?
        var localEvents = true
        var motionTimeout = 15
        var privacySwitch = true
        var lightSwitch = true
        var sirenSwitch = true
        var motionDetectSwitch = true
        var recording = true
        var encoder: String?
        /// The addendum's switches (section 2): off unless asked for, since each read costs calls of the day's budget.
        var personDetectSwitch = false
        var statusLightSwitch = false
        var linkageSirenSwitch = false
        var linkageLightSwitch = false
        var nightVisionSwitch = false
        /// A "Go to <preset>" switch per PTZ preset.
        var presetSwitches = false
        /// Two-way talk (ImouTalk.md): experimental, off unless asked for; `auto` asks the camera whether it has a speaker.
        var twoWayAudio = TalkMode.off
        var talkCodec = TalkCodec.g711A
        var talkMethod = TalkMethod.auto
        var talkZeroTimestamps = false

        init(fields: [String: JSONValue], password: String?, defaults: Configuration) {
            let json = JSONValue.object(fields)
            host = json["host"].text
            rtspPort = json["rtspPort"].lenientInt.flatMap { (1...65535).contains($0) ? $0 : nil } ?? rtspPort
            httpPort = json["httpPort"].lenientInt.flatMap { (1...65535).contains($0) ? $0 : nil } ?? httpPort
            username = json["username"].text ?? username
            self.password = password
            localEvents = json["localEvents"]?.boolValue ?? localEvents
            motionTimeout = min(max(json["motionTimeout"].lenientInt ?? defaults.motionTimeout ?? motionTimeout, 1), 3600)
            privacySwitch = json["privacySwitch"]?.boolValue ?? privacySwitch
            lightSwitch = json["lightSwitch"]?.boolValue ?? lightSwitch
            sirenSwitch = json["sirenSwitch"]?.boolValue ?? sirenSwitch
            motionDetectSwitch = json["motionDetectSwitch"]?.boolValue ?? motionDetectSwitch
            recording = json["recording"]?.boolValue ?? recording
            encoder = json["encoder"].text ?? defaults.encoder
            personDetectSwitch = json["personDetectSwitch"]?.boolValue ?? personDetectSwitch
            statusLightSwitch = json["statusLightSwitch"]?.boolValue ?? statusLightSwitch
            linkageSirenSwitch = json["linkageSirenSwitch"]?.boolValue ?? linkageSirenSwitch
            linkageLightSwitch = json["linkageLightSwitch"]?.boolValue ?? linkageLightSwitch
            nightVisionSwitch = json["nightVisionSwitch"]?.boolValue ?? nightVisionSwitch
            presetSwitches = json["presetSwitches"]?.boolValue ?? presetSwitches
            // A boolean turns it on or off, as the spec's "twoWayAudio boolean" reads.
            if let flag = json["twoWayAudio"]?.boolValue { twoWayAudio = flag ? .on : .off } else {
                twoWayAudio = json["twoWayAudio"].text.flatMap { TalkMode(rawValue: $0.lowercased()) } ?? twoWayAudio
            }
            talkCodec = json["talkCodec"].text.flatMap { text in [TalkCodec.g711A, .g711Mu, .aac].first { $0.rawValue.lowercased() == text.lowercased() } } ?? talkCodec
            talkMethod = json["talkMethod"].text.flatMap { TalkMethod(rawValue: $0.lowercased()) } ?? talkMethod
            talkZeroTimestamps = json["talkZeroTimestamps"]?.boolValue ?? talkZeroTimestamps
        }

        /// Video and snapshots can go local: an address and a password.
        var isLocal: Bool { host != nil && password != nil }
    }
}

/// What the vault keeps for the account (Setup's App Secret) and for a camera (its safety code; none for a camera set up
/// for the cloud only).
struct ImouAccountCredentials: Codable, Sendable {
    var appSecret: String
}

struct ImouCameraCredentials: Codable, Sendable {
    var password: String?
}

extension Optional where Wrapped == JSONValue {
    /// A non-empty string, trimmed (a number written as one too).
    var text: String? {
        switch self {
        case .string(let value)?:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .number(let value)?: return Int(saturating: value).map(String.init)
        default: return nil
        }
    }

    /// An integer from a number or a numeric string.
    var lenientInt: Int? {
        switch self {
        case .number(let value)?: Int(saturating: value)
        case .string(let value)?: Double(value.trimmingCharacters(in: .whitespaces)).flatMap { Int(saturating: $0) }
        default: nil
        }
    }

    var lenientDouble: Double? {
        switch self {
        case .number(let value)?: value.finite
        case .string(let value)?: Double(value.trimmingCharacters(in: .whitespaces))?.finite
        default: nil
        }
    }
}
