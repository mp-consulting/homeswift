import Foundation
import HomeswiftPlugin
import Homeswift

/// The H7120 and H7121 (`device/purifier-h7120.ts`): four speeds, child lock, and the night and display
/// lights as Eve switches.
final class PurifierH7120Device: GoveeDevice {
    static let maximumSpeed = 4
    private var service: Service!
    private var cacheSpeed = 25
    private var cacheLock = "off"
    private var cacheLight = "off"
    private var cacheDisplay = "off"

    override var category: AccessoryCategory { .airPurifier }

    override func configure() {
        service = addService(.airPurifier, characteristics: [
            .targetAirPurifierState.with(minValue: 1, maxValue: 1, validValues: [1]), .rotationSpeed.with(minStep: 25, validValues: [0, 25, 50, 75, 100]),
            .lockPhysicalControls, GoveeCharacteristic.nightLight, GoveeCharacteristic.displayLight,
        ], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        update(service[.targetAirPurifierState], 1)
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed]) == 0 ? 25 : int(service[.rotationSpeed])
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
        service.characteristic(GoveeCharacteristic.nightLight).onWrite { [weak self] value in try await self?.internalNightLightUpdate(value.boolValue ?? false) }
        cacheLight = bool(service[GoveeCharacteristic.nightLight]) ? "on" : "off"
        service.characteristic(GoveeCharacteristic.displayLight).onWrite { [weak self] value in try await self?.internalDisplayUpdate(value.boolValue ?? false) }
        cacheDisplay = bool(service[GoveeCharacteristic.displayLight]) ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.statePuri(value != 0))
            update(service[.currentAirPurifierState], value == 1 ? 2 : 0)
            cacheState = newValue
            log("\(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let level = Govee.speedPercentToValue(value, maxSpeed: Self.maximumSpeed)
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard percent != cacheSpeed, let code = Catalog.purifierH7120SpeedCodes[level] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = percent
            log("\(Lang.curSpeed) [\(cacheSpeed)%]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    private func internalNightLightUpdate(_ value: Bool) async throws {
        let state = try await toggle(value, current: cacheLight, label: Lang.curLight, service[GoveeCharacteristic.nightLight], revert: .bool(cacheLight == "on")) {
            .ptReal(Catalog.purifierH7120NightLightCodes[$0]!)
        }
        if let state { cacheLight = state }
    }

    private func internalLockUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheLock, label: Lang.curLock, service[.lockPhysicalControls], revert: .int(cacheLock == "on" ? 1 : 0)) {
            .ptReal(Catalog.lockCodes[$0]!)
        }
        if let state { cacheLock = state }
    }

    private func internalDisplayUpdate(_ value: Bool) async throws {
        let state = try await toggle(value, current: cacheDisplay, label: Lang.curDisplay, service[GoveeCharacteristic.displayLight], revert: .bool(cacheDisplay == "on")) {
            .ptReal(Catalog.displayCodes[$0]!)
        }
        if let state { cacheDisplay = state }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.currentAirPurifierState], cacheState == "on" ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        let speed: Govee.CommandHandler = { [unowned self] parts, _ in
            let speeds = ["01": 25, "02": 50, "03": 75, "04": 100]
            guard let value = speeds[Govee.item(parts, 3)], cacheSpeed != value else { return }
            cacheSpeed = value
            self.update(service[.rotationSpeed], cacheSpeed)
            log("\(Lang.curSpeed) [\(cacheSpeed)%]")
        }
        let lock: Govee.CommandHandler = { [unowned self] parts, _ in
            let value = Govee.item(parts, 3) == "01" ? "on" : "off"
            guard cacheLock != value else { return }
            cacheLock = value
            self.update(service[.lockPhysicalControls], cacheLock == "on" ? 1 : 0)
            log("\(Lang.curLock) [\(cacheLock)]")
        }
        Govee.processCommands(commands, ["0501": speed, "0502": speed, "1000": lock, "1001": lock]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }
}

/// The five-speed purifiers with an air quality sensor (`device/purifier-air-quality-base.ts`): the H7122
/// reports PM2.5, the H7123 and H7124 a level only (and have a night light switch). Speed, child lock and the
/// display light; the display comes back as it was, from the last status the purifier reported.
final class PurifierAirQualityDevice: GoveeDevice {
    enum Model { case h7122, h7123 }

    static let speedStep = 20
    static let speedLabels = [0: "off", 1: "sleep", 2: "low", 3: "medium", 4: "high", 5: "auto"]
    /// The speed code of the custom mode.
    static let customSpeedCode = "0202"

    let model: Model
    private var service: Service!
    private var air: Service!
    private var cacheMode = 1
    private var cacheLock = "off"
    private var cacheDisplay = "off"
    private var cacheAir = 0.0
    private var cacheAirQuality = ""

    init(environment: DeviceEnvironment, model: Model) {
        self.model = model
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { .airPurifier }

    /// The status opcode with the air quality.
    private var airQualityOpcode: String { model == .h7122 ? "1c" : "19" }

    override func configure() {
        var purifier: [CharacteristicType] = [
            .targetAirPurifierState.with(minValue: 1, maxValue: 1, validValues: [1]), .rotationSpeed.with(minStep: 20, validValues: [0, 20, 40, 60, 80, 100]),
            .lockPhysicalControls, GoveeCharacteristic.displayLight,
        ]
        // The H7123's night light is read-only in practice: it has no handler.
        if model == .h7123 { purifier.append(GoveeCharacteristic.nightLight) }
        service = addService(.airPurifier, characteristics: purifier, primary: true)
        air = addService(.airQualitySensor, characteristics: model == .h7122 ? [.pm2_5Density] : [])
        if model == .h7122 {
            cacheAir = double(air[.pm2_5Density])
        } else {
            cacheAir = int(air[.airQuality]) == 0 ? 1 : double(air[.airQuality])
        }
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        update(service[.targetAirPurifierState], 1)
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        let speed = int(service[.rotationSpeed])
        cacheMode = (speed == 0 ? Self.speedStep : speed) / Self.speedStep
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
        service.characteristic(GoveeCharacteristic.displayLight).onWrite { [weak self] value in try await self?.internalDisplayUpdate(value.boolValue ?? false) }
        cacheDisplay = bool(service[GoveeCharacteristic.displayLight]) ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.statePuri(value != 0))
            update(service[.currentAirPurifierState], value == 1 ? 2 : 0)
            cacheState = newValue
            log("\(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let mode = Int(saturating: (value / Double(Self.speedStep)).rounded(.down)) ?? 0
        guard mode != 0, mode != cacheMode, let code = Catalog.purifierH7122SpeedCodes[mode] else { return }
        do {
            try await send(.ptReal(code))
            cacheMode = mode
            log("\(Lang.curMode) [\(Self.speedLabels[cacheMode] ?? "")]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheMode * Self.speedStep))
        }
    }

    private func internalLockUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheLock, label: Lang.curLock, service[.lockPhysicalControls], revert: .int(cacheLock == "on" ? 1 : 0)) {
            .ptReal(Catalog.lockCodes[$0]!)
        }
        if let state { cacheLock = state }
    }

    private func internalDisplayUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard cacheDisplay != newValue else { return }
        let code: String
        if value, let saved = environment.store.value(info.id, "cacheDisplayCode")?.stringValue {
            code = Govee.hexToBase64(Govee.statusToActionCode(saved))
        } else {
            code = Catalog.displayCodes[newValue]!
        }
        do {
            try await send(.ptReal(code))
            cacheDisplay = newValue
            log("\(Lang.curDisplay) [\(newValue)]")
        } catch {
            throw failed(error, service[GoveeCharacteristic.displayLight], revert: .bool(cacheDisplay == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.currentAirPurifierState], cacheState == "on" ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        // By opcode alone: these read the sub-code bytes themselves.
        Govee.processCommands(commands, [
            "05": { [unowned self] parts, _ in speedReport(parts) },
            "10": { [unowned self] parts, _ in
                let lock = Govee.item(parts, 3) == "01" ? "on" : "off"
                guard lock != cacheLock else { return }
                cacheLock = lock
                self.update(service[.lockPhysicalControls], cacheLock == "on" ? 1 : 0)
                log("\(Lang.curLock) [\(cacheLock)]")
            },
            "16": { [unowned self] parts, hex in displayReport(parts, hex) },
            airQualityOpcode: { [unowned self] parts, _ in airQualityReport(parts) },
            "11": { _, _ in },
            "13": { _, _ in },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }

    private func speedReport(_ parts: [String]) {
        let code = Govee.item(parts, 3) + Govee.item(parts, 4)
        if code == Self.customSpeedCode {
            log("\(Lang.curMode) [custom]")
            return
        }
        guard let mode = Catalog.purifierSpeedCommandMap[code], mode != cacheMode else { return }
        cacheMode = mode
        update(service[.rotationSpeed], cacheMode * Self.speedStep)
        log("\(Lang.curMode) [\(Self.speedLabels[cacheMode] ?? "")]")
    }

    private func displayReport(_ parts: [String], _ hex: String) {
        let display = Govee.item(parts, 3) == "01" ? "on" : "off"
        if display == "on" { environment.store.set(info.id, "cacheDisplayCode", .string(hex)) }
        guard display != cacheDisplay else { return }
        cacheDisplay = display
        update(service[GoveeCharacteristic.displayLight], cacheDisplay == "on")
        log("\(Lang.curDisplay) [\(cacheDisplay)]")
    }

    private func airQualityReport(_ parts: [String]) {
        switch model {
        case .h7122:
            let pm25 = Double(Govee.hexToDecimal("0x" + Govee.item(parts, 4) + Govee.item(parts, 5)))
            guard pm25 != cacheAir else { return }
            cacheAir = pm25
            update(air[.pm2_5Density], cacheAir)
            log("\(Lang.curPM25) [\(DeviceUpdate.format(pm25))µg/m³]")
            let label = Catalog.airQualityLabel(pm25: cacheAir)
            if cacheAirQuality != label {
                cacheAirQuality = label
                update(air[.airQuality], Catalog.airQuality(pm25: cacheAir))
                log("\(Lang.curAirQual) [\(label)]")
            }
        case .h7123:
            // Govee's levels 1 to 4 (green, blue, yellow, red); HomeKit's poor is 5.
            var quality = Govee.parseInt(Govee.item(parts, 5)) ?? 0
            if quality == 4 { quality = 5 }
            guard Double(quality) != cacheAir else { return }
            cacheAir = Double(quality)
            update(air[.airQuality], quality)
            log("\(Lang.curAirQual) [\(Catalog.airQualityLabels[min(quality, 4)] ?? "unknown")]")
        }
    }
}

/// The H7126 to H712C (`device/purifier-h7126.ts`): three speeds, child lock and the display light.
final class PurifierH7126Device: GoveeDevice {
    static let maximumSpeed = 3
    private var service: Service!
    private var cacheSpeed = 0
    private var cacheSpeedRaw = "01"
    private var cacheLock = "off"
    private var cacheDisplay = "off"

    override var category: AccessoryCategory { .airPurifier }

    override func configure() {
        service = addService(.airPurifier, characteristics: [
            .targetAirPurifierState.with(validValues: [0]), .rotationSpeed.with(minStep: 33, validValues: [0, 33, 66, 99]), .lockPhysicalControls,
            GoveeCharacteristic.displayLight,
        ], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) == 1 ? "on" : "off"
        update(service[.targetAirPurifierState], 0)
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.doubleValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        service.characteristic(.lockPhysicalControls).onWrite { [weak self] value in try await self?.internalLockUpdate(value.intValue ?? 0) }
        cacheLock = int(service[.lockPhysicalControls]) == 1 ? "on" : "off"
        service.characteristic(GoveeCharacteristic.displayLight).onWrite { [weak self] value in try await self?.internalDisplayUpdate(value.boolValue ?? false) }
        cacheDisplay = bool(service[GoveeCharacteristic.displayLight]) ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let newValue = value == 1 ? "on" : "off"
        guard cacheState != newValue else { return }
        do {
            try await send(.statePuri(value != 0))
            update(service[.currentAirPurifierState], value == 1 ? 2 : 0)
            cacheState = newValue
            log("\(Lang.curState) [\(newValue)]")
        } catch {
            throw failed(error, service[.active], revert: .int(cacheState == "on" ? 1 : 0))
        }
    }

    private func internalSpeedUpdate(_ value: Double) async throws {
        guard value != 0 else { return }
        let level = Govee.speedPercentToValue(value, maxSpeed: Self.maximumSpeed)
        let percent = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
        guard percent != cacheSpeed, let code = Catalog.purifierH7126SpeedCodes[level] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = percent
            log("\(Lang.curSpeed) [\(cacheSpeed)%]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    private func internalLockUpdate(_ value: Int) async throws {
        let state = try await toggle(value == 1, current: cacheLock, label: Lang.curLock, service[.lockPhysicalControls], revert: .int(cacheLock == "on" ? 1 : 0)) {
            .ptReal(Catalog.lockCodes[$0]!)
        }
        if let state { cacheLock = state }
    }

    private func internalDisplayUpdate(_ value: Bool) async throws {
        let state = try await toggle(value, current: cacheDisplay, label: Lang.curDisplay, service[GoveeCharacteristic.displayLight], revert: .bool(cacheDisplay == "on")) {
            .ptReal(Catalog.displayCodes[$0]!)
        }
        if let state { cacheDisplay = state }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            self.update(service[.currentAirPurifierState], cacheState == "on" ? 2 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        Govee.processCommands(commands, [
            "0501": { [unowned self] parts, _ in
                let raw = Govee.item(parts, 4)
                guard raw != cacheSpeedRaw else { return }
                cacheSpeedRaw = raw
                // The Homebridge plugin set `raw × 10`, which is not one of the three speeds; this sets the speed.
                let level = min(max(Govee.parseInt(raw) ?? 1, 1), Self.maximumSpeed)
                cacheSpeed = Govee.speedValueToPercent(level, maxSpeed: Self.maximumSpeed)
                self.update(service[.rotationSpeed], cacheSpeed)
                log("\(Lang.curSpeed) [\(cacheSpeed)]")
            },
            "1000": { [unowned self] _, _ in lockReport("off") },
            "1001": { [unowned self] _, _ in lockReport("on") },
            "1600": { [unowned self] _, _ in displayReport("off") },
            "1601": { [unowned self] _, _ in displayReport("on") },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }

    private func lockReport(_ lock: String) {
        guard lock != cacheLock else { return }
        cacheLock = lock
        update(service[.lockPhysicalControls], cacheLock == "on" ? 1 : 0)
        log("\(Lang.curLock) [\(cacheLock)]")
    }

    private func displayReport(_ display: String) {
        guard display != cacheDisplay else { return }
        cacheDisplay = display
        update(service[GoveeCharacteristic.displayLight], cacheDisplay == "on")
        log("\(Lang.curDisplay) [\(cacheDisplay)]")
    }
}

/// Kettles (`device/kettle.ts`): a momentary switch per mode (green tea, oolong, coffee, black tea or boil,
/// two custom modes), each selecting the mode then boiling.
final class KettleDevice: GoveeDevice {
    private struct Mode {
        var name: String
        var subtype: String
        var index: Int
        var code: String
        var shown: Bool
    }

    override var category: AccessoryCategory { .switch }

    override func configure() {
        let modes = [
            Mode(name: "Green Tea", subtype: "greenTea", index: 1, code: Catalog.kettleModeCodes["greenTea"]!, shown: !settings.bool("hideModeGreenTea")),
            Mode(name: "Oolong Tea", subtype: "oolongTea", index: 2, code: Catalog.kettleModeCodes["oolongTea"]!, shown: !settings.bool("hideModeOolongTea")),
            Mode(name: "Coffee", subtype: "coffee", index: 3, code: Catalog.kettleModeCodes["coffee"]!, shown: !settings.bool("hideModeCoffee")),
            Mode(name: "Black Tea/Boil", subtype: "blackTeaBoil", index: 4, code: Catalog.kettleModeCodes["blackTea"]!, shown: !settings.bool("hideModeBlackTea")),
            Mode(name: "Custom Mode 1", subtype: "customMode1", index: 5, code: Catalog.kettleModeCodes["customMode1"]!, shown: settings.bool("showCustomMode1")),
            Mode(name: "Custom Mode 2", subtype: "customMode2", index: 6, code: Catalog.kettleModeCodes["customMode2"]!, shown: settings.bool("showCustomMode2")),
        ]
        var primary = true
        for mode in modes where mode.shown {
            let service = addService(.switch, name: mode.name, subtype: mode.subtype, characteristics: [.configuredName, .serviceLabelIndex], primary: primary)
            primary = false
            if (service[.configuredName]?.value.stringValue ?? "").isEmpty { update(service[.configuredName], .string(mode.name)) }
            update(service[.serviceLabelIndex], mode.index)
            service.characteristic(.on).value = false
            let code = mode.code
            service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(service, value.boolValue ?? false, code: code) }
        }
        // Every mode hidden: one plain switch, as the Homebridge plugin added.
        if primary { addService(.switch, primary: true) }
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ service: Service, _ value: Bool, code: String) async throws {
        guard value else { return }
        do {
            try await send(.ptReal(code))
            try? await Task.sleep(for: .milliseconds(Catalog.kettleModeDelayMs))
            try await send(.ptReal(Catalog.kettleModeCodes["boil"]!))
            cacheState = "on"
            log("\(Lang.curMode) [\(service[.name]?.value.stringValue ?? "")]")
            // The switch springs back after three seconds.
            schedule(after: .seconds(3)) { [weak self] in self?.update(service[.on], false) }
        } catch {
            throw failed(error, service[.on], revert: false)
        }
    }

    private var cacheOnBase: String?

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard let commands = update.commands else { return }
        var handlers: [String: Govee.CommandHandler] = [
            "1700": { [unowned self] parts, _ in
                let onBase = Govee.item(parts, 4) == "00" ? "yes" : "no"
                guard cacheOnBase != onBase else { return }
                cacheOnBase = onBase
                log("current on base [\(onBase)]")
            },
        ]
        for ignored in ["0500", "1001", "2200", "2201", "2300", "2301"] { handlers[ignored] = { _, _ in } }
        Govee.processCommands(commands, handlers) { [unowned self] command, hex, _ in newScene(command, hex) }
    }
}

/// Ice makers (`device/ice-maker.ts`): a switch that starts making ice, or cancels.
final class IceMakerDevice: GoveeDevice {
    private var service: Service!

    override var category: AccessoryCategory { .switch }

    override func configure() {
        service = addService(.switch, primary: true)
        service.characteristic(.on).onWrite { [weak self] value in try await self?.internalStateUpdate(value.boolValue ?? false) }
        cacheState = bool(service[.on]) ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private func internalStateUpdate(_ value: Bool) async throws {
        let newValue = value ? "on" : "off"
        guard newValue != cacheState else { return }
        do {
            try await send(.ptReal(Catalog.iceMakerCodes[value ? "startMakingIce" : "cancel"]!))
            cacheState = newValue
            log("\(Lang.curState) [\(cacheState)]")
        } catch {
            throw failed(error, service[.on], revert: .bool(cacheState == "on"))
        }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        guard let commands = update.commands else { return }
        Govee.processCommands(commands, [
            "19": { [unowned self] parts, _ in
                let state = Govee.item(parts, 3) == "01" ? "on" : "off"
                guard cacheState != state else { return }
                cacheState = state
                self.update(service[.on], cacheState == "on")
                log("\(Lang.curState) [\(cacheState)]")
            },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }
}
