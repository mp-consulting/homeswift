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

/// What a channel offers, from its abilities (section 1.3, [O]'s table; addendum, section 2). A versioned ability
/// (`AlarmPIRV2`) also counts as its name without the version.
struct ImouFeatures: Sendable, Equatable {
    var motionDetectSwitch: Bool
    var privacy: Bool
    var whiteLight: Bool
    var siren: Bool
    var battery: Bool
    var doorbell: Bool
    /// Human detection's enableTypes, one per ability that has one (addendum, section 2.2).
    var humanDetection: [String]
    var statusLight: Bool
    var linkageSiren: Bool
    var linkageLight: Bool
    var nightVision: Bool
    var ptz: ImouPTZ?
    var presets: Bool
    var reboot: Bool
    var storage: Bool

    init(abilities given: Set<String>) {
        var abilities = given
        for ability in given {
            if let last = ability.last, last.isNumber, ability.dropLast().hasSuffix("V") { abilities.insert(String(ability.dropLast(2))) }
        }
        motionDetectSwitch = abilities.contains("MobileDetect") || abilities.contains("AlarmMD")
        privacy = abilities.contains("CloseCamera")
        whiteLight = abilities.contains("WhiteLight") || abilities.contains("ChnWhiteLight")
        siren = abilities.contains("Siren")
        battery = abilities.contains("Electric")
        doorbell = abilities.contains("CallAbility")
        humanDetection = [("HeaderDetect", "headerDetect"), ("AiHuman", "aiHuman")].filter { abilities.contains($0.0) }.map(\.1)
            + (abilities.contains("SMDH") || abilities.contains("SmdHuman") ? ["smdHuman"] : [])
        statusLight = abilities.contains("BreathingLight")
        linkageSiren = abilities.contains("LinkageSiren")
        linkageLight = whiteLight || abilities.contains("LinkageWhiteLight")
        nightVision = abilities.contains("NVM")
        ptz = abilities.contains("PTZ") ? .full : abilities.contains("PT") || abilities.contains("PT1") ? .fourWay : abilities.contains("PT2") ? .pan : nil
        presets = abilities.contains("CollectionPoint")
        reboot = abilities.contains("Reboot")
        storage = abilities.contains("LocalStorage") || abilities.contains("LocalStorageEnable")
    }
}

/// What a camera's pan and tilt can do (addendum, section 1.1): `PTZ` all of it, `PT`/`PT1` four directions and their
/// diagonals without zoom, `PT2` left and right.
enum ImouPTZ: String, Sendable, Equatable {
    case full = "PTZ", fourWay = "PT", pan = "PT2"

    func allows(_ move: ImouPTZMove) -> Bool {
        switch self {
        case .full: true
        case .fourWay: move != .zoomIn && move != .zoomOut
        case .pan: [.left, .right, .stop].contains(move)
        }
    }
}

/// `controlMovePTZ`'s operations, by their code.
enum ImouPTZMove: Int, CaseIterable, Sendable {
    case up = 0, down, left, right, upLeft, downLeft, upRight, downRight, zoomIn, zoomOut, stop

    var name: String { "\(self)" }
    init?(name: String) {
        guard let move = Self.allCases.first(where: { $0.name.lowercased() == name.lowercased() }) else { return nil }
        self = move
    }
}

/// A HomeKit switch backed by one or more enableTypes of `getDeviceCameraStatus` (addendum, section 2): on when any reads
/// on, off only when all answered off; a write goes to each, and fails only when all fail. A device-level one is read and
/// written without a `channelId`.
struct ImouSwitch: Sendable, Equatable {
    var subtype: String
    var label: String
    var enableTypes: [String]
    var deviceLevel = false

    static let statusLight = ImouSwitch(subtype: "statusLight", label: "Status Light", enableTypes: ["breathingLight"], deviceLevel: true)
    /// On when either reads on; off only when both answered off (section 4.4).
    static let motionDetection = ImouSwitch(subtype: "motionDetection", label: "Motion Detection", enableTypes: ["mobileDetect", "motionDetect"])
}

/// What `deviceSdcardStatus` and `deviceStorage` say (addendum, section 4.1).
struct ImouStorage: Sendable, Equatable {
    /// `none`, `normal`, `abnormal` or `recovering` (formatting); another word as the cloud wrote it.
    var status: String
    var usedPercent: Int?

    var json: JSONValue { ["status": .string(status), "usedPercent": usedPercent.map { .number(Double($0)) } ?? .null] }
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

    /// `getDeviceCameraStatus`: on or off; nil for a status it does not say. A device-level switch (no channel) goes without
    /// `channelId`, and once more with `"0"` if the cloud wants one (addendum, section 2.1).
    func cameraStatus(_ deviceID: String, channel: String?, _ enableType: String, polling: Bool = false) async throws -> Bool? {
        let data = try await scoped("getDeviceCameraStatus", ["deviceId": .string(deviceID), "enableType": .string(enableType)], channel: channel, polling: polling)
        return Self.status(data["status"])
    }

    private func deviceID(_ params: [String: JSONValue]) -> String { params["deviceId"]?.stringValue ?? "" }

    /// A call with `channelId`, or without one for a device-level call, retried with `"0"` on `OP1003`.
    private func scoped(_ method: String, _ params: [String: JSONValue], channel: String?, polling: Bool = false) async throws -> JSONValue {
        var params = params
        if let channel {
            params["channelId"] = .string(channel)
            return try await call(method, params, polling: polling)
        }
        if devicesWantingChannel.contains(deviceID(params)) {
            params["channelId"] = "0"
            return try await call(method, params, polling: polling)
        }
        do {
            return try await call(method, params, polling: polling)
        } catch let error as ImouError where error.code == "OP1003" {
            params["channelId"] = "0"
            let data = try await call(method, params, polling: polling)
            // Remembered: one call, not two, from then on.
            wantsChannel(deviceID(params))
            return data
        }
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

    func setCameraStatus(_ deviceID: String, channel: String?, _ enableType: String, _ enable: Bool) async throws {
        _ = try await scoped("setDeviceCameraStatus", ["deviceId": .string(deviceID), "enableType": .string(enableType), "enable": .bool(enable)], channel: channel)
    }

    /// The legacy `breathingLightStatus`, for a camera that does not answer the `breathingLight` enableType (addendum, 2.4).
    func breathingLightStatus(_ deviceID: String) async throws -> Bool? {
        Self.status(try await call("breathingLightStatus", ["deviceId": .string(deviceID)], polling: true)["status"])
    }

    /// `getNightVisionMode`: the mode, and those the camera has (addendum, section 2.6).
    func nightVision(_ deviceID: String, channel: String) async throws -> (mode: String?, modes: [String]) {
        let data = try await call("getNightVisionMode", ["deviceId": .string(deviceID), "channelId": .string(channel)], polling: true)
        let modes = (data["modes"]?.arrayValue ?? []).prefix(16).compactMap { $0.stringValue.map { String($0.prefix(32)) } }
        return (data["mode"]?.stringValue.map { String($0.prefix(32)) }, modes)
    }

    func setNightVision(_ deviceID: String, channel: String, mode: String) async throws {
        _ = try await call("setNightVisionMode", ["deviceId": .string(deviceID), "channelId": .string(channel), "mode": .string(mode)])
    }

    /// `controlMovePTZ` for `duration` milliseconds (addendum, section 1.1): `operation` as a string, as the documentation's
    /// sample sends it, and once as a number when the cloud refuses that (`OP1003`), remembered.
    func movePTZ(_ deviceID: String, channel: String, _ move: ImouPTZMove, milliseconds: Int) async throws {
        func send(asNumber: Bool) async throws {
            _ = try await call("controlMovePTZ", [
                "deviceId": .string(deviceID), "channelId": .string(channel),
                "operation": asNumber ? .number(Double(move.rawValue)) : .string(String(move.rawValue)), "duration": .number(Double(milliseconds)),
            ])
        }
        if ptzOperationAsNumber { return try await send(asNumber: true) }
        do {
            try await send(asNumber: false)
        } catch let error as ImouError where error.code == "OP1003" {
            try await send(asNumber: true)
            ptzTakesNumbers()
        }
    }

    /// `controlLocationPTZ`: `h` and `v` from -1 to 1, `z` from 0 (widest) to 1 (addendum, section 1.2).
    func locatePTZ(_ deviceID: String, channel: String, h: Double, v: Double, z: Double) async throws {
        _ = try await call("controlLocationPTZ", ["deviceId": .string(deviceID), "channelId": .string(channel), "h": .number(h), "v": .number(v), "z": .number(z)])
    }

    /// `getCollection`'s preset names. Its answer's shape is not documented (addendum, section 1.2): the names of a list of
    /// objects under any key of `data`, or strings, read leniently.
    func presets(_ deviceID: String, channel: String) async throws -> [String] {
        let data = try await call("getCollection", ["deviceId": .string(deviceID), "channelId": .string(channel)])
        let lists = data.arrayValue.map { [$0] } ?? (data.objectValue ?? [:]).sorted { $0.key < $1.key }.compactMap(\.value.arrayValue)
        var names: [String] = []
        for item in lists.joined().prefix(64) {
            guard let name = (item.stringValue ?? item["name"]?.stringValue ?? item["collectionName"]?.stringValue)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.count <= 64, !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    func goToPreset(_ deviceID: String, channel: String, name: String) async throws {
        _ = try await call("turnCollection", ["deviceId": .string(deviceID), "channelId": .string(channel), "name": .string(name)])
    }

    /// `deviceSdcardStatus`, then `deviceStorage` for a card that is `normal` (addendum, section 4.1).
    func storage(_ deviceID: String) async throws -> ImouStorage {
        let text = try await call("deviceSdcardStatus", ["deviceId": .string(deviceID)], polling: true)["status"]?.stringValue ?? ""
        var storage = ImouStorage(status: text.isEmpty ? "none" : String(text.prefix(32)))
        guard text == "normal" else { return storage }
        let data = try await call("deviceStorage", ["deviceId": .string(deviceID)], polling: true)
        if let total = data["totalBytes"]?.doubleValue, total > 0, let used = data["usedBytes"]?.doubleValue, used >= 0 {
            storage.usedPercent = Int(saturating: (used * 100 / total).rounded(.down), in: 0...100)
        }
        return storage
    }

    func restart(_ deviceID: String) async throws {
        _ = try await call("restartDevice", ["deviceId": .string(deviceID)])
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
