import Foundation
import Homeswift
import Logging

/// One light: its API client, the last known state, and the polling that keeps it fresh.
///
/// Reads come from the cached state; after `offlineThreshold` failed polls the light is unreachable and
/// reads throw, so the Home app shows "No Response" instead of stale values.
actor KeyLightDevice {
    static let offlineThreshold = 3
    static let defaultSettings = KeyLightSettings(
        powerOnBehavior: 1, powerOnBrightness: 20, powerOnTemperature: 213,
        switchOnDurationMs: 100, switchOffDurationMs: 300, colorChangeDurationMs: 100)

    let mac: String
    /// The name announced over Bonjour or given in config.json.
    let discoveredName: String
    private(set) var client: KeyLightClient
    private(set) var info: KeyLightInfo?
    private(set) var state = LightState()
    private(set) var settings: KeyLightSettings?
    private(set) var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?
    private let pollingInterval: Duration
    private let logger: Logger
    private var stateHandler: (@Sendable (LightState) -> Void)?
    private var reachabilityHandler: (@Sendable (Bool) -> Void)?

    init(mac: String, name: String, client: KeyLightClient, pollingInterval: Duration, logger: Logger) {
        self.mac = mac
        discoveredName = name
        self.client = client
        self.pollingInterval = pollingInterval
        self.logger = logger
    }

    var isReachable: Bool { consecutiveFailures < Self.offlineThreshold }
    var host: String { client.host }
    var port: Int { client.port }

    var serialNumber: String { info?.serialNumber.flatMap { $0.isEmpty ? nil : $0 } ?? mac }
    var model: String { info?.productName ?? "Elgato Light" }
    var manufacturer: String {
        let product = model
        if let space = product.firstIndex(of: " ") { return String(product[..<space]) }
        return product
    }
    var firmwareVersion: String { info?.firmwareVersion ?? "1.0" }
    /// The name the light reports, or the discovered one.
    var displayName: String {
        info?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? discoveredName
    }

    func setStateHandler(_ handler: @escaping @Sendable (LightState) -> Void) { stateHandler = handler }
    func setReachabilityHandler(_ handler: @escaping @Sendable (Bool) -> Void) { reachabilityHandler = handler }

    /// Fetches the light's information, state and settings.
    func connect() async throws {
        async let info = client.info()
        async let lights = client.lights()
        async let settings = client.settings()
        self.info = try await info
        let payload = try await lights
        guard let first = payload.lights.first else { throw KeyLightError.invalidResponse("no lights") }
        state = first
        self.settings = try await settings
        consecutiveFailures = 0
    }

    /// The light was announced again, maybe on a new address: moves there once the light at that address
    /// reports the same serial number, so a spoofed announcement cannot redirect the plugin.
    func follow(host: String, port: Int) async {
        guard host != client.host || port != client.port else { return }
        guard KeyLightClient.isValidHost(host), KeyLightClient.isValidPort(port) else {
            logger.warning("Ignoring an announcement for \(displayName) with an invalid address \(host):\(port)")
            return
        }
        var probe = client
        probe.host = host
        probe.port = port
        do {
            let reported = try await probe.info()
            guard let serial = info?.serialNumber, !serial.isEmpty, reported.serialNumber == serial else {
                logger.warning("Ignoring an announcement for \(displayName) from \(host):\(port): a different light answers there")
                return
            }
        } catch {
            logger.debug("Ignoring an announcement for \(displayName) from \(host):\(port): \(error)")
            return
        }
        client.host = host
        client.port = port
        logger.info("\(displayName) is now at \(host):\(port)")
    }

    /// The last known state, or a communication failure while the light is unreachable.
    func currentState() throws -> LightState {
        guard isReachable else { throw HAPStatusError(.serviceCommunicationFailure) }
        return state
    }

    /// Sends the keys set in `change` and remembers them, so reads before the next poll see the new value
    /// and the next poll does not echo the change back to HomeKit.
    func apply(_ change: LightState) async throws {
        do {
            try await client.setLight(change)
        } catch {
            logger.error("Could not set \(describe(change)) on \(displayName): \(error)")
            throw error
        }
        state = state.merging(change)
        logger.debug("Set \(describe(change)) on \(displayName)")
    }

    func applySettings(_ settings: KeyLightSettings) async {
        do {
            try await client.updateSettings(settings)
            self.settings = try await client.settings()
            logger.debug("Updated the settings of \(displayName)")
        } catch {
            logger.error("Could not update the settings of \(displayName): \(error)")
            self.settings = settings
        }
    }

    func identify() async {
        do {
            try await client.identify()
        } catch {
            logger.debug("Identify failed for \(displayName): \(error)")
        }
    }

    /// Polls the light; each poll starts after the previous one settled, so a slow light never piles up requests.
    func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollingInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                await self?.poll()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        let payload: LightsPayload
        do {
            let seconds = Double(pollingInterval.components.seconds) + Double(pollingInterval.components.attoseconds) / 1e18
            payload = try await client.lights(timeout: seconds)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures == Self.offlineThreshold {
                logger.warning("\(displayName) is not responding, will keep retrying")
                reachabilityHandler?(false)
            } else if consecutiveFailures < Self.offlineThreshold {
                logger.debug("Polling \(displayName) failed, will retry: \(error)")
            }
            return
        }
        let wasReachable = isReachable
        consecutiveFailures = 0
        if !wasReachable {
            logger.info("\(displayName) is responding again")
            reachabilityHandler?(true)
        }
        guard let fresh = payload.lights.first else { return }
        let previous = state
        state = fresh
        if fresh != previous {
            stateHandler?(fresh)
        }
    }

    private func describe(_ change: LightState) -> String {
        var parts: [String] = []
        if let on = change.on { parts.append("on=\(on == 1)") }
        if let brightness = change.brightness { parts.append("brightness=\(brightness)") }
        if let temperature = change.temperature { parts.append("temperature=\(temperature)") }
        return parts.joined(separator: " ")
    }
}
