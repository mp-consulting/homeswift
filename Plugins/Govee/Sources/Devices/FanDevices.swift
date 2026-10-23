import Foundation
import HomeswiftPlugin
import Homeswift

/// Fans (`device/fan.ts`): power, eight speeds (11% steps; 99% is auto mode, with a linked sensor) and swing.
final class FanDevice: GoveeDevice {
    static let speedValues = [0, 11, 22, 33, 44, 55, 66, 77, 88, 99]
    static let autoSpeed = 99
    static let maximumManualSpeed = 88

    private var service: Service!
    private var cacheSpeed = 0
    private var cacheMode = "manual"
    private var cacheSwing = "off"
    private var cacheAutoCode: String?

    override var category: AccessoryCategory { .fan }

    override func configure() {
        service = addService(.fanv2, characteristics: [
            .rotationSpeed.with(minValue: 0, minStep: Double(Catalog.fanSpeedStep), validValues: Self.speedValues), .swingMode,
        ], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) != 0 ? "on" : "off"
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.intValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        cacheMode = cacheSpeed == Self.autoSpeed ? "auto" : "manual"
        service.characteristic(.swingMode).onWrite { [weak self] value in try await self?.internalSwingUpdate(value.intValue ?? 0) }
        cacheSwing = int(service[.swingMode]) == 1 ? "on" : "off"
        logInitOptions([])
        initialised = true
    }

    private var sensorAttached: Bool {
        get { environment.store.value(info.id, "sensorAttached")?.boolValue ?? false }
        set { environment.store.set(info.id, "sensorAttached", .bool(newValue)) }
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let state = try await toggle(value != 0, current: cacheState, label: Lang.curState, service[.active], revert: .int(cacheState == "on" ? 1 : 0)) {
            .ptReal(Catalog.deviceStateCodes[$0]!)
        }
        if let state { cacheState = state }
    }

    private func internalSpeedUpdate(_ value: Int) async throws {
        guard value >= Catalog.fanSpeedStep, cacheSpeed != value else { return }
        var newMode = value == Self.autoSpeed ? "auto" : "manual"
        var newValue = value
        let code: String
        if newMode == "auto" {
            if !sensorAttached || cacheAutoCode == nil {
                logWarn("auto mode not supported without a linked sensor")
                code = Catalog.fanH7102SpeedCodes[Self.maximumManualSpeed]!
                newMode = "manual"
                newValue = Self.maximumManualSpeed
            } else {
                code = cacheAutoCode!
            }
        } else {
            guard let speedCode = Catalog.fanH7102SpeedCodes[value] else { return }
            code = speedCode
        }
        do {
            try await send(.ptReal(code))
            if cacheMode != newMode {
                cacheMode = newMode
                log("\(Lang.curMode) [\(cacheMode)]")
            }
            if cacheSpeed != newValue {
                cacheSpeed = newValue
                log("\(Lang.curSpeed) [\(newValue)%]")
            }
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    private func internalSwingUpdate(_ value: Int) async throws {
        let state = try await toggle(value != 0, current: cacheSwing, label: Lang.curSwing, service[.swingMode], revert: .int(cacheSwing == "on" ? 1 : 0)) {
            .ptReal(Catalog.fanSwingCodes[$0]!)
        }
        if let state { cacheSwing = state }
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        noteSensor(commands)
        Govee.processCommands(commands, [
            "0501": { [unowned self] parts, _ in speedReport(parts) },
            "0500": { [unowned self] parts, _ in modeReport(parts) },
            "0503": { [unowned self] _, hex in
                // The auto mode frame, kept to send it back.
                let values = Govee.hexToTwoItems("33" + String(hex.dropFirst(2).dropLast(2))).map { Govee.hexToDecimal($0) }
                cacheAutoCode = Govee.code(values)
            },
            "1f01": { [unowned self] parts, _ in swingReport(parts) },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }

    /// `aa08` frames name the linked sensor; all zeros means none.
    func noteSensor(_ commands: [String]) {
        for command in commands {
            let hex = Govee.base64ToHex(command)
            let parts = Govee.hexToTwoItems(hex)
            if Govee.item(parts, 1) == "aa", Govee.item(parts, 2) == "08", hex.count > 28 {
                let device = String(hex.dropFirst(4).dropLast(24))
                sensorAttached = device != "000000000000"
            }
        }
    }

    private func speedReport(_ parts: [String]) {
        let speed = (Govee.parseInt(Govee.item(parts, 4)) ?? 0) * Catalog.fanSpeedStep
        if cacheMode != "manual" {
            cacheMode = "manual"
            log("\(Lang.curMode) [\(cacheMode)]")
        }
        if cacheSpeed != speed {
            cacheSpeed = speed
            update(service[.rotationSpeed], cacheSpeed)
            log("\(Lang.curSpeed) [\(cacheSpeed)%]")
        }
    }

    private func modeReport(_ parts: [String]) {
        // (Guess) fixed speed 1, custom 2, auto 3, sleep 5, nature 6, turbo 7.
        let mode = Govee.item(parts, 4) == "03" ? "auto" : "manual"
        guard cacheMode != mode else { return }
        cacheMode = mode
        log("\(Lang.curMode) [\(cacheMode)]")
        if cacheMode == "auto", cacheSpeed != Self.autoSpeed {
            cacheSpeed = Self.autoSpeed
            update(service[.rotationSpeed], cacheSpeed)
            log("\(Lang.curSpeed) [\(cacheSpeed)%]")
        }
    }

    private func swingReport(_ parts: [String]) {
        let swing = Govee.item(parts, 4) == "01" ? "on" : "off"
        guard cacheSwing != swing else { return }
        cacheSwing = swing
        update(service[.swingMode], cacheSwing == "on" ? 1 : 0)
        log("\(Lang.curSwing) [\(cacheSwing)]")
    }
}

/// The H7105 and H7107: twelve speeds and a night light (`device/fan-light.ts`), the light hidden with
/// `hideLight`.
final class FanLightDevice: GoveeDevice {
    static let speedCodes: [Int: String] = [
        1: "MwUBAQAAAAAAAAAAAAAAAAAAADY=", 2: "MwUBAgAAAAAAAAAAAAAAAAAAADU=", 3: "MwUBAwAAAAAAAAAAAAAAAAAAADQ=",
        4: "MwUBBAAAAAAAAAAAAAAAAAAAADM=", 5: "MwUBBQAAAAAAAAAAAAAAAAAAADI=", 6: "MwUBBgAAAAAAAAAAAAAAAAAAADE=",
        7: "MwUBBwAAAAAAAAAAAAAAAAAAADA=", 8: "MwUBCAAAAAAAAAAAAAAAAAAAAD8=", 9: "MwUBCQAAAAAAAAAAAAAAAAAAAD4=",
        10: "MwUBCgAAAAAAAAAAAAAAAAAAAD0=", 11: "MwUBCwAAAAAAAAAAAAAAAAAAADw=", 12: "MwUBDAAAAAAAAAAAAAAAAAAAADs=",
    ]
    static let maximumSpeed = 12

    private var service: Service!
    private var nightLight: NightLight?
    private var cacheSpeed = 0
    private var cacheSwing = "off"
    private let hideLight: Bool

    override init(environment: DeviceEnvironment) {
        hideLight = environment.settings.bool("hideLight")
        super.init(environment: environment)
    }

    override var category: AccessoryCategory { .fan }

    override func configure() {
        // Speeds 1 to 12, without a unit.
        var speed = CharacteristicType.rotationSpeed.with(minValue: 0, maxValue: Double(Self.maximumSpeed), minStep: 1)
        speed.unit = nil
        service = addService(.fanv2, characteristics: [speed, .swingMode], primary: true)
        service.characteristic(.active).onWrite { [weak self] value in try await self?.internalStateUpdate(value.intValue ?? 0) }
        cacheState = int(service[.active]) != 0 ? "on" : "off"
        service.characteristic(.rotationSpeed).onWrite { [weak self] value in try await self?.internalSpeedUpdate(value.intValue ?? 0) }
        cacheSpeed = int(service[.rotationSpeed])
        service.characteristic(.swingMode).onWrite { [weak self] value in await self?.internalSwingUpdate(value.intValue ?? 0) }
        cacheSwing = int(service[.swingMode]) == 1 ? "on" : "off"
        if !hideLight { nightLight = NightLight(self, frames: .separate) }
        logInitOptions([("hideLight", String(hideLight))])
        initialised = true
    }

    private func internalStateUpdate(_ value: Int) async throws {
        let state = try await toggle(value != 0, current: cacheState, label: Lang.curState, service[.active], revert: .int(cacheState == "on" ? 1 : 0)) {
            .ptReal(Catalog.deviceStateCodes[$0]!)
        }
        if let state { cacheState = state }
    }

    private func internalSpeedUpdate(_ value: Int) async throws {
        guard cacheSpeed != value, value != 0, let code = Self.speedCodes[value] else { return }
        do {
            try await send(.ptReal(code))
            cacheSpeed = value
            log("\(Lang.curSpeed) [\(value)]")
        } catch {
            throw failed(error, service[.rotationSpeed], revert: .int(cacheSpeed))
        }
    }

    private func internalSwingUpdate(_ value: Int) async {
        let newValue = value != 0 ? "on" : "off"
        guard cacheSwing != newValue else { return }
        logWarn("Swing mode control not yet implemented for this model")
        cacheSwing = newValue
    }

    override func externalUpdate(_ update: DeviceUpdate) async {
        if let state = update.state, state != cacheState {
            cacheState = state
            self.update(service[.active], cacheState == "on" ? 1 : 0)
            log("\(Lang.curState) [\(cacheState)]")
        }
        guard let commands = update.commands else { return }
        for command in commands {
            let hex = Govee.base64ToHex(command)
            let parts = Govee.hexToTwoItems(hex)
            if Govee.item(parts, 1) == "aa", Govee.item(parts, 2) == "08", hex.count > 28 {
                environment.store.set(info.id, "sensorAttached", .bool(String(hex.dropFirst(4).dropLast(24)) != "000000000000"))
            }
        }
        Govee.processCommands(commands, [
            "0501": { [unowned self] parts, _ in
                let speed = Govee.hexToDecimal(Govee.item(parts, 4))
                if cacheSpeed != speed {
                    cacheSpeed = speed
                    self.update(service[.rotationSpeed], cacheSpeed)
                    log("\(Lang.curSpeed) [\(cacheSpeed)]")
                }
            },
            "1b01": { [unowned self] parts, _ in nightLight?.stateReport(parts) },
            "1b05": { [unowned self] parts, _ in nightLight?.report(colour: parts) },
        ]) { [unowned self] command, hex, _ in newScene(command, hex) }
    }
}
