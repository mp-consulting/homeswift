import Foundation

extension UniFiProtectPlugin {
    /// The `UniFi Protect` platform block of `homebridge-unifi-protect`, key for key. Decoding is lenient as
    /// Homebridge was: numbers and booleans may come as strings, missing arrays are empty, and a key of the
    /// wrong type is ignored rather than failing the block.
    public struct Configuration: Decodable, Sendable {
        public var name: String?
        public var controllers: [Controller]
        /// `debug` in config.json: debug lines are logged at the info level.
        public var debug: Bool
        /// Feature options: `Enable.<Option>[.<scope id>][.<value>]` and `Disable.…`.
        public var options: [String]
        /// Seconds during which further rings of a doorbell are ignored.
        public var ringDelay: Int
        public var verboseFfmpeg: Bool
        /// The FFmpeg executable; the first `ffmpeg` on the PATH otherwise.
        public var videoProcessor: String?

        public struct Controller: Decodable, Sendable, Equatable {
            public var address: String
            public var username: String
            public var password: String
            public var name: String?
            public var cameraOverrides: [CameraOverride]
            public var doorbellMessages: [DoorbellMessage]
            /// The MQTT base topic: `unifi/protect` by default.
            public var mqttTopic: String
            public var mqttUrl: String?
            public var mqttVerifyTls: Bool?
            public var overrideAddress: String?
            public var playlistAddress: String?
            public var playlistToken: String?
            public var verifyTls: Bool?

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                address = container.lenientString(.address)?.trimmingCharacters(in: .whitespaces) ?? ""
                username = container.lenientString(.username) ?? ""
                password = container.lenientString(.password) ?? ""
                name = container.lenientString(.name)?.nonEmpty
                cameraOverrides = (try? container.decode([Lenient<CameraOverride>].self, forKey: .cameraOverrides))?.compactMap(\.value) ?? []
                doorbellMessages = (try? container.decode([Lenient<DoorbellMessage>].self, forKey: .doorbellMessages))?.compactMap(\.value) ?? []
                mqttTopic = container.lenientString(.mqttTopic)?.nonEmpty ?? ProtectSettings.mqttTopic
                mqttUrl = container.lenientString(.mqttUrl)?.trimmingCharacters(in: .whitespaces).nonEmpty
                mqttVerifyTls = container.lenientBool(.mqttVerifyTls)
                overrideAddress = container.lenientString(.overrideAddress)?.trimmingCharacters(in: .whitespaces).nonEmpty
                playlistAddress = container.lenientString(.playlistAddress)
                playlistToken = container.lenientString(.playlistToken)
                verifyTls = container.lenientBool(.verifyTls)
            }

            init(address: String, username: String, password: String) {
                self.address = address
                self.username = username
                self.password = password
                cameraOverrides = []
                doorbellMessages = []
                mqttTopic = ProtectSettings.mqttTopic
            }

            enum Key: String, CodingKey {
                case address, username, password, name, cameraOverrides, doorbellMessages, mqttTopic, mqttUrl, mqttVerifyTls, overrideAddress
                case playlistAddress, playlistToken, verifyTls
            }
        }

        /// Per-camera URLs for ONVIF and other third-party cameras adopted into Protect, whose streams the
        /// controller often does not relay. The ONVIF fields are the web page's memory; only the URLs are used.
        public struct CameraOverride: Decodable, Sendable, Equatable {
            public var mac: String
            public var rtspUrl: String?
            public var snapshotUrl: String?
            public var onvifPort: Int?
            public var onvifUsername: String?
            public var onvifPassword: String?
            public var onvifServicePath: String?

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                guard let mac = container.lenientString(.mac) else {
                    throw DecodingError.keyNotFound(Key.mac, .init(codingPath: decoder.codingPath, debugDescription: "a camera override needs a mac"))
                }
                self.mac = mac
                rtspUrl = container.lenientString(.rtspUrl)
                snapshotUrl = container.lenientString(.snapshotUrl)
                onvifPort = container.lenientInt(.onvifPort)
                onvifUsername = container.lenientString(.onvifUsername)
                onvifPassword = container.lenientString(.onvifPassword)
                onvifServicePath = container.lenientString(.onvifServicePath)
            }

            init(mac: String, rtspUrl: String? = nil, snapshotUrl: String? = nil) {
                self.mac = mac
                self.rtspUrl = rtspUrl
                self.snapshotUrl = snapshotUrl
            }

            enum Key: String, CodingKey {
                case mac, rtspUrl, snapshotUrl, onvifPort, onvifUsername, onvifPassword, onvifServicePath
            }
        }

        /// A message preset for the doorbells of a controller.
        public struct DoorbellMessage: Decodable, Sendable, Equatable {
            /// Seconds the message shows; 0 shows it until changed. Absent or negative: the default.
            public var duration: Double?
            public var message: String

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                message = container.lenientString(.message) ?? ""
                duration = container.lenientDouble(.duration)
            }

            init(message: String, duration: Double?) {
                self.message = message
                self.duration = duration
            }

            enum Key: String, CodingKey { case duration, message }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: Key.self)
            name = container.lenientString(.name)
            controllers = (try? container.decode([Lenient<Controller>].self, forKey: .controllers))?.compactMap(\.value) ?? []
            debug = container.lenientBool(.debug) ?? false
            options = (try? container.decode([Lenient<String>].self, forKey: .options))?.compactMap(\.value) ?? []
            ringDelay = max(0, container.lenientInt(.ringDelay) ?? 0)
            verboseFfmpeg = container.lenientBool(.verboseFfmpeg) ?? false
            videoProcessor = container.lenientString(.videoProcessor)?.trimmingCharacters(in: .whitespaces).nonEmpty
        }

        init(controllers: [Controller], options: [String] = [], ringDelay: Int = 0) {
            self.controllers = controllers
            self.options = options
            self.ringDelay = ringDelay
            debug = false
            verboseFfmpeg = false
        }

        enum Key: String, CodingKey {
            case name, controllers, debug, options, ringDelay, verboseFfmpeg, videoProcessor
        }
    }
}

extension UniFiProtectPlugin.Configuration.Controller {
    /// The override for a camera, matched by MAC whatever its case and separators (`findCameraOverride`).
    func cameraOverride(mac: String) -> UniFiProtectPlugin.Configuration.CameraOverride? {
        guard !mac.isEmpty else { return nil }
        let target = normalizeMAC(mac)
        return cameraOverrides.first { normalizeMAC($0.mac) == target }
    }
}

/// An element that decodes when it can and is skipped otherwise.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    func lenientString(_ key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decode(Double.self, forKey: key) { return value }
        if let text = try? decode(String.self, forKey: key) { return Double(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        lenientDouble(key).flatMap { $0.isFinite ? Int($0) : nil }
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) { return value }
        if let text = try? decode(String.self, forKey: key) {
            switch text.lowercased().trimmingCharacters(in: .whitespaces) {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off", "": return false
            default: return nil
            }
        }
        if let number = try? decode(Double.self, forKey: key) { return number != 0 }
        return nil
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
