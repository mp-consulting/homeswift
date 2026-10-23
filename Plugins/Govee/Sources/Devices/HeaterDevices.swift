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
            self.update(service[.active], cacheState == "on" ? 1 : 0)
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

/// The H7130 family with temperature reporting (`device/heater1b.ts`): a heater-cooler with auto and heat
/// modes and a 5-30°C target, and a fan tile for the speed that follows the heater.
final class Heater1bDevice: Heater1aDevice {
    static let defaultTemperature = 20.0

    private var fan: Service!
    private var cacheMode = "auto"
    private var cacheTemp = 20.0
    private var cacheTarget = 20
    private var cacheFanState = "off"

    override var speedService: Service { fan }

    override func configure() {
        let fresh = environment.cached?.service(.heaterCooler) == nil
        service = addService(.heaterCooler, characteristics: [
            .swingMode, .lockPhysicalControls, .targetHeaterCoolerState.with(minValue: 0, maxValue: 1, validValues: [0, 1]),
            .heatingThresholdTemperature.with(minValue: Double(Catalog.heaterTempMin), maxValue: Double(Catalog.heaterTempMax), minStep: 1),
        ], primary: true)
        if fresh {
            update(service[.currentTemperature], Self.defaultTemperature)
            update(service[.heatingThresholdTemperature], Self.defaultTemperature)
        }
        fan = addService(.fan, characteristics: [speedType])
        setupPowerSwingAndLock()
        service.characteristic(.targetHeaterCoolerState).onWrite { [weak self] value in try await self?.internalModeUpdate(value.intValue ?? 0) }
        cacheMode = int(service[.targetHeaterCoolerState]) == 0 ? "auto" : "heat"
        cacheTemp = double(service[.currentTemperature])
        service.characteristic(.heatingThresholdTemperature).onWrite { [weak self] value in try await self?.internalTemperatureUpdate(value.intValue ?? 20) }
        cacheTarget = int(service[.heatingThresholdTemperature])
        fan.characteristic(.on).onWrite { [weak self] value in await self?.internalFanStateUpdate(value.boolValue ?? false) }
        cacheFanState = bool(fan[.on]) ? "on" : "off"
        setupSpeed()
        logInitOptions([("tempReporting", "true")])
        initialised = true
    }

    /// The fan tile follows the heater's power.
    override func stateChanged(_ state: String) {
        guard cacheFanState != state else { return }
        cacheFanState = state
        update(fan[.on], state == "on")
    }

    private func codes(_ mode: String) -> [Int: String] { mode == "auto" ? Catalog.heaterH7130TempCodesAuto : Catalog.heaterH7130TempCodesHeat }

    private func internalModeUpdate(_ value: Int) async throws {
        let mode = value == 0 ? "auto" : "heat"
        guard cacheMode != mode else { return }
        do {
            guard let code = codes(mode)[cacheTarget] else { throw GoveeAPIError.message("no code for \(cacheTarget)°C") }
            try await send(.ptReal(code))
            cacheMode = mode
            log("\(Lang.curMode) [\(mode)]")
        } catch {
            throw failed(error, service[.targetHeaterCoolerState], revert: .int(cacheMode == "auto" ? 0 : 1))
        }
    }

    private func internalTemperatureUpdate(_ value: Int) async throws {
        guard cacheTarget != value else { return }
        do {
            guard let code = codes(cacheMode)[value] else { throw GoveeAPIError.message("no code for \(value)°C") }
            try await send(.ptReal(code))
            cacheTarget = value
            log("\(Lang.curTarg) [\(cacheTarget)°C]")
        } catch {
            throw failed(error, service[.heatingThresholdTemperature], revert: .int(cacheTarget))
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
                    self.update(service[.currentTemperature], cacheTemp)
                    log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C]")
                }
            }
        }
        if let target = update.setTemperature {
            let converted = Int(Govee.round(Govee.farToCen(target / Self.temperatureThreshold)))
            if converted != cacheTarget {
                cacheTarget = converted
                self.update(service[.heatingThresholdTemperature], cacheTarget)
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
        update(service[.targetHeaterCoolerState], cacheMode == "auto" ? 0 : 1)
        log("\(Lang.curMode) [\(cacheMode)]")
    }
}

/// The H7131 and H7132 (`device/heater2.ts`): a heater-cooler (auto with a 5-30°C target, or heat at a fan
/// speed), a fan for fan-only, low, medium and high, and the night light with its colour.
final class Heater2Device: GoveeDevice {
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
        let fresh = environment.cached?.service(.heaterCooler) == nil
        service = addService(.heaterCooler, characteristics: [
            .targetHeaterCoolerState.with(minValue: 0, maxValue: 1, validValues: [0, 1]),
            .heatingThresholdTemperature.with(minValue: 5, maxValue: 30, minStep: 1), .swingMode, .lockPhysicalControls,
        ], primary: true)
        if fresh {
            update(service[.currentTemperature], 20.0)
            update(service[.heatingThresholdTemperature], 20.0)
        }
        fan = addService(.fan, characteristics: [.rotationSpeed.with(minStep: 25, validValues: [0, 25, 50, 75, 100])])
        nightLight = NightLight(self, frames: .separate)

        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        service.characteristic(.targetHeaterCoolerState).onWrite { [weak self] value in try await self?.internalModeUpdate(value.intValue ?? 0) }
        cacheTemp = double(service[.currentTemperature])
        service.characteristic(.heatingThresholdTemperature).onWrite { [weak self] value in try await self?.internalTemperatureUpdate(value.intValue ?? 20) }
        cacheTarget = int(service[.heatingThresholdTemperature])
        service.characteristic(.swingMode).onWrite { [weak self] value in try await self?.internalSwingUpdate(value.intValue ?? 0) }
        cacheSwing = int(service[.swingMode]) == 1 ? "on" : "off"
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
        fan.characteristic(.on).onWrite { [weak self] value in await self?.internalFanStateUpdate(value.boolValue ?? false) }
        cacheFanState = bool(fan[.on]) ? "on" : "off"
        fan.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.intValue ?? 0) }
        cacheSpeed = int(fan[.rotationSpeed])
        cacheMode = Catalog.heater2SpeedLabels[cacheSpeed] ?? "auto"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.stateHeat(value == 1))
            if newValue == "off" { update(fan[.on], false) }
            cacheState = newValue
            log("\(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    private func internalModeUpdate(_ value: Int) async throws {
        let code: String?
        let mode: String
        if value == 0 {
            code = Catalog.heater2TempCodesAutoTurn[cacheTarget]
            mode = "auto"
        } else {
            code = Catalog.heater2SpeedCodes[cacheSpeed] ?? Catalog.heater2SpeedCodes[25]
            mode = Catalog.heater2SpeedLabels[cacheSpeed] ?? Catalog.heater2SpeedLabels[25]!
        }
        do {
            guard let code else { throw GoveeAPIError.message("no code for \(cacheTarget)°C") }
            try await send(.multiSync(code))
            if mode == "auto" { update(fan[.on], false) }
            if cacheMode != mode {
                cacheMode = mode
                log("\(Lang.curMode) [\(cacheMode)]")
            }
        } catch {
            throw failed(error, service[.targetHeaterCoolerState], revert: .int(cacheMode == "auto" ? 0 : 1))
        }
    }

    private func internalTemperatureUpdate(_ value: Int) async throws {
        guard cacheTarget != value else { return }
        // A target puts the heater in auto mode.
        let code = cacheMode == "auto" ? Catalog.heater2TempCodesAuto[value] : Catalog.heater2TempCodesAutoTurn[value]
        do {
            guard let code else { throw GoveeAPIError.message("no code for \(value)°C") }
            try await send(.multiSync(code))
            cacheMode = "auto"
            cacheTarget = value
            log("\(Lang.curTarg) [\(cacheTarget)°C]")
        } catch {
            throw failed(error, service[.heatingThresholdTemperature], revert: .int(cacheTarget))
        }
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
                update(service[.active], 1)
                log("\(Lang.curState) [\(cacheState)]")
            }
            cacheFanState = "on"
            return
        }
        // The fan off: back to auto mode.
        cacheFanState = "off"
        cacheMode = "auto"
        update(service[.targetHeaterCoolerState], 0)
        log("\(Lang.curMode) [\(cacheMode)]")
    }

    private func internalSpeedUpdate(_ value: Int) async throws {
        guard cacheSpeed != value, value != 0, let code = Catalog.heater2SpeedCodes[value] else { return }
        do {
            try await send(.multiSync(code))
            cacheFanState = "on"
            update(service[.active], 1)
            update(service[.targetHeaterCoolerState], 1)
            if cacheSpeed != value {
                cacheSpeed = value
                cacheMode = Catalog.heater2SpeedLabels[value] ?? cacheMode
                log("\(Lang.curMode) [\(cacheMode)]")
            }
        } catch {
            throw failed(error, fan[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        if let temperature = update.temperature {
            let converted = Govee.nearestHalf(Govee.farToCen(temperature / 100))
            if converted != cacheTemp {
                cacheTemp = converted
                self.update(service[.currentTemperature], cacheTemp)
                log("\(Lang.curTemp) [\(DeviceUpdate.format(cacheTemp))°C]")
            }
        }
        if let target = update.setTemperature {
            let converted = Int(Govee.round(Govee.farToCen(target / 100)))
            if converted != cacheTarget {
                cacheTarget = converted
                cacheFanState = "off"
                cacheSpeed = 0
                cacheMode = "auto"
                self.update(service[.heatingThresholdTemperature], cacheTarget)
                log("\(Lang.curTarg) [\(cacheTarget)°C]")
            }
        }
        guard let commands = update.commands else { return }
        var handlers: [String: Govee.CommandHandler] = [
            "1b01": { [unowned self] parts, _ in nightLight.stateReport(parts) },
            "1b05": { [unowned self] parts, _ in nightLight.report(colour: parts) },
            "1f00": { [unowned self] parts, _ in swingLockReport(parts) },
            "1f01": { [unowned self] parts, _ in swingLockReport(parts) },
            "0509": { [unowned self] _, _ in fanMode("fan-only", speed: 25, target: 1) },
            "0501": { [unowned self] parts, _ in
                switch Govee.item(parts, 4) {
                case "01": fanMode("low", speed: 50, target: 1)
                case "02": fanMode("medium", speed: 75, target: 1)
                case "03": fanMode("high", speed: 100, target: 1)
                default: break
                }
            },
            "0503": { [unowned self] _, _ in fanMode("auto", speed: 0, target: 0) },
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

    /// A mode report: the fan's state and speed and the heater's target state follow it.
    private func fanMode(_ mode: String, speed: Int, target: Int) {
        guard cacheMode != mode else { return }
        cacheMode = mode
        cacheFanState = speed > 0 ? "on" : "off"
        cacheSpeed = speed
        update(fan[.on], speed > 0)
        update(fan[.rotationSpeed], speed)
        update(service[.targetHeaterCoolerState], target)
        log("\(Lang.curMode) [\(cacheMode)]")
    }
}
