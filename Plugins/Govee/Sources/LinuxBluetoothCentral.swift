#if os(Linux)
import Foundation
import Glibc
import Logging

/// Linux's Bluetooth adapter, reached as noble reaches it on Linux (`@stoprocent/noble`'s hci-socket bindings,
/// which the Homebridge plugin used): a raw HCI socket on `hci<NOBLE_HCI_DEVICE_ID>` (hci0 by default) scans for
/// advertisements, and a connection is the kernel's L2CAP socket on the ATT channel, which noble's raw-channel
/// bindings open for each LE connection too; ATT runs on that socket here. Devices are found by MAC address.
///
/// The controller is not reset (noble resets it, which drops the connections BlueZ holds). Scanning needs
/// `CAP_NET_RAW` (root, or `setcap cap_net_raw,cap_net_admin+eip` on the binary), as noble's Node binary does.
final class LinuxBluetoothCentral: BLECentral, @unchecked Sendable {
    /// How long a connection waits for a device it has not seen advertise, to learn its address type.
    static let searchTime: Duration = .seconds(4)
    static let commandTimeout: Duration = .seconds(2)

    let deviceID: Int
    private let socket: HCISocket
    private let logger: Logger
    private let lock = NSLock()
    // Under `lock`.
    private var onDiscover: (@Sendable (BLEAdvertisement) -> Void)?
    private var scanServices: Set<String> = []
    private var searching: (address: String, continuation: CheckedContinuation<Bool, Never>)?
    private var cache = AdvertisementCache()
    private var waiters: [UUID: (opcode: UInt16, continuation: CheckedContinuation<(status: UInt8, parameters: [UInt8])?, Never>)] = [:]
    private var extended = false
    private var localAddress: [UInt8]?
    private var lastError: Int32?

    /// Opens the raw socket on `hci<deviceID>`; throws when there is no Bluetooth (`Address family not
    /// supported by protocol`) or no such adapter.
    init(deviceID: Int, logger: Logger) throws {
        self.deviceID = deviceID
        self.logger = logger
        socket = try HCISocket(device: deviceID)
        socket.start { [weak self] packet in self?.handle(packet) }
    }

    deinit { socket.close() }

    // MARK: State

    var state: String {
        get async {
            if await isPoweredOn() { return "poweredOn" }
            return lock.withLock {
                switch lastError {
                case EPERM?, EACCES?: "unauthorized"
                default: "poweredOff"
                }
            }
        }
    }

    /// The adapter answers Read BD_ADDR (which also gives the address connections bind to) once it is up.
    private func isPoweredOn() async -> Bool {
        guard let reply = await command(HCI.command(HCI.readBDAddr)), reply.status == 0 else { return false }
        if reply.parameters.count >= 6 { lock.withLock { localAddress = Array(reply.parameters.prefix(6)) } }
        return true
    }

    func waitForPoweredOn(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if await isPoweredOn() { return true }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        logger.warning("[BLE] failed to power on adapter: timeout waiting for bluetooth adapter.")
        return false
    }

    // MARK: Scanning

    func startScanning(services: [String], allowDuplicates: Bool, onDiscover: @escaping @Sendable (BLEAdvertisement) -> Void) async throws {
        let searchRunning = lock.withLock { () -> Bool in
            self.onDiscover = onDiscover
            scanServices = Set(services.map { $0.lowercased() })
            return searching != nil
        }
        // A device search scans already, and leaves the scan on when it ends.
        guard !searchRunning else { return }
        try await enableScan(filterDuplicates: !allowDuplicates)
    }

    func stopScanning() async {
        let searchRunning = lock.withLock { () -> Bool in
            onDiscover = nil
            scanServices = []
            return searching != nil
        }
        guard !searchRunning else { return }
        await disableScan()
    }

    func reset() async {}

    /// Disable, set the parameters, enable, as noble's `startScanning`; with the extended commands when the
    /// controller refuses the legacy ones.
    private func enableScan(filterDuplicates: Bool) async throws {
        var extended = lock.withLock { self.extended }
        _ = await command(HCI.setScanEnable(false, filterDuplicates: true, extended: extended))
        let parameters = try await required(HCI.setScanParameters(extended: extended))
        if !extended, parameters == HCI.unknownCommand || parameters == HCI.commandDisallowed {
            _ = await command(HCI.setScanEnable(false, filterDuplicates: true, extended: true))
            if await command(HCI.setScanParameters(extended: true))?.status == 0 {
                extended = true
                lock.withLock { self.extended = true }
            }
        }
        let status = try await required(HCI.setScanEnable(true, filterDuplicates: filterDuplicates, extended: extended))
        // Command disallowed: the controller scans already (BlueZ's own scan), and its reports reach this socket too.
        guard status == 0 || status == HCI.commandDisallowed else {
            throw BLEError.unavailable(String(format: "the adapter refused to scan (HCI status 0x%02x)", status))
        }
    }

    private func disableScan() async {
        _ = await command(HCI.setScanEnable(false, filterDuplicates: true, extended: lock.withLock { extended }))
    }

    // MARK: Connections

    func connect(_ target: BLETarget) async throws -> any BLEConnection {
        guard let address = BluetoothAddress.normalized(target.address), let peer = BluetoothAddress.bytes(address) else {
            throw BLEError.unavailable("invalid Bluetooth address [\(target.address)]")
        }
        var random = lock.withLock { cache.entries[address]?.randomAddress }
        if random == nil, await search(address) { random = lock.withLock { cache.entries[address]?.randomAddress } }
        if lock.withLock({ localAddress }) == nil { _ = await isPoweredOn() }
        let local = lock.withLock { localAddress } ?? [0, 0, 0, 0, 0, 0]
        return try await L2CAPConnection.connect(local: local, peer: peer, random: random ?? BluetoothAddress.looksRandom(address))
    }

    /// Scans until the device advertises (or `searchTime` passes), then puts the scan back as it was.
    private func search(_ address: String) async -> Bool {
        let wasScanning = lock.withLock { onDiscover != nil }
        if !wasScanning {
            do {
                try await enableScan(filterDuplicates: false)
            } catch {
                logger.debug("[BLE] could not scan for \(address): \(error)")
                return false
            }
        }
        let found = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        self.lock.withLock {
                            if self.cache.entries[address] != nil || Task.isCancelled || self.searching != nil {
                                continuation.resume(returning: self.cache.entries[address] != nil)
                            } else {
                                self.searching = (address, continuation)
                            }
                        }
                    }
                } onCancel: {
                    self.lock.withLock {
                        self.searching?.continuation.resume(returning: false)
                        self.searching = nil
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: Self.searchTime)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if !lock.withLock({ onDiscover != nil }) { await disableScan() }
        return found
    }

    // MARK: Packets (on the socket's thread)

    private func handle(_ packet: [UInt8]) {
        guard let event = HCI.parse(packet) else { return }
        switch event {
        case .commandComplete(let opcode, let status, let parameters):
            complete(opcode, (status, parameters))
        case .commandStatus(let opcode, let status):
            // A command that fails at once ends with its status; one that succeeds completes later.
            if status != 0 { complete(opcode, (status, [])) }
        case .advertisingReports(let reports):
            for report in reports {
                let delivery = lock.withLock { () -> (@Sendable (BLEAdvertisement) -> Void, BLEAdvertisement)? in
                    let entry = cache.add(report)
                    if let searching, searching.address == report.address {
                        self.searching = nil
                        searching.continuation.resume(returning: true)
                    }
                    guard let onDiscover, entry.data.advertises(anyOf: scanServices) else { return nil }
                    return (onDiscover, BLEAdvertisement(
                        identifier: report.address, address: report.address, localName: entry.data.localName,
                        manufacturerData: entry.data.manufacturerData, rssi: entry.rssi))
                }
                if let delivery { delivery.0(delivery.1) }
            }
        }
    }

    private func complete(_ opcode: UInt16, _ reply: (status: UInt8, parameters: [UInt8])) {
        lock.withLock {
            guard let id = waiters.first(where: { $0.value.opcode == opcode })?.key else { return }
            waiters.removeValue(forKey: id)?.continuation.resume(returning: reply)
        }
    }

    // MARK: Commands

    /// Sends a command and waits for its completion; nil when it could not be sent or got no answer in time.
    private func command(_ packet: [UInt8]) async -> (status: UInt8, parameters: [UInt8])? {
        let opcode = UInt16(packet[1]) | UInt16(packet[2]) << 8
        let id = UUID()
        return await withCheckedContinuation { continuation in
            lock.withLock { waiters[id] = (opcode, continuation) }
            do {
                try socket.write(packet)
                lock.withLock { lastError = nil }
            } catch {
                lock.withLock {
                    lastError = (error as? SocketError)?.code
                    waiters.removeValue(forKey: id)?.continuation.resume(returning: nil)
                }
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: Self.commandTimeout)
                self?.lock.withLock { self?.waiters.removeValue(forKey: id)?.continuation.resume(returning: nil) }
            }
        }
    }

    /// A command's status; throws when it could not be sent or the adapter did not answer.
    private func required(_ packet: [UInt8]) async throws -> UInt8 {
        if let reply = await command(packet) { return reply.status }
        if let code = lock.withLock({ lastError }) {
            let failure = SocketError(call: "write", code: code)
            throw BLEError.unavailable(code == EPERM ? "\(failure) (homeswift needs CAP_NET_RAW to scan)" : "\(failure)")
        }
        throw BLEError.timeout("no answer from hci\(deviceID)")
    }
}

/// A failed system call, with the system's message (`Address family not supported by protocol`).
struct SocketError: Error, CustomStringConvertible {
    let call: String
    let code: Int32

    init(call: String, code: Int32 = errno) {
        self.call = call
        self.code = code
    }

    var description: String { "\(call): \(String(cString: strerror(code)))" }
}

/// The raw HCI socket and the thread that reads it; `close()` ends the thread, which closes the socket.
final class HCISocket: @unchecked Sendable {
    let descriptor: Int32
    private let lock = NSLock()
    private var isOpen = true

    init(device: Int) throws {
        let descriptor = Glibc.socket(Int32(BluetoothSocketAddress.family), Int32(SOCK_RAW.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 1 /* BTPROTO_HCI */)
        guard descriptor >= 0 else { throw SocketError(call: "socket") }
        do {
            try withSocketAddress(BluetoothSocketAddress.hci(device: UInt16(clamping: device))) { address, length in
                guard Glibc.bind(descriptor, address, length) == 0 else { throw SocketError(call: "bind hci\(device)") }
            }
            let filter = HCI.socketFilter
            let result = filter.withUnsafeBytes { Glibc.setsockopt(descriptor, 0 /* SOL_HCI */, 2 /* HCI_FILTER */, $0.baseAddress, socklen_t($0.count)) }
            guard result == 0 else { throw SocketError(call: "setsockopt HCI_FILTER") }
        } catch {
            Glibc.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    func start(_ handler: @escaping @Sendable ([UInt8]) -> Void) {
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 1024)
            while lock.withLock({ isOpen }) {
                var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard Glibc.poll(&entry, 1, 500) > 0 else { continue }
                let count = buffer.withUnsafeMutableBytes { Glibc.read(descriptor, $0.baseAddress, $0.count) }
                if count > 0 {
                    handler(Array(buffer.prefix(count)))
                } else if count < 0, errno != EINTR, errno != EAGAIN {
                    // The adapter went away (ENODEV) or down: keep polling, it may come back.
                    Thread.sleep(forTimeInterval: 0.5)
                }
            }
            Glibc.close(descriptor)
        }
        thread.name = "homeswift.govee.hci"
        thread.start()
    }

    func write(_ packet: [UInt8]) throws {
        let written = packet.withUnsafeBytes { Glibc.write(descriptor, $0.baseAddress, $0.count) }
        guard written == packet.count else { throw SocketError(call: "write") }
    }

    func close() { lock.withLock { isOpen = false } }
}

/// Runs `body` with `bytes` as a `sockaddr`.
private func withSocketAddress<T>(_ bytes: [UInt8], _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { $0.copyBytes(from: bytes) }
    return try withUnsafePointer(to: &storage) { pointer in
        try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(bytes.count)) }
    }
}

/// Set by a task's cancellation, read by the blocking work it started.
private final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// An LE connection: the kernel's L2CAP socket on the ATT channel (the kernel creates the LE link when it
/// connects), and ATT on it: characteristic discovery and write commands. The peripheral's own PDUs are answered
/// (MTU requests, indications) or dropped (notifications) while reading a response and before each write.
final class L2CAPConnection: BLEConnection, @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "homeswift.govee.att")
    // On `queue`.
    private var handles: [String: UInt16] = [:]
    private var closed = false

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { if !closed { Glibc.close(descriptor) } }

    static func connect(local: [UInt8], peer: [UInt8], random: Bool) async throws -> L2CAPConnection {
        let type = Int32(SOCK_SEQPACKET.rawValue) | Int32(SOCK_NONBLOCK.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        let descriptor = Glibc.socket(Int32(BluetoothSocketAddress.family), type, 0 /* BTPROTO_L2CAP */)
        guard descriptor >= 0 else { throw SocketError(call: "socket") }
        let connection = L2CAPConnection(descriptor: descriptor)
        try withSocketAddress(BluetoothSocketAddress.l2cap(address: local, random: false)) { address, length in
            guard Glibc.bind(descriptor, address, length) == 0 else { throw SocketError(call: "bind") }
        }
        try withSocketAddress(BluetoothSocketAddress.l2cap(address: peer, random: random)) { address, length in
            guard Glibc.connect(descriptor, address, length) == 0 || errno == EINPROGRESS else { throw SocketError(call: "connect") }
        }
        try await connection.run { cancellation in
            try connection.wait(for: Int16(POLLOUT), cancellation)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard Glibc.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0 else { throw SocketError(call: "getsockopt") }
            guard failure == 0 else { throw SocketError(call: "connect", code: failure) }
        }
        return connection
    }

    func discoverCharacteristic(_ uuid: String) async throws -> Bool {
        try await run { cancellation in
            var discovery = CharacteristicDiscovery()
            while let request = discovery.request {
                if cancellation.isCancelled { throw CancellationError() }
                try self.send(request, cancellation)
                try discovery.receive(self.response(cancellation))
            }
            for characteristic in discovery.characteristics { self.handles[characteristic.uuid] = characteristic.valueHandle }
            return self.handles[uuid.lowercased()] != nil
        }
    }

    func write(_ data: Data, to characteristic: String) async throws {
        try await run { cancellation in
            guard let handle = self.handles[characteristic.lowercased()] else { throw BLEError.noCharacteristic }
            // The default MTU, which this client never raises: Govee's frames are 20 bytes.
            guard data.count <= ATT.defaultMTU - 3 else { throw BLEError.unavailable("frame of \(data.count) bytes exceeds the ATT MTU") }
            try self.drain(cancellation)
            try self.send(ATT.write(handle: handle, value: Array(data)), cancellation)
        }
    }

    func disconnect() async throws {
        try await run(open: false) { _ in
            guard !self.closed else { return }
            self.closed = true
            Glibc.close(self.descriptor)
        }
    }

    // MARK: On `queue`

    /// Runs blocking socket work on the connection's queue, on an open socket unless `open` is false; cancelling
    /// the task ends its waits.
    private func run<T: Sendable>(open: Bool = true, _ body: @escaping @Sendable (Cancellation) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !open || !self.closed else {
                        continuation.resume(throwing: BLEError.unavailable("disconnected"))
                        return
                    }
                    continuation.resume(with: Result { try body(cancellation) })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func wait(for events: Int16, _ cancellation: Cancellation) throws {
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            var entry = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Glibc.poll(&entry, 1, 100)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw SocketError(call: "poll") }
        }
    }

    private func send(_ pdu: [UInt8], _ cancellation: Cancellation) throws {
        while true {
            let sent = pdu.withUnsafeBytes { Glibc.send(descriptor, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
            if sent == pdu.count { return }
            guard sent < 0, errno == EAGAIN || errno == EINTR else { throw SocketError(call: "send") }
            try wait(for: Int16(POLLOUT), cancellation)
        }
    }

    /// One PDU; nil when none is waiting and `block` is false.
    private func receive(_ cancellation: Cancellation, block: Bool = true) throws -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.recv(descriptor, $0.baseAddress, $0.count, 0) }
            if count > 0 { return Array(buffer.prefix(count)) }
            if count == 0 { throw BLEError.unavailable("disconnected") }
            guard errno == EAGAIN || errno == EINTR else { throw SocketError(call: "recv") }
            guard block else { return nil }
            try wait(for: Int16(POLLIN), cancellation)
        }
    }

    /// The response to the request just sent, answering what the peripheral sends meanwhile.
    private func response(_ cancellation: Cancellation) throws -> [UInt8] {
        while true {
            guard let pdu = try receive(cancellation) else { continue }
            if let response = try answer(pdu, cancellation) { return response }
        }
    }

    /// What the peripheral sent before a write: its requests are answered.
    private func drain(_ cancellation: Cancellation) throws {
        while let pdu = try receive(cancellation, block: false) {
            _ = try answer(pdu, cancellation)
        }
    }

    /// Answers the peripheral's own PDUs; returns a response to this client's request.
    private func answer(_ pdu: [UInt8], _ cancellation: Cancellation) throws -> [UInt8]? {
        switch ATT.classify(pdu) {
        case .response(let response)?: return response
        case .request(let answer)?: try send(answer, cancellation)
        case .value(_, _, let confirm?)?: try send(confirm, cancellation)
        case .value?, nil: break
        }
        return nil
    }
}
#endif
