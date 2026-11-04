import Foundation
import Homeswift
import HomeswiftNetwork
import HomeswiftPlugin
import NIOConcurrencyHelpers

/// What an entity's handlers need of its device: sending a command, and how long a button stays on.
struct EntityLink: Sendable {
    /// Sends a command; throws No Response when the device is not connected or the write fails.
    var send: @Sendable (ESPHomeFrame) async throws -> Void
    var timing: ESPHomeTiming
}

/// One entity on its accessory: its services, the handlers that turn HomeKit's writes into commands, and `apply`, which
/// shows a state the device pushed. Built once per entity description; a description that changes builds a new one.
final class EntityBinding: Sendable {
    let info: EntityInfo
    let services: [Service]
    let category: AccessoryCategory
    let adaptiveLighting: AdaptiveLightingController?
    private let applyState: @Sendable (ProtobufMessage) -> Void
    /// The body of the last state shown: an identical one is dropped.
    private let lastState = NIOLockedValueBox<ProtobufMessage?>(nil)

    private init(info: EntityInfo, services: [Service], category: AccessoryCategory, adaptiveLighting: AdaptiveLightingController? = nil,
                 apply: @escaping @Sendable (ProtobufMessage) -> Void) {
        self.info = info
        self.services = services
        self.category = category
        self.adaptiveLighting = adaptiveLighting
        self.applyState = apply
    }

    /// Shows a state; false when it was the same as the last one.
    @discardableResult
    func apply(_ state: ProtobufMessage) -> Bool {
        let changed = lastState.withLockedValue { last in
            guard last != state else { return false }
            last = state
            return true
        }
        if changed { applyState(state) }
        return changed
    }

    /// The binding for an entity, or nil when it cannot be mapped (a binary sensor or a sensor of a class HomeKit has no
    /// service for). `adaptiveLighting` makes a light's controller once its lightbulb exists.
    static func make(_ info: EntityInfo, link: EntityLink, adaptiveLighting: (Service) -> AdaptiveLightingController? = { _ in nil }) -> EntityBinding? {
        switch info.kind {
        case .switch: makeSwitch(info, link)
        case .button: makeButton(info, link)
        case .light: makeLight(info, link, adaptiveLighting)
        case .binarySensor: makeBinarySensor(info)
        case .sensor: makeSensor(info)
        case .cover: info.isGarageDoor ? makeGarageDoor(info, link) : makeWindowCovering(info, link)
        case .fan: makeFan(info, link)
        case .climate: makeClimate(info, link)
        case .lock: makeLock(info, link)
        }
    }

    // MARK: Switches and buttons

    private static func makeSwitch(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let service = Service(.switch, name: info.name, isPrimary: true)
        let key = info.key
        service.characteristic(.on).onWrite(changesOnly: true) { value in
            try await link.send(ESPHomeRequest.switch(key: key, on: value.boolValue ?? false))
        }
        return EntityBinding(info: info, services: [service], category: .switch) { state in
            // SwitchStateResponse: state 2, missing_state 4.
            guard !state.bool(4) else { return }
            service.characteristic(.on).value = .bool(state.bool(2))
        }
    }

    /// A button is a switch that presses it and turns back off: HomeKit's programmable switch only reports presses.
    private static func makeButton(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let service = Service(.switch, name: info.name, isPrimary: true)
        let key = info.key
        let on = service.characteristic(.on)
        on.onWrite { value in
            guard value.boolValue == true else { return }
            try await link.send(ESPHomeRequest.button(key: key))
            on.revert(to: .bool(false), after: link.timing.buttonReset)
        }
        return EntityBinding(info: info, services: [service], category: .switch) { _ in }
    }

    // MARK: Lights

    /// What a light's writes add up to before they go: HomeKit writes On, Brightness, Hue and Saturation of one change
    /// one after the other.
    private final class LightWrites: Sendable {
        let pending = NIOLockedValueBox<ESPHomeRequest.Light?>(nil)
        let latest: LatestCallGuard
        /// The mireds the bridge sent last, so its own echo does not turn Adaptive Lighting off.
        let sentMireds = NIOLockedValueBox<Int?>(nil)
        let sentColor = NIOLockedValueBox(false)

        init(delay: Duration) { latest = LatestCallGuard(delay: delay) }
    }

    private static func makeLight(_ info: EntityInfo, _ link: EntityLink, _ makeAdaptiveLighting: (Service) -> AdaptiveLightingController?) -> EntityBinding {
        let key = info.key
        let brightness = info.supportsBrightness || info.supportsRGB
        let rgb = info.supportsRGB
        let temperature = info.supportsColorTemperature
        let range = info.miredsRange
        var optional: [CharacteristicType] = []
        if brightness { optional.append(.brightness) }
        if rgb { optional += [.hue, .saturation] }
        if temperature { optional.append(.colorTemperature.with(minValue: Double(range.lowerBound), maxValue: Double(range.upperBound))) }
        let lightbulb = Service(.lightbulb, name: info.name, optional: optional, isPrimary: true)
        let rgbMode = info.colorModes.first { $0 & ColorMode.rgb != 0 }
        let temperatureMode = info.colorModes.first { $0 & (ColorMode.colorTemperature | ColorMode.coldWarmWhite) != 0 && $0 & ColorMode.rgb == 0 }
            ?? info.colorModes.first { $0 & (ColorMode.colorTemperature | ColorMode.coldWarmWhite) != 0 }
        let writes = LightWrites(delay: link.timing.lightCoalescing)

        /// Adds a write's fields to what is pending, and sends it all when no later write came within the delay.
        @Sendable func write(_ change: (inout ESPHomeRequest.Light) -> Void) async throws {
            writes.pending.withLockedValue { pending in
                var command = pending ?? ESPHomeRequest.Light(key: key)
                change(&command)
                pending = command
            }
            guard await writes.latest() else { return }
            guard let command = writes.pending.withLockedValue({ pending -> ESPHomeRequest.Light? in
                defer { pending = nil }
                return pending
            }) else { return }
            try await link.send(command.frame)
        }

        lightbulb.characteristic(.on).onWrite { value in
            let on = value.boolValue ?? false
            try await write { $0.state = on }
        }
        if brightness {
            lightbulb.characteristic(.brightness).onWrite { value in
                let level = min(max(value.doubleValue ?? 0, 0), 100)
                try await write {
                    $0.brightness = Float(level / 100)
                    if $0.state == nil { $0.state = level > 0 }
                }
            }
        }
        if rgb {
            @Sendable func sendColor(hue: Double, saturation: Double) async throws {
                let color = Color.rgb(hue: hue, saturation: saturation)
                writes.sentColor.withLockedValue { $0 = true }
                try await write {
                    $0.rgb = (Float(color.red), Float(color.green), Float(color.blue))
                    $0.colorMode = rgbMode
                }
            }
            lightbulb.characteristic(.hue).onWrite { value in
                try await sendColor(hue: value.doubleValue ?? 0, saturation: lightbulb.characteristic(.saturation).value.doubleValue ?? 0)
            }
            lightbulb.characteristic(.saturation).onWrite { value in
                try await sendColor(hue: lightbulb.characteristic(.hue).value.doubleValue ?? 0, saturation: value.doubleValue ?? 0)
            }
        }
        var effectSwitches: [(name: String, service: Service)] = []
        let effects = info.effects
        for effect in effects where effect != "None" && !effect.isEmpty {
            let service = Service(.switch, name: "\(info.name) - \(effect)", subtype: "\(effect) Switch")
            effectSwitches.append((effect, service))
        }
        let switches = effectSwitches
        for (effect, service) in switches {
            service.characteristic(.on).onWrite { value in
                if value.boolValue == true {
                    try await write {
                        $0.state = true
                        $0.effect = effect
                    }
                } else if effects.contains("None") {
                    try await write { $0.effect = "None" }
                } else {
                    return
                }
                // A radio group: one effect at a time.
                for other in switches where other.name != effect { other.service.characteristic(.on).value = .bool(false) }
            }
        }
        var adaptiveLighting: AdaptiveLightingController?
        if temperature {
            lightbulb.characteristic(.colorTemperature).onWrite { value in
                let mireds = Int(saturating: value.doubleValue ?? Double(range.lowerBound), in: range) ?? range.lowerBound
                writes.sentMireds.withLockedValue { $0 = mireds }
                writes.sentColor.withLockedValue { $0 = false }
                try await write {
                    $0.colorTemperature = Float(mireds)
                    $0.colorMode = temperatureMode
                }
            }
            if brightness { adaptiveLighting = makeAdaptiveLighting(lightbulb) }
        }
        let controller = adaptiveLighting
        return EntityBinding(info: info, services: [lightbulb] + switches.map(\.service), category: .lightbulb, adaptiveLighting: controller) { state in
            // LightStateResponse: state 2, brightness 3, red 4, green 5, blue 6, color_temperature 8, effect 9, color_mode 11.
            lightbulb.characteristic(.on).value = .bool(state.bool(2))
            if brightness, state.has(3) {
                lightbulb.characteristic(.brightness).value = .int(Int(saturating: (Double(state.float(3)) * 100).rounded(), in: 0...100) ?? 0)
            }
            let mode = state.enumeration(11)
            let showsColor = rgb && (mode & ColorMode.rgb != 0 || (mode == 0 && (state.has(4) || state.has(5) || state.has(6))))
            if showsColor {
                let (hue, saturation) = Color.hueSaturation(red: Double(state.float(4)), green: Double(state.float(5)), blue: Double(state.float(6)))
                lightbulb.characteristic(.hue).value = .int(Int(saturating: hue.rounded(), in: 0...360) ?? 0)
                lightbulb.characteristic(.saturation).value = .int(Int(saturating: saturation.rounded(), in: 0...100) ?? 0)
                let ours = writes.sentColor.withLockedValue { sent in defer { sent = false }; return sent }
                if !ours { _ = controller?.disableIfChangedElsewhere(mireds: nil) }
            } else if temperature, state.has(8) {
                let mireds = Int(saturating: Double(state.float(8)).rounded(), in: range) ?? range.lowerBound
                // Before the value moves: the controller compares the report with what is shown.
                let sent = writes.sentMireds.withLockedValue { $0 }
                if sent.map({ abs($0 - mireds) > 1 }) ?? true { _ = controller?.disableIfChangedElsewhere(mireds: mireds) }
                lightbulb.characteristic(.colorTemperature).value = .int(mireds)
            }
            let effect = state.string(9)
            for (name, service) in switches { service.characteristic(.on).value = .bool(effect == name) }
        }
    }

    // MARK: Sensors

    private static func makeBinarySensor(_ info: EntityInfo) -> EntityBinding? {
        let service: Service
        let show: @Sendable (Bool) -> HAPValue
        let characteristic: CharacteristicType
        switch info.deviceClass {
        case "motion", "occupancy", "presence":
            service = Service(.motionSensor, name: info.name, isPrimary: true)
            characteristic = .motionDetected
            show = { .bool($0) }
        case "door", "window", "opening", "garage_door":
            service = Service(.contactSensor, name: info.name, isPrimary: true)
            characteristic = .contactSensorState
            show = { .int($0 ? 1 : 0) }
        case "smoke":
            service = Service(.smokeSensor, name: info.name, isPrimary: true)
            characteristic = .smokeDetected
            show = { .int($0 ? 1 : 0) }
        case "moisture":
            service = Service(.leakSensor, name: info.name, isPrimary: true)
            characteristic = .leakDetected
            show = { .int($0 ? 1 : 0) }
        default:
            return nil
        }
        service.characteristic(characteristic).value = show(false)
        return EntityBinding(info: info, services: [service], category: .sensor) { state in
            // BinarySensorStateResponse: state 2, missing_state 3.
            guard !state.bool(3) else { return }
            service.characteristic(characteristic).value = show(state.bool(2))
        }
    }

    private static func makeSensor(_ info: EntityInfo) -> EntityBinding? {
        let service: Service
        let characteristic: CharacteristicType
        let convert: @Sendable (Double) -> Double
        let unit = info.unit
        if unit == "°C" || unit == "°F" {
            service = Service(.temperatureSensor, name: info.name, isPrimary: true)
            characteristic = .currentTemperature
            if unit == "°F" { convert = { ($0 - 32) * 5 / 9 } } else { convert = { $0 } }
        } else if unit == "%", info.icon == "mdi:water-percent" || info.deviceClass == "humidity" {
            service = Service(.humiditySensor, name: info.name, isPrimary: true)
            characteristic = .currentRelativeHumidity
            convert = { min(max($0, 0), 100) }
        } else if unit == "lx" || info.deviceClass == "illuminance" {
            service = Service(.lightSensor, name: info.name, isPrimary: true)
            characteristic = .currentAmbientLightLevel
            convert = { min(max($0, 0.0001), 100_000) }
        } else {
            return nil
        }
        return EntityBinding(info: info, services: [service], category: .sensor) { state in
            // SensorStateResponse: state 2 (NaN without a valid state), missing_state 3.
            let value = Double(state.float(2))
            guard !state.bool(3), value.isFinite else { return }
            service.characteristic(characteristic).value = .double((convert(value) * 100).rounded() / 100)
        }
    }

    // MARK: Covers

    private static func makeWindowCovering(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        var optional: [CharacteristicType] = []
        if info.supportsStop { optional.append(.holdPosition) }
        if info.supportsTilt { optional += [.currentHorizontalTiltAngle, .targetHorizontalTiltAngle] }
        let service = Service(.windowCovering, name: info.name, optional: optional, isPrimary: true)
        let key = info.key
        let supportsPosition = info.supportsPosition
        let latest = LatestCallGuard(delay: link.timing.lightCoalescing)
        service.characteristic(.positionState).value = .int(2)
        service.characteristic(.targetPosition).onWrite { value in
            let target = min(max(value.doubleValue ?? 0, 0), 100)
            guard await latest("position") else { return }
            let position: Float = supportsPosition ? Float(target / 100) : (target >= 50 ? 1 : 0)
            try await link.send(ESPHomeRequest.Cover(key: key, position: position).frame)
        }
        if info.supportsStop {
            service.characteristic(.holdPosition).onWrite { value in
                guard value.boolValue == true else { return }
                try await link.send(ESPHomeRequest.Cover(key: key, stop: true).frame)
            }
        }
        if info.supportsTilt {
            service.characteristic(.targetHorizontalTiltAngle).onWrite { value in
                let angle = min(max(value.doubleValue ?? 0, -90), 90)
                guard await latest("tilt") else { return }
                try await link.send(ESPHomeRequest.Cover(key: key, tilt: Float((angle + 90) / 180)).frame)
            }
        }
        let tilt = info.supportsTilt
        return EntityBinding(info: info, services: [service], category: .windowCovering) { state in
            // CoverStateResponse: position 3, tilt 4, current_operation 5.
            let position = Int(saturating: (Double(state.float(3)) * 100).rounded(), in: 0...100) ?? 0
            service.characteristic(.currentPosition).value = .int(position)
            switch state.enumeration(5) {
            case 1: service.characteristic(.positionState).value = .int(1)
            case 2: service.characteristic(.positionState).value = .int(0)
            default:
                service.characteristic(.positionState).value = .int(2)
                service.characteristic(.targetPosition).value = .int(position)
            }
            if tilt {
                let angle = Int(saturating: (Double(state.float(4)) * 180 - 90).rounded(), in: -90...90) ?? 0
                service.characteristic(.currentHorizontalTiltAngle).value = .int(angle)
                if state.enumeration(5) == 0 { service.characteristic(.targetHorizontalTiltAngle).value = .int(angle) }
            }
        }
    }

    private static func makeGarageDoor(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let service = Service(.garageDoorOpener, name: info.name, isPrimary: true)
        let key = info.key
        service.characteristic(.obstructionDetected).value = .bool(false)
        service.characteristic(.targetDoorState).onWrite { value in
            // 0 open, 1 closed.
            let open = (value.intValue ?? 1) == 0
            try await link.send(ESPHomeRequest.Cover(key: key, position: open ? 1 : 0).frame)
        }
        return EntityBinding(info: info, services: [service], category: .garageDoorOpener) { state in
            let position = state.float(3)
            let current: Int
            let target: Int
            switch state.enumeration(5) {
            case 1: (current, target) = (2, 0)
            case 2: (current, target) = (3, 1)
            default:
                if position >= 1 { (current, target) = (0, 0) } else if position <= 0 { (current, target) = (1, 1) } else { (current, target) = (4, 0) }
            }
            service.characteristic(.currentDoorState).value = .int(current)
            service.characteristic(.targetDoorState).value = .int(target)
        }
    }

    // MARK: Fans

    private static func makeFan(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let count = max(info.speedCount, 1)
        var optional: [CharacteristicType] = []
        if info.supportsSpeed { optional.append(.rotationSpeed.with(minValue: 0, maxValue: 100, minStep: 100 / Double(count))) }
        if info.supportsOscillation { optional.append(.swingMode) }
        if info.supportsDirection { optional.append(.rotationDirection) }
        let service = Service(.fanv2, name: info.name, optional: optional, isPrimary: true)
        let key = info.key
        let latest = LatestCallGuard(delay: link.timing.lightCoalescing)
        service.characteristic(.active).onWrite(changesOnly: true) { value in
            try await link.send(ESPHomeRequest.Fan(key: key, state: (value.intValue ?? 0) == 1).frame)
        }
        if info.supportsSpeed {
            service.characteristic(.rotationSpeed).onWrite { value in
                let speed = min(max(value.doubleValue ?? 0, 0), 100)
                guard await latest("speed") else { return }
                let level = Int((speed / 100 * Double(count)).rounded(.up))
                let command = level == 0 ? ESPHomeRequest.Fan(key: key, state: false) : ESPHomeRequest.Fan(key: key, state: true, speedLevel: level)
                try await link.send(command.frame)
            }
        }
        if info.supportsOscillation {
            service.characteristic(.swingMode).onWrite { value in
                try await link.send(ESPHomeRequest.Fan(key: key, oscillating: (value.intValue ?? 0) == 1).frame)
            }
        }
        if info.supportsDirection {
            service.characteristic(.rotationDirection).onWrite { value in
                try await link.send(ESPHomeRequest.Fan(key: key, direction: (value.intValue ?? 0) == 1 ? 1 : 0).frame)
            }
        }
        let speed = info.supportsSpeed, oscillation = info.supportsOscillation, direction = info.supportsDirection
        return EntityBinding(info: info, services: [service], category: .fan) { state in
            // FanStateResponse: state 2, oscillating 3, direction 5, speed_level 6.
            service.characteristic(.active).value = .int(state.bool(2) ? 1 : 0)
            if speed, state.bool(2) {
                service.characteristic(.rotationSpeed).value = .double(min(Double(state.int32(6)) / Double(count) * 100, 100))
            }
            if oscillation { service.characteristic(.swingMode).value = .int(state.bool(3) ? 1 : 0) }
            if direction { service.characteristic(.rotationDirection).value = .int(state.enumeration(5) == 1 ? 1 : 0) }
        }
    }

    // MARK: Climates

    private static func makeClimate(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let features = info.climateFeatures
        let unit = info.temperatureUnit
        let twoPoint = features & (ClimateFeature.twoPoint | ClimateFeature.requiresTwoPoint) != 0
        let requiresTwoPoint = features & ClimateFeature.requiresTwoPoint != 0
        let modes = Set(info.climateModes)
        let mapping = ClimateModes(supported: modes)
        let low = Temperature.celsius(info.visualMinTemperature, unit: unit), high = Temperature.celsius(info.visualMaxTemperature, unit: unit)
        let bounds = low < high && low.isFinite && high.isFinite ? (low, high) : (10.0, 38.0)
        let step = info.visualTemperatureStep > 0 ? Temperature.step(info.visualTemperatureStep, unit: unit) : 0.5
        var optional: [CharacteristicType] = [
            .targetTemperature.with(minValue: bounds.0, maxValue: bounds.1, minStep: step),
            .targetHeatingCoolingState.with(validValues: mapping.validValues),
            .currentTemperature.with(minValue: -100, maxValue: 200),
        ]
        if twoPoint {
            optional += [
                .coolingThresholdTemperature.with(minValue: bounds.0, maxValue: bounds.1, minStep: step),
                .heatingThresholdTemperature.with(minValue: bounds.0, maxValue: bounds.1, minStep: step),
            ]
        }
        if features & ClimateFeature.currentHumidity != 0 { optional.append(.currentRelativeHumidity) }
        if features & ClimateFeature.targetHumidity != 0 { optional.append(.targetRelativeHumidity) }
        let service = Service(.thermostat, name: info.name, optional: optional, isPrimary: true)
        service.characteristic(.temperatureDisplayUnits).value = .int(unit == 1 ? 1 : 0)
        service.characteristic(.temperatureDisplayUnits).onWrite { _ in }
        let key = info.key
        let latest = LatestCallGuard(delay: link.timing.lightCoalescing)
        service.characteristic(.targetHeatingCoolingState).onWrite { value in
            guard let mode = mapping.esphome(value.intValue ?? 0) else { throw HAPStatusError(.invalidValueInRequest) }
            try await link.send(ESPHomeRequest.Climate(key: key, mode: mode).frame)
        }
        service.characteristic(.targetTemperature).onWrite { value in
            let celsius = value.doubleValue ?? 20
            guard await latest("target") else { return }
            let device = Float(Temperature.device(celsius, unit: unit))
            var command = ESPHomeRequest.Climate(key: key)
            if requiresTwoPoint {
                if service.characteristic(.targetHeatingCoolingState).value.intValue == 2 { command.targetHigh = device } else { command.targetLow = device }
            } else {
                command.targetTemperature = device
            }
            try await link.send(command.frame)
        }
        if twoPoint {
            service.characteristic(.heatingThresholdTemperature).onWrite { value in
                guard await latest("low") else { return }
                try await link.send(ESPHomeRequest.Climate(key: key, targetLow: Float(Temperature.device(value.doubleValue ?? 20, unit: unit))).frame)
            }
            service.characteristic(.coolingThresholdTemperature).onWrite { value in
                guard await latest("high") else { return }
                try await link.send(ESPHomeRequest.Climate(key: key, targetHigh: Float(Temperature.device(value.doubleValue ?? 24, unit: unit))).frame)
            }
        }
        if features & ClimateFeature.targetHumidity != 0 {
            service.characteristic(.targetRelativeHumidity).onWrite { value in
                guard await latest("humidity") else { return }
                try await link.send(ESPHomeRequest.Climate(key: key, targetHumidity: Float(value.doubleValue ?? 50)).frame)
            }
        }
        @Sendable func clamp(_ value: Double) -> Double { min(max(value, bounds.0), bounds.1) }
        return EntityBinding(info: info, services: [service], category: .thermostat) { state in
            // ClimateStateResponse: mode 2, current 3, target 4, low 5, high 6, action 8, humidity 14 and 15, missing_state 17.
            guard !state.bool(17) else { return }
            let mode = state.enumeration(2)
            if let target = mapping.homeKit(mode) { service.characteristic(.targetHeatingCoolingState).value = .int(target) }
            if features & ClimateFeature.action != 0 {
                let current = switch state.enumeration(8) {
                case 3: 1
                case 2: 2
                default: 0
                }
                service.characteristic(.currentHeatingCoolingState).value = .int(current)
            } else {
                service.characteristic(.currentHeatingCoolingState).value = .int(mode == 3 ? 1 : mode == 2 ? 2 : 0)
            }
            func celsius(_ field: Int) -> Double? {
                let value = Temperature.celsius(state.float(field), unit: unit)
                return value.isFinite ? (value * 10).rounded() / 10 : nil
            }
            if features & ClimateFeature.currentTemperature != 0, let current = celsius(3) {
                service.characteristic(.currentTemperature).value = .double(current)
            }
            if twoPoint {
                if let low = celsius(5) { service.characteristic(.heatingThresholdTemperature).value = .double(clamp(low)) }
                if let high = celsius(6) { service.characteristic(.coolingThresholdTemperature).value = .double(clamp(high)) }
            }
            if !requiresTwoPoint, let target = celsius(4) {
                service.characteristic(.targetTemperature).value = .double(clamp(target))
            } else if requiresTwoPoint, let target = celsius(mode == 2 ? 6 : 5) {
                service.characteristic(.targetTemperature).value = .double(clamp(target))
            }
            if features & ClimateFeature.currentHumidity != 0, state.float(14).isFinite {
                service.characteristic(.currentRelativeHumidity).value = .double(min(max(Double(state.float(14)), 0), 100))
            }
            if features & ClimateFeature.targetHumidity != 0, state.float(15).isFinite {
                service.characteristic(.targetRelativeHumidity).value = .double(min(max(Double(state.float(15)), 0), 100))
            }
        }
    }

    // MARK: Locks

    private static func makeLock(_ info: EntityInfo, _ link: EntityLink) -> EntityBinding {
        let service = Service(.lockMechanism, name: info.name, isPrimary: true)
        let key = info.key
        // Lock Target State is a security control: the bridge's own surfaces write it only once a person confirmed.
        service.characteristic(.lockTargetState).onWrite { value in
            try await link.send(ESPHomeRequest.lock(key: key, lock: (value.intValue ?? 1) == 1))
        }
        service.characteristic(.lockCurrentState).value = .int(3)
        return EntityBinding(info: info, services: [service], category: .doorLock) { state in
            // LockStateResponse: state 2 (0 none, 1 locked, 2 unlocked, 3 jammed, 4 locking, 5 unlocking, 6 opening, 7 open).
            let current = service.characteristic(.lockCurrentState)
            let target = service.characteristic(.lockTargetState)
            switch state.enumeration(2) {
            case 1: (current.value, target.value) = (.int(1), .int(1))
            case 2, 6, 7: (current.value, target.value) = (.int(0), .int(0))
            case 3: current.value = .int(2)
            case 4: target.value = .int(1)
            case 5: target.value = .int(0)
            default: current.value = .int(3)
            }
        }
    }
}

extension EntityInfo {
    /// A cover HomeKit shows as a garage door.
    var isGarageDoor: Bool { kind == .cover && ["garage", "gate", "door"].contains(deviceClass) }

    /// The light's color temperature range in mireds, within HomeKit's 140 to 500.
    var miredsRange: ClosedRange<Int> {
        let low = Int(saturating: Double(minMireds).rounded()).map { max($0, 140) } ?? 140
        let high = Int(saturating: Double(maxMireds).rounded()).map { min($0, 500) } ?? 500
        return low < high ? low...high : 140...500
    }
}

/// HomeKit's Target Heating Cooling State against ESPHome's climate modes: Off 0 ↔ OFF 0, Heat 1 ↔ HEAT 3, Cool 2 ↔
/// COOL 2, Auto 3 ↔ HEAT_COOL 1, or AUTO 6 when only that is supported.
struct ClimateModes: Sendable {
    let supported: Set<Int>

    var autoMode: Int? {
        if supported.isEmpty || supported.contains(1) { return 1 }
        return supported.contains(6) ? 6 : nil
    }

    func esphome(_ homeKit: Int) -> Int? {
        let mode: Int? = switch homeKit {
        case 0: 0
        case 1: 3
        case 2: 2
        case 3: autoMode
        default: nil
        }
        guard let mode, supported.isEmpty || supported.contains(mode) || mode == 0 else { return nil }
        return mode
    }

    func homeKit(_ esphome: Int) -> Int? {
        switch esphome {
        case 0: 0
        case 3: 1
        case 2: 2
        case 1, 6: 3
        default: nil
        }
    }

    var validValues: [Int] { (0...3).filter { esphome($0) != nil } }
}

/// Temperatures from a climate's unit (0 °C, 1 °F, 2 K) to HomeKit's Celsius and back.
enum Temperature {
    static func celsius(_ value: Float, unit: Int) -> Double {
        let value = Double(value)
        return switch unit {
        case 1: (value - 32) * 5 / 9
        case 2: value - 273.15
        default: value
        }
    }

    static func device(_ celsius: Double, unit: Int) -> Double {
        switch unit {
        case 1: celsius * 9 / 5 + 32
        case 2: celsius + 273.15
        default: celsius
        }
    }

    static func step(_ step: Float, unit: Int) -> Double {
        unit == 1 ? max(Double(step) * 5 / 9, 0.1) : Double(step)
    }
}

/// Hue and saturation against RGB channels (0…1), at full value.
enum Color {
    static func hueSaturation(red: Double, green: Double, blue: Double) -> (hue: Double, saturation: Double) {
        let maximum = max(red, green, blue), minimum = min(red, green, blue)
        let delta = maximum - minimum
        guard maximum > 0, delta > 0 else { return (0, 0) }
        var hue: Double
        if maximum == red {
            hue = (green - blue) / delta
        } else if maximum == green {
            hue = (blue - red) / delta + 2
        } else {
            hue = (red - green) / delta + 4
        }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, delta / maximum * 100)
    }

    static func rgb(hue: Double, saturation: Double) -> (red: Double, green: Double, blue: Double) {
        let s = min(max(saturation, 0), 100) / 100
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let chroma = s
        let x = chroma * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = 1 - chroma
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (chroma, x, 0)
        case 1: (x, chroma, 0)
        case 2: (0, chroma, x)
        case 3: (0, x, chroma)
        case 4: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return (min(max(r + m, 0), 1), min(max(g + m, 0), 1), min(max(b + m, 0), 1))
    }
}
