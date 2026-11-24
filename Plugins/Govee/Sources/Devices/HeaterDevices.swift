import Foundation
import HomeswiftPlugin
import Homeswift

/// The H7130 family without temperature reporting (`device/heater1a.ts`): a fan with three speeds, swing and
/// child lock. `Heater1bDevice` adds the thermostat for the ones that report temperatures (`tempReporting`).
class Heater1aDevice: GoveeDevice {
    static let speedStep = 33
    static let speedValues = [0, 33, 66, 99]
    /// Temperatures come in hundredths of °F; a converted value above this is not a reading.
    static let temperatureThreshold = 100.0

    var service: Service!
    var cacheSpeed = 33
    var cacheSwing = "off"
    var cacheLock = "off"

    override var category: AccessoryCategory { .heater }

    /// The service with the speed.
    var speedService: Service { service }

    override func configure() {
        service = addService(.fanv2, characteristics: [.swingMode, .lockPhysicalControls, speedType], primary: true)
        setupPowerSwingAndLock()
        setupSpeed()
        logInitOptions([("tempReporting", "false")])
        initialised = true
    }

    var speedType: CharacteristicType { .rotationSpeed.with(minStep: Double(Self.speedStep), validValues: Self.speedValues) }

    func setupPowerSwingAndLock() {
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        setupSwingAndLock()
    }

    func setupSwingAndLock() {
        service.characteristic(.swingMode).onWrite { [weak self] value in try await self?.internalSwingUpdate(value.intValue ?? 0) }
        cacheSwing = int(service[.swingMode]) == 1 ? "on" : "off"
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
    }

    func setupSpeed() {
        speedService.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.intValue ?? 0) }
        cacheSpeed = int(speedService[.rotationSpeed])
    }

    /// The power changed, from HomeKit or the device.
    func stateChanged(_ state: String) {}

    /// Shows the power the device reported.
    func showState() { update(service[.active], cacheState == "on" ? 1 : 0) }

    private func internalStateUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheState, label: Lang.curState, service[.active], revert: .int(cacheState == "on" ? 1 : 0)) {
            .ptReal(Catalog.deviceStateCodes[$0]!)
        }
        guard let state else { return }
        cacheState = state
        stateChanged(state)
    }

    private func internalSwingUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheSwing, label: Lang.curSwing, service[.swingMode], revert: .int(cacheSwing == "on" ? 1 : 0)) {
            .ptReal(Catalog.heaterSwingCodes[$0]!)
        }
        if let state { cacheSwing = state }
    }

    private func internalLockUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheLock, label: Lang.curLock, service[.lockPhysicalControls], revert: .int(cacheLock == "on" ? 1 : 0)) {
            .ptReal(Catalog.lockCodes[$0]!)
        }
        if let state { cacheLock = state }
    }

    private func internalSpeedUpdate(_ value: Int) async throws {
        guard cacheSpeed != value, value != 0, let code = Catalog.heaterH7130SpeedCodes[value] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = value
            log("\(Lang.curSpeed) [\(Catalog.heaterSpeedLabels[value] ?? "")]")
        } catch {
            throw failed(error, speedService[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            showState()
            log("\(Lang.curState) [\(cacheState)]")
            stateChanged(cacheState)
        }
        temperatures(update)
        if let commands = update.commands {
            Govee.processCommands(commands, commandHandlers()) { [unowned self] command, hex, _ in newScene(command, hex) }
        }
    }

    /// This variant reports no temperature: a plausible reading means it should have `tempReporting`.
    func temperatures(_ update: DeviceUpdate) {
        if let temperature = update.temperature {
            let converted = Govee.nearestHalf(Govee.farToCen(temperature / Self.temperatureThreshold))
            if converted <= Self.temperatureThreshold { logWarn("you should enable `tempReporting` in the config for this device") }
        }
    }

    func commandHandlers() -> [String: Govee.CommandHandler] {
        [
            "1800": { [unowned self] parts, _ in swingReport(parts) },
            "1801": { [unowned self] parts, _ in swingReport(parts) },
            "1000": { [unowned self] parts, _ in lockReport(parts) },
            "1001": { [unowned self] parts, _ in lockReport(parts) },
            "0501": { [unowned self] parts, _ in speedReport(parts) },
            "0502": { [unowned self] parts, _ in speedReport(parts) },
            "0503": { [unowned self] parts, _ in speedReport(parts) },
            "1a00": { _, _ in },
            "1a01": { _, _ in },
        ]
    }

    private func swingReport(_ parts: [String]) {
        let swing = Govee.item(parts, 3) == "01" ? "on" : "off"
        guard cacheSwing != swing else { return }
        cacheSwing = swing
        update(service[.swingMode], cacheSwing == "on" ? 1 : 0)
        log("\(Lang.curSwing) [\(cacheSwing)]")
    }

    private func lockReport(_ parts: [String]) {
        let lock = Govee.item(parts, 3) == "01" ? "on" : "off"
        guard cacheLock != lock else { return }
        cacheLock = lock
        update(service[.lockPhysicalControls], cacheLock == "on" ? 1 : 0)
        log("\(Lang.curLock) [\(cacheLock)]")
    }

    func speedReport(_ parts: [String]) {
        let speeds = ["01": Self.speedValues[1], "02": Self.speedValues[2], "03": Self.speedValues[3]]
        guard let speed = speeds[Govee.item(parts, 3)], cacheSpeed != speed else { return }
        cacheSpeed = speed
        update(speedService[.rotationSpeed], cacheSpeed)
        log("\(Lang.curSpeed) [\(Catalog.heaterSpeedLabels[cacheSpeed] ?? "")]")
    }
}

/// The H7130 family with temperature reporting (`device/heater1b.ts`): a heater-cooler with auto (the heater's
/// thermostat keeps the target) and heat, a 5-30°C target, and a fan tile for the speed that follows the heater. The
/// Heater Cooler is a `ClimateController`'s (ADR 0013).
final class Heater1bDevice: Heater1aDevice {
    static let defaultTemperature = 20.0

    private var climate: ClimateController!
    private var fan: Service!
    private var cacheMode = "auto"
    private var cacheTemp = 20.0
    private var cacheTarget = 20
    private var cacheFanState = "off"

    override var speedService: Service { fan }

    override func configure() {
        let range = Double(Catalog.heaterTempMin)...Double(Catalog.heaterTempMax)
        climate = addClimate(capabilities: ClimateCapabilities(modes: [.auto, .heat], setpoints: .single, range: range, step: 1),
                             characteristics: [.swingMode, .lockPhysicalControls], primary: true) { [weak self] command in
            try await self?.apply(command)
        }
        service = climate.service
        if let cached = cachedService(.heaterCooler) {
            cacheState = cached[.active]?.value.intValue == 1 ? "on" : "off"
            cacheMode = cached[.targetHeaterCoolerState]?.value.intValue == 1 ? "heat" : "auto"
            cacheTemp = cached[.currentTemperature]?.value.doubleValue ?? Self.defaultTemperature
            cacheTarget = Govee.roundInt(cachedClimateTarget() ?? Self.defaultTemperature)
        }
        fan = addService(.fan, characteristics: [speedType])
        setupSwingAndLock()
        fan.characteristic(.on).onWrite { [weak self] value in await self?.internalFanStateUpdate(value.boolValue ?? false) }
        cacheFanState = bool(fan[.on]) ? "on" : "off"
        setupSpeed()
        showClimate()
        logInitOptions([("tempReporting", "true")])
        initialised = true
    }

    /// The fan tile follows the heater's power.
    override func stateChanged(_ state: String) {
        guard cacheFanState != state else { return }
        cacheFanState = state
        update(fan[.on], state == "on")
    }

    override func showState() { showClimate() }

    private func showClimate() {
        climate.update(ClimateReport(power: cacheState == "on", mode: cacheMode == "auto" ? .auto : .heat, current: cacheTemp,
                                     target: Double(cacheTarget)))
    }

    private func codes(_ mode: String) -> [Int: String] { mode == "auto" ? Catalog.heaterH7130TempCodesAuto : Catalog.heaterH7130TempCodesHeat }

    /// The power, then the mode and the target together: one code says both. A failure after the power was sent puts
    /// the power kept back, as the controller shows it: the next report of it is then not taken for no change.
    private func apply(_ command: ClimateCommand) async throws {
        let previousState = cacheState
        do {
            if let power = command.power {
                let state = power ? "on" : "off"
                try await send(.ptReal(Catalog.deviceStateCodes[state]!))
                cacheState = state
                log("\(Lang.curState) [\(state)]")
                stateChanged(state)
            }
            guard command.mode != nil || command.target != nil else { return }
            let mode = command.mode.map { $0 == .auto ? "auto" : "heat" } ?? cacheMode
            let target = command.target.map(Govee.roundInt) ?? cacheTarget
            guard mode != cacheMode || target != cacheTarget else { return }
            guard let code = codes(mode)[target] else { throw GoveeAPIError.message("no code for \(target)°C") }
            try await send(.ptReal(code))
            if mode != cacheMode { log("\(Lang.curMode) [\(mode)]") }
            if target != cacheTarget { log("\(Lang.curTarg) [\(target)°C]") }
            cacheMode = mode
            cacheTarget = target
        } catch {
            if cacheState != previousState {
                cacheState = previousState
                stateChanged(previousState)
            }
            throw climateFailed(error)
        }
    }

    /// The fan runs only with the heater: a manual toggle is put back.
    private func internalFanStateUpdate(_ value: Bool) async {
        let newValue = value ? "on" : "off"
        guard cacheFanState != newValue else { return }
        if newValue == "on" {
            schedule(after: .seconds(3)) { [weak self] in self?.update(self?.fan[.on], false) }
            return
        }
        schedule(after: .seconds(2)) { [weak self] in
            guard let self else { return }
            self.update(self.fan[.on], true)
            self.update(self.fan[.rotationSpeed], self.cacheSpeed)
        }
    }

    override func temperatures(_ update: DeviceUpdate) {
        if let temperature = update.temperature {
            let converted = Govee.nearestHalf(Govee.farToCen(temperature / Self.temperatureThreshold))
            if converted != cacheTemp {
                if converted > Self.temperatureThreshold {
                    logWarn("you should disable `tempReporting` in the config for this device")
                } else {
                    cacheTemp = converted
                    showClimate()
                    log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C]")
                }
            }
        }
        if let target = update.setTemperature {
            let converted = Govee.roundInt(Govee.farToCen(target / Self.temperatureThreshold))
            if converted != cacheTarget {
                cacheTarget = converted
                showClimate()
                log("\(Lang.curTarg) [\(cacheTarget)°C]")
            }
        }
    }

    override func commandHandlers() -> [String: Govee.CommandHandler] {
        var handlers = super.commandHandlers()
        handlers["1a00"] = { [unowned self] parts, _ in modeReport(parts) }
        handlers["1a01"] = { [unowned self] parts, _ in modeReport(parts) }
        for ignored in ["1100", "1101", "1300", "1600", "1601"] { handlers[ignored] = { _, _ in } }
        return handlers
    }

    override func speedReport(_ parts: [String]) {
        // A speed report while the heater runs means the fan runs too.
        if cacheState == "on", cacheFanState != "on" {
            cacheFanState = "on"
            update(fan[.on], true)
            log("\(Lang.curMode) [\(cacheFanState)]")
        }
        super.speedReport(parts)
    }

    private func modeReport(_ parts: [String]) {
        let mode = Govee.item(parts, 3) == "01" ? "auto" : "heat"
        guard cacheMode != mode else { return }
        cacheMode = mode
        showClimate()
        log("\(Lang.curMode) [\(cacheMode)]")
    }
}

/// The H7131 and H7132 (`device/heater2.ts`): a heater-cooler (auto keeps a 5-30°C target with the heater's
/// thermostat, heat runs at a fan speed), a fan for fan-only, low, medium and high, and the night light with its colour.
/// The Heater Cooler is a `ClimateController`'s (ADR 0013): fan-only, which does not heat, is an Other Mode.
final class Heater2Device: GoveeDevice {
    static let defaultTemperature = 20.0
    /// Heat's slowest speed: the fan tile's 25 is fan-only.
    static let heatSpeed = 50

    private var climate: ClimateController!
    private var service: Service!
    private var fan: Service!
    private var nightLight: NightLight!
    private var cacheMode = "auto"
    private var cacheTemp = 20.0
    private var cacheTarget = 20
    private var cacheSpeed = 0
    private var cacheSwing = "off"
    private var cacheLock = "off"
    private var cacheFanState = "off"

    override var category: AccessoryCategory { .heater }

    override func configure() {
        climate = addClimate(capabilities: ClimateCapabilities(modes: [.auto, .heat], setpoints: .single, range: 5...30, step: 1),
                             characteristics: [.swingMode, .lockPhysicalControls], primary: true) { [weak self] command in
            try await self?.apply(command)
        }
        service = climate.service
        if let cached = cachedService(.heaterCooler) {
            cacheState = cached[.active]?.value.intValue == 1 ? "on" : "off"
            cacheTemp = cached[.currentTemperature]?.value.doubleValue ?? Self.defaultTemperature
            cacheTarget = Govee.roundInt(cachedClimateTarget() ?? Self.defaultTemperature)
        }
        fan = addService(.fan, characteristics: [.rotationSpeed.with(minStep: 25, validValues: [0, 25, 50, 75, 100])])
        nightLight = NightLight(self, frames: .separate)

        service.characteristic(.swingMode).onWrite { [weak self] value in try await self?.internalSwingUpdate(value.intValue ?? 0) }
        cacheSwing = int(service[.swingMode]) == 1 ? "on" : "off"
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
        fan.characteristic(.on).onWrite { [weak self] value in await self?.internalFanStateUpdate(value.boolValue ?? false) }
        cacheFanState = bool(fan[.on]) ? "on" : "off"
        fan.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.intValue ?? 0) }
        cacheSpeed = int(fan[.rotationSpeed])
        cacheMode = Catalog.heater2SpeedLabels[cacheSpeed] ?? "auto"
        showClimate()
        logInitOptions([])
        initialised = true
    }

    /// Auto is auto, low to high heat, fan-only an Other Mode.
    private var climateMode: ClimateMode? {
        switch cacheMode {
        case "auto": .auto
        case "fan-only": nil
        default: .heat
        }
    }

    private func showClimate() {
        climate.update(ClimateReport(power: cacheState == "on", mode: climateMode, current: cacheTemp, target: Double(cacheTarget)))
    }

    /// The power, then the mode, then the target. The heater takes a target only in auto: a target alone while it heats at
    /// a speed switches it to auto, as it did; with Heat chosen in the same change, it is kept for auto.
    private func apply(_ command: ClimateCommand) async throws {
        do {
            if let power = command.power {
                try await send(.stateHeat(power))
                if !power { update(fan[.on], false) }
                cacheState = power ? "on" : "off"
                log("\(Lang.curState) [\(cacheState)]")
            }
            let target = command.target.map(Govee.roundInt)
            if command.mode == .heat {
                let speed = cacheSpeed >= Self.heatSpeed ? cacheSpeed : Self.heatSpeed
                try await send(.multiSync(Catalog.heater2SpeedCodes[speed]!))
                cacheFanState = "on"
                cacheSpeed = speed
                update(fan[.on], true)
                update(fan[.rotationSpeed], speed)
                setMode(Catalog.heater2SpeedLabels[speed]!)
                if let target { setTarget(target) }
            } else if command.mode == .auto || target != nil {
                let value = target ?? cacheTarget
                let codes = command.mode == nil && cacheMode == "auto" ? Catalog.heater2TempCodesAuto : Catalog.heater2TempCodesAutoTurn
                guard let code = codes[value] else { throw GoveeAPIError.message("no code for \(value)°C") }
                try await send(.multiSync(code))
                if command.mode == .auto { update(fan[.on], false) }
                let switched = cacheMode != "auto"
                setMode("auto")
                setTarget(value)
                // Switched to auto by the target: shown now, the controller keeping the mode it was not asked for.
                if switched, command.mode == nil { showClimate() }
            }
        } catch {
            throw climateFailed(error)
        }
    }

    private func setMode(_ mode: String) {
        guard cacheMode != mode else { return }
        cacheMode = mode
        log("\(Lang.curMode) [\(cacheMode)]")
    }

    private func setTarget(_ target: Int) {
        guard cacheTarget != target else { return }
        cacheTarget = target
        log("\(Lang.curTarg) [\(cacheTarget)°C]")
    }

    private func internalSwingUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheSwing, label: Lang.curSwing, service[.swingMode], revert: .int(cacheSwing == "on" ? 1 : 0)) {
            .multiSync(Catalog.heater2SwingCodes[$0]!)
        }
        if let state { cacheSwing = state }
    }

    private func internalLockUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheLock, label: Lang.curLock, service[.lockPhysicalControls], revert: .int(cacheLock == "on" ? 1 : 0)) {
            .multiSync(Catalog.heater2LockCodes[$0]!)
        }
        if let state { cacheLock = state }
    }

    private func internalFanStateUpdate(_ value: Bool) async {
        let newValue = value ? "on" : "off"
        guard cacheFanState != newValue else { return }
        if newValue == "on" {
            if cacheState != "on" {
                cacheState = "on"
                showClimate()
                log("\(Lang.curState) [\(cacheState)]")
            }
            cacheFanState = "on"
            return
        }
        // The fan off: back to auto mode.
        cacheFanState = "off"
        cacheMode = "auto"
        showClimate()
        log("\(Lang.curMode) [\(cacheMode)]")
    }

    private func internalSpeedUpdate(_ value: Int) async throws {
        guard cacheSpeed != value, value != 0, let code = Catalog.heater2SpeedCodes[value] else { return }
        do {
            try await send(.multiSync(code))
            cacheFanState = "on"
            cacheState = "on"
            if cacheSpeed != value {
                cacheSpeed = value
                cacheMode = Catalog.heater2SpeedLabels[value] ?? cacheMode
                log("\(Lang.curMode) [\(cacheMode)]")
            }
            showClimate()
        } catch {
            throw failed(error, fan[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            showClimate()
            log("\(Lang.curState) [\(cacheState)]")
        }
        if let temperature = update.temperature {
            let converted = Govee.nearestHalf(Govee.farToCen(temperature / 100))
            if converted != cacheTemp {
                cacheTemp = converted
                showClimate()
                log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C]")
            }
        }
        if let target = update.setTemperature {
            let converted = Govee.roundInt(Govee.farToCen(target / 100))
            if converted != cacheTarget {
                cacheTarget = converted
                cacheFanState = "off"
                cacheSpeed = 0
                cacheMode = "auto"
                showClimate()
                log("\(Lang.curTarg) [\(cacheTarget)°C]")
            }
        }
        guard let commands = update.commands else { return }
        var handlers: [String: Govee.CommandHandler] = [
            "1b01": { [unowned self] parts, _ in nightLight.stateReport(parts) },
            "1b05": { [unowned self] parts, _ in nightLight.report(colour: parts) },
            "1f00": { [unowned self] parts, _ in swingLockReport(parts) },
            "1f01": { [unowned self] parts, _ in swingLockReport(parts) },
            "0509": { [unowned self] _, _ in fanMode("fan-only", speed: 25) },
            "0501": { [unowned self] parts, _ in
                switch Govee.item(parts, 4) {
                case "01": fanMode("low", speed: 50)
                case "02": fanMode("medium", speed: 75)
                case "03": fanMode("high", speed: 100)
                default: break
                }
            },
            "0503": { [unowned self] _, _ in fanMode("auto", speed: 0) },
        ]
        for ignored in ["1a00", "1100", "1101", "1600", "1601"] { handlers[ignored] = { _, _ in } }
        Govee.processCommands(commands, handlers) { [unowned self] command, hex, _ in newScene(command, hex) }
    }

    private func swingLockReport(_ parts: [String]) {
        let swing = Govee.item(parts, 3) == "01" ? "on" : "off"
        if cacheSwing != swing {
            cacheSwing = swing
            update(service[.swingMode], cacheSwing == "on" ? 1 : 0)
            log("\(Lang.curSwing) [\(cacheSwing)]")
        }
        let lock = Govee.item(parts, 4) == "01" ? "on" : "off"
        if cacheLock != lock {
            cacheLock = lock
            update(service[.lockPhysicalControls], cacheLock == "on" ? 1 : 0)
            log("\(Lang.curLock) [\(cacheLock)]")
        }
    }

    /// A mode report: the fan's state and speed and the heater's mode follow it.
    private func fanMode(_ mode: String, speed: Int) {
        guard cacheMode != mode else { return }
        cacheMode = mode
        cacheFanState = speed > 0 ? "on" : "off"
        cacheSpeed = speed
        update(fan[.on], speed > 0)
        update(fan[.rotationSpeed], speed)
        showClimate()
        log("\(Lang.curMode) [\(cacheMode)]")
    }
}
