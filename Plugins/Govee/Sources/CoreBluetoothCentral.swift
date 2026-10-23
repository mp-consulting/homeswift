#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import Foundation
import Logging

/// The Mac's Bluetooth adapter. CoreBluetooth hides MAC addresses, so a device is found by the name it
/// advertises (Govee's `bleName`, e.g. `ihoment_H6199_1A2B`) or, failing that, by a name ending in the last two
/// bytes of its MAC; sensor readings carry their name too.
final class CoreBluetoothCentral: NSObject, BLECentral, CBCentralManagerDelegate, @unchecked Sendable {
    /// How long a command looks for a device it has not seen advertise yet.
    static let searchTime: Duration = .seconds(6)

    private let queue = DispatchQueue(label: "homeswift.govee.ble")
    private var manager: CBCentralManager!
    private let logger: Logger

    // Everything below is touched on `queue` only.
    private var powerWaiters: [UUID: QueueWait<Bool>] = [:]
    private var onDiscover: (@Sendable (BLEAdvertisement) -> Void)?
    private var scanServices: [CBUUID]?
    private var searching: (match: @Sendable (CBPeripheral, String?) -> Bool, continuation: CheckedContinuation<Found, any Error>)?
    /// Named peripherals seen advertising, the latest `seenLimit` (a Mac nearby sees many, and their identifiers change).
    private var seen: [UUID: (peripheral: CBPeripheral, name: String)] = [:]
    private var seenOrder: [UUID] = []
    private var connecting: [UUID: QueueWait<Result<Void, any Error>>] = [:]
    private var connections: [UUID: CoreBluetoothConnection] = [:]

    static let seenLimit = 256
    static let usageDescriptionKey = "NSBluetoothAlwaysUsageDescription"

    /// Whether this process may use Bluetooth: macOS kills a process that does without a usage description in
    /// its Info.plist, so without one the plugin runs without BLE. The `homeswift` binary embeds one
    /// (Sources/HomeswiftCLI/Info.plist, in its `__TEXT,__info_plist` section), which `Bundle.main` reads.
    static var isPermitted: Bool { isPermitted(infoDictionary: Bundle.main.infoDictionary) }

    static func isPermitted(infoDictionary: [String: Any]?) -> Bool {
        (infoDictionary?[usageDescriptionKey] as? String).map { !$0.isEmpty } ?? false
    }

    /// A peripheral handed between tasks; CoreBluetooth objects are used on `queue` only.
    final class Found: @unchecked Sendable {
        let peripheral: CBPeripheral
        init(_ peripheral: CBPeripheral) { self.peripheral = peripheral }
    }

    init(logger: Logger) {
        self.logger = logger
        super.init()
        manager = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    var state: String {
        get async { await queue.run { Self.name(self.manager.state) } }
    }

    static func name(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "poweredOn"
        case .poweredOff: "poweredOff"
        case .resetting: "resetting"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .unknown: "unknown"
        @unknown default: "unknown"
        }
    }

    func waitForPoweredOn(timeout: Duration) async -> Bool {
        if await queue.run({ self.manager.state == .poweredOn }) { return true }
        let id = UUID()
        let powered = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Ends on power on, or when cancelled (the timeout won, or the caller was cancelled, even before this).
                let wait = QueueWait<Bool>(queue: self.queue)
                let powered = await wait.wait(cancelled: false) { wait in
                    if self.manager.state == .poweredOn { wait.resume(true) } else { self.powerWaiters[id] = wait }
                }
                await self.queue.run { self.powerWaiters[id] = nil }
                return powered
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !powered { logger.warning("[BLE] failed to power on adapter: timeout waiting for bluetooth adapter.") }
        return powered
    }

    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        await queue.run {
            self.onDiscover = onDiscover
            self.scanServices = services.map { CBUUID(string: $0) }
            // A device search (find) scans for every peripheral, and goes back to this scan when it ends: starting
            // this one now would hide the device it looks for.
            guard self.searching == nil else { return }
            self.manager.scanForPeripherals(withServices: self.scanServices, options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates])
        }
    }

    func stopScanning() async {
        await queue.run {
            self.onDiscover = nil
            self.scanServices = nil
            if self.searching == nil { self.manager.stopScan() }
        }
    }

    func reset() async {}

    func connect(_ target: BLETarget) async throws -> any BLEConnection {
        let found = try await find(target)
        let handle = Unchecked(value: found.peripheral)
        // CoreBluetooth never gives up on a connection: it ends when the device answers or the caller is cancelled.
        let wait = QueueWait<Result<Void, any Error>>(queue: queue)
        let result = await wait.wait(cancelled: .failure(CancellationError())) { wait in
            self.connecting[handle.value.identifier] = wait
            self.manager.connect(handle.value)
        }
        await queue.run {
            // Still listed: it did not connect (cancelled), so the attempt is called off.
            guard self.connecting[handle.value.identifier] === wait else { return }
            self.connecting[handle.value.identifier] = nil
            self.manager.cancelPeripheralConnection(handle.value)
        }
        try result.get()
        let peripheral = found.peripheral
        let connection = CoreBluetoothConnection(peripheral: peripheral, queue: queue) { [weak self] peripheral in
            self?.manager.cancelPeripheralConnection(peripheral)
        }
        await queue.run { self.connections[peripheral.identifier] = connection }
        return connection
    }

    /// A peripheral seen advertising the target's name, or one found by scanning for it.
    private func find(_ target: BLETarget) async throws -> Found {
        let suffix = target.address.replacingOccurrences(of: ":", with: "").suffix(4).uppercased()
        let match: @Sendable (CBPeripheral, String?) -> Bool = { _, name in
            guard let name else { return false }
            if let wanted = target.name, !wanted.isEmpty { return name.caseInsensitiveCompare(wanted) == .orderedSame }
            return suffix.count == 4 && name.uppercased().hasSuffix(suffix)
        }
        if let known = await queue.run({ self.seen.values.first { match($0.peripheral, $0.name) }.map { Found($0.peripheral) } }) { return known }
        return try await withThrowingTaskGroup(of: Found.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        self.queue.async {
                            self.searching = (match, continuation)
                            self.manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                        }
                    }
                } onCancel: {
                    self.queue.async {
                        self.searching?.continuation.resume(throwing: CancellationError())
                        self.searching = nil
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.searchTime)
                throw BLEError.notFound
            }
            defer {
                group.cancelAll()
                queue.async {
                    self.searching?.continuation.resume(throwing: BLEError.notFound)
                    self.searching = nil
                    if let services = self.scanServices {
                        self.manager.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                    } else {
                        self.manager.stopScan()
                    }
                }
            }
            return try await group.next()!
        }
    }

    // MARK: CBCentralManagerDelegate (on `queue`)

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logger.debug("[BLE] adapter state changed to: \(Self.name(central.state)).")
        if central.state == .poweredOn {
            let waiters = powerWaiters.values
            powerWaiters.removeAll()
            for waiter in waiters { waiter.resume(true) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        // Only a name finds a device again.
        if let name, seen.updateValue((peripheral, name), forKey: peripheral.identifier) == nil {
            seenOrder.append(peripheral.identifier)
            if seenOrder.count > Self.seenLimit { seen[seenOrder.removeFirst()] = nil }
        }
        if let searching, searching.match(peripheral, name) {
            self.searching = nil
            searching.continuation.resume(returning: Found(peripheral))
        }
        guard let onDiscover else { return }
        let data = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map(Array.init)
        onDiscover(BLEAdvertisement(identifier: peripheral.identifier.uuidString, address: nil, localName: name, manufacturerData: data, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connecting.removeValue(forKey: peripheral.identifier)?.resume(.success(()))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        connecting.removeValue(forKey: peripheral.identifier)?.resume(.failure(error ?? BLEError.unavailable("could not connect")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        connecting.removeValue(forKey: peripheral.identifier)?.resume(.failure(error ?? BLEError.unavailable("disconnected")))
        connections.removeValue(forKey: peripheral.identifier)?.didDisconnect(error)
    }
}

extension DispatchQueue {
    /// Runs `body` on the queue, waiting without blocking the caller's thread.
    fileprivate func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in async { continuation.resume(returning: body()) } }
    }
}

/// A CoreBluetooth object handed between tasks; it is used on the queue only.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// One connected peripheral: discovers its characteristics and writes to the control one.
final class CoreBluetoothConnection: NSObject, BLEConnection, CBPeripheralDelegate, @unchecked Sendable {
    private let peripheral: CBPeripheral
    private let queue: DispatchQueue
    private let cancel: (CBPeripheral) -> Void
    // On `queue` only.
    private var discovery: CheckedContinuation<Void, any Error>?
    private var pendingServices = 0
    private var characteristics: [String: CBCharacteristic] = [:]
    private var readyWaiter: CheckedContinuation<Void, Never>?
    private var disconnectWaiter: CheckedContinuation<Void, any Error>?

    init(peripheral: CBPeripheral, queue: DispatchQueue, cancel: @escaping (CBPeripheral) -> Void) {
        self.peripheral = peripheral
        self.queue = queue
        self.cancel = cancel
        super.init()
        queue.sync { peripheral.delegate = self }
    }

    static func key(_ uuid: CBUUID) -> String { uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    func discoverCharacteristic(_ uuid: String) async throws -> Bool {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    self.discovery = continuation
                    self.peripheral.discoverServices(nil)
                }
            }
        } onCancel: {
            queue.async {
                self.discovery?.resume(throwing: CancellationError())
                self.discovery = nil
            }
        }
        return await queue.run { self.characteristics[uuid.lowercased()] != nil }
    }

    func write(_ data: Data, to characteristic: String) async throws {
        guard let target = await queue.run({ self.characteristics[characteristic.lowercased()].map(Unchecked.init) }) else { throw BLEError.noCharacteristic }
        if await !queue.run({ self.peripheral.canSendWriteWithoutResponse }) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    queue.async {
                        if self.peripheral.canSendWriteWithoutResponse { continuation.resume() } else { self.readyWaiter = continuation }
                    }
                }
            } onCancel: {
                queue.async {
                    self.readyWaiter?.resume()
                    self.readyWaiter = nil
                }
            }
            try Task.checkCancellation()
        }
        await queue.run { self.peripheral.writeValue(data, for: target.value, type: .withoutResponse) }
    }

    func disconnect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    guard self.peripheral.state != .disconnected else {
                        continuation.resume()
                        return
                    }
                    self.disconnectWaiter = continuation
                    self.cancel(self.peripheral)
                }
            }
        } onCancel: {
            queue.async {
                self.disconnectWaiter?.resume(throwing: CancellationError())
                self.disconnectWaiter = nil
            }
        }
    }

    /// From the central's delegate, on `queue`.
    func didDisconnect(_ error: (any Error)?) {
        disconnectWaiter?.resume()
        disconnectWaiter = nil
        discovery?.resume(throwing: error ?? BLEError.unavailable("disconnected"))
        discovery = nil
        readyWaiter?.resume()
        readyWaiter = nil
    }

    // MARK: CBPeripheralDelegate (on `queue`)

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let services = peripheral.services ?? []
        if let error {
            discovery?.resume(throwing: error)
            discovery = nil
            return
        }
        guard !services.isEmpty else {
            discovery?.resume()
            discovery = nil
            return
        }
        pendingServices = services.count
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        for characteristic in service.characteristics ?? [] { characteristics[Self.key(characteristic.uuid)] = characteristic }
        pendingServices -= 1
        if pendingServices <= 0 {
            discovery?.resume()
            discovery = nil
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        readyWaiter?.resume()
        readyWaiter = nil
    }
}
#endif
