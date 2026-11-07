import Foundation
import HomeswiftNetwork
import NIOConcurrencyHelpers

/// A Bluetooth adapter in memory behind the `BLECentral` a plugin uses: a test advertises to the plugin's scan,
/// says how each peripheral answers a write, and reads what the plugin wrote. No radio.
///
/// ```swift
/// let central = FakeBLECentral()
/// central.respond(to: "aa:bb:cc:dd:ee:ff") { written in [0x01] }   // each write's notification
/// let plugin = MyPlugin(..., central: central)
/// central.advertise(BLEAdvertisement(identifier: "aa:bb:cc:dd:ee:ff", serviceData: ["fd3d": [0x54, 0x00, 0x64]], rssi: -60))
/// #expect(central.writes(to: "aa:bb:cc:dd:ee:ff").count == 1)
/// ```
public final class FakeBLECentral: BLECentral {
    /// What a peripheral sends back on its notifying characteristics for a write; nil sends nothing.
    public typealias Responder = @Sendable (_ written: [UInt8]) -> [UInt8]?

    public struct Write: Sendable, Equatable {
        public var characteristic: String
        public var value: [UInt8]
        public var withResponse: Bool
    }

    private struct State {
        var state = "poweredOn"
        var scanning: (services: [String], duplicates: Bool)?
        var onDiscover: (@Sendable (BLEAdvertisement) -> Void)?
        var scans = 0
        var connections = 0
        var disconnects = 0
        var unreachable: Set<String> = []
        var characteristics: [String: Set<String>] = [:]
        var responders: [String: Responder] = [:]
        var writes: [String: [Write]] = [:]
        var streams: [String: [String: AsyncStream<Data>.Continuation]] = [:]
    }

    private let box = NIOLockedValueBox(State())

    public init() {}

    // MARK: The test's side

    /// Sends an advertisement to the plugin's scan (when it scans for one of its services, or for everything).
    public func advertise(_ advertisement: BLEAdvertisement) {
        let handler = box.withLockedValue { state -> (@Sendable (BLEAdvertisement) -> Void)? in
            guard let scanning = state.scanning, let onDiscover = state.onDiscover else { return nil }
            let wanted = Set(scanning.services.map { $0.lowercased() })
            let carried = Set(advertisement.serviceUUIDs).union(advertisement.serviceData.keys)
            return wanted.isEmpty || !wanted.isDisjoint(with: carried) ? onDiscover : nil
        }
        handler?(advertisement)
    }

    /// The characteristics a peripheral has (every one asked for, when none are set).
    public func setCharacteristics(_ characteristics: [String], of peripheral: String) {
        box.withLockedValue { $0.characteristics[peripheral.lowercased()] = Set(characteristics.map { $0.lowercased() }) }
    }

    /// How a peripheral answers each write: on every characteristic the plugin listens to.
    public func respond(to peripheral: String, _ responder: @escaping Responder) {
        box.withLockedValue { $0.responders[peripheral.lowercased()] = responder }
    }

    /// Connections to the peripheral fail (it is out of range).
    public func setUnreachable(_ peripheral: String, _ unreachable: Bool = true) {
        box.withLockedValue {
            if unreachable { $0.unreachable.insert(peripheral.lowercased()) } else { $0.unreachable.remove(peripheral.lowercased()) }
        }
    }

    /// Sends a notification from a connected peripheral.
    public func notify(_ peripheral: String, characteristic: String, value: [UInt8]) {
        let stream = box.withLockedValue { $0.streams[peripheral.lowercased()]?[characteristic.lowercased()] }
        stream?.yield(Data(value))
    }

    public func setState(_ state: String) { box.withLockedValue { $0.state = state } }

    public func writes(to peripheral: String) -> [Write] { box.withLockedValue { $0.writes[peripheral.lowercased()] ?? [] } }
    public var isScanning: Bool { box.withLockedValue { $0.scanning != nil } }
    public var scannedServices: [String]? { box.withLockedValue { $0.scanning?.services } }
    public var scanCount: Int { box.withLockedValue { $0.scans } }
    public var connectionCount: Int { box.withLockedValue { $0.connections } }
    public var disconnectCount: Int { box.withLockedValue { $0.disconnects } }

    // MARK: BLECentral

    public var state: String { get async { box.withLockedValue { $0.state } } }

    public func waitForPoweredOn(timeout: Duration) async -> Bool { box.withLockedValue { $0.state == "poweredOn" } }

    public func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        box.withLockedValue {
            $0.scanning = (services, allowDuplicates)
            $0.onDiscover = onDiscover
            $0.scans += 1
        }
    }

    public func stopScanning() async {
        box.withLockedValue {
            $0.scanning = nil
            $0.onDiscover = nil
        }
    }

    public func connect(_ target: BLETarget) async throws -> any BLEConnection {
        let peripheral = (target.identifier ?? target.address).lowercased()
        let reachable = box.withLockedValue { state -> Bool in
            guard !state.unreachable.contains(peripheral) else { return false }
            state.connections += 1
            return true
        }
        guard reachable else { throw BLEError.notFound }
        return Connection(central: self, peripheral: peripheral)
    }

    // MARK: The connection

    struct Connection: BLEConnection {
        let central: FakeBLECentral
        let peripheral: String

        func discoverCharacteristic(_ uuid: String) async throws -> Bool {
            central.box.withLockedValue { $0.characteristics[peripheral]?.contains(uuid.lowercased()) ?? true }
        }

        func write(_ data: Data, to characteristic: String) async throws {
            central.record(peripheral, Write(characteristic: characteristic.lowercased(), value: Array(data), withResponse: false))
        }

        func writeWithResponse(_ data: Data, to characteristic: String) async throws {
            central.record(peripheral, Write(characteristic: characteristic.lowercased(), value: Array(data), withResponse: true))
        }

        func notifications(of characteristic: String) async throws -> AsyncStream<Data> {
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            central.box.withLockedValue { $0.streams[peripheral, default: [:]][characteristic.lowercased()] = continuation }
            return stream
        }

        func disconnect() async throws {
            let streams = central.box.withLockedValue { state -> [AsyncStream<Data>.Continuation] in
                state.disconnects += 1
                return Array((state.streams.removeValue(forKey: peripheral) ?? [:]).values)
            }
            for stream in streams { stream.finish() }
        }
    }

    private func record(_ peripheral: String, _ write: Write) {
        let (responder, streams) = box.withLockedValue { state -> (Responder?, [AsyncStream<Data>.Continuation]) in
            state.writes[peripheral, default: []].append(write)
            return (state.responders[peripheral], Array((state.streams[peripheral] ?? [:]).values))
        }
        guard let reply = responder?(write.value) else { return }
        for stream in streams { stream.yield(Data(reply)) }
    }
}
