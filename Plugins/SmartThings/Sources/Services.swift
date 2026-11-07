import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

// The services of section 7.3, each with the updater that shows the status and the handlers that send commands.

/// A sensor of section 7.3.8.
struct Sensor: Sendable {
    var capability: String
    var attribute: String
    var service: ServiceType
    var characteristic: CharacteristicType
    var role: String
    var value: @Sendable (_ status: DeviceStatus, _ component: String) -> HAPValue?

    static let all: [Sensor] = [
        Sensor(capability: "motionSensor", attribute: "motion", service: .motionSensor, characteristic: .motionDetected, role: "motion") {
            $0.string($1, "motionSensor", "motion").map { .bool($0 == "active") }
        },
        Sensor(capability: "waterSensor", attribute: "water", service: .leakSensor, characteristic: .leakDetected, role: "leak") {
            $0.string($1, "waterSensor", "water").map { .int($0 == "wet" ? 1 : 0) }
        },
        Sensor(capability: "smokeDetector", attribute: "smoke", service: .smokeSensor, characteristic: .smokeDetected, role: "smoke") {
            $0.string($1, "smokeDetector", "smoke").map { .int($0 == "detected" ? 1 : 0) }
        },
        Sensor(capability: "carbonMonoxideDetector", attribute: "carbonMonoxide", service: .carbonMonoxideSensor, characteristic: .carbonMonoxideDetected, role: "carbonMonoxide") {
            $0.string($1, "carbonMonoxideDetector", "carbonMonoxide").map { .int($0 == "detected" ? 1 : 0) }
        },
        Sensor(capability: "presenceSensor", attribute: "presence", service: .occupancySensor, characteristic: .occupancyDetected, role: "presence") {
            $0.string($1, "presenceSensor", "presence").map { .int($0 == "present" ? 1 : 0) }
        },
        Sensor(capability: "occupancySensor", attribute: "occupancy", service: .occupancySensor, characteristic: .occupancyDetected, role: "occupancy") {
            $0.string($1, "occupancySensor", "occupancy").map { .int($0 == "occupied" ? 1 : 0) }
        },
        Sensor(capability: "temperatureMeasurement", attribute: "temperature", service: .temperatureSensor,
               characteristic: .currentTemperature.with(minValue: -100, maxValue: 200, minStep: 0.1), role: "temperature") { status, component in
            status.number(component, "temperatureMeasurement", "temperature").map {
                .double(Convert.celsius($0, unit: status.unit(component, "temperatureMeasurement", "temperature")))
            }
        },
        Sensor(capability: "relativeHumidityMeasurement", attribute: "humidity", service: .humiditySensor, characteristic: .currentRelativeHumidity, role: "humidity") {
            $0.number($1, "relativeHumidityMeasurement", "humidity").map { .double(Convert.clamp($0, 0...100)) }
        },
        Sensor(capability: "illuminanceMeasurement", attribute: "illuminance", service: .lightSensor, characteristic: .currentAmbientLightLevel, role: "illuminance") {
            $0.number($1, "illuminanceMeasurement", "illuminance").map { .double(max($0, 0.0001)) }
        },
        Sensor(capability: "contactSensor", attribute: "contact", service: .contactSensor, characteristic: .contactSensorState, role: "contact") {
            $0.string($1, "contactSensor", "contact").map { .int($0 == "closed" ? 0 : 1) }
        },
    ]
}

extension AccessoryBuilder {
    // MARK: Switch, Outlet (7.3.1)

    static let meteringCapabilities = ["powerMeter", "energyMeter", "powerConsumptionReport"]

    mutating func plainSwitch(_ component: String, component info: DeviceComponent) {
        let metered = !info.capabilities.filter(Self.meteringCapabilities.contains).isEmpty
        let isOutlet = options.outlet && metered && component == "main"
        let service: Service
        if device.mainCategory == "Light" {
            service = makeService(.lightbulb, component, "light", kind: "light", category: .lightbulb)
        } else if isOutlet {
            service = makeService(.outlet, component, "outlet", optional: [.outletInUse], kind: "outlet", category: .outlet)
        } else {
            service = makeService(.switch, component, "switch", kind: "switch", category: .switch)
        }
        bindOn(service, component)
        if isOutlet {
            update { status in
                let on = status.string(component, "switch", "switch") == "on"
                let power = status.number(component, "powerMeter", "power")
                service.set(.outletInUse, .bool(power.map { $0 > 0.5 } ?? on))
            }
        }
    }

    /// On ↔ `switch.switch`, written as `switch.on`/`off`; `changesOnly` does not send a write of the state already shown.
    mutating func bindOn(_ service: Service, _ component: String, characteristic: CharacteristicType = .on, changesOnly: Bool = false) {
        let writer = writer
        service.characteristic(characteristic).onWrite(changesOnly: changesOnly) { value in
            let on = characteristic == .active ? value.intValue == 1 : value.boolValue == true
            try await writer.send([DeviceCommand(component, "switch", on ? "on" : "off")], set: [(component, "switch", "switch", .string(on ? "on" : "off"))])
        }
        update { status in
            guard let state = status.string(component, "switch", "switch") else { return }
            service.set(characteristic, characteristic == .active ? .int(state == "on" ? 1 : 0) : .bool(state == "on"))
        }
    }

    // MARK: Lightbulb (7.3.2)

    mutating func light(_ component: String, level: Bool, color: Bool, temperature: Bool) {
        var optional: [CharacteristicType] = []
        if level { optional.append(.brightness) }
        if color { optional += [.hue, .saturation] }
        var extra: [Characteristic] = []
        // Props from colorTemperatureRange (kelvin) when present, else HAP's 140–500 mireds.
        var minMireds = 140.0, maxMireds = 500.0
        if let range = status.value(component, "colorTemperature", "colorTemperatureRange"),
           let low = range["minimum"]?.doubleValue, let high = range["maximum"]?.doubleValue, low > 0, high > low,
           let fewest = Convert.mireds(kelvin: high), let most = Convert.mireds(kelvin: low) {
            minMireds = Double(fewest)
            maxMireds = Double(most)
        }
        if temperature { extra.append(Characteristic(.colorTemperature.with(minValue: minMireds, maxValue: maxMireds))) }
        let service = makeService(.lightbulb, component, "light", optional: optional, extra: extra, kind: "light", category: .lightbulb)
        bindOn(service, component)
        let writer = writer
        let box = box
        if level {
            onSlide(service, .brightness) { value in
                let level = Convert.percent(value.doubleValue) ?? 0
                // setLevel 0 turns a light off: send the off itself (section 7.3.2).
                if level == 0 {
                    try await writer.send([DeviceCommand(component, "switch", "off")], set: [(component, "switch", "switch", "off")])
                } else {
                    try await writer.send([DeviceCommand(component, "switchLevel", "setLevel", [.number(Double(level))])],
                                          set: [(component, "switchLevel", "level", .number(Double(level))), (component, "switch", "switch", "on")])
                }
            }
            update { status in service.set(.brightness, Convert.percent(status.number(component, "switchLevel", "level")).map { .int($0) }) }
        }
        if color {
            // HomeKit writes hue and saturation together: one setColor 100 ms later carries both, each write waiting for it
            // (section 7.3.2).
            let colors = LightChangeBatcher(window: env.timing.seconds(0.1)) { changes in
                let status = box.status
                let stHue = changes.hue.map { ($0 / 3.6).rounded() } ?? status.number(component, "colorControl", "hue") ?? 0
                let stSaturation = changes.saturation.map { $0.rounded() } ?? status.number(component, "colorControl", "saturation") ?? 0
                try await writer.send([DeviceCommand(component, "colorControl", "setColor", [["hue": .number(stHue), "saturation": .number(stSaturation)]])],
                                      set: [(component, "colorControl", "hue", .number(stHue)), (component, "colorControl", "saturation", .number(stSaturation))])
            }
            service.characteristic(.hue).onWrite(changesOnly: true) { value in try await colors.set(.hue(value.doubleValue ?? 0)) }
            service.characteristic(.saturation).onWrite(changesOnly: true) { value in try await colors.set(.saturation(value.doubleValue ?? 0)) }
            update { status in
                service.set(.hue, status.number(component, "colorControl", "hue").map { .double(Convert.clamp(($0 * 3.6).rounded(), 0...360)) })
                service.set(.saturation, status.number(component, "colorControl", "saturation").map { .double(Convert.clamp($0, 0...100)) })
            }
        }
        if temperature {
            let range = minMireds...maxMireds
            onSlide(service, .colorTemperature) { value in
                let mireds = Convert.clamp(value.doubleValue ?? 300, range)
                var kelvin = Convert.kelvin(mireds: mireds) ?? 3000
                if let limits = box.status.value(component, "colorTemperature", "colorTemperatureRange") {
                    if let low = limits["minimum"]?.doubleValue { kelvin = max(kelvin, Int(saturating: low) ?? kelvin) }
                    if let high = limits["maximum"]?.doubleValue { kelvin = min(kelvin, Int(saturating: high) ?? kelvin) }
                }
                try await writer.send([DeviceCommand(component, "colorTemperature", "setColorTemperature", [.number(Double(kelvin))])],
                                      set: [(component, "colorTemperature", "colorTemperature", .number(Double(kelvin)))])
            }
            update { status in
                guard let kelvin = status.number(component, "colorTemperature", "colorTemperature"), let mireds = Convert.mireds(kelvin: kelvin) else { return }
                service.set(.colorTemperature, .int(Int(Convert.clamp(Double(mireds), range))))
            }
        }
        // Adaptive Lighting on a white light with brightness (CLAUDE.md), turned off by a colour or a white set elsewhere.
        if level, temperature, let context, let controller = context.adaptiveLighting(for: service, accessoryID: accessoryID) {
            adaptiveLighting.append(controller)
            eventHooks[StatusBox.key(component, "colorTemperature", "colorTemperature")] = { [weak controller] event, _ in
                guard let kelvin = event.value.doubleValue, let mireds = Convert.mireds(kelvin: kelvin) else { return }
                _ = controller?.disableIfChangedElsewhere(mireds: mireds)
            }
            if color {
                // A colour bulb reports a new hue for a white the bridge just set: that is not a colour set elsewhere.
                let echo = env.timing.timeInterval(10), clock = env.now
                eventHooks[StatusBox.key(component, "colorControl", "hue")] = { [weak controller] _, _ in
                    guard !box.wroteRecently(within: echo, now: clock()) else { return }
                    _ = controller?.disableIfChangedElsewhere(mireds: nil)
                }
            }
        }
    }

    // MARK: Fan (7.3.3)

    enum FanSpeed { case level, percent, steps }

    mutating func fan(_ component: String, speed: FanSpeed) {
        let service = makeService(.fanv2, component, "fan", optional: [.rotationSpeed], kind: "fan", category: .fan)
        bindOn(service, component, characteristic: .active)
        let writer = writer
        onSlide(service, .rotationSpeed) { value in
            let level = Convert.percent(value.doubleValue) ?? 0
            switch speed {
            case .level:
                try await writer.send([DeviceCommand(component, "switchLevel", "setLevel", [.number(Double(level))])], set: [(component, "switchLevel", "level", .number(Double(level)))])
            case .percent:
                try await writer.send([DeviceCommand(component, "fanSpeedPercent", "setPercent", [.number(Double(level))])], set: [(component, "fanSpeedPercent", "percent", .number(Double(level)))])
            case .steps:
                let step = level == 0 ? 0 : level <= 33 ? 1 : level <= 66 ? 2 : 3
                try await writer.send([DeviceCommand(component, "fanSpeed", "setFanSpeed", [.number(Double(step))])], set: [(component, "fanSpeed", "fanSpeed", .number(Double(step)))])
            }
        }
        update { status in
            let value: Int?
            switch speed {
            case .level: value = Convert.percent(status.number(component, "switchLevel", "level"))
            case .percent: value = Convert.percent(status.number(component, "fanSpeedPercent", "percent"))
            case .steps: value = status.number(component, "fanSpeed", "fanSpeed").map { $0 <= 0 ? 0 : $0 < 2 ? 33 : $0 < 3 ? 66 : 100 }
            }
            service.set(.rotationSpeed, value.map { .int($0) })
        }
    }

    // MARK: Valve (7.3.9)

    mutating func valve(_ component: String) {
        let service = makeService(.valve, component, "valve", optional: [.isConfigured], kind: "valve", category: .faucet)
        service.characteristic(.valveType).value = .int(0)
        service.characteristic(.isConfigured).value = .int(1)
        let writer = writer
        service.characteristic(.active).onWrite { value in
            let open = value.intValue == 1
            try await writer.send([DeviceCommand(component, "valve", open ? "open" : "close")], set: [(component, "valve", "valve", .string(open ? "open" : "closed"))])
        }
        update { status in
            guard let state = status.string(component, "valve", "valve") else { return }
            service.set(.active, .int(state == "open" ? 1 : 0))
            service.set(.inUse, .int(state == "open" ? 1 : 0))
        }
    }

    // MARK: Thermostat (7.3.4)

    enum ThermostatVariant { case both, heating, single }

    /// A setpoint range (`value.minimum`, `maximum`, `step`) in °C.
    func setpointRange(_ component: String, _ capability: String, _ attribute: String, unit: String?, fallback: (Double, Double, Double)) -> (Double, Double, Double) {
        guard let range = status.value(component, capability, attribute), let low = range["minimum"]?.doubleValue, let high = range["maximum"]?.doubleValue,
              high > low else { return fallback }
        let rangeUnit = status.unit(component, capability, attribute) ?? unit
        let step = range["step"]?.doubleValue.map { rangeUnit?.uppercased() == "F" ? $0 * 5 / 9 : $0 } ?? fallback.2
        return (Convert.celsius(low, unit: rangeUnit), Convert.celsius(high, unit: rangeUnit), max(step, 0.1))
    }

    static func heatingCoolingState(mode: String) -> Int {
        switch mode.lowercased() {
        case "off": 0
        case "cool": 2
        case "auto": 3
        default: 1
        }
    }

    mutating func thermostat(_ component: String, variant: ThermostatVariant, caps: Swift.Set<String>) {
        let hasMode = caps.contains("thermostatMode")
        let hasOperatingState = caps.contains("thermostatOperatingState")
        let hasSwitch = variant == .single && caps.contains("switch")
        let unitNow = status.unit(component, "temperatureMeasurement", "temperature")
        var valid: [Int]
        if hasMode {
            if let supported = status.strings(component, "thermostatMode", "supportedThermostatModes"), !supported.isEmpty {
                var set = Swift.Set(supported.map(Self.heatingCoolingState))
                if let current = status.string(component, "thermostatMode", "thermostatMode") { set.insert(Self.heatingCoolingState(mode: current)) }
                if variant == .heating { set = set.intersection([0, 1]) }
                valid = set.sorted()
            } else {
                valid = variant == .heating ? [0, 1] : [0, 1, 2, 3]
            }
        } else {
            valid = [1]
        }
        if valid.isEmpty { valid = [1] }
        let allowed = valid
        let (capability, rangeAttribute) = variant == .single
            ? ("temperatureSetpoint", "temperatureSetpointRange")
            : ("thermostatHeatingSetpoint", "heatingSetpointRange")
        let range = setpointRange(component, capability, rangeAttribute, unit: unitNow, fallback: (5, 35, 0.5))
        var optional: [CharacteristicType] = [
            .currentTemperature.with(minValue: -50, maxValue: 100, minStep: 0.1),
            .targetTemperature.with(minValue: range.0, maxValue: range.1, minStep: range.2),
            .targetHeatingCoolingState.with(validValues: valid),
        ]
        if variant == .both {
            let cooling = setpointRange(component, "thermostatCoolingSetpoint", "coolingSetpointRange", unit: unitNow, fallback: (5, 35, 0.5))
            optional += [.heatingThresholdTemperature.with(minValue: range.0, maxValue: range.1, minStep: range.2),
                         .coolingThresholdTemperature.with(minValue: cooling.0, maxValue: cooling.1, minStep: cooling.2)]
        }
        let service = makeService(.thermostat, component, "thermostat", optional: optional, kind: "thermostat", category: .thermostat)
        let writer = writer
        let box = box
        let heatMode = options.heatMode, coolMode = options.coolMode
        @Sendable func unit(_ status: DeviceStatus) -> String? { status.unit(component, "temperatureMeasurement", "temperature") }
        @Sendable func targetState(_ status: DeviceStatus) -> Int {
            if hasSwitch, status.string(component, "switch", "switch") == "off" { return 0 }
            guard hasMode else { return 1 }
            return status.string(component, "thermostatMode", "thermostatMode").map(Self.heatingCoolingState) ?? 1
        }
        service.characteristic(.targetHeatingCoolingState).onWrite { value in
            let target = value.intValue ?? 0
            let mode = switch target { case 0: "off"; case 2: coolMode; case 3: "auto"; default: heatMode }
            if hasSwitch {
                if target == 0 {
                    try await writer.send([DeviceCommand(component, "switch", "off")], set: [(component, "switch", "switch", "off")])
                } else {
                    try await writer.send([DeviceCommand(component, "switch", "on"), DeviceCommand(component, "thermostatMode", "setThermostatMode", [.string(mode)])],
                                          set: [(component, "switch", "switch", "on"), (component, "thermostatMode", "thermostatMode", .string(mode))])
                }
            } else if hasMode {
                try await writer.send([DeviceCommand(component, "thermostatMode", "setThermostatMode", [.string(mode)])],
                                      set: [(component, "thermostatMode", "thermostatMode", .string(mode))])
            }
        }
        @Sendable func setpoint(_ capability: String, _ command: String, _ attribute: String, _ celsius: Double) async throws {
            let value = Convert.deviceTemperature(celsius, unit: box.status.unit(component, capability, attribute) ?? unit(box.status))
            try await writer.send([DeviceCommand(component, capability, command, [value])], set: [(component, capability, attribute, value)])
        }
        onSlide(service, .targetTemperature) { value in
            let celsius = value.doubleValue ?? 20
            switch variant {
            case .single: try await setpoint("temperatureSetpoint", "setTemperatureSetpoint", "temperatureSetpoint", celsius)
            case .heating: try await setpoint("thermostatHeatingSetpoint", "setHeatingSetpoint", "heatingSetpoint", celsius)
            case .both:
                // The setpoint of the mode HomeKit has now, not one cached before a mode change (section 7.3.4).
                let cooling = service.characteristic(.targetHeatingCoolingState).value.intValue == 2
                if cooling {
                    try await setpoint("thermostatCoolingSetpoint", "setCoolingSetpoint", "coolingSetpoint", celsius)
                } else {
                    try await setpoint("thermostatHeatingSetpoint", "setHeatingSetpoint", "heatingSetpoint", celsius)
                }
            }
        }
        if variant == .both {
            onSlide(service, .heatingThresholdTemperature) { value in
                try await setpoint("thermostatHeatingSetpoint", "setHeatingSetpoint", "heatingSetpoint", value.doubleValue ?? 20)
            }
            onSlide(service, .coolingThresholdTemperature) { value in
                try await setpoint("thermostatCoolingSetpoint", "setCoolingSetpoint", "coolingSetpoint", value.doubleValue ?? 24)
            }
        }
        service.characteristic(.temperatureDisplayUnits).onWrite { _ in }
        update { status in
            let temperatureUnit = unit(status)
            func celsius(_ capability: String, _ attribute: String) -> HAPValue? {
                status.number(component, capability, attribute).map { .double(Convert.celsius($0, unit: status.unit(component, capability, attribute) ?? temperatureUnit)) }
            }
            service.set(.currentTemperature, celsius("temperatureMeasurement", "temperature"))
            let target = targetState(status)
            if allowed.contains(target) { service.set(.targetHeatingCoolingState, .int(target)) }
            switch variant {
            case .single: service.set(.targetTemperature, celsius("temperatureSetpoint", "temperatureSetpoint"))
            case .heating: service.set(.targetTemperature, celsius("thermostatHeatingSetpoint", "heatingSetpoint"))
            case .both:
                service.set(.targetTemperature, target == 2 ? celsius("thermostatCoolingSetpoint", "coolingSetpoint") : celsius("thermostatHeatingSetpoint", "heatingSetpoint"))
                service.set(.heatingThresholdTemperature, celsius("thermostatHeatingSetpoint", "heatingSetpoint"))
                service.set(.coolingThresholdTemperature, celsius("thermostatCoolingSetpoint", "coolingSetpoint"))
            }
            var current: Int?
            if hasOperatingState, let state = status.string(component, "thermostatOperatingState", "thermostatOperatingState") {
                switch state {
                case "heating": current = 1
                case "cooling": current = 2
                case "idle", "pending heat", "pending cool": current = 0
                default: current = nil
                }
            }
            if current == nil {
                if target == 0 { current = 0 } else if let mode = status.string(component, "thermostatMode", "thermostatMode") {
                    current = mode == "cool" ? 2 : (mode == "off" || mode == "idle") ? 0 : 1
                } else {
                    current = 1
                }
            }
            if hasSwitch, status.string(component, "switch", "switch") == "off" { current = 0 }
            service.set(.currentHeatingCoolingState, current.map { .int($0) })
            service.set(.temperatureDisplayUnits, .int(temperatureUnit?.uppercased() == "F" ? 1 : 0))
        }
    }

    // MARK: Window covering (7.3.6)

    enum ShadeLevel { case shadeLevel, switchLevel, none }

    mutating func windowCovering(_ component: String, level: ShadeLevel, shade: Bool, caps: Swift.Set<String>) {
        let canPause = status.strings(component, "windowShade", "supportedWindowShadeCommands")?.contains("pause") ?? false
        let tilt = caps.contains("windowShadeTiltLevel")
        var optional: [CharacteristicType] = []
        if canPause, shade { optional.append(.holdPosition) }
        if tilt { optional += [.currentHorizontalTiltAngle, .targetHorizontalTiltAngle] }
        let service = makeService(.windowCovering, component, "windowCovering", optional: optional, kind: "windowCovering", category: .windowCovering)
        let writer = writer
        @Sendable func position(_ status: DeviceStatus) -> Int? {
            switch level {
            case .shadeLevel: return Convert.percent(status.number(component, "windowShadeLevel", "shadeLevel"))
            case .switchLevel: return Convert.percent(status.number(component, "switchLevel", "level"))
            case .none:
                switch status.string(component, "windowShade", "windowShade") {
                case "open": return 100
                case "closed": return 0
                case "partially open": return 50
                default: return nil
                }
            }
        }
        // Every write is sent, even one of the target shown: a repeated open or close goes to the device again.
        onSlide(service, .targetPosition, changesOnly: false) { value in
            var target = Convert.percent(value.doubleValue) ?? 0
            if level == .none { target = target >= 50 ? 100 : 0 }
            if shade, target == 0 || target == 100 {
                let open = target == 100
                try await writer.send([DeviceCommand(component, "windowShade", open ? "open" : "close")],
                                      set: [(component, "windowShade", "windowShade", .string(open ? "opening" : "closing"))])
            } else if level == .shadeLevel {
                try await writer.send([DeviceCommand(component, "windowShadeLevel", "setShadeLevel", [.number(Double(target))])])
            } else {
                try await writer.send([DeviceCommand(component, "switchLevel", "setLevel", [.number(Double(target))])])
            }
        }
        if canPause, shade {
            service.characteristic(.holdPosition).onWrite { value in
                guard value.boolValue == true else { return }
                try await writer.send([DeviceCommand(component, "windowShade", "pause")])
            }
        }
        if tilt {
            onSlide(service, .targetHorizontalTiltAngle) { value in
                let angle = Convert.clamp(value.doubleValue ?? 0, -90...90)
                let tiltLevel = ((angle + 90) / 1.8).rounded()
                try await writer.send([DeviceCommand(component, "windowShadeTiltLevel", "setShadeTiltLevel", [.number(tiltLevel)])],
                                      set: [(component, "windowShadeTiltLevel", "shadeTiltLevel", .number(tiltLevel))])
            }
        }
        update { status in
            let current = position(status)
            service.set(.currentPosition, current.map { .int($0) })
            let state = status.string(component, "windowShade", "windowShade")
            let positionState = state == "opening" ? 1 : state == "closing" ? 0 : 2
            service.set(.positionState, .int(positionState))
            if positionState == 2, let current { service.set(.targetPosition, .int(current)) }
            if tilt, let level = status.number(component, "windowShadeTiltLevel", "shadeTiltLevel") {
                let angle = Int(saturating: Convert.clamp((level * 1.8 - 90).rounded(), -90...90)) ?? 0
                service.set(.currentHorizontalTiltAngle, .int(angle))
                service.set(.targetHorizontalTiltAngle, .int(angle))
            }
        }
    }

    // MARK: Garage door (7.3.5), a security control

    mutating func garageDoor(_ component: String) {
        let service = makeService(.garageDoorOpener, component, "garageDoor", kind: "garageDoor", category: .garageDoorOpener)
        service.characteristic(.obstructionDetected).value = .bool(false)
        let writer = writer
        let hold = Hold(duration: env.timing.timeInterval(20), now: env.now)
        // Target Door State is a security control by default (written only through set_security_accessory).
        service.characteristic(.targetDoorState).securityControl().onWrite { value in
            let open = value.intValue == 0
            hold.start()
            try await writer.send([DeviceCommand(component, "doorControl", open ? "open" : "close")],
                                  set: [(component, "doorControl", "door", .string(open ? "opening" : "closing"))])
        }
        update { status in
            guard let door = status.string(component, "doorControl", "door") else { return }
            let current = switch door { case "open": 0; case "closed": 1; case "opening": 2; case "closing": 3; default: 4 }
            service.set(.currentDoorState, .int(current))
            guard !hold.isHolding else { return }
            if door == "open" || door == "opening" { service.set(.targetDoorState, .int(0)) }
            if door == "closed" || door == "closing" { service.set(.targetDoorState, .int(1)) }
        }
    }

    // MARK: Lock (7.3.7), a security control

    mutating func lock(_ component: String) {
        let service = makeService(.lockMechanism, component, "lock", kind: "lock", category: .doorLock)
        let writer = writer
        let hold = Hold(duration: env.timing.timeInterval(10), now: env.now)
        service.characteristic(.lockTargetState).securityControl().onWrite { value in
            let lock = value.intValue == 1
            hold.start()
            try await writer.send([DeviceCommand(component, "lock", lock ? "lock" : "unlock")])
        }
        update { status in
            guard let state = status.string(component, "lock", "lock") else { return }
            let current = switch state {
            case "locked": 1
            case "unlocked", "unlocked with timeout", "unlatched": 0
            case "not fully locked": 2
            default: 3
            }
            service.set(.lockCurrentState, .int(current))
            guard !hold.isHolding else { return }
            if current == 1 || current == 0 { service.set(.lockTargetState, .int(current)) }
        }
    }

    /// Zigbang's lock (7.3.13): its state in `absoluteweather46907.lockstaterelease`, unlock only.
    mutating func zigbangLock(_ component: String) {
        let service = makeService(.lockMechanism, component, "lock.zigbang", kind: "lock", category: .doorLock)
        let writer = writer
        service.characteristic(.lockTargetState).securityControl().onWrite { value in
            guard value.intValue == 0 else { throw HAPStatusError(.notAllowedInCurrentState) }
            try await writer.send([DeviceCommand(component, "absoluteweather46907.lock", "unlock")])
        }
        update { status in
            guard let raw = status.string(component, "absoluteweather46907.lockstaterelease", "lock") else { return }
            let state = raw.split(separator: ".").first.map(String.init) ?? raw
            let current = state == "locked" ? 1 : state == "unlocked" ? 0 : 3
            service.set(.lockCurrentState, .int(current))
            if current != 3 { service.set(.lockTargetState, .int(current)) }
        }
    }

    // MARK: Sensors (7.3.8)

    mutating func sensor(_ component: String, _ sensor: Sensor) {
        // A capability that never reported a value is left out (section 7.3.8); a rebuild adds it once it does.
        guard status.value(component, sensor.capability, sensor.attribute) != nil else { return }
        let service = makeService(sensor.service, component, sensor.role, optional: [sensor.characteristic], kind: "sensor", category: .sensor)
        let type = sensor.characteristic
        let read = sensor.value
        update { status in service.set(type, read(status, component)) }
    }

    // MARK: Button (7.3.11)

    static func pressKind(_ value: String) -> Int? {
        let text = value.lowercased()
        if text == "pushed" || text == "down" { return HAPConstants.ProgrammableSwitchEvent.singlePress }
        if text == "held" || text.hasSuffix("_hold") { return HAPConstants.ProgrammableSwitchEvent.longPress }
        if text == "double" || text.range(of: #"^(pushed|down|up)_[2-6]x$"#, options: .regularExpression) != nil { return HAPConstants.ProgrammableSwitchEvent.doublePress }
        return nil
    }

    mutating func button(_ component: String, index: Int?) {
        var valid = Swift.Set<Int>([HAPConstants.ProgrammableSwitchEvent.singlePress])
        if let supported = status.strings(component, "button", "supportedButtonValues") {
            valid.formUnion(supported.compactMap(Self.pressKind))
        } else {
            valid.formUnion([1, 2])
        }
        let allowed = valid
        var optional: [CharacteristicType] = [.programmableSwitchEvent.with(validValues: valid.sorted())]
        if index != nil { optional.append(.serviceLabelIndex) }
        let service = makeService(.statelessProgrammableSwitch, component, "button", optional: optional, kind: "button", category: .programmableSwitch)
        if let index { service.characteristic(.serviceLabelIndex).value = .int(index) }
        keptTogether.append(service)
        // A press is an event, even one repeating the last value (section 5.1).
        eventHooks[StatusBox.key(component, "button", "button")] = { event, _ in
            guard let text = event.value.stringValue, let press = Self.pressKind(text), allowed.contains(press) else { return }
            service.characteristic(.programmableSwitchEvent).sendEvent(.int(press))
        }
    }

    // MARK: Battery (7.3.12)

    mutating func battery(_ component: String) {
        let service = makeService(.battery, component, "battery", optional: [.batteryLevel, .statusLowBattery, .chargingState])
        service.characteristic(.chargingState).value = .int(2)
        update { status in
            guard let level = Convert.percent(status.number(component, "battery", "battery")) else { return }
            service.set(.batteryLevel, .int(level))
            service.set(.statusLowBattery, .int(level <= 20 ? 1 : 0))
        }
    }

    // MARK: An air conditioner's display light (7.3.10)

    mutating func displayLight(_ component: String) {
        let service = makeService(.lightbulb, component, "displayLight", name: serviceName(component, "Display Light"))
        let writer = writer
        service.characteristic(.on).onWrite { value in
            let on = value.boolValue == true
            try await writer.send([DeviceCommand(component, "samsungce.airConditionerLighting", on ? "on" : "off")],
                                  set: [(component, "samsungce.airConditionerLighting", "lighting", .string(on ? "on" : "off"))])
        }
        update { status in service.set(.on, status.string(component, "samsungce.airConditionerLighting", "lighting").map { .bool($0 == "on") }) }
    }

    // MARK: Security system (10.1)

    mutating func securitySystem(_ component: String, has capabilities: [String]) {
        let alarms = ["alarm", "panicAlarm", "temperatureAlarm"].filter(capabilities.contains)
        var valid = Swift.Set([HAPConstants.SecuritySystemTargetState.disarm])
        if let commands = status.strings(component, "securitySystem", "supportedSecuritySystemCommands"), !commands.isEmpty {
            for command in commands {
                switch command {
                case "armStay": valid.insert(0)
                case "armAway": valid.insert(1)
                case "armNight": valid.insert(2)
                default: break
                }
            }
        } else {
            valid.formUnion([0, 1])
        }
        let canNight = valid.contains(2)
        var optional: [CharacteristicType] = [.securitySystemTargetState.with(validValues: valid.sorted())]
        if !alarms.isEmpty { optional.append(.securitySystemAlarmType) }
        let service = makeService(.securitySystem, component, "securitySystem", optional: optional, kind: "securitySystem", category: .securitySystem)
        consume(component, ["securitySystem"] + alarms)
        let writer = writer
        let box = box
        @Sendable func settled(_ status: DeviceStatus) -> Int? {
            switch status.string(component, "securitySystem", "securitySystemStatus") {
            case "armedStay": 0
            case "armedAway": 1
            case "armedNight": 2
            case "disarmed": 3
            default: nil
            }
        }
        @Sendable func alarmActive(_ status: DeviceStatus) -> Bool {
            ["siren", "both"].contains(status.string(component, "alarm", "alarm") ?? "") || status.string(component, "panicAlarm", "panicAlarm") == "panic"
                || ["heat", "freeze"].contains(status.string(component, "temperatureAlarm", "temperatureAlarm") ?? "")
        }
        service.characteristic(.securitySystemTargetState).onWrite { value in
            let target = value.intValue ?? 3
            let (command, state, arguments): (String, String, [JSONValue]) = switch target {
            case 0: ("armStay", "armedStay", [false])
            case 1: ("armAway", "armedAway", [false])
            case 2: canNight ? ("armNight", "armedNight", [false]) : ("armStay", "armedStay", [false])
            default: ("disarm", "disarmed", [])
            }
            let previous = settled(box.status) ?? 3
            service.characteristic(.securitySystemCurrentState).value = .int(state == "armedStay" ? 0 : state == "armedAway" ? 1 : state == "armedNight" ? 2 : 3)
            do {
                try await writer.send([DeviceCommand(component, "securitySystem", command, arguments)], set: [(component, "securitySystem", "securitySystemStatus", .string(state))])
            } catch {
                // The last settled state back, and the write fails (section 10.1).
                service.characteristic(.securitySystemCurrentState).value = .int(previous)
                throw error
            }
        }
        update { status in
            let alarm = alarmActive(status)
            if alarm {
                service.set(.securitySystemCurrentState, .int(4))
            } else if let state = settled(status) {
                service.set(.securitySystemCurrentState, .int(state))
                service.set(.securitySystemTargetState, .int(state))
            }
            if !alarms.isEmpty { service.set(.securitySystemAlarmType, .int(alarm ? 1 : 0)) }
        }
    }

    // MARK: Energy (7.3.14)

    mutating func energy() {
        guard let main = device.main, !main.capabilities.filter(Self.meteringCapabilities.contains).isEmpty || main.has("voltageMeasurement") else { return }
        // On the device's Switch, Outlet or Lightbulb of `main`; energy never makes a service of its own.
        guard let host = services.first(where: { $0.subtype?.hasPrefix("main/") == true && [ServiceType.switch, .outlet, .lightbulb].contains($0.type) }) else { return }
        if settings.exposeEnergyMonitoring {
            for type in [EveCharacteristic.currentConsumption, EveCharacteristic.totalConsumption, EveCharacteristic.voltage] where host[type] == nil {
                host.characteristic(adding: type)
            }
            update { status in
                if let watts = Self.power(status) { host.set(EveCharacteristic.currentConsumption, .int(Int(saturating: watts.rounded()) ?? 0)) }
                if let kWh = Self.energyKWh(status) { host.set(EveCharacteristic.totalConsumption, .double(kWh)) }
                if let volts = status.number("main", "voltageMeasurement", "voltage") { host.set(EveCharacteristic.voltage, .double(volts)) }
            }
        }
        // A Homeswift Meter either way: its power and total energy (section 7.3.14).
        guard let context else { return }
        let meter = context.meter(of: host, accessoryID: accessoryID, device: name, suggestedRole: nil)
        meters.append { status in
            if let watts = Self.power(status) { meter.record(watts: max(watts, 0)) }
            if let kWh = Self.energyKWh(status) { meter.record(counter: kWh * 1000) }
        }
    }

    static func power(_ status: DeviceStatus) -> Double? {
        status.number("main", "powerMeter", "power") ?? status.value("main", "powerConsumptionReport", "powerConsumption")?["power"]?.doubleValue
    }

    /// `energyMeter.energy` in kWh (`Wh` and `mWh` converted), else the report's `energy` (Wh).
    static func energyKWh(_ status: DeviceStatus) -> Double? {
        if let energy = status.number("main", "energyMeter", "energy") {
            switch status.unit("main", "energyMeter", "energy")?.lowercased() {
            case "wh": return energy / 1000
            case "mwh": return energy / 1_000_000
            default: return energy
            }
        }
        return status.value("main", "powerConsumptionReport", "powerConsumption")?["energy"]?.doubleValue.map { $0 / 1000 }
    }
}

/// A target held as written for a while after a write, while the device moves (sections 7.3.5, 7.3.7).
final class Hold: Sendable {
    private let until = NIOLockedValueBox<Date?>(nil)
    let duration: TimeInterval
    let now: @Sendable () -> Date

    init(duration: TimeInterval, now: @escaping @Sendable () -> Date) {
        self.duration = duration
        self.now = now
    }

    func start() { until.withLockedValue { $0 = now().addingTimeInterval(duration) } }
    var isHolding: Bool { until.withLockedValue { $0.map { now() < $0 } ?? false } }
}
