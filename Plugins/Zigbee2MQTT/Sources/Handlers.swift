import Foundation
import Homeswift
import HomeswiftPlugin
import Logging
import NIOConcurrencyHelpers

/// The plugin's log, with `log.debug_as_info` applied.
struct Log: Sendable {
    let logger: Logger
    var debugAsInfo = false

    func debug(_ message: @autoclosure () -> String) {
        if debugAsInfo { logger.info("\(message())") } else { logger.debug("\(message())") }
    }
    func info(_ message: @autoclosure () -> String) { logger.info("\(message())") }
    func warning(_ message: @autoclosure () -> String) { logger.warning("\(message())") }
    func error(_ message: @autoclosure () -> String) { logger.error("\(message())") }
}

/// What a device's handlers write through: its `set` and `get` topics, and the log.
final class DeviceLink: Sendable {
    let displayName: String
    let log: Log
    let coverPollInterval: Duration
    private let sendSet: @Sendable ([String: JSONValue]) -> Void
    private let sendGet: @Sendable ([String]) -> Void
    /// The characteristics already warned about for a value outside their range, by type and bound.
    private let warned = NIOLockedValueBox<Set<String>>([])

    init(displayName: String, log: Log, coverPollInterval: Duration, set: @escaping @Sendable ([String: JSONValue]) -> Void, get: @escaping @Sendable ([String]) -> Void) {
        self.displayName = displayName
        self.log = log
        self.coverPollInterval = coverPollInterval
        sendSet = set
        sendGet = get
    }

    func set(_ partial: [String: JSONValue]) { sendSet(partial) }
    func get(_ keys: [String]) { if !keys.isEmpty { sendGet(keys) } }

    /// Sets a number as the device reports it, never clamped (6.3, "range growth"): a value outside the
    /// characteristic's range is warned about once and shown as it is.
    func setNumber(_ characteristic: Characteristic, _ value: Double) {
        let type = characteristic.type
        if let low = type.minValue, value < low { warnOnce(type, "min", "\(type.name) of \(displayName) reported \(value), below its minimum \(low)") }
        if let high = type.maxValue, value > high { warnOnce(type, "max", "\(type.name) of \(displayName) reported \(value), above its maximum \(high)") }
        characteristic.value = type.format == .float ? .double(value) : .int(Int(saturating: value.rounded()) ?? 0)
    }

    private func warnOnce(_ type: CharacteristicType, _ bound: String, _ message: String) {
        let key = type.uuid.uuidString + bound
        if warned.withLockedValue({ $0.insert(key).inserted }) { log.warning(message) }
    }
}

/// One service and what keeps it in step with the device (section 9).
protocol ServiceHandler: AnyObject, Sendable {
    var service: Service { get }
    /// The properties a `get` asks for when the accessory is built and every four hours of silence.
    var gettableKeys: [String] { get }
    /// A state message, nulls taken out.
    func update(_ state: [String: JSONValue])
}

/// `[a, b]` to `[c, d]`, clamped at the ends (6.3).
func linearScale(_ value: Double, from a: Double, _ b: Double, to c: Double, _ d: Double) -> Double {
    if value <= a { return c }
    if value >= b { return d }
    return c + (value - a) / (b - a) * (d - c)
}

/// The type with the exposes entry's range (8, "copy range from exposes"), when it has one.
func ranged(_ type: CharacteristicType, _ expose: Expose?) -> CharacteristicType {
    guard let expose, expose.isNumericRange, let low = expose.valueMin, let high = expose.valueMax else { return type }
    return type.with(minValue: low, maxValue: high, minStep: expose.valueStep ?? 1)
}

extension Expose {
    /// `value_on` → true, `value_off` → false, anything else nil.
    func onOff(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if value == valueOn { return true }
        if value == valueOff { return false }
        return nil
    }

    func onOffValue(_ on: Bool) -> JSONValue { (on ? valueOn : valueOff) ?? .bool(on) }

    var gettableProperty: String? { isGettable ? property : nil }
}

/// What the converters build on: the device, its options, and the services built so far.
final class ServiceBuilder {
    let friendlyName: String
    /// The IEEE address, or a group's id.
    let fallbackName: String
    let accessoryID: String
    let options: DeviceOptions
    let link: DeviceLink
    let adaptiveLighting: (Service) -> AdaptiveLightingController?
    private(set) var handlers: [any ServiceHandler] = []
    private var identities = Set<String>()

    init(friendlyName: String, fallbackName: String, accessoryID: String, options: DeviceOptions, link: DeviceLink,
         adaptiveLighting: @escaping (Service) -> AdaptiveLightingController?) {
        self.friendlyName = friendlyName
        self.fallbackName = fallbackName
        self.accessoryID = accessoryID
        self.options = options
        self.link = link
        self.adaptiveLighting = adaptiveLighting
    }

    /// A service's Name: the friendly name and its subtype (3.2).
    func serviceName(_ subtype: String?) -> String {
        Names.sanitize(subtype.map { "\(friendlyName) \($0)" } ?? friendlyName) ?? fallbackName
    }

    func service(_ type: ServiceType, subtype: String?, optional: [CharacteristicType] = [], extra: [Characteristic] = []) -> Service {
        Service(type, name: serviceName(subtype), subtype: subtype, optional: optional, extra: extra)
    }

    /// Whether a service of this type and subtype is still free; logs an error when it is not.
    func claim(_ type: ServiceType, subtype: String?) -> Bool {
        let key = "\(type.uuid.uuidString)/\(subtype ?? "")"
        guard identities.insert(key).inserted else {
            link.log.error("Duplicate service handler for \(type.name) \(subtype ?? "") on \(link.displayName)")
            return false
        }
        return true
    }

    func add(_ handler: any ServiceHandler) { handlers.append(handler) }

    func warn(_ reason: String, _ expose: Expose) {
        let json = (try? JSONValue(encoding: expose))?.text() ?? ""
        link.log.warning("Could not set up a service of \(link.displayName) for \(json): \(reason)")
    }

    /// Every converter, in the order of section 8.
    func build(_ exposes: [Expose]) -> [any ServiceHandler] {
        let converters: [(String, ([Expose]) -> Void)] = [
            ("light", buildLights), ("switch", buildSwitches), ("cover", buildCovers), ("lock", buildLocks), ("sensor", buildBasicSensors),
            ("air quality", buildAirQuality), ("electrical", buildElectrical), ("action", buildActions), ("thermostat", buildThermostats),
            ("battery", buildBatteries),
        ]
        for (_, converter) in converters { converter(exposes) }
        return handlers
    }

    /// Top-level entries with a property that are published, grouped by endpoint in the order the endpoints first appear.
    static func groupedByEndpoint(_ exposes: [Expose], where include: (Expose) -> Bool) -> [(endpoint: String?, entries: [Expose])] {
        var groups: [(endpoint: String?, entries: [Expose])] = []
        for entry in exposes where entry.hasProperty && entry.isPublished && include(entry) {
            if let index = groups.firstIndex(where: { $0.endpoint == entry.endpoint }) {
                groups[index].entries.append(entry)
            } else {
                groups.append((entry.endpoint, [entry]))
            }
        }
        return groups
    }
}

// MARK: Light (9.1)

final class LightHandler: ServiceHandler, @unchecked Sendable {
    enum Color {
        case hs(property: String, hue: String, saturation: String)
        case xy(property: String, x: String, y: String)

        var property: String {
            switch self {
            case .hs(let property, _, _), .xy(let property, _, _): property
            }
        }
    }

    let service: Service
    let gettableKeys: [String]
    let adaptiveLighting: AdaptiveLightingController?
    private let state: Expose
    private let brightness: Expose?
    private let colorTemperature: Expose?
    private let color: Color?
    private let options: DeviceOptions.Light
    private let link: DeviceLink
    private let lock = NIOLock()
    private var lastAdaptiveTemperature: Double?
    private var pendingHue: Double?
    private var pendingSaturation: Double?

    init?(_ expose: Expose, builder: ServiceBuilder) {
        guard expose.type == "light", let features = expose.features else { return nil }
        guard let state = expose.feature("state"), state.isBinary, state.isPublished, state.isSettable else {
            builder.warn("a light without a usable state", expose)
            return nil
        }
        guard builder.claim(.lightbulb, subtype: expose.endpoint) else { return nil }
        let link = builder.link
        self.link = link
        self.state = state
        self.options = builder.options.light
        let brightness = expose.feature("brightness").flatMap { $0.isNumericRange && $0.isPublished && $0.isSettable ? $0 : nil }
        let colorTemperature = expose.feature("color_temp").flatMap { $0.isNumericRange && $0.isPublished && $0.isSettable ? $0 : nil }
        func composite(_ name: String, _ a: String, _ b: String) -> (String, Expose, Expose)? {
            guard let entry = features.first(where: { $0.type == "composite" && $0.name == name }), let property = entry.property,
                  let first = entry.features?.first(where: { $0.name == a }), let second = entry.features?.first(where: { $0.name == b }),
                  first.hasProperty, second.hasProperty else { return nil }
            return (property, first, second)
        }
        var colorGettable = false
        if let (property, hue, saturation) = composite("color_hs", "hue", "saturation"), let hueProperty = hue.property, let saturationProperty = saturation.property {
            color = .hs(property: property, hue: hueProperty, saturation: saturationProperty)
            colorGettable = hue.isGettable || saturation.isGettable
        } else if let (property, x, y) = composite("color_xy", "x", "y"), let xProperty = x.property, let yProperty = y.property {
            color = .xy(property: property, x: xProperty, y: yProperty)
            colorGettable = x.isGettable || y.isGettable
        } else {
            color = nil
        }
        self.brightness = brightness
        self.colorTemperature = colorTemperature
        var optional: [CharacteristicType] = []
        if brightness != nil { optional.append(.brightness) }
        if color != nil { optional += [.hue, .saturation] }
        if let colorTemperature { optional.append(ranged(.colorTemperature, colorTemperature)) }
        let service = builder.service(.lightbulb, subtype: expose.endpoint, optional: optional)
        self.service = service
        adaptiveLighting = brightness != nil && colorTemperature != nil && builder.options.light.adaptiveLighting ? builder.adaptiveLighting(service) : nil

        var keys: [String] = []
        if let property = state.gettableProperty { keys.append(property) }
        if let brightness, brightness.isGettable, builder.options.light.requestBrightness, let property = brightness.property { keys.append(property) }
        if let property = colorTemperature?.gettableProperty { keys.append(property) }
        if let color, colorGettable { keys.append(color.property) }
        gettableKeys = keys

        adaptiveLighting?.onDisable { [weak self] in self?.lock.withLock { self?.lastAdaptiveTemperature = nil } }
        installWriteHandlers()
    }

    private func installWriteHandlers() {
        let link = self.link, state = self.state
        guard let stateProperty = state.property else { return }
        service.characteristic(.on).onWrite { value in
            link.set([stateProperty: state.onOffValue(value.boolValue ?? false)])
        }
        if let brightness, let property = brightness.property, let low = brightness.valueMin, let high = brightness.valueMax {
            service.characteristic(.brightness).onWrite { value in
                guard let percent = value.doubleValue else {
                    link.log.warning("Non-numeric brightness written to \(link.displayName)")
                    throw HAPStatusError(.invalidValueInRequest, reason: "non-numeric brightness")
                }
                let device = percent <= 0 ? low : percent >= 100 ? high : ColorMath.jsRound(low + percent / 100 * (high - low))
                link.set([property: .number(device)])
            }
        }
        if color != nil {
            service.characteristic(.hue).onWrite { [weak self] value in try self?.colorWritten(hue: value.doubleValue) }
            service.characteristic(.saturation).onWrite { [weak self] value in try self?.colorWritten(saturation: value.doubleValue) }
        }
        if colorTemperature != nil {
            service.characteristic(.colorTemperature).onWrite { [weak self] value in
                guard let mired = value.doubleValue else { throw HAPStatusError(.invalidValueInRequest, reason: "non-numeric color temperature") }
                self?.colorTemperatureWritten(mired)
            }
        }
    }

    /// Hue and saturation go out together, once both were written (a Home app write carries both).
    private func colorWritten(hue: Double? = nil, saturation: Double? = nil) throws {
        guard let color else { throw HAPStatusError(.invalidValueInRequest, reason: "color not supported") }
        let both: (Double, Double)? = lock.withLock {
            if let hue { pendingHue = hue }
            if let saturation { pendingSaturation = saturation }
            guard let h = pendingHue, let s = pendingSaturation else { return nil }
            pendingHue = nil
            pendingSaturation = nil
            return (h, s)
        }
        guard let (h, s) = both else { return }
        if let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive { adaptiveLighting.disableAdaptiveLighting() }
        switch color {
        case .hs(let property, let hueProperty, let saturationProperty):
            link.set([property: [hueProperty: .number(h), saturationProperty: .number(s)]])
        case .xy(let property, let xProperty, let yProperty):
            let xy = ColorMath.hsToXY(hue: h, saturation: s)
            link.set([property: [xProperty: .number(xy.x), yProperty: .number(xy.y)]])
        }
    }

    private func colorTemperatureWritten(_ written: Double) {
        guard let colorTemperature, let property = colorTemperature.property else { return }
        var mired = written
        if let low = colorTemperature.valueMin { mired = max(mired, low) }
        if let high = colorTemperature.valueMax { mired = min(mired, high) }
        var partial: [String: JSONValue] = [property: .number(mired)]
        let isOn = service.characteristic(.on).value.boolValue == true
        if let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive {
            if options.onlyWhenOn, !isOn {
                link.log.debug("Adaptive Lighting: \(link.displayName) is off, not sending \(mired)")
                return
            }
            let skip: Double? = lock.withLock {
                if let last = lastAdaptiveTemperature, abs(mired - last) < options.minDelta { return last }
                lastAdaptiveTemperature = mired
                return nil
            }
            if let last = skip {
                link.log.debug("Adaptive Lighting: \(link.displayName) skips \(mired), too close to \(last)")
                return
            }
            if isOn, let transition = options.transition, transition > 0 { partial["transition"] = .number(transition) }
            link.log.debug("Adaptive Lighting: \(link.displayName) to \(mired)")
        } else {
            lock.withLock { lastAdaptiveTemperature = nil }
        }
        link.set(partial)
    }

    func update(_ state: [String: JSONValue]) {
        var ignoreTemperature = false, ignoreColor = false
        let temperatureProperty = colorTemperature?.property
        let mode = state["color_mode"]?.stringValue
        if let mode {
            if let adaptiveLighting, adaptiveLighting.isAdaptiveLightingActive {
                if mode != "color_temp" {
                    link.log.debug("Adaptive Lighting: \(link.displayName) was set to a colour elsewhere")
                    adaptiveLighting.disableIfChangedElsewhere(mireds: nil)
                } else if let last = lock.withLock({ lastAdaptiveTemperature }), let reported = temperatureProperty.flatMap({ state[$0]?.doubleValue }),
                          abs(last - reported) > 10 {
                    link.log.debug("Adaptive Lighting: \(link.displayName) was set to \(reported) elsewhere, not \(last)")
                    adaptiveLighting.disableAdaptiveLighting()
                }
            }
            if mode == "color_temp" { ignoreColor = true } else { ignoreTemperature = true }
        }
        if let property = self.state.property, let on = self.state.onOff(state[property]) { service.characteristic(.on).value = .bool(on) }
        if let brightness, let property = brightness.property, let value = state[property]?.doubleValue, let low = brightness.valueMin, let high = brightness.valueMax, low != high {
            var percent = linearScale(value, from: low, high, to: 0, 100)
            if percent > 0, percent < 1 { percent = 1 }
            service.characteristic(.brightness).value = .int(Int(ColorMath.jsRound(percent)))
        }
        if let color, !ignoreColor, let object = state[color.property] {
            switch color {
            case .hs(_, let hue, let saturation):
                if let value = object[hue]?.doubleValue { link.setNumber(service.characteristic(.hue), value) }
                if let value = object[saturation]?.doubleValue { link.setNumber(service.characteristic(.saturation), value) }
            case .xy(_, let x, let y):
                if let x = object[x]?.doubleValue, let y = object[y]?.doubleValue { showColor(ColorMath.xyToHS(x: x, y: y)) }
            }
        }
        if let temperatureProperty, !ignoreTemperature, let mired = state[temperatureProperty]?.doubleValue {
            link.setNumber(service.characteristic(.colorTemperature), mired)
        }
        if color != nil, let temperatureProperty, mode == "color_temp", let mired = state[temperatureProperty]?.doubleValue, mired > 0 {
            showColor(ColorMath.miredToHS(mired))
        }
    }

    private func showColor(_ hs: (hue: Double, saturation: Double)) {
        service.characteristic(.hue).value = .double(hs.hue)
        service.characteristic(.saturation).value = .double(hs.saturation)
    }
}

extension ServiceBuilder {
    func buildLights(_ exposes: [Expose]) {
        for expose in exposes where expose.type == "light" && expose.features != nil {
            if let handler = LightHandler(expose, builder: self) { add(handler) }
        }
    }
}

// MARK: Switch (9.2)

final class SwitchHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let state: Expose

    init(service: Service, state: Expose, link: DeviceLink) {
        self.service = service
        self.state = state
        gettableKeys = state.gettableProperty.map { [$0] } ?? []
        let property = state.property ?? "state"
        service.characteristic(.on).onWrite { value in link.set([property: state.onOffValue(value.boolValue ?? false)]) }
    }

    func update(_ message: [String: JSONValue]) {
        if let property = state.property, let on = state.onOff(message[property]) { service.characteristic(.on).value = .bool(on) }
    }
}

extension ServiceBuilder {
    func buildSwitches(_ exposes: [Expose]) {
        let type: ServiceType = options.outlet ? .outlet : .switch
        for expose in exposes where expose.type == "switch" && expose.features != nil {
            guard let state = expose.feature("state"), state.isBinary, state.isPublished, state.isSettable else { continue }
            guard claim(type, subtype: expose.endpoint) else { continue }
            add(SwitchHandler(service: service(type, subtype: expose.endpoint), state: state, link: link))
        }
    }
}

// MARK: Lock (9.4)

final class LockHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let state: Expose
    private let lockState: Expose

    init(service: Service, state: Expose, lockState: Expose, link: DeviceLink) {
        self.service = service
        self.state = state
        self.lockState = lockState
        gettableKeys = [state.gettableProperty, lockState.gettableProperty].compactMap { $0 }
        let property = state.property ?? "state"
        service.characteristic(.lockTargetState).onWrite { value in
            link.set([property: state.onOffValue((value.intValue ?? 0) != 0)])
        }
    }

    func update(_ message: [String: JSONValue]) {
        if let property = state.property, let on = state.onOff(message[property]) { service.characteristic(.lockTargetState).value = .int(on ? 1 : 0) }
        if let property = lockState.property, let value = message[property]?.stringValue,
           let current = ["locked": 1, "unlocked": 0, "not_fully_locked": 2][value] {
            service.characteristic(.lockCurrentState).value = .int(current)
        }
    }
}

extension ServiceBuilder {
    func buildLocks(_ exposes: [Expose]) {
        for expose in exposes where expose.type == "lock" && expose.features != nil {
            guard let state = expose.feature("state"), state.isBinary, state.isPublished, state.isSettable,
                  let lockState = expose.feature("lock_state"), lockState.isEnum, lockState.isPublished else { continue }
            guard lockState.valueStrings.allSatisfy(["locked", "unlocked", "not_fully_locked"].contains) else {
                warn("lock_state has values a lock cannot show", expose)
                continue
            }
            guard claim(.lockMechanism, subtype: expose.endpoint) else { continue }
            add(LockHandler(service: service(.lockMechanism, subtype: expose.endpoint), state: state, lockState: lockState, link: link))
        }
    }
}

// MARK: Thermostat (9.5)

final class ThermostatHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let localTemperature: Expose
    private let setpoint: Expose
    private let systemMode: Expose?
    private let runningState: Expose?
    static let running = ["idle": 0, "heat": 1, "cool": 2]
    static let modes = ["off": 0, "heat": 1, "cool": 2, "auto": 3]

    init(service: Service, localTemperature: Expose, setpoint: Expose, systemMode: Expose?, runningState: Expose?, link: DeviceLink) {
        self.service = service
        self.localTemperature = localTemperature
        self.setpoint = setpoint
        self.systemMode = systemMode
        self.runningState = runningState
        gettableKeys = [localTemperature.gettableProperty, setpoint.gettableProperty, systemMode?.gettableProperty, runningState?.gettableProperty].compactMap { $0 }
        let setpointProperty = setpoint.property ?? "current_heating_setpoint"
        service.characteristic(.targetTemperature).onWrite { value in
            link.set([setpointProperty: .number(value.doubleValue ?? 0)])
        }
        if let systemMode, let property = systemMode.property {
            service.characteristic(.targetHeatingCoolingState).onWrite { value in
                guard let mode = Self.modes.first(where: { $0.value == value.intValue })?.key, systemMode.valueStrings.contains(mode) else { return }
                link.set([property: .string(mode)])
            }
        } else {
            service.characteristic(.targetHeatingCoolingState).onWrite { _ in
                throw HAPStatusError(.serviceCommunicationFailure, reason: "changing the target state is not supported")
            }
        }
    }

    func update(_ message: [String: JSONValue]) {
        if let property = localTemperature.property, let value = message[property]?.doubleValue {
            service.characteristic(.currentTemperature).value = .double(value)
        }
        if let property = setpoint.property, let value = message[property]?.doubleValue {
            service.characteristic(.targetTemperature).value = .double(value)
        }
        if let property = runningState?.property, let value = message[property]?.stringValue, let state = Self.running[value] {
            service.characteristic(.currentHeatingCoolingState).value = .int(state)
        }
        if let property = systemMode?.property, let value = message[property]?.stringValue, let mode = Self.modes[value] {
            service.characteristic(.targetHeatingCoolingState).value = .int(mode)
        }
    }
}

extension ServiceBuilder {
    func buildThermostats(_ exposes: [Expose]) {
        for expose in exposes where expose.type == "climate" {
            guard let features = expose.features, !features.contains(where: { $0.name == "occupied_cooling_setpoint" }) else { continue }
            guard let setpoint = features.first(where: { ["current_heating_setpoint", "occupied_heating_setpoint"].contains($0.name) && $0.hasProperty && $0.isPublished && $0.isSettable }),
                  let local = features.first(where: { $0.name == "local_temperature" && $0.hasProperty && $0.isPublished }) else { continue }
            var systemMode = features.first { $0.name == "system_mode" && $0.isEnum && $0.isPublished && $0.isSettable }
            var runningState = features.first { $0.name == "running_state" && $0.isEnum && $0.isPublished }
            if (systemMode == nil) != (runningState == nil) {
                link.log.debug("\(link.displayName): system_mode and running_state are used only together")
                systemMode = nil
                runningState = nil
            }
            func single(_ type: CharacteristicType, _ value: Int) -> Characteristic {
                Characteristic(type.with(minValue: Double(value), maxValue: Double(value), validValues: [value]), value: .int(value))
            }
            func restricted(_ type: CharacteristicType, _ values: [Int]) -> Characteristic {
                Characteristic(type.with(minValue: Double(values.min() ?? 0), maxValue: Double(values.max() ?? 0), validValues: values), value: .int(values[0]))
            }
            var extra = [single(.temperatureDisplayUnits, 0)]
            if let systemMode, let runningState {
                let running = ["idle", "heat", "cool"].filter(runningState.valueStrings.contains).compactMap { ThermostatHandler.running[$0] }
                let modes = ["off", "heat", "cool", "auto"].filter(systemMode.valueStrings.contains).compactMap { ThermostatHandler.modes[$0] }
                guard !running.isEmpty, !modes.isEmpty else {
                    warn("no running state or system mode HomeKit has", expose)
                    continue
                }
                extra += [restricted(.currentHeatingCoolingState, running), restricted(.targetHeatingCoolingState, modes)]
            } else {
                extra += [single(.currentHeatingCoolingState, 1), single(.targetHeatingCoolingState, 1)]
            }
            guard claim(.thermostat, subtype: expose.endpoint) else { continue }
            let service = service(.thermostat, subtype: expose.endpoint,
                                  optional: [ranged(.currentTemperature, local), ranged(.targetTemperature, setpoint)], extra: extra)
            add(ThermostatHandler(service: service, localTemperature: local, setpoint: setpoint, systemMode: systemMode, runningState: runningState, link: link))
        }
    }
}

// MARK: Battery (9.10)

final class BatteryHandler: ServiceHandler, @unchecked Sendable {
    let service: Service
    let gettableKeys: [String]
    private let level: Expose?
    private let low: Expose?
    private let link: DeviceLink

    init(service: Service, level: Expose?, low: Expose?, link: DeviceLink) {
        self.service = service
        self.level = level
        self.low = low
        self.link = link
        gettableKeys = [level?.gettableProperty, low?.gettableProperty].compactMap { $0 }
        service.characteristic(.chargingState).value = .int(2)
    }

    func update(_ message: [String: JSONValue]) {
        if let level, let property = level.property, let value = message[property]?.doubleValue, let min = level.valueMin, let max = level.valueMax, min != max {
            link.setNumber(service.characteristic(.batteryLevel), linearScale(value, from: min, max, to: 0, 100))
            if low == nil { service.characteristic(.statusLowBattery).value = .int(value < 30 ? 1 : 0) }
        }
        if let low, let property = low.property, let isLow = low.onOff(message[property]) {
            service.characteristic(.statusLowBattery).value = .int(isLow ? 1 : 0)
            if level == nil { service.characteristic(.batteryLevel).value = .int(isLow ? 0 : 100) }
        }
    }
}

extension ServiceBuilder {
    func buildBatteries(_ exposes: [Expose]) {
        let groups = Self.groupedByEndpoint(exposes) { ($0.name == "battery" && $0.isNumericRange) || ($0.name == "battery_low" && $0.isBinary) }
        for (endpoint, entries) in groups {
            guard claim(.battery, subtype: endpoint) else { continue }
            let service = service(.battery, subtype: endpoint, optional: [.batteryLevel, .chargingState])
            add(BatteryHandler(service: service, level: entries.first { $0.name == "battery" }, low: entries.first { $0.name == "battery_low" }, link: link))
        }
    }
}
