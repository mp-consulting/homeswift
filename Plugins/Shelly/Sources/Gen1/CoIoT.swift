import Foundation
import HomeswiftAI
import HomeswiftNetwork

/// A Gen 1 device's status as CoIoT carries it: CoAP (`CoAPMessage`) with Shelly's options, multicast to 224.0.1.187:5683
/// with code 0.30 on change and periodically, or sent back with 2.05 to a `/cit/s` request.
struct CoIoTStatus: Sendable, Equatable {
    /// Option 3332: `<model>#<deviceId>#<protocolRevision>`.
    static let deviceIDOption = 3332
    /// Option 3412: how long the status holds.
    static let validityOption = 3412
    /// Option 3420: grows when the status changes.
    static let serialOption = 3420

    static let multicastGroup = "224.0.1.187"
    static let port = 5683

    var model: String
    var deviceID: String
    /// `"1"` for CoIoT v1 (3-digit ids, firmware before 1.8), `"2"` for v2.
    var revision: String
    /// Seconds the device may stay silent before it counts as offline.
    var validity: Int?
    var serial: Int?
    /// The `G` tuples: channel, property id, value.
    var values: [(channel: Int, id: Int, value: JSONValue)]

    static func == (a: CoIoTStatus, b: CoIoTStatus) -> Bool {
        a.model == b.model && a.deviceID == b.deviceID && a.revision == b.revision && a.validity == b.validity && a.serial == b.serial
            && a.values.map(\.id) == b.values.map(\.id) && a.values.map(\.value) == b.values.map(\.value)
    }

    /// The property ids present.
    var ids: Set<Int> { Set(values.map(\.id)) }

    /// A datagram: nil for anything but a status (code 0.30 or 2.05) with a device id option and a `G` list.
    init?(datagram: some Collection<UInt8>) {
        guard let message = try? CoAPMessage(bytes: datagram), message.code == 30 || message.code == 69,
              let id = message.option(Self.deviceIDOption)?.stringValue else { return nil }
        let parts = id.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        model = parts[0]
        deviceID = parts[1]
        revision = parts.count > 2 ? parts[2] : "1"
        // Both are 16-bit: a longer value keeps its low bytes, never an overflow.
        validity = message.option(Self.validityOption)?.unsignedValue.map { Self.validity(Int(UInt16(truncatingIfNeeded: $0))) }
        serial = message.option(Self.serialOption)?.unsignedValue.map { Int(UInt16(truncatingIfNeeded: $0)) }
        guard let payload = try? JSONValue(data: Data(message.payload)), case .array(let tuples) = payload["G"] ?? .null else { return nil }
        values = tuples.compactMap { tuple in
            guard let items = tuple.arrayValue, items.count >= 3, let id = items[1].intValue else { return nil }
            return (items[0].intValue ?? 0, id, items[2])
        }
    }

    /// Even: tenths of a second, floored to seconds; odd: units of 4 seconds.
    static func validity(_ raw: Int) -> Int { raw & 1 == 0 ? raw / 10 : raw * 4 }

    /// The GET `/cit/s` (or `/cit/d`) request aioshelly sends: NON, message id 10, no token, a zero-byte payload.
    static func request(path: String = "s") -> [UInt8] {
        CoAPMessage(type: .nonConfirmable, code: 1, messageID: 10, options: [
            .init(number: CoAPMessage.OptionNumber.uriPath, value: Array("cit".utf8)),
            .init(number: CoAPMessage.OptionNumber.uriPath, value: Array(path.utf8)),
        ], payload: [0]).encoded()
    }
}

/// Where CoIoT datagrams come from: the multicast socket, or a test's.
protocol CoIoTListener: Sendable {
    var datagrams: AsyncStream<(data: Data, address: String)> { get }
    func send(_ data: Data, to host: String, port: Int) async throws
    func close() async
}

extension UDPSocket: CoIoTListener {}

enum CoIoT {
    /// Joins the CoIoT group on port 5683, on the interface of `interfaceAddress` when given.
    static func listen(interfaceAddress: String?) async throws -> any CoIoTListener {
        try await UDPSocket.bind(port: CoIoTStatus.port, reuseAddress: true, multicastGroup: CoIoTStatus.multicastGroup,
                                 multicastInterface: interfaceAddress)
    }
}
