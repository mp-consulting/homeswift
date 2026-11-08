import Foundation
import HomeswiftNetwork
import HomeswiftPlugin
import Logging

/// A device on Bluetooth, as its options give it (§1 of docs/clean-room/SwitchBotBLE.md).
struct BLEDevice: Sendable {
    var name: String
    var model: BLEModel
    /// 12 upper-case hex digits: `customBLEaddress`, else the cloud's `deviceId`.
    var mac: String
    var key: BLEKey?
    var password: String?
    /// Attempts of a connection and its exchanges (`maxRetry`, 5 by default).
    var attempts: Int
}

/// The Bluetooth side of the plugin on the shared adapter: one scan for every SwitchBot advertisement, and the GATT
/// exchanges of §4 (one at a time per device: subscribe, write with response, the next notification is the reply).
actor SwitchBotBluetooth {
    struct Timing: Sendable {
        var powerOn: Duration = .seconds(5)
        var connect: Duration = .seconds(10)
        var reply: Duration = .seconds(5)
        var disconnect: Duration = .seconds(5)
        /// The first wait between two attempts, doubled up to `maximumRetryDelay`.
        var retryDelay: Duration = .milliseconds(100)
        var maximumRetryDelay: Duration = .seconds(5)
    }

    nonisolated let central: any BLECentral
    let logger: Logger
    let timing: Timing
    private var scanning = false
    /// The system's identifier of each MAC (CoreBluetooth's UUID on macOS), from its advertisements.
    private var identifiers: [String: String] = [:]
    private var lastHeard: [String: ContinuousClock.Instant] = [:]
    private var logged: Set<String> = []
    private var queues: [String: SerialTasks] = [:]

    init(central: any BLECentral, logger: Logger, timing: Timing = Timing()) {
        self.central = central
        self.logger = logger
        self.timing = timing
    }

    // MARK: Advertisements

    /// Scans every advertiser (the merged ADV_IND and scan response of each), handing each SwitchBot reading on.
    func startScanning(_ onReading: @escaping @Sendable (BLEReading) -> Void) async throws {
        guard !scanning else { return }
        guard await central.waitForPoweredOn(timeout: timing.powerOn) else { throw BLEError.wrongState(await central.state) }
        scanning = true
        do {
            // Every advertiser: a filter on the service-data UUID would drop the ADV_IND that carries a plug's or a
            // bulb's state where a system does not merge it with the scan response.
            try await central.startScanning(services: [], allowDuplicates: true) { [weak self] advertisement in
                guard let reading = BLEAdvertisementDecoder.decode(advertisement), let mac = reading.mac else { return }
                Task {
                    await self?.heard(mac, identifier: advertisement.identifier, model: reading.model)
                    onReading(reading)
                }
            }
        } catch {
            scanning = false
            throw error
        }
    }

    func stop() async {
        guard scanning else { return }
        scanning = false
        await central.stopScanning()
    }

    private func heard(_ mac: String, identifier: String, model: BLEModel) {
        if identifiers.updateValue(identifier, forKey: mac) == nil, logged.insert(mac).inserted {
            logger.debug("[BLE] SwitchBot \(model.rawValue) advertising as \(colonMAC(mac))")
        }
        lastHeard[mac] = .now
    }

    /// Whether the device advertised within `window`.
    func heard(_ mac: String, within window: Duration) -> Bool {
        lastHeard[mac].map { ContinuousClock.now - $0 <= window } ?? false
    }

    // MARK: Exchanges

    /// What a connection's exchanges answered: each request's reply, status byte first, decrypted.
    struct Exchange: Sendable {
        var request: BLERequest
        var reply: [UInt8]
    }

    /// Connects to the device and sends `requests` in turn over one connection; retried whole (up to the device's
    /// attempts) when the connection or a reply fails or the device is busy. A refused request ends it with its status.
    func send(_ requests: [BLERequest], to device: BLEDevice) async throws -> [Exchange] {
        let queue = queues[device.mac] ?? SerialTasks()
        queues[device.mac] = queue
        let target = BLETarget(address: colonMAC(device.mac), identifier: identifiers[device.mac])
        return try await queue.run { [self] in
            let backoff = Backoff(initial: timing.retryDelay, maximum: timing.maximumRetryDelay)
            var failure: any Error = BLEError.notFound
            for attempt in 1...max(device.attempts, 1) {
                try Task.checkCancellation()
                do {
                    return try await exchange(requests, with: device, at: target)
                } catch let status as BLEStatus where !status.retryable {
                    throw status
                } catch let rejected as BLECipher.Rejected {
                    throw rejected
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    failure = error
                    guard attempt < device.attempts else { break }
                    try await Task.sleep(for: backoff.delay(attempt: attempt - 1))
                }
            }
            throw failure
        }
    }

    private nonisolated func exchange(_ requests: [BLERequest], with device: BLEDevice, at target: BLETarget) async throws -> [Exchange] {
        let central = central, timing = timing, logger = logger
        guard await central.waitForPoweredOn(timeout: timing.powerOn) else { throw BLEError.wrongState(await central.state) }
        let started = ContinuousClock.now
        let connection = try await withTimeout(timing.connect, error: { BLEError.timeout("connection timeout") }) { try await central.connect(target) }
        let inbox = ReplyInbox()
        var listener: Task<Void, Never>?
        defer { listener?.cancel() }
        do {
            let found = try await withTimeout(timing.connect, error: { BLEError.timeout("service discovery timeout") }) {
                try await connection.discoverCharacteristic(BLEGATT.write)
            }
            guard found else { throw BLEError.noCharacteristic }
            // Subscribed before the first write: the stream keeps what arrives until the listener reads it.
            let stream = try await withTimeout(timing.connect, error: { BLEError.timeout("subscription timeout") }) {
                try await connection.notifications(of: BLEGATT.notify)
            }
            listener = Task {
                for await value in stream { await inbox.push(Array(value)) }
                await inbox.finish()
            }
            var cipher: BLECipher?
            if let key = device.key, requests.contains(where: \.encrypted) || device.model == .stripLight {
                let reply = try await roundTrip(BLEFrames.encryptionInit(keyID: key.id), connection, inbox, timing)
                do {
                    cipher = try BLECipher(key: key, initReply: reply)
                } catch {
                    logger.warning("[BLE] \(device.name): \(error)")
                    throw error
                }
                logger.debug("[BLE] \(device.name): encryption session \(cipher!.mode == .ctr ? "AES-CTR" : "AES-GCM")")
            }
            var exchanges: [Exchange] = []
            for request in requests {
                guard !request.encrypted || cipher != nil else {
                    throw BLEUnsupported(reason: "\(device.name) needs its encryption key and key id (Setup)")
                }
                var lastStatus = BLEStatus(code: 0)
                var answered: [UInt8]?
                for frame in request.frames {
                    let reply: [UInt8]
                    if var session = cipher {
                        let raw = try await roundTrip(try session.encrypt(frame), connection, inbox, timing)
                        reply = try session.decrypt(raw)
                        session.advance()
                        cipher = session
                    } else {
                        reply = try await roundTrip(frame, connection, inbox, timing)
                    }
                    lastStatus = BLEStatus(code: reply.first ?? 0)
                    if lastStatus.succeeded {
                        answered = reply
                        break
                    }
                }
                let elapsed = ContinuousClock.now - started
                guard let answered else {
                    if lastStatus.isWarning {
                        logger.warning("[BLE] \(device.name): \(request.name): \(lastStatus)")
                    } else {
                        logger.debug("[BLE] \(device.name): \(request.name): \(lastStatus) after \(elapsed)")
                    }
                    throw lastStatus
                }
                if lastStatus.code == 0x06 { logger.warning("[BLE] \(device.name): low battery") }
                logger.debug("[BLE] \(device.name): \(request.name): \(lastStatus) after \(elapsed)")
                exchanges.append(Exchange(request: request, reply: answered))
            }
            try? await withTimeout(timing.disconnect) { try await connection.disconnect() }
            return exchanges
        } catch {
            try? await withTimeout(timing.disconnect) { try await connection.disconnect() }
            throw error
        }
    }

    /// One request and the next notification, its reply (§4.2). Status notifications (byte 0 `0x0F`, a lock's) are not replies.
    private nonisolated func roundTrip(_ frame: [UInt8], _ connection: any BLEConnection, _ inbox: ReplyInbox, _ timing: Timing) async throws -> [UInt8] {
        await inbox.clear()
        try await withTimeout(timing.reply, error: { BLEError.timeout("write timeout") }) {
            try await connection.writeWithResponse(Data(frame), to: BLEGATT.write)
        }
        return try await withTimeout(timing.reply, error: { BLEError.timeout("no reply") }, onTimeout: { await inbox.cancelWait() }) {
            try await inbox.next()
        }
    }
}

/// The notifications of one connection, kept until a reply is waited for.
actor ReplyInbox {
    private var buffer: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8], any Error>?
    private var finished = false

    func push(_ value: [UInt8]) {
        guard value.first != 0x0F else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            buffer.append(value)
        }
    }

    func finish() {
        finished = true
        waiter?.resume(throwing: BLEError.unavailable("disconnected"))
        waiter = nil
    }

    func clear() { buffer.removeAll() }

    func cancelWait() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    /// The next reply; a cancelled wait ends with `CancellationError`.
    func next() async throws -> [UInt8] {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if finished { throw BLEError.unavailable("disconnected") }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) } else { waiter = continuation }
            }
        } onCancel: {
            Task { await self.cancelWait() }
        }
    }
}
