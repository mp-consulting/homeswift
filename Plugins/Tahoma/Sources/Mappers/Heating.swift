import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin

/// The base thermostat (docs/clean-room/Tahoma.md 5.10.1): `HeatingSystem` and its relatives. A subclass changes the
/// modes, the temperature range, the custom Prog and Eco characteristics, the commands, and reads several states
/// together in `computeStates()`, updating the target state only while idle.
class ThermostatMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .thermostat }
    override class var kind: String { "heating" }

    /// Target Heating Cooling State's valid values.
    var modes: [Int] { [HAP.off, HAP.auto] }
    var minimumTemperature: Double { 7 }
    var maximumTemperature: Double { 30 }
    var temperatureStep: Double { 0.5 }
    var targetTemperatureWritable: Bool { true }
    var hasProg: Bool { false }
    var hasEco: Bool { false }
    /// Switch services by subtype, with their names.
    var switches: [(subtype: String, name: String)] { [] }
    /// The target state shown before any state arrives.
    var initialTarget: Int? { nil }
    var initialCurrent: Int? { nil }

    private(set) var thermostat: Service!
    private(set) var switchServices: [String: Service] = [:]

    var targetState: Int { thermostat.characteristic(.targetHeatingCoolingState).value.intValue ?? HAP.off }
    var currentState: Int { thermostat.characteristic(.currentHeatingCoolingState).value.intValue ?? HAP.off }
    var prog: Bool { thermostat[TahomaCharacteristics.prog]?.value.boolValue ?? false }
    var eco: Bool { thermostat[TahomaCharacteristics.eco]?.value.boolValue ?? false }
    var currentTemperature: Double { thermostat.number(.currentTemperature) ?? 0 }
    var targetTemperature: Double { thermostat.number(.targetTemperature) ?? minimumTemperature }

    /// Eve's Total Consumption, when an attached sensor counts the energy (5.10.1).
    var measuresEnergy: Bool {
        sensors.contains { $0.widgetName == "CumulativeElectricPowerConsumptionSensor" || $0.states["core:ElectricEnergyConsumptionState"] != nil }
    }

    override func build() throws -> [Service] {
        var targetType = CharacteristicType.targetTemperature.with(minValue: minimumTemperature, maxValue: maximumTemperature, minStep: temperatureStep)
        if !targetTemperatureWritable { targetType.permissions = [.pairedRead, .events] }
        let thermostat = Service(.thermostat, name: label, optional: [
            CharacteristicType.currentTemperature.with(minValue: -50, maxValue: 100, minStep: 0.1), targetType,
            CharacteristicType.targetHeatingCoolingState.with(validValues: modes.sorted()),
        ], isPrimary: true)
        let target = thermostat.characteristic(.targetTemperature)
        target.setClamped(target.value.doubleValue ?? minimumTemperature)
        if let initialTarget { thermostat.characteristic(.targetHeatingCoolingState).value = .int(initialTarget) }
        if let initialCurrent { thermostat.characteristic(.currentHeatingCoolingState).value = .int(initialCurrent) }
        if hasProg { thermostat.characteristic(adding: TahomaCharacteristics.prog).value = false }
        if hasEco { thermostat.characteristic(adding: TahomaCharacteristics.eco).value = false }
        if measuresEnergy { thermostat.characteristic(adding: EveCharacteristic.totalConsumption).value = .double(0) }
        self.thermostat = thermostat

        thermostat.characteristic(.targetHeatingCoolingState).onWrite { [weak self] value in
            try await self?.writeState(value.intValue ?? HAP.off)
        }
        if targetTemperatureWritable {
            target.onWrite { [weak self] value in
                guard let self, await debounced("temperature") else { return }
                try await writeTemperature(value.doubleValue ?? minimumTemperature)
            }
        }
        for type in [TahomaCharacteristics.prog, TahomaCharacteristics.eco] {
            thermostat[type]?.onWrite { [weak self] value in
                guard let self else { return }
                thermostat[type]?.value = value
                guard targetState != HAP.off else { return }
                try await execute(progCommands())
            }
        }
        var services = [thermostat]
        for (subtype, name) in switches {
            let service = Service(.switch, name: name, subtype: subtype)
            service.characteristic(.on).onWrite { [weak self] value in
                guard let self else { return }
                let on = value.boolValue ?? false
                try await execute(switchCommands(subtype, on: on)) { [weak self] update in
                    if update.state == .failed || update.state == .timedOut { self?.switchServices[subtype]?.characteristic(.on).value = .bool(!on) }
                }
            }
            switchServices[subtype] = service
            services.append(service)
        }
        return services
    }

    // MARK: Commands

    func stateCommands(_ target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.auto: [OverkizCommand("auto")]
        case HAP.heat: [OverkizCommand("heat")]
        case HAP.cool: [OverkizCommand("cool")]
        default: [OverkizCommand("off")]
        }
    }

    func temperatureCommands(_ value: Double) -> [OverkizCommand] { [OverkizCommand("setTargetTemperature", .number(value))] }

    func progCommands() -> [OverkizCommand] { stateCommands(targetState) }

    func switchCommands(_ subtype: String, on: Bool) -> [OverkizCommand] { [OverkizCommand("setOn", .bool(on))] }

    func writeState(_ target: Int) async throws {
        guard target != targetState else { return }
        try await execute(stateCommands(target)) { [weak self] update in
            guard let self else { return }
            switch update.state {
            case .completed where stateless: show(current: target)
            case .failed, .timedOut: thermostat.characteristic(.targetHeatingCoolingState).value = .int(currentState)
            default: break
            }
        }
    }

    func writeTemperature(_ value: Double) async throws {
        try await execute(temperatureCommands(value))
    }

    // MARK: Showing

    /// Current and target heating states; a target only while idle unless `always`. AUTO is shown as HEAT for the
    /// current state, which has no AUTO.
    func show(current: Int? = nil, target: Int? = nil, always: Bool = false) {
        if let current { thermostat.characteristic(.currentHeatingCoolingState).value = .int(current == HAP.auto ? HAP.heat : current) }
        if let target, always || isIdle, modes.contains(target) { thermostat.characteristic(.targetHeatingCoolingState).value = .int(target) }
    }

    func showTarget(temperature: Double?) {
        thermostat.characteristic(.targetTemperature).setClamped(temperature)
    }

    func showProg(_ value: Bool) { thermostat[TahomaCharacteristics.prog]?.value = .bool(value) }
    func showEco(_ value: Bool) { thermostat[TahomaCharacteristics.eco]?.value = .bool(value) }

    /// `core:TemperatureState`, in kelvin above 273.15.
    func showCurrentTemperature(_ states: [String: JSONValue]) {
        guard let temperature = states["core:TemperatureState"]?.number else { return }
        thermostat.characteristic(.currentTemperature).setClamped(temperature > 273.15 ? temperature - 273.15 : temperature)
    }

    /// A derogated target temperature for `derogationDuration` hours.
    func derogationCommands(_ value: Double) -> [OverkizCommand] {
        [
            OverkizCommand("setDerogatedTargetTemperature", .number(value)), OverkizCommand("setDerogationTime", .number(options.derogationDuration)),
            OverkizCommand("setDerogationOnOffState", "on"),
        ]
    }

    /// The derogated target with Prog, the target otherwise.
    func progTemperatureCommands(_ value: Double) -> [OverkizCommand] {
        [OverkizCommand(prog ? "setDerogatedTargetTemperature" : "setTargetTemperature", .number(value))]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        showCurrentTemperature(states)
        if deviceURL == device.deviceURL, let target = states["core:TargetTemperatureState"]?.number { showTarget(temperature: target) }
        if let energy = states["core:ElectricEnergyConsumptionState"]?.number {
            thermostat[EveCharacteristic.totalConsumption]?.setClamped(energy / 1000)
        }
    }
}

/// `HitachiAirToWaterMainComponent`: the base thermostat from 0 °C.
final class HitachiMainComponentMapper: ThermostatMapper, @unchecked Sendable {
    override var minimumTemperature: Double { 0 }
}

// MARK: - Atlantic electrical heaters

/// `AtlanticElectricalHeater` (pilot wire): comfort, eco, frost protection and off; the temperature snaps to them.
final class PilotWireHeaterMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { [HAP.off, HAP.heat, HAP.cool] }
    override var maximumTemperature: Double { max(options.comfort, 8) }
    override var temperatureStep: Double { 1 }
    override var hasEco: Bool { true }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.auto: [OverkizCommand("setHeatingLevel", .string(eco ? "eco" : "comfort"))]
        case HAP.heat: [OverkizCommand("setHeatingLevel", "comfort")]
        case HAP.cool: [OverkizCommand("setHeatingLevel", "eco")]
        default: [OverkizCommand("setHeatingLevel", "off")]
        }
    }

    override func progCommands() -> [OverkizCommand] { [OverkizCommand("setHeatingLevel", .string(eco ? "eco" : "comfort"))] }

    /// The temperature a request snaps to (8.5): frost protection (7), eco or comfort.
    static func snap(_ value: Double, comfort: Double, eco: Double) -> Double {
        if value <= 7 + (eco - 7) / 2 { return 7 }
        if value <= eco { return eco }
        return comfort
    }

    override func writeTemperature(_ value: Double) async throws {
        // The write stores the value asked once the handler returns: the snapped one (or, while off, the one shown
        // before) is put back just after.
        let target = thermostat.characteristic(.targetTemperature)
        guard targetState != HAP.off else {
            target.revert(to: target.value, after: scaled(0.05))
            return
        }
        let snapped = Self.snap(value, comfort: options.comfort, eco: options.eco)
        if snapped != value { target.revert(to: .double(snapped), after: scaled(0.05)) }
        let (level, mode) = switch snapped {
        case 7: ("frostprotection", HAP.cool)
        case options.eco: ("eco", HAP.cool)
        default: ("comfort", HAP.heat)
        }
        show(target: mode, always: true)
        try await execute([OverkizCommand("setHeatingLevel", .string(level))])
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        super.apply(states, from: deviceURL)
        guard deviceURL == device.deviceURL, let level = states["io:TargetHeatingLevelState"]?.stringValue else { return }
        switch level {
        case "off":
            show(current: HAP.off, target: HAP.off)
        case "frostprotection":
            show(current: HAP.off, target: HAP.heat)
            showTemperatures(7)
        case "comfort", "comfort-1", "comfort-2":
            show(current: HAP.heat, target: HAP.heat)
            showEco(false)
            showTemperatures(options.comfort)
        case "eco":
            show(current: HAP.cool, target: HAP.cool)
            showEco(true)
            showTemperatures(options.eco)
        default:
            break
        }
    }

    private func showTemperatures(_ value: Double) {
        thermostat.characteristic(.currentTemperature).setClamped(value)
        if isIdle { showTarget(temperature: value) }
    }
}

/// `AtlanticElectricalHeaterWithAdjustableTemperatureSetpoint`: HEAT too on a `Top` model; Prog.
final class AdjustableSetpointHeaterMapper: ThermostatMapper, @unchecked Sendable {
    var top: Bool { string("io:NativeFunctionalLevelState") == "Top" }
    override var modes: [Int] { top ? [HAP.off, HAP.heat, HAP.auto] : [HAP.off, HAP.auto] }
    override var maximumTemperature: Double { 28 }
    override var hasProg: Bool { true }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        let manual = OverkizCommand("setOperatingMode", .string(prog ? "internal" : "basic"))
        switch target {
        case HAP.auto: return [top ? OverkizCommand("setOperatingMode", "auto") : manual]
        case HAP.heat where top: return [manual]
        case HAP.off: return [OverkizCommand("setOperatingMode", "standby")]
        default: return []
        }
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { progTemperatureCommands(value) }

    override func computeStates() {
        guard let mode = string("core:OperatingModeState") else { return }
        let current = string("io:TargetHeatingLevelState") == "eco" ? HAP.cool : HAP.heat
        switch mode {
        case "off", "away", "frostprotection", "standby":
            show(current: HAP.off, target: HAP.off)
            showTarget(temperature: number("core:TargetTemperatureState"))
        case "auto":
            show(current: current, target: HAP.auto)
            showProg(false)
            showTarget(temperature: number("io:EffectiveTemperatureSetpointState"))
        case "prog", "program", "internal", "comfort", "eco", "manual", "basic":
            show(current: current, target: top ? HAP.heat : HAP.auto)
            showProg(["prog", "program", "internal"].contains(mode))
            showTarget(temperature: number("io:EffectiveTemperatureSetpointState"))
        default:
            break
        }
    }
}

/// `AtlanticElectricalTowelDryer`: Prog, and Boost and drying (`Séchage`) switches.
final class TowelDryerMapper: ThermostatMapper, @unchecked Sendable {
    override var maximumTemperature: Double { 28 }
    override var hasProg: Bool { true }
    override var switches: [(subtype: String, name: String)] {
        var switches: [(String, String)] = []
        if device.has("setTowelDryerBoostModeDuration") { switches.append(("boost", "Boost")) }
        if device.has("setDryingDuration") { switches.append(("drying", "Séchage")) }
        return switches
    }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        target == HAP.off
            ? [OverkizCommand("setTowelDryerOperatingMode", "standby")]
            : [OverkizCommand("setTowelDryerOperatingMode", .string(prog ? "internal" : "external"))]
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { progTemperatureCommands(value) }

    override func switchCommands(_ subtype: String, on: Bool) -> [OverkizCommand] {
        guard on else { return [OverkizCommand("setTowelDryerTemporaryState", "permanentHeating")] }
        return subtype == "boost"
            ? [OverkizCommand("setTowelDryerTemporaryState", "boost"), OverkizCommand("setTowelDryerBoostModeDuration", 10)]
            : [OverkizCommand("setTowelDryerTemporaryState", "drying"), OverkizCommand("setDryingDuration", 60)]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        super.apply(states, from: deviceURL)
        guard deviceURL == device.deviceURL, let temporary = states["io:TowelDryerTemporaryStateState"]?.stringValue else { return }
        switchServices["boost"]?.characteristic(.on).value = .bool(temporary == "boost")
        switchServices["drying"]?.characteristic(.on).value = .bool(temporary == "drying")
    }

    override func computeStates() {
        var temperature = number("core:ComfortRoomTemperatureState")
        switch string("io:TargetHeatingLevelState") {
        case "off":
            show(current: HAP.off)
            temperature = number("core:TargetTemperatureState")
        case "eco":
            show(current: HAP.cool)
            if let comfort = temperature, let eco = number("core:EcoRoomTemperatureState") { temperature = comfort - eco }
        case "comfort":
            show(current: HAP.heat)
        default:
            break
        }
        switch string("core:OperatingModeState") {
        case "standby":
            show(target: HAP.off, always: true)
        case "internal":
            showProg(true)
            show(target: HAP.auto, always: true)
            let derogated = number("core:DerogatedTargetTemperatureState") ?? 0
            showTarget(temperature: derogated > 0 ? derogated : temperature)
        case "external":
            showProg(false)
            show(target: HAP.auto, always: true)
            showTarget(temperature: temperature)
        default:
            break
        }
    }
}

// MARK: - Set points and Somfy thermostats

/// `ThermostatSetPoint`, `ProgrammableAndProtectableThermostatSetPoint`: AUTO only.
final class ThermostatSetPointMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { [HAP.auto] }
    override var initialTarget: Int? { HAP.auto }
    override var initialCurrent: Int? { HAP.heat }

    override func stateCommands(_ target: Int) -> [OverkizCommand] { [] }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { [OverkizCommand("setHeatingTargetTemperature", .number(value))] }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        super.apply(states, from: deviceURL)
        guard deviceURL == device.deviceURL else { return }
        for name in ["zwave:SetPointHeatingValueState", "core:RoomTemperatureState"] {
            if let value = states[name]?.number { thermostat.characteristic(.currentTemperature).setClamped(value) }
        }
        if let target = states["core:HeatingTargetTemperatureState"]?.number { showTarget(temperature: target) }
    }
}

/// `EvoHome/EvoHomeController`.
final class EvoHomeControllerMapper: ThermostatMapper, @unchecked Sendable {
    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        [OverkizCommand("setOperatingMode", .string(target == HAP.off ? "off" : "auto"))]
    }
}

/// `EvoHome/HeatingSetPoint`: AUTO from the start.
final class EvoHomeSetPointMapper: ThermostatMapper, @unchecked Sendable {
    override var initialTarget: Int? { HAP.auto }
}

/// A thermostat whose modes and temperatures are derogations "until further notice", AUTO leaving them.
class DerogationThermostatMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { HAP.allModes }
    /// The derogation modes of HEAT, COOL and OFF.
    var derogationModes: (heat: String, cool: String, off: String) { ("comfort", "eco", "away") }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        let modes = derogationModes
        switch target {
        case HAP.auto: return [OverkizCommand("exitDerogation")]
        case HAP.heat: return [OverkizCommand("setDerogation", [.string(modes.heat), "further_notice"])]
        case HAP.cool: return [OverkizCommand("setDerogation", [.string(modes.cool), "further_notice"])]
        default: return [OverkizCommand("setDerogation", [.string(modes.off), "further_notice"])]
        }
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        [OverkizCommand("setDerogation", [.number(value), "further_notice"])]
    }
}

/// `SomfyThermostat`.
final class SomfyThermostatMapper: DerogationThermostatMapper, @unchecked Sendable {
    override var derogationModes: (heat: String, cool: String, off: String) { ("atHomeMode", "sleepingMode", "awayMode") }
    override var minimumTemperature: Double { 0 }
    override var maximumTemperature: Double { 26 }

    static let modeTemperatures = [
        "atHomeMode": "AtHome", "geofencingMode": "GeofencingMode", "manualMode": "ManualMode", "sleepingMode": "SleepingMode",
        "suddenDropMode": "SuddenDropMode", "awayMode": "AwayMode", "freezeMode": "FreezeMode",
    ]

    override func computeStates() {
        let derogation = string("core:DerogationActivationState") == "active"
        guard let mode = string(derogation ? "somfythermostat:DerogationHeatingModeState" : "somfythermostat:HeatingModeState") else { return }
        switch mode {
        case "atHomeMode", "geofencingMode", "manualMode": show(current: HAP.heat, target: derogation ? HAP.heat : HAP.auto)
        case "sleepingMode", "suddenDropMode": show(current: HAP.cool, target: derogation ? HAP.cool : HAP.auto)
        case "awayMode", "freezeMode": show(current: HAP.off, target: HAP.off)
        default: break
        }
        let modeTemperature = Self.modeTemperatures[mode].flatMap { number("somfythermostat:\($0)TargetTemperatureState") }
        showTarget(temperature: modeTemperature ?? number(derogation ? "core:DerogatedTargetTemperatureState" : "core:TargetTemperatureState"))
    }
}

/// `SomfyHeatingTemperatureInterface`: Prog and Eco.
final class SomfyHeatingInterfaceMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { HAP.allModes }
    override var minimumTemperature: Double { 0 }
    override var maximumTemperature: Double { 26 }
    override var hasProg: Bool { true }
    override var hasEco: Bool { true }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        let on = OverkizCommand("setOnOff", "on")
        switch target {
        case HAP.auto: return [on, OverkizCommand("setOperatingMode", "both")]
        case HAP.heat: return [on, OverkizCommand("setOperatingMode", "heating")]
        case HAP.cool: return [on, OverkizCommand("setOperatingMode", "cooling")]
        default: return [OverkizCommand("setOnOff", "off")]
        }
    }

    override func progCommands() -> [OverkizCommand] {
        prog ? [OverkizCommand("setActiveMode", "auto")] : [OverkizCommand("setManuAndSetPointModes", .string(eco ? "eco" : "comfort"))]
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        let comfort = string("ovp:HeatingTemperatureInterfaceSetPointModeState") == "comfort"
        return [OverkizCommand(comfort ? "setComfortTemperature" : "setEcoTemperature", .number(value))]
    }

    override func computeStates() {
        guard let onOff = string("core:OnOffState") else { return }
        guard onOff == "on" else { return show(current: HAP.off, target: HAP.off) }
        switch string("ovp:HeatingTemperatureInterfaceOperatingModeState") {
        case "both": show(current: HAP.heat, target: HAP.auto)
        case "heating": show(current: HAP.heat, target: HAP.heat)
        case "cooling": show(current: HAP.cool, target: HAP.cool)
        default: break
        }
    }
}

/// `ValveHeatingTemperatureInterface`.
final class ValveHeatingInterfaceMapper: DerogationThermostatMapper, @unchecked Sendable {

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        super.apply(states, from: deviceURL)
        if deviceURL == device.deviceURL, let target = states["core:TargetRoomTemperatureState"]?.number { showTarget(temperature: target) }
    }

    override func computeStates() {
        let auto = ["auto", "prog", "program"].contains(string("core:OperatingModeState") ?? "")
        switch string("io:CurrentHeatingModeState") {
        case "manual", "comfort": show(current: HAP.heat, target: auto ? HAP.auto : HAP.heat)
        case "eco": show(current: HAP.cool, target: auto ? HAP.auto : HAP.cool)
        case "off", "awayMode", "frostprotection": show(current: HAP.off, target: HAP.off)
        default: break
        }
    }
}

// MARK: - Atlantic Pass APC

/// `AtlanticPassAPCHeatingZone`: Eco and Prog.
final class PassAPCHeatingZoneMapper: ThermostatMapper, @unchecked Sendable {
    override var minimumTemperature: Double { 10 }
    override var maximumTemperature: Double { 35 }
    override var hasProg: Bool { true }
    override var hasEco: Bool { true }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        guard target != HAP.off else { return [OverkizCommand("setHeatingOnOffState", "off")] }
        if prog { return [OverkizCommand("setHeatingOnOffState", "on"), OverkizCommand("setPassAPCHeatingMode", "internalScheduling")] }
        return [
            OverkizCommand("setHeatingOnOffState", "on"), OverkizCommand("setDerogationOnOffState", "off"),
            OverkizCommand("setPassAPCHeatingMode", .string(eco ? "eco" : "comfort")),
        ]
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        if prog { return derogationCommands(value) }
        return [OverkizCommand(eco ? "setEcoHeatingTargetTemperature" : "setComfortHeatingTargetTemperature", .number(value))]
    }

    override func computeStates() {
        let target = number("core:TargetTemperatureState")
        let comfort = number("core:ComfortHeatingTargetTemperatureState"), eco = number("core:EcoHeatingTargetTemperatureState")
        guard string("core:HeatingOnOffState") != "off" else {
            show(current: HAP.off, target: HAP.off)
            return showTarget(temperature: target)
        }
        let profile = string("io:PassAPCHeatingProfileState")
        switch string("io:PassAPCHeatingModeState") {
        case "off", "absence":
            show(current: HAP.off, target: HAP.off)
        case "auto", "internalScheduling", "externalScheduling":
            show(current: profile == "comfort" ? HAP.heat : HAP.cool, target: HAP.auto)
            showProg(true)
            switch profile {
            case "derogation": showTarget(temperature: number("core:DerogatedTargetTemperatureState"))
            case "comfort": showTarget(temperature: comfort)
            case "eco": showTarget(temperature: eco)
            default: showTarget(temperature: target)
            }
        case "comfort":
            show(current: HAP.heat, target: HAP.auto)
            showProg(false)
            showEco(false)
            showTarget(temperature: comfort)
        case "eco":
            show(current: HAP.cool, target: HAP.auto)
            showEco(true)
            showTarget(temperature: eco)
        default:
            break
        }
    }
}

/// `AtlanticPassAPCHeatingAndCoolingZone`: heating or cooling as its heat pump (the parent) runs.
final class PassAPCHeatingCoolingZoneMapper: ThermostatMapper, @unchecked Sendable {
    override var minimumTemperature: Double { 16 }
    override var hasProg: Bool { true }

    var cooling: Bool { parentState("io:PassAPCOperatingModeState")?.stringValue == "cooling" }
    var mode: String { cooling ? "Cooling" : "Heating" }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        guard target != HAP.off else { return [OverkizCommand("set\(mode)OnOffState", "off")] }
        return [OverkizCommand("set\(mode)OnOffState", "on"), OverkizCommand("setPassAPC\(mode)Mode", .string(prog ? "internalScheduling" : "manu"))]
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        if prog {
            if device.has("setDerogatedTargetTemperature") { return derogationCommands(value) }
            let ecoProfile = state("core:Eco\(mode)TargetTemperatureState") != nil && state("core:Eco\(mode)TargetTemperatureState") == state("core:TargetTemperatureState")
            return [OverkizCommand("set\(ecoProfile ? "Eco" : "Comfort")\(mode)TargetTemperature", .number(value))]
        }
        let name = device.has("set\(mode)TargetTemperature") ? "set\(mode)TargetTemperature" : "setComfort\(mode)TargetTemperature"
        return [OverkizCommand(name, .number(value))]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        showCurrentTemperature(states)
        if deviceURL == device.deviceURL, let target = states["core:TargetTemperatureState"]?.number, target >= 16 { showTarget(temperature: target) }
    }

    override func computeStates() {
        guard string("core:\(mode)OnOffState") != "off" else { return show(current: HAP.off, target: HAP.off) }
        guard let target = number("core:\(mode)TargetTemperatureState") ?? number("core:TargetTemperatureState") else { return }
        if cooling {
            show(current: currentTemperature <= target - 0.5 ? HAP.off : HAP.cool, target: HAP.auto)
        } else {
            show(current: currentTemperature >= target + 0.5 ? HAP.off : HAP.heat, target: HAP.auto)
        }
        showProg(string("io:PassAPC\(mode)ModeState") == "internalScheduling")
        if target >= 16, isIdle { showTarget(temperature: target) }
    }
}

/// `AtlanticPassAPCHeatPump`: its target temperature is read-only.
final class PassAPCHeatPumpMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { HAP.allModes }
    override var minimumTemperature: Double { 0 }
    override var targetTemperatureWritable: Bool { false }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.cool: [OverkizCommand("setPassAPCOperatingMode", "cooling")]
        case HAP.off: [OverkizCommand("setPassAPCOperatingMode", "stop")]
        default: [OverkizCommand("setPassAPCOperatingMode", "heating")]
        }
    }

    override func computeStates() {
        switch string("io:PassAPCOperatingModeState") {
        case "heating": show(current: HAP.heat, target: HAP.heat)
        case "cooling": show(current: HAP.cool, target: HAP.cool)
        case "stop": show(current: HAP.off, target: HAP.off)
        default: break
        }
    }
}

/// `AtlanticPassAPCZoneControl`.
final class PassAPCZoneControlMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { HAP.allModes }
    override var targetTemperatureWritable: Bool { false }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        switch target {
        case HAP.auto: [OverkizCommand("setPassAPCOperatingMode", "heating"), OverkizCommand("setHeatingCoolingAutoSwitch", "on")]
        case HAP.heat: [OverkizCommand("setPassAPCOperatingMode", "heating"), OverkizCommand("setHeatingCoolingAutoSwitch", "off")]
        case HAP.cool: [OverkizCommand("setPassAPCOperatingMode", "cooling"), OverkizCommand("setHeatingCoolingAutoSwitch", "off")]
        default: [OverkizCommand("setPassAPCOperatingMode", "stop")]
        }
    }

    override func computeStates() {
        let auto = string("core:HeatingCoolingAutoSwitchState") == "on"
        switch string("io:PassAPCOperatingModeState") {
        case "heating": show(current: HAP.heat, target: auto ? HAP.auto : HAP.heat)
        case "cooling": show(current: HAP.cool, target: auto ? HAP.auto : HAP.cool)
        case "stop": show(current: HAP.off, target: HAP.off)
        default: break
        }
    }
}

/// A Switch for one state and two commands: `AtlanticPassAPCBoiler`, `DomesticHotWaterTank`.
final class StateSwitchMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .switch }
    override class var kind: String { "switch" }
    private var power: Service!

    var isBoiler: Bool { device.widgetName == "AtlanticPassAPCBoiler" }

    override func build() throws -> [Service] {
        let power: Service
        if isBoiler {
            power = Service(.switch, name: label, isPrimary: true)
        } else {
            power = Service(.switch, name: "Boost", subtype: "boost", isPrimary: true)
        }
        power.characteristic(.on).onWrite { [weak self] value in
            guard let self else { return }
            let on = value.boolValue ?? false
            if isBoiler {
                try await execute([OverkizCommand("setPassAPCOperatingMode", .string(on ? "heating" : "stop"))])
            } else {
                try await execute([OverkizCommand("setForceHeating", .string(on ? "on" : "off"))])
            }
        }
        self.power = power
        return [power]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if isBoiler, let mode = states["io:PassAPCOperatingModeState"]?.stringValue {
            if mode == "stop" { power.characteristic(.on).value = false }
            else if ["heating", "drying", "cooling"].contains(mode) { power.characteristic(.on).value = true }
        }
        if !isBoiler, let force = states["io:ForceHeatingState"]?.stringValue { power.characteristic(.on).value = .bool(force == "on") }
    }
}

// MARK: - Hitachi

/// `HitachiHeatingSystem/HitachiAirToAirHeatPump`: every write is one `globalControl`.
final class HitachiAirToAirMapper: ThermostatMapper, @unchecked Sendable {
    override var modes: [Int] { HAP.allModes }
    override var minimumTemperature: Double { 16 }

    override func stateCommands(_ target: Int) -> [OverkizCommand] { globalControl(state: target, temperature: targetTemperature) }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { globalControl(state: targetState, temperature: value) }

    func globalControl(state: Int, temperature: Double) -> [OverkizCommand] {
        let onOff = state == HAP.off ? "off" : "on"
        let heatMode: String
        switch state {
        case HAP.heat: heatMode = "heating"
        case HAP.cool: heatMode = "cooling"
        case HAP.off: heatMode = currentState == HAP.heat ? "heating" : currentState == HAP.cool ? "cooling" : "auto"
        default: heatMode = "auto"
        }
        var value = temperature
        if heatMode == "auto" {
            let offset = temperature - currentTemperature.rounded(.towardZero)
            value = min(5, max(-5, offset)).rounded(.towardZero)
        }
        value = value.rounded()
        logger.debug("[\(label)] FROM \(currentState)/\(targetTemperature) TO \(state)/\(value)")
        return [OverkizCommand("globalControl", [.string(onOff), .number(value), "auto", .string(heatMode), "manu"])]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let room = states["ovp:RoomTemperatureState"]?.number { thermostat.characteristic(.currentTemperature).setClamped(room) }
        if let target = states["core:TargetTemperatureState"]?.number { showTarget(temperature: target) }
        if states["ovp:MainOperationState"] != nil || states["ovp:ModeChangeState"] != nil {
            if let main = string("ovp:MainOperationState"), main.lowercased() == "off" { return show(current: HAP.off, target: HAP.off) }
            switch string("ovp:ModeChangeState")?.lowercased() {
            case "auto cooling": show(current: HAP.cool, target: HAP.auto)
            case "auto heating": show(current: HAP.heat, target: HAP.auto)
            case "cooling": show(current: HAP.cool, target: HAP.cool)
            case "heating": show(current: HAP.heat, target: HAP.heat)
            default: break
            }
        }
    }
}
