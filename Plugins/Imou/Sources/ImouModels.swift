import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

// The cloud's devices, abilities, switches and alarms (docs/clean-room/Imou.md, sections 1, 4 and 5), read leniently: a
// device or a cloud sends any shape, so every field is optional and bounded.

/// A camera device of the account (`listDeviceDetailsByPage`), with its channels.
struct ImouDevice: Sendable, Equatable {
    var deviceID: String
    var name: String
    var model: String
    var firmware: String?
    var abilities: Set<String>
    var channelCount: Int
    var multiFlag: Bool
    /// IoT devices (plugs, bulbs, sensors) have one: out of scope (section 1.1).
    var productID: String?
    var channels: [ImouChannel]

    /// An IPC: one lens, or a multi-lens camera (section 1.1).
    var isIPC: Bool { channelCount == 1 || multiFlag }

    /// The channels to make accessories of: those listed, or channel "0" for a device without.
    var cameraChannels: [ImouChannel] {
        channels.isEmpty ? [ImouChannel(id: "0", name: name, abilities: [])] : channels
    }

    /// A channel's abilities (section 1.3): its own, and the device's for channel "0" of an IPC; the device's for a device
    /// without channels.
    func abilities(of channel: ImouChannel) -> Set<String> {
        if channels.isEmpty { return abilities }
        return channel.id == "0" && isIPC ? channel.abilities.union(abilities) : channel.abilities
    }

    init(deviceID: String, name: String, model: String = "unknown", firmware: String? = nil, abilities: Set<String> = [], channelCount: Int = 1,
         multiFlag: Bool = false, productID: String? = nil, channels: [ImouChannel] = []) {
        self.deviceID = deviceID
        self.name = name
        self.model = model
        self.firmware = firmware
        self.abilities = abilities
        self.channelCount = channelCount
        self.multiFlag = multiFlag
        self.productID = productID
        self.channels = channels
    }

    init?(json: JSONValue) {
        guard let id = json["deviceId"]?.stringValue?.trimmingCharacters(in: .whitespaces), !id.isEmpty, id.count <= 128 else { return nil }
        deviceID = id
        name = json["deviceName"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) } ?? id
        model = json["deviceModel"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? "unknown"
        firmware = json["deviceVersion"]?.stringValue.map { String($0.prefix(64)) }
        abilities = Self.abilities(json["deviceAbility"])
        channelCount = json["channelNum"]?.saturatingIntValue(in: 0...256) ?? 1
        multiFlag = json["multiFlag"]?.boolValue ?? false
        productID = json["productId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        channels = (json["channelList"]?.arrayValue ?? []).prefix(64).compactMap { ImouChannel(json: $0, device: id) }
    }

    /// A comma-separated ability string; `null` or `""` is none.
    static func abilities(_ value: JSONValue?) -> Set<String> {
        guard let text = value?.stringValue else { return [] }
        return Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(256))
    }
}

struct ImouChannel: Sendable, Equatable {
    /// A string, as the cloud wants it back: "0" for the first.
    var id: String
    var name: String
    var abilities: Set<String>

    init(id: String, name: String, abilities: Set<String>) {
        self.id = id
        self.name = name
        self.abilities = abilities
    }

    init?(json: JSONValue, device: String) {
        guard let id = json["channelId"].text, id.count <= 8 else { return nil }
        self.id = id
        name = json["channelName"]?.stringValue.flatMap { $0.isEmpty ? nil : String($0.prefix(128)) } ?? "\(device)-\((Int(id) ?? 0) + 1)"
        abilities = ImouDevice.abilities(json["channelAbility"])
    }

    /// The RTSP and CGI channel: the cloud's `channelId` plus one.
    var localChannel: Int { (Int(id) ?? 0) + 1 }
}

/// What `deviceOnline` says of a device or a channel (section 4.3).
enum ImouOnline: Sendable, Equatable {
    case online, offline, upgrading, sleeping

    init(_ value: String?) {
        switch value {
        case "1": self = .online
        case "3": self = .upgrading
        case "4": self = .sleeping
        default: self = .offline
        }
    }
}

/// What a channel offers, from its abilities (section 1.3, [O]'s table).
struct ImouFeatures: Sendable, Equatable {
    var motionDetectSwitch: Bool
    var privacy: Bool
    var whiteLight: Bool
    var siren: Bool
    var battery: Bool
    var doorbell: Bool

    init(abilities: Set<String>) {
        motionDetectSwitch = abilities.contains("MobileDetect") || abilities.contains("AlarmMD")
        privacy = abilities.contains("CloseCamera")
        whiteLight = abilities.contains("WhiteLight") || abilities.contains("ChnWhiteLight")
        siren = abilities.contains("Siren")
        battery = abilities.contains("Electric")
        doorbell = abilities.contains("CallAbility")
    }
}

/// The newest alarm of a camera (`getAlarmMessage`, section 4.6).
struct ImouAlarm: Sendable, Equatable {
    var id: String
    var messageType: String
    var time: Int
}

/// Event and message types (sections 5.2 and 5.3).
enum ImouEvents {
    /// Cloud `msgType`s that are motion, compared lowercased without a leading `e_`.
    static let motionMessages: Set<String> = [
        "videomotion", "human", "mobiledetect", "motiondetect", "alarmpir", "pir_alarm", "aiperarea", "aiperareaalarm", "multivideoaiperarea",
        "multivideoaiperareaalarm", "smartmixdetect", "crosslinedetection", "areadetect", "areadetectalarm", "multivideoareadetect",
        "multivideodetectalarm",
    ]
    static let doorbellMessages: Set<String> = ["callbellevent", "callevent", "callquickevent", "callsupplyevent", "calleventcall", "309100", "309200", "311000"]

    static func normalized(_ type: String) -> String {
        let lower = type.lowercased()
        return lower.hasPrefix("e_") ? String(lower.dropFirst(2)) : lower
    }

    /// The Dahua event codes asked of a camera's event stream, and those that are motion.
    static let localCodes = ["VideoMotion", "SmartMotionHuman", "SmartMotionVehicle", "CrossLineDetection", "CrossRegionDetection", "AlarmLocal"]
    static let localMotionCodes = Set(localCodes)
    static let localDoorbellCodes: Set<String> = ["CallNoAnswered", "BackKeyLight"]
}

// MARK: The methods

extension ImouCloud {
    /// Pages through `listDeviceDetailsByPage` while a page is full (section 4.2), 50 pages at most.
    func listDevices(pageSize: Int = 10) async throws -> [ImouDevice] {
        var devices: [ImouDevice] = []
        for page in 1...50 {
            let data = try await call("listDeviceDetailsByPage", ["page": .number(Double(page)), "pageSize": .number(Double(pageSize))])
            let list = data["deviceList"]?.arrayValue ?? []
            devices += list.compactMap(ImouDevice.init(json:))
            if list.count < pageSize { break }
        }
        return devices
    }

    /// `deviceOnline`: the device's state, and each channel's.
    func online(_ deviceID: String, polling: Bool = false) async throws -> (device: ImouOnline, channels: [String: ImouOnline]) {
        let data = try await call("deviceOnline", ["deviceId": .string(deviceID)], polling: polling)
        var channels: [String: ImouOnline] = [:]
        for channel in (data["channels"]?.arrayValue ?? []).prefix(64) {
            guard let id = channel["channelId"].text else { continue }
            channels[id] = ImouOnline(channel["onLine"].text)
        }
        return (ImouOnline(data["onLine"].text), channels)
    }

    /// `getDeviceCameraStatus`: on or off; nil for a status it does not say.
    func cameraStatus(_ deviceID: String, channel: String, _ enableType: String, polling: Bool = false) async throws -> Bool? {
        let data = try await call("getDeviceCameraStatus", ["deviceId": .string(deviceID), "channelId": .string(channel), "enableType": .string(enableType)],
                                  polling: polling)
        return Self.status(data["status"])
    }

    /// `"on"`/`"off"`, `1`/`0`, `"1"`/`"0"` or a boolean (section 4.4).
    static func status(_ value: JSONValue?) -> Bool? {
        switch value {
        case .bool(let on)?: on
        case .number(let number)?: number == 1 ? true : number == 0 ? false : nil
        case .string(let text)?:
            switch text.lowercased() {
            case "on", "1", "true": true
            case "off", "0", "false": false
            default: nil
            }
        default: nil
        }
    }

    func setCameraStatus(_ deviceID: String, channel: String, _ enableType: String, _ enable: Bool) async throws {
        _ = try await call("setDeviceCameraStatus", ["deviceId": .string(deviceID), "channelId": .string(channel), "enableType": .string(enableType),
                                                     "enable": .bool(enable)])
    }

    /// The camera's own motion detection (section 4.5): `modifyDeviceAlarmStatus`, else `setDeviceCameraStatus`
    /// `motionDetect` on an error other than the account's.
    func setMotionDetection(_ deviceID: String, channel: String, _ enable: Bool) async throws {
        do {
            _ = try await call("modifyDeviceAlarmStatus", ["deviceId": .string(deviceID), "channelId": .string(channel), "enable": .bool(enable)])
        } catch let error as ImouError where !error.isAuthRefused && error.code != nil && error.code != "TK1002" && !error.isDormant {
            try await setCameraStatus(deviceID, channel: channel, "motionDetect", enable)
        }
    }

    /// `sirenStart`/`sirenStop` (section 4.9), with the channel for a channel of a multi-channel device; the `siren` switch
    /// when the method is refused.
    func siren(_ deviceID: String, channel: String, multiChannel: Bool, _ on: Bool) async throws {
        var params: [String: JSONValue] = ["deviceId": .string(deviceID)]
        if multiChannel { params["channels"] = [.number(Double(Int(channel) ?? 0))] }
        do {
            _ = try await call(on ? "sirenStart" : "sirenStop", params)
        } catch let error as ImouError where !error.isAuthRefused && error.code != nil && error.code != "TK1002" && !error.isDormant {
            try await setCameraStatus(deviceID, channel: channel, "siren", on)
        }
    }

    /// `getAlarmMessage`'s newest alarm, from a day ago to a day ahead (local time).
    func latestAlarm(_ deviceID: String, channel: String, now: Date) async throws -> ImouAlarm? {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let data = try await call("getAlarmMessage", [
            "deviceId": .string(deviceID), "channelId": .string(channel), "count": "10",
            "beginTime": .string(format.string(from: now.addingTimeInterval(-86_400))), "endTime": .string(format.string(from: now.addingTimeInterval(86_400))),
        ], polling: true)
        guard let alarm = data["alarms"]?[0] else { return nil }
        let id = alarm["alarmId"].text ?? ""
        let time = alarm["time"]?.saturatingIntValue ?? alarm["time"]?.stringValue.flatMap { Int($0) } ?? 0
        guard !id.isEmpty || time != 0 else { return nil }
        return ImouAlarm(id: id, messageType: alarm["msgType"]?.stringValue ?? "", time: time)
    }

    /// `setDeviceSnapEnhanced`: where the picture will be, once the camera has uploaded it (section 4.7).
    func snapshotURL(_ deviceID: String, channel: String) async throws -> URL {
        let data = try await call("setDeviceSnapEnhanced", ["deviceId": .string(deviceID), "channelId": .string(channel)])
        guard let text = data["url"]?.stringValue, let url = URL(string: text), url.scheme?.lowercased() == "https" else {
            throw ImouError.malformed("no snapshot address")
        }
        return url
    }

    /// `getStreamUrl`: a short-lived cloud RTSP URL (section 4.8); `streamID` 0 is HD, 1 SD.
    func streamURL(_ deviceID: String, channel: String, streamID: Int) async throws -> String {
        let data = try await call("getStreamUrl", ["deviceId": .string(deviceID), "channelId": .string(channel), "streamId": .number(Double(streamID))])
        guard let url = data["url"]?.stringValue, url.lowercased().hasPrefix("rtsp") else { throw ImouError.malformed("no stream address") }
        return url
    }

    func wakeUp(_ deviceID: String) async throws {
        _ = try await call("wakeUpDevice", ["deviceId": .string(deviceID), "url": "/device/wakeup"])
    }

    /// `getDevicePowerInfo`'s battery level in percent: `litElec`, else `alkElec`, else `electric` (section 4.10).
    func batteryLevel(_ deviceID: String) async throws -> Int? {
        let data = try await call("getDevicePowerInfo", ["deviceId": .string(deviceID)], polling: true)
        guard let entry = data["electricitys"]?.arrayValue?.first(where: { $0["type"]?.stringValue == "battery" }) ?? data["electricitys"]?[0] else { return nil }
        for key in ["litElec", "alkElec", "electric"] {
            if let value = entry[key]?.stringValue.flatMap(Double.init) ?? entry[key]?.doubleValue, let level = Int(saturating: value, in: 0...100) { return level }
        }
        return nil
    }
}
