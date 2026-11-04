import Foundation
import Homeswift
import HomeswiftAI

/// `WaterHeatingSystem` and `HitachiHeatingSystem/HitachiDHW` (docs/clean-room/Tahoma.md 5.11): the thermostat from
/// 40 to 65 °C, AUTO and OFF.
class WaterHeaterMapper: ThermostatMapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .heater }
    override class var kind: String { "waterHeater" }
    override var minimumTemperature: Double { 40 }
    override var maximumTemperature: Double { 65 }
    override var temperatureStep: Double { 1 }
}

/// `AtlanticPassAPCDHW`: Eco, Prog and a Boost switch.
final class PassAPCDHWMapper: WaterHeaterMapper, @unchecked Sendable {
    override var hasProg: Bool { true }
    override var hasEco: Bool { true }
    override var switches: [(subtype: String, name: String)] { device.has("setBoostOnOffState") ? [("boost", "Boost")] : [] }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        guard target != HAP.off else { return [OverkizCommand("setDHWOnOffState", "off")] }
        return [OverkizCommand("setDHWOnOffState", "on"), OverkizCommand("setPassAPCDHWMode", .string(prog ? "internalScheduling" : eco ? "eco" : "comfort"))]
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        [OverkizCommand(targetState == HAP.cool ? "setEcoTargetDHWTemperature" : "setComfortTargetDHWTemperature", .number(value))]
    }

    override func switchCommands(_ subtype: String, on: Bool) -> [OverkizCommand] {
        [OverkizCommand("setBoostOnOffState", .string(on ? "on" : "off"))]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let value = states["core:TargetDHWTemperatureState"]?.number { thermostat.characteristic(.currentTemperature).setClamped(value) }
        if let boost = states["core:BoostOnOffState"]?.stringValue { switchServices["boost"]?.characteristic(.on).value = .bool(boost == "on") }
    }

    override func computeStates() {
        let comfort = number("core:ComfortTargetDHWTemperatureState"), eco = number("core:EcoTargetDHWTemperatureState")
        guard string("core:DHWOnOffState") != "off" else {
            show(current: HAP.off, target: HAP.off)
            return showTarget(temperature: number("core:TargetDHWTemperatureState"))
        }
        switch string("io:PassAPCDHWModeState") {
        case "off", "stop":
            show(current: HAP.off, target: HAP.off)
        case "internalScheduling", "externalScheduling":
            showProg(true)
            let comfortProfile = string("io:PassAPCDHWProfileState") == "comfort"
            show(current: comfortProfile ? HAP.heat : HAP.cool, target: HAP.auto)
            showTarget(temperature: comfortProfile ? comfort : eco)
        case "comfort":
            show(current: HAP.heat, target: HAP.auto)
            showTarget(temperature: comfort)
        case "eco":
            showEco(true)
            show(current: HAP.cool, target: HAP.auto)
            showTarget(temperature: eco)
        default:
            break
        }
    }
}

/// `DomesticHotWaterProduction`: AUTO, HEAT and OFF, Eco, a Boost switch, and the showers left when it counts them.
class HotWaterProductionMapper: WaterHeaterMapper, @unchecked Sendable {
    override var modes: [Int] { [HAP.off, HAP.heat, HAP.auto] }
    override var hasEco: Bool { true }
    override var switches: [(subtype: String, name: String)] { [("boost", "Boost")] }

    override func build() throws -> [Service] {
        let services = try super.build()
        if hasState("core:NumberOfShowerRemainingState") {
            thermostat.characteristic(adding: TahomaCharacteristics.currentShower)
            let minimum = number("core:MinimalShowerManualModeState") ?? 0, maximum = number("core:MaximalShowerManualModeState") ?? 8
            let range = maximum >= minimum ? (minimum, maximum) : (0, 8)
            thermostat.characteristic(adding: TahomaCharacteristics.targetShower.with(minValue: range.0, maxValue: range.1)).onWrite { [weak self] value in
                guard let self else { return }
                let previous = thermostat[TahomaCharacteristics.targetShower]?.value ?? .null
                try await execute([OverkizCommand("setExpectedNumberOfShower", .number(value.doubleValue ?? 0))]) { [weak self] update in
                    if update.state == .failed || update.state == .timedOut { self?.thermostat[TahomaCharacteristics.targetShower]?.value = previous }
                }
            }
        }
        return services
    }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        if device.has("setDHWMode") {
            var commands = targetState == HAP.off ? [OverkizCommand("setAbsenceMode", "off")] : []
            switch target {
            case HAP.auto: commands.append(OverkizCommand("setDHWMode", "autoMode"))
            case HAP.heat: commands.append(OverkizCommand("setDHWMode", .string(eco ? "manualEcoActive" : "manualEcoInactive")))
            default: commands = [OverkizCommand("setAbsenceMode", "on")]
            }
            return commands
        }
        if device.has("setCurrentOperatingMode") {
            switch target {
            case HAP.auto: return [OverkizCommand("setCurrentOperatingMode", ["relaunch": "off", "absence": "off"])]
            case HAP.heat: return [OverkizCommand("setCurrentOperatingMode", ["relaunch": "on", "absence": "off"])]
            default: return [OverkizCommand("setCurrentOperatingMode", ["relaunch": "off", "absence": "on"])]
            }
        }
        if device.has("setBoostModeDuration") {
            switch target {
            case HAP.auto: return [OverkizCommand("setBoostModeDuration", 0), OverkizCommand("setAwayModeDuration", 0)]
            case HAP.heat: return [OverkizCommand("setBoostModeDuration", 1)]
            default: return [OverkizCommand("setAwayModeDuration", 30)]
            }
        }
        if device.has("setBoostMode") {
            switch target {
            case HAP.auto: return [OverkizCommand("setBoostMode", "off"), OverkizCommand("setAbsenceMode", "off")]
            case HAP.heat: return [OverkizCommand("setBoostMode", "on")]
            default: return [OverkizCommand("setAbsenceMode", "on")]
            }
        }
        return []
    }

    override func temperatureCommands(_ value: Double) -> [OverkizCommand] { [OverkizCommand("setWaterTargetTemperature", .number(value))] }

    override func switchCommands(_ subtype: String, on: Bool) -> [OverkizCommand] { [OverkizCommand("setBoostMode", .string(on ? "on" : "off"))] }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        for name in ["io:DHWBoostModeState", "modbuslink:DHWBoostModeState"] {
            if let boost = states[name]?.scalarText { switchServices["boost"]?.characteristic(.on).value = .bool(boost != "off") }
        }
        if !hasState("io:MiddleWaterTemperatureState"), let value = states["core:WaterTemperatureState"]?.number {
            thermostat.characteristic(.currentTemperature).setClamped(value)
        }
        for name in ["io:MiddleWaterTemperatureState", "modbuslink:MiddleWaterTemperatureState"] {
            if let value = states[name]?.number { thermostat.characteristic(.currentTemperature).setClamped(value) }
        }
        for name in ["core:TargetTemperatureState", "core:WaterTargetTemperatureState"] {
            if let value = states[name]?.number { showTarget(temperature: value) }
        }
        if let value = states["core:NumberOfShowerRemainingState"]?.number { thermostat[TahomaCharacteristics.currentShower]?.setClamped(value) }
        if let value = states["core:ExpectedNumberOfShowerState"]?.number { thermostat[TahomaCharacteristics.targetShower]?.setClamped(value) }
    }

    override func computeStates() {
        let prefix = hasState("modbuslink:DHWModeState") && !hasState("io:DHWModeState") ? "modbuslink" : "io"
        guard let absence = string("\(prefix):DHWAbsenceModeState") else { return }
        guard absence == "off" else { return show(current: HAP.off, target: HAP.off) }
        switch string("\(prefix):DHWModeState") {
        case "autoMode": show(current: HAP.heat, target: HAP.auto)
        case "manualEcoInactive":
            showEco(false)
            show(current: HAP.heat, target: HAP.heat)
        case "manualEcoActive":
            showEco(true)
            show(current: HAP.cool, target: HAP.heat)
        default: break
        }
    }
}

/// `DomesticHotWaterProduction/AtlanticDomesticHotWaterProductionV2_SPLIT_IOComponent`: 50 to 54.5 °C, its operating
/// mode an object (`relaunch`, `absence`).
final class HotWaterSplitMapper: HotWaterProductionMapper, @unchecked Sendable {
    override var minimumTemperature: Double { 50 }
    override var maximumTemperature: Double { 54.5 }
    override var temperatureStep: Double { 0.5 }

    override func stateCommands(_ target: Int) -> [OverkizCommand] {
        var commands = targetState == HAP.off ? [OverkizCommand("setCurrentOperatingMode", ["relaunch": "off", "absence": "off"])] : []
        switch target {
        case HAP.auto: commands.append(OverkizCommand("setDHWMode", "autoMode"))
        case HAP.heat: commands.append(OverkizCommand("setDHWMode", .string(eco ? "manualEcoActive" : "manualEcoInactive")))
        default: commands = [OverkizCommand("setCurrentOperatingMode", ["relaunch": "off", "absence": "on"])]
        }
        return commands
    }

    /// 54 is sent as 54.5, as the Homebridge plugin did.
    override func temperatureCommands(_ value: Double) -> [OverkizCommand] {
        [OverkizCommand("setTargetTemperature", .number(value == 54 ? 54.5 : value))]
    }

    override func switchCommands(_ subtype: String, on: Bool) -> [OverkizCommand] {
        [OverkizCommand("setCurrentOperatingMode", ["relaunch": .string(on ? "on" : "off"), "absence": "off"])]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL else { return }
        if let value = states["io:MiddleWaterTemperatureState"]?.number { thermostat.characteristic(.currentTemperature).setClamped(value) }
        if let value = states["core:TargetTemperatureState"]?.number { showTarget(temperature: value) }
    }

    override func computeStates() {
        guard let mode = state("core:OperatingModeState") else { return }
        if let relaunch = mode["relaunch"]?.stringValue { switchServices["boost"]?.characteristic(.on).value = .bool(relaunch != "off") }
        guard mode["absence"]?.stringValue == "off" else { return show(current: HAP.off, target: HAP.off) }
        let heating = (number("io:PowerHeatElectricalState") ?? 0) > 100 || (number("io:PowerHeatPumpState") ?? 0) > 100
        switch string("io:DHWModeState") {
        case "autoMode": show(current: heating ? HAP.heat : HAP.off, target: HAP.auto)
        case "manualEcoInactive":
            showEco(false)
            show(current: heating ? HAP.heat : HAP.off, target: HAP.heat)
        case "manualEcoActive":
            showEco(true)
            show(current: heating ? HAP.heat : HAP.off, target: HAP.heat)
        default: break
        }
    }
}

// MARK: - Ventilation

/// `VentilationSystem` and `VentilationSystem/DimplexVentilationInletOutlet`: an Air Purifier whose target is the air
/// demand mode. Active and its current state follow the device here (the Homebridge plugin left them as they were).
final class VentilationMapper: Mapper, @unchecked Sendable {
    override class var category: AccessoryCategory { .airPurifier }
    override class var kind: String { "ventilation" }
    private var purifier: Service!

    var dimplex: Bool { device.widgetName == "DimplexVentilationInletOutlet" }

    override func build() throws -> [Service] {
        let purifier = Service(.airPurifier, name: label, isPrimary: true)
        purifier.characteristic(.active).value = 1
        purifier.characteristic(.currentAirPurifierState).value = 2
        purifier.characteristic(.active).onWrite { _ in }
        purifier.characteristic(.targetAirPurifierState).onWrite { [weak self] value in
            guard let self else { return }
            let auto = value.intValue == 1
            let mode = auto ? "auto" : (dimplex ? "max" : "boost")
            try await execute([OverkizCommand("setAirDemandMode", .string(mode))]) { [weak self] update in
                guard let self, update.state == .failed || update.state == .timedOut else { return }
                self.purifier.characteristic(.targetAirPurifierState).value = .int(auto ? 0 : 1)
            }
        }
        self.purifier = purifier
        return [purifier]
    }

    override func apply(_ states: [String: JSONValue], from deviceURL: String) {
        guard deviceURL == device.deviceURL, let mode = states["io:AirDemandModeState"]?.stringValue else { return }
        purifier.characteristic(.targetAirPurifierState).value = .int(mode == "auto" ? 1 : 0)
        purifier.characteristic(.active).value = 1
        purifier.characteristic(.currentAirPurifierState).value = 2
    }
}
