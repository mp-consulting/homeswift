import Crypto
import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import _CryptoExtras

// SwitchBot over Bluetooth LE, the bytes (docs/clean-room/SwitchBotBLE.md): the advertisements of §2–§3, the GATT
// frames of §4–§5, the encryption of §7. Nothing here reaches a radio; SwitchBotBluetooth.swift does.

/// The products the spec pins, by their advertised model code (§2.3): each has two codes, both the same product.
enum BLEModel: String, Sendable, CaseIterable {
    case bot, curtain, curtain3, meter, meterPlus, outdoorMeter, meterPro, meterProCO2, contact, motion, plugMiniUS, plugMiniJP
    case lock, lockPro, blindTilt, colorBulb, stripLight

    /// The model of service data byte 0 (bits 6–0); nil for a code the spec does not use (Hub 2 among them).
    init?(code: UInt8) {
        switch code & 0x7F {
        case 0x48: self = .bot
        case 0x63, 0x43: self = .curtain
        case 0x7B, 0x5B: self = .curtain3
        case 0x54, 0x74: self = .meter
        case 0x69, 0x49: self = .meterPlus
        case 0x77, 0x57: self = .outdoorMeter
        case 0x34, 0x14: self = .meterPro
        case 0x35, 0x15: self = .meterProCO2
        case 0x64, 0x44: self = .contact
        case 0x73, 0x53: self = .motion
        case 0x67, 0x47: self = .plugMiniUS
        case 0x6A, 0x4A: self = .plugMiniJP
        // The Lock Lite advertises as a Smart Lock with codes of its own.
        case 0x6F, 0x4F, 0x2D, 0x0D: self = .lock
        case 0x24, 0x04: self = .lockPro
        case 0x78, 0x58: self = .blindTilt
        case 0x75, 0x55: self = .colorBulb
        case 0x72, 0x52: self = .stripLight
        default: return nil
        }
    }

    /// The model an OpenAPI `deviceType` is over Bluetooth; nil for a type that stays on the cloud (§10).
    init?(deviceType: String) {
        switch deviceType {
        case "Bot": self = .bot
        case "Curtain": self = .curtain
        case "Curtain3": self = .curtain3
        case "Meter": self = .meter
        case "MeterPlus", "Meter Plus (JP)": self = .meterPlus
        case "WoIOSensor": self = .outdoorMeter
        case "Meter Pro": self = .meterPro
        case "MeterPro(CO2)": self = .meterProCO2
        case "Contact Sensor": self = .contact
        case "Motion Sensor": self = .motion
        case "Plug Mini (US)": self = .plugMiniUS
        case "Plug Mini (JP)": self = .plugMiniJP
        case "Smart Lock": self = .lock
        case "Smart Lock Pro": self = .lockPro
        case "Blind Tilt": self = .blindTilt
        case "Color Bulb": self = .colorBulb
        case "Strip Light": self = .stripLight
        default: return nil
        }
    }

    var family: Family {
        switch self {
        case .bot: .bot
        case .curtain, .curtain3: .curtain
        case .meter, .meterPlus, .outdoorMeter, .meterPro, .meterProCO2: .meter
        case .contact: .contact
        case .motion: .motion
        case .plugMiniUS, .plugMiniJP: .plug
        case .lock, .lockPro: .lock
        case .blindTilt: .blindTilt
        case .colorBulb, .stripLight: .light
        }
    }

    /// Only advertisements: never connected to (§6).
    var isPassive: Bool { family == .meter || family == .contact || family == .motion }

    /// A connected status read the spec pins (§5.3, §5.4, §5.6).
    var hasRead: Bool { [.plugMiniUS, .plugMiniJP, .colorBulb, .stripLight, .lock, .lockPro].contains(self) }

    var isLock: Bool { self == .lock || self == .lockPro }
}

/// A Bluetooth address as 12 upper-case hex digits (the cloud's `deviceId`), from any spelling; nil when it is not one.
func bluetoothMAC(_ text: String) -> String? {
    let hex = text.uppercased().filter { $0.isHexDigit }
    let separators = text.filter { !$0.isHexDigit }
    guard hex.count == 12, separators.allSatisfy({ $0 == ":" || $0 == "-" || $0 == " " }) else { return nil }
    return hex
}

/// `AA:BB:CC:DD:EE:FF` of 12 hex digits.
func colonMAC(_ mac: String) -> String {
    stride(from: 0, to: mac.count, by: 2).map { String(Array(mac)[$0..<min($0 + 2, mac.count)]) }.joined(separator: ":")
}

/// What one advertisement says (§3), in the cloud's status keys so each accessory shows it as it shows a status:
/// `temperature`, `humidity`, `CO2`, `battery`, `power`, `slidePosition`, `moving`, `openState`, `moveDetected`,
/// `brightness`, `lockState`, `doorState`. Fields the cloud has no key for keep the spec's names.
struct BLEReading: Sendable, Equatable {
    var model: BLEModel
    /// 12 upper-case hex digits: the system's address (Linux), else the manufacturer data's (macOS hides addresses).
    var mac: String?
    /// Payload byte 6 of the types that have one: a change means a new state.
    var sequence: UInt8?
    var status: [String: JSONValue]
}

enum BLEAdvertisementDecoder {
    /// SwitchBot's company ids, little-endian on air: `0x0969`, and Nordic's `0x0059` before Bot 6.4, Curtain 4.6 and
    /// Meter 2.7 (§2.1).
    static func payload(_ manufacturerData: [UInt8]?) -> [UInt8]? {
        guard let data = manufacturerData, data.count >= 2 else { return nil }
        guard (data[0] == 0x69 && data[1] == 0x09) || (data[0] == 0x59 && data[1] == 0x00) else { return nil }
        return Array(data.dropFirst(2))
    }

    /// The service data of `0xFD3D` (or `0x000D` before those firmware versions), short or on the base UUID.
    static func serviceData(_ advertisement: BLEAdvertisement) -> [UInt8]? {
        for uuid in ["fd3d", "000d", "0000fd3d00001000800000805f9b34fb", "0000000d00001000800000805f9b34fb"] {
            if let data = advertisement.serviceData[uuid] { return data }
        }
        return nil
    }

    static func decode(_ advertisement: BLEAdvertisement) -> BLEReading? {
        guard let service = serviceData(advertisement) else { return nil }
        let payload = payload(advertisement.manufacturerData)
        var reading = decode(serviceData: service, payload: payload)
        if let address = advertisement.address.flatMap(bluetoothMAC) { reading?.mac = address }
        return reading
    }

    /// Decodes service data (UUID bytes off) and the manufacturer payload (company id off). Nil for a model the spec does
    /// not use or data too short for it.
    static func decode(serviceData sd: [UInt8], payload mp: [UInt8]?) -> BLEReading? {
        guard let first = sd.first, let model = BLEModel(code: first) else { return nil }
        let mac = mp.flatMap { $0.count >= 6 ? $0[0..<6].map { String(format: "%02X", $0) }.joined() : nil }
        var status: [String: JSONValue] = [:]
        var sequence: UInt8?
        if sd.count >= 3 { status["battery"] = .number(Double(sd[2] & 0x7F)) }
        func bit(_ byte: UInt8, _ n: Int) -> Bool { byte & (1 << n) != 0 }
        switch model {
        case .meter, .meterPlus, .outdoorMeter, .meterPro, .meterProCO2:
            let triple: ArraySlice<UInt8>? = mp.flatMap { $0.count >= 11 ? $0[8...10] : nil } ?? (sd.count >= 6 ? sd[3...5] : nil)
            if let triple, let (celsius, humidity, fahrenheit) = climate(Array(triple)) {
                status["temperature"] = .number(celsius)
                status["humidity"] = .number(Double(humidity))
                status["displayFahrenheit"] = .bool(fahrenheit)
            }
            if model == .meterProCO2, let mp, mp.count >= 15 {
                let ppm = Int(mp[13]) << 8 | Int(mp[14])
                if ppm <= 9999 { status["CO2"] = .number(Double(ppm)) }
            }
        case .contact:
            guard sd.count >= 9 else { return nil }
            var motion = bit(sd[1], 6), light = bit(sd[3], 0)
            let door = (sd[3] >> 1) & 0x03
            var openState = door == 0 ? "close" : door == 1 ? "open" : "timeOutNotClose"
            status["secondsSinceMotion"] = .number(Double(Int(sd[3] >> 7) << 16 | Int(sd[4]) << 8 | Int(sd[5])))
            status["secondsSinceDoorChange"] = .number(Double(Int((sd[3] >> 6) & 1) << 16 | Int(sd[6]) << 8 | Int(sd[7])))
            status["entranceCount"] = .number(Double(sd[8] >> 6))
            status["exitCount"] = .number(Double((sd[8] >> 4) & 0x03))
            status["buttonCount"] = .number(Double(sd[8] & 0x0F))
            // The manufacturer form, when there is one, is preferred (NS only); timed out counts as open.
            if let mp, mp.count >= 13 {
                motion = bit(mp[7], 7)
                light = bit(mp[7], 6)
                openState = bit(mp[7], 5) ? "timeOutNotClose" : bit(mp[7], 4) ? "open" : "close"
            }
            status["moveDetected"] = .bool(motion)
            status["brightness"] = .string(light ? "bright" : "dim")
            status["openState"] = .string(openState)
        case .motion:
            guard sd.count >= 6 || (mp?.count ?? 0) >= 8 else { return nil }
            var motion: Bool?, bright: Bool?
            if sd.count >= 6 {
                motion = bit(sd[1], 6)
                switch sd[5] & 0x03 {
                case 0x01: bright = false
                case 0x02: bright = true
                default: break
                }
            }
            if let mp, mp.count >= 8 {
                motion = bit(mp[7], 6)
                bright = bit(mp[7], 5)
            }
            if let motion { status["moveDetected"] = .bool(motion) }
            if let bright { status["brightness"] = .string(bright ? "bright" : "dim") }
        case .bot:
            guard sd.count >= 2 else { return nil }
            let switchMode = bit(sd[1], 7)
            status["switchMode"] = .bool(switchMode)
            // 0 on, 1 off (§9: the published docs over NS); press mode shows off.
            status["power"] = .string(switchMode && !bit(sd[1], 6) ? "on" : "off")
        case .curtain, .curtain3:
            guard sd.count >= 5 else { return nil }
            status["connectable"] = .bool(bit(sd[1], 7))
            status["calibrate"] = .bool(bit(sd[1], 6))
            status["moving"] = .bool(bit(sd[3], 7))
            status["slidePosition"] = .number(Double(min(Int(sd[3] & 0x7F), 100)))
            status["lightLevel"] = .number(Double(sd[4] >> 4))
            status["chainLength"] = .number(Double(sd[4] & 0x0F))
        case .plugMiniUS, .plugMiniJP:
            guard let mp, mp.count >= 12 else { return nil }
            sequence = mp[6]
            status["power"] = .string(bit(mp[7], 7) ? "on" : "off")
            status["delay"] = .bool(bit(mp[8], 0))
            status["timer"] = .bool(bit(mp[8], 1))
            status["syncUTCTime"] = .bool(bit(mp[8], 2))
            status["overload"] = .bool(bit(mp[10], 7))
            // The load's unit is stated by no source: kept raw, never shown as watts (§3.6).
            status["loadRaw"] = .number(Double(Int(mp[10] & 0x7F) << 8 | Int(mp[11])))
        case .lock:
            // Only the sequence number is trusted: the Lock page's offsets are ambiguous (§3.7), so the state comes from the
            // connected lock info read this change triggers.
            guard let mp, mp.count >= 7 else { return nil }
            sequence = mp[6]
        case .lockPro:
            guard let mp, mp.count >= 12 else { return nil }
            sequence = mp[6]
            let calibrated = bit(mp[7], 7)
            status["calibrate"] = .bool(calibrated)
            status["lockState"] = .string(lockState(calibrated: calibrated, status: Int((mp[7] >> 3) & 0x0F)))
            status["doorState"] = .string(bit(mp[8], 4) ? "opened" : "closed")
            status["battery"] = .number(Double(mp[9] & 0x7F))
        case .blindTilt:
            guard let mp, mp.count >= 10 else { return nil }
            sequence = mp[6]
            let tilt = min(Int(mp[8] & 0x7F), 100)
            status["calibrate"] = .bool(bit(mp[7], 0))
            status["moving"] = .bool(bit(mp[8], 7))
            // The cloud's slidePosition is the same scale: 0 closed down, 50 open, 100 closed up (§3.8, §6.5).
            status["slidePosition"] = .number(Double(tilt))
            status["direction"] = .string(tilt < 50 ? "down" : "up")
            // Its range is not stated: not shown on the light sensor.
            status["lightLevelRaw"] = .number(Double(mp[9] >> 4))
        case .colorBulb, .stripLight:
            guard let mp, mp.count >= 9 else { return nil }
            sequence = mp[6]
            status["power"] = .string(bit(mp[7], 7) ? "on" : "off")
            status["brightness"] = .number(Double(mp[7] & 0x7F))
            status["mode"] = .number(Double(mp[8] & (model == .colorBulb ? 0x07 : 0x0F)))
        }
        return BLEReading(model: model, mac: mac, sequence: sequence, status: status)
    }

    /// Temperature (°C), humidity and the device's display unit from the three bytes of §3.3; nil for 0.0 °C and 0 %.
    static func climate(_ bytes: [UInt8]) -> (Double, Int, Bool)? {
        guard bytes.count == 3 else { return nil }
        let tenths = Int(bytes[0] & 0x0F), whole = Int(bytes[1] & 0x7F), humidity = Int(bytes[2] & 0x7F)
        guard tenths != 0 || whole != 0 || humidity != 0 else { return nil }
        let magnitude = (Double(whole * 10 + tenths) / 10)
        return (bytes[1] & 0x80 != 0 ? magnitude : -magnitude, humidity, bytes[2] & 0x80 != 0)
    }

    /// The lock status of §3.7 and §5.6 as a `lockState` (`unknown` while not calibrated).
    static func lockState(calibrated: Bool, status: Int) -> String {
        guard calibrated else { return "unknown" }
        switch status {
        case 0: return "locked"
        case 1, 6: return "unlocked"
        case 2: return "locking"
        case 3: return "unlocking"
        case 4, 5: return "jammed"
        default: return "unknown"
        }
    }

    /// A lock info read's bytes after the status (§5.6) as a status.
    static func lockInfo(_ info: [UInt8], pro: Bool) -> [String: JSONValue]? {
        guard let first = info.first else { return nil }
        let calibrated = first & 0x80 != 0
        var status: [String: JSONValue] = ["calibrate": .bool(calibrated)]
        if pro {
            status["lockState"] = .string(lockState(calibrated: calibrated, status: Int((first >> 3) & 0x0F)))
            if info.count >= 2 { status["doorState"] = .string(info[1] & 0x10 != 0 ? "opened" : "closed") }
        } else {
            status["lockState"] = .string(lockState(calibrated: calibrated, status: Int((first >> 4) & 0x07)))
            status["doorState"] = .string(first & 0x04 != 0 ? "opened" : "closed")
        }
        return status
    }

    /// A bulb's or strip's state reply, status byte included (§5.4).
    static func lightState(_ reply: [UInt8], bulb: Bool) -> [String: JSONValue]? {
        guard reply.count >= 6 else { return nil }
        var status: [String: JSONValue] = [
            "power": .string(reply[1] & 0x80 != 0 ? "on" : "off"), "brightness": .number(Double(reply[2])),
        ]
        let color = "\(reply[3]):\(reply[4]):\(reply[5])"
        if bulb, reply.count >= 11 {
            let kelvin = Int(reply[6]) << 8 | Int(reply[7])
            let mode = Int(reply[10])
            status["mode"] = .number(Double(mode))
            if mode == 1, kelvin > 0 { status["colorTemperature"] = .number(Double(kelvin)) }
            if mode == 2 { status["color"] = .string(color) }
        } else if !bulb {
            status["color"] = .string(color)
        }
        return status
    }
}

// MARK: Frames

/// The GATT service and its two characteristics (§4.1), as the shared central names them.
enum BLEGATT {
    static let service = "cba20d00224d11e69fb80002a5d5c51b"
    static let write = "cba20002224d11e69fb80002a5d5c51b"
    static let notify = "cba20003224d11e69fb80002a5d5c51b"
}

/// One request: its frames tried in turn until one is answered OK (the Blind Tilt's two firmware forms, §5.5), and
/// whether it must be encrypted.
struct BLERequest: Sendable, Equatable {
    var frames: [[UInt8]]
    var encrypted = false
    var name: String
}

/// A command Bluetooth cannot carry: the cloud takes it when it can.
struct BLEUnsupported: Error, CustomStringConvertible {
    var reason: String
    var description: String { reason }
}

enum BLEFrames {
    static func bot(action: UInt8, password: String?) -> [UInt8] {
        guard let password else { return [0x57, 0x01, action] }
        let crc = crc32(Array(password.utf8))
        return [0x57, 0x11, UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF), action]
    }

    static func curtain(position: Int, speed: UInt8 = 0xFF) -> [UInt8] {
        [0x57, 0x0F, 0x45, 0x01, 0x05, speed, UInt8(min(max(position, 0), 100))]
    }

    static let curtainPause: [UInt8] = [0x57, 0x0F, 0x45, 0x01, 0x00, 0xFF]

    static let plugOn: [UInt8] = [0x57, 0x0F, 0x50, 0x01, 0x01, 0x80]
    static let plugOff: [UInt8] = [0x57, 0x0F, 0x50, 0x01, 0x01, 0x00]
    static let plugRead: [UInt8] = [0x57, 0x0F, 0x51, 0x01]

    static func light(_ model: BLEModel, _ body: [UInt8]) -> [UInt8] { [0x57, 0x0F, model == .colorBulb ? 0x47 : 0x49, 0x01] + body }
    static func lightRead(_ model: BLEModel) -> [UInt8] { [0x57, 0x0F, model == .colorBulb ? 0x48 : 0x4A, 0x01] }

    /// A tilt's two forms (§5.5).
    static func blindTilt(_ tilt: Int) -> [[UInt8]] {
        let tilt = UInt8(min(max(tilt, 0), 100))
        return [[0x57, 0x0F, 0x45, 0x01, 0x01, 0x01, tilt], [0x57, 0x0F, 0x45, 0x01, 0x05, 0xFF, tilt]]
    }

    static func lock(_ action: UInt8, pro: Bool) -> [UInt8] {
        pro ? [0x57, 0x0F, 0x4E, 0x01, 0x01, 0x00, 0x00, action] : [0x57, 0x0F, 0x4E, 0x01, 0x01, 0x10, action]
    }

    static func lockInfo(pro: Bool) -> [UInt8] { [0x57, 0x0F, 0x4F, 0x81, pro ? 0x04 : 0x01] }

    static func encryptionInit(keyID: UInt8) -> [UInt8] { [0x57, 0x00, 0x00, 0x00, 0x0F, 0x21, 0x03, keyID] }

    /// The frames of a cloud command on a model. `brightness` is the light's current one (a colour is sent with it);
    /// `cloudAvailable` sends a Curtain's silent move to the cloud, whose speed byte Bluetooth does not pin (§5.2).
    static func request(
        for command: Command, model: BLEModel, password: String? = nil, brightness: Int = 100, cloudAvailable: Bool = false
    ) throws -> BLERequest {
        func unsupported() -> BLEUnsupported { BLEUnsupported(reason: "\(command) has no Bluetooth frame for a \(model.rawValue)") }
        switch model.family {
        case .bot:
            let action: UInt8 = switch command.command {
            case "press": 0x00
            case "turnOn": 0x01
            case "turnOff": 0x02
            default: throw unsupported()
            }
            return BLERequest(frames: [bot(action: action, password: password)], name: command.command)
        case .plug:
            switch command.command {
            case "turnOn": return BLERequest(frames: [plugOn], name: "turnOn")
            case "turnOff": return BLERequest(frames: [plugOff], name: "turnOff")
            default: throw unsupported()
            }
        case .curtain:
            switch command.command {
            case "pause": return BLERequest(frames: [curtainPause], name: "pause")
            case "setPosition":
                // `<index>,<mode>,<position>`: mode `1` is silent, `ff` (or `0`) the default.
                let parts = command.parameter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 3, let position = Int(parts[2]) else { throw unsupported() }
                var speed: UInt8 = 0xFF
                if parts[1] == "1" {
                    if model == .curtain3 { speed = 0x01 } else if cloudAvailable { throw BLEUnsupported(reason: "a Curtain's silent speed is not pinned over Bluetooth") }
                }
                return BLERequest(frames: [curtain(position: position, speed: speed)], name: "setPosition \(position)")
            case "fullyOpen": return BLERequest(frames: [curtain(position: 0)], name: "open")
            default: throw unsupported()
            }
        case .blindTilt:
            let tilt: Int
            switch command.command {
            case "fullyOpen": tilt = 50
            case "closeDown": tilt = 0
            case "closeUp": tilt = 100
            case "setPosition":
                // `<direction>;<openness>`: (down, h) → h / 2, (up, h) → 100 − h / 2 (§3.8).
                let parts = command.parameter.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, let openness = Double(parts[1]) else { throw unsupported() }
                let half = min(max(openness, 0), 100) / 2
                tilt = Int((parts[0] == "down" ? half : 100 - half).rounded())
            default: throw unsupported()
            }
            return BLERequest(frames: blindTilt(tilt), name: "tilt \(tilt)")
        case .light:
            let body: [UInt8]
            switch command.command {
            case "turnOn": body = [0x01]
            case "turnOff": body = [0x02]
            case "toggle": body = [0x03]
            case "setBrightness":
                guard let level = Int(command.parameter) else { throw unsupported() }
                body = [0x14, UInt8(min(max(level, 0), 100))]
            case "setColorTemperature":
                guard model == .colorBulb, let kelvin = Int(command.parameter) else { throw unsupported() }
                let clamped = UInt16(min(max(kelvin, 2700), 6500))
                body = [0x17, UInt8(clamped >> 8), UInt8(clamped & 0xFF)]
            case "setColor":
                let channels = command.parameter.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                guard channels.count == 3 else { throw unsupported() }
                body = [0x12, UInt8(min(max(brightness, 0), 100))] + channels.map { UInt8(min(max($0, 0), 255)) }
            default: throw unsupported()
            }
            return BLERequest(frames: [light(model, body)], name: command.description)
        case .lock:
            let pro = model == .lockPro
            switch command.command {
            case "lock": return BLERequest(frames: [lock(0x00, pro: pro)], encrypted: true, name: "lock")
            // Unlock also unlatches where the EU feature is on, as the cloud's `unlock` does (§5.6).
            case "unlock": return BLERequest(frames: [lock(0x80, pro: pro)], encrypted: true, name: "unlock")
            default: throw unsupported()
            }
        default:
            throw unsupported()
        }
    }

    /// The read of a model's state (§5.3, §5.4, §5.6), or nil without one.
    static func read(_ model: BLEModel) -> BLERequest? {
        switch model {
        case .plugMiniUS, .plugMiniJP: BLERequest(frames: [plugRead], name: "read state")
        case .colorBulb, .stripLight: BLERequest(frames: [lightRead(model)], name: "read state")
        case .lock, .lockPro: BLERequest(frames: [lockInfo(pro: model == .lockPro)], encrypted: true, name: "read lock info")
        default: nil
        }
    }

    /// A read's (or a command's) reply, status byte included, as a status; nil when it says nothing to show.
    static func status(ofReply reply: [UInt8], to request: BLERequest, model: BLEModel) -> [String: JSONValue]? {
        switch model {
        case .plugMiniUS, .plugMiniJP:
            guard reply.count >= 2 else { return nil }
            return ["power": .string(reply[1] & 0x80 != 0 ? "on" : "off")]
        case .colorBulb, .stripLight:
            guard request.name == "read state" else { return nil }
            return BLEAdvertisementDecoder.lightState(reply, bulb: model == .colorBulb)
        case .lock, .lockPro:
            guard request.name == "read lock info" else { return nil }
            return BLEAdvertisementDecoder.lockInfo(Array(reply.dropFirst()), pro: model == .lockPro)
        default:
            return nil
        }
    }
}

/// CRC-32 (IEEE: reflected `0xEDB88320`, initial and final `0xFFFFFFFF`), the Bot password's (§7.4).
func crc32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
    }
    return crc ^ 0xFFFF_FFFF
}

/// A Bot password as the Bot takes it: exactly 4 letters or digits (§7.4).
func validBotPassword(_ password: String) -> Bool {
    password.count == 4 && password.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
}

// MARK: Status

/// A reply's status byte (§4.4).
struct BLEStatus: Error, CustomStringConvertible, Equatable {
    var code: UInt8

    /// OK, and OK with a low battery (the command was executed).
    var succeeded: Bool { code == 0x01 || code == 0x06 }
    /// Busy is worth another attempt; a wrong password or an unsupported command is not.
    var retryable: Bool { code == 0x03 }

    var description: String {
        switch code {
        case 0x01: "OK"
        case 0x02: "error while executing (0x02)"
        case 0x03: "busy (0x03)"
        case 0x04: "protocol version incompatible (0x04)"
        case 0x05: "command not supported (0x05)"
        case 0x06: "OK, low battery (0x06)"
        case 0x07: "password required: the device is encrypted (0x07)"
        case 0x08: "the device is not encrypted (0x08)"
        case 0x09: "wrong password (0x09)"
        case 0x0A: "encryption method not supported (0x0A)"
        case 0x0B: "mesh device not found (0x0B)"
        case 0x0C: "network connection failed (0x0C)"
        case 0x0D: "not supported in the current mode (0x0D)"
        case 0x0E: "disconnected from a device that must stay connected (0x0E)"
        default: String(format: "status 0x%02X", code)
        }
    }

    /// Statuses the log shows as warnings (§8).
    var isWarning: Bool { [0x05, 0x07, 0x09, 0x0A].contains(code) }
}

// MARK: Encryption

/// A device's key (§7.1): 16 bytes from 32 hex digits, its id one byte from 2.
struct BLEKey: Sendable, Equatable {
    var key: [UInt8]
    var id: UInt8

    init?(key text: String, id idText: String) {
        let hex = text.trimmingCharacters(in: .whitespaces)
        let idHex = idText.trimmingCharacters(in: .whitespaces)
        guard hex.count == 32, hex.allSatisfy(\.isHexDigit), idHex.count == 2, let id = UInt8(idHex, radix: 16) else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        key = bytes
        self.id = id
    }
}

/// One connection's encryption session (§7.2, §7.3): set up by the init reply, forgotten with the connection.
struct BLECipher: Sendable {
    enum Mode: Sendable { case ctr, gcm }

    struct Rejected: Error, CustomStringConvertible {
        var description: String
    }

    let key: BLEKey
    let mode: Mode
    private(set) var iv: [UInt8]

    /// The session from the init reply: status `0x01`, byte 2 the mode, the IV from byte 4.
    init(key: BLEKey, initReply reply: [UInt8]) throws {
        guard reply.first == 0x01 else { throw Rejected(description: "the device rejected the key id (\(BLEStatus(code: reply.first ?? 0)))") }
        guard reply.count >= 4 else { throw Rejected(description: "the encryption init reply is too short") }
        self.key = key
        switch reply[2] {
        case 0:
            iv = Array(reply[4...])
            guard iv.count == 16 else { throw Rejected(description: "the device sent an IV of the wrong length for AES-CTR") }
            mode = .ctr
        case 1:
            guard reply.count >= 8 else { throw Rejected(description: "the encryption init reply is too short") }
            iv = Array(reply[4..<(reply.count - 4)])
            guard iv.count == 12 else { throw Rejected(description: "the device sent an IV of the wrong length for AES-GCM") }
            mode = .gcm
        default:
            throw Rejected(description: "encryption mode \(reply[2]) is not supported")
        }
    }

    /// `57 b1 … bn` as `57 KK H0 H1 E(b1 … bn)`; GCM moves the IV on after it.
    mutating func encrypt(_ request: [UInt8]) throws -> [UInt8] {
        let body = Array(request.dropFirst())
        switch mode {
        case .ctr:
            return [0x57, key.id, iv[0], iv[1]] + (try Self.ctr(body, key: key.key, counter: iv))
        case .gcm:
            let sealed = try AES.GCM.seal(body, using: SymmetricKey(data: key.key), nonce: AES.GCM.Nonce(data: iv))
            let tag = Array(sealed.tag)
            return [0x57, key.id, tag[0], tag[1]] + Array(sealed.ciphertext)
        }
    }

    /// A reply: its status in clear, then the payload from byte 4 decrypted with this message's IV (GCM's tag is not
    /// carried, so not checked).
    func decrypt(_ reply: [UInt8]) throws -> [UInt8] {
        guard let status = reply.first else { return [] }
        let body = reply.count > 4 ? Array(reply[4...]) : []
        switch mode {
        case .ctr: return [status] + (try Self.ctr(body, key: key.key, counter: iv))
        case .gcm: return [status] + (try Self.ctr(body, key: key.key, counter: iv + [0, 0, 0, 2], increment32: true))
        }
    }

    /// GCM's IV, a 96-bit big-endian number, plus one after each command.
    mutating func advance() {
        guard mode == .gcm else { return }
        for index in iv.indices.reversed() {
            iv[index] &+= 1
            if iv[index] != 0 { break }
        }
    }

    /// AES-128 in counter mode from `counter` (the whole 128-bit block counts, or its last 32 bits for GCM).
    static func ctr(_ data: [UInt8], key: [UInt8], counter start: [UInt8], increment32: Bool = false) throws -> [UInt8] {
        let symmetric = SymmetricKey(data: key)
        var counter = start
        var output: [UInt8] = []
        output.reserveCapacity(data.count)
        var offset = 0
        while offset < data.count {
            var block = counter
            try AES.permute(&block, key: symmetric)
            for index in 0..<min(16, data.count - offset) { output.append(data[offset + index] ^ block[index]) }
            offset += 16
            for index in (increment32 ? 12..<16 : 0..<16).reversed() {
                counter[index] &+= 1
                if counter[index] != 0 { break }
            }
        }
        return output
    }
}
