import Foundation
import HomeswiftPlugin
import Logging

/// Modes switched on whenever the device goes from off to on (`enable…WhenActivating`), for the modes the
/// model has.
struct ActivationDefaults: Sendable, Equatable {
    var autoMode = false
    var oscillation = false
    var nightMode = false
}

/// What a device tells its observers.
enum DeviceEvent: Sendable {
    case stateChanged(DeviceState)
    case connected
    case disconnected
    /// The MQTT client gave up reconnecting: the device is offline.
    case reconnectFailed
    case error(String)
}

/// One Dyson device over its local MQTT broker, as the Homebridge plugin's `DysonLinkDevice`: the state it
/// reports, the commands HomeKit sends (in the model's power protocol), and a state request every polling
/// interval.
actor DysonDevice {
    static let pollingRange = 10...300
    /// After an OFF, mode and speed writes are dropped for this long unless something switches the device on:
    /// HomeKit writes Active and the target state one after the other, and a mode command right after OFF
    /// would switch the fan back on (the Homebridge plugin drops them within the same tick).
    static let offGuard: Duration = .seconds(1)

    let serial: String
    let productType: String
    let name: String
    let features: DeviceFeatures
    let usesFpwr: Bool
    private let credentials: String
    private(set) var ipAddress: String?
    private(set) var state = DeviceState()
    private(set) var pollingInterval: Duration = .seconds(60)
    private(set) var activationDefaults = ActivationDefaults()

    private let mqtt: DysonMQTTClient.Connect
    private let logger: Logger
    private let backoff: @Sendable (Int) -> Duration
    private var client: DysonMQTTClient?
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    /// Power commanded but not yet confirmed by a state message: a quick off → on still sends ON although the
    /// reported state says on.
    private var commandedPower: Bool?
    private var offCommandedAt: ContinuousClock.Instant?
    private var observers: [UUID: @Sendable (DeviceEvent) -> Void] = [:]

    init(serial: String, productType: String, name: String, credentials: String, ipAddress: String?, mqtt: @escaping DysonMQTTClient.Connect, logger: Logger,
         backoff: @escaping @Sendable (Int) -> Duration = DysonMQTTClient.exponentialBackoff) {
        self.serial = serial
        self.productType = productType
        self.name = name
        self.credentials = credentials
        self.ipAddress = ipAddress
        self.mqtt = mqtt
        self.logger = logger
        self.backoff = backoff
        features = DeviceCatalog.features(productType)
        usesFpwr = DeviceCatalog.powerProtocol(productType) == .fpwr
    }

    var isConnected: Bool {
        get async { await client?.isConnected ?? false }
    }

    var activeVariant: DysonMQTTClient.Variant? {
        get async { await client?.activeVariant }
    }

    @discardableResult
    func observe(_ observer: @escaping @Sendable (DeviceEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func emit(_ event: DeviceEvent) {
        for observer in observers.values { observer(event) }
    }

    func setIPAddress(_ ip: String) { ipAddress = ip }

    /// 10 to 300 seconds.
    func setPollingInterval(seconds: Int) {
        pollingInterval = .seconds(min(max(seconds, Self.pollingRange.lowerBound), Self.pollingRange.upperBound))
        if pollTask != nil {
            stopPolling()
            startPolling()
        }
    }

    func setActivationDefaults(_ defaults: ActivationDefaults) { activationDefaults = defaults }

    // MARK: Connection

    /// Connects, subscribes to the status topic and asks for the current state and the sensor readings.
    func connect() async throws {
        guard let ipAddress else { throw DysonMQTTError.unreachable("No IP address for device \(serial)") }
        if await client?.isConnected == true { return }
        // A half-open client from a failed attempt must not keep reconnecting and feeding us messages.
        await disposeClient()
        let client = DysonMQTTClient(
            settings: .init(host: ipAddress, serial: serial, credentials: credentials, productType: productType), mqtt: mqtt, backoff: backoff)
        self.client = client
        let events = client.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        do {
            try await client.connect()
            try await client.subscribeToStatus()
            try await client.requestCurrentState()
            try await client.requestEnvironment()
        } catch {
            await disposeClient()
            throw error
        }
        startPolling()
        markConnected(true)
    }

    func disconnect() async {
        commandedPower = nil
        offCommandedAt = nil
        stopPolling()
        await disposeClient()
        updateState { $0.connected = false }
        emit(.disconnected)
    }

    private func disposeClient() async {
        guard let client else { return }
        self.client = nil
        eventTask?.cancel()
        eventTask = nil
        await client.disconnect()
        await client.finish()
    }

    private func markConnected(_ connected: Bool) {
        guard state.connected != connected else { return }
        updateState { $0.connected = connected }
        emit(connected ? .connected : .disconnected)
    }

    private func handle(_ event: DysonMQTTClient.Event) {
        switch event {
        case .connected: markConnected(true)
        case .disconnected: markConnected(false)
        case .message(_, let payload): handleMessage(payload)
        case .reconnecting(let attempt): logger.debug("[\(serial)] Reconnecting (attempt \(attempt))")
        case .reconnectFailed:
            updateState { $0.connected = false }
            emit(.reconnectFailed)
        case .error(let message): emit(.error(message))
        }
    }

    // MARK: Polling

    private func startPolling() {
        guard pollTask == nil else { return }
        let interval = pollingInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                await self?.poll()
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// The state, then the sensor readings.
    func poll() async {
        guard let client, await client.isConnected else { return }
        try? await client.requestCurrentState()
        try? await client.requestEnvironment()
    }

    // MARK: Messages

    func handleMessage(_ payload: Data) {
        guard let message = try? JSONValue(data: payload).objectValue else { return }
        var next = state
        guard MessageCodec.apply(message, to: &next) else { return }
        if message["msg"]?.stringValue != "ENVIRONMENTAL-CURRENT-SENSOR-DATA" {
            let fields = message["product-state"] ?? message["data"]
            logger.debug("Received state: fmod=\(MessageCodec.value(fields?["fmod"]) ?? "nil"), auto=\(MessageCodec.value(fields?["auto"]) ?? "nil"), fnsp=\(MessageCodec.value(fields?["fnsp"]) ?? "nil")")
            // Once the device reports the power we commanded, it is confirmed.
            if let fields = MessageCodec.stateFields(message), let isOn = MessageCodec.reportedPower(fields), isOn == commandedPower { commandedPower = nil }
        }
        updateState { $0 = next }
    }

    /// Changes the state; observers hear of it only when something changed, so identical polls fan out to nothing.
    private func updateState(_ change: (inout DeviceState) -> Void) {
        var next = state
        change(&next)
        guard next != state else { return }
        state = next
        emit(.stateChanged(state))
    }

    // MARK: Commands

    /// Sends `STATE-SET` with the fields; the later dictionaries win where they overlap.
    private func send(_ parts: [[String: String]]) async throws {
        var fields: [String: String] = [:]
        for part in parts { fields.merge(part) { _, new in new } }
        guard !fields.isEmpty else { return }
        guard let client, await client.isConnected else { throw DysonMQTTError.unreachable("Device not connected") }
        let payload = MessageCodec.stateSet(fields)
        logger.debug("Sending command: \(String(decoding: payload, as: UTF8.self))")
        try await client.publishCommand(payload)
    }

    private var manualSpeed: Int { state.fanSpeed > 0 ? state.fanSpeed : MessageCodec.FanSpeed.default }

    /// The fields that run the fan in auto or manual mode, in the model's power protocol.
    func powerOnFields(auto: Bool, speed: Int) -> [String: String] {
        let encoded = MessageCodec.encodeFanSpeed(auto ? MessageCodec.FanSpeed.auto : speed)
        if usesFpwr { return ["fpwr": MessageCodec.on, "auto": auto ? MessageCodec.on : MessageCodec.off, "fnsp": encoded] }
        return auto ? ["fmod": MessageCodec.auto] : ["fmod": MessageCodec.fan, "fnsp": encoded]
    }

    /// Switching on: the power fields and the activation defaults, in one command; nothing when already on
    /// (HomeKit sends Active with mode changes), unless an OFF is still unconfirmed.
    private func powerOnParts() -> [[String: String]] {
        if state.isOn, commandedPower != false { return [] }
        commandedPower = true
        offCommandedAt = nil
        var parts: [[String: String]] = [usesFpwr
            ? powerOnFields(auto: state.autoMode, speed: manualSpeed)
            : ["fmod": state.autoMode ? MessageCodec.auto : MessageCodec.fan]]
        if activationDefaults.autoMode, features.autoMode { parts.append(powerOnFields(auto: true, speed: manualSpeed)) }
        if activationDefaults.oscillation, features.oscillation { parts.append(["oson": MessageCodec.on]) }
        if activationDefaults.nightMode, features.nightMode { parts.append(["nmod": MessageCodec.on]) }
        return parts
    }

    private var recentlyTurnedOff: Bool {
        guard let offCommandedAt else { return false }
        return ContinuousClock.now - offCommandedAt < Self.offGuard
    }

    func setFanPower(_ on: Bool) async throws {
        if on {
            try await send(powerOnParts())
        } else {
            commandedPower = false
            offCommandedAt = .now
            try await send([usesFpwr ? ["fpwr": MessageCodec.off] : ["fmod": MessageCodec.off]])
        }
    }

    /// 1-10, or a negative speed for auto mode.
    func setFanSpeed(_ speed: Int) async throws {
        guard !recentlyTurnedOff else { return }
        try await send([powerOnFields(auto: speed < 0, speed: speed)])
    }

    /// Switches on if needed and sets the speed, in one command; the speed wins over the activation defaults.
    func powerOnAndSetSpeed(_ speed: Int) async throws {
        let power = state.isOn ? [] : powerOnParts()
        try await send(power + [powerOnFields(auto: speed < 0, speed: speed)])
    }

    func setAutoMode(_ on: Bool) async throws {
        guard !recentlyTurnedOff else { return }
        try await send([powerOnFields(auto: on, speed: manualSpeed)])
    }

    func setOscillation(_ on: Bool) async throws { try await send([["oson": on ? MessageCodec.on : MessageCodec.off]]) }
    func setNightMode(_ on: Bool) async throws { try await send([["nmod": on ? MessageCodec.on : MessageCodec.off]]) }
    func setContinuousMonitoring(_ on: Bool) async throws { try await send([["rhtm": on ? MessageCodec.on : MessageCodec.off]]) }
    func setJetFocus(_ on: Bool) async throws { try await send([["ffoc": on ? MessageCodec.on : MessageCodec.off]]) }
    func setHeating(_ on: Bool) async throws { try await send([["hmod": on ? MessageCodec.heat : MessageCodec.off]]) }

    /// Heating on, and the fan on when it is off, in one command.
    func startHeating() async throws {
        let power = state.isOn ? [] : powerOnParts()
        try await send([["hmod": MessageCodec.heat]] + power)
    }

    /// Celsius, clamped to 1-37.
    func setTargetTemperature(_ celsius: Double) async throws {
        let clamped = min(max(celsius, MessageCodec.HeatingTemperature.minCelsius), MessageCodec.HeatingTemperature.maxCelsius)
        try await send([["hmax": MessageCodec.encodeTemperature(clamped)]])
    }

    func setHumidifier(_ on: Bool) async throws { try await send([["hume": on ? MessageCodec.on : MessageCodec.off]]) }
    func setHumidifierAuto() async throws { try await send([["hume": MessageCodec.auto]]) }

    /// Percent, clamped to 0-100.
    func setTargetHumidity(_ percent: Double) async throws {
        let rounded = Int((percent + 0.5).rounded(.down))
        let clamped = min(max(rounded, MessageCodec.Humidity.minPercent), MessageCodec.Humidity.maxPercent)
        try await send([["humt": MessageCodec.pad(clamped)]])
    }
}
