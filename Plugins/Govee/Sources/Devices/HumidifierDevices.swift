import Foundation
import HomeswiftPlugin
import Homeswift

/// Humidifiers without a model of their own (`device/humidifier.ts`, the H7140): a fan with eight mist
/// levels, and the night light.
final class HumidifierDevice: GoveeDevice {
    static let maximumSpeed = 8
    private var service: Service!
    private var light: Service!
    private var cacheSpeed = 0
    private var cacheLightState = "off"
    private let cacheBright = 100

    override var category: AccessoryCategory { .humidifier }

    override func configure() {
        service = addService(.fan, characteristics: [.rotationSpeed.with(minStep: 10, validValues: Array(stride(from: 0, through: 100, by: 10)))], primary: true)
        light = addService(.lightbulb, characteristics: [.hue, .saturation])
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        light.characteristic(.on).onWrite { [weak self] value in try await self?.internalLightStateUpdate(value.boolValue ?? false) }
        cacheLightState = bool(light[.on]) ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.stateHumi(value))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let level = Govee.speedPercentToValue(value, maxSpeed: Self.maximumSpeed, rounding: Govee.round)
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard percent != cacheSpeed, let code = Catalog.humidifierH7140SpeedCodes[level] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = percent
            log("\(Lang.curSpeed) [\(level)]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    private func internalLightStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard cacheLightState != newValue else { return }
        let code = value ? Govee.nightLightCode(brightness: cacheBright, hue: double(light[.hue]), saturation: double(light[.saturation])) : Govee.nightLightOffCode()
        do {
            try await send(.ptReal(code))
            cacheLightState = newValue
            log("\(Lang.curLight) [\(newValue)]")
        } catch {
            throw failed(error, light[.on], revert: .bool(cacheLightState == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        Govee.processCommands(commands, [
            "0501": { [unowned self] parts, _ in speedReport(parts) },
            "0502": { [unowned self] parts, _ in speedReport(parts) },
            "1b00": { [unowned self] _, _ in nightLightReport("off") },
            "1b01": { [unowned self] _, _ in nightLightReport("on") },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }

    private func speedReport(_ parts: [String]) {
        let level = Govee.hexToDecimal(Govee.item(parts, 3))
        guard (1...Self.maximumSpeed).contains(level) else { return }
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard cacheSpeed != percent else { return }
        cacheSpeed = percent
        update(service[.rotationSpeed], cacheSpeed)
        log("\(Lang.curSpeed) [\(level)]")
    }

    private func nightLightReport(_ state: String) {
        guard state != cacheLightState else { return }
        cacheLightState = state
        update(light[.on], cacheLightState == "on")
        log("current night light state [\(cacheLightState)]")
    }
}

/// The H7160 (`device/humidifier-h7160.ts`): nine mist levels and an RGB night light. The H7142 adds a
/// humidity sensor and a UV light (`HumidifierH7142Device`).
class HumidifierH7160Device: GoveeDevice {
    static let maximumSpeed = 9
    var service: Service!
    private var nightLight: NightLight!
    private var cacheSpeed = 0
    private var cacheSpeedRaw = "01"

    override var category: AccessoryCategory { .humidifier }

    override func configure() {
        service = addService(.fan, characteristics: [.rotationSpeed.with(minStep: 10, validValues: Array(stride(from: 0, through: 100, by: 10)))], primary: true)
        setupHumiditySensor()
        nightLight = NightLight(self, frames: .combined)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        cacheSpeedRaw = "0\(Govee.roundInt(Double(cacheSpeed) / 10))"
        logInitOptions([])
        initialised = true
    }

    /// No humidity sensor on this model.
    func setupHumiditySensor() {}

    /// After a power change was sent, before it is cached.
    func afterPowerChange(_ on: Bool) async throws {}

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.stateHumi(value))
            try await afterPowerChange(value)
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
            // The night light goes off with the humidifier.
            if !value { nightLight.report(on: false) }
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let level = Govee.speedPercentToValue(value, maxSpeed: Self.maximumSpeed, rounding: Govee.round)
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard percent != cacheSpeed, let code = Catalog.humidifierH7142SpeedCodes[level] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = percent
            cacheSpeedRaw = "0\(level)"
            log("\(Lang.curSpeed) [\(level)]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
        }
        if let commands = update.commands {
            Govee.processCommands(commands, commandHandlers()) { [unowned self] command, hex, _ in newScene(command, hex) }
        }
    }

    func commandHandlers() -> [String: Govee.CommandHandler] {
        [
            "0501": { [unowned self] parts, _ in speedReport(parts) },
            "1b00": { [unowned self] parts, _ in nightLightReport("off", parts) },
            "1b01": { [unowned self] parts, _ in nightLightReport("on", parts) },
        ]
    }

    private func speedReport(_ parts: [String]) {
        let raw = Govee.item(parts, 4)
        guard cacheSpeedRaw != raw else { return }
        cacheSpeedRaw = raw
        cacheSpeed = (Govee.parseInt(raw) ?? 0) * 10
        update(service[.rotationSpeed], cacheSpeed)
        log("\(Lang.curSpeed) [\(cacheSpeedRaw)]")
    }

    private func nightLightReport(_ state: String, _ parts: [String]) {
        nightLight.report(on: state == "on")
        guard state == "on" else { return }
        nightLight.report(brightness: Govee.hexToDecimal(Govee.item(parts, 4)))
        nightLight.report(colour: parts, orSaturation: true)
    }
}

/// The H7142 (`device/humidifier-h7142.ts`): the H7160's controls, a humidity sensor, and a UV light switched on
/// with the humidifier.
final class HumidifierH7142Device: HumidifierH7160Device {
    private var humidity: Service!
    private var cacheMode = "manual"
    private var cacheHumi = 0
    private var cacheUV = "off"
    private var cacheDisplay = "off"

    override func setupHumiditySensor() {
        humidity = addService(.humiditySensor)
        cacheHumi = int(humidity[.currentRelativeHumidity])
        cacheUV = bool(service[.on]) ? "on" : "off"
    }

    override func afterPowerChange(_ on: Bool) async throws {
        if on, cacheUV == "off" {
            try? await Task.sleep(for: .milliseconds(200))
            try await send(.ptReal(Catalog.humidifierH7142UvOn))
        }
        let uv = on ? "on" : "off"
        if cacheUV != uv {
            cacheUV = uv
            log("current uv light [\(cacheUV)]")
        }
    }

    override func commandHandlers() -> [String: Govee.CommandHandler] {
        var handlers = super.commandHandlers()
        handlers["0500"] = { [unowned self] parts, _ in
            let modes = ["01": "manual", "02": "custom", "03": "auto"]
            if let mode = modes[Govee.item(parts, 4)], cacheMode != mode {
                cacheMode = mode
                log("\(Lang.curMode) [\(cacheMode)]")
            }
        }
        handlers["1001"] = { [unowned self] parts, _ in humidityReport(parts) }
        handlers["1800"] = { [unowned self] _, _ in displayReport("off") }
        handlers["1801"] = { [unowned self] _, _ in displayReport("on") }
        handlers["1a00"] = { [unowned self] _, _ in uvReport("off") }
        handlers["1a01"] = { [unowned self] _, _ in uvReport("on") }
        handlers["0503"] = { [unowned self] parts, _ in
            // Auto mode: byte 4 is believed to be the target humidity; logged to confirm before it is exposed.
            logDebug("auto mode reported [target ~\(Govee.hexToDecimal(Govee.item(parts, 4)))%] [\(parts.joined())]")
        }
        for ignored in ["0502", "1100", "1101", "1300", "1500"] { handlers[ignored] = { _, _ in } }
        return handlers
    }

    private func humidityReport(_ parts: [String]) {
        guard Govee.item(parts, 4) == "00" else {
            // A variant not parsed yet: logged so owners can report it (upstream issue #1294).
            logDebugWarn("unparsed humidity payload [1001] [\(parts.joined())]")
            return
        }
        let tenths = Double(Govee.hexToDecimal(Govee.item(parts, 5) + Govee.item(parts, 6)))
        let value = Govee.roundInt(Govee.round(tenths) / 10)
        guard value != cacheHumi else { return }
        cacheHumi = value
        update(humidity[.currentRelativeHumidity], cacheHumi)
        log("\(Lang.curHumi) [\(cacheHumi)%]")
    }

    private func displayReport(_ display: String) {
        guard display != cacheDisplay else { return }
        cacheDisplay = display
        log("\(Lang.curDisplay) [\(cacheDisplay)]")
    }

    private func uvReport(_ uv: String) {
        guard uv != cacheUV else { return }
        cacheUV = uv
        log("current uv light [\(cacheUV)]")
    }
}

/// Dehumidifiers (`device/dehumidifier.ts`): a fan with eight levels.
final class DehumidifierDevice: GoveeDevice {
    static let maximumSpeed = 8
    private var service: Service!
    private var cacheSpeed = 0

    override var category: AccessoryCategory { .dehumidifier }

    override func configure() {
        service = addService(.fan, characteristics: [.rotationSpeed.with(minStep: 10, validValues: Array(stride(from: 0, through: 80, by: 10)))], primary: true)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.stateHumi(value))
            cacheState = newValue
            log("\(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let level = Govee.speedPercentToValue(value, maxSpeed: Self.maximumSpeed, rounding: Govee.round)
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard percent != cacheSpeed, let code = Catalog.humidifierH7140SpeedCodes[level] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = percent
            log("\(Lang.curSpeed) [\(level)]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.on], cacheState == "on")
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        let report: Govee.CommandHandler = { [unowned self] parts, _ in
            let level = Govee.hexToDecimal(Govee.item(parts, 3))
            guard (1...Self.maximumSpeed).contains(level) else { return }
            let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
            guard cacheSpeed != percent else { return }
            cacheSpeed = percent
            self.update(service[.rotationSpeed], cacheSpeed)
            log("\(Lang.curSpeed) [\(level)]")
        }
        Govee.processCommands(commands, ["0501": report, "0502": report]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }
}

/// Diffusers (`device/diffuser.ts`): an air purifier with power only.
final class DiffuserDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory { .airPurifier }

    override func configure() {
        service = addService(.airPurifier, characteristics: [.targetAirPurifierState.with(minValue: 1, maxValue: 1, validValues: [1])], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        update(service[.targetAirPurifierState], 1)
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.stateHumi(value == 1))
            cacheState = newValue
            update(service[.currentAirPurifierState], value == 1 ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.currentAirPurifierState], cacheState == "on" ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        if let commands = update.commands {
            Govee.processCommands(commands, [:]) { [unowned self] command, hex, _ in newScene(command, hex) }
        }
    }
}
