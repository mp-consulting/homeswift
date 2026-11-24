import Foundation
import Homeswift
import HomeswiftAI
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// The base thermostat (docs/clean-room/Tahoma.md 5.10.1): `HeatingSystem` and its relatives, its Thermostat the shared
/// `ClimateController`'s (docs/adr/0013-climate-is-mapped-once.md). A subclass changes the modes, the temperature range,
/// the custom Prog and Eco characteristics and the commands, and reads several states together in `computeStates()`,
/// reporting them with `show(_:action:)`, `showTarget(temperature:)` and `showCurrent(temperature:)`. One target for
/// every mode: in auto (usually the device's schedule), Apple Home shows the Auto Band around it.
class ThermostatMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .thermostat }
    override class var kind: String { "heating" }

    /// Target Heating Cooling State's values: the device's modes, as HomeKit names them (OFF its power).
    var modes: [Int] { [HAP.off, HAP.auto] }
    var minimumTemperature: Double { 7 }
    var maximumTemperature: Double { 30 }
    var temperatureStep: Double { 0.5 }
    var targetTemperatureWritable: Bool { true }
    var hasProg: Bool { false }
    var hasEco: Bool { false }
    /// What a target written while the device is off does: sent, or held for the next mode chosen.
    var whileOff: ClimateCapabilities.WhileOff { .sends }
    /// Switch services by subtype, with their names.
    var switches: [(subtype: String, name: String)] { [] }
    /// The target state shown before any state arrives.
    var initialTarget: Int? { nil }
    /// What the device is shown doing before any state arrives.
    var initialCurrent: Int? { nil }

    private(set) var climate: ClimateController!
    private(set) var switchServices: [String: Service] = [:]
    /// The device's climate state as its states say, shown again when an execution fails.
    let reading = NIOLockedValueBox(ClimateReport(power: false, mode: nil))

    var thermostat: Service { climate.service }
    /// The target state Apple Home shows.
    var targetState: Int { thermostat.characteristic(.targetHeatingCoolingState).value.intValue ?? HAP.off }
    var currentState: Int { thermostat.characteristic(.currentHeatingCoolingState).value.intValue ?? HAP.off }
    /// Whether the device is on, as last reported or commanded.
    var isOn: Bool { climate.report?.power ?? false }
    var prog: Bool { thermostat[TahomaCharacteristics.prog]?.value.boolValue ?? false }
    var eco: Bool { thermostat[TahomaCharacteristics.eco]?.value.boolValue ?? false }
    var currentTemperature: Double { climate.report?.current ?? thermostat.number(.currentTemperature) ?? 0 }
    var targetTemperature: Double { climate.report?.target ?? thermostat.number(.targetTemperature) ?? minimumTemperature }

    /// Eve's Total Consumption, when an attached sensor counts the energy (5.10.1).
    var measuresEnergy: Bool {
        sensors.contains { $0.widgetName == "CumulativeElectricPowerConsumptionSensor" || $0.states["core:ElectricEnergyConsumptionState"] != nil }
    }

    /// What the device can do, for the controller.
    var capabilities: ClimateCapabilities {
        ClimateCapabilities(
            modes: Set(modes.compactMap(HAP.climateMode)), setpoints: .single, range: minimumTemperature...maximumTemperature,
            step: temperatureStep, canTurnOff: modes.contains(HAP.off), whileOff: whileOff)
    }

    override func build() throws -> [Service] {
        let capabilities = capabilities
        var optional = [CharacteristicType.currentTemperature.with(minValue: -50, maxValue: 100, minStep: 0.1)]
        if !targetTemperatureWritable {
            // Read-only, as are the thresholds of its Auto Band: the device sets its own target.
            let range = minimumTemperature...maximumTemperature
            var types: [CharacteristicType] = [.targetTemperature]
            if capabilities.modes.contains(.auto) { types += [.heatingThresholdTemperature, .coolingThresholdTemperature] }
            for type in types {
                var readOnly = type.with(minValue: range.lowerBound, maxValue: range.upperBound, minStep: temperatureStep)
                readOnly.permissions = [.pairedRead, .events]
                optional.append(readOnly)
            }
        }
        // 500 ms of gathering: a slider's drag is one execution (6.4), at the test's time scale in tests.
        let climate = ClimateController(
            .thermostat, name: label, isPrimary: true, capabilities: capabilities, optional: optional, window: scaled(0.5)
        ) { [weak self] command in
            try await self?.applyClimate(command)
        }
        self.climate = climate
        let thermostat = climate.service
        thermostat.characteristic(.targetTemperature).setClamped(minimumTemperature)
        if hasProg { thermostat.characteristic(adding: TahomaCharacteristics.prog).value = false }
        if hasEco { thermostat.characteristic(adding: TahomaCharacteristics.eco).value = false }
        if measuresEnergy { thermostat.characteristic(adding: EveCharacteristic.totalConsumption).value = .double(0) }
        climate.update(reading.withLockedValue { $0 })
        if initialTarget != nil || initialCurrent != nil { show(current: initialCurrent, target: initialTarget) }

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
                    if update.state.isFailure { self?.switchServices[subtype]?.characteristic(.on).value = .bool(!on) }
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

    /// The commands of one change: OFF, or the mode chosen (which turns the device on), then the target. A mode or OFF
    /// the device has no command for is "No target command".
    func climateCommands(_ command: ClimateCommand) throws -> [OverkizCommand] {
        var commands: [OverkizCommand] = []
        let state: Int? = command.power == false ? HAP.off : (command.mode ?? (command.power == true ? climate.report?.mode : nil)).map(HAP.value)
        if let state {
            commands = stateCommands(state)
            guard !commands.isEmpty else {
                logger.error("No target command for \(label)")
                throw HAPStatusError(.resourceDoesNotExist)
            }
        }
        if let target = command.target { commands += temperatureCommands(target) }
        // One action per device: a command named twice keeps the later one, as two writes merged did.
        return Executions.merge([], commands)
    }

    /// Sends one change as one execution. A failed execution shows the device's state again; a stateless device keeps
    /// what it was sent once it completed.
    func applyClimate(_ command: ClimateCommand) async throws {
        let commands = try climateCommands(command)
        try await execute(commands) { [weak self] update in
            guard let self else { return }
            if update.state.isFailure {
                climate.update(reading.withLockedValue { $0 })
            } else if update.state == .completed, stateless {
                reading.withLockedValue { reading in
                    if let power = command.power { reading.power = power }
                    if let mode = command.mode { reading.mode = mode }
                    if let target = command.target { reading.target = target }
                }
            }
        }
    }

    // MARK: Showing

    /// Changes the device's state as its states say and shows it. While an execution is in flight, Apple Home keeps the
    /// power, mode and target it asked for: a target follows the device only when idle (6.4).
    func showClimate(_ change: (inout ClimateReport) -> Void) {
        var report = reading.withLockedValue { reading in
            change(&reading)
            return reading
        }
        if !isIdle, let asked = climate.report {
            report.power = asked.power
            report.mode = asked.mode
            report.target = asked.target
        }
        climate.update(report)
    }

    /// What the device does and its target state, as HomeKit names them. `current`: OFF idle, HEAT (or AUTO) heating,
    /// COOL cooling. `target`: OFF its power, another mode one it has (one it has not is ignored).
    func show(current: Int? = nil, target: Int? = nil) {
        let mode = target.flatMap(HAP.climateMode).flatMap { climate.capabilities.modes.contains($0) ? $0 : nil }
        showClimate { report in
            if let current { report.action = current == HAP.off ? .idle : current == HAP.cool ? .cooling : .heating }
            if let target, target == HAP.off || mode != nil {
                report.power = target != HAP.off
                if let mode { report.mode = mode }
            }
        }
    }

    func showTarget(temperature: Double?) {
        guard let temperature, temperature.isFinite else { return }
        showClimate { $0.target = temperature }
    }

    func showCurrent(temperature: Double?) {
        guard let temperature, temperature.isFinite else { return }
        showClimate { $0.current = temperature }
    }

    func showProg(_ value: Bool) { thermostat[TahomaCharacteristics.prog]?.value = .bool(value) }
    func showEco(_ value: Bool) { thermostat[TahomaCharacteristics.eco]?.value = .bool(value) }

    /// `core:TemperatureState`, in kelvin above 273.15.
    func showCurrentTemperature(_ states: [String: JSONValue]) {
        guard let temperature = states["core:TemperatureState"]?.number else { return }
        showCurrent(temperature: temperature > 273.15 ? temperature - 273.15 : temperature)
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

    /// The level decides the temperature: a target sent with a mode is the mode's level.
    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { [] }

    /// A target alone sets the level it snaps to, and that level's mode; while off, it sends nothing. The controller
    /// shows the value asked once this returns: the snapped one (or, while off, the device's) is shown just after.
    override func applyClimate(_ command: ClimateCommand) async throws {
        guard let value = command.target, command.power == nil, command.mode == nil else { return try await super.applyClimate(command) }
        guard isOn else {
            return schedule("snap", after: scaled(0.05)) { [weak self] in self?.showSnapped(nil) }
        }
        let snapped = Self.snap(value, comfort: options.comfort, eco: options.eco)
        let (level, mode): (String, ClimateMode) = switch snapped {
        case 7: ("frostprotection", .cool)
        case options.eco: ("eco", .cool)
        default: ("comfort", .heat)
        }
        try await execute([OverkizCommand("setHeatingLevel", .string(level))]) { [weak self] update in
            guard let self, update.state.isFailure else { return }
            climate.update(reading.withLockedValue { $0 })
        }
        schedule("snap", after: scaled(0.05)) { [weak self] in self?.showSnapped((snapped, mode)) }
    }

    /// Shows the temperature and mode a target snapped to, or the device's state again.
    private func showSnapped(_ snapped: (temperature: Double, mode: ClimateMode)?) {
        let report = reading.withLockedValue { reading in
            if let snapped {
                reading.power = true
                reading.mode = snapped.mode
                reading.target = snapped.temperature
            }
            return reading
        }
        climate.update(report)
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
        showCurrent(temperature: value)
        showTarget(temperature: value)
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
            show(target: HAP.off)
        case "internal":
            showProg(true)
            show(target: HAP.auto)
            let derogated = number("core:DerogatedTargetTemperatureState") ?? 0
            showTarget(temperature: derogated > 0 ? derogated : temperature)
        case "external":
            showProg(false)
            show(target: HAP.auto)
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
            if let value = states[name]?.number { showCurrent(temperature: value) }
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

    /// One `globalControl` for the whole change: the state asked (or the device's) with the target asked (or its own).
    override func climateCommands(_ command: ClimateCommand) throws -> [OverkizCommand] {
        let report = climate.report
        let on = command.power ?? report?.power ?? false
        let state = on ? (command.mode ?? report?.mode).map(HAP.value) ?? HAP.auto : HAP.off
        return globalControl(state: state, temperature: command.target ?? targetTemperature)
    }

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
        if let room = states["ovp:RoomTemperatureState"]?.number { showCurrent(temperature: room) }
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

extension HAP {
    /// A target state's Climate Mode: nil for OFF.
    static func climateMode(_ state: Int) -> ClimateMode? {
        switch state {
        case heat: .heat
        case cool: .cool
        case auto: .auto
        default: nil
        }
    }

    /// A Climate Mode's target state.
    static func value(_ mode: ClimateMode) -> Int {
        switch mode {
        case .heat: heat
        case .cool: cool
        case .auto: auto
        }
    }
}
