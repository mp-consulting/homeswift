import Foundation
import Homeswift
import HomeswiftPlugin
import Logging

/// What every accessory handler shares, after the Homebridge plugin's `BaseAccessory`: the device and its
/// parameters, the services it builds, logging, commands that report "No Response" when they fail, timers
/// that die with the handler, latest-wins debouncing, and the Eve power characteristics.
///
/// A handler builds its services in its initializer; the factory makes the HomeKit accessory from them.
/// `updateState(_:)` receives every update the device sends (WebSocket, LAN, query answers).
@EWeLinkActor
class BaseAccessory {
    unowned let platform: EWeLinkPlatform
    private(set) var record: AccessoryRecord
    let box: DeviceBox
    /// The accessory that was on the bridge under this id before this handler (restored from the cache or
    /// built by the previous handler): characteristics start from its values, as Homebridge's cached
    /// accessories kept theirs.
    let previous: Accessory?
    /// The services, in the order the handler made them.
    private(set) var services: [Service] = []
    /// The main service.
    var service: Service!
    var category: AccessoryCategory = .other

    private var timers: [Int: Task<Void, Never>] = [:]
    private var sleepers: [Int: Task<Void, any Error>] = [:]
    private var nextID = 0
    /// Only claims are used: the waits run on the plugin's clock (`debounceLatest`).
    private let latest = LatestCallGuard(delay: .zero)
    private(set) var isDestroyed = false
    /// Set when the initializer applied the device's parameters: a kept handler re-applies fresh ones.
    private var appliesInitialState = false

    init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        self.platform = platform
        self.record = record
        self.box = box
        previous = platform.context.accessory(id: record.id)
    }

    var configuration: EWeLinkPlugin.Configuration { platform.configuration }
    var device: EWeLinkDevice { box.device }
    var deviceID: String { record.deviceID }
    var uiid: Int { box.device.uiid }

    /// The device's parameters, shared with its other handlers.
    var deviceParams: DeviceParams {
        get { box.params }
        set { box.params = newValue }
    }

    /// Online unless the cloud said otherwise.
    var isOnline: Bool { box.device.online }

    /// Called for every update; subclasses override.
    func updateState(_ params: DeviceParams) {}

    func mergeDeviceParams(_ params: DeviceParams) { box.params.merge(params) }

    /// Applies the device's parameters from the initializer.
    func applyInitialState() {
        appliesInitialState = true
        updateState(deviceParams)
    }

    /// Re-syncs a handler kept across a re-discovery: handlers that applied their initial state get the fresh
    /// parameters through `updateState`; event-style ones (a full set of parameters would read as a press)
    /// only merge them.
    func refreshFromDevice() {
        guard !isDestroyed else { return }
        if appliesInitialState { updateState(deviceParams) } else { mergeDeviceParams(deviceParams) }
    }

    func refresh(record: AccessoryRecord) { self.record = record }

    func markStatus(_ online: Bool) {
        box.device.online = online
        logDebug(online ? "Device marked as online" : "Device marked as offline")
    }

    // MARK: Logging

    func logDebug(_ message: @autoclosure () -> String) {
        guard configuration.debug == true else { return }
        platform.logger.debug("[\(record.displayName)] \(message())")
    }

    func logInfo(_ message: @autoclosure () -> String) {
        guard configuration.disableDeviceLogging != true else { return }
        platform.logger.info("[\(record.displayName)] \(message())")
    }

    func logError(_ message: @autoclosure () -> String) {
        platform.logger.error("[\(record.displayName)] \(message())")
    }

    // MARK: Services

    /// Adds a service; values start from the previous accessory's. An `optional` type the service requires
    /// replaces it (other bounds, valid values), `extra` adds characteristics.
    @discardableResult
    func addService(
        _ type: ServiceType, name: String? = nil, subtype: String? = nil, optional: [CharacteristicType] = [], extra: [Characteristic] = [],
        primary: Bool = false
    ) -> Service {
        let service = Service(type, name: name, subtype: subtype, optional: optional, extra: extra, isPrimary: primary)
        if let old = previous?.services.first(where: { $0.type.uuid == type.uuid && $0.subtype == subtype }) { service.takeValues(from: old) }
        services.append(service)
        return service
    }

    /// Reads that throw "No Response" while the device is offline (unless `offlineAsOff`) or the value is unknown.
    func onRead(_ characteristic: Characteristic, _ label: String, _ get: @escaping @EWeLinkActor @Sendable () -> HAPValue?) {
        characteristic.onRead { [weak self] in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            return try await self.handleGet(label, get)
        }
    }

    /// Reads without the offline check.
    func onReadAlways(_ characteristic: Characteristic, _ get: @escaping @EWeLinkActor @Sendable () -> HAPValue) {
        characteristic.onRead { await get() }
    }

    func handleGet(_ label: String, _ get: @EWeLinkActor () -> HAPValue?) throws -> HAPValue {
        if !isOnline, configuration.offlineAsOff != true { throw HAPStatusError(.serviceCommunicationFailure) }
        guard let value = get(), value != .null else { throw HAPStatusError(.serviceCommunicationFailure) }
        logDebug("GET \(label): \(value)")
        return value
    }

    /// Writes from HomeKit; throwing reports "No Response" and keeps the old value.
    func onWrite(_ characteristic: Characteristic, _ set: @escaping @EWeLinkActor @Sendable (HAPValue) async throws -> Void) {
        characteristic.onWrite { value in try await set(value) }
    }

    /// Logs the write, runs `handler`, and reports "No Response" when it returns false.
    func handleSet(_ label: String, _ value: HAPValue, _ handler: () async throws -> Bool) async throws {
        logDebug("SET \(label): \(value)")
        guard try await handler() else { throw HAPStatusError(.serviceCommunicationFailure) }
    }

    /// Sets a characteristic's value, clamped to its bounds as HAP-NodeJS does.
    func update(_ characteristic: Characteristic, _ value: Double) {
        characteristic.value = Self.hapValue(value, for: characteristic.type)
    }

    func update(_ characteristic: Characteristic, _ value: Int) { update(characteristic, Double(value)) }

    func update(_ characteristic: Characteristic, _ value: Bool) {
        characteristic.value = characteristic.type.format == .bool ? .bool(value) : .int(value ? 1 : 0)
    }

    static func hapValue(_ value: Double, for type: CharacteristicType) -> HAPValue {
        guard value.isFinite else { return type.format == .float ? .double(type.minValue ?? 0) : .int((type.minValue ?? 0).clampedInt) }
        var clamped = value
        if let minimum = type.minValue { clamped = max(clamped, minimum) }
        if let maximum = type.maxValue { clamped = min(clamped, maximum) }
        switch type.format {
        case .bool: return .bool(clamped != 0)
        case .float: return .double(clamped)
        case .string, .tlv8, .data: return .string(clamped.jsDescription)
        default: return .int(jsRound(clamped).clampedInt)
        }
    }

    // MARK: Commands

    /// Sends a command; on success the parameters are merged into the cache.
    @discardableResult
    func sendCommand(_ params: DeviceParams) async -> Bool {
        let success = await platform.sendDeviceCommand(deviceID, params)
        if success { mergeDeviceParams(params) }
        return success
    }

    /// For write handlers: a command that fails makes HomeKit show "No Response".
    func sendCommandOrThrow(_ params: DeviceParams) async throws {
        guard await sendCommand(params) else { throw HAPStatusError(.serviceCommunicationFailure) }
    }

    var communicationError: HAPStatusError { HAPStatusError(.serviceCommunicationFailure) }

    // MARK: Timers

    /// Runs `body` after `milliseconds` unless the handler is destroyed or the timer cleared first.
    @discardableResult
    func setTrackedTimeout(_ milliseconds: Double, _ body: @escaping @EWeLinkActor () -> Void) -> Int {
        let id = makeID()
        guard !isDestroyed else { return id }
        let clock = platform.clock
        timers[id] = Task { [weak self] in
            do { try await clock.sleep(milliseconds: milliseconds) } catch { return }
            guard let self, !self.isDestroyed, self.timers.removeValue(forKey: id) != nil else { return }
            body()
        }
        return id
    }

    func clearTrackedTimeout(_ id: Int?) {
        guard let id else { return }
        timers.removeValue(forKey: id)?.cancel()
    }

    /// Runs `body` every `milliseconds` until cleared or destroyed.
    @discardableResult
    func setTrackedInterval(_ milliseconds: Double, _ body: @escaping @EWeLinkActor () -> Void) -> Int {
        let id = makeID()
        guard !isDestroyed else { return id }
        let clock = platform.clock
        timers[id] = Task { [weak self] in
            while true {
                do { try await clock.sleep(milliseconds: milliseconds) } catch { return }
                guard let self, !self.isDestroyed, self.timers[id] != nil else { return }
                body()
            }
        }
        return id
    }

    func clearTrackedInterval(_ id: Int?) { clearTrackedTimeout(id) }

    /// Sleeps; false when the handler was destroyed meanwhile.
    func trackedSleep(_ milliseconds: Double) async -> Bool {
        guard !isDestroyed else { return false }
        let id = makeID()
        let clock = platform.clock
        let task = Task { try await clock.sleep(milliseconds: milliseconds) }
        sleepers[id] = task
        let completed = (try? await task.value) != nil
        sleepers[id] = nil
        return completed && !isDestroyed
    }

    /// Claims `key` for a new request: the closure says whether it is still the latest one.
    func claimLatest(_ key: String) -> @EWeLinkActor () -> Bool {
        let isLatest = latest.claim(key)
        return { [weak self] in
            guard let self else { return false }
            return !self.isDestroyed && isLatest()
        }
    }

    /// For sliders: waits, then says whether this call is still the latest for `key`.
    func debounceLatest(_ key: String, _ milliseconds: Double) async -> Bool {
        let isLatest = claimLatest(key)
        let completed = await trackedSleep(milliseconds)
        return completed && isLatest()
    }

    /// Puts a value back after a failed command, later, so HomeKit does not overwrite it with the request.
    func revertCharacteristicLater(_ characteristic: Characteristic, _ value: HAPValue, after milliseconds: Double = Double(Timing.failedCommandReset)) {
        setTrackedTimeout(milliseconds) { characteristic.value = value }
    }

    /// Polls `update` after `initialDelay`, then every `interval` until destroyed; errors are logged.
    func setupPollingInterval(
        interval: Double = Double(Timing.pollingInterval), initialDelay: Double = Double(Timing.pollingInitialDelay),
        _ update: @escaping @EWeLinkActor () async throws -> Void
    ) {
        guard !isDestroyed else { return }
        let id = makeID()
        let clock = platform.clock
        let task = Task { [weak self] in
            var delay = initialDelay
            while true {
                do { try await clock.sleep(milliseconds: delay) } catch { return }
                guard let self, !self.isDestroyed else { return }
                do { try await update() } catch { self.logError("Polling update failed: \(error)") }
                delay = interval
            }
        }
        timers[id] = task
    }

    /// Asks the device for fresh power or sensor readings (`uiActive`). DUALR3s take an outlet.
    func requestUIActiveUpdate(outlet: Int? = nil) async {
        let params: DeviceParams = outlet.map { ["uiActive": ["outlet": .number(Double($0)), "time": .number(Double(Timing.uiActiveSeconds))]] }
            ?? ["uiActive": .number(Double(Timing.uiActiveSeconds))]
        await sendCommand(params)
    }

    func setupUIActivePolling(outlet: Int? = nil) {
        setupPollingInterval { [weak self] in await self?.requestUIActiveUpdate(outlet: outlet) }
    }

    /// Stops every timer, poll and pending sleep. Safe to call twice.
    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for sleeper in sleepers.values { sleeper.cancel() }
        sleepers.removeAll()
    }

    private func makeID() -> Int {
        nextID += 1
        return nextID
    }

    // MARK: Persisted context

    func contextValue(_ key: String) -> JSONValue? { platform.contexts.value(record.id, key) }
    func setContext(_ key: String, _ value: JSONValue?) { platform.contexts.set(record.id, key, value) }

    // MARK: Values

    func applyTemperatureOffset(_ temperature: Double, offset: Double, factor: Double? = nil) -> Double {
        var result = temperature
        if let factor { result *= factor }
        result += offset
        return clamp(roundTemperature(result), DeviceLimits.temperature)
    }

    func applyHumidityOffset(_ humidity: Double, offset: Double) -> Double { clamp(humidity + offset, DeviceLimits.humidity) }

    func roundTemperature(_ value: Double) -> Double { jsRound(value * 10) / 10 }

    // MARK: Eve power monitoring

    /// Adds the Eve power characteristics to a service's extras: watts, and volts and amps with full readings.
    static func powerCharacteristics(full: Bool) -> [Characteristic] {
        var list = [Characteristic(EveCharacteristic.currentConsumption)]
        if full { list += [Characteristic(EveCharacteristic.voltage), Characteristic(EveCharacteristic.electricCurrent)] }
        return list
    }

    /// DUALR3-style readings (`actPow_XX`, `voltage_XX`, `current_XX`, ×100), else plain `power`, `voltage`, `current`.
    func updateDualR3PowerReadings(_ service: Service, _ params: DeviceParams, suffix: String = "00", fullReadings: Bool = true) {
        func read(_ scaledKey: String, _ plainKey: String, _ divisor: Double) -> Double? {
            if let scaled = params[scaledKey] { return scaled.jsParseInt.map { Double($0) / divisor } }
            if let plain = params[plainKey] { return plain.jsParseFloat }
            return nil
        }
        if let power = read("actPow_\(suffix)", "power", DeviceLimits.powerDivisor), let characteristic = service[EveCharacteristic.currentConsumption] {
            update(characteristic, power)
            logDebug("Power: \(power.jsDescription)W")
        }
        guard fullReadings else { return }
        if let voltage = read("voltage_\(suffix)", "voltage", DeviceLimits.voltageDivisor), let characteristic = service[EveCharacteristic.voltage] {
            update(characteristic, voltage)
            logDebug("Voltage: \(voltage.jsDescription)V")
        }
        if let current = read("current_\(suffix)", "current", DeviceLimits.currentDivisor), let characteristic = service[EveCharacteristic.electricCurrent] {
            update(characteristic, current)
            logDebug("Current: \(current.jsDescription)A")
        }
    }

    // MARK: Inching

    /// Inching mode always sends "on" and toggles the state shown; the echo of its own command is ignored for
    /// a moment. Returns the new state; throws (reverting the switch later) when the command fails.
    func handleInchingModeSet(_ characteristic: Characteristic, outlets: [Int], cacheState: Bool, ignoreUpdates: InchingFlag) async throws -> Bool {
        let newState = !cacheState
        let params = SwitchHelper.switchParams(deviceParams, outlets: outlets, on: true)
        startInchingIgnoreWindow(ignoreUpdates)
        guard await sendCommand(params) else {
            logError("Failed to set inching mode state")
            ignoreUpdates.value = false
            revertCharacteristicLater(characteristic, .bool(cacheState))
            throw communicationError
        }
        characteristic.value = .bool(newState)
        logDebug("Inching mode state toggled: \(newState ? "ON" : "OFF")")
        return newState
    }

    func startInchingIgnoreWindow(_ flag: InchingFlag) {
        flag.value = true
        let isLatest = claimLatest("inching-ignore")
        setTrackedTimeout(Double(Timing.inchingDebounce)) {
            if isLatest() { flag.value = false }
        }
    }
}

/// The inching "ignore the echo" flag, shared by reference like the Homebridge plugin's `{ value }` object.
@EWeLinkActor
final class InchingFlag {
    var value = false
}

func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double { min(max(value, range.lowerBound), range.upperBound) }
func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double { min(max(value, lower), upper) }

extension HAPValue {
    /// Read as a number the way JavaScript would compare it.
    var number: Double? { doubleValue }
}
