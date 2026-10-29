import Foundation
import HomeswiftPlugin
import Homeswift

/// A plug shown as a heater or a cooler (`device/heater-single.ts`, `device/cooler-single.ts`): a thermostat
/// in the plugin, switching the plug on and off around the target from the temperature another Govee sensor
/// reports (`temperatureSource`).
final class ThermostatPlugDevice: GoveeDevice {
    enum Mode: String { case heater, cooler }

    let mode: Mode
    private var service: Service!
    private let temperatureSource: String
    private var cacheTemp = 20.0
    /// Heating or cooling: the plug is on.
    private var cacheActive = "off"
    private var cacheTarget = 20.0
    private var poller: Task<Void, Never>?

    init(environment: DeviceEnvironment, mode: Mode) {
        self.mode = mode
        temperatureSource = environment.settings.temperatureSource ?? ""
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { mode == .heater ? .heater : .airConditioner }

    private var threshold: CharacteristicType { mode == .heater ? .heatingThresholdTemperature : .coolingThresholdTemperature }
    /// HomeKit's current state while the plug runs: 2 heating, 3 cooling.
    private var runningState: Int { mode == .heater ? 2 : 3 }

    override func configure() {
        // A plug switched from heater to cooler, or back, starts again from 20°C.
        let store = environment.store
        if store.value(info.id, "cacheType")?.stringValue != mode.rawValue {
            store.set(info.id, "cacheType", .string(mode.rawValue))
            store.set(info.id, "cacheTarget", 20)
        }
        cacheTarget = store.value(info.id, "cacheTarget")?.doubleValue ?? 20
        service = addService(.heaterCooler, characteristics: [
            .currentTemperature.with(minStep: 0.1), .targetHeaterCoolerState.with(minValue: 0, maxValue: 0, validValues: [0]), threshold.with(minStep: 0.5),
        ], primary: true)
        // Until the source sensor reports, 20°C (the Homebridge plugin's starting value).
        if environment.cached?.service(.heaterCooler) == nil { update(service[.currentTemperature], 20.0) }
        cacheTemp = double(service[.currentTemperature])
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        update(service[threshold], cacheTarget)
        service.characteristic(threshold).onWrite { [weak self] value in try await self?.internalTargetUpdate(value.doubleValue ?? 20) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        cacheActive = cacheState == "on" && int(service[mode == .heater ? .targetHeaterCoolerState : .currentHeaterCoolerState]) == runningState ? "on" : "off"
        startCustomHistory()
        // Temperatures from the source sensor, five seconds in and then every two minutes.
        let firstRead = environment.temperatureSourceFirstRead
        poller = Task { [weak self] in
            try? await Task.sleep(for: firstRead)
            while !Task.isCancelled {
                await self?.readTemperature()
                try? await Task.sleep(for: .seconds(120))
            }
        }
        logInitOptions([("showAs", "\"\(mode.rawValue)\""), ("temperatureSource", "\"\(temperatureSource)\"")])
        initialised = true
    }

    override func destroy() {
        super.destroy()
        poller?.cancel()
        poller = nil
    }

    /// Whether the plug should run at this temperature.
    private func shouldRun(_ temperature: Double, target: Double) -> Bool {
        mode == .heater ? temperature < target : temperature > target
    }

    private func logActive() {
        log("\(mode == .heater ? Lang.curHeat : Lang.curCool) [\(cacheActive)]")
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newState: String
        let newActive: String
        if value == 0 {
            (newState, newActive) = ("off", "off")
        } else if shouldRun(cacheTemp, target: cacheTarget) {
            (newState, newActive) = ("on", "on")
        } else {
            (newState, newActive) = ("on", "off")
        }
        do {
            // Only when switching off a running plug, or switching on one that has to run.
            if (value == 0 && cacheActive == "on") || (value == 1 && newActive == "on") {
                holdReports()
                try await send(.stateOutlet(newActive == "on"))
            }
            if newState != cacheState {
                cacheState = newState
                log("\(Lang.curState) [\(cacheState)]")
            }
            if newActive != cacheActive {
                cacheActive = newActive
                logActive()
            }
            update(service[.currentHeaterCoolerState], value == 1 ? (cacheActive == "on" ? runningState : 1) : 0)
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    private func internalTargetUpdate(_ value: Double) async throws {
        guard value != cacheTarget else { return }
        cacheTarget = value
        environment.store.set(info.id, "cacheTarget", .number(value))
        log("\(Lang.curTarg) [\(DeviceUpdate.format(value))°C]")
        guard cacheState != "off" else { return }
        let newActive = shouldRun(cacheTemp, target: value) ? "on" : "off"
        guard newActive != cacheActive else { return }
        do {
            holdReports()
            try await send(.stateOutlet(newActive == "on"))
            cacheActive = newActive
            logActive()
            update(service[.currentHeaterCoolerState], cacheActive == "on" ? runningState : 1)
        } catch {
            throw failed(error, service[threshold], revert: .double(cacheTarget))
        }
    }

    private func currentTemperatureChanged() async {
        guard cacheState != "off" else { return }
        let newActive = shouldRun(cacheTemp, target: cacheTarget) ? "on" : "off"
        guard newActive != cacheActive else { return }
        do {
            holdReports()
            try await send(.stateOutlet(newActive == "on"))
            cacheActive = newActive
            logActive()
            update(service[.currentHeaterCoolerState], cacheActive == "on" ? runningState : 1)
        } catch {
            logWarn("\(error)")
        }
    }

    private func readTemperature() async {
        guard let temperature = environment.store.temperature(of: temperatureSource), temperature != 0, temperature != cacheTemp else { return }
        cacheTemp = temperature
        update(service[.currentTemperature], cacheTemp)
        addHistory(temp: cacheTemp)
        log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C]")
        await currentTemperatureChanged()
    }
}

/// A plug shown as an air purifier, and the purifiers without a model of their own: on and off, with Eve
/// history (`device/purifier.ts`).
final class PurifierDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory { .airPurifier }

    override func configure() {
        service = addService(.airPurifier, characteristics: [.targetAirPurifierState.with(minValue: 1, maxValue: 1, validValues: [1])], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        update(service[.targetAirPurifierState], 1)
        startHistory(.switch)
        logInitOptions([("showAs", "\"purifier\"")])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard newValue != cacheState else { return }
        holdReports()
        do {
            try await send(.stateOutlet(newValue == "on"))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
            addHistory(status: value != 0 ? 1 : 0)
            update(service[.currentAirPurifierState], value == 1 ? 2 : 0)
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard !isHoldingReports else { return }
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.currentAirPurifierState], cacheState == "on" ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
            addHistory(status: cacheState == "on" ? 1 : 0)
        }
    }
}

/// A plug shown as a tap (valve type 3) or an irrigation valve (type 1, with a duration and a timer)
/// (`device/tap.ts`, `device/valve.ts`).
final class ValvePlugDevice: GoveeDevice {
    enum Kind { case tap, valve }

    let kind: Kind
    private var service: Service!
    private var timer: Task<Void, Never>?

    init(environment: DeviceEnvironment, kind: Kind) {
        self.kind = kind
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { kind == .tap ? .faucet : .sprinkler }

    override func configure() {
        let valveType = kind == .tap ? 3 : 1
        // A valve shown as the other kind before starts from scratch.
        let fresh = environment.store.value(info.id, "valveType")?.intValue != valveType
        environment.store.set(info.id, "valveType", .number(Double(valveType)))
        let extra: [CharacteristicType] = kind == .valve ? [.setDuration, .remainingDuration] : []
        service = addService(.valve, characteristics: extra, primary: true)
        update(service[.valveType], valveType)
        if fresh {
            update(service[.active], 0)
            update(service[.inUse], 0)
            if kind == .valve { update(service[.setDuration], 120) }
        }
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        if kind == .valve {
            service.characteristic(.setDuration).onWrite { @GoveeActor [weak self] value in
                guard let self, self.int(self.service[.inUse]) == 1 else { return }
                let duration = value.intValue ?? 0
                self.update(self.service[.remainingDuration], duration)
                self.timer?.cancel()
                self.timer = self.schedule(after: .seconds(duration)) { [weak self] in self?.closeByTimer() }
            }
        }
        logInitOptions([("showAs", kind == .tap ? "\"tap\"" : "\"valve\"")])
        initialised = true
    }

    /// The timer ran out: closes the valve as HomeKit would (`setCharacteristic(Active, 0)`).
    private func closeByTimer() {
        let active = service.characteristic(.active)
        Task { @GoveeActor [weak self] in
            try? await self?.internalStateUpdate(0)
            active.value = 0
        }
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard newValue != cacheState else { return }
        holdReports()
        do {
            try await send(.stateOutlet(newValue == "on"))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
            update(service[.inUse], value)
            guard kind == .valve else { return }
            if value == 0 {
                update(service[.remainingDuration], 0)
                timer?.cancel()
            } else {
                let duration = int(service[.setDuration])
                update(service[.remainingDuration], duration)
                timer = schedule(after: .seconds(duration)) { [weak self] in self?.closeByTimer() }
            }
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard !isHoldingReports, let state = update.state, state != cacheState else { return }
        cacheState = state
        switch kind {
        case .tap:
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.inUse], cacheState == "on" ? 1 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        case .valve:
            if cacheState == "on" {
                guard int(service[.active]) == 0 else { return }
                let duration = int(service[.setDuration])
                self.update(service[.active], 1)
                self.update(service[.inUse], 1)
                self.update(service[.remainingDuration], duration)
                log("\(Lang.curState) [\(cacheState)]")
                timer = schedule(after: .seconds(duration)) { [weak self] in self?.closeByTimer() }
            } else {
                self.update(service[.active], 0)
                self.update(service[.inUse], 0)
                self.update(service[.remainingDuration], 0)
                timer?.cancel()
            }
        }
    }
}

/// A plug shown as an audio receiver, a set-top box or a streaming stick: a television with power only
/// (`device/tv.ts`). On the bridge, as the Homebridge plugin put it.
final class TelevisionPlugDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory {
        switch settings.showAs {
        case "audio": .audioReceiver
        case "box": .tvSetTopBox
        default: .tvStreamingStick
        }
    }

    override func configure() {
        service = addService(.television, characteristics: [.configuredName], primary: true)
        update(service[.configuredName], .string(info.name))
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        logInitOptions([("showAs", "\"audio/box/stick\"")])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard newValue != cacheState else { return }
        holdReports()
        do {
            try await send(.stateOutlet(newValue == "on"))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard !isHoldingReports, let state = update.state, state != cacheState else { return }
        cacheState = state
        self.update(service[.active], cacheState == "on" ? 1 : 0)
        log("\(Lang.curState) [\(cacheState)]")
    }
}
