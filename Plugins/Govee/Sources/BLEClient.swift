import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A sensor reading decoded from an advertisement.
struct BLESensorReading: Sendable, Equatable {
    var identifier: String
    var address: String?
    var model: String
    var battery: Int
    var humidity: Double
    var tempInC: Double
    var tempInF: Double
    var rssi: Int
}

/// Govee's BLE control and sensor scanning (`connection/ble.ts`). Commands connect, find the control
/// characteristic, write their frames in order and disconnect, each step bounded; a sensor scan running at the
/// time is paused and resumed for what remains of its window.
actor BLEClient {
    static let sensorServices = ["EC88", "0001"]
    static let controlCharacteristic = "000102030405060708090a0b0c0d1910"

    /// How long each step may take.
    struct Timing: Sendable {
        var connection: Duration = .seconds(10)
        var discovery: Duration = .seconds(10)
        var write: Duration = .seconds(5)
        var disconnect: Duration = .seconds(5)
        /// Between a command and the sensor scan it interrupted.
        var resumeScan: Duration = .seconds(1)
        var powerOn: Duration = .seconds(5)
    }

    let timing: Timing

    private let central: any BLECentral
    private let logger: Logger
    private let debug: DebugLog
    private(set) var isScanning = false
    private(set) var isConnecting = false
    private var isShuttingDown = false
    private var discoverCallback: (@Sendable (BLESensorReading) -> Void)?
    private(set) var scanDeadline: ContinuousClock.Instant?
    private var scanTimer: Task<Void, Never>?
    private var resumeTimer: Task<Void, Never>?
    private var scanGeneration = 0

    init(central: any BLECentral, logger: Logger, timing: Timing = Timing(), debug: DebugLog) {
        self.central = central
        self.timing = timing
        self.logger = logger
        self.debug = debug
    }

    // MARK: Commands

    /// Writes a command to a device.
    func updateDevice(_ target: BLETarget, params: BLEParams, log: DeviceLog) async throws {
        log.debug("starting ble update with params [\(params)]")
        // Claimed before the first await: a sensor scan that would start meanwhile (the actor is reentrant) waits
        // for its next window rather than take the adapter's scan over while connect() searches for the device.
        isConnecting = true
        guard await central.waitForPoweredOn(timeout: timing.powerOn) else {
            isConnecting = false
            throw BLEError.wrongState(await central.state)
        }

        let wasScanning = isScanning
        let savedCallback = discoverCallback
        let savedDeadline = scanDeadline
        if wasScanning {
            log.debug("pausing sensor scan for device update")
            await stopDiscovery()
        }

        var connection: (any BLEConnection)?
        do {
            await central.reset()
            log.debug("connecting to device at \(target.address)")
            let central = central
            let connected = try await withTimeout(timing.connection, error: { BLEError.timeout("Connection timeout") }) { try await central.connect(target) }
            connection = connected
            log.debug("connected successfully")
            log.debug("discovering services and characteristics")
            let found = try await withTimeout(timing.discovery, error: { BLEError.timeout("Service discovery timeout") }) {
                try await connected.discoverCharacteristic(Self.controlCharacteristic)
            }
            guard found else { throw BLEError.noCharacteristic }
            log.debug("found control characteristic")
            // Scenes and DIY effects span several frames, written in order over one connection.
            let frames = params.frames
            for (index, frame) in frames.enumerated() {
                log.debug("sending frame \(index + 1)/\(frames.count): \(Secrets.hex(frame))")
                try await withTimeout(timing.write, error: { BLEError.timeout("Write timeout") }) { try await connected.write(Data(frame), to: Self.controlCharacteristic) }
            }
            log.debug("command sent successfully")
        } catch {
            log.warn("BLE update failed: \(error)")
            await finish(connection: connection, wasScanning: wasScanning, callback: savedCallback, deadline: savedDeadline, log: log)
            throw error
        }
        await finish(connection: connection, wasScanning: wasScanning, callback: savedCallback, deadline: savedDeadline, log: log)
    }

    private func finish(
        connection: (any BLEConnection)?, wasScanning: Bool, callback: (@Sendable (BLESensorReading) -> Void)?, deadline: ContinuousClock.Instant?,
        log: DeviceLog
    ) async {
        isConnecting = false
        if let connection {
            do {
                log.debug("disconnecting from device")
                try await withTimeout(timing.disconnect, error: { BLEError.timeout("Disconnect timeout") }) { try await connection.disconnect() }
                log.debug("disconnected")
            } catch {
                log.debug("disconnect error (non-critical): \(error)")
            }
        }
        // Resume an interrupted sensor scan for whatever remains of its window.
        guard wasScanning, let callback, !isShuttingDown else { return }
        let delay = timing.resumeScan
        if let deadline, deadline - .now - delay <= .zero { return }
        resumeTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            do {
                try await self.scan(for: callback, until: { deadline })
            } catch {
                self.debug("[BLE] failed to resume scanning: \(error).")
            }
        }
    }


    // MARK: Sensor scans

    /// Scans for sensor advertisements, stopping after `duration` (or at `stopDiscovery()` without one).
    func scan(for callback: @escaping @Sendable (BLESensorReading) -> Void, duration: Duration?) async throws {
        try await scan(for: callback) { duration.map { ContinuousClock.now + $0 } }
    }

    /// Scans until `deadline` (read once the scan has started; nil: no end): a resumed scan keeps its window's end.
    private func scan(for callback: @escaping @Sendable (BLESensorReading) -> Void, until deadline: () -> ContinuousClock.Instant?) async throws {
        let generation = try await startDiscovery(callback)
        guard generation != nil, let deadline = deadline() else { return }
        scanTimer?.cancel()
        scanDeadline = deadline
        scanTimer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.stopDiscovery()
        }
    }

    /// Returns the scan's generation, or nil when no scan was started for this callback.
    @discardableResult
    func startDiscovery(_ callback: @escaping @Sendable (BLESensorReading) -> Void) async throws -> Int? {
        guard !isShuttingDown else { return nil }
        if isConnecting {
            debug("[BLE] skipping sensor scan - device connection in progress.")
            return nil
        }
        if isScanning {
            debug("[BLE] already scanning.")
            discoverCallback = callback
            return scanGeneration
        }
        guard await central.waitForPoweredOn(timeout: timing.powerOn) else { throw BLEError.unavailable("bluetooth adapter not ready") }
        discoverCallback = callback
        scanGeneration += 1
        do {
            try await central.startScanning(services: Self.sensorServices, allowDuplicates: true) { [weak self] advertisement in
                Task { await self?.handle(advertisement) }
            }
            isScanning = true
            debug("[BLE] started scanning for sensors.")
            return scanGeneration
        } catch {
            discoverCallback = nil
            throw error
        }
    }

    func stopDiscovery() async {
        discoverCallback = nil
        scanTimer?.cancel()
        scanTimer = nil
        resumeTimer?.cancel()
        resumeTimer = nil
        scanDeadline = nil
        guard isScanning else { return }
        await central.stopScanning()
        isScanning = false
        debug("[BLE] stopped scanning.")
    }

    func handle(_ advertisement: BLEAdvertisement) {
        guard !isShuttingDown, let callback = discoverCallback, let data = advertisement.manufacturerData else { return }
        let hex = Secrets.hex(data)
        guard SensorDecoding.isValid(hex: hex) else { return }
        debug("[BLE] sensor data from \(advertisement.address ?? advertisement.localName ?? advertisement.identifier): \(hex).")
        do {
            let reading = try SensorDecoding.decode(hex)
            callback(BLESensorReading(
                identifier: advertisement.identifier, address: advertisement.address, model: advertisement.localName ?? "", battery: reading.battery,
                humidity: reading.humidity, tempInC: reading.tempInC, tempInF: reading.tempInF, rssi: advertisement.rssi))
        } catch {
            debug("[BLE] error processing discovered peripheral: \(error).")
        }
    }

    func shutdown() async {
        logger.info("[BLE] shutting down.")
        isShuttingDown = true
        scanTimer?.cancel()
        resumeTimer?.cancel()
        if isScanning { await central.stopScanning() }
        discoverCallback = nil
        isScanning = false
        isConnecting = false
        await central.reset()
        logger.info("[BLE] shutdown complete.")
    }
}
