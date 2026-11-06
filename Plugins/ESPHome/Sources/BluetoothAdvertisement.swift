import Foundation
import HomeswiftNetwork

/// One Bluetooth LE advertisement a proxy heard: who sent it, how loud, and the parts of it the decoders read.
struct BluetoothAdvertisement: Sendable, Equatable {
    /// The sender's address, canonical (`A4:C1:38:12:34:56`).
    var mac: String
    var rssi: Int
    /// The complete or shortened local name, when this advertisement (or its scan response) carried one.
    var name: String?
    /// Service data by 16-bit UUID (BTHome's 0xFCD2, Xiaomi's 0xFE95).
    var serviceData: [UInt16: [UInt8]] = [:]
    /// Manufacturer data by company id, the id itself left out (Govee's 0xEC88).
    var manufacturerData: [UInt16: [UInt8]] = [:]

    /// A 48-bit address as ESPHome sends it (`uint64 address`, the first octet in the most significant byte).
    static func mac(of address: UInt64) -> String {
        // Hand-made rather than String(format:): every advertisement heard comes through here.
        let digits = Array("0123456789ABCDEF".utf8)
        var text: [UInt8] = []
        text.reserveCapacity(17)
        for shift in stride(from: 40, through: 0, by: -8) {
            let byte = UInt8(truncatingIfNeeded: address >> UInt64(shift))
            if !text.isEmpty { text.append(UInt8(ascii: ":")) }
            text += [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The advertisement's AD structures (Bluetooth Core Specification, Supplement part A): a length, a type, its data.
    /// A structure that runs past the end stops the reading; what came before it stays.
    init(mac: String, rssi: Int, raw: [UInt8]) {
        self.mac = mac
        self.rssi = rssi
        var index = 0
        while index < raw.count {
            let length = Int(raw[index])
            guard length > 0, index + 1 + length <= raw.count else { break }
            let type = raw[index + 1]
            let data = Array(raw[(index + 2)..<(index + 1 + length)])
            index += 1 + length
            switch type {
            case 0x08, 0x09:
                // The complete name wins over a shortened one.
                if type == 0x09 || name == nil { name = Self.text(data) }
            case 0x16 where data.count >= 2:
                serviceData[UInt16(BluetoothDecoders.uint(data[0..<2]))] = Array(data.dropFirst(2))
            case 0xFF where data.count >= 2:
                manufacturerData[UInt16(BluetoothDecoders.uint(data[0..<2]))] = Array(data.dropFirst(2))
            default:
                break
            }
        }
    }

    init(mac: String, rssi: Int, name: String? = nil, serviceData: [UInt16: [UInt8]] = [:], manufacturerData: [UInt16: [UInt8]] = [:]) {
        self.mac = mac
        self.rssi = rssi
        self.name = name
        self.serviceData = serviceData
        self.manufacturerData = manufacturerData
    }

    static func text(_ bytes: [UInt8]) -> String? {
        let text = Sanitized.text(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self), limit: 64)
        return text.isEmpty ? nil : text
    }

    /// The 16-bit UUID of a Bluetooth Base UUID (`0000fcd2-0000-1000-8000-00805f9b34fb`), or of `0xFCD2`.
    static func shortUUID(_ text: String) -> UInt16? {
        let lower = text.lowercased()
        if lower.hasPrefix("0x") { return UInt16(lower.dropFirst(2), radix: 16) }
        if lower.count == 36, lower.hasPrefix("0000"), lower.hasSuffix("-0000-1000-8000-00805f9b34fb") {
            return UInt16(lower.dropFirst(4).prefix(4), radix: 16)
        }
        if lower.count <= 4 { return UInt16(lower, radix: 16) }
        return nil
    }
}

/// The native API's Bluetooth proxy messages (ESPHome's `api.proto`).
enum BluetoothProxy {
    /// SubscribeBluetoothLEAdvertisementsRequest: `flags` 1 asks for raw advertisements.
    static let subscribeRequest = 66
    /// BluetoothLEAdvertisementResponse: one advertisement, parsed by the proxy (firmware without raw advertisements).
    static let advertisementResponse = 67
    /// BluetoothLERawAdvertisementsResponse: a batch of advertisements as received.
    static let rawAdvertisementsResponse = 93

    /// DeviceInfoResponse's `bluetooth_proxy_feature_flags`: passive scanning, and raw advertisements.
    static let passiveScanFeature: UInt32 = 1
    static let rawAdvertisementsFeature: UInt32 = 32

    static func subscribe(raw: Bool) -> ESPHomeFrame {
        var body = ProtobufWriter()
        body.uint32(1, raw ? 1 : 0)
        return ESPHomeFrame(type: subscribeRequest, body: body.bytes)
    }

    /// The advertisements of a BluetoothLERawAdvertisementsResponse or a BluetoothLEAdvertisementResponse; nil for
    /// another message.
    static func advertisements(type: Int, message: ProtobufMessage) -> [BluetoothAdvertisement]? {
        switch type {
        case rawAdvertisementsResponse:
            // repeated BluetoothLERawAdvertisement advertisements = 1: address 1, sint32 rssi 2, address_type 3, data 4.
            return message.fields.compactMap { field in
                guard field.number == 1, case .bytes(let bytes) = field.value, let item = ProtobufMessage(bytes) else { return nil }
                return BluetoothAdvertisement(mac: BluetoothAdvertisement.mac(of: item.uint64(1)), rssi: sint32(item.uint64(2)), raw: item.bytes(4))
            }
        case advertisementResponse:
            // address 1, bytes name 2, sint32 rssi 3, service_uuids 4, service_data 5, manufacturer_data 6 (each
            // BluetoothServiceData: string uuid 1, repeated uint32 legacy_data 2, bytes data 3).
            var advertisement = BluetoothAdvertisement(
                mac: BluetoothAdvertisement.mac(of: message.uint64(1)), rssi: sint32(message.uint64(3)), name: BluetoothAdvertisement.text(message.bytes(2)))
            for field in message.fields where field.number == 5 || field.number == 6 {
                guard case .bytes(let bytes) = field.value, let data = ProtobufMessage(bytes),
                      let uuid = BluetoothAdvertisement.shortUUID(data.string(1)) else { continue }
                let payload = data.has(3) ? data.bytes(3) : data.enumerations(2).map { UInt8(truncatingIfNeeded: $0) }
                if field.number == 5 { advertisement.serviceData[uuid] = payload } else { advertisement.manufacturerData[uuid] = payload }
            }
            return [advertisement]
        default:
            return nil
        }
    }

    /// protobuf's `sint32` (zigzag).
    static func sint32(_ raw: UInt64) -> Int {
        let value = UInt32(truncatingIfNeeded: raw)
        return Int(Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1))))
    }
}
