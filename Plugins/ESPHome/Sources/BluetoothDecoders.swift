import Foundation

/// The advertisement formats the plugin reads: what a Bluetooth sensor's Accessory Settings' `format` says.
enum BluetoothFormat: String, Sendable, Codable, CaseIterable {
    /// BTHome v2 (bthome.io): service data 0xFCD2, open or AES-CCM encrypted with a bindkey.
    case bthome
    /// Xiaomi's MiBeacon: service data 0xFE95, its objects AES-CCM encrypted with the device's bindkey (v4 and v5).
    case xiaomi
    /// Govee's thermometers and hygrometers: manufacturer data, never encrypted.
    case govee

    var manufacturer: String {
        switch self {
        case .bthome: "BTHome"
        case .xiaomi: "Xiaomi"
        case .govee: "Govee"
        }
    }

    /// The bytes of the format's part of an advertisement: what the decoder reads, and what tells one frame from another.
    /// `name` is the sender's name, from this advertisement or an earlier one.
    func frame(of advertisement: BluetoothAdvertisement, name: String?) -> [UInt8]? {
        switch self {
        case .bthome: advertisement.serviceData[BTHome.uuid]
        case .xiaomi: advertisement.serviceData[MiBeacon.uuid]
        case .govee: advertisement.manufacturerData[Govee.companyID] ?? (Govee.isGovee(name) ? advertisement.manufacturerData[Govee.genericCompanyID] : nil)
        }
    }
}

/// A button's press, as HomeKit's Programmable Switch Event tells them.
enum BluetoothButtonEvent: Int, Sendable, Equatable {
    case single = 0
    case double = 1
    case long = 2
}

/// What one advertisement says. A value it does not carry stays nil.
struct BluetoothReadings: Sendable, Equatable {
    /// °C.
    var temperature: Double?
    /// %.
    var humidity: Double?
    /// %.
    var battery: Int?
    var lowBattery: Bool?
    /// lux.
    var illuminance: Double?
    /// ppm.
    var carbonDioxide: Double?
    var motion: Bool?
    var occupancy: Bool?
    /// A door, a window or an opening: true when open.
    var open: Bool?
    /// Water: true when wet.
    var leak: Bool?
    var smoke: Bool?
    var carbonMonoxide: Bool?
    /// Each button of the device in order, with what it did (nil: nothing, it only says it exists).
    var buttons: [BluetoothButtonEvent?] = []
}

/// A frame read: what it says, and the counter of an encrypted one, which the sender increases with each frame (a frame
/// whose counter does not is a replay).
struct DecodedFrame: Sendable, Equatable {
    var readings: BluetoothReadings
    var counter: UInt32?
}

/// What the plugin knows of a sender from one advertisement, before any key.
struct BluetoothRecognition: Sendable, Equatable {
    var format: BluetoothFormat
    var model: String?
    var encrypted: Bool
}

enum BluetoothDecodeError: Error, Equatable {
    /// Encrypted, and no bindkey yet.
    case needsKey
    /// Encrypted, and the bindkey does not open it.
    case wrongKey
    /// A frame the plugin does not read (a legacy encryption, a version it does not know, bytes missing).
    case unsupported
    /// Open, from a sender set up with a bindkey: anyone can send it under the sensor's address.
    case unencrypted
}

enum BluetoothDecoders {
    /// Which format the advertisement is in; `name` is the sender's name from an earlier advertisement or scan response
    /// (Govee's newer models use a company id that is not Govee's own).
    static func recognize(_ advertisement: BluetoothAdvertisement, name: String?) -> BluetoothRecognition? {
        if let data = advertisement.serviceData[BTHome.uuid], let first = data.first, first >> 5 == 2 {
            return BluetoothRecognition(format: .bthome, model: nil, encrypted: first & 1 != 0)
        }
        if let data = advertisement.serviceData[MiBeacon.uuid], let frame = MiBeacon.Header(data, mac: advertisement.mac) {
            return BluetoothRecognition(format: .xiaomi, model: MiBeacon.models[frame.productID], encrypted: frame.encrypted)
        }
        if let model = Govee.model(of: advertisement, name: name ?? advertisement.name) {
            return BluetoothRecognition(format: .govee, model: model, encrypted: false)
        }
        return nil
    }

    /// The frame of an advertisement in `format`; nil when it carries none of that format.
    static func decode(_ advertisement: BluetoothAdvertisement, as format: BluetoothFormat, key: [UInt8]?, name: String?) throws -> DecodedFrame? {
        let name = name ?? advertisement.name
        guard let data = format.frame(of: advertisement, name: name) else { return nil }
        switch format {
        case .bthome: return try BTHome.decode(data, mac: advertisement.mac, key: key)
        case .xiaomi: return try MiBeacon.decode(data, mac: advertisement.mac, key: key)
        case .govee: return Govee.decode(advertisement, name: name).map { DecodedFrame(readings: $0) }
        }
    }

    /// The objects of a payload, opened when `encrypted`: it then ends with `trailer` bytes, a counter and a 4-byte MIC.
    /// `nonce` makes the nonce from the counter's bytes. Answers the plaintext and the counter's bytes (nil when open).
    /// A sender with a `key` must encrypt: an open frame under its address could come from anyone.
    static func open(
        _ payload: [UInt8], encrypted: Bool, trailer: Int, key: [UInt8]?, associatedData: [UInt8] = [], nonce: ([UInt8]) -> [UInt8]
    ) throws -> (plaintext: [UInt8], counter: [UInt8]?) {
        guard encrypted else {
            guard key == nil else { throw BluetoothDecodeError.unencrypted }
            return (payload, nil)
        }
        guard let key else { throw BluetoothDecodeError.needsKey }
        guard payload.count >= trailer, key.count == 16 else { throw BluetoothDecodeError.unsupported }
        let counter = Array(payload[(payload.count - trailer)..<(payload.count - 4)])
        do {
            let plaintext = try AESCCM.open(
                Array(payload.prefix(payload.count - trailer)), tag: Array(payload.suffix(4)), key: key, nonce: nonce(counter), associatedData: associatedData)
            return (plaintext, counter)
        } catch {
            throw BluetoothDecodeError.wrongKey
        }
    }

    /// The six octets of a canonical MAC, the first one first.
    static func octets(_ mac: String) -> [UInt8] {
        mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
    }

    static func uint(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    static func int(_ bytes: ArraySlice<UInt8>) -> Int32 {
        let bits = bytes.count * 8
        let raw = uint(bytes)
        guard bits > 0 else { return 0 }
        return bits >= 32 ? Int32(bitPattern: raw) : Int32(bitPattern: raw << UInt32(32 - bits)) >> Int32(32 - bits)
    }
}

// MARK: BTHome v2

/// BTHome v2 (https://bthome.io/format/ and /encryption/): service data 0xFCD2 whose first byte is the device
/// information (bit 0 encrypted, bit 2 sent on a trigger, bits 5 to 7 the version, 2), then objects: an id and its
/// value, little-endian, its size fixed by the id. An encrypted one ends with a 4-byte counter and a 4-byte MIC, its
/// objects AES-CCM encrypted with the 16-byte bindkey, the nonce the MAC, the UUID, the device information and the counter.
enum BTHome {
    static let uuid: UInt16 = 0xFCD2

    static func decode(_ data: [UInt8], mac: String, key: [UInt8]?) throws -> DecodedFrame {
        guard let info = data.first, info >> 5 == 2 else { throw BluetoothDecodeError.unsupported }
        let (objects, counter) = try BluetoothDecoders.open(Array(data.dropFirst()), encrypted: info & 1 != 0, trailer: 8, key: key) { counter in
            BluetoothDecoders.octets(mac) + [UInt8(uuid & 0xFF), UInt8(uuid >> 8), info] + counter
        }
        return DecodedFrame(readings: readings(objects), counter: counter.map { BluetoothDecoders.uint($0[...]) })
    }

    /// The size of each object's value, by id; an id not here ends the reading, as what follows cannot be found.
    static let sizes: [UInt8: Int] = {
        var sizes: [UInt8: Int] = [
            0x00: 1, 0x01: 1, 0x02: 2, 0x03: 2, 0x04: 3, 0x05: 3, 0x06: 2, 0x07: 2, 0x08: 2, 0x09: 1, 0x0A: 3, 0x0B: 3, 0x0C: 2,
            0x0D: 2, 0x0E: 2, 0x0F: 1, 0x10: 1, 0x11: 1, 0x12: 2, 0x13: 2, 0x14: 2, 0x2E: 1, 0x2F: 1, 0x3A: 1, 0x3C: 2,
            0x3D: 2, 0x3E: 4, 0x3F: 2, 0x40: 2, 0x41: 2, 0x42: 3, 0x43: 2, 0x44: 2, 0x45: 2, 0x46: 1, 0x47: 2, 0x48: 2, 0x49: 2,
            0x4A: 2, 0x4B: 3, 0x4C: 4, 0x4D: 4, 0x4E: 4, 0x4F: 4, 0x50: 4, 0x51: 2, 0x52: 2, 0x55: 4, 0x56: 2, 0x57: 1, 0x58: 1,
            0x59: 1, 0x5A: 2, 0x5B: 4, 0x5C: 4, 0x5D: 2, 0x5E: 2, 0x5F: 2, 0x60: 1, 0x61: 2, 0xF0: 2, 0xF1: 4, 0xF2: 3,
        ]
        // The binary sensors, one byte each: battery low (0x15) to window (0x2D).
        for id in UInt8(0x15)...0x2D { sizes[id] = 1 }
        return sizes
    }()

    static func readings(_ objects: [UInt8]) -> BluetoothReadings {
        var readings = BluetoothReadings()
        var index = 0
        func first<T>(_ path: WritableKeyPath<BluetoothReadings, T?>, _ value: T) {
            if readings[keyPath: path] == nil { readings[keyPath: path] = value }
        }
        while index < objects.count {
            let id = objects[index]
            index += 1
            let size: Int
            if id == 0x53 || id == 0x54 {
                // Text and raw: their length first.
                guard index < objects.count else { break }
                size = Int(objects[index]) + 1
            } else {
                guard let known = sizes[id] else { break }
                size = known
            }
            guard index + size <= objects.count else { break }
            let value = objects[index..<(index + size)]
            index += size
            let unsigned = Double(BluetoothDecoders.uint(value)), signed = Double(BluetoothDecoders.int(value))
            let on = value.first.map { $0 != 0 }
            switch id {
            case 0x01: first(\.battery, Int(unsigned))
            case 0x02: first(\.temperature, signed * 0.01)
            case 0x45: first(\.temperature, signed * 0.1)
            case 0x57: first(\.temperature, signed)
            case 0x58: first(\.temperature, signed * 0.35)
            case 0x03: first(\.humidity, unsigned * 0.01)
            case 0x2E: first(\.humidity, unsigned)
            case 0x05: first(\.illuminance, unsigned * 0.01)
            case 0x12: first(\.carbonDioxide, unsigned)
            case 0x15: if let on { first(\.lowBattery, on) }
            case 0x11, 0x1A, 0x1B, 0x2D: if let on { first(\.open, on) }
            case 0x21: if let on { first(\.motion, on) }
            case 0x23, 0x25: if let on { first(\.occupancy, on) }
            case 0x20: if let on { first(\.leak, on) }
            case 0x29: if let on { first(\.smoke, on) }
            case 0x17: if let on { first(\.carbonMonoxide, on) }
            case 0x3A:
                // 0 none, 1 press, 2 double press, 3 triple press, 4 long press, 5 long double, 6 long triple, 0x80 hold.
                let event: BluetoothButtonEvent? = switch value.first {
                case 0x01: .single
                case 0x02: .double
                case 0x04, 0x80: .long
                default: nil
                }
                readings.buttons.append(event)
            default:
                break
            }
        }
        return readings
    }
}

// MARK: Xiaomi MiBeacon

/// Xiaomi's MiBeacon in service data 0xFE95: a frame control (bit 3 encrypted, bit 4 MAC included, bit 5 capability
/// included, bit 6 object included, bits 12 to 15 the version), the product id, a frame counter, the MAC (least
/// significant octet first), the capability, then objects: a 2-byte type, a length and a value. From version 4 the
/// objects are AES-CCM encrypted with the 16-byte bindkey and followed by a 3-byte extended counter and a 4-byte MIC;
/// the nonce is the MAC as sent, the product id, the frame counter and the extended counter, the associated data 0x11.
enum MiBeacon {
    static let uuid: UInt16 = 0xFE95

    /// Product ids of the common thermometers and plant sensors.
    static let models: [UInt16: String] = [
        0x01AA: "LYWSDCGQ", 0x0347: "CGG1", 0x045B: "LYWSD02", 0x055B: "LYWSD03MMC", 0x0098: "HHCCJCY01",
    ]

    struct Header {
        var control: UInt16
        var productID: UInt16
        var counter: UInt8
        /// The MAC as sent, least significant octet first.
        var reversedMAC: [UInt8]
        /// Where the objects start.
        var payloadStart: Int

        var encrypted: Bool { control & 0x0008 != 0 }
        var hasObjects: Bool { control & 0x0040 != 0 }
        var version: Int { Int(control >> 12) }

        init?(_ data: [UInt8], mac: String) {
            guard data.count >= 5 else { return nil }
            control = UInt16(BluetoothDecoders.uint(data[0..<2]))
            productID = UInt16(BluetoothDecoders.uint(data[2..<4]))
            counter = data[4]
            var index = 5
            if control & 0x0010 != 0 {
                guard data.count >= index + 6 else { return nil }
                reversedMAC = Array(data[index..<(index + 6)])
                index += 6
            } else {
                reversedMAC = BluetoothDecoders.octets(mac).reversed()
            }
            if control & 0x0020 != 0 {
                guard data.count > index else { return nil }
                let capability = data[index]
                index += 1
                // An I/O capability follows when its bit is set.
                if capability & 0x20 != 0 { index += 2 }
            }
            guard index <= data.count else { return nil }
            payloadStart = index
        }
    }

    static func decode(_ data: [UInt8], mac: String, key: [UInt8]?) throws -> DecodedFrame {
        guard let header = Header(data, mac: mac) else { throw BluetoothDecodeError.unsupported }
        // A beacon without objects says nothing.
        guard header.hasObjects else { return DecodedFrame(readings: BluetoothReadings()) }
        // Versions before 4 encrypted with another scheme, which this plugin does not read.
        guard !header.encrypted || header.version >= 4 else { throw BluetoothDecodeError.unsupported }
        let (objects, extended) = try BluetoothDecoders.open(
            Array(data[header.payloadStart...]), encrypted: header.encrypted, trailer: 7, key: key, associatedData: [0x11]
        ) { extended in header.reversedMAC + Array(data[2..<5]) + extended }
        // The extended counter above the frame counter.
        return DecodedFrame(readings: readings(objects), counter: extended.map { BluetoothDecoders.uint($0[...]) << 8 | UInt32(header.counter) })
    }

    static func readings(_ payload: [UInt8]) -> BluetoothReadings {
        var readings = BluetoothReadings()
        var index = 0
        while index + 3 <= payload.count {
            let type = UInt16(BluetoothDecoders.uint(payload[index..<(index + 2)]))
            let length = Int(payload[index + 2])
            index += 3
            guard index + length <= payload.count else { break }
            let value = payload[index..<(index + length)]
            index += length
            switch (type, length) {
            case (0x1004, 2): readings.temperature = Double(BluetoothDecoders.int(value)) / 10
            case (0x1006, 2): readings.humidity = Double(BluetoothDecoders.uint(value)) / 10
            case (0x100A, 1): readings.battery = Int(BluetoothDecoders.uint(value))
            case (0x100D, 4):
                readings.temperature = Double(BluetoothDecoders.int(value.prefix(2))) / 10
                readings.humidity = Double(BluetoothDecoders.uint(value.suffix(2))) / 10
            case (0x1007, 3): readings.illuminance = Double(BluetoothDecoders.uint(value))
            // Motion with the light level, then the seconds without motion.
            case (0x000F, 3):
                readings.motion = true
                readings.illuminance = Double(BluetoothDecoders.uint(value))
            case (0x1017, 4): readings.motion = false
            // Door: 0 open, 1 closed, 2 left open too long.
            case (0x1019, 1): readings.open = value.first != 1
            case (0x4C01, 4): readings.temperature = Double(Float(bitPattern: BluetoothDecoders.uint(value)))
            case (0x4C02, 1): readings.humidity = Double(BluetoothDecoders.uint(value))
            default: break
            }
        }
        return readings
    }
}

// MARK: Govee

/// Govee's thermometers and hygrometers, in manufacturer data. Company id 0xEC88: the H5072 and H5075 (six bytes, the
/// temperature and humidity packed in three, then the battery) and the H5074 (seven bytes, the temperature and humidity in
/// hundredths, little-endian, then the battery); other lengths there are other Govee devices. Company id 0x0001, told by
/// a name starting GVH5 or Govee: the H5100 family (H5100, H5101, H5102, H5104, H5174, H5177; six bytes, packed from the third) and the H5179 (nine bytes, the
/// values in hundredths from the fifth). Packed is `temperature × 10000 + humidity × 10` in tenths, its top bit the sign.
enum Govee {
    static let companyID: UInt16 = 0xEC88
    static let genericCompanyID: UInt16 = 0x0001

    /// The model from the name (`GVH5075_A1B2` is an H5075), else from the frame's shape.
    static func model(of advertisement: BluetoothAdvertisement, name: String?) -> String? {
        if let data = advertisement.manufacturerData[companyID] {
            switch data.count {
            case 6: return name.flatMap(modelName) ?? "H5075"
            case 7: return name.flatMap(modelName) ?? "H5074"
            default: return nil
            }
        }
        guard let data = advertisement.manufacturerData[genericCompanyID], data.count == 6 || data.count == 9, isGovee(name) else { return nil }
        return name.flatMap(modelName)
    }

    static func isGovee(_ name: String?) -> Bool {
        guard let name else { return false }
        return name.hasPrefix("GVH5") || name.hasPrefix("Govee")
    }

    /// `GVH5075_A1B2` → `H5075`; `Govee_H5179_1234` → `H5179`.
    static func modelName(_ name: String) -> String? {
        guard let start = name.range(of: "H5") else { return nil }
        let model = name[start.lowerBound...].prefix { $0.isLetter || $0.isNumber }
        return model.count >= 5 ? String(model) : nil
    }

    static func decode(_ advertisement: BluetoothAdvertisement, name: String?) -> BluetoothReadings? {
        if let data = advertisement.manufacturerData[companyID] {
            if data.count == 6 { return packed(data[1..<4], battery: data[4]) }
            if data.count == 7 { return hundredths(data[1..<5], battery: data[5]) }
            return nil
        }
        if let data = advertisement.manufacturerData[genericCompanyID], isGovee(name) {
            if data.count == 6 { return packed(data[2..<5], battery: data[5]) }
            if data.count == 9 { return hundredths(data[4..<8], battery: data[8]) }
        }
        return nil
    }

    /// Three bytes, big-endian.
    static func packed(_ bytes: ArraySlice<UInt8>, battery: UInt8) -> BluetoothReadings {
        let raw = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let negative = raw & 0x80_0000 != 0
        let value = Int(raw & 0x7F_FFFF)
        let temperature = Double(value / 1000) / 10
        return BluetoothReadings(
            temperature: negative ? -temperature : temperature, humidity: Double(value % 1000) / 10, battery: Int(min(battery, 100)))
    }

    /// Temperature then humidity, each two bytes little-endian, in hundredths.
    static func hundredths(_ bytes: ArraySlice<UInt8>, battery: UInt8) -> BluetoothReadings {
        let start = bytes.startIndex
        return BluetoothReadings(
            temperature: Double(BluetoothDecoders.int(bytes[start..<(start + 2)])) / 100,
            humidity: Double(BluetoothDecoders.uint(bytes[(start + 2)..<(start + 4)])) / 100, battery: Int(min(battery, 100)))
    }
}
