import Foundation
import HomeswiftPlugin
import Logging

/// Throttles cloud commands so a scene that switches twenty devices does not trip eWeLink's limits: at most
/// `concurrency` in flight, `minInterval` apart, `maxSize` waiting (the oldest is dropped beyond).
@EWeLinkActor
final class CommandQueue {
    struct OverflowError: Error, CustomStringConvertible {
        let deviceID: String
        var description: String { "Command queue full - command dropped" }
    }

    private struct Command {
        var deviceID: String
        var execute: @EWeLinkActor () async throws -> Bool
        var continuation: CheckedContinuation<Bool, any Error>
        var queuedAt: Double
    }

    let minInterval: Double
    let concurrency: Int
    let maxSize: Int
    private let clock: EWeLinkClock
    private let log: (String) -> Void
    private let deviceName: (String) -> String
    private var queue: [Command] = []
    /// Commands waiting for their turn.
    var queuedCount: Int { queue.count }
    private(set) var activeCount = 0
    private var lastCommandTime = -Double.infinity
    private var throttle: Task<Void, Never>?

    init(minInterval: Double = 250, concurrency: Int = 3, maxSize: Int = 100, clock: EWeLinkClock, log: @escaping (String) -> Void = { _ in }, deviceName: @escaping (String) -> String = { $0 }) {
        self.minInterval = minInterval
        // `commandQueueConcurrency: 0` in config.json would leave every command waiting forever.
        self.concurrency = max(1, concurrency)
        self.maxSize = max(1, maxSize)
        self.clock = clock
        self.log = log
        self.deviceName = deviceName
    }

    func enqueue(_ deviceID: String, _ execute: @escaping @EWeLinkActor () async throws -> Bool) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.append(Command(deviceID: deviceID, execute: execute, continuation: continuation, queuedAt: clock.nowMilliseconds))
            while queue.count > maxSize {
                let dropped = queue.removeFirst()
                log("Queue full (max \(maxSize)) - dropping oldest command for \(deviceName(dropped.deviceID))")
                dropped.continuation.resume(throwing: OverflowError(deviceID: dropped.deviceID))
            }
            log("Command queued for \(deviceName(deviceID)) (queue size: \(queue.count), active: \(activeCount))")
            process()
        }
    }

    private func process() {
        while !queue.isEmpty, activeCount < concurrency {
            let elapsed = clock.nowMilliseconds - lastCommandTime
            if elapsed < minInterval {
                if throttle == nil {
                    let wait = minInterval - elapsed
                    log("Throttling: scheduling next command in \(wait.rounded().clampedInt)ms")
                    let clock = clock
                    throttle = Task { [weak self] in
                        try? await clock.sleep(milliseconds: wait)
                        guard let self, !Task.isCancelled else { return }
                        self.throttle = nil
                        self.process()
                    }
                }
                return
            }
            let command = queue.removeFirst()
            activeCount += 1
            lastCommandTime = clock.nowMilliseconds
            log("Executing command for \(deviceName(command.deviceID)) (waited \((clock.nowMilliseconds - command.queuedAt).rounded().clampedInt)ms in queue)")
            Task {
                do {
                    command.continuation.resume(returning: try await command.execute())
                } catch {
                    command.continuation.resume(throwing: error)
                }
                self.activeCount -= 1
                self.process()
            }
        }
    }

    /// Fails every waiting command (shutdown).
    func clear() {
        throttle?.cancel()
        throttle = nil
        let pending = queue
        queue.removeAll()
        for command in pending { command.continuation.resume(throwing: EWeLinkError("Queue cleared")) }
    }
}

/// The LAN, cloud and group transports the dispatcher routes to (the platform's clients; fakes in tests).
protocol LANTransport: Sendable {
    func sendCommand(_ deviceID: String, params: DeviceParams) async -> Bool
}

protocol CloudTransport: Sendable {
    /// False when nothing was sent (socket not open); throws on a timeout, a server error, or a socket that
    /// closed before the answer.
    func sendCommand(_ deviceID: String, params: DeviceParams) async throws -> Bool
    func queryDeviceState(_ deviceID: String) async throws -> Bool
    var isConnected: Bool { get async }
}

protocol GroupTransport: Sendable {
    func updateGroup(_ groupID: String, params: DeviceParams) async -> Bool
}

extension LANControl: LANTransport {}
extension CloudSocket: CloudTransport {}
extension CloudAPI: GroupTransport {}

/// Routes commands: groups through the HTTP API, others over the LAN first, then the cloud through the queue.
///
/// Cloud retries (3 attempts, 2 s apart): a command that never left (socket not open) is retried; one that
/// timed out is retried once, since the device may have run it; one lost when the socket closed before the
/// answer is never resent (a toggle or a pulse must not run twice); one the server rejected is not retried.
@EWeLinkActor
final class CommandDispatcher {
    static let notDeliveredPattern = ["not connected", "not ready", "not open"]

    let configuration: EWeLinkPlugin.Configuration
    let registry: DeviceRegistry
    let logger: Logger
    let clock: EWeLinkClock
    let lan: () -> (any LANTransport)?
    let cloud: () -> (any CloudTransport)?
    let groups: () -> (any GroupTransport)?
    let queue: CommandQueue
    private var curtainCounter = 0

    init(
        configuration: EWeLinkPlugin.Configuration, registry: DeviceRegistry, logger: Logger, clock: EWeLinkClock, maxQueueSize: Int = 100,
        lan: @escaping () -> (any LANTransport)?, cloud: @escaping () -> (any CloudTransport)?, groups: @escaping () -> (any GroupTransport)?
    ) {
        self.configuration = configuration
        self.registry = registry
        self.logger = logger
        self.clock = clock
        self.lan = lan
        self.cloud = cloud
        self.groups = groups
        queue = CommandQueue(
            minInterval: configuration.commandQueueInterval ?? 250, concurrency: configuration.commandQueueConcurrency ?? 3, maxSize: maxQueueSize,
            clock: clock, log: { [logger] in logger.debug("[CommandQueue] \($0)") }, deviceName: { [registry] in registry.displayName($0) })
    }

    func sendDeviceCommand(_ deviceID: String, _ params: DeviceParams) async -> Bool {
        let parent = DeviceLimits.parentDeviceID(deviceID)
        guard let device = registry.device(parent) else {
            logger.error("Device not found in cache: \(deviceID)")
            return false
        }
        let name = registry.displayName(parent)
        if DeviceCatalog.isGroup(device.uiid), let groups = groups() {
            logger.debug("Sending group command to \(deviceID) via HTTP API")
            return await groups.updateGroup(deviceID, params: params)
        }
        // LAN needs no queue. A LAN failure of any kind falls back to the cloud.
        if configuration.connectionMode != .wan, let lan = lan(), await lan.sendCommand(deviceID, params: params) {
            return true
        }
        do {
            return try await queue.enqueue(deviceID) { [weak self] in
                guard let self else { return false }
                return await self.executeCloudCommand(deviceID, params, name: name)
            }
        } catch {
            logger.warning("[\(name)] Command not sent: \(error)")
            return false
        }
    }

    private func executeCloudCommand(_ deviceID: String, _ params: DeviceParams, name: String) async -> Bool {
        var timeoutRetries = 0
        for attempt in 1...Timing.queryRetryAttempts {
            guard let cloud = cloud(), configuration.connectionMode != .lan else {
                logger.error("No available control method for device: \(deviceID)")
                return false
            }
            let isLast = attempt == Timing.queryRetryAttempts
            var reason: String
            do {
                if try await cloud.sendCommand(deviceID, params: params) { return true }
                if isLast {
                    logger.error("[\(name)] Failed to send command: cloud connection unavailable")
                    return false
                }
                reason = "cloud connection unavailable"
            } catch {
                reason = "\(error)"
                let lowered = reason.lowercased()
                let notDelivered = Self.notDeliveredPattern.contains { lowered.contains($0) }
                let timedOut = lowered.contains("timeout")
                guard notDelivered || (timedOut && timeoutRetries < 1), !isLast else {
                    logger.error(attempt > 1 ? "[\(name)] Failed to send command after \(attempt) attempts: \(reason)" : "[\(name)] Failed to send command: \(reason)")
                    return false
                }
                if timedOut { timeoutRetries += 1 }
            }
            logger.debug("Command attempt \(attempt)/\(Timing.queryRetryAttempts) failed for \(name): \(reason), retrying...")
            try? await clock.sleep(milliseconds: Double(Timing.queryRetryDelay))
        }
        return false
    }

    /// Asks the device for its state over the WebSocket, retrying; the answer arrives as an update.
    func queryDeviceState(_ deviceID: String) async -> Bool {
        let name = registry.displayName(deviceID)
        guard let cloud = cloud(), await cloud.isConnected else {
            logger.debug("Cannot query \(name): WebSocket not connected")
            return false
        }
        for attempt in 1...Timing.queryRetryAttempts {
            do {
                _ = try await cloud.queryDeviceState(deviceID)
                return true
            } catch {
                if attempt < Timing.queryRetryAttempts {
                    logger.debug("Query attempt \(attempt)/\(Timing.queryRetryAttempts) failed for \(name): \(error), retrying...")
                    try? await clock.sleep(milliseconds: Double(Timing.queryRetryDelay))
                } else {
                    logger.warning("Failed to query device \(name) after \(Timing.queryRetryAttempts) attempts: \(error)")
                }
            }
        }
        return false
    }

    /// 1 s, 2 s, 3 s...: curtains refresh their state one after the other.
    func curtainStaggerDelay() -> Int {
        curtainCounter += 1
        return curtainCounter * 1000
    }

    func clear() { queue.clear() }
}
