import Foundation
import Homeswift
import HomeswiftPlugin
import Matter

/// One HAP service as one function of a Matter bridged device: the Matter device kind it becomes, the state it
/// reports from its characteristics, and the characteristic writes a Matter command turns into. Conversions follow
/// the mapping table of docs/matter.md.
struct ServiceMapping: Sendable {
    enum Role: Sendable, Equatable {
        case light(dimmable: Bool, colorTemperature: Bool, hueSaturation: Bool)
        case plug
        case contact
        case occupancy
        case temperature
        case humidity
        case illuminance
        case leak
        case covering
        /// A fan, with Swing Mode (rocking) and Rotation Direction (airflow) when it has them.
        case fan(rocking: Bool, direction: Bool)
        case thermostat(cooling: Bool)
        /// A Heater Cooler: a thermostat with the modes its target state allows, auto keeping it between its thresholds.
        case heaterCooler(heating: Bool, cooling: Bool, auto: Bool)
        case lock
        /// A Garage Door Opener: a Closure of the garage door kind.
        case garageDoor
        case button
        /// An Air Quality Sensor, or a Carbon Dioxide Sensor, with the concentrations it reports.
        case airQuality(measuring: [Concentration])
        /// An Air Purifier, with the accessory's Filter Maintenance when it has one.
        case airPurifier(filter: Bool, rocking: Bool)
        /// A smoke alarm, or a carbon monoxide one.
        case alarm(smoke: Bool)
        case valve
        /// A Switch that runs a cleaning robot (`Service.standsFor`): a Robotic Vacuum Cleaner.
        case cleaningRobot

        /// The role without its details (`light`, `airQuality`): the Status page picks an icon by it.
        var name: String { String(String(describing: self).prefix { $0 != "(" }) }
    }

    let role: Role
    let service: Service
    /// An air purifier's Filter Maintenance, the service it links: reported with it.
    let filter: Service?
    /// Whether the service reports Eve's power or energy readings: its device is metered too.
    let isMetered: Bool

    /// The Filter Maintenance an air purifier links, as HomeKit groups them.
    private static func linkedFilter(_ service: Service) -> Service? {
        guard service.type.uuid == ServiceType.airPurifier.uuid else { return nil }
        return service.linked.first { $0.type.uuid == ServiceType.filterMaintenance.uuid && !$0.isHidden }
    }

    /// The characteristics the mapping reports, its filter's included.
    var characteristics: [Characteristic] { service.characteristics + (filter?.characteristics ?? []) }

    /// The concentrations Matter measures and the HAP characteristic that reports each.
    static let concentrations: [(Concentration, CharacteristicType)] = [
        (.carbonDioxide, .carbonDioxideLevel), (.pm25, .pm2_5Density), (.pm10, .pm10Density), (.totalVolatileOrganicCompounds, .vocDensity),
    ]

    /// The mapping of a service, or nil for one Matter does not get (information, battery, a camera's, a lock or a garage
    /// door while `exposeSecurity` is off).
    init?(_ service: Service, exposeSecurity: Bool) {
        guard !service.isHidden else { return nil }
        let type = service.type.uuid
        let filter = Self.linkedFilter(service)
        func has(_ characteristic: CharacteristicType) -> Bool { service[characteristic] != nil }
        let role: Role
        switch type {
        case ServiceType.lightbulb.uuid:
            role = .light(dimmable: has(.brightness), colorTemperature: has(.colorTemperature), hueSaturation: has(.hue) && has(.saturation))
        case ServiceType.switch.uuid where service.standsFor == .cleaningRobot: role = .cleaningRobot
        case ServiceType.outlet.uuid, ServiceType.switch.uuid: role = .plug
        case ServiceType.contactSensor.uuid: role = .contact
        case ServiceType.motionSensor.uuid, ServiceType.occupancySensor.uuid: role = .occupancy
        case ServiceType.temperatureSensor.uuid: role = .temperature
        case ServiceType.humiditySensor.uuid: role = .humidity
        case ServiceType.lightSensor.uuid: role = .illuminance
        case ServiceType.leakSensor.uuid: role = .leak
        // A door or a window moves to a percentage as a covering does, and every ecosystem shows coverings.
        case ServiceType.windowCovering.uuid, ServiceType.door.uuid, ServiceType.window.uuid: role = .covering
        case ServiceType.fan.uuid, ServiceType.fanv2.uuid: role = .fan(rocking: has(.swingMode), direction: has(.rotationDirection))
        case ServiceType.thermostat.uuid:
            // Cooling when the target state allows it (2): HAP's default range does, a heater narrows it.
            let modes = service[.targetHeatingCoolingState]?.type.validValues ?? [0, 1, 2, 3]
            role = .thermostat(cooling: modes.contains(2))
        case ServiceType.heaterCooler.uuid:
            // Target Heater Cooler State: auto 0, heat 1, cool 2, as its valid values allow.
            let modes = service[.targetHeaterCoolerState]?.type.validValues ?? [0, 1, 2]
            let heating = modes.contains(1) || !modes.contains(2), cooling = modes.contains(2)
            // Auto needs both: swift-matter offers it only to a thermostat that heats and cools.
            role = .heaterCooler(heating: heating, cooling: cooling, auto: modes.contains(0))
        case ServiceType.lockMechanism.uuid: role = .lock
        case ServiceType.garageDoorOpener.uuid: role = .garageDoor
        case ServiceType.statelessProgrammableSwitch.uuid: role = .button
        case ServiceType.airQualitySensor.uuid, ServiceType.carbonDioxideSensor.uuid:
            role = .airQuality(measuring: Self.concentrations.filter { has($0.1) }.map(\.0))
        case ServiceType.airPurifier.uuid: role = .airPurifier(filter: filter != nil, rocking: has(.swingMode))
        case ServiceType.smokeSensor.uuid: role = .alarm(smoke: true)
        case ServiceType.carbonMonoxideSensor.uuid: role = .alarm(smoke: false)
        case ServiceType.valve.uuid, ServiceType.faucet.uuid: role = .valve
        default: return nil
        }
        // A lock, a door (an entrance that opens, though its position is not a security control in HAP), or a service whose
        // write opens something (a garage door, a switch that unlocks a door), only when asked for.
        if !exposeSecurity, role == .lock || type == ServiceType.door.uuid || service.characteristics.contains(where: \.isSecurityControl) { return nil }
        self.role = role
        self.service = service
        self.filter = filter
        isMetered = service[EveCharacteristic.currentConsumption] != nil || service[EveCharacteristic.totalConsumption] != nil
    }


    /// The Matter device kind, metered when the service reports power or energy.
    var kind: DeviceKind { isMetered ? baseKind.metered() : baseKind }

    private var baseKind: DeviceKind {
        switch role {
        case .light(let dimmable, let colorTemperature, let hueSaturation):
            if hueSaturation { return .extendedColorLight(mireds: miredRange) }
            if colorTemperature { return .colorTemperatureLight(mireds: miredRange) }
            return dimmable ? .dimmableLight : .onOffLight
        case .plug: return .onOffPlug
        case .contact: return .contactSensor
        case .occupancy: return .occupancySensor
        case .temperature: return .temperatureSensor
        case .humidity: return .humiditySensor
        case .illuminance: return .lightSensor
        case .leak: return .waterLeakDetector
        case .covering: return .windowCovering
        case .fan(let rocking, let direction): return .fan(rocking: rocking, airflowDirection: direction)
        case .thermostat(let cooling): return .thermostat(heating: true, cooling: cooling)
        case .heaterCooler(let heating, let cooling, let auto): return .thermostat(heating: heating, cooling: cooling, auto: auto)
        case .lock: return .doorLock
        case .garageDoor: return .closure(.garageDoor)
        case .button: return .genericSwitch
        case .airQuality(let measuring): return .airQualitySensor(measuring: measuring)
        case .airPurifier(let filter, let rocking): return .airPurifier(filter: filter, rocking: rocking)
        case .alarm(let smoke): return .smokeCOAlarm(smoke: smoke, carbonMonoxide: !smoke)
        case .valve: return .waterValve
        case .cleaningRobot: return .roboticVacuum
        }
    }

    /// HAP's Color Temperature range, 140–500 mireds unless the type narrows it.
    private var miredRange: ClosedRange<UInt16> {
        let type = service[.colorTemperature]?.type ?? CharacteristicType.colorTemperature
        let low = UInt16(clamping: Int(type.minValue ?? 140)), high = UInt16(clamping: Int(type.maxValue ?? 500))
        return low < high ? low...high : 140...500
    }

    // MARK: - HAP to Matter

    /// The state to report: all of it, or what follows from one characteristic that changed.
    func states(changed changedType: HAPUUID? = nil) -> [DeviceState] {
        func value(_ type: CharacteristicType) -> HAPValue? {
            guard changedType == nil || changedType == type.uuid else { return nil }
            return service[type]?.value
        }
        var states: [DeviceState] = []
        switch role {
        case .light, .plug:
            if let on = value(.on)?.boolValue { states.append(.on(on)) }
            if let brightness = value(.brightness)?.doubleValue { states.append(.level(Self.level(percent: brightness))) }
            if let mireds = value(.colorTemperature)?.intValue {
                states.append(.colorTemperature(mireds: UInt16(clamping: mireds)))
            }
            // Hue and saturation travel together: either one changing reports both. At start a light with a color
            // temperature reports that, not its color.
            let colorChanged = [CharacteristicType.hue.uuid, CharacteristicType.saturation.uuid].contains(changedType)
                || changedType == nil && service[.colorTemperature] == nil
            if colorChanged, case .light(_, _, true) = role,
               let hue = service[.hue]?.value.doubleValue, let saturation = service[.saturation]?.value.doubleValue {
                states.append(.hueSaturation(hue: Self.scale(hue, from: 360), saturation: Self.scale(saturation, from: 100)))
            }
        case .contact:
            // HAP's 0 is "contact detected", a closed door: Matter's StateValue true.
            if let state = value(.contactSensorState)?.intValue { states.append(.contact(state == 0)) }
        case .occupancy:
            if let detected = (value(.motionDetected) ?? value(.occupancyDetected)).flatMap(Self.flag) { states.append(.occupied(detected)) }
        case .temperature:
            if let celsius = value(.currentTemperature) { states.append(.temperature(celsius.doubleValue)) }
        case .humidity:
            if let percent = value(.currentRelativeHumidity) { states.append(.humidity(percent.doubleValue)) }
        case .illuminance:
            if let lux = value(.currentAmbientLightLevel) { states.append(.illuminance(lux: lux.doubleValue)) }
        case .leak:
            if let detected = value(.leakDetected).flatMap(Self.flag) { states.append(.leak(detected)) }
        case .covering:
            // HAP counts percent open, Matter hundredths of a percent closed.
            if let open = value(.currentPosition)?.doubleValue {
                states.append(.coveringPosition(percent100ths: UInt16((100 - min(max(open, 0), 100)) * 100)))
            }
        case .fan, .airPurifier:
            if changedType == nil || [CharacteristicType.on.uuid, CharacteristicType.active.uuid, CharacteristicType.rotationSpeed.uuid].contains(changedType) {
                states.append(.fanSpeed(percent: fanPercent))
            }
            if let swing = value(.swingMode).flatMap(Self.flag) { states.append(.fanRocking(swing)) }
            // Clockwise 0 is the usual airflow, forward; counter-clockwise (1) reverses it. Only a fan's has the feature.
            if case .fan(_, true) = role, let reversed = value(.rotationDirection).flatMap(Self.flag) { states.append(.fanAirflowReversed(reversed)) }
            if let filter, changedType == nil || changedType == CharacteristicType.filterLifeLevel.uuid || changedType == CharacteristicType.filterChangeIndication.uuid {
                let left = filter[.filterLifeLevel]?.value.doubleValue.map { UInt8(min(max($0, 0), 100).rounded()) }
                states.append(.filter(percentLeft: left, needsChange: filter[.filterChangeIndication].flatMap { Self.flag($0.value) } ?? false))
            }
        case .thermostat:
            if let celsius = value(.currentTemperature) { states.append(.localTemperature(celsius.doubleValue)) }
            let mode = service[.targetHeatingCoolingState]?.value.intValue ?? 1
            if value(.targetHeatingCoolingState) != nil { states.append(.thermostatMode(Self.systemMode(hap: mode))) }
            // HAP has one target; Matter a setpoint per mode: the one of the mode in use, again when the mode changes.
            let modeChanged = changedType == CharacteristicType.targetHeatingCoolingState.uuid
            if let target = (modeChanged ? service[.targetTemperature]?.value : value(.targetTemperature))?.doubleValue {
                states.append(mode == 2 ? .coolingSetpoint(target) : .heatingSetpoint(target))
            }
        case .heaterCooler(let heating, let cooling, _):
            if let celsius = value(.currentTemperature) { states.append(.localTemperature(celsius.doubleValue)) }
            if changedType == nil || changedType == CharacteristicType.active.uuid || changedType == CharacteristicType.targetHeaterCoolerState.uuid {
                states.append(.thermostatMode(Self.systemMode(active: service[.active]?.value.intValue ?? 1, heaterCooler: service[.targetHeaterCoolerState]?.value.intValue ?? 1)))
            }
            // Only the setpoints its thermostat has: a cooler may carry a heating threshold it never uses.
            if heating, let celsius = value(.heatingThresholdTemperature)?.doubleValue { states.append(.heatingSetpoint(celsius)) }
            if cooling, let celsius = value(.coolingThresholdTemperature)?.doubleValue { states.append(.coolingSetpoint(celsius)) }
        case .garageDoor:
            // Open 0, closed 1, opening 2, closing 3, stopped 4: on its way it is partly open.
            if let state = value(.currentDoorState)?.intValue {
                let position: ClosurePosition? = state == 0 ? .fullyOpened : state == 1 ? .fullyClosed : (2...4).contains(state) ? .partiallyOpened : nil
                states.append(.closure(position, moving: state == 2 || state == 3))
            }
        case .lock:
            if let state = value(.lockCurrentState)?.intValue {
                // Unsecured 0, secured 1, jammed 2, unknown 3.
                states.append(.locked(state == 1 ? true : state == 0 ? false : nil))
            }
        case .button:
            break
        case .airQuality(let measuring):
            // HAP excellent 1 to poor 5 are Matter's good 1 to very poor 5; unknown stays 0. A carbon dioxide sensor says only
            // whether the level is abnormal: poor, else good.
            if let quality = value(.airQuality)?.intValue { states.append(.airQuality(UInt8(clamping: min(max(quality, 0), 5)))) }
            if let abnormal = value(.carbonDioxideDetected).flatMap(Self.flag) { states.append(.airQuality(abnormal ? 4 : 1)) }
            for (concentration, type) in Self.concentrations where measuring.contains(concentration) {
                if let reading = value(type) { states.append(.concentration(concentration, reading.doubleValue)) }
            }
        case .alarm(let smoke):
            if let detected = value(smoke ? .smokeDetected : .carbonMonoxideDetected).flatMap(Self.flag) {
                states.append(smoke ? .smoke(detected) : .carbonMonoxide(detected))
            }
        case .valve:
            // In Use says whether water flows: the valve is open. A faucet has only Active.
            if let open = value(service[.inUse] != nil ? .inUse : .active).flatMap(Self.flag) { states.append(.valveOpen(open)) }
        case .cleaningRobot:
            // The switch says only whether it cleans: running, else stopped (where it is is not known).
            if let on = value(.on)?.boolValue { states.append(.robot(on ? .running : .stopped)) }
        }
        if isMetered {
            if let watts = value(EveCharacteristic.currentConsumption) { states.append(.power(watts: watts.doubleValue)) }
            if let kilowattHours = value(EveCharacteristic.totalConsumption) { states.append(.energy(kilowattHours: kilowattHours.doubleValue)) }
        }
        return states
    }

    /// A Stateless Programmable Switch's press: single 0, double 1, long 2.
    static func press(_ value: HAPValue) -> ButtonPress? {
        switch value.intValue {
        case 0: .single
        case 1: .double
        case 2: .long
        default: nil
        }
    }

    private var fanPercent: UInt8 {
        let running = service[.active]?.value.intValue.map { $0 == 1 } ?? service[.on]?.value.boolValue ?? false
        guard running else { return 0 }
        return UInt8(clamping: Int((service[.rotationSpeed]?.value.doubleValue ?? 100).rounded()))
    }

    // MARK: - Matter to HAP

    /// The characteristic writes a command asks for, in order. Empty when this service has nothing for it.
    func writes(for command: DeviceCommand) -> [(Characteristic, HAPValue)] {
        var writes: [(Characteristic, HAPValue)] = []
        func write(_ type: CharacteristicType, _ value: HAPValue) {
            if let characteristic = service[type] { writes.append((characteristic, value)) }
        }
        switch command {
        case .setOn(let on):
            write(.on, .bool(on))
        case .setLevel(let level):
            write(.brightness, .int(Self.percent(level: level)))
        case .setColorTemperature(let mireds):
            if service[.colorTemperature] != nil {
                write(.colorTemperature, .int(Int(mireds)))
            } else {
                // An Extended Color Light has whites in Matter: a light with only hue and saturation shows the color
                // of that white, from the table Adaptive Lighting uses.
                let white = ColorUtils.colorTemperatureToHueAndSaturation(Double(mireds))
                write(.hue, .double(white.hue))
                write(.saturation, .double(white.saturation))
            }
        case .setHueSaturation(let hue, let saturation):
            write(.hue, .double(Self.unscale(hue, to: 360)))
            write(.saturation, .double(Self.unscale(saturation, to: 100)))
        case .setColorXY(let x, let y):
            let color = ColorConversion.hueSaturation(x: Double(x) / 65536, y: Double(y) / 65536)
            write(.hue, .double(color.hue.rounded()))
            write(.saturation, .double(color.saturation.rounded()))
        case .setCoveringPosition(let closed):
            write(.targetPosition, .int(100 - Int((Double(min(closed, 10_000)) / 100).rounded())))
        case .stopCovering:
            if service[.holdPosition] != nil {
                write(.holdPosition, .bool(true))
            } else if let current = service[.currentPosition]?.value {
                write(.targetPosition, current)
            }
        case .setFanSpeed(let percent):
            let running = percent > 0
            if service[.active] != nil { write(.active, .int(running ? 1 : 0)) } else { write(.on, .bool(running)) }
            if running { write(.rotationSpeed, .double(Double(percent))) }
        case .setFanRocking(let rocking):
            write(.swingMode, .int(rocking ? 1 : 0))
        case .setFanAirflowReversed(let reversed):
            write(.rotationDirection, .int(reversed ? 1 : 0))
        case .resetFilter:
            if let reset = filter?[.resetFilterIndication] { writes.append((reset, .int(1))) }
        case .setHeatingSetpoint(let celsius):
            write(setpoints.heating, .double(celsius))
        case .setCoolingSetpoint(let celsius):
            write(setpoints.cooling, .double(celsius))
        case .setThermostatMode(let mode):
            if case .heaterCooler = role {
                // Off is Active off; a mode is Active on with the Target Heater Cooler State.
                guard let target = Self.heaterCoolerMode(systemMode: mode) else { write(.active, .int(0)); break }
                write(.active, .int(1))
                write(.targetHeaterCoolerState, .int(target))
            } else if let hap = Self.hapMode(systemMode: mode) {
                write(.targetHeatingCoolingState, .int(hap))
            }
        case .setLocked(let locked):
            write(.lockTargetState, .int(locked ? 1 : 0))
        case .setValveOpen(let open):
            write(.active, .int(open ? 1 : 0))
        case .startCleaning, .resumeCleaning:
            if role == .cleaningRobot { write(.on, .bool(true)) }
        case .stopCleaning, .pauseCleaning, .returnToDock:
            // The switch only starts and stops: pausing and going home stop it, and the robot goes back by itself.
            if role == .cleaningRobot { write(.on, .bool(false)) }
        case .setClosureOpen(let open):
            // Target Door State: open 0, closed 1.
            write(.targetDoorState, .int(open ? 0 : 1))
        case .identify, .stopClosure:
            // Identify goes to the accessory; a garage door cannot be stopped from HAP.
            break
        }
        return writes
    }

    /// The characteristics Matter's two setpoints write: a Heater Cooler's thresholds, else the one target temperature.
    private var setpoints: (heating: CharacteristicType, cooling: CharacteristicType) {
        if case .heaterCooler = role { return (.heatingThresholdTemperature, .coolingThresholdTemperature) }
        return (.targetTemperature, .targetTemperature)
    }

    // MARK: - Conversions

    /// HAP Brightness 0–100 % to Matter CurrentLevel 1–254.
    static func level(percent: Double) -> UInt8 {
        UInt8(max(1, min(254, (min(max(percent, 0), 100) * 254 / 100).rounded())))
    }

    /// Matter CurrentLevel 1–254 to HAP Brightness, at least 1 % so a dimmed light stays on.
    static func percent(level: UInt8) -> Int {
        max(1, Int((Double(min(level, 254)) * 100 / 254).rounded()))
    }

    /// A value in 0...range (hue's degrees, saturation's percent) to Matter's 0–254.
    static func scale(_ value: Double, from range: Double) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((min(max(value, 0), range) * 254 / range).rounded())
    }

    static func unscale(_ value: UInt8, to range: Double) -> Double {
        (Double(min(value, 254)) * range / 254).rounded()
    }

    /// HAP Target Heating Cooling State (off 0, heat 1, cool 2, auto 3) to Matter's SystemMode (off 0, cool 3, heat 4):
    /// auto, which the bridge's thermostats do not offer in Matter, shows as heat.
    static func systemMode(hap: Int) -> UInt8 {
        typealias Mode = ThermostatCluster.SystemModeEnum
        return UInt8(hap == 0 ? Mode.off : hap == 2 ? Mode.cool : Mode.heat)
    }

    static func hapMode(systemMode: UInt8) -> Int? {
        switch UInt64(systemMode) {
        case ThermostatCluster.SystemModeEnum.off: 0
        case ThermostatCluster.SystemModeEnum.heat: 1
        case ThermostatCluster.SystemModeEnum.cool: 2
        default: nil
        }
    }

    /// A Heater Cooler's Active and Target Heater Cooler State (auto 0, heat 1, cool 2) to Matter's SystemMode (off 0,
    /// auto 1, cool 3, heat 4).
    /// Heat 1 and cool 2 are the Thermostat's own: `systemMode(hap:)` has them.
    static func systemMode(active: Int, heaterCooler target: Int) -> UInt8 {
        active == 0 ? UInt8(ThermostatCluster.SystemModeEnum.off) : target == 0 ? UInt8(ThermostatCluster.SystemModeEnum.auto) : systemMode(hap: target)
    }

    /// Matter's SystemMode to a Target Heater Cooler State, nil for off (and the modes a Heater Cooler does not have).
    static func heaterCoolerMode(systemMode: UInt8) -> Int? {
        if UInt64(systemMode) == ThermostatCluster.SystemModeEnum.auto { return 0 }
        return hapMode(systemMode: systemMode).flatMap { $0 == 0 ? nil : $0 }
    }

    private static func flag(_ value: HAPValue) -> Bool? { value.boolValue ?? value.intValue.map { $0 != 0 } }
}

/// CIE 1931 chromaticity, as Matter's Color Control sends it, to the hue and saturation HAP lights take.
enum ColorConversion {
    /// Hue in degrees, saturation in percent, through linear sRGB (D65) at full brightness.
    static func hueSaturation(x: Double, y: Double) -> (hue: Double, saturation: Double) {
        guard y > 0, x >= 0, x + y <= 1 else { return (0, 0) }
        let X = x / y, Z = (1 - x - y) / y
        func gamma(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        var rgb = [3.2406 * X - 1.5372 - 0.4986 * Z, -0.9689 * X + 1.8758 + 0.0415 * Z, 0.0557 * X - 0.2040 + 1.0570 * Z].map { max($0, 0) }
        let peak = rgb.max() ?? 0
        guard peak > 0 else { return (0, 0) }
        rgb = rgb.map { gamma($0 / peak) }
        let high = rgb.max()!, low = rgb.min()!, delta = high - low
        guard delta > 0 else { return (0, 0) }
        var hue: Double
        if high == rgb[0] {
            hue = (rgb[1] - rgb[2]) / delta
        } else if high == rgb[1] {
            hue = (rgb[2] - rgb[0]) / delta + 2
        } else {
            hue = (rgb[0] - rgb[1]) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, delta / high * 100)
    }
}
