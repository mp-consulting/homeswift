import Foundation
import Logging
import NIOConcurrencyHelpers
#if canImport(Glibc)
import Glibc
#endif

/// An advertisement a scan saw.
public struct BLEAdvertisement: Sendable, Equatable {
    /// The system's identifier for the peripheral (CoreBluetooth's UUID, the MAC address on Linux).
    public var identifier: String
    /// The MAC address, where the system gives it (Linux; not macOS).
    public var address: String?
    public var localName: String?
    /// Company id first, as noble and the vendors' apps see it.
    public var manufacturerData: [UInt8]?
    /// The service UUIDs it lists: four lower-case hex digits for a 16-bit UUID, 32 for the others.
    public var serviceUUIDs: [String]
    /// Service data by service UUID, written as `serviceUUIDs` are (`fd3d`).
    public var serviceData: [String: [UInt8]]
    public var rssi: Int

    public init(
        identifier: String, address: String? = nil, localName: String? = nil, manufacturerData: [UInt8]? = nil,
        serviceUUIDs: [String] = [], serviceData: [String: [UInt8]] = [:], rssi: Int
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.identifier = identifier
        self.address = address
        self.localName = localName
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.rssi = rssi
    }
}

/// Where a peripheral is: its MAC, which Linux connects to, and the name it advertises, which is how macOS (which
/// hides MAC addresses) finds it; on macOS an `identifier` a scan reported finds it first.
public struct BLETarget: Sendable, Equatable {
    public var address: String
    public var name: String?
    /// The system's identifier from an advertisement (CoreBluetooth's UUID); nil when only the MAC is known.
    public var identifier: String?

    public init(address: String, name: String? = nil, identifier: String? = nil) {
        self.address = address
        self.name = name
        self.identifier = identifier
    }
}

/// The Bluetooth adapter: CoreBluetooth on macOS, a raw HCI socket on Linux, a fake in tests
/// (`HomeswiftNetworkTestSupport`'s `FakeBLECentral`).
public protocol BLECentral: Sendable {
    /// `poweredOn`, `poweredOff`, `unauthorized`, `unsupported`…
    var state: String { get async }
    func waitForPoweredOn(timeout: Duration) async -> Bool
    /// Starts scanning for peripherals advertising any of these service UUIDs (every peripheral when empty); every
    /// advertisement goes to `onDiscover`.
    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws
    func stopScanning() async
    /// Connects to the peripheral, finding it by identifier, address or advertised name.
    func connect(_ target: BLETarget) async throws -> any BLEConnection
}

/// A connection to one peripheral. Characteristic UUIDs are 128-bit without dashes, or four hex digits for one on
/// the Bluetooth base UUID; lower case.
public protocol BLEConnection: Sendable {
    /// Discovers services and characteristics; whether the one with this UUID exists.
    func discoverCharacteristic(_ uuid: String) async throws -> Bool
    /// Writes without response.
    func write(_ data: Data, to characteristic: String) async throws
    /// Writes with a response (an ATT Write Request), ending when the peripheral acknowledged it.
    func writeWithResponse(_ data: Data, to characteristic: String) async throws
    /// Turns on notifications (or indications) of a characteristic; its values arrive on the stream until the
    /// connection ends.
    func notifications(of characteristic: String) async throws -> AsyncStream<Data>
    func disconnect() async throws
}

extension BLEConnection {
    public func writeWithResponse(_ data: Data, to characteristic: String) async throws {
        throw BLEError.unavailable("writes with response are not supported")
    }

    public func notifications(of characteristic: String) async throws -> AsyncStream<Data> {
        throw BLEError.unavailable("notifications are not supported")
    }
}

public enum BLEError: Error, CustomStringConvertible, Equatable {
    case timeout(String)
    case wrongState(String)
    case notFound
    case noCharacteristic
    case unavailable(String)

    public var description: String {
        switch self {
        case .timeout(let message): message
        case .wrongState(let state): "BLE adapter not in correct state [\(state)]"
        case .notFound: "device not found nearby"
        case .noCharacteristic: "Control characteristic not found"
        case .unavailable(let reason): reason
        }
    }
}

/// The system's Bluetooth adapter, for every plugin that uses Bluetooth.
public enum Bluetooth {
    /// CoreBluetooth on a Mac whose binary may use Bluetooth; on Linux a raw HCI socket on `hci<device>` (the
    /// adapter `NOBLE_HCI_DEVICE_ID` names, hci0 by default, as noble chose it for Homebridge plugins). Nil, with
    /// the reason logged, when this process may not use Bluetooth; throws when there is no adapter.
    ///
    /// macOS grants Bluetooth only to a binary whose Info.plist describes the use, and it asks the *responsible*
    /// process: `homeswift` started from a shell inherits the app that started the shell. Without a usage
    /// description there, the first Bluetooth call would abort the whole bridge, so Bluetooth stays off and the log
    /// names the app.
    public static func systemCentral(logger: Logger) throws -> (any BLECentral)? {
        #if canImport(CoreBluetooth)
        guard CoreBluetoothCentral.isPermitted(infoDictionary: Bundle.main.infoDictionary) else {
            logger.info("[BLE] Bluetooth needs NSBluetoothAlwaysUsageDescription in the homeswift binary's Info.plist")
            return nil
        }
        if let app = CoreBluetoothCentral.responsibleApp, !CoreBluetoothCentral.isPermitted(infoDictionary: app.infoDictionary) {
            logger.warning("[BLE] disabled: macOS holds \(app.path) responsible for homeswift, and it declares no Bluetooth use. Run homeswift on its own (launchd, brew services) or from a terminal that does, to use Bluetooth.")
            return nil
        }
        return shared.central(logger: logger)
        #elseif os(Linux)
        let device = ProcessInfo.processInfo.environment["NOBLE_HCI_DEVICE_ID"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        return try shared.central(device: device, logger: logger)
        #else
        return nil
        #endif
    }

    /// Whether an error from `systemCentral` means the system has no Bluetooth at all (no hardware or driver).
    public static func isMissing(_ error: any Error) -> Bool {
        #if os(Linux)
        return (error as? SocketError)?.code == EAFNOSUPPORT
        #else
        return false
        #endif
    }

    /// One adapter per process, which plugins share as they share the radio: a second HCI socket would turn off a
    /// scan the first one started, and each plugin's scan is one subscription to the hub's single scan.
    private static let shared = SharedAdapter()

    private final class SharedAdapter: @unchecked Sendable {
        private let lock = NSLock()
        private var hub: BLEScanHub?

        #if canImport(CoreBluetooth)
        func central(logger: Logger) -> any BLECentral {
            lock.withLock {
                let hub = self.hub ?? BLEScanHub(base: CoreBluetoothCentral(logger: logger))
                self.hub = hub
                return SharedBLECentral(hub: hub)
            }
        }
        #elseif os(Linux)
        func central(device: Int, logger: Logger) throws -> any BLECentral {
            try lock.withLock {
                if let hub, (hub.base as? LinuxBluetoothCentral)?.deviceID == device { return SharedBLECentral(hub: hub) }
                let hub = BLEScanHub(base: try LinuxBluetoothCentral(deviceID: device, logger: logger))
                self.hub = hub
                return SharedBLECentral(hub: hub)
            }
        }
        #endif
    }
}

/// One adapter's scan shared by several scanners: it scans for the union of their services (every peripheral when one
/// of them wants every one), with duplicates when one of them does, and hands each scanner the advertisements it asked
/// for, in the order the adapter reported them. Connections go one at a time, whichever plugin asks: each central has
/// a single search for a peripheral to connect to.
public final class BLEScanHub: Sendable {
    public let base: any BLECentral
    private let scanners = NIOLockedValueBox<[UUID: Scanner]>([:])
    private let changes = AsyncLock()
    private let connects = AsyncLock()
    private let scanning = NIOLockedValueBox<(services: Set<String>, duplicates: Bool)?>(nil)

    private struct Scanner {
        var services: Set<String>
        var duplicates: Bool
        var onDiscover: @Sendable (BLEAdvertisement) -> Void
    }

    public init(base: any BLECentral) { self.base = base }

    func start(_ id: UUID, services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        try await changes.run {
            self.scanners.withLockedValue { $0[id] = Scanner(services: Set(services.map { $0.lowercased() }), duplicates: allowDuplicates, onDiscover: onDiscover) }
            do {
                try await self.rescan()
            } catch {
                self.scanners.withLockedValue { $0[id] = nil }
                throw error
            }
        }
    }

    func stop(_ id: UUID) async {
        await changes.locked {
            guard self.scanners.withLockedValue({ $0.removeValue(forKey: id) }) != nil else { return }
            try? await self.rescan()
        }
    }

    func connect(_ target: BLETarget) async throws -> any BLEConnection {
        try await connects.run { try await self.base.connect(target) }
    }

    /// Starts, changes or stops the adapter's scan to cover every scanner.
    private func rescan() async throws {
        let current = scanners.withLockedValue { Array($0.values) }
        guard !current.isEmpty else {
            if scanning.withLockedValue({ $0 }) != nil {
                scanning.withLockedValue { $0 = nil }
                await base.stopScanning()
            }
            return
        }
        let everything = current.contains { $0.services.isEmpty }
        let services = everything ? Set<String>() : current.reduce(into: Set<String>()) { $0.formUnion($1.services) }
        let duplicates = current.contains { $0.duplicates }
        if let now = scanning.withLockedValue({ $0 }), now.services == services, now.duplicates == duplicates { return }
        scanning.withLockedValue { $0 = (services, duplicates) }
        try await base.startScanning(services: services.sorted(), allowDuplicates: duplicates) { [weak self] advertisement in
            self?.deliver(advertisement)
        }
    }

    /// On the adapter's callback, in its order.
    private func deliver(_ advertisement: BLEAdvertisement) {
        let current = scanners.withLockedValue { Array($0.values) }
        var carried: Set<String>?
        for scanner in current {
            if !scanner.services.isEmpty {
                let services = carried ?? Set(advertisement.serviceUUIDs.map { $0.lowercased() }).union(advertisement.serviceData.keys)
                carried = services
                guard !scanner.services.isDisjoint(with: services) else { continue }
            }
            scanner.onDiscover(advertisement)
        }
    }
}

/// A lock for async work: one body at a time, in the order they asked; a waiter cancelled before its turn throws.
final class AsyncLock: Sendable {
    private let state = NIOLockedValueBox<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    func locked(_ body: @Sendable () async -> Void) async {
        await acquire()
        defer { release() }
        await body()
    }

    private func acquire() async {
        await withCheckedContinuation { continuation in
            let now = state.withLockedValue { state -> Bool in
                if state.busy {
                    state.waiters.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if now { continuation.resume() }
        }
    }

    private func release() {
        let next = state.withLockedValue { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.busy = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}

/// One plugin's handle on the shared adapter.
struct SharedBLECentral: BLECentral {
    let hub: BLEScanHub
    let id = UUID()

    var state: String { get async { await hub.base.state } }
    func waitForPoweredOn(timeout: Duration) async -> Bool { await hub.base.waitForPoweredOn(timeout: timeout) }
    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        try await hub.start(id, services: services, allowDuplicates: allowDuplicates, onDiscover: onDiscover)
    }
    func stopScanning() async { await hub.stop(id) }
    func connect(_ target: BLETarget) async throws -> any BLEConnection { try await hub.connect(target) }
}

/// A wait for a callback that arrives on a serial queue (CoreBluetooth's delegate), which cancelling the waiting
/// task ends with `cancelled`, also when the task was cancelled before the wait was parked: then
/// `withTaskCancellationHandler` runs its handler before the operation, and a wait parked after it would never end.
final class QueueWait<Value: Sendable>: @unchecked Sendable {
    private let queue: DispatchQueue
    // On `queue` only.
    private var continuation: CheckedContinuation<Value, Never>?
    private var result: Value?

    init(queue: DispatchQueue) { self.queue = queue }

    /// Waits until `resume(_:)`. `park` runs on the queue first, to register the wait where the callback finds it,
    /// or to resume it at once; it is skipped when the wait already ended.
    func wait(cancelled: Value, park: @escaping @Sendable (QueueWait<Value>) -> Void) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(returning: result)
                    } else {
                        self.continuation = continuation
                        park(self)
                    }
                }
            }
        } onCancel: {
            queue.async { self.resume(cancelled) }
        }
    }

    /// Ends the wait with `value`, on the queue; later calls change nothing.
    func resume(_ value: Value) {
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: value)
        } else if result == nil {
            result = value
        }
    }
}
