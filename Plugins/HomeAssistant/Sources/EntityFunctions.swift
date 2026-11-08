import Foundation
import Homeswift
import HomeswiftPlugin

/// A Home Assistant service call (2.6): `call_service` with `target.entity_id`.
struct ServiceCall: Sendable, Equatable {
    var domain: String
    var service: String
    var data: [String: JSONValue]
    /// nil for a script's own service, which takes no target (7.3).
    var entityID: String?
}

/// What an entity's Function needs from the plugin: the call, its timings, and the server's units.
struct EntityLink: Sendable {
    let entityID: String
    let send: @Sendable (ServiceCall) async throws -> Void
    /// Writes of one service gathered into one call (section 6: 10 ms).
    let batchWindow: Duration
    /// A momentary switch's On goes back to false after this (7.3).
    let momentaryReset: Duration
    /// The climate domain's temperatures are in °F (7.6).
    let fahrenheit: Bool
    let lockCode: String?
    let alarmCode: String?

    /// Calls a service on this entity; a refused or failed call is HomeKit's Service Communication Failure (section 6).
    func call(_ domain: String, _ service: String, _ data: [String: JSONValue] = [:]) async throws {
        try await deliver(ServiceCall(domain: domain, service: service, data: data, entityID: entityID))
    }

    /// Sends a call as it is (a script's own service); a refused or failed call is HomeKit's Service Communication Failure.
    func deliver(_ call: ServiceCall) async throws {
        do { try await send(call) } catch { throw communicationFailure(error) }
    }
}

/// One HAP service (and its linked ones) standing for one entity: built from the entity's state, given its later states.
class EntityFunction: @unchecked Sendable {
    let entityID: String
    let service: Service
    /// Linked services shown with it (a fan's presets).
    var extraServices: [Service] { [] }
    var services: [Service] { [service] + extraServices }

    init(entityID: String, service: Service) {
        self.entityID = entityID
        self.service = service
    }

    /// Shows a state of the entity; `unknown` and `unavailable` never reach it (4.5).
    func update(_ state: EntityState) {}

    /// The accessory category this Function suggests.
    var category: AccessoryCategory { .other }
}

/// Characteristic writes gathered for `window` and handed over in arrival order (section 6); each write waits for the call
/// that carries it, so its error reaches HomeKit. Lights gather theirs with the shared `LightChangeBatcher`.
actor WriteBatch {
    private let window: Duration
    private let commit: @Sendable ([(String, HAPValue)]) async throws -> Void
    private var entries: [(String, HAPValue)] = []
    private var batch: Task<Void, any Error>?

    init(window: Duration, commit: @escaping @Sendable ([(String, HAPValue)]) async throws -> Void) {
        self.window = window
        self.commit = commit
    }

    func set(_ key: String, _ value: HAPValue) async throws {
        entries.append((key, value))
        let task: Task<Void, any Error>
        if let batch {
            task = batch
        } else {
            let window = self.window
            task = Task {
                try await Task.sleep(for: window)
                try await self.flush()
            }
            batch = task
        }
        try await task.value
    }

    private func flush() async throws {
        let taken = entries
        entries = []
        batch = nil
        guard !taken.isEmpty else { return }
        try await commit(taken)
    }
}

extension Characteristic {
    /// Sets the value when it fits the characteristic's bounds; nothing otherwise.
    func show(_ value: HAPValue) {
        if self.value != value { self.value = value }
    }
}

/// A service call that failed, as HomeKit's error.
func communicationFailure(_ error: any Error) -> HAPStatusError {
    if let status = error as? HAPStatusError { return status }
    return HAPStatusError(.serviceCommunicationFailure, reason: "Home Assistant: \(error)")
}

/// Clamps to a characteristic type's bounds.
func clamp(_ value: Double, _ type: CharacteristicType) -> Double {
    var value = value
    if let minimum = type.minValue { value = max(minimum, value) }
    if let maximum = type.maxValue { value = min(maximum, value) }
    return value
}

// MARK: - 7.1 light → Lightbulb

final class LightFunction: EntityFunction, @unchecked Sendable {
    static let colorModes: Set<String> = ["hs", "xy", "rgb", "rgbw", "rgbww"]

    let hasBrightness: Bool
    let hasColor: Bool
    /// `color_temp` is supported: Color Temperature writes `color_temp_kelvin`.
    let hasColorTemperature: Bool
    /// A fixed white (rgbw or white without `color_temp`): Color Temperature min = max, written as rgbw or white.
    let fixedWhite: String?
    let mireds: ClosedRange<Int>
    /// The writes of one change, gathered into one call (section 6); when it last sent, a colour report right after is its
    /// echo, not a change made elsewhere.
    private let writer: LightChangeBatcher
    private(set) weak var adaptiveLighting: AdaptiveLightingController?

    override var category: AccessoryCategory { .lightbulb }

    static func shape(_ state: EntityState) -> String {
        let modes = state.strings("supported_color_modes").sorted().joined(separator: ",")
        return "\(modes)|\(state.double("min_color_temp_kelvin") ?? 0)|\(state.double("max_color_temp_kelvin") ?? 0)"
    }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        var modes = Set(state.strings("supported_color_modes"))
        if modes.isEmpty, state.attributes["brightness"] != nil { modes = ["brightness"] }
        hasBrightness = !modes.subtracting(["onoff", "unknown"]).isEmpty
        hasColor = !modes.intersection(Self.colorModes).isEmpty
        hasColorTemperature = modes.contains("color_temp")
        fixedWhite = hasColorTemperature ? nil : modes.contains("rgbw") ? "rgbw" : modes.contains("white") ? "white" : nil
        // Kelvin bounds to mireds (vectors: absent → 153…500), swapped when reversed.
        var low = Int((1_000_000 / (state.double("max_color_temp_kelvin") ?? 6500)).rounded(.down))
        var high = Int((1_000_000 / (state.double("min_color_temp_kelvin") ?? 2000)).rounded(.down))
        if low > high { swap(&low, &high) }
        if fixedWhite != nil { high = low }
        mireds = low...high
        var optional: [CharacteristicType] = []
        if hasBrightness { optional.append(.brightness) }
        if hasColor { optional += [.hue, .saturation] }
        if hasColorTemperature || fixedWhite != nil {
            optional.append(.colorTemperature.with(minValue: Double(mireds.lowerBound), maxValue: Double(mireds.upperBound)))
        }
        let service = Service(.lightbulb, name: state.friendlyName, subtype: key, optional: optional, isPrimary: isPrimary)
        let (hasColorTemperature, fixedWhite) = (hasColorTemperature, fixedWhite)
        let writer = LightChangeBatcher(window: link.batchWindow) { [weak service] changes in
            guard let service else { return }
            try await Self.commit(changes, link: link, service: service, hasColorTemperature: hasColorTemperature, fixedWhite: fixedWhite)
        }
        self.writer = writer
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.on).onWrite { value in
            guard let on = value.boolValue else { return }
            try await writer.set(.on(on))
        }
        service[.brightness]?.onWrite { value in
            guard let level = value.intValue ?? value.doubleValue.flatMap({ Int(saturating: $0) }) else { return }
            try await writer.set(.brightness(Double(level)))
        }
        service[.hue]?.onWrite { value in
            guard let hue = value.doubleValue else { return }
            try await writer.set(.hue(hue))
        }
        service[.saturation]?.onWrite { value in
            guard let saturation = value.doubleValue else { return }
            try await writer.set(.saturation(saturation))
        }
        service[.colorTemperature]?.onWrite { value in
            guard let mired = value.intValue else { return }
            try await writer.set(.mirek(mired))
        }
    }

    var canHaveAdaptiveLighting: Bool { hasBrightness && hasColorTemperature }

    func attach(_ controller: AdaptiveLightingController?) { adaptiveLighting = controller }

    override func update(_ state: EntityState) {
        let on = state.state == "on"
        service.characteristic(.on).show(.bool(on))
        if let brightness = state.double("brightness"), let characteristic = service[.brightness] {
            var percent = Int(saturating: (brightness / 255 * 100).rounded()) ?? 0
            if on, percent == 0 { percent = 1 }
            characteristic.show(.int(min(100, max(0, percent))))
        }
        let mode = state.string("color_mode")
        if let hue = service[.hue], let saturation = service[.saturation] {
            if let kelvin = state.double("color_temp_kelvin"), kelvin > 0 {
                let (h, s) = ColorUtils.colorTemperatureToHueAndSaturation(1_000_000 / kelvin)
                hue.show(.double(h))
                saturation.show(.double(s))
            } else if mode == "white" {
                hue.show(.double(0))
                saturation.show(.double(0))
            } else if let hs = state.attributes["hs_color"]?.arrayValue, hs.count == 2, let h = hs[0].doubleValue, let s = hs[1].doubleValue {
                hue.show(.double(min(360, max(0, h.rounded()))))
                saturation.show(.double(min(100, max(0, s.rounded()))))
            }
        }
        if let characteristic = service[.colorTemperature] {
            if mode == "white" || fixedWhite != nil {
                characteristic.show(.int(mireds.lowerBound))
            } else if hasColorTemperature, let kelvin = state.double("color_temp_kelvin"), kelvin > 0 {
                let value = Int((1_000_000 / kelvin).rounded(.down))
                characteristic.show(.int(min(mireds.upperBound, max(mireds.lowerBound, value))))
            }
        }
        // A colour or white set elsewhere (HA's own UI, a remote) ends Adaptive Lighting; this bridge's echo does not.
        if let adaptiveLighting, on {
            let changed: Int??
            if let mode, Self.colorModes.contains(mode) {
                changed = .some(nil)
            } else if mode == "color_temp", let kelvin = state.double("color_temp_kelvin"), kelvin > 0 {
                changed = Int((1_000_000 / kelvin).rounded(.down))
            } else {
                changed = nil
            }
            if let changed {
                let writer = writer
                Task {
                    guard await !writer.isSettling(within: .seconds(2)) else { return }
                    adaptiveLighting.disableIfChangedElsewhere(mireds: changed)
                }
            }
        }
    }

    /// One call per batch (7.1): off, or `turn_on` with what was written; a colour and a white replace each other.
    static func commit(
        _ changes: LightChangeBatcher.Changes, link: EntityLink, service: Service, hasColorTemperature: Bool, fixedWhite: String?
    ) async throws {
        let brightness = changes.brightness.map { Int($0) }
        if changes.on == false || brightness == 0 {
            try await link.call("light", "turn_off")
            return
        }
        var data: [String: JSONValue] = [:]
        if let mired = changes.mirek, mired > 0 {
            if hasColorTemperature {
                data["color_temp_kelvin"] = .number((1_000_000 / Double(mired)).rounded(.down))
            } else if let fixedWhite {
                let current = brightness ?? service[.brightness]?.value.intValue ?? 100
                let level = JSONValue.number((Double(current) * 255 / 100).rounded())
                data[fixedWhite == "rgbw" ? "rgbw_color" : "white"] = fixedWhite == "rgbw" ? .array([0, 0, 0, level]) : level
            }
        }
        if changes.hue != nil || changes.saturation != nil {
            let h = changes.hue ?? service[.hue]?.value.doubleValue ?? 0
            let s = changes.saturation ?? service[.saturation]?.value.doubleValue ?? 0
            data["hs_color"] = .array([.number(h), .number(s)])
        }
        if let brightness, data["rgbw_color"] == nil, data["white"] == nil { data["brightness_pct"] = .number(Double(brightness)) }
        try await link.call("light", "turn_on", data)
    }
}

// MARK: - 7.2 switch, input_boolean → Switch or Outlet

final class SwitchFunction: EntityFunction, @unchecked Sendable {
    let isOutlet: Bool
    override var category: AccessoryCategory { isOutlet ? .outlet : .switch }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        isOutlet = state.domain == "switch" && state.deviceClass == "outlet"
        let service = Service(isOutlet ? .outlet : .switch, name: state.friendlyName, subtype: key, optional: isOutlet ? [.outletInUse] : [], isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        if isOutlet { service.characteristic(.outletInUse).value = .bool(true) }
        let domain = state.domain
        service.characteristic(.on).onWrite { value in
            try await link.call(domain, value.boolValue == true ? "turn_on" : "turn_off")
        }
    }

    override func update(_ state: EntityState) {
        service.characteristic(.on).show(.bool(state.state == "on"))
    }
}

// MARK: - 7.3 scene, script, button, input_button → momentary Switch

final class MomentaryFunction: EntityFunction, @unchecked Sendable {
    override var category: AccessoryCategory { .switch }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        let service = Service(.switch, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        let domain = state.domain, objectID = state.objectID
        let on = service.characteristic(.on)
        on.value = .bool(false)
        on.onWrite { [weak on] value in
            // Off is ignored: the switch turns itself off.
            guard value.boolValue == true else { return }
            switch domain {
            case "scene": try await link.call("scene", "turn_on")
            case "script": try await link.deliver(ServiceCall(domain: "script", service: objectID, data: [:], entityID: nil))
            default: try await link.call(domain, "press")
            }
            on?.revert(to: .bool(false), after: link.momentaryReset)
        }
    }

    // State changes are ignored: On stays false except just after a write.
}

// MARK: - 7.4 cover

final class CoverFunction: EntityFunction, @unchecked Sendable {
    enum Kind { case garage, window, door, covering, basic, tiltOnly }
    static let open = 1, close = 2, setPosition = 4, stop = 8, setTiltPosition = 128

    let kind: Kind
    let hasStop: Bool
    let hasTilt: Bool
    override var category: AccessoryCategory {
        switch kind {
        case .garage: .garageDoorOpener
        case .window: .window
        case .door: .door
        default: .windowCovering
        }
    }

    static func kind(of state: EntityState) -> Kind? {
        let openClose = state.supports(open) || state.supports(close)
        let deviceClass = state.deviceClass
        if (deviceClass == "garage" || deviceClass == "gate"), openClose { return .garage }
        if deviceClass == "window", state.supports(setPosition) { return .window }
        if deviceClass == "door", state.supports(setPosition) { return .door }
        if state.supports(setPosition) { return .covering }
        if openClose { return .basic }
        if state.supports(setTiltPosition) { return .tiltOnly }
        return nil
    }

    init?(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        guard let kind = Self.kind(of: state) else { return nil }
        self.kind = kind
        hasStop = state.supports(Self.stop)
        hasTilt = state.supports(Self.setTiltPosition) && kind != .garage
        let service: Service
        switch kind {
        case .garage:
            service = Service(.garageDoorOpener, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        default:
            let type: ServiceType = kind == .window ? .window : kind == .door ? .door : .windowCovering
            var optional: [CharacteristicType] = []
            if hasStop, kind != .tiltOnly { optional.append(.holdPosition) }
            if hasTilt { optional += [.currentHorizontalTiltAngle, .targetHorizontalTiltAngle] }
            if kind == .tiltOnly { optional.append(.targetPosition.with(minValue: 0, maxValue: 0)) }
            if kind == .tiltOnly { optional.append(.currentPosition.with(minValue: 0, maxValue: 0)) }
            service = Service(type, name: state.friendlyName, subtype: key, optional: optional, isPrimary: isPrimary)
            service.characteristic(.positionState).value = .int(2)
        }
        super.init(entityID: state.entityID, service: service)
        switch kind {
        case .garage:
            let current = service.characteristic(.currentDoorState)
            service.characteristic(.targetDoorState).onWrite { [weak current] value in
                let open = value.intValue == 0
                try await link.call("cover", open ? "open_cover" : "close_cover")
                // HA shows the door moving at once (opening 2, closing 3) when it is not there yet.
                if let current, current.value.intValue != (open ? 0 : 1) { current.value = .int(open ? 2 : 3) }
            }
        case .basic:
            let hasStop = self.hasStop
            let currentPosition = service.characteristic(.currentPosition)
            let targetPosition = service.characteristic(.targetPosition)
            targetPosition.onWrite { [weak currentPosition, weak targetPosition] value in
                let wanted = value.doubleValue ?? 0
                let (call, position): (String, Int)
                if hasStop {
                    (call, position) = wanted > 70 ? ("open_cover", 100) : wanted < 30 ? ("close_cover", 0) : ("stop_cover", 50)
                } else {
                    (call, position) = wanted >= 50 ? ("open_cover", 100) : ("close_cover", 0)
                }
                try await link.call("cover", call)
                currentPosition?.value = .int(position)
                targetPosition?.revert(to: .int(position), after: .zero)
            }
        case .tiltOnly:
            break
        default:
            service.characteristic(.targetPosition).onWrite { value in
                try await link.call("cover", "set_cover_position", ["position": .number(Double(value.intValue ?? 0))])
            }
        }
        if hasStop, kind != .garage, kind != .tiltOnly {
            service[.holdPosition]?.onWrite { value in
                guard value.boolValue == true else { return }
                try await link.call("cover", "stop_cover")
            }
        }
        if hasTilt {
            service[.targetHorizontalTiltAngle]?.onWrite { value in
                let angle = Double(value.intValue ?? 0)
                let tilt = ((angle + 90) / 180 * 100).rounded()
                try await link.call("cover", "set_cover_tilt_position", ["tilt_position": .number(tilt)])
            }
        }
    }

    override func update(_ state: EntityState) {
        let positionState = state.state == "opening" ? 1 : state.state == "closing" ? 0 : 2
        switch kind {
        case .garage:
            let current: Int? = ["open": 0, "closed": 1, "opening": 2, "closing": 3][state.state]
            if let current { service.characteristic(.currentDoorState).show(.int(current)) }
            switch state.state {
            case "open", "opening": service.characteristic(.targetDoorState).show(.int(0))
            case "closed", "closing": service.characteristic(.targetDoorState).show(.int(1))
            default: break
            }
            service.characteristic(.obstructionDetected).show(.bool(state.attributes["obstruction-detected"]?.boolValue == true))
        case .basic:
            service.characteristic(.positionState).show(.int(positionState))
            if state.state == "open" || state.state == "closed" {
                let position = state.state == "open" ? 100 : 0
                service.characteristic(.currentPosition).show(.int(position))
                service.characteristic(.targetPosition).show(.int(position))
            }
        case .tiltOnly:
            service.characteristic(.positionState).show(.int(positionState))
        default:
            service.characteristic(.positionState).show(.int(positionState))
            if let position = state.double("current_position") {
                let current = min(100, max(0, Int(saturating: position) ?? 0))
                service.characteristic(.currentPosition).show(.int(current))
                let target = service.characteristic(.targetPosition)
                let wanted = target.value.intValue ?? current
                switch state.state {
                case "opening": if wanted < current { target.show(.int(100)) }
                case "closing": if wanted > current { target.show(.int(0)) }
                default: target.show(.int(current))
                }
            }
        }
        if hasTilt, let tilt = state.double("current_tilt_position") {
            let angle = min(90, max(-90, Int(saturating: tilt / 100 * 180 - 90) ?? 0))
            service[.currentHorizontalTiltAngle]?.show(.int(angle))
            service[.targetHorizontalTiltAngle]?.show(.int(angle))
        }
    }
}

// MARK: - 7.5 lock → LockMechanism (a security control)

final class LockFunction: EntityFunction, @unchecked Sendable {
    override var category: AccessoryCategory { .doorLock }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        let service = Service(.lockMechanism, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        // Lock Target State is a security control of its own (Characteristic.securityControls): the MCP server and the
        // Assistant write it only through set_security_accessory.
        service.characteristic(.lockTargetState).securityControl().onWrite { value in
            var data: [String: JSONValue] = [:]
            if let code = link.lockCode { data["code"] = .string(code) }
            try await link.call("lock", value.intValue == 1 ? "lock" : "unlock", data)
        }
    }

    override func update(_ state: EntityState) {
        let current = ["unlocked": 0, "unlocking": 1, "locking": 0, "locked": 1, "jammed": 2][state.state] ?? 3
        service.characteristic(.lockCurrentState).show(.int(current))
        if let target = ["unlocked": 0, "unlocking": 0, "locking": 1, "locked": 1][state.state] {
            service.characteristic(.lockTargetState).show(.int(target))
        }
    }
}

// MARK: - 7.6 climate → Thermostat

final class ClimateFunction: EntityFunction, @unchecked Sendable {
    static let targetTemperatureFeature = 1, rangeFeature = 2, targetHumidityFeature = 4
    static let gap = 5.0

    let fahrenheit: Bool
    let hasTarget: Bool
    let hasRange: Bool
    let hasTargetHumidity: Bool
    /// HomeKit's Target Heating Cooling State → HA's hvac mode.
    let modes: [Int: String]
    let range: ClosedRange<Double>
    private let link: EntityLink
    override var category: AccessoryCategory { .thermostat }

    static func shape(_ state: EntityState) -> String {
        "\(state.strings("hvac_modes"))|\(state.double("min_temp") ?? 0)|\(state.double("max_temp") ?? 0)|\(state.double("min_humidity") ?? 0)|"
            + "\(state.features)|\(state.attributes["current_humidity"] != nil)"
    }

    /// The reverse mode map (7.6): `auto` left out when `heat_cool` is there, `dry` and `fan_only` when `cool` is.
    static func modes(_ hvacModes: [String]) -> [Int: String] {
        let list = hvacModes.isEmpty ? ["heat", "cool", "heat_cool", "off"] : hvacModes
        let toHomeKit = ["off": 0, "heat": 1, "cool": 2, "auto": 3, "heat_cool": 3, "dry": 2, "fan_only": 2]
        var map: [Int: String] = [:]
        for mode in list {
            if mode == "auto", list.contains("heat_cool") { continue }
            if mode == "dry" || mode == "fan_only", list.contains("cool") { continue }
            guard let value = toHomeKit[mode], map[value] == nil else { continue }
            map[value] = mode
        }
        return map
    }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        fahrenheit = link.fahrenheit
        hasTarget = state.supports(Self.targetTemperatureFeature)
        hasRange = state.supports(Self.rangeFeature)
        hasTargetHumidity = state.supports(Self.targetHumidityFeature)
        modes = Self.modes(state.strings("hvac_modes"))
        let fahrenheit = link.fahrenheit
        let low = state.double("min_temp").map { Temperature.celsius($0, fahrenheit: fahrenheit) } ?? 7
        let high = state.double("max_temp").map { Temperature.celsius($0, fahrenheit: fahrenheit) } ?? 35
        var minimum = (min(low, high) * 10).rounded(.up) / 10, maximum = (max(low, high) * 10).rounded(.down) / 10
        minimum = max(0, minimum)
        if maximum < minimum { maximum = minimum }
        range = minimum...maximum
        self.link = link
        let validModes = modes.keys.sorted()
        var optional: [CharacteristicType] = [
            .targetHeatingCoolingState.with(validValues: validModes.isEmpty ? [0] : validModes),
            .targetTemperature.with(minValue: minimum, maxValue: maximum),
            .currentTemperature.with(minValue: -100, maxValue: 200),
        ]
        if hasRange {
            optional += [.coolingThresholdTemperature.with(minValue: minimum, maxValue: maximum), .heatingThresholdTemperature.with(minValue: minimum, maxValue: maximum)]
        }
        if state.attributes["current_humidity"] != nil || hasTargetHumidity { optional.append(.currentRelativeHumidity) }
        if hasTargetHumidity {
            let minHumidity = state.double("min_humidity") ?? 30, maxHumidity = state.double("max_humidity") ?? 99
            optional.append(.targetRelativeHumidity.with(minValue: min(minHumidity, maxHumidity), maxValue: max(minHumidity, maxHumidity)))
        }
        let service = Service(.thermostat, name: state.friendlyName, subtype: key, optional: optional, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.temperatureDisplayUnits).value = .int(fahrenheit ? 1 : 0)
        service.characteristic(.targetTemperature).value = .double(min(maximum, max(minimum, 20)))
        let batch = WriteBatch(window: link.batchWindow) { [weak self] entries in try await self?.commit(entries) }
        service.characteristic(.targetHeatingCoolingState).onWrite { try await batch.set("mode", $0) }
        service.characteristic(.targetTemperature).onWrite { try await batch.set("target", $0) }
        service[.coolingThresholdTemperature]?.onWrite { try await batch.set("cool", $0) }
        service[.heatingThresholdTemperature]?.onWrite { try await batch.set("heat", $0) }
        service[.targetRelativeHumidity]?.onWrite { try await batch.set("humidity", $0) }
    }

    private func temperature(_ state: EntityState, _ key: String) -> Double? {
        state.double(key).map { Temperature.tenth(Temperature.celsius($0, fahrenheit: fahrenheit)) }
    }

    private func inRange(_ value: Double) -> Double { min(range.upperBound, max(range.lowerBound, value)) }

    override func update(_ state: EntityState) {
        let toHomeKit = ["off": 0, "heat": 1, "cool": 2, "auto": 3, "heat_cool": 3, "dry": 2, "fan_only": 2]
        if let mode = toHomeKit[state.state] { service.characteristic(.targetHeatingCoolingState).show(.int(mode)) }
        if let action = state.string("hvac_action") {
            let current: Int
            switch action {
            case "heating", "preheating", "defrosting": current = 1
            case "cooling", "drying", "fan": current = 2
            default: current = 0
            }
            service.characteristic(.currentHeatingCoolingState).show(.int(current))
        }
        if let current = temperature(state, "current_temperature") {
            service.characteristic(.currentTemperature).show(.double(clamp(current, .currentTemperature.with(minValue: -100, maxValue: 200))))
        }
        let mode = service.characteristic(.targetHeatingCoolingState).value.intValue
        var target = temperature(state, "temperature")
        if target == nil, hasRange { target = mode == 1 ? temperature(state, "target_temp_low") : mode == 2 ? temperature(state, "target_temp_high") : nil }
        if let target { service.characteristic(.targetTemperature).show(.double(inRange(target))) }
        if hasRange {
            if let high = temperature(state, "target_temp_high") { service[.coolingThresholdTemperature]?.show(.double(inRange(high))) }
            if let low = temperature(state, "target_temp_low") { service[.heatingThresholdTemperature]?.show(.double(inRange(low))) }
        }
        if let humidity = state.double("current_humidity") { service[.currentRelativeHumidity]?.show(.double(min(100, max(0, humidity)))) }
        if let humidity = state.double("humidity"), let characteristic = service[.targetRelativeHumidity] {
            characteristic.show(.double(clamp(humidity, characteristic.type)))
        }
    }

    private func toServer(_ celsius: Double) -> JSONValue {
        .number(Temperature.tenth(Temperature.fromCelsius(celsius, fahrenheit: fahrenheit)))
    }

    func commit(_ entries: [(String, HAPValue)]) async throws {
        var written: [String: Double] = [:]
        var order: [String] = []
        for (key, value) in entries {
            if written[key] == nil { order.append(key) }
            written[key] = value.doubleValue ?? value.intValue.map(Double.init)
        }
        for key in order {
            switch key {
            case "mode":
                guard let value = written["mode"].map({ Int($0) }) else { continue }
                var mode = modes[value]
                if mode == nil {
                    // A mode the device lacks (Siri's Auto on a heater): heat first, cool first when the target is below now.
                    let current = service.characteristic(.currentTemperature).value.doubleValue ?? 0
                    let fallback = (written["target"].map { $0 < current } ?? false) ? [3, 2, 1, 0] : [3, 1, 2, 0]
                    if let first = fallback.first(where: { modes[$0] != nil }) {
                        mode = modes[first]
                        service.characteristic(.targetHeatingCoolingState).revert(to: .int(first), after: .zero)
                    }
                }
                if let mode { try await link.call("climate", "set_hvac_mode", ["hvac_mode": .string(mode)]) }
            case "target":
                guard let value = written["target"] else { continue }
                let mode = modes[Int(written["mode"] ?? Double(service.characteristic(.targetHeatingCoolingState).value.intValue ?? 0))]
                if hasTarget {
                    try await link.call("climate", "set_temperature", ["temperature": toServer(value)])
                } else if hasRange, mode == "heat" {
                    try await setThresholds(heat: value, cool: nil)
                } else if hasRange, mode == "cool" {
                    try await setThresholds(heat: nil, cool: value)
                }
            case "cool", "heat":
                guard written["cool"] != nil || written["heat"] != nil, order.firstIndex(of: key) == order.firstIndex(where: { $0 == "cool" || $0 == "heat" }) else { continue }
                try await setThresholds(heat: written["heat"], cool: written["cool"])
            case "humidity":
                guard let value = written["humidity"] else { continue }
                try await link.call("climate", "set_humidity", ["humidity": .number(value.rounded())])
            default:
                break
            }
        }
    }

    /// Both thresholds go together (7.6): the one not written from the characteristic, a 5 °C gap kept on the side not at a
    /// bound.
    private func setThresholds(heat: Double?, cool: Double?) async throws {
        var low = heat ?? service[.heatingThresholdTemperature]?.value.doubleValue ?? range.lowerBound
        var high = cool ?? service[.coolingThresholdTemperature]?.value.doubleValue ?? range.upperBound
        if high < low {
            if cool != nil { low = high - Self.gap } else { high = low + Self.gap }
        }
        low = inRange(low)
        high = inRange(high)
        if high - low < Self.gap {
            if high >= range.upperBound { low = inRange(high - Self.gap) } else { high = inRange(low + Self.gap) }
        }
        try await link.call("climate", "set_temperature", ["target_temp_high": toServer(high), "target_temp_low": toServer(low)])
    }
}

// MARK: - 7.7 sensor

final class SensorFunction: EntityFunction, @unchecked Sendable {
    enum Kind: String { case temperature, humidity, illuminance, carbonDioxide, carbonMonoxide, pm25, pm10 }
    let kind: Kind
    private var peak: Double = 0
    override var category: AccessoryCategory { .sensor }

    /// The kind of a sensor, in HA homekit's order (7.7); nil for one this release leaves out.
    static func kind(of state: EntityState) -> Kind? {
        let id = state.entityID
        switch state.deviceClass {
        case "temperature": return .temperature
        case "humidity": return state.unit == "%" ? .humidity : nil
        case "pm10": return .pm10
        case "pm25": return .pm25
        case "carbon_monoxide": return .carbonMonoxide
        case "carbon_dioxide": return .carbonDioxide
        case "illuminance": return .illuminance
        default: break
        }
        if state.unit == "°C" || state.unit == "°F" { return .temperature }
        if state.unit == "lx" { return .illuminance }
        if id.contains("pm10") { return .pm10 }
        if id.contains("pm25") { return .pm25 }
        if id.contains("co2") { return .carbonDioxide }
        return nil
    }

    init?(state: EntityState, key: String, isPrimary: Bool) {
        guard let kind = Self.kind(of: state) else { return nil }
        self.kind = kind
        let service: Service
        switch kind {
        case .temperature: service = Service(.temperatureSensor, name: state.friendlyName, subtype: key, optional: [.currentTemperature.with(minValue: -273, maxValue: 999)], isPrimary: isPrimary)
        case .humidity: service = Service(.humiditySensor, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        case .illuminance: service = Service(.lightSensor, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        case .carbonDioxide: service = Service(.carbonDioxideSensor, name: state.friendlyName, subtype: key, optional: [.carbonDioxideLevel, .carbonDioxidePeakLevel], isPrimary: isPrimary)
        case .carbonMonoxide: service = Service(.carbonMonoxideSensor, name: state.friendlyName, subtype: key, optional: [.carbonMonoxideLevel, .carbonMonoxidePeakLevel], isPrimary: isPrimary)
        case .pm25: service = Service(.airQualitySensor, name: state.friendlyName, subtype: key, optional: [.pm2_5Density], isPrimary: isPrimary)
        case .pm10: service = Service(.airQualitySensor, name: state.friendlyName, subtype: key, optional: [.pm10Density], isPrimary: isPrimary)
        }
        super.init(entityID: state.entityID, service: service)
    }

    /// AirQuality from PM2.5 µg/m³ (7.7).
    static func airQuality(pm25 value: Double) -> Int {
        value <= 9 ? 1 : value <= 35.4 ? 2 : value <= 55.4 ? 3 : value <= 125.4 ? 4 : 5
    }

    static func airQuality(pm10 value: Double) -> Int {
        value <= 54 ? 1 : value <= 154 ? 2 : value <= 254 ? 3 : value <= 354 ? 4 : 5
    }

    override func update(_ state: EntityState) {
        guard let value = state.number else { return }
        switch kind {
        case .temperature:
            let celsius = Temperature.tenth(Temperature.celsius(value, fahrenheit: state.unit == "°F"))
            service.characteristic(.currentTemperature).show(.double(min(999, max(-273, celsius))))
        case .humidity:
            service.characteristic(.currentRelativeHumidity).show(.double(min(100, max(0, value))))
        case .illuminance:
            service.characteristic(.currentAmbientLightLevel).show(.double(min(100_000, max(0.0001, value))))
        case .carbonDioxide:
            peak = max(peak, value)
            service.characteristic(.carbonDioxideLevel).show(.double(clamp(value, .carbonDioxideLevel)))
            service.characteristic(.carbonDioxidePeakLevel).show(.double(clamp(peak, .carbonDioxidePeakLevel)))
            service.characteristic(.carbonDioxideDetected).show(.int(value > 1000 ? 1 : 0))
        case .carbonMonoxide:
            peak = max(peak, value)
            service.characteristic(.carbonMonoxideLevel).show(.double(clamp(value, .carbonMonoxideLevel)))
            service.characteristic(.carbonMonoxidePeakLevel).show(.double(clamp(peak, .carbonMonoxidePeakLevel)))
            service.characteristic(.carbonMonoxideDetected).show(.int(value > 25 ? 1 : 0))
        case .pm25:
            service.characteristic(.pm2_5Density).show(.double(clamp(value, .pm2_5Density)))
            service.characteristic(.airQuality).show(.int(Self.airQuality(pm25: value)))
        case .pm10:
            service.characteristic(.pm10Density).show(.double(clamp(value, .pm10Density)))
            service.characteristic(.airQuality).show(.int(Self.airQuality(pm10: value)))
        }
    }
}

// MARK: - 7.8 binary_sensor

final class BinarySensorFunction: EntityFunction, @unchecked Sendable {
    /// Classes an occupancy sensor would misread (7.8, proposal): left out unless the entity is included by name.
    static let misleading: Set<String> = [
        "connectivity", "problem", "update", "running", "plug", "power", "light", "lock", "tamper", "battery_charging", "cold", "heat",
        "moving", "safety", "sound", "vibration",
    ]

    let characteristicType: CharacteristicType
    let isBool: Bool
    override var category: AccessoryCategory { .sensor }

    static func serviceType(of deviceClass: String?) -> (ServiceType, CharacteristicType, Bool)? {
        switch deviceClass {
        case "door", "window", "opening", "garage_door": (.contactSensor, .contactSensorState, false)
        case "motion": (.motionSensor, .motionDetected, true)
        case "moisture": (.leakSensor, .leakDetected, false)
        case "smoke": (.smokeSensor, .smokeDetected, false)
        case "carbon_monoxide", "gas": (.carbonMonoxideSensor, .carbonMonoxideDetected, false)
        case "battery": nil
        default: (.occupancySensor, .occupancyDetected, false)
        }
    }

    init?(state: EntityState, key: String, isPrimary: Bool, included: Bool) {
        if let deviceClass = state.deviceClass, Self.misleading.contains(deviceClass), !included { return nil }
        guard let (type, characteristic, isBool) = Self.serviceType(of: state.deviceClass) else { return nil }
        characteristicType = characteristic
        self.isBool = isBool
        super.init(entityID: state.entityID, service: Service(type, name: state.friendlyName, subtype: key, isPrimary: isPrimary))
    }

    override func update(_ state: EntityState) {
        let on = state.state == "on"
        service.characteristic(characteristicType).show(isBool ? .bool(on) : .int(on ? 1 : 0))
    }
}

// MARK: - Battery (5, 7.7, 7.8): one service per device, from whichever entities report it

final class BatteryFunction: EntityFunction, @unchecked Sendable {
    init(key: String, name: String?) {
        super.init(entityID: "", service: Service(.battery, name: name, subtype: key, optional: [.batteryLevel, .chargingState]))
        service.characteristic(.chargingState).value = .int(2)
    }

    /// Whether an entity feeds a device's Battery.
    static func feeds(_ state: EntityState) -> Bool {
        state.attributes["battery_level"] != nil
            || (state.domain == "sensor" && state.deviceClass == "battery")
            || (state.domain == "binary_sensor" && state.deviceClass == "battery")
    }

    override func update(_ state: EntityState) {
        if state.domain == "binary_sensor", state.deviceClass == "battery" {
            service.characteristic(.statusLowBattery).show(.int(state.state == "on" ? 1 : 0))
            return
        }
        let level = state.domain == "sensor" && state.deviceClass == "battery" ? state.number : state.double("battery_level")
        if let level {
            let percent = min(100, max(0, Int(saturating: level.rounded()) ?? 0))
            service.characteristic(.batteryLevel).show(.int(percent))
            service.characteristic(.statusLowBattery).show(.int(percent < 20 ? 1 : 0))
        }
        if let charging = state.attributes["battery_charging"]?.boolValue {
            service.characteristic(.chargingState).show(.int(charging ? 1 : 0))
        }
    }
}

// MARK: - 7.9 fan → Fanv2

final class FanFunction: EntityFunction, @unchecked Sendable {
    static let setSpeed = 1, oscillate = 2, direction = 4, presetMode = 8

    let presets: [String]
    private var presetSwitches: [String: Service] = [:]
    private let link: EntityLink
    override var extraServices: [Service] { presets.count > 1 ? presets.compactMap { presetSwitches[$0] } : [] }
    override var category: AccessoryCategory { .fan }

    static func shape(_ state: EntityState) -> String {
        "\(state.features)|\(state.double("percentage_step") ?? 0)|\(state.strings("preset_modes"))"
    }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        presets = state.supports(Self.presetMode) ? state.strings("preset_modes") : []
        self.link = link
        var optional: [CharacteristicType] = []
        let step = max(1, state.double("percentage_step") ?? 1)
        if state.supports(Self.setSpeed) { optional.append(.rotationSpeed.with(minStep: step)) }
        if state.supports(Self.oscillate) { optional.append(.swingMode) }
        if state.supports(Self.direction) { optional.append(.rotationDirection) }
        if presets.count == 1 { optional.append(.targetFanState) }
        var switches: [Service] = []
        if presets.count > 1 {
            for preset in presets {
                switches.append(Service(.switch, name: "\(state.friendlyName ?? state.objectID) \(preset)", subtype: "\(key):preset:\(preset)"))
            }
        }
        let service = Service(.fanv2, name: state.friendlyName, subtype: key, optional: optional, linked: switches, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        for (preset, switchService) in zip(presets, switches) {
            presetSwitches[preset] = switchService
            switchService.characteristic(.on).onWrite { value in
                if value.boolValue == true {
                    try await link.call("fan", "set_preset_mode", ["preset_mode": .string(preset)])
                } else {
                    try await link.call("fan", "turn_on")
                }
            }
        }
        let batch = WriteBatch(window: link.batchWindow) { [weak self] entries in try await self?.commit(entries) }
        service.characteristic(.active).onWrite { try await batch.set("active", $0) }
        service[.rotationSpeed]?.onWrite { try await batch.set("speed", $0) }
        service[.swingMode]?.onWrite { try await batch.set("swing", $0) }
        service[.rotationDirection]?.onWrite { try await batch.set("direction", $0) }
        service[.targetFanState]?.onWrite { try await batch.set("preset", $0) }
    }

    override func update(_ state: EntityState) {
        if state.state == "on" { service.characteristic(.active).show(.int(1)) } else if state.state == "off" { service.characteristic(.active).show(.int(0)) }
        if let speed = service[.rotationSpeed], state.state != "off", let percentage = state.double("percentage") {
            let step = speed.type.minStep ?? 1
            let value = percentage == 0 && state.state == "on" ? max(1, step) : percentage
            speed.show(.double(min(100, max(0, value))))
        }
        if let oscillating = state.attributes["oscillating"]?.boolValue { service[.swingMode]?.show(.int(oscillating ? 1 : 0)) }
        if let direction = state.string("direction") { service[.rotationDirection]?.show(.int(direction == "reverse" ? 1 : 0)) }
        let preset = state.string("preset_mode")
        service[.targetFanState]?.show(.int(preset != nil ? 1 : 0))
        for (name, switchService) in presetSwitches { switchService.characteristic(.on).show(.bool(state.state == "on" && preset == name)) }
    }

    func commit(_ entries: [(String, HAPValue)]) async throws {
        var written: [String: HAPValue] = [:]
        for (key, value) in entries { written[key] = value }
        if written["active"]?.intValue == 0 {
            try await link.call("fan", "turn_off")
            return
        }
        if let speed = written["speed"]?.doubleValue ?? written["speed"]?.intValue.map(Double.init) {
            try await link.call("fan", "set_percentage", ["percentage": .number(speed.rounded())])
        } else if written["active"]?.intValue == 1 {
            try await link.call("fan", "turn_on")
        }
        if let swing = written["swing"]?.intValue { try await link.call("fan", "oscillate", ["oscillating": .bool(swing == 1)]) }
        if let direction = written["direction"]?.intValue {
            try await link.call("fan", "set_direction", ["direction": .string(direction == 1 ? "reverse" : "forward")])
        }
        if let preset = written["preset"]?.intValue, let only = presets.first {
            if preset == 1 {
                try await link.call("fan", "set_preset_mode", ["preset_mode": .string(only)])
            } else {
                let current = service[.rotationSpeed]?.value.doubleValue ?? 50
                try await link.call("fan", "turn_on", ["percentage": .number(current > 0 ? current : 50)])
            }
        }
    }
}

// MARK: - 7.10 media_player → Switch (power)

final class MediaPowerFunction: EntityFunction, @unchecked Sendable {
    static let turnOn = 128, turnOff = 256
    override var category: AccessoryCategory { .switch }

    init?(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        guard state.supports(Self.turnOn) || state.supports(Self.turnOff) else { return nil }
        let service = Service(.switch, name: "\(state.friendlyName ?? state.objectID) Power", subtype: key, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.on).onWrite { value in
            try await link.call("media_player", value.boolValue == true ? "turn_on" : "turn_off")
        }
    }

    override func update(_ state: EntityState) {
        service.characteristic(.on).show(.bool(!["off", "unknown", "standby", "None"].contains(state.state)))
    }
}

// MARK: - 7.11 valve → Valve

final class ValveFunction: EntityFunction, @unchecked Sendable {
    override var category: AccessoryCategory { .faucet }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        let service = Service(.valve, name: state.friendlyName, subtype: key, isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.valveType).value = .int(0)
        let active = service.characteristic(.active)
        // A gas valve opens what can hurt: a security control (proposal), written by the MCP server only after confirming.
        if state.deviceClass == "gas" { active.securityControl() }
        let inUse = service.characteristic(.inUse)
        active.onWrite { [weak inUse] value in
            let open = value.intValue == 1
            try await link.call("valve", open ? "open_valve" : "close_valve")
            inUse?.value = .int(open ? 1 : 0)
        }
    }

    override func update(_ state: EntityState) {
        let open = ["open", "opening", "closing"].contains(state.state)
        service.characteristic(.active).show(.int(open ? 1 : 0))
        service.characteristic(.inUse).show(.int(open ? 1 : 0))
    }
}

// MARK: - 7.12 alarm_control_panel → SecuritySystem (a security control)

final class AlarmFunction: EntityFunction, @unchecked Sendable {
    static let armHome = 1, armAway = 2, armNight = 4, trigger = 8, armVacation = 32
    let targets: [Int]
    override var category: AccessoryCategory { .securitySystem }

    static func shape(_ state: EntityState) -> String { "\(state.attributes["supported_features"]?.intValue ?? -1)" }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        let features = state.attributes["supported_features"]?.intValue ?? (Self.armHome | Self.armAway | Self.armNight | Self.trigger | Self.armVacation)
        var targets = [3]
        if features & Self.armHome != 0 { targets.append(0) }
        if features & (Self.armAway | Self.armVacation) != 0 { targets.append(1) }
        if features & Self.armNight != 0 { targets.append(2) }
        targets.sort()
        self.targets = targets
        let current = (targets + [4]).sorted()
        let service = Service(.securitySystem, name: state.friendlyName, subtype: key, optional: [
            .securitySystemCurrentState.with(validValues: current), .securitySystemTargetState.with(validValues: targets),
        ], isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.securitySystemCurrentState).value = .int(3)
        service.characteristic(.securitySystemTargetState).value = .int(3)
        service.characteristic(.securitySystemTargetState).securityControl().onWrite { value in
            let calls = [0: "alarm_arm_home", 1: "alarm_arm_away", 2: "alarm_arm_night", 3: "alarm_disarm"]
            guard let call = calls[value.intValue ?? -1] else { throw HAPStatusError(.invalidValueInRequest) }
            var data: [String: JSONValue] = [:]
            if let code = link.alarmCode { data["code"] = .string(code) }
            try await link.call("alarm_control_panel", call, data)
        }
    }

    override func update(_ state: EntityState) {
        let current: Int? = ["armed_home": 0, "armed_away": 1, "armed_vacation": 1, "armed_night": 2, "disarmed": 3, "arming": 3, "triggered": 4][state.state]
        if let current, current == 4 || current == 3 || targets.contains(current) {
            service.characteristic(.securitySystemCurrentState).show(.int(current))
        }
        let target: Int? = ["armed_home": 0, "armed_away": 1, "armed_vacation": 1, "arming": 1, "armed_night": 2, "disarmed": 3][state.state]
        if let target, targets.contains(target) { service.characteristic(.securitySystemTargetState).show(.int(target)) }
    }
}

// MARK: - 7.13 humidifier → HumidifierDehumidifier

final class HumidifierFunction: EntityFunction, @unchecked Sendable {
    let isDehumidifier: Bool
    let thresholdType: CharacteristicType
    let bounds: ClosedRange<Double>
    override var category: AccessoryCategory { isDehumidifier ? .dehumidifier : .humidifier }

    static func shape(_ state: EntityState) -> String { "\(state.deviceClass ?? "")|\(state.double("min_humidity") ?? 0)|\(state.double("max_humidity") ?? 0)" }

    init(state: EntityState, key: String, isPrimary: Bool, link: EntityLink) {
        isDehumidifier = state.deviceClass == "dehumidifier"
        thresholdType = isDehumidifier ? .relativeHumidityDehumidifierThreshold : .relativeHumidityHumidifierThreshold
        let low = state.double("min_humidity") ?? 0, high = state.double("max_humidity") ?? 100
        bounds = min(low, high)...max(low, high)
        let target = isDehumidifier ? 2 : 1
        let service = Service(.humidifierDehumidifier, name: state.friendlyName, subtype: key, optional: [
            .targetHumidifierDehumidifierState.with(minValue: Double(target), maxValue: Double(target), validValues: [target]),
            thresholdType.with(minValue: 0, maxValue: 100, minStep: 1),
        ], isPrimary: isPrimary)
        super.init(entityID: state.entityID, service: service)
        service.characteristic(.targetHumidifierDehumidifierState).value = .int(target)
        service.characteristic(.active).onWrite { value in
            try await link.call("humidifier", value.intValue == 1 ? "turn_on" : "turn_off")
        }
        let bounds = self.bounds
        service.characteristic(thresholdType).onWrite { value in
            let humidity = min(bounds.upperBound, max(bounds.lowerBound, (value.doubleValue ?? 0).rounded()))
            try await link.call("humidifier", "set_humidity", ["humidity": .number(humidity)])
        }
    }

    override func update(_ state: EntityState) {
        let on = state.state == "on"
        service.characteristic(.active).show(.int(on ? 1 : 0))
        var current = on ? (isDehumidifier ? 3 : 2) : 0
        // HA's action, when the device reports one (proposal): idle 1, humidifying 2, drying 3, off 0.
        if let action = state.string("action"), let mapped = ["off": 0, "idle": 1, "humidifying": 2, "drying": 3][action] { current = mapped }
        service.characteristic(.currentHumidifierDehumidifierState).show(.int(current))
        if let target = state.double("humidity") { service.characteristic(thresholdType).show(.double(min(100, max(0, target.rounded())))) }
        if let humidity = state.double("current_humidity") { service.characteristic(.currentRelativeHumidity).show(.double(min(100, max(0, humidity)))) }
    }
}

// MARK: - The table

enum EntityFunctions {
    /// Which of a device's Functions is its primary service: the first of these domains it has. They are the domains of
    /// the first release (docs/clean-room/HomeAssistant.md, section 7).
    static let primaryOrder = [
        "light", "lock", "alarm_control_panel", "cover", "climate", "fan", "humidifier", "valve", "switch", "input_boolean", "media_player",
        "binary_sensor", "sensor", "scene", "script", "button", "input_button",
    ]

    static let domains = Set(primaryOrder)

    /// What decides an entity's service shape: a change rebuilds the accessory (4.5).
    static func shape(of state: EntityState) -> String {
        let base = "\(state.domain)|\(state.deviceClass ?? "")|\(state.friendlyName ?? "")"
        switch state.domain {
        case "light": return base + "|" + LightFunction.shape(state)
        case "climate": return base + "|" + ClimateFunction.shape(state)
        case "fan": return base + "|" + FanFunction.shape(state)
        case "humidifier": return base + "|" + HumidifierFunction.shape(state)
        case "alarm_control_panel": return base + "|" + AlarmFunction.shape(state)
        case "cover", "media_player": return base + "|\(state.features)"
        case "sensor": return base + "|\(state.unit ?? "")"
        default: return base
        }
    }

    /// The Function of an entity, nil for one this release does not map (a sensor of another kind, a battery entity:
    /// those feed the device's Battery instead).
    static func make(_ state: EntityState, key: String, isPrimary: Bool, included: Bool, link: EntityLink) -> EntityFunction? {
        switch state.domain {
        case "light": LightFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "switch", "input_boolean": SwitchFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "scene", "script", "button", "input_button": MomentaryFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "cover": CoverFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "lock": LockFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "climate": ClimateFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "sensor": SensorFunction(state: state, key: key, isPrimary: isPrimary)
        case "binary_sensor": BinarySensorFunction(state: state, key: key, isPrimary: isPrimary, included: included)
        case "fan": FanFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "media_player": MediaPowerFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "valve": ValveFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "alarm_control_panel": AlarmFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        case "humidifier": HumidifierFunction(state: state, key: key, isPrimary: isPrimary, link: link)
        default: nil
        }
    }
}
