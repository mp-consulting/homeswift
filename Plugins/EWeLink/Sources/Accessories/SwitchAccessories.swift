import Foundation
import Homeswift
import HomeswiftPlugin

/// A switch or one channel of a multi-channel switch; with `isInched`, inching mode (always "on", the state
/// shown toggles). Channel n of a multi-channel device drives outlet n - 1; the master channel (0) drives them
/// all and shows on when any is.
final class SwitchAccessory: BaseAccessory {
    let channel: Int
    /// The device outlets this accessory drives (`SwitchHelper.outlets`).
    let outlets: [Int]
    let isInched: Bool
    private var cacheState = false
    private let ignoreUpdates = InchingFlag()

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        channel = record.switchNumber ?? 0
        outlets = SwitchHelper.outlets(switchNumber: record.switchNumber, channelCount: record.channelCount)
        isInched = platform.configuration.single(record.deviceID)?.isInched ?? false
        super.init(platform: platform, record: record, box: box)
        category = .switch
        service = addService(.switch, primary: true)
        let on = service.characteristic(.on)
        on.onRead { [weak self] in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            return try await self.readOn()
        }
        onWrite(on) { [weak self] value in try await self?.setOn(value) }
        if isInched { cacheState = currentState }
        applyInitialState()
    }

    private var currentState: Bool { SwitchHelper.currentState(deviceParams, outlets: outlets) }

    private func readOn() throws -> HAPValue {
        if isInched { return .bool(cacheState) }
        return try handleGet("On") { .bool(currentState) }
    }

    private func setOn(_ value: HAPValue) async throws {
        if isInched {
            cacheState = try await handleInchingModeSet(service.characteristic(.on), outlets: outlets, cacheState: cacheState, ignoreUpdates: ignoreUpdates)
            return
        }
        try await handleSet("On", value) {
            await sendCommand(SwitchHelper.switchParams(deviceParams, outlets: outlets, on: value.boolValue ?? false))
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if isInched {
            let received = SwitchHelper.isSCMDevice(deviceParams)
                ? params.switches?.contains { $0.outletNumber.map(outlets.contains) == true && $0["switch"] == "on" } == true
                : params["switch"] == "on"
            if received, !ignoreUpdates.value {
                startInchingIgnoreWindow(ignoreUpdates)
                cacheState.toggle()
                service.characteristic(.on).value = .bool(cacheState)
                logDebug("Inching mode state toggled (external): \(cacheState ? "ON" : "OFF")")
            }
            return
        }
        // The master channel's outlets are all of them: it shows on when any channel is.
        let on = currentState
        let isPrimary = channel == 0 && (record.channelCount ?? 0) != 0
        service.characteristic(.on).value = .bool(on)
        logDebug("State updated: \(on ? "ON" : "OFF")\(isPrimary ? " (primary state)" : "")")
    }
}

/// An outlet: on/off, "in use" from the power reading (above `inUsePowerThreshold`) or the state, Eve power
/// characteristics when the device reports power, and inching mode. As a channel of a multi-channel device
/// (`showAs: outlet`), it drives the outlets a `SwitchAccessory` channel would.
final class OutletAccessory: BaseAccessory {
    /// The device outlets this accessory drives (`SwitchHelper.outlets`).
    let outlets: [Int]
    let isInched: Bool
    let inUsePowerThreshold: Double
    let hasFullPowerReadings: Bool
    let monitorsPower: Bool
    private var cacheState = false
    private let ignoreUpdates = InchingFlag()

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        let entry = platform.configuration.single(record.deviceID)
        outlets = SwitchHelper.outlets(switchNumber: record.switchNumber, channelCount: record.channelCount)
        isInched = entry?.isInched ?? false
        inUsePowerThreshold = entry?.inUsePowerThreshold ?? 0
        hasFullPowerReadings = DeviceCatalog.hasFullPowerReadings(box.device.uiid)
        monitorsPower = DeviceValueParser.hasPowerReadings(box.params)
        super.init(platform: platform, record: record, box: box)
        category = .outlet
        service = addService(.outlet, optional: [.outletInUse], extra: monitorsPower ? Self.powerCharacteristics(full: hasFullPowerReadings) : [], primary: true)
        let on = service.characteristic(.on)
        on.onRead { [weak self] in
            guard let self else { throw HAPStatusError(.serviceCommunicationFailure) }
            return try await self.readOn()
        }
        onWrite(on) { [weak self] value in try await self?.setOn(value) }
        onRead(service.characteristic(.outletInUse), "OutletInUse") { [weak self] in
            guard let self else { return nil }
            if let power = DeviceValueParser.powerReadings(self.deviceParams).power { return .bool(power > self.inUsePowerThreshold) }
            return .bool(self.isInched ? self.cacheState : self.currentState)
        }
        if monitorsPower { logDebug("Power monitoring enabled (full readings: \(hasFullPowerReadings))") }
        if isInched { cacheState = currentState }
        applyInitialState()
    }

    private var currentState: Bool { SwitchHelper.currentState(deviceParams, outlets: outlets) }

    private func readOn() throws -> HAPValue {
        if isInched { return .bool(cacheState) }
        return try handleGet("On") { .bool(currentState) }
    }

    private func setOn(_ value: HAPValue) async throws {
        if isInched {
            cacheState = try await handleInchingModeSet(service.characteristic(.on), outlets: outlets, cacheState: cacheState, ignoreUpdates: ignoreUpdates)
            return
        }
        try await handleSet("On", value) {
            await sendCommand(SwitchHelper.switchParams(deviceParams, outlets: outlets, on: value.boolValue ?? false))
        }
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        let readings = DeviceValueParser.powerReadings(params)
        if isInched {
            let received = SwitchHelper.isSCMDevice(deviceParams)
                ? params.switches?.contains { $0.outletNumber.map(outlets.contains) == true && $0["switch"] == "on" } == true
                : params["switch"] == "on"
            if received, !ignoreUpdates.value {
                startInchingIgnoreWindow(ignoreUpdates)
                cacheState.toggle()
                service.characteristic(.on).value = .bool(cacheState)
                logDebug("Inching mode state toggled (external): \(cacheState ? "ON" : "OFF")")
            }
            let inUse = readings.power.map { $0 > inUsePowerThreshold } ?? cacheState
            service.characteristic(.outletInUse).value = .bool(inUse)
        } else {
            let on = currentState
            service.characteristic(.on).value = .bool(on)
            let inUse = readings.power.map { $0 > inUsePowerThreshold } ?? on
            service.characteristic(.outletInUse).value = .bool(inUse)
            logDebug("State updated: \(on ? "ON" : "OFF"), In Use: \(inUse)")
        }
        if monitorsPower {
            if let power = readings.power, let characteristic = service[EveCharacteristic.currentConsumption] { update(characteristic, power) }
            if hasFullPowerReadings {
                if let voltage = readings.voltage, let characteristic = service[EveCharacteristic.voltage] { update(characteristic, voltage) }
                if let current = readings.current, let characteristic = service[EveCharacteristic.electricCurrent] { update(characteristic, current) }
            }
        }
    }
}

/// SONOFF SwitchMan R5 and other multi-channel programmable switches: six stateless switches (Channel 1 to 6)
/// with single, double and long presses (`outlet` 0-5, `key` 0-2, a recent `actionTime`).
final class SwitchMiniAccessory: BaseAccessory {
    private var channels: [Int: Service] = [:]
    private var debouncing: Set<Int> = []

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .programmableSwitch
        for channel in 1...6 {
            let name = "Channel \(channel)"
            let service = addService(
                .statelessProgrammableSwitch, name: name, subtype: "channel\(channel)",
                optional: [CharacteristicType.programmableSwitchEvent.with(minValue: 0, maxValue: 2, validValues: [0, 1, 2])],
                extra: [Characteristic(.configuredName, value: .string(name)), Characteristic(.serviceLabelIndex, value: .int(channel))],
                primary: channel == 1)
            channels[channel] = service
        }
        service = channels[1]
        logInfo("SONOFF Mini initialized with 6 programmable switch channels")
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        guard case .number(let outletNumber) = params["outlet"], case .string(let actionTime) = params["actionTime"] else { return }
        guard let outlet = Int(exactly: outletNumber), (0...5).contains(outlet) else { return }
        let key = params["key"]?.doubleValue?.clampedInt ?? 0
        let channel = outlet + 1
        guard !debouncing.contains(channel) else { return }
        debouncing.insert(channel)
        setTrackedTimeout(Double(Timing.eventDebounce)) { [weak self] in self?.debouncing.remove(channel) }
        guard isRecent(actionTime, now: platform.clock.nowMilliseconds), let service = channels[channel] else { return }
        service.characteristic(.programmableSwitchEvent).sendEvent(.int(key))
        logInfo("Channel \(channel): \(key == 0 ? "Single" : key == 1 ? "Double" : "Long") press")
    }
}

/// SONOFF S-MATE: one stateless switch; `outlet` 0, 1, 2 are single, double and long presses.
final class SwitchMateAccessory: BaseAccessory {
    private var debouncing: Set<Int> = []

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .programmableSwitch
        service = addService(
            .statelessProgrammableSwitch, optional: [CharacteristicType.programmableSwitchEvent.with(minValue: 0, maxValue: 2, validValues: [0, 1, 2])],
            primary: true)
        logInfo("SONOFF Mate initialized with programmable switch (single/double/long press)")
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        guard case .number(let outletNumber) = params["outlet"], case .string(let actionTime) = params["actionTime"] else { return }
        guard let outlet = Int(exactly: outletNumber), (0...2).contains(outlet), !debouncing.contains(outlet) else { return }
        debouncing.insert(outlet)
        setTrackedTimeout(Double(Timing.eventDebounce)) { [weak self] in self?.debouncing.remove(outlet) }
        guard isRecent(actionTime, now: platform.clock.nowMilliseconds) else { return }
        service.characteristic(.programmableSwitchEvent).sendEvent(.int(outlet))
        logInfo("Button press: \(outlet == 0 ? "Single" : outlet == 1 ? "Double" : "Long")")
    }
}

/// An eWeLink cloud group (UIID 5000): one switch for every device in it, sent through the HTTP API.
final class GroupAccessory: BaseAccessory {
    private var cacheState = "off"

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        super.init(platform: platform, record: record, box: box)
        category = .switch
        service = addService(.switch, primary: true)
        onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.cacheState == "on") }
        onWrite(service.characteristic(.on)) { [weak self] value in try await self?.setOn(value) }
        if let state = deviceParams["switch"]?.jsString {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
        }
        if let first = deviceParams.switches?.first, let state = first["switch"]?.jsString {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
        }
        logDebug("Group initialized with state \(cacheState)")
    }

    private func setOn(_ value: HAPValue) async throws {
        let state = value.boolValue == true ? "on" : "off"
        guard state != cacheState else { return }
        logInfo("Setting group to \(state)")
        let params: DeviceParams = deviceParams.switches != nil
            ? ["switches": [["switch": .string(state), "outlet": 0]]]
            : ["switch": .string(state)]
        guard await sendCommand(params) else { throw communicationError }
        cacheState = state
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if let state = params["switch"]?.jsString, state != cacheState {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
            logDebug("Group state updated to \(cacheState)")
        }
        if let first = params.switches?.first, let state = first["switch"]?.jsString, state != cacheState {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
            logDebug("Group state updated to \(cacheState) (SCM format)")
        }
    }
}

/// A virtual device (UIID 265): a button (stateless switch) when it reports a `key`, else a switch.
final class VirtualAccessory: BaseAccessory {
    let isButton: Bool
    private var cacheState = "off"

    override init(platform: EWeLinkPlatform, record: AccessoryRecord, box: DeviceBox) {
        isButton = box.params["key"] != nil
        super.init(platform: platform, record: record, box: box)
        if isButton {
            category = .programmableSwitch
            service = addService(
                .statelessProgrammableSwitch, optional: [CharacteristicType.programmableSwitchEvent.with(minValue: 0, maxValue: 2, validValues: [0, 1, 2])],
                primary: true)
            logDebug("Configured as virtual button")
        } else {
            category = .switch
            service = addService(.switch, primary: true)
            onRead(service.characteristic(.on), "On") { [weak self] in .bool(self?.cacheState == "on") }
            onWrite(service.characteristic(.on)) { [weak self] value in try await self?.setOn(value) }
            logDebug("Configured as virtual switch")
            if let state = deviceParams["switch"]?.jsString {
                cacheState = state
                service.characteristic(.on).value = .bool(cacheState == "on")
            }
        }
    }

    private func setOn(_ value: HAPValue) async throws {
        guard !isButton else { return }
        let state = value.boolValue == true ? "on" : "off"
        guard state != cacheState else { return }
        logInfo("Setting virtual switch to \(state)")
        guard await sendCommand(["switch": .string(state)]) else { throw communicationError }
        cacheState = state
    }

    override func updateState(_ params: DeviceParams) {
        mergeDeviceParams(params)
        if isButton {
            guard let key = params["key"] else { return }
            let text = key.jsString ?? ""
            let event = text.contains("double") ? 1 : text.contains("long") ? 2 : 0
            service.characteristic(.programmableSwitchEvent).sendEvent(.int(event))
            logDebug("Button pressed: \(text) (event type: \(event))")
        } else if let state = params["switch"]?.jsString, state != cacheState {
            cacheState = state
            service.characteristic(.on).value = .bool(cacheState == "on")
            logDebug("Virtual switch updated to \(cacheState)")
        }
    }
}

/// Whether an `actionTime` (ISO 8601) is less than five seconds old.
func isRecent(_ actionTime: String, now: Double) -> Bool {
    guard let date = parseISODate(actionTime) else { return false }
    return (now - date.timeIntervalSince1970 * 1000) / 1000 < Timing.eventFreshnessSeconds
}

/// `Date.parse` for the ISO 8601 timestamps eWeLink sends, with or without fractional seconds.
func parseISODate(_ text: String) -> Date? {
    (try? fractionalISODate.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text))
}

private let fractionalISODate = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
