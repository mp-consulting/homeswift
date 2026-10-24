import Foundation

/// The bytes of Bluetooth LE on Linux, as noble's hci-socket bindings write and read them (`lib/hci-socket/hci.js`,
/// `gap.js`, `gatt.js`): HCI commands and events on a raw HCI socket for scanning, ATT PDUs on the kernel's L2CAP
/// ATT channel for connections. Pure, so tests check them on every platform; `LinuxBluetoothCentral` sends them.
enum HCI {
    static let commandPacket: UInt8 = 0x01
    static let eventPacket: UInt8 = 0x04

    static let eventCommandComplete: UInt8 = 0x0e
    static let eventCommandStatus: UInt8 = 0x0f
    static let eventLEMeta: UInt8 = 0x3e
    static let leAdvertisingReport: UInt8 = 0x02
    static let leExtendedAdvertisingReport: UInt8 = 0x0d

    static let readBDAddr: UInt16 = 0x1009
    static let leSetScanParameters: UInt16 = 0x200b
    static let leSetScanEnable: UInt16 = 0x200c
    static let leSetExtendedScanParameters: UInt16 = 0x2041
    static let leSetExtendedScanEnable: UInt16 = 0x2042

    /// Statuses that mean "use the extended commands": unknown command, command disallowed (the host used
    /// extended advertising commands since the controller's reset, so legacy ones are refused).
    static let unknownCommand: UInt8 = 0x01
    static let commandDisallowed: UInt8 = 0x0c

    /// A command packet: type, opcode (little endian), parameter length, parameters.
    static func command(_ opcode: UInt16, _ parameters: [UInt8] = []) -> [UInt8] {
        [commandPacket, UInt8(opcode & 0xff), UInt8(opcode >> 8), UInt8(parameters.count)] + parameters
    }

    /// LE Set Scan Parameters as noble sends it: active scanning, interval and window 0x0012 (11.25 ms, so the
    /// controller listens all the time), the adapter's public address, every advertiser.
    static func setScanParameters(extended: Bool, interval: UInt16 = 0x0012, window: UInt16 = 0x0012) -> [UInt8] {
        if extended {
            // Own address type, filter policy, PHYs (LE 1M), then for that PHY: type, interval, window.
            return command(leSetExtendedScanParameters, [0x00, 0x00, 0x01, 0x01] + le16(interval) + le16(window))
        }
        return command(leSetScanParameters, [0x01] + le16(interval) + le16(window) + [0x00, 0x00])
    }

    /// LE Set Scan Enable; the extended form adds a duration and period of 0 (until disabled).
    static func setScanEnable(_ enabled: Bool, filterDuplicates: Bool, extended: Bool) -> [UInt8] {
        let flags: [UInt8] = [enabled ? 0x01 : 0x00, filterDuplicates ? 0x01 : 0x00]
        return extended ? command(leSetExtendedScanEnable, flags + [0, 0, 0, 0]) : command(leSetScanEnable, flags)
    }

    /// The raw socket's filter (`struct hci_filter`, with its padding): event packets only, those this central
    /// reads (command complete and status, LE meta events).
    static var socketFilter: [UInt8] {
        let typeMask = UInt32(1) << UInt32(eventPacket)
        let events0 = (UInt32(1) << UInt32(eventCommandComplete)) | (UInt32(1) << UInt32(eventCommandStatus))
        let events1 = UInt32(1) << UInt32(eventLEMeta - 32)
        return le32(typeMask) + le32(events0) + le32(events1) + [0, 0, 0, 0]
    }

    enum Event: Equatable {
        case commandComplete(opcode: UInt16, status: UInt8, parameters: [UInt8])
        case commandStatus(opcode: UInt16, status: UInt8)
        case advertisingReports([AdvertisingReport])
    }

    /// One advertisement or scan response of an LE (extended) advertising report.
    struct AdvertisingReport: Equatable {
        /// Lower case, colon separated, most significant byte first, as noble writes it.
        var address: String
        var randomAddress: Bool
        var isScanResponse: Bool
        var data: [UInt8]
        var rssi: Int
    }

    /// An event packet read from the raw socket; nil for other packets and events, and for truncated ones.
    static func parse(_ packet: [UInt8]) -> Event? {
        guard packet.count >= 3, packet[0] == eventPacket, packet.count >= 3 + Int(packet[2]) else { return nil }
        let body = Array(packet[3..<(3 + Int(packet[2]))])
        switch packet[1] {
        case eventCommandComplete:
            // Allowed command packets, opcode, status, return parameters.
            guard body.count >= 4 else { return nil }
            return .commandComplete(opcode: UInt16(body[1]) | UInt16(body[2]) << 8, status: body[3], parameters: Array(body.dropFirst(4)))
        case eventCommandStatus:
            guard body.count >= 4 else { return nil }
            return .commandStatus(opcode: UInt16(body[2]) | UInt16(body[3]) << 8, status: body[0])
        case eventLEMeta:
            guard body.count >= 2 else { return nil }
            let count = Int(body[1])
            let reports = Array(body.dropFirst(2))
            switch body[0] {
            case leAdvertisingReport: return .advertisingReports(legacyReports(count, reports))
            case leExtendedAdvertisingReport: return .advertisingReports(extendedReports(count, reports))
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Event type, address type, address, data length, data, RSSI, report after report (`processLeAdvertisingReport`).
    static func legacyReports(_ count: Int, _ bytes: [UInt8]) -> [AdvertisingReport] {
        var reports: [AdvertisingReport] = []
        var offset = 0
        for _ in 0..<count {
            guard bytes.count >= offset + 10 else { break }
            let length = Int(bytes[offset + 8])
            guard bytes.count >= offset + 10 + length else { break }
            reports.append(AdvertisingReport(
                address: BluetoothAddress.string(bytes[(offset + 2)..<(offset + 8)]), randomAddress: isRandom(bytes[offset + 1]),
                isScanResponse: bytes[offset] == 0x04, data: Array(bytes[(offset + 9)..<(offset + 9 + length)]),
                rssi: Int(Int8(bitPattern: bytes[offset + 9 + length]))))
            offset += 10 + length
        }
        return reports
    }

    /// 24 bytes (event type, address type and address, PHYs, SID, TX power, RSSI, interval, direct address, data
    /// length) then the data (`processLeExtendedAdvertisingReport`).
    static func extendedReports(_ count: Int, _ bytes: [UInt8]) -> [AdvertisingReport] {
        var reports: [AdvertisingReport] = []
        var offset = 0
        for _ in 0..<count {
            guard bytes.count >= offset + 24 else { break }
            let length = Int(bytes[offset + 23])
            guard bytes.count >= offset + 24 + length else { break }
            let type = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            reports.append(AdvertisingReport(
                address: BluetoothAddress.string(bytes[(offset + 3)..<(offset + 9)]), randomAddress: isRandom(bytes[offset + 2]),
                isScanResponse: type & 0x08 != 0, data: Array(bytes[(offset + 24)..<(offset + 24 + length)]),
                rssi: Int(Int8(bitPattern: bytes[offset + 13]))))
            offset += 24 + length
        }
        return reports
    }

    /// Random (1) and random identity (3) addresses.
    private static func isRandom(_ type: UInt8) -> Bool { type == 0x01 || type == 0x03 }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) } }
}

/// MAC addresses: text, most significant byte first, against HCI's little-endian bytes.
enum BluetoothAddress {
    /// `a4:c1:38:00:00:11`, `A4-C1-38-00-00-11` or `A4C138000011`; nil for anything else.
    static func normalized(_ text: String) -> String? {
        let hex = text.lowercased().filter { $0 != ":" && $0 != "-" }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            String(hex[hex.index(hex.startIndex, offsetBy: offset)..<hex.index(hex.startIndex, offsetBy: offset + 2)])
        }.joined(separator: ":")
    }

    /// The address as HCI and the kernel's `bdaddr_t` hold it: least significant byte first.
    static func bytes(_ text: String) -> [UInt8]? {
        guard let normalized = normalized(text) else { return nil }
        return normalized.split(separator: ":").compactMap { UInt8($0, radix: 16) }.reversed()
    }

    static func string(_ littleEndian: ArraySlice<UInt8>) -> String {
        littleEndian.reversed().map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// For an address never seen advertising: a static random address has its two top bits set; Govee's are
    /// mostly public (Telink's and Govee's own prefixes).
    static func looksRandom(_ text: String) -> Bool {
        guard let first = bytes(text)?.last else { return false }
        return first & 0xc0 == 0xc0
    }
}

/// Advertising data (`gap.js` `parseServices`): length, type, value structures. Merged over a scan, as noble does,
/// so a scan response adds to the advertisement before it.
struct AdvertisingData: Equatable {
    var localName: String?
    /// Company id first.
    var manufacturerData: [UInt8]?
    /// Service UUIDs listed or carrying service data: four hex digits for 16-bit ones (and 128-bit ones on the
    /// Bluetooth base), 32 for the others, lower case.
    var services: [String] = []

    mutating func merge(_ data: [UInt8]) {
        var offset = 0
        while offset + 1 < data.count {
            let length = Int(data[offset])
            guard length >= 1, offset + length + 1 <= data.count else { break }
            let value = Array(data[(offset + 2)..<(offset + length + 1)])
            switch data[offset + 1] {
            case 0x02, 0x03:
                for start in stride(from: 0, to: value.count - 1, by: 2) { add(ATT.uuidString(value[start..<(start + 2)])) }
            case 0x06, 0x07:
                for start in stride(from: 0, to: value.count - 15, by: 16) { add(ATT.uuidString(value[start..<(start + 16)])) }
            case 0x08, 0x09:
                localName = String(decoding: value, as: UTF8.self)
            case 0x16:
                if value.count >= 2 { add(ATT.uuidString(value[0..<2])) }
            case 0x21:
                if value.count >= 16 { add(ATT.uuidString(value[0..<16])) }
            case 0xff:
                manufacturerData = value
            default:
                break
            }
            offset += length + 1
        }
    }

    private mutating func add(_ uuid: String) {
        if !services.contains(uuid) { services.append(uuid) }
    }

    /// Whether it lists one of these services (any, when there are none), as noble's scan filter.
    func advertises(anyOf wanted: Set<String>) -> Bool {
        wanted.isEmpty || services.contains { wanted.contains($0) }
    }
}

/// What a scan has seen, by address: the merged advertising data, the address type and RSSI, the latest `limit`.
struct AdvertisementCache {
    struct Entry: Equatable {
        var randomAddress: Bool
        var data: AdvertisingData
        var rssi: Int
    }

    static let limit = 256
    private(set) var entries: [String: Entry] = [:]
    private var order: [String] = []

    mutating func add(_ report: HCI.AdvertisingReport) -> Entry {
        var entry = entries[report.address] ?? Entry(randomAddress: report.randomAddress, data: AdvertisingData(), rssi: report.rssi)
        if entries[report.address] == nil {
            order.append(report.address)
            if order.count > Self.limit { entries[order.removeFirst()] = nil }
        }
        // A scan response comes with the advertiser's address type too.
        entry.randomAddress = report.randomAddress
        entry.rssi = report.rssi
        entry.data.merge(report.data)
        entries[report.address] = entry
        return entry
    }
}

/// The Attribute Protocol, client side, as `gatt.js` speaks it: characteristic discovery, write commands, and
/// the answers a peripheral's own PDUs need.
enum ATT {
    /// The fixed L2CAP channel of ATT on LE.
    static let channel: UInt16 = 0x0004
    static let defaultMTU = 23

    static let error: UInt8 = 0x01
    static let mtuRequest: UInt8 = 0x02
    static let mtuResponse: UInt8 = 0x03
    static let readByTypeRequest: UInt8 = 0x08
    static let readByTypeResponse: UInt8 = 0x09
    static let notification: UInt8 = 0x1b
    static let indication: UInt8 = 0x1d
    static let confirmation: UInt8 = 0x1e
    static let writeCommand: UInt8 = 0x52

    static let attributeNotFound: UInt8 = 0x0a
    static let requestNotSupported: UInt8 = 0x06
    static let characteristicDeclaration: UInt16 = 0x2803

    static func readByType(start: UInt16, end: UInt16 = 0xffff, type: UInt16 = characteristicDeclaration) -> [UInt8] {
        [readByTypeRequest] + HCI.le16(start) + HCI.le16(end) + HCI.le16(type)
    }

    static func write(handle: UInt16, value: [UInt8]) -> [UInt8] {
        [writeCommand] + HCI.le16(handle) + value
    }

    static func errorResponse(request: UInt8, handle: UInt16 = 0, code: UInt8) -> [UInt8] {
        [error, request] + HCI.le16(handle) + [code]
    }

    /// A UUID's little-endian bytes as text: four hex digits for 16 bits, 32 for 128 bits, which shrink to four
    /// on the Bluetooth base UUID; lower case, no dashes (CoreBluetooth's keys in this plugin).
    static func uuidString(_ bytes: ArraySlice<UInt8>) -> String {
        let text = bytes.reversed().map { String(format: "%02x", $0) }.joined()
        if text.count == 32, text.hasPrefix("0000"), text.hasSuffix("00001000800000805f9b34fb") {
            return String(text.dropFirst(4).prefix(4))
        }
        return text
    }

    struct Characteristic: Equatable {
        var declaration: UInt16
        var properties: UInt8
        var valueHandle: UInt16
        var uuid: String
    }

    /// What arrived from the peripheral.
    enum Incoming: Equatable {
        /// A response (or error response) to this client's request.
        case response([UInt8])
        /// A request of the peripheral's (an MTU exchange), with its answer.
        case request(answer: [UInt8])
        /// A notification, or an indication with the confirmation it needs.
        case value(handle: UInt16, value: [UInt8], confirm: [UInt8]?)
    }

    /// Requests have even opcodes: an MTU exchange is answered with the default MTU, others are refused, as
    /// `gatt.js` does; nil for commands and empty PDUs.
    static func classify(_ pdu: [UInt8]) -> Incoming? {
        guard let opcode = pdu.first else { return nil }
        if opcode == notification || opcode == indication {
            guard pdu.count >= 3 else { return nil }
            let handle = UInt16(pdu[1]) | UInt16(pdu[2]) << 8
            return .value(handle: handle, value: Array(pdu.dropFirst(3)), confirm: opcode == indication ? [confirmation] : nil)
        }
        // Commands (write commands) want no answer.
        if opcode & 0x40 != 0 { return nil }
        if opcode & 0x01 == 0 {
            if opcode == mtuRequest { return .request(answer: [mtuResponse] + HCI.le16(UInt16(defaultMTU))) }
            return .request(answer: errorResponse(request: opcode, code: requestNotSupported))
        }
        return .response(pdu)
    }
}

/// Every characteristic of the peripheral, by Read By Type requests over the whole handle range (gatttool's
/// `characteristics`), each starting after the last value handle found, as `gatt.js` continues.
struct CharacteristicDiscovery {
    enum Failure: Error, CustomStringConvertible, Equatable {
        case error(request: UInt8, code: UInt8)
        case unexpected([UInt8])

        var description: String {
            switch self {
            case .error(let request, let code): String(format: "ATT error 0x%02x for request 0x%02x", code, request)
            case .unexpected(let pdu): "unexpected ATT PDU \(pdu.map { String(format: "%02x", $0) }.joined())"
            }
        }
    }

    private(set) var characteristics: [ATT.Characteristic] = []
    private var next: UInt16? = 0x0001

    /// The request to send next; nil once every characteristic is known.
    var request: [UInt8]? { next.map { ATT.readByType(start: $0) } }

    mutating func receive(_ pdu: [UInt8]) throws {
        guard let opcode = pdu.first else { throw Failure.unexpected(pdu) }
        if opcode == ATT.error, pdu.count >= 5 {
            // Attribute not found ends the search.
            guard pdu[4] == ATT.attributeNotFound else { throw Failure.error(request: pdu[1], code: pdu[4]) }
            next = nil
            return
        }
        guard opcode == ATT.readByTypeResponse, pdu.count >= 2, pdu[1] == 7 || pdu[1] == 21 else { throw Failure.unexpected(pdu) }
        let size = Int(pdu[1])
        var found: [ATT.Characteristic] = []
        var offset = 2
        while offset + size <= pdu.count {
            found.append(ATT.Characteristic(
                declaration: UInt16(pdu[offset]) | UInt16(pdu[offset + 1]) << 8, properties: pdu[offset + 2],
                valueHandle: UInt16(pdu[offset + 3]) | UInt16(pdu[offset + 4]) << 8, uuid: ATT.uuidString(pdu[(offset + 5)..<(offset + size)])))
            offset += size
        }
        // A peripheral that answers with handles before the requested range would keep the search going forever.
        guard let last = found.last, let start = next, last.valueHandle >= start else { throw Failure.unexpected(pdu) }
        characteristics += found
        next = last.valueHandle == 0xffff ? nil : last.valueHandle + 1
    }
}

/// The kernel's Bluetooth socket addresses as bytes (little-endian hosts: x86 and ARM Linux).
enum BluetoothSocketAddress {
    static let family: UInt16 = 31   // AF_BLUETOOTH
    static let rawChannel: UInt16 = 0   // HCI_CHANNEL_RAW
    static let lePublic: UInt8 = 1   // BDADDR_LE_PUBLIC
    static let leRandom: UInt8 = 2   // BDADDR_LE_RANDOM

    /// `struct sockaddr_hci`: family, device, channel.
    static func hci(device: UInt16, channel: UInt16 = rawChannel) -> [UInt8] {
        HCI.le16(family) + HCI.le16(device) + HCI.le16(channel)
    }

    /// `struct sockaddr_l2` on the ATT channel: family, PSM 0, address (little endian), CID, address type, padding.
    static func l2cap(address: [UInt8], random: Bool) -> [UInt8] {
        HCI.le16(family) + HCI.le16(0) + address + HCI.le16(ATT.channel) + [random ? leRandom : lePublic, 0]
    }
}
